//
//  PeerSessionManager.swift
//  Peel
//
//  Manages all persistent WebRTC peer sessions.
//  Provides observable state for UI (connection status, peer list, RTT).
//
//  Part of the WebRTC-first networking replan (Plans/NETWORKING_REPLAN.md).
//

import Foundation
import os.log
import WebRTCTransfer

/// Manages all WebRTC peer sessions and provides observable state for UI.
@MainActor
@Observable
public final class PeerSessionManager {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "PeerSessionManager")

  /// Active sessions keyed by peer ID.
  private(set) var sessions: [String: PeerSession] = [:]

  /// Observable state mirror of each peer's connection state.
  private(set) var peerStates: [String: PeerSessionState] = [:]

  /// When each session entered .connecting state (for timeout decisions).
  private var connectStartedAt: [String: Date] = [:]

  /// Last known RTT for each peer (ms).
  private(set) var peerRTT: [String: Double] = [:]

  /// Called when a peer transitions to a non-connected state after being connected.
  var onPeerDisconnected: (@MainActor (String) -> Void)?

  /// Peers with an active WebRTC connection.
  var connectedPeers: [String] {
    peerStates.filter { $0.value == .connected }.map(\.key)
  }

  /// Whether any peer is currently connected.
  var hasConnectedPeers: Bool {
    peerStates.values.contains(.connected)
  }

  // MARK: - Connect

  /// Establish a persistent WebRTC session with a peer as the initiator.
  func connectToPeer(
    _ peerId: String,
    signaling: WebRTCSignalingChannel
  ) async throws {
    if let existing = sessions[peerId] {
      let existingState = await existing.state
      if existingState == .connected {
        let hasMCP = await existing.mcpChannel != nil
        let hasTransfer = await existing.transferChannel != nil
        if hasMCP && hasTransfer {
          logger.info("Already connected to \(peerId, privacy: .public)")
          return
        }
        logger.warning("Session for \(peerId, privacy: .public) is connected but missing channels (mcp: \(hasMCP), transfer: \(hasTransfer)) — resetting")
      } else if existingState == .connecting || existingState == .reconnecting {
        // If the session has been connecting for less than 60 seconds, it's likely
        // still doing SDP/ICE negotiation. Don't clobber it — just return and let
        // the existing attempt finish. WebRTC negotiation over Firestore signaling
        // can easily take 10-30+ seconds (offer → Firestore → remote → answer → ICE).
        let connectAge = Date().timeIntervalSince(connectStartedAt[peerId] ?? .distantPast)
        if connectAge < 60 {
          logger.info("Session for \(peerId, privacy: .public) still connecting (\(Int(connectAge))s old) — not clobbering")
          return
        }
        logger.warning("Session for \(peerId, privacy: .public) stuck in \(existingState.rawValue, privacy: .public) for \(Int(connectAge))s — resetting")
      }
      await existing.disconnect()
      sessions.removeValue(forKey: peerId)
      peerStates.removeValue(forKey: peerId)
      peerRTT.removeValue(forKey: peerId)
      connectStartedAt.removeValue(forKey: peerId)
    }

    let session = PeerSession(peerId: peerId)
    sessions[peerId] = session
    peerStates[peerId] = .connecting
    connectStartedAt[peerId] = Date()

    await session.setStateChangeHandler { [weak self] newState in
      Task { @MainActor [weak self] in
        let previous = self?.peerStates[peerId]
        self?.peerStates[peerId] = newState
        if previous == .connected, newState == .failed || newState == .disconnected {
          self?.onPeerDisconnected?(peerId)
        }
      }
    }

    do {
      try await session.connect(signaling: signaling)
      peerStates[peerId] = .connected
      connectStartedAt.removeValue(forKey: peerId)
      logger.notice("Session established with \(peerId, privacy: .public)")
    } catch {
      peerStates[peerId] = .failed
      connectStartedAt.removeValue(forKey: peerId)
      logger.error("Failed to connect to \(peerId, privacy: .public): \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  /// Accept an incoming WebRTC session from a peer (responder side).
  func acceptFromPeer(
    _ peerId: String,
    signaling: WebRTCSignalingChannel
  ) async throws {
    if let existing = sessions[peerId] {
      logger.warning("Replacing existing session for \(peerId, privacy: .public) during accept()")
      await existing.disconnect()
      sessions.removeValue(forKey: peerId)
      peerStates.removeValue(forKey: peerId)
      peerRTT.removeValue(forKey: peerId)
      connectStartedAt.removeValue(forKey: peerId)
    }

    let session = PeerSession(peerId: peerId)
    sessions[peerId] = session
    peerStates[peerId] = .connecting
    connectStartedAt[peerId] = Date()

    await session.setStateChangeHandler { [weak self] newState in
      Task { @MainActor [weak self] in
        let previous = self?.peerStates[peerId]
        self?.peerStates[peerId] = newState
        if previous == .connected, newState == .failed || newState == .disconnected {
          self?.onPeerDisconnected?(peerId)
        }
      }
    }

    do {
      try await session.accept(signaling: signaling)
      peerStates[peerId] = .connected
      connectStartedAt.removeValue(forKey: peerId)
      logger.notice("Accepted session from \(peerId, privacy: .public)")
    } catch {
      peerStates[peerId] = .failed
      connectStartedAt.removeValue(forKey: peerId)
      logger.error("Failed to accept from \(peerId, privacy: .public): \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  // MARK: - Disconnect

  /// Disconnect a specific peer.
  func disconnectPeer(_ peerId: String) async {
    guard let session = sessions[peerId] else { return }
    await session.disconnect()
    sessions.removeValue(forKey: peerId)
    peerStates.removeValue(forKey: peerId)
    peerRTT.removeValue(forKey: peerId)
    connectStartedAt.removeValue(forKey: peerId)
    logger.notice("Disconnected peer \(peerId, privacy: .public)")
  }

  /// Disconnect all peers.
  func disconnectAll() async {
    for (peerId, session) in sessions {
      await session.disconnect()
      logger.notice("Disconnected peer \(peerId, privacy: .public)")
    }
    sessions.removeAll()
    peerStates.removeAll()
    peerRTT.removeAll()
    connectStartedAt.removeAll()
  }

  // MARK: - Lookup

  /// Get the session for a specific peer, if connected.
  func session(for peerId: String) -> PeerSession? {
    sessions[peerId]
  }

  /// Get the MCP channel for a specific peer, if connected.
  func mcpChannel(for peerId: String) async -> DataChannelHandle? {
    guard let session = sessions[peerId] else { return nil }
    return await session.mcpChannel
  }

  /// Get the transfer channel for a specific peer, if connected.
  func transferChannel(for peerId: String) async -> DataChannelHandle? {
    guard let session = sessions[peerId] else { return nil }
    return await session.transferChannel
  }
}
