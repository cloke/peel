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
import Network
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

        for change in snapshot.documentChanges where change.type == .added {
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
            // Deduplicate
            guard !self.respondedOffers.contains(docId) else { return }
            self.respondedOffers.insert(docId)

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

    // 1. Discover our own STUN endpoint (binding to our listening port
    //    so the NAT mapping is for the same port the TCP listener uses)
    guard let myEndpoint = await STUNClient.discoverEndpoint(localPort: listeningPort) else {
      logger.error("[stun-responder] Failed to discover STUN endpoint for answer")
      return
    }

    logger.info("[stun-responder] Our endpoint: \(myEndpoint)")

    // 2. Write our answer to Firestore
    let db = Firestore.firestore()
    let answerDocRef = db.collection("swarms/\(swarmId)/stunSignaling")
      .document("\(myDeviceId)_to_\(fromWorkerId)")

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
    } catch {
      logger.error("[stun-responder] Failed to write STUN answer: \(error)")
      return
    }

    // 3. TCP simultaneous open — connect to the peer's STUN endpoint
    //    from our listener port. The initiator is doing the same thing
    //    at roughly the same time. When both SYNs cross, the connection
    //    establishes through both NATs.
    //
    //    No UDP probes — UDP and TCP NAT mappings are independent on
    //    most routers, so UDP probes don't help TCP connections.
    Task {
      _ = try? await attemptTCPConnect(to: peerEndpoint)
    }

    // 4. Clean up signaling docs after 2 minutes
    Task {
      try? await Task.sleep(for: .seconds(120))
      let db = Firestore.firestore()
      try? await db.collection("swarms/\(swarmId)/stunSignaling")
        .document(offerDocId).delete()
      try? await answerDocRef.delete()
    }

    logger.info("[stun-responder] Answer sent to \(fromWorkerId), TCP simultaneous open initiated")
  }

  // MARK: - TCP Simultaneous Open

  /// Attempt a TCP connection to the peer's STUN endpoint (simultaneous open).
  /// Binds to our listener port with SO_REUSEADDR so the NAT mapping matches
  /// what STUN discovered. The initiator does the same thing at the same time.
  private func attemptTCPConnect(to endpoint: STUNResult) async throws -> NWConnection? {
    let host = NWEndpoint.Host(endpoint.address)
    guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return nil }
    let nwEndpoint = NWEndpoint.hostPort(host: host, port: port)

    let params = NWParameters.tcp
    params.includePeerToPeer = true
    params.allowLocalEndpointReuse = true  // Critical for TCP simultaneous open
    // Bind to our listening port for simultaneous TCP open
    if let nwPort = NWEndpoint.Port(rawValue: listeningPort) {
      params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: nwPort)
    }

    let connection = NWConnection(to: nwEndpoint, using: params)
    logger.info("[stun-responder] Starting TCP simultaneous open to \(endpoint)")

    return try await withCheckedThrowingContinuation { continuation in
      let box = ContinuationBox()

      connection.stateUpdateHandler = { [self] state in
        switch state {
        case .ready:
          if box.tryResume() {
            connection.stateUpdateHandler = nil
            logger.info("[stun-responder] TCP simultaneous open SUCCEEDED to \(endpoint)")
            continuation.resume(returning: connection)
          }
        case .failed(let error):
          if box.tryResume() {
            connection.stateUpdateHandler = nil
            logger.info("[stun-responder] TCP simultaneous open failed: \(error)")
            continuation.resume(throwing: error)
          }
        case .waiting(let error):
          logger.info("[stun-responder] TCP waiting: \(error)")
        case .cancelled:
          if box.tryResume() {
            connection.stateUpdateHandler = nil
            continuation.resume(returning: nil)
          }
        default:
          break
        }
      }

      connection.start(queue: .main)

      // Timeout after 20 seconds (matches initiator)
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(20))
        if box.tryResume() {
          connection.cancel()
          logger.info("[stun-responder] TCP simultaneous open timed out")
          continuation.resume(returning: nil)
        }
      }
    }
  }
}
