//
//  WebRTCSignalingResponder.swift
//  Peel
//
//  Watches Firestore for incoming WebRTC SDP offers and responds
//  by creating a WebRTC peer connection, exchanging SDP/ICE, and
//  serving data via a data channel.
//
//  Replaces STUNSignalingResponder — instead of custom STUN+UDP hole punch,
//  WebRTC handles all NAT traversal (ICE) and reliable data transfer (SCTP).
//

import Foundation
import os.log
import FirebaseFirestore
import WebRTCTransfer

@MainActor
@Observable
public final class WebRTCSignalingResponder {
  private let logger = Logger(subsystem: "com.peel.webrtc", category: "Responder")

  /// Active Firestore listeners, keyed by swarmId
  private var listeners: [String: ListenerRegistration] = [:]
  private var isActive = false

  /// Track offer fingerprints we've already responded to.
  /// Retries reuse the same Firestore document ID, so doc ID alone is not enough.
  private var respondedOfferFingerprints: Set<String> = []

  /// Active serve task — tracked to prevent concurrent transfers
  private(set) var activeServeTask: Task<Void, Never>?

  /// Data provider for serving transfer data
  weak var dataProvider: WebRTCTransferDataProvider?

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
          if let error { self?.logger.error("WebRTC signaling listener error: \(error)") }
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
            self.respondedOfferFingerprints.insert(offerFingerprint)

            self.logger.info("WebRTC offer received from \(fromWorkerId) (purpose: \(purpose))")
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

    logger.info("WebRTC signaling responder started for \(swarmIds.count) swarm(s)")
  }

  func stop() {
    for (_, listener) in listeners {
      listener.remove()
    }
    listeners.removeAll()
    respondedOfferFingerprints.removeAll()
    activeServeTask?.cancel()
    activeServeTask = nil
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
    logger.notice("[responder] respondToOffer: from=\(fromWorkerId) purpose=\(purpose) (on MainActor: \(Thread.isMainThread))")
    // Create signaling channel for this session
    let signaling = FirestoreWebRTCSignaling(
      swarmId: swarmId,
      myDeviceId: myDeviceId,
      remoteDeviceId: fromWorkerId
    )

    // Only cancel previous task for ping (lightweight). For transfers, let them finish.
    // Blindly cancelling was killing multi-chunk transfers when Firestore re-fired.
    if purpose == "ping" || activeServeTask == nil {
      activeServeTask?.cancel()
    } else if let existing = activeServeTask, !existing.isCancelled {
      logger.info("Skipping new offer — active transfer in progress from \(fromWorkerId)")
      return
    }

    if purpose == "ping" {
      // Ping: lightweight connectivity test, no data provider needed
      activeServeTask = Task {
        do {
          try await WebRTCPeerTransfer.respondToPing(signaling: signaling)
          await MainActor.run {
            self.logger.info("WebRTC ping response completed")
          }
        } catch {
          await MainActor.run {
            self.logger.error("WebRTC ping response failed: \(error)")
          }
        }
      }
      return
    }

    if purpose == "session" {
      // Persistent session: accept via PeerSessionManager
      guard let peerSessionManager else {
        logger.warning("No PeerSessionManager — cannot accept session from \(fromWorkerId)")
        return
      }
      Task {
        do {
          try await peerSessionManager.acceptFromPeer(fromWorkerId, signaling: signaling)
          await MainActor.run {
            self.logger.notice("Persistent session accepted from \(fromWorkerId)")
            self.onSessionAccepted?(fromWorkerId)
          }
        } catch {
          await MainActor.run {
            self.logger.error("Failed to accept session from \(fromWorkerId): \(error)")
          }
        }
      }
      return
    }

    // Transfer: serve data to remote peer
    guard let dataProvider else {
      logger.warning("No data provider — cannot serve WebRTC transfer from \(fromWorkerId)")
      return
    }

    logger.info("Starting serveData for \(fromWorkerId)")

    activeServeTask = Task {
      let taskStart = ContinuousClock.now
      do {
        try await WebRTCPeerTransfer.serveData(
          signaling: signaling,
          dataProvider: dataProvider
        )
        await MainActor.run {
          self.logger.notice("[responder] serve completed in \(ContinuousClock.now - taskStart)")
        }
      } catch {
        await MainActor.run {
          self.logger.error("[responder] serve failed after \(ContinuousClock.now - taskStart): \(error)")
        }
      }
    }
  }
}
