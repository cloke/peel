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
//  2. Try LAN address → WAN address → STUN + UDP hole-punch
//  3. Run transfer (RAG sync, etc.)
//  4. Disconnect
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │  P2P ONLY — NO FIRESTORE DATA RELAY                                 │
// │                                                                     │
// │  Transfer pipeline: TCP LAN → TCP WAN → WebRTC data channel → FAIL  │
// │  If all P2P methods fail, the transfer FAILS with an error.         │
// │  Do NOT add FirestoreRelayTransfer as a fallback here.              │
// │  Firestore is for signaling/coordination only, never bulk data.     │
// │  Do NOT add coordination/status/task messages to this path.         │
// └─────────────────────────────────────────────────────────────────────┘
//

import Foundation
import Network
import os.log
import WebRTCTransfer

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
    case udpHolePunch
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

  /// Reference to the WebRTC signaling responder for status tracking.
  weak var webrtcResponder: WebRTCSignalingResponder?

  // MARK: - Public API

  /// Connect to a peer, request a repo's RAG index, and import it.
  /// Tries direct TCP first (LAN → WAN), then WebRTC data channel,
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
    let transferTimer = MainThreadBlockTimer(label: "OnDemandPeerTransfer.requestIndex(\(worker.displayName))", logger: logger)
    defer { transferTimer.finish() }
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

    // LAN/WAN direct failed — try WebRTC data channel transfer.
    // WebRTC handles ICE (STUN/TURN), NAT traversal, and reliable SCTP delivery.
    do {
      let bundleData = try await attemptWebRTCTransfer(
        worker: worker,
        repoIdentifier: repoIdentifier,
        state: state
      )
      state.connectionMethod = .udpHolePunch
      state.status = .importing
      try await importRepoBundle(data: bundleData, ragSyncDelegate: ragSyncDelegate)
      state.status = .complete
      state.completedAt = Date()
      p2pLog.log("transfer", "WebRTC transfer complete", details: [
        "bytes": String(bundleData.count),
        "repo": repoIdentifier,
        "elapsed": String(format: "%.1f", state.elapsedSeconds),
      ])
      logger.info("[transfer] WebRTC transfer complete: \(repoIdentifier) from \(worker.displayName) (\(bundleData.count) bytes in \(String(format: "%.1f", state.elapsedSeconds))s)")
      return state
    } catch {
      p2pLog.log("transfer", "WebRTC transfer failed", details: [
        "error": "\(error)",
        "targetWorker": worker.displayName,
      ])
      logger.info("[transfer] WebRTC failed to \(worker.displayName): \(error)")
    }

    // All direct P2P connections exhausted
    let msg = "All direct connections (LAN/WAN/WebRTC) failed to '\(worker.displayName)'."
    p2pLog.log("transfer", "ALL connections failed", details: [
      "targetWorker": worker.displayName,
    ])
    state.error = msg
    logger.error("[transfer] \(msg)")
    throw OnDemandTransferError.remoteError(message: msg)
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
      logger.info("WAN direct failed")
    } else {
      p2pLog.log("transfer", "WAN direct skipped (no address)", details: [
        "wanAddress": worker.wanAddress ?? "nil",
        "wanPort": worker.wanPort.map { String($0) } ?? "nil",
      ])
    }

    // All direct TCP methods failed — return nil to trigger STUN+UDP / relay fallback
    logger.info("All direct TCP methods failed to \(worker.displayName)")
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

      connection.start(queue: DispatchQueue(label: "com.peel.transfer.connection", qos: .userInitiated))

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

  /// Perform a WebRTC data channel transfer.
  ///
  /// WebRTC handles all NAT traversal (ICE/STUN) and reliable data delivery
  /// (SCTP data channels) automatically. No manual hole-punching, keepalives,
  /// or ACK management needed.
  private func attemptWebRTCTransfer(
    worker: FirestoreWorker,
    repoIdentifier: String,
    state: OnDemandTransferState
  ) async throws -> Data {
    let p2pLog = P2PConnectionLog.shared
    let myDeviceId = WorkerCapabilities.current().deviceId

    p2pLog.log("webrtc", "Starting WebRTC transfer", details: [
      "targetWorker": worker.displayName,
      "targetWorkerId": worker.workerId,
      "repo": repoIdentifier,
    ])

    // Create Firestore signaling channel
    let signaling = FirestoreWebRTCSignaling(
      swarmId: state.swarmId,
      myDeviceId: myDeviceId,
      remoteDeviceId: worker.workerId
    )

    // WebRTC transfer with safety timeout
    state.status = .transferring
    return try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask {
        try await WebRTCPeerTransfer.requestData(
          signaling: signaling,
          repoIdentifier: repoIdentifier,
          timeout: .seconds(300)
        ) { bytesReceived, totalBytes in
          Task { @MainActor in
            state.transferredBytes = bytesReceived
            state.totalBytes = totalBytes
          }
        }
      }
      group.addTask {
        try await Task.sleep(for: .seconds(330))
        throw OnDemandTransferError.transferTimedOut(seconds: 330)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw OnDemandTransferError.transferTimedOut(seconds: 330)
      }
      return result
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
    let start = ContinuousClock.now
    logger.notice("[import] decoding \(data.count) bytes...")
    // Decode off main actor to avoid blocking UI
    let bundle = try await Task.detached(priority: .userInitiated) {
      try JSONDecoder().decode(RAGRepoExportBundle.self, from: data)
    }.value
    logger.notice("[import] decode complete: \(ContinuousClock.now - start)")
    let applyStart = ContinuousClock.now
    logger.notice("[import] applying bundle (will hop to MainActor)...")
    _ = try await ragSyncDelegate.applyRepoSyncBundle(bundle, localRepoPath: nil, forceImportEmbeddings: true)
    logger.notice("[import] apply complete: \(ContinuousClock.now - applyStart), total import: \(ContinuousClock.now - start)")
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
  case webrtcFailed(reason: String)
  case handshakeFailed(reason: String)
  case transferTimedOut(seconds: Int)
  case invalidChunkData(index: Int)
  case missingManifest
  case missingChunk(index: Int, total: Int)
  case remoteError(message: String)

  public var errorDescription: String? {
    switch self {
    case .allConnectionMethodsFailed(let worker):
      return "Could not connect to \(worker) via LAN, WAN, or WebRTC"
    case .connectionTimeout(let host, let port):
      return "Connection timed out to \(host):\(port)"
    case .connectionCancelled:
      return "Connection was cancelled"
    case .webrtcFailed(let reason):
      return "WebRTC transfer failed: \(reason)"
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
