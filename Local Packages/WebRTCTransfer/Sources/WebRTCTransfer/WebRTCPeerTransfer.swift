//
//  WebRTCPeerTransfer.swift
//  WebRTCTransfer
//
//  High-level API for P2P data transfer using WebRTC data channels.
//  Replaces the custom UDP hole-punch + PUNCH/REQUEST/DATA/ACK/FIN protocol
//  with WebRTC's ICE (NAT traversal) + SCTP (reliable data channel).
//
//  WebRTC handles all of the following automatically:
//  - STUN discovery and NAT mapping
//  - ICE connectivity checks and candidate selection
//  - NAT keepalives
//  - Reliable, ordered data delivery (SCTP)
//  - Congestion control
//

import Foundation
import WebRTC
import os.log

/// Data provider protocol — the caller provides the data to serve.
/// Replaces the previous `UDPTransferDataProvider`.
public protocol WebRTCTransferDataProvider: AnyObject, Sendable {
  func exportRepoBundle(repoIdentifier: String) async throws -> Data
}

/// High-level P2P transfer using WebRTC data channels.
public enum WebRTCPeerTransfer {
  private static let logger = Logger(subsystem: "com.peel.webrtc", category: "Transfer")

  /// Max message size for a single RTCDataChannel send.
  /// SCTP handles fragmentation, but keeping messages reasonably sized
  /// improves flow control and allows progress tracking.
  static let chunkSize = 64 * 1024  // 64KB

  // MARK: - Transfer Protocol Messages

  private enum MessageType: UInt8 {
    case request = 1
    case manifest = 2
    case chunk = 3
    case complete = 4
    case error = 5
    case ping = 6
    case pong = 7
  }

  // MARK: - Ping Result

  /// Result of a WebRTC ping, with timing at each stage of the pipeline.
  public struct PingResult: Sendable {
    /// Time to exchange SDP offer/answer via signaling (Firestore)
    public let signalingMs: Double
    /// Time from SDP answer received to data channel open (ICE + DTLS)
    public let iceNegotiationMs: Double
    /// Round-trip time for ping/pong over the data channel
    public let roundTripMs: Double
    /// Total time from start to pong received
    public let totalMs: Double
  }

  // MARK: - Initiator Side

  /// Request data from a remote peer via WebRTC data channel.
  ///
  /// Flow:
  /// 1. Create RTCPeerConnection + data channel
  /// 2. Exchange SDP offer/answer via signaling
  /// 3. Exchange ICE candidates via signaling
  /// 4. Wait for data channel to open (ICE + DTLS complete)
  /// 5. Send request, receive chunked data
  ///
  /// - Parameters:
  ///   - signaling: Channel for exchanging SDP and ICE candidates (e.g., Firestore)
  ///   - repoIdentifier: The repo to request data for
  ///   - timeout: Total transfer timeout
  ///   - progressHandler: Called with (bytesReceived, totalBytes)
  /// - Returns: The received data
  public static func requestData(
    signaling: WebRTCSignalingChannel,
    repoIdentifier: String,
    timeout: Duration = .seconds(300),
    progressHandler: (@Sendable (Int, Int) -> Void)? = nil
  ) async throws -> Data {
    let client = WebRTCClient()
    var remoteCandidateTask: Task<Void, Never>?
    var candidateTask: Task<Void, Never>?
    defer {
      candidateTask?.cancel()
      remoteCandidateTask?.cancel()
      client.close()
      Task { await signaling.cleanup() }
    }

    logger.info("Starting WebRTC transfer (initiator) for \(repoIdentifier)")
    let transferStart = ContinuousClock.now

    // 1. Create data channel (must be before createOffer so it's in the SDP)
    try await client.createDataChannel(label: "rag-transfer")

    // 2. Set up ICE candidate forwarding to remote peer
    var iceCandidatesSent = 0
    candidateTask = Task {
      await client.onLocalICECandidate { candidate in
        Task {
          try? await signaling.sendCandidate(candidate)
          iceCandidatesSent += 1
        }
      }
    }

    // 3. Start receiving remote ICE candidates
    var iceCandidatesReceived = 0
    remoteCandidateTask = Task {
      for await candidate in signaling.receiveCandidates() {
        try? await client.addICECandidate(candidate)
        iceCandidatesReceived += 1
      }
    }

    // 4. Create and send SDP offer
    var stageStart = ContinuousClock.now
    let offerSDP = try await client.createOffer()
    logger.notice("[initiator] createOffer: \(ContinuousClock.now - stageStart)")
    stageStart = ContinuousClock.now
    try await signaling.sendOffer(offerSDP)
    logger.notice("[initiator] sendOffer (Firestore write): \(ContinuousClock.now - stageStart)")

    // 5. Wait for SDP answer
    stageStart = ContinuousClock.now
    let answerSDP = try await signaling.waitForAnswer(timeout: .seconds(30))
    logger.notice("[initiator] waitForAnswer: \(ContinuousClock.now - stageStart)")
    try await client.setRemoteDescription(answerSDP, type: .answer)
    logger.notice("[initiator] ICE candidates so far: sent=\(iceCandidatesSent) received=\(iceCandidatesReceived)")

    // 6. Wait for data channel to open (ICE negotiation + DTLS handshake)
    stageStart = ContinuousClock.now
    try await client.waitForDataChannelOpen(timeout: .seconds(30))
    logger.notice("[initiator] data channel open: \(ContinuousClock.now - stageStart) (ICE: sent=\(iceCandidatesSent) recv=\(iceCandidatesReceived))")

    // 7. Send request
    let requestJSON = try JSONEncoder().encode(["repo": repoIdentifier])
    var requestMsg = Data([MessageType.request.rawValue])
    requestMsg.append(requestJSON)
    try await client.send(requestMsg)
    logger.notice("[initiator] request sent, waiting for data")

    // 8. Receive data
    let result = try await receiveChunkedData(
      client: client,
      timeout: timeout,
      progressHandler: progressHandler
    )

    // Clean up — tasks cancelled by defer
    let totalElapsed = ContinuousClock.now - transferStart
    logger.notice("[initiator] transfer complete: \(result.count) bytes in \(totalElapsed) for \(repoIdentifier)")
    return result
  }

  // MARK: - Responder Side

  /// Serve data to a remote peer via WebRTC data channel.
  ///
  /// Flow:
  /// 1. Receive SDP offer from signaling
  /// 2. Create RTCPeerConnection, set remote offer, create answer
  /// 3. Exchange ICE candidates
  /// 4. Wait for data channel from remote peer
  /// 5. Wait for request, export data, send in chunks
  ///
  /// - Parameters:
  ///   - signaling: Channel for exchanging SDP and ICE candidates
  ///   - dataProvider: Provides the data to serve
  ///   - timeout: Total serve timeout
  public static func serveData(
    signaling: WebRTCSignalingChannel,
    dataProvider: WebRTCTransferDataProvider,
    timeout: Duration = .seconds(300)
  ) async throws {
    let client = WebRTCClient()
    var remoteCandidateTask: Task<Void, Never>?
    defer {
      remoteCandidateTask?.cancel()
      client.close()
      Task { await signaling.cleanup() }
    }

    logger.info("Starting WebRTC transfer (responder)")
    let transferStart = ContinuousClock.now

    // 1. Set up ICE candidate forwarding
    var iceCandidatesSent = 0
    await client.onLocalICECandidate { candidate in
      Task {
        try? await signaling.sendCandidate(candidate)
        iceCandidatesSent += 1
      }
    }

    // 2. Start receiving remote ICE candidates
    var iceCandidatesReceived = 0
    remoteCandidateTask = Task {
      for await candidate in signaling.receiveCandidates() {
        try? await client.addICECandidate(candidate)
        iceCandidatesReceived += 1
      }
    }

    // 3. Wait for SDP offer
    var stageStart = ContinuousClock.now
    let offerSDP = try await signaling.waitForOffer(timeout: .seconds(30))
    try await client.setRemoteDescription(offerSDP, type: .offer)
    logger.notice("[responder] offer received: \(ContinuousClock.now - stageStart)")

    // 4. Create and send SDP answer
    stageStart = ContinuousClock.now
    let answerSDP = try await client.createAnswer()
    try await signaling.sendAnswer(answerSDP)
    logger.notice("[responder] answer sent (Firestore write): \(ContinuousClock.now - stageStart)")

    // 5. Wait for remote data channel
    stageStart = ContinuousClock.now
    try await client.waitForRemoteDataChannel(timeout: .seconds(30))
    logger.notice("[responder] data channel open: \(ContinuousClock.now - stageStart) (ICE: sent=\(iceCandidatesSent) recv=\(iceCandidatesReceived))")

    // 6. Wait for request
    stageStart = ContinuousClock.now
    let requestData = try await client.receive(timeout: .seconds(30))
    guard requestData.first == MessageType.request.rawValue else {
      throw WebRTCError.transferFailed(reason: "Expected request message, got type \(requestData.first ?? 0)")
    }

    let requestJSON = requestData.dropFirst()
    guard let request = try? JSONDecoder().decode([String: String].self, from: Data(requestJSON)),
      let repoIdentifier = request["repo"]
    else {
      throw WebRTCError.transferFailed(reason: "Invalid request format")
    }

    logger.notice("[responder] request received for \(repoIdentifier): \(ContinuousClock.now - stageStart)")

    // 7. Export data
    stageStart = ContinuousClock.now
    logger.notice("[responder] calling exportRepoBundle (will hop to MainActor)...")
    let bundleData = try await dataProvider.exportRepoBundle(repoIdentifier: repoIdentifier)
    logger.notice("[responder] exportRepoBundle complete: \(bundleData.count) bytes in \(ContinuousClock.now - stageStart)")

    // 8. Send manifest
    try await sendManifest(client: client, totalBytes: bundleData.count)
    logger.notice("[responder] manifest sent")

    // 9. Send chunked data
    stageStart = ContinuousClock.now
    try await sendChunkedData(client: client, data: bundleData)
    logger.notice("[responder] all chunks sent: \(ContinuousClock.now - stageStart)")

    // 10. Send complete
    try await client.send(Data([MessageType.complete.rawValue]))
    let totalElapsed = ContinuousClock.now - transferStart
    logger.notice("[responder] transfer served: \(bundleData.count) bytes for \(repoIdentifier) in \(totalElapsed)")

    // Give the peer a moment to receive the complete message
    try? await Task.sleep(for: .seconds(1))
    // remoteCandidateTask cancelled by defer
  }

  // MARK: - Chunked Transfer Helpers

  private static func sendManifest(client: WebRTCClient, totalBytes: Int) async throws {
    let totalChunks = (totalBytes + chunkSize - 1) / chunkSize
    var msg = Data([MessageType.manifest.rawValue])
    // 4 bytes totalBytes (big-endian) + 4 bytes totalChunks (big-endian)
    var tb = UInt32(totalBytes).bigEndian
    var tc = UInt32(totalChunks).bigEndian
    msg.append(Data(bytes: &tb, count: 4))
    msg.append(Data(bytes: &tc, count: 4))
    try await client.send(msg)
  }

  private static func sendChunkedData(client: WebRTCClient, data: Data) async throws {
    let totalChunks = (data.count + chunkSize - 1) / chunkSize
    logger.notice("[responder] sending \(totalChunks) chunks (\(data.count) bytes)")
    for i in 0..<totalChunks {
      let start = i * chunkSize
      let end = min(start + chunkSize, data.count)
      let chunkData = data[start..<end]

      var msg = Data([MessageType.chunk.rawValue])
      // 4 bytes chunk index (big-endian)
      var idx = UInt32(i).bigEndian
      msg.append(Data(bytes: &idx, count: 4))
      msg.append(chunkData)

      // send() applies backpressure via bufferedAmount checking
      try await client.send(msg)

      // Log progress every 50 chunks or on first/last
      if i == 0 || i == totalChunks - 1 || (i + 1) % 50 == 0 {
        logger.info("[responder] chunk \(i + 1)/\(totalChunks) sent")
      }
    }
  }

  private static func receiveChunkedData(
    client: WebRTCClient,
    timeout: Duration,
    progressHandler: (@Sendable (Int, Int) -> Void)?
  ) async throws -> Data {
    var totalBytes = 0
    var totalChunks = 0
    var receivedChunks = [UInt32: Data]()
    var bytesReceived = 0

    while true {
      let msg = try await client.receive(timeout: timeout)
      guard let type = msg.first.flatMap({ MessageType(rawValue: $0) }) else {
        logger.warning("Unknown message type: \(msg.first ?? 0)")
        continue
      }

      switch type {
      case .manifest:
        guard msg.count >= 9 else {
          throw WebRTCError.transferFailed(reason: "Manifest too short")
        }
        let tbBytes = msg[1...4]
        let tcBytes = msg[5...8]
        totalBytes = Int(UInt32(bigEndian: tbBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        totalChunks = Int(UInt32(bigEndian: tcBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        logger.notice("[initiator] manifest: \(totalBytes) bytes in \(totalChunks) chunks")

      case .chunk:
        guard msg.count >= 5 else {
          throw WebRTCError.transferFailed(reason: "Chunk too short")
        }
        let idxBytes = msg[1...4]
        let chunkIndex = UInt32(bigEndian: idxBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let chunkData = msg.dropFirst(5)
        receivedChunks[chunkIndex] = Data(chunkData)
        bytesReceived += chunkData.count
        progressHandler?(bytesReceived, totalBytes)

        // Log progress every 50 chunks or first/last
        let chunkNum = Int(chunkIndex) + 1
        if chunkNum == 1 || chunkNum == totalChunks || chunkNum % 50 == 0 {
          logger.info("[initiator] chunk \(chunkNum)/\(totalChunks) (\(bytesReceived)/\(totalBytes) bytes)")
        }

      case .complete:
        // Reassemble chunks in order
        guard totalChunks > 0 else {
          throw WebRTCError.transferFailed(reason: "Complete received but no manifest")
        }
        var assembled = Data(capacity: totalBytes)
        for i in 0..<UInt32(totalChunks) {
          guard let chunk = receivedChunks[i] else {
            throw WebRTCError.transferFailed(reason: "Missing chunk \(i) of \(totalChunks)")
          }
          assembled.append(chunk)
        }
        return assembled

      case .error:
        let errorMsg = String(data: Data(msg.dropFirst()), encoding: .utf8) ?? "Unknown error"
        throw WebRTCError.transferFailed(reason: errorMsg)

      case .request:
        logger.warning("Unexpected request message on initiator side")

      case .ping, .pong:
        logger.warning("Unexpected ping/pong message during transfer")
      }
    }
  }

  // MARK: - WebRTC Ping (Connectivity Test)

  /// Ping a remote peer via WebRTC data channel.
  /// Tests the full pipeline: Firestore signaling → ICE negotiation → data channel → round-trip.
  ///
  /// - Parameters:
  ///   - signaling: Channel for exchanging SDP and ICE candidates
  ///   - timeout: Total ping timeout
  /// - Returns: Timing breakdown of each pipeline stage
  public static func ping(
    signaling: WebRTCSignalingChannel,
    timeout: Duration = .seconds(30)
  ) async throws -> PingResult {
    let client = WebRTCClient()
    defer { client.close(); Task { await signaling.cleanup() } }

    let totalStart = ContinuousClock.now

    logger.info("Starting WebRTC ping (initiator)")

    // 1. Create data channel + ICE forwarding
    try await client.createDataChannel(label: "ping")

    let candidateTask = Task {
      await client.onLocalICECandidate { candidate in
        Task { try? await signaling.sendCandidate(candidate) }
      }
    }
    let remoteCandidateTask = Task {
      for await candidate in signaling.receiveCandidates() {
        try? await client.addICECandidate(candidate)
      }
    }

    // 2. SDP exchange (timed)
    let signalingStart = ContinuousClock.now
    let offerSDP = try await client.createOffer()
    try await signaling.sendOffer(offerSDP)
    let answerSDP = try await signaling.waitForAnswer(timeout: .seconds(15))
    try await client.setRemoteDescription(answerSDP, type: .answer)
    let signalingMs = Double((ContinuousClock.now - signalingStart).components.attoseconds) / 1e15

    // 3. Wait for data channel open (ICE + DTLS, timed)
    let iceStart = ContinuousClock.now
    try await client.waitForDataChannelOpen(timeout: .seconds(15))
    let iceMs = Double((ContinuousClock.now - iceStart).components.attoseconds) / 1e15

    // 4. Send ping, receive pong (timed)
    let pingStart = ContinuousClock.now
    var pingMsg = Data([MessageType.ping.rawValue])
    var nanos = UInt64(DispatchTime.now().uptimeNanoseconds).bigEndian
    pingMsg.append(Data(bytes: &nanos, count: 8))
    try await client.send(pingMsg)

    let pongData = try await client.receive(timeout: .seconds(10))
    guard pongData.first == MessageType.pong.rawValue else {
      throw WebRTCError.transferFailed(reason: "Expected pong, got type \(pongData.first ?? 0)")
    }
    let roundTripMs = Double((ContinuousClock.now - pingStart).components.attoseconds) / 1e15
    let totalMs = Double((ContinuousClock.now - totalStart).components.attoseconds) / 1e15

    candidateTask.cancel()
    remoteCandidateTask.cancel()

    logger.info("WebRTC ping complete: signaling=\(signalingMs, format: .fixed(precision: 1))ms ice=\(iceMs, format: .fixed(precision: 1))ms rtt=\(roundTripMs, format: .fixed(precision: 1))ms total=\(totalMs, format: .fixed(precision: 1))ms")

    return PingResult(
      signalingMs: signalingMs,
      iceNegotiationMs: iceMs,
      roundTripMs: roundTripMs,
      totalMs: totalMs
    )
  }

  /// Respond to a ping from a remote peer.
  /// Called by the signaling responder when it detects a ping-purpose offer.
  public static func respondToPing(
    signaling: WebRTCSignalingChannel,
    timeout: Duration = .seconds(30)
  ) async throws {
    let client = WebRTCClient()
    defer { client.close(); Task { await signaling.cleanup() } }

    logger.info("Starting WebRTC ping (responder)")

    // 1. ICE forwarding
    await client.onLocalICECandidate { candidate in
      Task { try? await signaling.sendCandidate(candidate) }
    }
    let remoteCandidateTask = Task {
      for await candidate in signaling.receiveCandidates() {
        try? await client.addICECandidate(candidate)
      }
    }

    // 2. SDP exchange
    let offerSDP = try await signaling.waitForOffer(timeout: .seconds(15))
    try await client.setRemoteDescription(offerSDP, type: .offer)
    let answerSDP = try await client.createAnswer()
    try await signaling.sendAnswer(answerSDP)

    // 3. Wait for remote data channel
    try await client.waitForRemoteDataChannel(timeout: .seconds(15))

    // 4. Receive ping, send pong
    let pingData = try await client.receive(timeout: .seconds(10))
    guard pingData.first == MessageType.ping.rawValue else {
      throw WebRTCError.transferFailed(reason: "Expected ping, got type \(pingData.first ?? 0)")
    }

    // Echo the timestamp back as pong
    var pongMsg = Data([MessageType.pong.rawValue])
    pongMsg.append(pingData.dropFirst())
    try await client.send(pongMsg)

    // Brief delay to let SCTP flush the pong
    try? await Task.sleep(for: .milliseconds(500))
    remoteCandidateTask.cancel()

    logger.info("WebRTC ping responded")
  }
}
