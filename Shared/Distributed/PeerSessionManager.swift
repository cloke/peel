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

  /// Last known RTT for each peer (ms).
  private(set) var peerRTT: [String: Double] = [:]

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
      if existingState == .connected || existingState == .connecting {
        logger.info("Already connected/connecting to \(peerId)")
        return
      }
    }

    let session = PeerSession(peerId: peerId)
    sessions[peerId] = session
    peerStates[peerId] = .connecting

    await session.setStateChangeHandler { [weak self] newState in
      Task { @MainActor [weak self] in
        self?.peerStates[peerId] = newState
      }
    }

    do {
      try await session.connect(signaling: signaling)
      peerStates[peerId] = .connected
      logger.notice("Session established with \(peerId)")
    } catch {
      peerStates[peerId] = .failed
      logger.error("Failed to connect to \(peerId): \(error)")
      throw error
    }
  }

  /// Accept an incoming WebRTC session from a peer (responder side).
  func acceptFromPeer(
    _ peerId: String,
    signaling: WebRTCSignalingChannel
  ) async throws {
    let session = PeerSession(peerId: peerId)
    sessions[peerId] = session
    peerStates[peerId] = .connecting

    await session.setStateChangeHandler { [weak self] newState in
      Task { @MainActor [weak self] in
        self?.peerStates[peerId] = newState
      }
    }

    do {
      try await session.accept(signaling: signaling)
      peerStates[peerId] = .connected
      logger.notice("Accepted session from \(peerId)")
    } catch {
      peerStates[peerId] = .failed
      logger.error("Failed to accept from \(peerId): \(error)")
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
    logger.notice("Disconnected peer \(peerId)")
  }

  /// Disconnect all peers.
  func disconnectAll() async {
    for (peerId, session) in sessions {
      await session.disconnect()
      logger.notice("Disconnected peer \(peerId)")
    }
    sessions.removeAll()
    peerStates.removeAll()
    peerRTT.removeAll()
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
