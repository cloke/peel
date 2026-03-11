//
//  OnDemandPeerTransfer.swift
//  Peel
//
//  Establishes temporary P2P connections for one-off data transfers.
//  Tries direct TCP first (LAN, then WAN), then falls back to
//  STUN/hole-punching. Tears down the connection after transfer.
//
//  This replaces the always-on STUN model with on-demand connections:
//  1. Look up peer address from Firestore worker document
//  2. Try LAN address → WAN address → STUN hole-punch
//  3. Run transfer (RAG sync, etc.)
//  4. Disconnect
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │  THIS IS THE CORRECT USE OF P2P — large binary file transfers.      │
// │  P2P with Firestore relay fallback is the right pattern here.       │
// │  Do NOT add coordination/status/task messages to this path.         │
// └─────────────────────────────────────────────────────────────────────┘
//

import Foundation
import Network
import os.log

// MARK: - Transfer State

/// Progress of an on-demand peer transfer.
@MainActor
@Observable
public final class OnDemandTransferState {
  public let id: UUID
  public let targetWorkerId: String
  public let targetWorkerName: String
  public let repoIdentifier: String
  public var status: TransferStatus = .connecting
  public var connectionMethod: ConnectionMethod?
  public var transferredBytes: Int = 0
  public var totalBytes: Int = 0
  public var chunksReceived: Int = 0
  public var totalChunks: Int = 0
  public var startedAt = Date()
  public var completedAt: Date?
  public var error: String?

  public enum TransferStatus: String, Sendable {
    case connecting
    case handshaking
    case transferring
    case importing
    case complete
    case failed
  }

  public enum ConnectionMethod: String, Sendable {
    case lan
    case wanDirect
    case stunHolePunch
    case firestoreRelay
  }

  /// The Firestore swarm ID (needed for STUN signaling and relay paths)
  public let swarmId: String

  init(id: UUID, targetWorkerId: String, targetWorkerName: String, repoIdentifier: String, swarmId: String) {
    self.id = id
    self.targetWorkerId = targetWorkerId
    self.targetWorkerName = targetWorkerName
    self.repoIdentifier = repoIdentifier
    self.swarmId = swarmId
  }

  public var progressFraction: Double {
    guard totalBytes > 0 else { return 0 }
    return Double(transferredBytes) / Double(totalBytes)
  }

  public var elapsedSeconds: TimeInterval {
    (completedAt ?? Date()).timeIntervalSince(startedAt)
  }
}

// MARK: - On-Demand Peer Transfer

/// Manages temporary P2P connections for one-off transfers.
/// Each transfer creates a fresh TCP connection, runs the handshake,
/// performs the data exchange, then tears down.
@MainActor
public final class OnDemandPeerTransfer {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "OnDemandTransfer")

  /// Active transfers for UI progress reporting
  @Observable
  public final class TransferTracker {
    public var activeTransfers: [UUID: OnDemandTransferState] = [:]
  }

  let tracker = TransferTracker()

  /// Timeout for each connection attempt (LAN, WAN, STUN)
  private let connectionTimeout: TimeInterval = 10
  private let transferReceiveTimeout: Duration = .seconds(30)
  /// Total transfer timeout — if the entire transfer hasn't completed after
  /// this many seconds, cancel it. Prevents indefinite hangs.
  private let totalTransferTimeout: Duration = .seconds(600)  // 10 minutes

  /// The local TCP listener port — must match PeerConnectionManager's port
  /// so that STUN discovers the NAT mapping for our actual listening port.
  /// Both sides (initiator + responder) must use the same port strategy
  /// for TCP simultaneous open to work through NATs.
  let listeningPort: UInt16

  init(listeningPort: UInt16 = 8766) {
    self.listeningPort = listeningPort
  }

  // MARK: - Public API

  /// Firestore relay consumer (shared across transfers)
  private let relayConsumer = FirestoreRelayConsumer()

  /// Connect to a peer, request a repo's RAG index, and import it.
  /// Tries direct connection first (LAN → WAN → STUN), then falls back
  /// to Firestore relay if all direct methods fail.
  /// Returns the transfer state when complete.
  func requestIndex(
    from worker: FirestoreWorker,
    repoIdentifier: String,
    swarmId: String,
    ragSyncDelegate: RAGArtifactSyncDelegate
  ) async throws -> OnDemandTransferState {
    let transferId = UUID()
    let state = OnDemandTransferState(
      id: transferId,
      targetWorkerId: worker.workerId,
      targetWorkerName: worker.displayName,
      repoIdentifier: repoIdentifier,
      swarmId: swarmId
    )
    tracker.activeTransfers[transferId] = state

    defer {
      if state.status != .complete {
        state.status = .failed
      }
      // Clean up after a delay so UI can show final state
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(30))
        self.tracker.activeTransfers.removeValue(forKey: transferId)
      }
    }

    // Try direct P2P connection (LAN → WAN → STUN)
    let p2pLog = P2PConnectionLog.shared
    p2pLog.log("transfer", "requestIndex started", details: [
      "targetWorker": worker.displayName,
      "targetWorkerId": worker.workerId,
      "repo": repoIdentifier,
      "swarmId": swarmId,
      "targetLAN": "\(worker.lanAddress ?? "nil"):\(worker.lanPort.map { String($0) } ?? "nil")",
      "targetWAN": "\(worker.wanAddress ?? "nil"):\(worker.wanPort.map { String($0) } ?? "nil")",
      "relayProviderActive": String(worker.relayProviderActive),
    ])
    if let connection = try? await connectToPeer(worker: worker, state: state) {
      // Direct path: handshake → transfer → disconnect
      try await directTransfer(
        connection: connection,
        worker: worker,
        transferId: transferId,
        repoIdentifier: repoIdentifier,
        ragSyncDelegate: ragSyncDelegate,
        state: state
      )
      return state
    }

    // All direct connections failed — fall back to Firestore relay
    p2pLog.log("transfer", "ALL direct connections failed, falling back to relay", details: [
      "targetWorker": worker.displayName,
      "relayProviderActive": String(worker.relayProviderActive),
    ])
    logger.info("[transfer] All direct connections failed to \(worker.displayName) (\(worker.workerId)), using Firestore relay")

    // Check if the target worker has an active relay provider — if not, fail fast
    // instead of waiting 300s for a response that will never come.
    if !worker.relayProviderActive {
      let msg = "All direct connections (LAN/WAN/STUN) failed and target worker '\(worker.displayName)' has no relay provider active. The worker may need to restart with the swarm enabled."
      state.error = msg
      logger.error("[transfer] \(msg)")
      throw OnDemandTransferError.remoteError(message: msg)
    }

    logger.info("[transfer] Relay context: swarmId=\(state.swarmId), repo=\(repoIdentifier)")
    state.connectionMethod = .firestoreRelay
    state.status = .connecting

    do {
      try await relayConsumer.requestIndex(
        from: worker,
        repoIdentifier: repoIdentifier,
        swarmId: swarmId,
        ragSyncDelegate: ragSyncDelegate,
        state: state
      )
    } catch {
      state.error = "Relay failed: \(error.localizedDescription)"
      logger.error("[transfer] Firestore relay failed from \(worker.displayName): \(error)")
      throw error
    }

    return state
  }

  /// Perform a direct transfer over an established NWConnection.
  private func directTransfer(
    connection: NWConnection,
    worker: FirestoreWorker,
    transferId: UUID,
    repoIdentifier: String,
    ragSyncDelegate: RAGArtifactSyncDelegate,
    state: OnDemandTransferState
  ) async throws {
    // Handshake
    state.status = .handshaking
    let peerConn = PeerConnectionActor(connection: connection, peerId: worker.workerId)
    do {
      try await performHandshake(peerConn: peerConn)
    } catch {
      await peerConn.close()
      state.error = "Handshake failed: \(error.localizedDescription)"
      logger.error("Handshake failed with \(worker.displayName): \(error)")
      throw error
    }

    // Request the RAG repo data
    state.status = .transferring
    do {
      try await peerConn.send(
        .ragArtifactsRequest(id: transferId, direction: .pull, repoIdentifier: repoIdentifier)
      )

      // Receive with a total transfer timeout to prevent indefinite hangs
      let totalTimeout = totalTransferTimeout
      let bundleData = try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
          try await self.receiveTransfer(peerConn: peerConn, transferId: transferId, state: state)
        }
        group.addTask {
          try await Task.sleep(for: totalTimeout)
          throw OnDemandTransferError.transferTimedOut(seconds: Int(totalTimeout.components.seconds))
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
          throw OnDemandTransferError.transferTimedOut(seconds: Int(totalTimeout.components.seconds))
        }
        return result
      }

      // Import
      state.status = .importing
      try await importRepoBundle(data: bundleData, ragSyncDelegate: ragSyncDelegate)

      state.status = .complete
      state.completedAt = Date()
      logger.info("Transfer complete: \(repoIdentifier) from \(worker.displayName) (\(state.transferredBytes) bytes in \(String(format: "%.1f", state.elapsedSeconds))s)")

    } catch {
      state.error = "Transfer failed: \(error.localizedDescription)"
      logger.error("Transfer failed from \(worker.displayName): \(error)")
      throw error
    }

    // Disconnect
    try? await peerConn.send(.goodbye)
    await peerConn.close()
  }

  // MARK: - Connection Strategy

  /// Try LAN → WAN direct → STUN, returning the first working connection.
  /// Returns nil if all methods fail (caller should fall back to relay).
  private func connectToPeer(
    worker: FirestoreWorker,
    state: OnDemandTransferState
  ) async throws -> NWConnection? {
    let p2pLog = P2PConnectionLog.shared

    // Attempt 1: LAN (fastest, most reliable)
    if let lanAddress = worker.lanAddress, let lanPort = worker.lanPort {
      p2pLog.log("transfer", "LAN attempt start", details: ["address": "\(lanAddress):\(lanPort)"])
      logger.info("Trying LAN connection to \(worker.displayName) at \(lanAddress):\(lanPort)")
      if let conn = try? await attemptTCPConnection(host: lanAddress, port: UInt16(lanPort)) {
        state.connectionMethod = .lan
        p2pLog.log("transfer", "LAN CONNECTED", details: ["address": "\(lanAddress):\(lanPort)"])
        logger.info("Connected via LAN to \(worker.displayName)")
        return conn
      }
      p2pLog.log("transfer", "LAN failed", details: ["address": "\(lanAddress):\(lanPort)"])
      logger.info("LAN connection failed, trying WAN")
    } else {
      p2pLog.log("transfer", "LAN skipped (no address)", details: [
        "lanAddress": worker.lanAddress ?? "nil",
        "lanPort": worker.lanPort.map { String($0) } ?? "nil",
      ])
    }

    // Attempt 2: Direct WAN TCP (works with port forwarding / UPnP)
    if let wanAddress = worker.wanAddress, let wanPort = worker.wanPort {
      p2pLog.log("transfer", "WAN direct attempt start", details: ["address": "\(wanAddress):\(wanPort)"])
      logger.info("Trying WAN direct to \(worker.displayName) at \(wanAddress):\(wanPort)")
      if let conn = try? await attemptTCPConnection(host: wanAddress, port: UInt16(wanPort)) {
        state.connectionMethod = .wanDirect
        p2pLog.log("transfer", "WAN direct CONNECTED", details: ["address": "\(wanAddress):\(wanPort)"])
        logger.info("Connected via WAN direct to \(worker.displayName)")
        return conn
      }
      p2pLog.log("transfer", "WAN direct failed", details: ["address": "\(wanAddress):\(wanPort)"])
      logger.info("WAN direct failed, trying STUN")
    } else {
      p2pLog.log("transfer", "WAN direct skipped (no address)", details: [
        "wanAddress": worker.wanAddress ?? "nil",
        "wanPort": worker.wanPort.map { String($0) } ?? "nil",
      ])
    }

    // Attempt 3: STUN + hole punch
    p2pLog.log("stun-initiator", "STUN attempt start", details: ["targetWorker": worker.displayName, "targetWorkerId": worker.workerId])
    logger.info("Trying STUN hole-punch to \(worker.displayName)")
    do {
      let conn = try await attemptSTUNConnection(worker: worker, swarmId: state.swarmId)
      state.connectionMethod = .stunHolePunch
      p2pLog.log("stun-initiator", "STUN hole-punch CONNECTED", details: ["targetWorker": worker.displayName])
      logger.info("Connected via STUN hole-punch to \(worker.displayName)")
      return conn
    } catch {
      p2pLog.log("stun-initiator", "STUN hole-punch FAILED", details: [
        "error": "\(error)",
        "targetWorker": worker.displayName,
      ])
    }

    // All direct methods failed — return nil to trigger relay fallback
    logger.info("All direct connection methods failed to \(worker.displayName)")
    return nil
  }

  /// Open a TCP connection with a timeout.
  private func attemptTCPConnection(host: String, port: UInt16) async throws -> NWConnection {
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!
    )
    let params = NWParameters.tcp
    params.includePeerToPeer = true
    let connection = NWConnection(to: endpoint, using: params)

    return try await withCheckedThrowingContinuation { continuation in
      let box = ContinuationBox()

      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if box.tryResume() {
            connection.stateUpdateHandler = nil
            continuation.resume(returning: connection)
          }
        case .failed(let error):
          if box.tryResume() {
            connection.stateUpdateHandler = nil
            continuation.resume(throwing: error)
          }
        case .cancelled:
          if box.tryResume() {
            connection.stateUpdateHandler = nil
            continuation.resume(throwing: OnDemandTransferError.connectionCancelled)
          }
        default:
          break
        }
      }

      connection.start(queue: .main)

      // Timeout
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(self.connectionTimeout))
        if box.tryResume() {
          connection.cancel()
          continuation.resume(throwing: OnDemandTransferError.connectionTimeout(host: host, port: port))
        }
      }
    }
  }

  /// Perform STUN discovery and TCP simultaneous open via Firestore signaling.
  ///
  /// **Architecture (why this works):**
  /// Both sides (initiator here + STUNSignalingResponder) use the same local
  /// port (the PeerConnectionManager listener port, typically 8766) for:
  ///   1. STUN discovery — so the NAT mapping is for our real listening port
  ///   2. TCP simultaneous open — both sides connect() at roughly the same time
  ///
  /// On endpoint-independent mapping NATs (most home routers), the external
  /// port stays the same regardless of destination, so STUN-discovered ports
  /// correctly predict where TCP SYNs will appear.
  ///
  /// On symmetric NATs (carrier-grade NAT), each destination gets a different
  /// external port — STUN discovery is useless and this will fail. Those
  /// require a TURN relay (future work).
  ///
  /// **Why TCP, not UDP+TCP:**
  /// UDP and TCP NAT mappings are independent on most routers. Sending UDP
  /// probes does NOT open a path for TCP connections. We do TCP-only.
  private func attemptSTUNConnection(
    worker: FirestoreWorker,
    swarmId: String
  ) async throws -> NWConnection {
    let localPort = listeningPort
    let p2pLog = P2PConnectionLog.shared
    p2pLog.log("stun-initiator", "STUN discovery starting", details: ["localPort": String(localPort)])
    logger.info("[stun-initiator] Using local port \(localPort) (matches TCP listener)")

    // 1. Run STUN to discover our public endpoint bound to our listener port.
    //    This tells us what external IP:port the NAT assigned for port 8766.
    guard let myEndpoint = await STUNClient.discoverEndpoint(localPort: localPort) else {
      p2pLog.log("stun-initiator", "STUN discovery FAILED — all servers unreachable", details: ["localPort": String(localPort)])
      throw OnDemandTransferError.stunDiscoveryFailed
    }
    p2pLog.log("stun-initiator", "STUN discovery OK", details: [
      "externalAddress": myEndpoint.address,
      "externalPort": String(myEndpoint.port),
      "server": myEndpoint.serverUsed,
      "latencyMs": String(myEndpoint.latencyMs),
    ])
    logger.info("[stun-initiator] Our external endpoint: \(myEndpoint)")

    // 2. Write our STUN offer to Firestore for the target peer
    let myDeviceId = WorkerCapabilities.current().deviceId
    p2pLog.log("stun-initiator", "Writing STUN offer to Firestore", details: [
      "myDeviceId": myDeviceId,
      "targetWorkerId": worker.workerId,
      "docId": "\(myDeviceId)_to_\(worker.workerId)",
      "swarmId": swarmId,
      "offerAddress": myEndpoint.address,
      "offerPort": String(myEndpoint.port),
    ])
    try await writeSTUNOffer(
      swarmId: swarmId,
      targetWorkerId: worker.workerId,
      myDeviceId: myDeviceId,
      endpoint: myEndpoint
    )
    p2pLog.log("stun-initiator", "STUN offer written, waiting for answer", details: [
      "answerDocId": "\(worker.workerId)_to_\(myDeviceId)",
      "timeout": "30s",
    ])

    // 3. Wait for the peer's STUN answer (they do the same STUN + write)
    let peerEndpoint: STUNResult
    do {
      peerEndpoint = try await waitForSTUNAnswer(
        swarmId: swarmId,
        myDeviceId: myDeviceId,
        fromWorkerId: worker.workerId,
        timeout: 30
      )
    } catch {
      p2pLog.log("stun-initiator", "STUN answer wait FAILED", details: ["error": "\(error)"])
      throw error
    }
    p2pLog.log("stun-initiator", "STUN answer received", details: [
      "peerAddress": peerEndpoint.address,
      "peerPort": String(peerEndpoint.port),
    ])
    logger.info("[stun-initiator] Peer endpoint: \(peerEndpoint)")

    // 4. TCP simultaneous open — connect to peer's STUN endpoint
    //    from our listener port with SO_REUSEADDR. The responder is
    //    doing the same thing to our endpoint at roughly the same time.
    //    When both SYNs cross in the network, both NATs create mappings
    //    and the connection establishes.
    let peerHost = NWEndpoint.Host(peerEndpoint.address)
    let peerPort = NWEndpoint.Port(rawValue: peerEndpoint.port)!
    let endpoint = NWEndpoint.hostPort(host: peerHost, port: peerPort)

    let params = NWParameters.tcp
    params.includePeerToPeer = true
    params.allowLocalEndpointReuse = true  // Critical for TCP simultaneous open
    if let nwPort = NWEndpoint.Port(rawValue: localPort) {
      params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: nwPort)
    }
    let connection = NWConnection(to: endpoint, using: params)

    p2pLog.log("stun-initiator", "TCP simultaneous open starting", details: [
      "targetAddress": peerEndpoint.address,
      "targetPort": String(peerEndpoint.port),
      "localPort": String(localPort),
    ])
    logger.info("[stun-initiator] Starting TCP simultaneous open to \(peerEndpoint)")

    return try await withCheckedThrowingContinuation { continuation in
      let box = ContinuationBox()

      connection.stateUpdateHandler = { [self] state in
        switch state {
        case .ready:
          if box.tryResume() {
            connection.stateUpdateHandler = nil
            Task { @MainActor in
              P2PConnectionLog.shared.log("stun-initiator", "TCP simultaneous open SUCCEEDED", details: [
                "peerAddress": peerEndpoint.address,
                "peerPort": String(peerEndpoint.port),
              ])
            }
            logger.info("[stun-initiator] TCP simultaneous open SUCCEEDED to \(peerEndpoint)")
            continuation.resume(returning: connection)
          }
        case .failed(let error):
          if box.tryResume() {
            connection.stateUpdateHandler = nil
            Task { @MainActor in
              P2PConnectionLog.shared.log("stun-initiator", "TCP simultaneous open FAILED", details: ["error": "\(error)"])
            }
            logger.error("[stun-initiator] TCP simultaneous open FAILED: \(error)")
            continuation.resume(throwing: error)
          }
        case .waiting(let error):
          Task { @MainActor in
            P2PConnectionLog.shared.log("stun-initiator", "TCP waiting", details: ["error": "\(error)"])
          }
          logger.info("[stun-initiator] TCP waiting: \(error)")
        default:
          break
        }
      }

      connection.start(queue: .main)

      Task { @MainActor in
        try? await Task.sleep(for: .seconds(20))
        if box.tryResume() {
          connection.cancel()
          p2pLog.log("stun-initiator", "TCP simultaneous open TIMED OUT (20s)")
          logger.error("[stun-initiator] TCP simultaneous open timed out after 20s")
          continuation.resume(throwing: OnDemandTransferError.stunHolePunchFailed)
        }
      }
    }
  }

  // MARK: - Handshake

  private func performHandshake(peerConn: PeerConnectionActor) async throws {
    let caps = WorkerCapabilities.current()
    try await peerConn.send(.hello(capabilities: caps))

    let response = try await receiveMessage(
      from: peerConn,
      timeout: transferReceiveTimeout,
      timeoutError: .handshakeFailed(reason: "Timed out waiting for helloAck")
    )
    guard case .helloAck = response else {
      throw OnDemandTransferError.handshakeFailed(reason: "Expected helloAck, got \(response.messageType)")
    }
  }

  // MARK: - Data Transfer

  /// Receive chunked RAG data from peer and reassemble.
  private func receiveTransfer(
    peerConn: PeerConnectionActor,
    transferId: UUID,
    state: OnDemandTransferState
  ) async throws -> Data {
    var chunks: [Int: Data] = [:]
    var totalChunks = 0
    var receivedManifest = false

    while true {
      let message = try await receiveMessage(
        from: peerConn,
        timeout: transferReceiveTimeout,
        timeoutError: .transferTimedOut(seconds: 30)
      )

      switch message {
      case .ragArtifactsManifest(let id, let manifest) where id == transferId:
        receivedManifest = true
        state.totalBytes = manifest.totalBytes
        logger.info("Received manifest: \(manifest.totalBytes) bytes")

      case .ragArtifactsChunk(let id, let index, let total, let data) where id == transferId:
        guard let chunkData = Data(base64Encoded: data) else {
          throw OnDemandTransferError.invalidChunkData(index: index)
        }
        chunks[index] = chunkData
        totalChunks = total
        state.chunksReceived = chunks.count
        state.totalChunks = total
        state.transferredBytes += chunkData.count

      case .ragArtifactsComplete(let id) where id == transferId:
        // Reassemble
        guard receivedManifest else {
          throw OnDemandTransferError.missingManifest
        }
        var assembled = Data()
        for i in 0..<totalChunks {
          guard let chunk = chunks[i] else {
            throw OnDemandTransferError.missingChunk(index: i, total: totalChunks)
          }
          assembled.append(chunk)
        }
        return assembled

      case .ragArtifactsError(let id, let message) where id == transferId:
        throw OnDemandTransferError.remoteError(message: message)

      case .ragRepoManifest(let id, _):
        // Delta sync path: peer sends manifest first, we respond with what we need
        if id == transferId {
          // We want everything — send empty exclude list
          try await peerConn.send(.ragRepoDeltaRequest(id: id, excludeFileHashes: []))
          state.totalBytes = 0  // will be updated by chunk messages
        }

      default:
        logger.debug("Ignoring unexpected message during transfer: \(message.messageType)")
      }
    }
  }

  private func receiveMessage(
    from peerConn: PeerConnectionActor,
    timeout: Duration,
    timeoutError: OnDemandTransferError
  ) async throws -> PeerMessage {
    try await withThrowingTaskGroup(of: PeerMessage.self) { group in
      group.addTask {
        try await peerConn.receiveMessage()
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw timeoutError
      }

      defer { group.cancelAll() }
      guard let message = try await group.next() else {
        throw timeoutError
      }
      return message
    }
  }

  /// Import a received repo bundle into the local RAG store.
  private func importRepoBundle(data: Data, ragSyncDelegate: RAGArtifactSyncDelegate) async throws {
    let bundle = try JSONDecoder().decode(RAGRepoExportBundle.self, from: data)
    _ = try await ragSyncDelegate.applyRepoSyncBundle(bundle, localRepoPath: nil, forceImportEmbeddings: true)
  }

  // MARK: - STUN Signaling (via Firestore)

  private func writeSTUNOffer(
    swarmId: String,
    targetWorkerId: String,
    myDeviceId: String,
    endpoint: STUNResult
  ) async throws {
    let db = Firestore.firestore()
    let collection = db.collection("swarms/\(swarmId)/stunSignaling")
    let answerDocRef = collection.document("\(targetWorkerId)_to_\(myDeviceId)")

    // Delete stale answer doc from previous attempts so we can watch for a fresh one
    try? await answerDocRef.delete()

    // Use a unique offer doc ID per attempt so the responder's respondedOffers
    // deduplication set doesn't block re-processing of retried signaling.
    let uniqueOfferDocId = "\(myDeviceId)_to_\(targetWorkerId)_\(Int(Date().timeIntervalSince1970))"
    let offerDocRef = collection.document(uniqueOfferDocId)

    try await offerDocRef.setData([
      "fromWorkerId": myDeviceId,
      "toWorkerId": targetWorkerId,
      "stunAddress": endpoint.address,
      "stunPort": Int(endpoint.port),
      "createdAt": FieldValue.serverTimestamp(),
      "expiresAt": Timestamp(date: Date().addingTimeInterval(60)),
    ])
  }

  /// Wait for the responder's STUN answer using a Firestore snapshot listener.
  /// This is faster than polling (reacts within ~100ms vs up to 1s polling jitter),
  /// which tightens the TCP simultaneous open timing window.
  private func waitForSTUNAnswer(
    swarmId: String,
    myDeviceId: String,
    fromWorkerId: String,
    timeout: TimeInterval
  ) async throws -> STUNResult {
    let db = Firestore.firestore()
    let docRef = db.collection("swarms/\(swarmId)/stunSignaling")
      .document("\(fromWorkerId)_to_\(myDeviceId)")

    // Use an actor to safely coordinate between the snapshot listener callback
    // and the timeout task (NSLock is unavailable in async contexts in Swift 6).
    actor SignalingState {
      var resumed = false
      func tryResume() -> Bool {
        guard !resumed else { return false }
        resumed = true
        return true
      }
    }

    let state = SignalingState()

    return try await withCheckedThrowingContinuation { continuation in
      var listener: ListenerRegistration?

      let p2pLog = P2PConnectionLog.shared
      let answerDocPath = "\(fromWorkerId)_to_\(myDeviceId)"
      p2pLog.log("stun-initiator", "Snapshot listener attached for answer", details: [
        "docPath": "swarms/\(swarmId)/stunSignaling/\(answerDocPath)",
        "timeout": "\(timeout)s",
      ])

      // Timeout task
      let timeoutTask = Task {
        try await Task.sleep(for: .seconds(timeout))
        guard await state.tryResume() else { return }
        listener?.remove()
        p2pLog.log("stun-initiator", "STUN answer TIMED OUT", details: ["timeout": "\(timeout)s"])
        continuation.resume(throwing: OnDemandTransferError.stunSignalingTimeout)
      }

      listener = docRef.addSnapshotListener { snapshot, error in
        if let error {
          P2PConnectionLog.shared.log("stun-initiator", "Snapshot listener error", details: ["error": "\(error)"])
        }
        guard let data = snapshot?.data(),
          let address = data["stunAddress"] as? String,
          let port = data["stunPort"] as? Int
        else {
          let exists = snapshot?.exists ?? false
          let hasData = snapshot?.data() != nil
          P2PConnectionLog.shared.log("stun-initiator", "Snapshot event (no valid answer yet)", details: [
            "docExists": String(exists),
            "hasData": String(hasData),
          ])
          return
        }

        Task {
          guard await state.tryResume() else { return }
          timeoutTask.cancel()
          listener?.remove()

          P2PConnectionLog.shared.log("stun-initiator", "STUN answer received from snapshot", details: [
            "peerAddress": address,
            "peerPort": String(port),
          ])

          // Clean up the answer doc
          try? await docRef.delete()

          continuation.resume(returning: STUNResult(
            address: address,
            port: UInt16(port),
            serverUsed: "signaling",
            latencyMs: 0
          ))
        }
      }
    }
  }

}

// MARK: - Firestore Worker (extended)

// The FirestoreWorker type is defined in FirebaseServiceTypes.swift.
// We just need lanAddress, wanAddress, stunAddress fields which already exist.

import FirebaseFirestore

// MARK: - Errors

public enum OnDemandTransferError: LocalizedError, Sendable {
  case allConnectionMethodsFailed(worker: String)
  case connectionTimeout(host: String, port: UInt16)
  case connectionCancelled
  case stunDiscoveryFailed
  case stunSignalingTimeout
  case stunHolePunchFailed
  case handshakeFailed(reason: String)
  case transferTimedOut(seconds: Int)
  case invalidChunkData(index: Int)
  case missingManifest
  case missingChunk(index: Int, total: Int)
  case remoteError(message: String)

  public var errorDescription: String? {
    switch self {
    case .allConnectionMethodsFailed(let worker):
      return "Could not connect to \(worker) via LAN, WAN, or STUN"
    case .connectionTimeout(let host, let port):
      return "Connection timed out to \(host):\(port)"
    case .connectionCancelled:
      return "Connection was cancelled"
    case .stunDiscoveryFailed:
      return "STUN endpoint discovery failed"
    case .stunSignalingTimeout:
      return "Timed out waiting for peer's STUN endpoint"
    case .stunHolePunchFailed:
      return "UDP hole-punching failed — peer may be behind symmetric NAT"
    case .handshakeFailed(let reason):
      return "Handshake failed: \(reason)"
    case .transferTimedOut(let seconds):
      return "Timed out waiting for transfer data after \(seconds) seconds"
    case .invalidChunkData(let index):
      return "Invalid base64 data in chunk \(index)"
    case .missingManifest:
      return "Transfer completed without receiving manifest"
    case .missingChunk(let index, let total):
      return "Missing chunk \(index) of \(total)"
    case .remoteError(let message):
      return "Remote peer error: \(message)"
    }
  }
}
