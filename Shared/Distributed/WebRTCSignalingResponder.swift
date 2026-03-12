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

        // Only process newly added offers. `.modified` events (e.g. ICE candidate
        // updates on the same document) must NOT re-trigger offer handling — that was
        // cancelling in-flight transfers after the first chunk.
        for change in snapshot.documentChanges where change.type == .added {
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

          Task { @MainActor in
            guard !self.respondedOffers.contains(docId) else { return }
            self.respondedOffers.insert(docId)

            self.logger.info("WebRTC offer received from \(fromWorkerId) (purpose: \(purpose))")
            P2PConnectionLog.shared.log("webrtc-responder", "Offer received", details: [
              "fromWorkerId": fromWorkerId,
              "purpose": purpose,
              "docId": docId,
              "hasDataProvider": String(self.dataProvider != nil),
            ])
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
    P2PConnectionLog.shared.log("webrtc-responder", "Signaling responder started", details: [
      "swarmCount": String(swarmIds.count),
      "deviceId": myDeviceId,
      "hasDataProvider": String(dataProvider != nil),
    ])
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
    offerSDP: String,
    purpose: String
  ) async {
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
      logger.info("Skipping new offer — active transfer in progress")
      P2PConnectionLog.shared.log("webrtc-responder", "Skipped offer, transfer in progress", details: [
        "fromWorkerId": fromWorkerId,
      ])
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

    // Transfer: serve data to remote peer
    guard let dataProvider else {
      logger.warning("No data provider — cannot serve WebRTC transfer")
      P2PConnectionLog.shared.log("webrtc-responder", "No data provider – cannot respond", details: [
        "fromWorkerId": fromWorkerId,
        "purpose": purpose,
      ])
      return
    }

    P2PConnectionLog.shared.log("webrtc-responder", "Starting serveData", details: [
      "fromWorkerId": fromWorkerId,
    ])

    activeServeTask = Task {
      do {
        try await WebRTCPeerTransfer.serveData(
          signaling: signaling,
          dataProvider: dataProvider
        )
        await MainActor.run {
          self.logger.info("WebRTC serve completed successfully")
          P2PConnectionLog.shared.log("webrtc-responder", "Serve completed", details: [
            "fromWorkerId": fromWorkerId,
          ])
        }
      } catch {
        await MainActor.run {
          self.logger.error("WebRTC serve failed: \(error)")
          P2PConnectionLog.shared.log("webrtc-responder", "Serve failed", details: [
            "error": "\(error)",
            "fromWorkerId": fromWorkerId,
          ])
        }
      }
    }
  }
}
