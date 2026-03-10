//
//  P2PLogRequestListener.swift
//  Peel
//
//  Watches Firestore for log requests targeting this device and responds
//  with the local P2PConnectionLog entries. Enables remote debugging of
//  P2P connections — critical when two machines can't see each other's
//  console output.
//
//  Collection path: swarms/{swarmId}/logRequests/{requestId}
//  - requesterId: who's asking
//  - targetWorkerId: who should respond
//  - createdAt: when the request was made
//  - status: "pending" → "responded"
//  - responseLogs: JSON string of P2PConnectionLog entries (written by responder)
//  - respondedAt: when the response was written
//

import Foundation
import FirebaseFirestore
import os.log

@MainActor
public final class P2PLogRequestListener {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "LogRequest")
  private var listeners: [String: ListenerRegistration] = [:]
  private var respondedRequests: Set<String> = []
  private var isActive = false

  func start(swarmIds: [String], myDeviceId: String) {
    guard !isActive else { return }
    isActive = true
    respondedRequests.removeAll()

    let db = Firestore.firestore()

    for swarmId in swarmIds {
      let query = db.collection("swarms/\(swarmId)/logRequests")
        .whereField("targetWorkerId", isEqualTo: myDeviceId)
        .whereField("status", isEqualTo: "pending")

      let listener = query.addSnapshotListener { [weak self] snapshot, error in
        guard let self, let snapshot else {
          if let error { self?.logger.error("Log request listener error: \(error)") }
          return
        }

        for change in snapshot.documentChanges where change.type == .added {
          let docId = change.document.documentID
          let data = change.document.data()

          guard let requesterId = data["requesterId"] as? String else { continue }

          Task { @MainActor in
            guard !self.respondedRequests.contains(docId) else { return }
            self.respondedRequests.insert(docId)

            await self.respondToLogRequest(
              swarmId: swarmId,
              requestId: docId,
              requesterId: requesterId
            )
          }
        }
      }

      listeners[swarmId] = listener
    }

    logger.info("P2P log request listener started for \(swarmIds.count) swarm(s)")
  }

  func stop() {
    for (_, listener) in listeners {
      listener.remove()
    }
    listeners.removeAll()
    respondedRequests.removeAll()
    isActive = false
    logger.info("P2P log request listener stopped")
  }

  private func respondToLogRequest(
    swarmId: String,
    requestId: String,
    requesterId: String
  ) async {
    logger.info("Responding to log request \(requestId) from \(requesterId)")

    let p2pLog = P2PConnectionLog.shared
    let logsJSON = p2pLog.toJSONString()
    let entryCount = p2pLog.entries.count

    let db = Firestore.firestore()
    let docRef = db.collection("swarms/\(swarmId)/logRequests").document(requestId)

    do {
      try await docRef.updateData([
        "status": "responded",
        "responseLogs": logsJSON,
        "responseEntryCount": entryCount,
        "respondedAt": FieldValue.serverTimestamp(),
        "responderDeviceId": WorkerCapabilities.current().deviceId,
        "responderDeviceName": WorkerCapabilities.current().deviceName,
      ])
      logger.info("Log request \(requestId) responded with \(entryCount) entries")
    } catch {
      logger.error("Failed to respond to log request \(requestId): \(error)")
    }
  }

  // MARK: - Requester API

  /// Request P2P logs from a remote worker via Firestore.
  /// Returns the log entries as a JSON string, or nil on timeout.
  static func requestLogs(
    fromWorkerId: String,
    swarmId: String,
    timeout: TimeInterval = 30
  ) async -> (logs: String, entryCount: Int, responderName: String)? {
    let db = Firestore.firestore()
    let requestId = UUID().uuidString
    let myDeviceId = WorkerCapabilities.current().deviceId

    let docRef = db.collection("swarms/\(swarmId)/logRequests").document(requestId)

    // Write the request
    do {
      try await docRef.setData([
        "requesterId": myDeviceId,
        "targetWorkerId": fromWorkerId,
        "status": "pending",
        "createdAt": FieldValue.serverTimestamp(),
      ])
    } catch {
      return nil
    }

    // Wait for response via snapshot listener
    actor ResponseState {
      var resumed = false
      func tryResume() -> Bool {
        guard !resumed else { return false }
        resumed = true
        return true
      }
    }

    let state = ResponseState()

    let result: (String, Int, String)? = await withCheckedContinuation { continuation in
      var listener: ListenerRegistration?

      let timeoutTask = Task {
        try? await Task.sleep(for: .seconds(timeout))
        guard await state.tryResume() else { return }
        listener?.remove()
        continuation.resume(returning: nil)
      }

      listener = docRef.addSnapshotListener { snapshot, error in
        guard let data = snapshot?.data(),
          data["status"] as? String == "responded",
          let logs = data["responseLogs"] as? String
        else { return }

        let entryCount = data["responseEntryCount"] as? Int ?? 0
        let responderName = data["responderDeviceName"] as? String ?? "unknown"

        Task {
          guard await state.tryResume() else { return }
          timeoutTask.cancel()
          listener?.remove()
          continuation.resume(returning: (logs, entryCount, responderName))
        }
      }
    }

    // Clean up the request doc
    try? await docRef.delete()

    guard let (logs, entryCount, responderName) = result else { return nil }
    return (logs: logs, entryCount: entryCount, responderName: responderName)
  }
}
