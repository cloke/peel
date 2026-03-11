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

  /// Track offers we've already responded to
  private var respondedOffers: Set<String> = []

  /// Active serve task — tracked to prevent concurrent transfers
  private(set) var activeServeTask: Task<Void, Never>?

  /// Data provider for serving transfer data
  weak var dataProvider: WebRTCTransferDataProvider?

  /// My device ID
  private var myDeviceId: String = ""

  // MARK: - Lifecycle

  func start(swarmIds: [String], myDeviceId: String) {
    guard !isActive else { return }
    isActive = true
    self.myDeviceId = myDeviceId
    respondedOffers.removeAll()

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

        for change in snapshot.documentChanges where change.type == .added || change.type == .modified {
          let data = change.document.data()

          guard let fromWorkerId = data["fromWorkerId"] as? String,
            let sdp = data["sdp"] as? String
          else { continue }

          // Check expiry
          if let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue(),
            expiresAt < Date()
          { continue }

          let docId = change.document.documentID

          Task { @MainActor in
            if change.type == .modified {
              self.respondedOffers.remove(docId)
            }
            guard !self.respondedOffers.contains(docId) else { return }
            self.respondedOffers.insert(docId)

            self.logger.info("WebRTC offer received from \(fromWorkerId)")
            await self.respondToOffer(
              swarmId: swarmId,
              fromWorkerId: fromWorkerId,
              offerSDP: sdp
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
    respondedOffers.removeAll()
    activeServeTask?.cancel()
    activeServeTask = nil
    isActive = false
    logger.info("WebRTC signaling responder stopped")
  }

  // MARK: - Offer Handling

  private func respondToOffer(
    swarmId: String,
    fromWorkerId: String,
    offerSDP: String
  ) async {
    guard let dataProvider else {
      logger.warning("No data provider — cannot serve WebRTC transfer")
      return
    }

    // Create signaling channel for this session
    let signaling = FirestoreWebRTCSignaling(
      swarmId: swarmId,
      myDeviceId: myDeviceId,
      remoteDeviceId: fromWorkerId
    )

    // Cancel any previous serve task
    activeServeTask?.cancel()
    activeServeTask = Task {
      do {
        // The signaling channel already has the offer in Firestore.
        // WebRTCPeerTransfer.serveData will:
        // 1. Read the offer from signaling
        // 2. Create answer and send via signaling
        // 3. Exchange ICE candidates
        // 4. Open data channel
        // 5. Serve the requested data
        try await WebRTCPeerTransfer.serveData(
          signaling: signaling,
          dataProvider: dataProvider
        )
        await MainActor.run {
          self.logger.info("WebRTC serve completed successfully")
        }
      } catch {
        await MainActor.run {
          self.logger.error("WebRTC serve failed: \(error)")
        }
      }
    }
  }
}
