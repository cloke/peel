//
//  FirestoreRelayTransfer.swift
//  Peel
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │  ⚠️  DEPRECATED — DO NOT USE AS A FALLBACK IN OnDemandPeerTransfer  │
// │                                                                     │
// │  This file sends actual RAG data (~30MB+) as base64 chunks through  │
// │  Firestore documents. This is expensive, slow, and violates the     │
// │  architecture: Firestore is for coordination/signaling ONLY.        │
// │                                                                     │
// │  The correct transfer pipeline is P2P only:                         │
// │    TCP LAN → TCP WAN → WebRTC data channel → FAIL                  │
// │                                                                     │
// │  If P2P fails, fix the P2P path — do NOT route data through here.   │
// │  This code is retained for reference but must not be wired as a     │
// │  fallback in the transfer pipeline.                                 │
// └─────────────────────────────────────────────────────────────────────┘
//
//  Original purpose (now deprecated):
//  Relayed RAG data through Firestore documents when all direct P2P
//  connections failed (LAN, WAN direct, STUN hole-punch).
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

    let startTime = Date()

    do {
      // Mark as exporting
      logger.info("[relay-provider] Setting status=exporting for transfer \(transferId)")
      try await requestRef.updateData(["status": "exporting"])

      // Export the RAG bundle
      logger.info("[relay-provider] Creating sync bundle for \(repoIdentifier)...")
      guard let bundle = try await delegate.createRepoSyncBundle(
        repoIdentifier: repoIdentifier,
        excludeFileHashes: []
      ) else {
        logger.error("[relay-provider] Repo not found: \(repoIdentifier)")
        try await requestRef.updateData(["status": "error", "error": "Repo not found: \(repoIdentifier)"])
        return
      }

      let data = try JSONEncoder().encode(bundle)
      let totalChunks = (data.count + Self.chunkSize - 1) / Self.chunkSize
      let exportElapsed = Date().timeIntervalSince(startTime)

      logger.info("[relay-provider] Bundle exported: \(data.count) bytes (\(totalChunks) chunks) in \(String(format: "%.1f", exportElapsed))s")

      // Update status with metadata
      try await requestRef.updateData([
        "status": "uploading",
        "totalBytes": data.count,
        "totalChunks": totalChunks,
        "chunksUploaded": 0,
      ])

      // Write chunks — update progress counter every chunk so consumer can track
      let chunksRef = requestRef.collection("chunks")
      for i in 0..<totalChunks {
        let start = i * Self.chunkSize
        let end = min(start + Self.chunkSize, data.count)
        let chunkData = data[start..<end]
        let base64 = chunkData.base64EncodedString()

        let chunkStart = Date()
        do {
          try await chunksRef.document(String(format: "%06d", i)).setData([
            "index": i,
            "data": base64,
            "size": chunkData.count,
          ])
          let chunkElapsed = Date().timeIntervalSince(chunkStart)

          // Update progress counter on the request doc
          try await requestRef.updateData(["chunksUploaded": i + 1])

          if i % 5 == 0 || i == totalChunks - 1 {
            let totalElapsed = Date().timeIntervalSince(startTime)
            logger.info("[relay-provider] Uploaded chunk \(i + 1)/\(totalChunks) (\(chunkData.count) bytes, \(String(format: "%.2f", chunkElapsed))s this chunk, \(String(format: "%.1f", totalElapsed))s total)")
          }
        } catch {
          logger.error("[relay-provider] FAILED to upload chunk \(i)/\(totalChunks): \(error)")
          try? await requestRef.updateData(["status": "error", "error": "Chunk upload failed at \(i)/\(totalChunks): \(error.localizedDescription)"])
          return
        }
      }

      // Mark complete
      let totalElapsed = Date().timeIntervalSince(startTime)
      try await requestRef.updateData(["status": "complete"])
      logger.info("[relay-provider] Upload complete: \(totalChunks) chunks, \(data.count) bytes in \(String(format: "%.1f", totalElapsed))s")

      // Clean up after 5 minutes
      Task {
        try? await Task.sleep(for: .seconds(300))
        await Self.cleanupRelayDocs(requestRef: requestRef, chunksRef: chunksRef)
      }

    } catch {
      let elapsed = Date().timeIntervalSince(startTime)
      logger.error("[relay-provider] Export failed after \(String(format: "%.1f", elapsed))s: \(error)")
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
    let deadline = Date().addingTimeInterval(self.timeout)
    let pollStart = Date()
    var pollCount = 0

    logger.info("[relay-consumer] Polling for provider response (timeout: \(Int(self.timeout))s)...")

    while Date() < deadline {
      try? await Task.sleep(for: .seconds(2))
      pollCount += 1
      let elapsed = Date().timeIntervalSince(pollStart)

      let doc: DocumentSnapshot
      do {
        doc = try await requestRef.getDocument()
      } catch {
        logger.error("[relay-consumer] Poll \(pollCount): Firestore read error after \(String(format: "%.0f", elapsed))s: \(error)")
        continue
      }

      guard let data = doc.data() else {
        logger.warning("[relay-consumer] Poll \(pollCount): document has no data (\(String(format: "%.0f", elapsed))s elapsed)")
        continue
      }

      let status = data["status"] as? String ?? "<nil>"
      let chunksUploaded = data["chunksUploaded"] as? Int ?? 0
      let totalChunks = data["totalChunks"] as? Int ?? 0
      let totalBytes = data["totalBytes"] as? Int ?? 0

      // Update state for UI progress during upload phase
      if totalChunks > 0 {
        state.totalChunks = totalChunks
        state.totalBytes = totalBytes
        state.chunksReceived = chunksUploaded
      }

      // Log every poll at info level while debugging
      logger.info("[relay-consumer] Poll \(pollCount) (\(String(format: "%.0f", elapsed))s): status=\(status) chunks=\(chunksUploaded)/\(totalChunks) totalBytes=\(totalBytes)")

      switch status {
      case "complete":
        // 3. Download all chunks
        state.totalBytes = totalBytes
        state.totalChunks = totalChunks

        logger.info("[relay-consumer] Provider upload complete: \(totalChunks) chunks, \(totalBytes) bytes. Starting download...")

        let chunksRef = requestRef.collection("chunks")
        let downloadStart = Date()
        let chunkDocs: QuerySnapshot
        do {
          chunkDocs = try await chunksRef.order(by: "index").getDocuments()
        } catch {
          logger.error("[relay-consumer] Failed to fetch chunks collection: \(error)")
          throw OnDemandTransferError.remoteError(message: "Failed to fetch chunks: \(error.localizedDescription)")
        }

        logger.info("[relay-consumer] Fetched \(chunkDocs.documents.count) chunk documents in \(String(format: "%.1f", Date().timeIntervalSince(downloadStart)))s")

        if chunkDocs.documents.count != totalChunks {
          logger.error("[relay-consumer] Chunk count mismatch: expected \(totalChunks), got \(chunkDocs.documents.count)")
        }

        var assembled = Data()
        assembled.reserveCapacity(totalBytes)
        for (i, doc) in chunkDocs.documents.enumerated() {
          guard let base64 = doc.data()["data"] as? String,
            let chunkData = Data(base64Encoded: base64)
          else {
            logger.error("[relay-consumer] Invalid chunk data at index \(i) — doc fields: \(doc.data().keys.sorted())")
            throw OnDemandTransferError.invalidChunkData(index: i)
          }
          assembled.append(chunkData)
          state.chunksReceived = i + 1
          state.transferredBytes = assembled.count

          if i % 10 == 0 || i == chunkDocs.documents.count - 1 {
            logger.info("[relay-consumer] Downloaded chunk \(i + 1)/\(chunkDocs.documents.count) (\(assembled.count) bytes so far)")
          }
        }

        let downloadElapsed = Date().timeIntervalSince(downloadStart)
        logger.info("[relay-consumer] All chunks downloaded: \(assembled.count) bytes in \(String(format: "%.1f", downloadElapsed))s")

        // 4. Import
        state.status = .importing
        logger.info("[relay-consumer] Decoding bundle (\(assembled.count) bytes)...")
        let bundle: RAGRepoExportBundle
        do {
          bundle = try JSONDecoder().decode(RAGRepoExportBundle.self, from: assembled)
          logger.info("[relay-consumer] Bundle decoded successfully")
        } catch {
          logger.error("[relay-consumer] Bundle decode failed: \(error)")
          throw error
        }

        logger.info("[relay-consumer] Importing bundle...")
        do {
          _ = try await ragSyncDelegate.applyRepoSyncBundle(
            bundle, localRepoPath: nil, forceImportEmbeddings: true
          )
        } catch {
          logger.error("[relay-consumer] Import failed: \(error)")
          throw error
        }

        state.status = .complete
        state.completedAt = Date()
        let totalElapsed = Date().timeIntervalSince(pollStart)
        logger.info("[relay-consumer] Import complete: \(assembled.count) bytes, total time \(String(format: "%.1f", totalElapsed))s")

        // Clean up our request (provider will clean up chunks)
        Task {
          try? await Task.sleep(for: .seconds(10))
          try? await requestRef.delete()
        }
        return

      case "error":
        let errorMsg = data["error"] as? String ?? "Unknown relay error"
        logger.error("[relay-consumer] Provider reported error: \(errorMsg)")
        throw OnDemandTransferError.remoteError(message: errorMsg)

      case "exporting":
        logger.info("[relay-consumer] Provider is exporting data... (\(String(format: "%.0f", elapsed))s elapsed)")

      case "uploading":
        logger.info("[relay-consumer] Provider uploading: \(chunksUploaded)/\(totalChunks) chunks (\(String(format: "%.0f", elapsed))s elapsed)")

      case "pending":
        logger.info("[relay-consumer] Waiting for provider to pick up request... (\(String(format: "%.0f", elapsed))s elapsed)")

      default:
        logger.warning("[relay-consumer] Unknown status: '\(status)' (\(String(format: "%.0f", elapsed))s elapsed)")
        continue
      }
    }

    // Timed out waiting for provider
    let totalElapsed = Date().timeIntervalSince(pollStart)
    logger.error("[relay-consumer] Timed out after \(String(format: "%.0f", totalElapsed))s (\(pollCount) polls)")
    try? await requestRef.updateData(["status": "timeout"])
    throw OnDemandTransferError.connectionTimeout(host: "firestore-relay", port: 0)
  }
}
