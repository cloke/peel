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

    // MARK: - Named Channel Support

    var usingNamedChannels = false
    var pendingRemoteChannels: [String: CheckedContinuation<DataChannelHandle, Error>] = [:]
    var receivedRemoteChannels: [String: DataChannelHandle] = [:]
    var iceStateHandler: ((RTCIceConnectionState) -> Void)?

    func setUsingNamedChannels() {
      usingNamedChannels = true
    }

    /// Routes a remote data channel to a named handle. Returns true if handled.
    func handleRemoteNamedChannel(_ channel: RTCDataChannel) -> Bool {
      guard usingNamedChannels else { return false }

      let handle = DataChannelHandle(channel: channel)
      let label = channel.label

      if let continuation = pendingRemoteChannels[label] {
        pendingRemoteChannels.removeValue(forKey: label)
        receivedRemoteChannels[label] = handle
        continuation.resume(returning: handle)
      } else {
        receivedRemoteChannels[label] = handle
      }

      return true
    }

    func waitForRemoteNamedChannel(_ label: String) async throws -> DataChannelHandle {
      if let existing = receivedRemoteChannels[label] {
        return existing
      }
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
          if let existing = receivedRemoteChannels[label] {
            cont.resume(returning: existing)
          } else if Task.isCancelled {
            cont.resume(throwing: CancellationError())
          } else {
            pendingRemoteChannels[label] = cont
          }
        }
      } onCancel: {
        Task { [weak self] in await self?.cancelRemoteChannelWaiter(label) }
      }
    }

    func cancelRemoteChannelWaiter(_ label: String) {
      pendingRemoteChannels[label]?.resume(throwing: CancellationError())
      pendingRemoteChannels.removeValue(forKey: label)
    }

    func setICEStateHandler(_ handler: @escaping (RTCIceConnectionState) -> Void) {
      iceStateHandler = handler
    }

    func notifyICEState(_ newState: RTCIceConnectionState) {
      iceStateHandler?(newState)
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
      logger.debug("Backpressure: buffered=\(channel.bufferedAmount) > \(Self.bufferHighWaterMark), waiting for drain")
      let drainStart = ContinuousClock.now
      try await state.waitForBufferDrain()
      logger.debug("Backpressure: drained in \(ContinuousClock.now - drainStart)")
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

  // MARK: - Named Data Channels

  /// Enable named channel routing for responder side.
  /// Call before receiving remote channels to ensure they're routed to DataChannelHandle instances.
  public func enableNamedChannels() async {
    await state.setUsingNamedChannels()
  }

  /// Create a named data channel (initiator side). Must be called before createOffer().
  /// Returns a DataChannelHandle that manages this channel's send/receive independently.
  public func openChannel(label: String, config: DataChannelConfig = .reliable) async throws -> DataChannelHandle {
    await state.setUsingNamedChannels()

    let rtcConfig = RTCDataChannelConfiguration()
    rtcConfig.isOrdered = config.ordered
    if let maxRetransmits = config.maxRetransmits {
      rtcConfig.maxRetransmits = Int32(maxRetransmits)
    }

    guard let channel = peerConnection.dataChannel(forLabel: label, configuration: rtcConfig) else {
      throw WebRTCError.dataChannelCreationFailed
    }

    let handle = DataChannelHandle(channel: channel)
    logger.info("Named data channel '\(label)' created (ordered=\(config.ordered))")
    return handle
  }

  /// Wait for a named remote data channel (responder side).
  public func waitForRemoteChannel(label: String, timeout: Duration = .seconds(30)) async throws -> DataChannelHandle {
    await state.setUsingNamedChannels()
    return try await withThrowingTaskGroup(of: DataChannelHandle.self) { group in
      group.addTask { try await self.state.waitForRemoteNamedChannel(label) }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WebRTCError.dataChannelTimeout
      }
      defer { group.cancelAll() }
      guard let handle = try await group.next() else {
        throw WebRTCError.dataChannelTimeout
      }
      return handle
    }
  }

  // MARK: - ICE Restart

  /// Restart ICE to recover a dropped connection. Returns a new SDP offer.
  public func restartICE() async throws -> String {
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: [
        "IceRestart": "true",
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

  // MARK: - ICE State Observation

  /// Register a handler for ICE connection state changes.
  public func onICEStateChange(_ handler: @escaping @Sendable (RTCIceConnectionState) -> Void) async {
    await state.setICEStateHandler(handler)
  }

  // MARK: - Convenience (avoids importing WebRTC for RTCSdpType)

  /// Set a remote SDP offer.
  public func setRemoteOffer(_ sdp: String) async throws {
    try await setRemoteDescription(sdp, type: .offer)
  }

  /// Set a remote SDP answer.
  public func setRemoteAnswer(_ sdp: String) async throws {
    try await setRemoteDescription(sdp, type: .answer)
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
    logger.notice("ICE connection state: \(String(describing: newState)) (thread: \(Thread.isMainThread ? "main" : "bg"))")
    Task { await state.notifyICEState(newState) }
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
    Task {
      let handled = await state.handleRemoteNamedChannel(dataChannel)
      if !handled {
        // Legacy single-channel path
        dataChannel.delegate = self
        await state.onRemoteDataChannel(dataChannel)
      }
    }
  }
}

// MARK: - RTCDataChannelDelegate

extension WebRTCClient: RTCDataChannelDelegate {
  public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    logger.notice("Data channel state: \(String(describing: dataChannel.readyState)) (thread: \(Thread.isMainThread ? "main" : "bg"))")
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
