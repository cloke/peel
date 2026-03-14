//
//  FirestoreWebRTCSignaling.swift
//  Peel
//
//  Implements WebRTCSignalingChannel using Firestore for exchanging
//  SDP offers/answers and ICE candidates between peers.
//
//  Uses the Firestore collection path:
//    swarms/{swarmId}/webrtcSignaling/
//
//  Document structure for WebRTC signaling:
//    {myDeviceId}_to_{targetDeviceId}:
//      - type: "offer" | "answer"
//      - sdp: String (SDP content)
//      - createdAt: Timestamp
//      - expiresAt: Timestamp
//
//    {myDeviceId}_to_{targetDeviceId}_candidates/{auto-id}:
//      - sdp: String
//      - sdpMid: String?
//      - sdpMLineIndex: Int
//      - createdAt: Timestamp
//

import Foundation
import FirebaseFirestore
import os.log
import WebRTCTransfer

/// Firestore-backed signaling channel for WebRTC.
/// Each instance represents one signaling session between two peers.
///
/// Each session uses a unique `sessionId` to tag SDP offers and ICE candidates.
/// This prevents stale candidates from previous sessions (which accumulate in
/// Firestore subcollections) from being fed to the ICE agent.
final class FirestoreWebRTCSignaling: WebRTCSignalingChannel, @unchecked Sendable {
  private let logger = Logger(subsystem: "com.peel.webrtc", category: "Signaling")
  private let db = Firestore.firestore()

  private let swarmId: String
  private let myDeviceId: String
  private let remoteDeviceId: String

  /// Unique session identifier shared by both peers. The initiator generates
  /// it in `prepareSession()` and includes it in the SDP offer. The responder
  /// extracts it when the offer arrives.
  private(set) var sessionId: String?

  /// Purpose of this signaling session (e.g. "transfer", "ping").
  /// Written to the offer doc so the responder can dispatch appropriately.
  var purpose: String = "transfer"

  /// Firestore collection for this swarm's signaling
  private var signalingCollection: CollectionReference {
    db.collection("swarms/\(swarmId)/webrtcSignaling")
  }

  /// Document path: myDeviceId writes to {myDeviceId}_to_{remoteDeviceId}
  private var myDocRef: DocumentReference {
    signalingCollection.document("\(myDeviceId)_to_\(remoteDeviceId)")
  }

  /// Document path: remote writes to {remoteDeviceId}_to_{myDeviceId}
  private var remoteDocRef: DocumentReference {
    signalingCollection.document("\(remoteDeviceId)_to_\(myDeviceId)")
  }

  /// Subcollection for my outgoing ICE candidates
  private var myCandidatesCollection: CollectionReference {
    myDocRef.collection("candidates")
  }

  /// Subcollection for remote ICE candidates
  private var remoteCandidatesCollection: CollectionReference {
    remoteDocRef.collection("candidates")
  }

  /// Active listener registrations (for cleanup)
  private var listeners: [ListenerRegistration] = []

  init(swarmId: String, myDeviceId: String, remoteDeviceId: String) {
    self.swarmId = swarmId
    self.myDeviceId = myDeviceId
    self.remoteDeviceId = remoteDeviceId
  }

  /// Generate a fresh sessionId. Call this on the initiator side before
  /// creating the SDP offer so that local candidates sent to Firestore
  /// are tagged with the correct session.
  func prepareSession() {
    sessionId = UUID().uuidString
    logger.notice("[signaling] session prepared: \(self.sessionId ?? "?", privacy: .public)")
  }

  // MARK: - Offers & Answers

  func sendOffer(_ sdp: String) async throws {
    // Generate sessionId if not already prepared
    if sessionId == nil { prepareSession() }

    // Delete any stale remote answer doc so we can detect a fresh one
    try? await remoteDocRef.delete()

    let start = ContinuousClock.now
    try await myDocRef.setData([
      "type": "offer",
      "sdp": sdp,
      "sessionId": sessionId!,
      "fromWorkerId": myDeviceId,
      "toWorkerId": remoteDeviceId,
      "purpose": purpose,
      "createdAt": FieldValue.serverTimestamp(),
      "expiresAt": Timestamp(date: Date().addingTimeInterval(60)),
    ])
    logger.notice("[signaling] SDP offer written (session=\(self.sessionId?.prefix(8) ?? "?", privacy: .public)): \(ContinuousClock.now - start)")
  }

  func sendAnswer(_ sdp: String) async throws {
    let start = ContinuousClock.now
    var data: [String: Any] = [
      "type": "answer",
      "sdp": sdp,
      "fromWorkerId": myDeviceId,
      "toWorkerId": remoteDeviceId,
      "createdAt": FieldValue.serverTimestamp(),
      "expiresAt": Timestamp(date: Date().addingTimeInterval(60)),
    ]
    if let sessionId { data["sessionId"] = sessionId }
    try await myDocRef.setData(data)
    logger.notice("[signaling] SDP answer written (session=\(self.sessionId?.prefix(8) ?? "?", privacy: .public)): \(ContinuousClock.now - start)")
  }

  func waitForOffer(timeout: Duration) async throws -> String {
    try await waitForSDP(docRef: remoteDocRef, expectedType: "offer", timeout: timeout)
  }

  func waitForAnswer(timeout: Duration) async throws -> String {
    try await waitForSDP(docRef: remoteDocRef, expectedType: "answer", timeout: timeout)
  }

  private func waitForSDP(docRef: DocumentReference, expectedType: String, timeout: Duration) async throws -> String {
    logger.notice("[signaling] waiting for \(expectedType) (timeout: \(timeout), session=\(self.sessionId?.prefix(8) ?? "none", privacy: .public))")
    let waitStart = ContinuousClock.now
    let result = try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { [weak self] in
        guard let self else { throw WebRTCSignalingError.signalingClosed }
        let box = SDPContinuationBox()

        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            if Task.isCancelled {
              cont.resume(throwing: CancellationError())
              return
            }

            box.setContinuation(cont)

            let listener = docRef.addSnapshotListener { [weak self] snapshot, error in
              if let error {
                self?.logger.warning("[signaling] listener error for \(expectedType): \(error)")
                box.resume(throwing: error)
                return
              }
              guard let data = snapshot?.data(),
                let type = data["type"] as? String,
                type == expectedType,
                let sdp = data["sdp"] as? String
              else {
                self?.logger.debug("[signaling] listener fired for \(expectedType) but no match yet")
                return
              }

              // For offers: extract the initiator's sessionId so the responder
              // can tag its candidates and filter incoming ones.
              if expectedType == "offer", let sid = data["sessionId"] as? String {
                self?.sessionId = sid
                self?.logger.notice("[signaling] extracted sessionId \(sid.prefix(8), privacy: .public) from offer")
              }

              self?.logger.notice("[signaling] \(expectedType) received from Firestore")
              box.resume(returning: sdp)
            }
            box.setListener(listener)
            self.listeners.append(listener)
          }
        } onCancel: {
          box.cancel()
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WebRTCSignalingError.timeout(waiting: expectedType)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw WebRTCSignalingError.timeout(waiting: expectedType)
      }
      return result
    }
    logger.notice("[signaling] \(expectedType) resolved in \(ContinuousClock.now - waitStart)")
    return result
  }

  // MARK: - ICE Candidates

  func sendCandidate(_ candidate: ICECandidateMessage) async throws {
    var data: [String: Any] = [
      "sdp": candidate.sdp,
      "sdpMid": candidate.sdpMid as Any,
      "sdpMLineIndex": candidate.sdpMLineIndex,
      "createdAt": FieldValue.serverTimestamp(),
    ]
    if let sessionId { data["sessionId"] = sessionId }
    try await myCandidatesCollection.addDocument(data: data)
  }

  func receiveCandidates() -> AsyncStream<ICECandidateMessage> {
    let currentSessionId = sessionId
    return AsyncStream { continuation in
      var accepted = 0
      var rejected = 0
      let listener = remoteCandidatesCollection.addSnapshotListener { [weak self] snapshot, _ in
        guard let snapshot else { return }
        // Use the sessionId that was current when the stream was created,
        // or check the latest one (responder may set it after offer arrives).
        let sid = currentSessionId ?? self?.sessionId
        for change in snapshot.documentChanges where change.type == .added {
          let data = change.document.data()

          // Filter out candidates from previous sessions.
          // If we have a sessionId, only accept candidates tagged with the same one.
          if let sid {
            let candidateSid = data["sessionId"] as? String
            if candidateSid != sid {
              rejected += 1
              continue
            }
          }

          guard let sdp = data["sdp"] as? String,
            let sdpMLineIndex = data["sdpMLineIndex"] as? Int
          else { continue }
          let sdpMid = data["sdpMid"] as? String
          continuation.yield(ICECandidateMessage(
            sdp: sdp,
            sdpMid: sdpMid,
            sdpMLineIndex: Int32(sdpMLineIndex)
          ))
          accepted += 1
        }
        if rejected > 0 {
          self?.logger.notice("[signaling] candidates: \(accepted) accepted, \(rejected) stale rejected")
        }
      }
      self.listeners.append(listener)

      nonisolated(unsafe) let unsafeListener = listener
      continuation.onTermination = { @Sendable _ in
        unsafeListener.remove()
      }
    }
  }

  // MARK: - Cleanup

  func cleanup() async {
    // Remove listeners
    for listener in listeners {
      listener.remove()
    }
    listeners.removeAll()

    // Delete signaling documents after a delay
    Task {
      try? await Task.sleep(for: .seconds(10))
      // Delete my doc and its candidates subcollection
      let myCandidates = try? await self.myCandidatesCollection.getDocuments()
      for doc in myCandidates?.documents ?? [] {
        try? await doc.reference.delete()
      }
      try? await self.myDocRef.delete()

      // Delete remote doc and its candidates
      let remoteCandidates = try? await self.remoteCandidatesCollection.getDocuments()
      for doc in remoteCandidates?.documents ?? [] {
        try? await doc.reference.delete()
      }
      try? await self.remoteDocRef.delete()
    }
  }
}

// MARK: - Thread-Safe Continuation Box

/// Thread-safe wrapper to prevent continuation leaks when task cancellation
/// races with Firestore snapshot callbacks. The `onCancel` handler from
/// `withTaskCancellationHandler` can fire on any thread, so we need a lock.
private final class SDPContinuationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  private var listener: ListenerRegistration?
  private var resumed = false

  func setContinuation(_ cont: CheckedContinuation<String, Error>) {
    lock.lock()
    defer { lock.unlock() }
    continuation = cont
  }

  func setListener(_ l: ListenerRegistration) {
    lock.lock()
    defer { lock.unlock() }
    listener = l
  }

  func resume(returning value: String) {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed, let cont = continuation else { return }
    resumed = true
    continuation = nil
    cont.resume(returning: value)
  }

  func resume(throwing error: Error) {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed, let cont = continuation else { return }
    resumed = true
    continuation = nil
    cont.resume(throwing: error)
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    listener?.remove()
    listener = nil
    guard !resumed, let cont = continuation else { return }
    resumed = true
    continuation = nil
    cont.resume(throwing: CancellationError())
  }
}

// MARK: - Errors

enum WebRTCSignalingError: LocalizedError {
  case timeout(waiting: String)
  case signalingClosed

  var errorDescription: String? {
    switch self {
    case .timeout(let waiting): "Timed out waiting for \(waiting)"
    case .signalingClosed: "Signaling channel was closed"
    }
  }
}
