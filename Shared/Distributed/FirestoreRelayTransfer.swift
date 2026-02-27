//
//  FirestoreRelayTransfer.swift
//  Peel
//
//  Relays RAG data through Firestore documents when all direct P2P
//  connections fail (LAN, WAN direct, STUN hole-punch).
//
//  This is the "always works" fallback — both peers already have
//  authenticated Firestore access, so no NAT traversal is needed.
//
//  Flow:
//  1. Consumer writes a relay request to Firestore
//  2. Provider detects the request, exports RAG data, writes chunks
//  3. Consumer reads the chunks and imports
//
//  Data is chunked into ~700KB base64-encoded documents to stay
//  under Firestore's 1MB per-document limit.
//

import Foundation
import os.log
import FirebaseFirestore

// MARK: - Provider (serves data via Firestore relay)

/// Watches for incoming relay requests targeting this device and fulfills
/// them by exporting RAG data and writing it as chunked Firestore documents.
///
/// Started when the swarm starts, stopped when it stops.
@MainActor
@Observable
public final class FirestoreRelayProvider {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "RelayProvider")

  /// Active Firestore listeners, keyed by swarmId
  private var listeners: [String: ListenerRegistration] = [:]
  private var isActive = false

  /// The delegate that can export RAG data
  weak var ragSyncDelegate: RAGArtifactSyncDelegate?

  /// Maximum raw chunk size in bytes (before base64 encoding).
  /// 700KB raw → ~940KB base64, safely under Firestore's 1MB doc limit.
  static let chunkSize = 700 * 1024

  /// Track requests we've already started processing
  private var processingRequests: Set<String> = []

  // MARK: - Lifecycle

  func start(swarmIds: [String], myDeviceId: String) {
    guard !isActive else { return }
    isActive = true
    processingRequests.removeAll()

    let db = Firestore.firestore()

    for swarmId in swarmIds {
      let query = db.collection("swarms/\(swarmId)/relayRequests")
        .whereField("targetWorkerId", isEqualTo: myDeviceId)
        .whereField("status", isEqualTo: "pending")

      let listener = query.addSnapshotListener { [weak self] snapshot, error in
        guard let self, let snapshot else {
          if let error { self?.logger.error("Relay provider listener error: \(error)") }
          return
        }

        for change in snapshot.documentChanges where change.type == .added {
          let data = change.document.data()
          guard let fromWorkerId = data["fromWorkerId"] as? String,
            let repoIdentifier = data["repoIdentifier"] as? String
          else { continue }

          let transferId = change.document.documentID

          Task { @MainActor in
            guard !self.processingRequests.contains(transferId) else { return }
            self.processingRequests.insert(transferId)

            await self.handleRelayRequest(
              transferId: transferId,
              fromWorkerId: fromWorkerId,
              repoIdentifier: repoIdentifier,
              swarmId: swarmId
            )
          }
        }
      }

      listeners[swarmId] = listener
    }

    logger.info("Firestore relay provider started for \(swarmIds.count) swarm(s)")
  }

  func stop() {
    for (_, listener) in listeners {
      listener.remove()
    }
    listeners.removeAll()
    processingRequests.removeAll()
    isActive = false
    logger.info("Firestore relay provider stopped")
  }

  // MARK: - Request Handling

  private func handleRelayRequest(
    transferId: String,
    fromWorkerId: String,
    repoIdentifier: String,
    swarmId: String
  ) async {
    logger.info("Relay request from \(fromWorkerId) for repo \(repoIdentifier)")

    let db = Firestore.firestore()
    let requestRef = db.collection("swarms/\(swarmId)/relayRequests").document(transferId)

    guard let delegate = ragSyncDelegate else {
      logger.error("No RAG sync delegate — cannot serve relay request")
      try? await requestRef.updateData(["status": "error", "error": "Provider has no RAG data available"])
      return
    }

    do {
      // Mark as exporting
      try await requestRef.updateData(["status": "exporting"])

      // Export the RAG bundle
      guard let bundle = try await delegate.createRepoSyncBundle(
        repoIdentifier: repoIdentifier,
        excludeFileHashes: []
      ) else {
        try await requestRef.updateData(["status": "error", "error": "Repo not found: \(repoIdentifier)"])
        return
      }

      let data = try JSONEncoder().encode(bundle)
      let totalChunks = (data.count + Self.chunkSize - 1) / Self.chunkSize

      logger.info("Exporting \(data.count) bytes (\(totalChunks) chunks) via Firestore relay")

      // Update status with metadata
      try await requestRef.updateData([
        "status": "uploading",
        "totalBytes": data.count,
        "totalChunks": totalChunks,
      ])

      // Write chunks
      let chunksRef = requestRef.collection("chunks")
      for i in 0..<totalChunks {
        let start = i * Self.chunkSize
        let end = min(start + Self.chunkSize, data.count)
        let chunkData = data[start..<end]
        let base64 = chunkData.base64EncodedString()

        try await chunksRef.document(String(format: "%06d", i)).setData([
          "index": i,
          "data": base64,
          "size": chunkData.count,
        ])

        if i % 10 == 0 || i == totalChunks - 1 {
          logger.debug("Relay upload progress: \(i + 1)/\(totalChunks)")
        }
      }

      // Mark complete
      try await requestRef.updateData(["status": "complete"])
      logger.info("Relay upload complete: \(totalChunks) chunks, \(data.count) bytes")

      // Clean up after 5 minutes
      Task {
        try? await Task.sleep(for: .seconds(300))
        await Self.cleanupRelayDocs(requestRef: requestRef, chunksRef: chunksRef)
      }

    } catch {
      logger.error("Relay export failed: \(error)")
      try? await requestRef.updateData(["status": "error", "error": error.localizedDescription])
    }
  }

  /// Delete the relay request and all chunk documents
  private static func cleanupRelayDocs(
    requestRef: DocumentReference,
    chunksRef: CollectionReference
  ) async {
    let chunkDocs = try? await chunksRef.getDocuments()
    for doc in chunkDocs?.documents ?? [] {
      try? await doc.reference.delete()
    }
    try? await requestRef.delete()
  }
}

// MARK: - Consumer (receives data via Firestore relay)

/// Used by the pull side to request RAG data via Firestore when direct
/// connections are unavailable. Writes a relay request, polls for the
/// provider to upload chunks, then downloads and imports.
@MainActor
public final class FirestoreRelayConsumer {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "RelayConsumer")

  /// Maximum time to wait for the provider to finish uploading (seconds)
  private let timeout: TimeInterval = 300

  /// Request a RAG index from a remote peer via Firestore relay.
  ///
  /// - Parameters:
  ///   - worker: The remote worker to request from
  ///   - repoIdentifier: Which repo's RAG index to pull
  ///   - swarmId: Firestore swarm ID for the relay collection path
  ///   - ragSyncDelegate: Delegate to import the received bundle
  ///   - state: Transfer state for UI progress reporting
  func requestIndex(
    from worker: FirestoreWorker,
    repoIdentifier: String,
    swarmId: String,
    ragSyncDelegate: RAGArtifactSyncDelegate,
    state: OnDemandTransferState
  ) async throws {
    let db = Firestore.firestore()
    let transferId = state.id.uuidString
    let myDeviceId = WorkerCapabilities.current().deviceId

    // 1. Write the relay request
    let requestRef = db.collection("swarms/\(swarmId)/relayRequests").document(transferId)
    try await requestRef.setData([
      "fromWorkerId": myDeviceId,
      "targetWorkerId": worker.workerId,
      "repoIdentifier": repoIdentifier,
      "status": "pending",
      "createdAt": FieldValue.serverTimestamp(),
    ])

    logger.info("Relay request written for \(repoIdentifier) from \(worker.displayName)")
    state.status = .transferring

    // 2. Poll for the provider to finish uploading
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      try? await Task.sleep(for: .seconds(2))

      let doc = try await requestRef.getDocument()
      guard let data = doc.data() else { continue }
      let status = data["status"] as? String ?? ""

      switch status {
      case "complete":
        // 3. Download all chunks
        let totalBytes = data["totalBytes"] as? Int ?? 0
        let totalChunks = data["totalChunks"] as? Int ?? 0
        state.totalBytes = totalBytes
        state.totalChunks = totalChunks

        logger.info("Relay transfer ready: \(totalChunks) chunks, \(totalBytes) bytes")

        let chunksRef = requestRef.collection("chunks")
        let chunkDocs = try await chunksRef.order(by: "index").getDocuments()

        var assembled = Data()
        assembled.reserveCapacity(totalBytes)
        for (i, doc) in chunkDocs.documents.enumerated() {
          guard let base64 = doc.data()["data"] as? String,
            let chunkData = Data(base64Encoded: base64)
          else {
            throw OnDemandTransferError.invalidChunkData(index: i)
          }
          assembled.append(chunkData)
          state.chunksReceived = i + 1
          state.transferredBytes = assembled.count
        }

        // 4. Import
        state.status = .importing
        let bundle = try JSONDecoder().decode(RAGRepoExportBundle.self, from: assembled)
        _ = try await ragSyncDelegate.applyRepoSyncBundle(
          bundle, localRepoPath: nil, forceImportEmbeddings: true
        )

        state.status = .complete
        state.completedAt = Date()
        logger.info("Relay import complete: \(assembled.count) bytes")

        // Clean up our request (provider will clean up chunks)
        Task {
          try? await Task.sleep(for: .seconds(10))
          try? await requestRef.delete()
        }
        return

      case "error":
        let errorMsg = data["error"] as? String ?? "Unknown relay error"
        throw OnDemandTransferError.remoteError(message: errorMsg)

      case "exporting":
        logger.debug("Relay: provider is exporting data...")

      case "uploading":
        if let uploaded = data["totalChunks"] as? Int {
          state.totalChunks = uploaded
        }
        logger.debug("Relay: provider is uploading chunks...")

      default:
        continue
      }
    }

    // Timed out waiting for provider
    try? await requestRef.updateData(["status": "timeout"])
    throw OnDemandTransferError.connectionTimeout(host: "firestore-relay", port: 0)
  }
}
