//
//  PeerSession.swift
//  Peel
//
//  Manages a single persistent WebRTC connection to one peer.
//  Provides typed access to named data channels (mcp, transfer, heartbeat, chat).
//
//  Part of the WebRTC-first networking replan (Plans/NETWORKING_REPLAN.md).
//

import Foundation
import os.log
import WebRTCTransfer

// MARK: - Connection State

/// Connection state for a peer session.
public enum PeerSessionState: String, Sendable {
  case disconnected
  case connecting
  case connected
  case reconnecting
  case failed
}

// MARK: - PeerSession

/// Manages a persistent WebRTC connection to one peer with multiple named data channels.
public actor PeerSession {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "PeerSession")

  public let peerId: String
  private var client: WebRTCClient?

  // Named channel handles
  public private(set) var mcpChannel: DataChannelHandle?
  public private(set) var transferChannel: DataChannelHandle?
  public private(set) var heartbeatChannel: DataChannelHandle?
  public private(set) var chatChannel: DataChannelHandle?

  public private(set) var state: PeerSessionState = .disconnected
  public private(set) var lastHeartbeat: Date?
  public private(set) var roundTripMs: Double?

  private var heartbeatTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var stateChangeHandler: (@Sendable (PeerSessionState) -> Void)?

  // ICE candidate forwarding tasks — kept alive for the connection lifetime
  // so that late-arriving candidates (TURN relay, network changes) are still
  // exchanged. Matches the Firebase RTC codelab pattern where candidate
  // listeners persist until disconnect.
  private var localCandidateTask: Task<Void, Never>?
  private var remoteCandidateTask: Task<Void, Never>?

  // Channel labels
  static let mcpLabel = "mcp"
  static let transferLabel = "transfer"
  static let heartbeatLabel = "heartbeat"
  static let chatLabel = "chat"

  public var isConnected: Bool { state == .connected }

  public init(peerId: String) {
    self.peerId = peerId
  }

  /// Register a handler called whenever the session state changes.
  public func setStateChangeHandler(_ handler: @escaping @Sendable (PeerSessionState) -> Void) {
    stateChangeHandler = handler
  }

  private func updateState(_ newState: PeerSessionState) {
    state = newState
    stateChangeHandler?(newState)
  }

  // MARK: - Connect (Initiator)

  /// Connect to peer as the initiator. Creates channels, exchanges SDP via signaling.
  public func connect(signaling: WebRTCSignalingChannel) async throws {
    guard state == .disconnected || state == .failed else {
      logger.warning("Cannot connect: already in state \(self.state.rawValue)")
      return
    }

    updateState(.connecting)
    let newClient = WebRTCClient()
    client = newClient

    do {
      // Create named channels (must be before createOffer)
      let mcp = try await newClient.openChannel(label: Self.mcpLabel)
      let transfer = try await newClient.openChannel(label: Self.transferLabel, config: .bulkTransfer)
      let heartbeat = try await newClient.openChannel(label: Self.heartbeatLabel, config: .unreliable)
      let chat = try await newClient.openChannel(label: Self.chatLabel)

      // ICE candidate forwarding — kept alive for connection lifetime
      localCandidateTask = Task {
        await newClient.onLocalICECandidate { candidate in
          Task { try? await signaling.sendCandidate(candidate) }
        }
      }
      remoteCandidateTask = Task {
        for await candidate in signaling.receiveCandidates() {
          try? await newClient.addICECandidate(candidate)
        }
      }

      // SDP offer/answer exchange
      let offerSDP = try await newClient.createOffer()
      try await signaling.sendOffer(offerSDP)
      let answerSDP = try await signaling.waitForAnswer(timeout: .seconds(30))
      try await newClient.setRemoteAnswer(answerSDP)

      // Wait for control and bulk-transfer channels to open before treating the
      // persistent session as ready. The first RAG chunk can otherwise race the
      // transfer channel coming fully online.
      try await mcp.waitForOpen(timeout: .seconds(30))
      try await transfer.waitForOpen(timeout: .seconds(30))

      mcpChannel = mcp
      transferChannel = transfer
      heartbeatChannel = heartbeat
      chatChannel = chat
      updateState(.connected)

      // Monitor ICE state for disconnection
      setupICEMonitoring(newClient)
      startHeartbeat()

      logger.notice("Connected to peer \(self.peerId)")
    } catch {
      updateState(.failed)
      client?.close()
      client = nil
      throw error
    }
  }

  // MARK: - Accept (Responder)

  /// Accept a connection from a peer. Responds to an SDP offer, receives named channels.
  public func accept(signaling: WebRTCSignalingChannel) async throws {
    guard state == .disconnected || state == .failed else {
      logger.warning("Cannot accept: already in state \(self.state.rawValue)")
      return
    }

    updateState(.connecting)
    let newClient = WebRTCClient()
    client = newClient

    do {
      // Tell the client we're using named channels (so didOpen routes to handles)
      await newClient.enableNamedChannels()

      // ICE candidate forwarding — kept alive for connection lifetime
      localCandidateTask = Task {
        await newClient.onLocalICECandidate { candidate in
          Task { try? await signaling.sendCandidate(candidate) }
        }
      }
      remoteCandidateTask = Task {
        for await candidate in signaling.receiveCandidates() {
          try? await newClient.addICECandidate(candidate)
        }
      }

      // Receive offer, create answer
      let offerSDP = try await signaling.waitForOffer(timeout: .seconds(30))
      try await newClient.setRemoteOffer(offerSDP)
      let answerSDP = try await newClient.createAnswer()
      try await signaling.sendAnswer(answerSDP)

      // Wait for remote channels to arrive
      let mcp = try await newClient.waitForRemoteChannel(label: Self.mcpLabel, timeout: .seconds(30))
      let transfer = try await newClient.waitForRemoteChannel(label: Self.transferLabel, timeout: .seconds(30))
      let heartbeat = try await newClient.waitForRemoteChannel(label: Self.heartbeatLabel, timeout: .seconds(30))
      let chat = try await newClient.waitForRemoteChannel(label: Self.chatLabel, timeout: .seconds(30))

      // Keep ICE candidate exchange alive until the control and transfer channels
      // are fully open. Remote channel discovery can happen before SCTP/data-channel
      // readiness, and the first RAG chunk depends on the transfer channel.
      try await mcp.waitForOpen(timeout: .seconds(30))
      try await transfer.waitForOpen(timeout: .seconds(30))

      mcpChannel = mcp
      transferChannel = transfer
      heartbeatChannel = heartbeat
      chatChannel = chat
      updateState(.connected)

      setupICEMonitoring(newClient)
      startHeartbeat()

      logger.notice("Accepted connection from peer \(self.peerId)")
    } catch {
      updateState(.failed)
      client?.close()
      client = nil
      throw error
    }
  }

  // MARK: - Disconnect

  public func disconnect() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    localCandidateTask?.cancel()
    localCandidateTask = nil
    remoteCandidateTask?.cancel()
    remoteCandidateTask = nil
    client?.close()
    client = nil
    mcpChannel = nil
    transferChannel = nil
    heartbeatChannel = nil
    chatChannel = nil
    updateState(.disconnected)
    logger.notice("Disconnected from peer \(self.peerId)")
  }

  // MARK: - ICE Monitoring

  private func setupICEMonitoring(_ client: WebRTCClient) {
    Task { [weak self] in
      guard let self else { return }
      await client.onICEStateChange { [weak self] state in
        Task { [weak self] in
          await self?.handleICEStateChange(state)
        }
      }
    }
  }

  private nonisolated func handleICEStateChange(_ iceState: Any) async {
    // RTCIceConnectionState is an ObjC enum, compare raw values
    // .disconnected = 5 (transient), .failed = 6 (terminal), .closed = 7
    // We receive it as Any to avoid importing WebRTC directly
    let stateValue = (iceState as? Int) ?? -1
    if stateValue == 6 || stateValue == 7 {
      // ICE failed or closed — trigger reconnect
      await self.onICEFailed()
    }
  }

  private func onICEFailed() {
    guard state == .connected else { return }
    logger.warning("ICE connection failed for peer \(self.peerId)")
    updateState(.reconnecting)
    // TODO: Implement ICE restart reconnection in Phase 1.5
    // For now, mark as failed. The PeerSessionManager will handle reconnection.
    updateState(.failed)
  }

  // MARK: - Heartbeat

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard let self, let channel = await self.heartbeatChannel else { break }

        let pingTime = ContinuousClock.now
        let pingData = Data("ping".utf8)
        do {
          try await channel.send(pingData)
          let pong = try await channel.receive(timeout: .seconds(5))
          if String(data: pong, encoding: .utf8) == "pong" {
            let rtt = Double((ContinuousClock.now - pingTime).components.attoseconds) / 1e15
            await self.updateHeartbeat(rtt: rtt)
          }
        } catch {
          // Heartbeat failure is not fatal — channel may recover
          break
        }
      }
    }
  }

  private func updateHeartbeat(rtt: Double) {
    lastHeartbeat = Date()
    roundTripMs = rtt
  }
}
