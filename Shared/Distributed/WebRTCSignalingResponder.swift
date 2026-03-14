//
//  WebRTCSignalingResponder.swift
//  Peel
//
//  Watches Firestore for incoming WebRTC SDP offers and responds
//  by accepting persistent peer sessions via PeerSessionManager.
//  One-shot ping and transfer purposes have been removed — all
//  peer communication now uses persistent WebRTC sessions.
//

import Foundation
import os.log
import FirebaseFirestore

@MainActor
@Observable
public final class WebRTCSignalingResponder {
  private let logger = Logger(subsystem: "com.peel.webrtc", category: "Responder")

  /// Active Firestore listeners, keyed by swarmId
  private var listeners: [String: ListenerRegistration] = [:]
  private var isActive = false

  /// Track offer fingerprints we've already responded to.
  /// Capped at 500 entries; oldest are evicted first to prevent unbounded growth.
  private var respondedOfferFingerprints: [String] = []
  private static let maxOfferFingerprints = 500

  /// Peer session manager — handles persistent session offers
  var peerSessionManager: PeerSessionManager?
  /// Called on MainActor after a persistent session is accepted from a peer.
  var onSessionAccepted: (@MainActor (String) -> Void)?

  /// Swarm ID → my device ID mapping (for creating signaling channels)
  private var myDeviceId: String = ""

  // MARK: - Lifecycle

  func start(swarmIds: [String], myDeviceId: String) {
    guard !isActive else { return }
    isActive = true
    self.myDeviceId = myDeviceId
    respondedOfferFingerprints.removeAll()

    let db = Firestore.firestore()

    for swarmId in swarmIds {
      // Watch for WebRTC offers targeting this device
      let query = db.collection("swarms/\(swarmId)/webrtcSignaling")
        .whereField("toWorkerId", isEqualTo: myDeviceId)
        .whereField("type", isEqualTo: "offer")

      let listener = query.addSnapshotListener { [weak self] snapshot, error in
        guard let self, let snapshot else {
          if let error { self?.logger.error("WebRTC signaling listener error: \(error.localizedDescription, privacy: .public)") }
          return
        }

        // Process new offers and meaningful offer retries. Retry attempts reuse the
        // same document ID with a new SDP, so dedupe by document ID + SDP instead of
        // document ID alone. Candidate updates arrive in a subcollection, not as offer
        // document modifications, so this will not re-trigger on normal ICE traffic.
        for change in snapshot.documentChanges where change.type == .added || change.type == .modified {
          let data = change.document.data()

          guard let fromWorkerId = data["fromWorkerId"] as? String,
            let sdp = data["sdp"] as? String
          else { continue }

          let purpose = data["purpose"] as? String ?? "transfer"

          // Check expiry
          if let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue(),
            expiresAt < Date()
          { continue }

          let docId = change.document.documentID
          let offerFingerprint = "\(docId):\(sdp)"

          Task { @MainActor in
            guard !self.respondedOfferFingerprints.contains(offerFingerprint) else { return }
            self.respondedOfferFingerprints.append(offerFingerprint)
            if self.respondedOfferFingerprints.count > Self.maxOfferFingerprints {
              self.respondedOfferFingerprints.removeFirst(self.respondedOfferFingerprints.count - Self.maxOfferFingerprints)
            }

            self.logger.info("WebRTC offer received from \(fromWorkerId, privacy: .public) (purpose: \(purpose, privacy: .public))")
            await self.respondToOffer(
              swarmId: swarmId,
              fromWorkerId: fromWorkerId,
              offerSDP: sdp,
              purpose: purpose
            )
          }
        }
      }

      listeners[swarmId] = listener
    }

    logger.info("WebRTC signaling responder started for \(swarmIds.count, privacy: .public) swarm(s)")
  }

  func stop() {
    for (_, listener) in listeners {
      listener.remove()
    }
    listeners.removeAll()
    respondedOfferFingerprints.removeAll()
    isActive = false
    logger.info("WebRTC signaling responder stopped")
  }

  // MARK: - Offer Handling

  private func respondToOffer(
    swarmId: String,
    fromWorkerId: String,
    offerSDP: String,
    purpose: String
  ) async {
    logger.notice("[responder] respondToOffer: from=\(fromWorkerId, privacy: .public) purpose=\(purpose, privacy: .public)")
    
    guard purpose == "session" else {
      logger.warning("Ignoring offer with unsupported purpose '\(purpose, privacy: .public)' from \(fromWorkerId, privacy: .public)")
      return
    }

    let signaling = FirestoreWebRTCSignaling(
      swarmId: swarmId,
      myDeviceId: myDeviceId,
      remoteDeviceId: fromWorkerId
    )

    guard let peerSessionManager else {
      logger.warning("No PeerSessionManager — cannot accept session from \(fromWorkerId, privacy: .public)")
      return
    }
    Task {
      do {
        try await peerSessionManager.acceptFromPeer(fromWorkerId, signaling: signaling)
        await MainActor.run {
          self.logger.notice("Persistent session accepted from \(fromWorkerId, privacy: .public)")
          self.onSessionAccepted?(fromWorkerId)
        }
      } catch {
        await MainActor.run {
          self.logger.error("Failed to accept session from \(fromWorkerId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
      }
    }
  }
}
