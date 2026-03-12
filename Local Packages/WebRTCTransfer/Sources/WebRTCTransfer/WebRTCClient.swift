//
//  WebRTCClient.swift
//  WebRTCTransfer
//
//  Wraps RTCPeerConnection with async/await for data channel transfers.
//  Handles ICE negotiation, data channel creation, and message exchange.
//

import Foundation
import WebRTC
import os.log

/// Wraps an RTCPeerConnection for data channel use with async/await.
public final class WebRTCClient: NSObject, Sendable {
  private let logger = Logger(subsystem: "com.peel.webrtc", category: "Client")

  // WebRTC objects (created on init, accessed from signaling thread)
  private let peerConnection: RTCPeerConnection
  private let factory: RTCPeerConnectionFactory

  // State management via actor to avoid data races
  private let state = ClientState()

  /// STUN/TURN servers for ICE candidate gathering.
  public static let defaultICEServers = [
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
    "stun:stun2.l.google.com:19302",
  ]

  // MARK: - State Actor

  private actor ClientState {
    var iceCandidates: [RTCIceCandidate] = []
    var iceCandidateHandler: ((RTCIceCandidate) -> Void)?
    var iceGatheringComplete = false
    var iceGatheringContinuation: CheckedContinuation<Void, Never>?

    // Data channel
    var dataChannel: RTCDataChannel?
    var remoteDataChannel: RTCDataChannel?
    var dataChannelContinuation: CheckedContinuation<Void, Error>?

    // Message receiving
    var messageBuffer: [Data] = []
    var messageWaiter: CheckedContinuation<Data, Error>?
    var channelClosedError: Error?

    func setICEHandler(_ handler: @escaping (RTCIceCandidate) -> Void) {
      iceCandidateHandler = handler
      // Flush buffered candidates
      for candidate in iceCandidates {
        handler(candidate)
      }
      iceCandidates.removeAll()
    }

    func addICECandidate(_ candidate: RTCIceCandidate) {
      if let handler = iceCandidateHandler {
        handler(candidate)
      } else {
        iceCandidates.append(candidate)
      }
    }

    func completeICEGathering() {
      iceGatheringComplete = true
      iceGatheringContinuation?.resume()
      iceGatheringContinuation = nil
    }

    func waitForICEGathering() async {
      guard !iceGatheringComplete else { return }
      await withTaskCancellationHandler {
        await withCheckedContinuation { cont in
          if iceGatheringComplete {
            cont.resume()
          } else if Task.isCancelled {
            cont.resume()
          } else {
            iceGatheringContinuation = cont
          }
        }
      } onCancel: {
        Task { await self.cancelICEGatheringWaiter() }
      }
    }

    func cancelICEGatheringWaiter() {
      iceGatheringContinuation?.resume()
      iceGatheringContinuation = nil
    }

    func setDataChannel(_ channel: RTCDataChannel) {
      dataChannel = channel
    }

    func onRemoteDataChannel(_ channel: RTCDataChannel) {
      remoteDataChannel = channel
      dataChannelContinuation?.resume()
      dataChannelContinuation = nil
    }

    func waitForRemoteDataChannel() async throws {
      if remoteDataChannel != nil { return }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          if remoteDataChannel != nil {
            cont.resume()
          } else if Task.isCancelled {
            cont.resume(throwing: CancellationError())
          } else {
            dataChannelContinuation = cont
          }
        }
      } onCancel: {
        Task { await self.cancelDataChannelWaiter() }
      }
    }

    func onDataChannelOpen() {
      dataChannelContinuation?.resume()
      dataChannelContinuation = nil
    }

    func waitForDataChannelOpen() async throws {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          // Check if already open
          if let dc = dataChannel, dc.readyState == .open {
            cont.resume()
          } else if let dc = remoteDataChannel, dc.readyState == .open {
            cont.resume()
          } else if Task.isCancelled {
            cont.resume(throwing: CancellationError())
          } else {
            dataChannelContinuation = cont
          }
        }
      } onCancel: {
        Task { await self.cancelDataChannelWaiter() }
      }
    }

    func onMessage(_ data: Data) {
      if let waiter = messageWaiter {
        messageWaiter = nil
        waiter.resume(returning: data)
      } else {
        messageBuffer.append(data)
      }
    }

    func onChannelClosed(_ error: Error) {
      channelClosedError = error
      messageWaiter?.resume(throwing: error)
      messageWaiter = nil
      dataChannelContinuation?.resume(throwing: error)
      dataChannelContinuation = nil
    }

    func receiveMessage() async throws -> Data {
      if let error = channelClosedError { throw error }
      if !messageBuffer.isEmpty {
        return messageBuffer.removeFirst()
      }
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
          if !messageBuffer.isEmpty {
            cont.resume(returning: messageBuffer.removeFirst())
          } else if let error = channelClosedError {
            cont.resume(throwing: error)
          } else if Task.isCancelled {
            cont.resume(throwing: CancellationError())
          } else {
            messageWaiter = cont
          }
        }
      } onCancel: {
        Task { await self.cancelMessageWaiter() }
      }
    }

    func getActiveDataChannel() -> RTCDataChannel? {
      dataChannel ?? remoteDataChannel
    }

    func cancelDataChannelWaiter() {
      dataChannelContinuation?.resume(throwing: CancellationError())
      dataChannelContinuation = nil
    }

    func cancelMessageWaiter() {
      messageWaiter?.resume(throwing: CancellationError())
      messageWaiter = nil
    }

    // Buffer drain waiting for backpressure
    var bufferDrainContinuation: CheckedContinuation<Void, Error>?

    func onBufferDrained() {
      bufferDrainContinuation?.resume()
      bufferDrainContinuation = nil
    }

    func waitForBufferDrain() async throws {
      if let error = channelClosedError { throw error }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          if let error = channelClosedError {
            cont.resume(throwing: error)
          } else if Task.isCancelled {
            cont.resume(throwing: CancellationError())
          } else {
            bufferDrainContinuation = cont
          }
        }
      } onCancel: {
        Task { await self.cancelBufferDrainWaiter() }
      }
    }

    func cancelBufferDrainWaiter() {
      bufferDrainContinuation?.resume(throwing: CancellationError())
      bufferDrainContinuation = nil
    }
  }

  // MARK: - Init

  public init(iceServers: [String] = WebRTCClient.defaultICEServers) {
    RTCInitializeSSL()

    let encoderFactory = RTCDefaultVideoEncoderFactory()
    let decoderFactory = RTCDefaultVideoDecoderFactory()
    factory = RTCPeerConnectionFactory(
      encoderFactory: encoderFactory,
      decoderFactory: decoderFactory
    )

    let config = RTCConfiguration()
    config.iceServers = [RTCIceServer(urlStrings: iceServers)]
    config.sdpSemantics = .unifiedPlan
    config.continualGatheringPolicy = .gatherContinually
    // Needed for data-only connections
    config.bundlePolicy = .maxBundle
    config.rtcpMuxPolicy = .require

    let constraints = RTCMediaConstraints(
      mandatoryConstraints: nil,
      optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
    )

    peerConnection = factory.peerConnection(
      with: config,
      constraints: constraints,
      delegate: nil
    )!

    super.init()
    peerConnection.delegate = self
  }

  deinit {
    peerConnection.close()
    RTCCleanupSSL()
  }

  // MARK: - SDP Negotiation

  /// Create an SDP offer. Call this on the initiator side.
  public func createOffer() async throws -> String {
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: [
        "OfferToReceiveAudio": "false",
        "OfferToReceiveVideo": "false",
      ],
      optionalConstraints: nil
    )

    let sdp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
      peerConnection.offer(for: constraints) { sdp, error in
        if let error { cont.resume(throwing: error); return }
        guard let sdp else { cont.resume(throwing: WebRTCError.sdpCreationFailed); return }
        cont.resume(returning: sdp)
      }
    }

    try await setLocalDescription(sdp)
    return sdp.sdp
  }

  /// Create an SDP answer after receiving a remote offer. Call this on the responder side.
  public func createAnswer() async throws -> String {
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: [
        "OfferToReceiveAudio": "false",
        "OfferToReceiveVideo": "false",
      ],
      optionalConstraints: nil
    )

    let sdp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
      peerConnection.answer(for: constraints) { sdp, error in
        if let error { cont.resume(throwing: error); return }
        guard let sdp else { cont.resume(throwing: WebRTCError.sdpCreationFailed); return }
        cont.resume(returning: sdp)
      }
    }

    try await setLocalDescription(sdp)
    return sdp.sdp
  }

  /// Set the remote SDP (offer on responder, answer on initiator).
  public func setRemoteDescription(_ sdp: String, type: RTCSdpType) async throws {
    let sessionDescription = RTCSessionDescription(type: type, sdp: sdp)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      peerConnection.setRemoteDescription(sessionDescription) { error in
        if let error { cont.resume(throwing: error) } else { cont.resume() }
      }
    }
  }

  private func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      peerConnection.setLocalDescription(sdp) { error in
        if let error { cont.resume(throwing: error) } else { cont.resume() }
      }
    }
  }

  // MARK: - ICE Candidates

  /// Add a remote ICE candidate.
  public func addICECandidate(_ candidate: ICECandidateMessage) async throws {
    let rtcCandidate = RTCIceCandidate(
      sdp: candidate.sdp,
      sdpMLineIndex: candidate.sdpMLineIndex,
      sdpMid: candidate.sdpMid
    )
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      peerConnection.add(rtcCandidate) { error in
        if let error { cont.resume(throwing: error) } else { cont.resume() }
      }
    }
  }

  /// Register a handler for locally gathered ICE candidates (to send to peer).
  /// Flushes any candidates gathered before the handler was set.
  public func onLocalICECandidate(_ handler: @escaping @Sendable (ICECandidateMessage) -> Void) async {
    await state.setICEHandler { candidate in
      handler(ICECandidateMessage(
        sdp: candidate.sdp,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex
      ))
    }
  }

  // MARK: - Data Channel

  /// Create a data channel (initiator side). Must be called before createOffer().
  public func createDataChannel(label: String = "transfer") async throws {
    let config = RTCDataChannelConfiguration()
    config.isOrdered = true  // Reliable, ordered delivery via SCTP
    // maxRetransmits = nil → unlimited retransmits (fully reliable)

    guard let channel = peerConnection.dataChannel(forLabel: label, configuration: config) else {
      throw WebRTCError.dataChannelCreationFailed
    }

    channel.delegate = self
    await state.setDataChannel(channel)
    logger.info("Data channel '\(label)' created")
  }

  /// Wait for the data channel to be open (either local or remote).
  public func waitForDataChannelOpen(timeout: Duration = .seconds(30)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await self.state.waitForDataChannelOpen() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WebRTCError.dataChannelTimeout
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  /// Wait for a remote data channel to arrive (responder side).
  public func waitForRemoteDataChannel(timeout: Duration = .seconds(30)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await self.state.waitForRemoteDataChannel() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WebRTCError.dataChannelTimeout
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  // MARK: - Data Transfer

  /// Max buffered bytes before pausing sends (256KB).
  private static let bufferHighWaterMark: UInt64 = 256 * 1024
  /// Resume threshold (64KB).
  private static let bufferLowWaterMark: UInt64 = 64 * 1024

  /// Send binary data over the data channel with backpressure.
  /// Waits if the channel's buffer exceeds the high water mark.
  public func send(_ data: Data) async throws {
    guard let channel = await state.getActiveDataChannel() else {
      throw WebRTCError.noDataChannel
    }
    guard channel.readyState == .open else {
      throw WebRTCError.dataChannelNotOpen
    }

    // Wait for buffer to drain if above high water mark
    if channel.bufferedAmount > Self.bufferHighWaterMark {
      try await state.waitForBufferDrain()
    }

    let buffer = RTCDataBuffer(data: data, isBinary: true)
    guard channel.sendData(buffer) else {
      throw WebRTCError.sendFailed
    }
  }

  /// Receive a message from the data channel.
  public func receive(timeout: Duration = .seconds(30)) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { try await self.state.receiveMessage() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WebRTCError.receiveTimeout
      }
      defer { group.cancelAll() }
      guard let data = try await group.next() else {
        throw WebRTCError.receiveTimeout
      }
      return data
    }
  }

  /// Close the peer connection.
  public func close() {
    peerConnection.close()
  }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {
  public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
    logger.debug("Signaling state: \(String(describing: stateChanged))")
  }

  public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

  public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

  public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

  public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
    logger.info("ICE connection state: \(String(describing: newState))")
    // Only fail on terminal states. `.disconnected` is transient — ICE will
    // attempt to recover via candidate pair switching. Treating it as fatal
    // was killing transfers after the first 64KB chunk.
    if newState == .failed || newState == .closed {
      Task {
        await state.onChannelClosed(WebRTCError.iceConnectionFailed(state: newState))
      }
    }
  }

  public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
    logger.debug("ICE gathering state: \(String(describing: newState))")
    if newState == .complete {
      Task { await state.completeICEGathering() }
    }
  }

  public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
    logger.debug("ICE candidate: \(candidate.sdp.prefix(80))")
    Task { await state.addICECandidate(candidate) }
  }

  public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

  public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
    logger.info("Remote data channel opened: \(dataChannel.label)")
    dataChannel.delegate = self
    Task { await state.onRemoteDataChannel(dataChannel) }
  }
}

// MARK: - RTCDataChannelDelegate

extension WebRTCClient: RTCDataChannelDelegate {
  public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    logger.info("Data channel state: \(String(describing: dataChannel.readyState))")
    if dataChannel.readyState == .open {
      Task { await state.onDataChannelOpen() }
    } else if dataChannel.readyState == .closed {
      Task { await state.onChannelClosed(WebRTCError.dataChannelClosed) }
    }
  }

  public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    Task { await state.onMessage(buffer.data) }
  }

  public func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
    if amount <= Self.bufferLowWaterMark {
      Task { await state.onBufferDrained() }
    }
  }
}

// MARK: - Errors

public enum WebRTCError: LocalizedError, Sendable {
  case sdpCreationFailed
  case dataChannelCreationFailed
  case dataChannelTimeout
  case dataChannelNotOpen
  case dataChannelClosed
  case noDataChannel
  case sendFailed
  case receiveTimeout
  case iceConnectionFailed(state: RTCIceConnectionState)
  case transferFailed(reason: String)

  public var errorDescription: String? {
    switch self {
    case .sdpCreationFailed: "Failed to create SDP"
    case .dataChannelCreationFailed: "Failed to create data channel"
    case .dataChannelTimeout: "Data channel open timed out"
    case .dataChannelNotOpen: "Data channel is not open"
    case .dataChannelClosed: "Data channel was closed"
    case .noDataChannel: "No data channel available"
    case .sendFailed: "Failed to send data"
    case .receiveTimeout: "Timed out waiting for data"
    case .iceConnectionFailed(let state): "ICE connection failed: \(state)"
    case .transferFailed(let reason): "Transfer failed: \(reason)"
    }
  }
}
