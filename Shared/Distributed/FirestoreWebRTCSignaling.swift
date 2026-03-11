//
//  FirestoreWebRTCSignaling.swift
//  Peel
//
//  Implements WebRTCSignalingChannel using Firestore for exchanging
//  SDP offers/answers and ICE candidates between peers.
//
//  Uses the same Firestore collection path as the previous STUN signaling:
//    swarms/{swarmId}/stunSignaling/
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
final class FirestoreWebRTCSignaling: WebRTCSignalingChannel, @unchecked Sendable {
  private let logger = Logger(subsystem: "com.peel.webrtc", category: "Signaling")
  private let db = Firestore.firestore()

  private let swarmId: String
  private let myDeviceId: String
  private let remoteDeviceId: String

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

  // MARK: - Offers & Answers

  func sendOffer(_ sdp: String) async throws {
    // Delete any stale remote answer doc so we can detect a fresh one
    try? await remoteDocRef.delete()

    try await myDocRef.setData([
      "type": "offer",
      "sdp": sdp,
      "fromWorkerId": myDeviceId,
      "toWorkerId": remoteDeviceId,
      "createdAt": FieldValue.serverTimestamp(),
      "expiresAt": Timestamp(date: Date().addingTimeInterval(60)),
    ])
    logger.info("SDP offer written to Firestore")
  }

  func sendAnswer(_ sdp: String) async throws {
    try await myDocRef.setData([
      "type": "answer",
      "sdp": sdp,
      "fromWorkerId": myDeviceId,
      "toWorkerId": remoteDeviceId,
      "createdAt": FieldValue.serverTimestamp(),
      "expiresAt": Timestamp(date: Date().addingTimeInterval(60)),
    ])
    logger.info("SDP answer written to Firestore")
  }

  func waitForOffer(timeout: Duration) async throws -> String {
    try await waitForSDP(docRef: remoteDocRef, expectedType: "offer", timeout: timeout)
  }

  func waitForAnswer(timeout: Duration) async throws -> String {
    try await waitForSDP(docRef: remoteDocRef, expectedType: "answer", timeout: timeout)
  }

  private func waitForSDP(docRef: DocumentReference, expectedType: String, timeout: Duration) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { [weak self] in
        guard let self else { throw WebRTCSignalingError.signalingClosed }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
          var resumed = false
          let listener = docRef.addSnapshotListener { snapshot, error in
            guard !resumed else { return }
            if let error {
              resumed = true
              cont.resume(throwing: error)
              return
            }
            guard let data = snapshot?.data(),
              let type = data["type"] as? String,
              type == expectedType,
              let sdp = data["sdp"] as? String
            else { return }

            resumed = true
            cont.resume(returning: sdp)
          }
          self.listeners.append(listener)
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
  }

  // MARK: - ICE Candidates

  func sendCandidate(_ candidate: ICECandidateMessage) async throws {
    try await myCandidatesCollection.addDocument(data: [
      "sdp": candidate.sdp,
      "sdpMid": candidate.sdpMid as Any,
      "sdpMLineIndex": candidate.sdpMLineIndex,
      "createdAt": FieldValue.serverTimestamp(),
    ])
  }

  func receiveCandidates() -> AsyncStream<ICECandidateMessage> {
    AsyncStream { continuation in
      let listener = remoteCandidatesCollection.addSnapshotListener { snapshot, _ in
        guard let snapshot else { return }
        for change in snapshot.documentChanges where change.type == .added {
          let data = change.document.data()
          guard let sdp = data["sdp"] as? String,
            let sdpMLineIndex = data["sdpMLineIndex"] as? Int
          else { continue }
          let sdpMid = data["sdpMid"] as? String
          continuation.yield(ICECandidateMessage(
            sdp: sdp,
            sdpMid: sdpMid,
            sdpMLineIndex: Int32(sdpMLineIndex)
          ))
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
