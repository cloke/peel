//
//  STUNSignalingResponder.swift
//  Peel
//
//  Watches Firestore for incoming STUN signaling offers and responds
//  with our own STUN endpoint to complete the bilateral exchange needed
//  for NAT hole-punching.
//
//  Without this, the initiator writes an offer but nobody writes an
//  answer back — the exchange is one-sided and always times out.
//
//  Lifecycle: started when the swarm starts, stopped when it stops.
//

import Foundation
import os.log
import FirebaseFirestore

@MainActor
@Observable
public final class STUNSignalingResponder {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "STUNResponder")

  /// Active Firestore listeners, keyed by swarmId
  private var listeners: [String: ListenerRegistration] = [:]
  private var isActive = false

  /// The local port our TCP listener is on (from PeerConnectionManager)
  private let listeningPort: UInt16

  /// Track offers we've already responded to (avoid duplicate answers)
  private var respondedOffers: Set<String> = []

  /// Data provider for UDP transfer responder (set by SwarmCoordinator)
  weak var dataProvider: UDPTransferDataProvider?

  init(listeningPort: UInt16 = 8766) {
    self.listeningPort = listeningPort
  }

  // MARK: - Lifecycle

  func start(swarmIds: [String], myDeviceId: String) {
    guard !isActive else { return }
    isActive = true
    respondedOffers.removeAll()

    let db = Firestore.firestore()

    for swarmId in swarmIds {
      // Watch for STUN offers targeting this device
      let query = db.collection("swarms/\(swarmId)/stunSignaling")
        .whereField("toWorkerId", isEqualTo: myDeviceId)

      let listener = query.addSnapshotListener { [weak self] snapshot, error in
        guard let self, let snapshot else {
          if let error { self?.logger.error("STUN signaling listener error: \(error)") }
          return
        }

        for change in snapshot.documentChanges where change.type == .added || change.type == .modified {
          let data = change.document.data()
          // Don't respond to our own answers
          if data["isAnswer"] as? Bool == true { continue }

          guard let fromWorkerId = data["fromWorkerId"] as? String,
            let stunAddress = data["stunAddress"] as? String,
            let stunPort = data["stunPort"] as? Int
          else { continue }

          // Check expiry
          if let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue(),
            expiresAt < Date()
          {
            continue
          }

          let docId = change.document.documentID

          Task { @MainActor in
            // For modified documents, allow re-processing (the initiator retried)
            if change.type == .modified {
              self.respondedOffers.remove(docId)
            }
            // Deduplicate
            guard !self.respondedOffers.contains(docId) else { return }
            self.respondedOffers.insert(docId)
            let p2pLog = P2PConnectionLog.shared
            p2pLog.log("stun-responder", "Offer received", details: [
              "fromWorkerId": fromWorkerId,
              "peerAddress": stunAddress,
              "peerPort": String(stunPort),
              "docId": docId,
              "swarmId": swarmId,
            ])
            let peerEndpoint = STUNResult(
              address: stunAddress,
              port: UInt16(stunPort),
              serverUsed: "signaling",
              latencyMs: 0
            )

            await self.respondToOffer(
              swarmId: swarmId,
              fromWorkerId: fromWorkerId,
              myDeviceId: myDeviceId,
              peerEndpoint: peerEndpoint,
              offerDocId: docId
            )
          }
        }
      }

      listeners[swarmId] = listener
    }

    logger.info("STUN signaling responder started for \(swarmIds.count) swarm(s)")
  }

  func stop() {
    for (_, listener) in listeners {
      listener.remove()
    }
    listeners.removeAll()
    respondedOffers.removeAll()
    isActive = false
    logger.info("STUN signaling responder stopped")
  }

  // MARK: - Offer Handling

  private func respondToOffer(
    swarmId: String,
    fromWorkerId: String,
    myDeviceId: String,
    peerEndpoint: STUNResult,
    offerDocId: String
  ) async {
    logger.info("[stun-responder] Offer received from \(fromWorkerId) at \(peerEndpoint)")

    let p2pLog = P2PConnectionLog.shared

    // 1. Discover our own STUN endpoint (binding to our listening port
    //    so the NAT mapping is for the same port the TCP listener uses)
    p2pLog.log("stun-responder", "STUN discovery starting", details: ["localPort": String(listeningPort)])
    guard let myEndpoint = await STUNClient.discoverEndpoint(localPort: listeningPort) else {
      p2pLog.log("stun-responder", "STUN discovery FAILED", details: ["localPort": String(listeningPort)])
      logger.error("[stun-responder] Failed to discover STUN endpoint for answer")
      return
    }

    p2pLog.log("stun-responder", "STUN discovery OK", details: [
      "externalAddress": myEndpoint.address,
      "externalPort": String(myEndpoint.port),
      "server": myEndpoint.serverUsed,
      "latencyMs": String(myEndpoint.latencyMs),
    ])
    logger.info("[stun-responder] Our endpoint: \(myEndpoint)")

    // 2. Write our answer to Firestore
    let db = Firestore.firestore()
    let answerDocId = "\(myDeviceId)_to_\(fromWorkerId)"
    let answerDocRef = db.collection("swarms/\(swarmId)/stunSignaling")
      .document(answerDocId)

    p2pLog.log("stun-responder", "Writing STUN answer to Firestore", details: [
      "answerDocId": answerDocId,
      "myDeviceId": myDeviceId,
      "targetWorkerId": fromWorkerId,
      "answerAddress": myEndpoint.address,
      "answerPort": String(myEndpoint.port),
    ])

    do {
      try await answerDocRef.setData([
        "fromWorkerId": myDeviceId,
        "toWorkerId": fromWorkerId,
        "stunAddress": myEndpoint.address,
        "stunPort": Int(myEndpoint.port),
        "createdAt": FieldValue.serverTimestamp(),
        "expiresAt": Timestamp(date: Date().addingTimeInterval(60)),
        "isAnswer": true,
      ])
      p2pLog.log("stun-responder", "STUN answer written OK")
    } catch {
      p2pLog.log("stun-responder", "STUN answer write FAILED", details: ["error": "\(error)"])
      logger.error("[stun-responder] Failed to write STUN answer: \(error)")
      return
    }

    // 3. Start UDP serve — the initiator will connect via UDP hole punch
    //    and request data after receiving our STUN answer.
    //    TCP simultaneous open was tried previously but doesn't work through
    //    consumer NATs — UDP hole punch succeeds because STUN creates the
    //    correct UDP NAT mappings directly.
    if let dataProvider {
      p2pLog.log("stun-responder", "Starting UDP serve for initiator", details: [
        "peerAddress": peerEndpoint.address,
        "peerPort": String(peerEndpoint.port),
        "localPort": String(listeningPort),
      ])
      Task {
        await UDPPeerTransfer.serveData(
          peerEndpoint: peerEndpoint,
          localPort: listeningPort,
          dataProvider: dataProvider
        )
      }
    } else {
      p2pLog.log("stun-responder", "No data provider — cannot serve UDP transfer")
      logger.warning("[stun-responder] No dataProvider set — UDP serve skipped")
    }

    // 4. Clean up signaling docs after 2 minutes
    Task {
      try? await Task.sleep(for: .seconds(120))
      let db = Firestore.firestore()
      try? await db.collection("swarms/\(swarmId)/stunSignaling")
        .document(offerDocId).delete()
      try? await answerDocRef.delete()
    }

    logger.info("[stun-responder] Answer sent to \(fromWorkerId), UDP serve initiated")
  }
}
