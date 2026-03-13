//
//  DataChannelHandle.swift
//  WebRTCTransfer
//
//  Self-contained wrapper for a single RTCDataChannel with async send/receive
//  and backpressure. Each handle manages its own message buffer independently,
//  enabling multiple named channels on one RTCPeerConnection.
//

import Foundation
import WebRTC
import os.log

// MARK: - Channel Configuration

/// Configuration for creating a data channel.
public struct DataChannelConfig: Sendable {
  public var ordered: Bool
  public var maxRetransmits: Int?

  /// Reliable, ordered delivery (default for MCP, transfer, chat).
  public static let reliable = DataChannelConfig(ordered: true, maxRetransmits: nil)
  /// Unreliable, unordered delivery (heartbeats, pings).
  public static let unreliable = DataChannelConfig(ordered: false, maxRetransmits: 0)

  public init(ordered: Bool = true, maxRetransmits: Int? = nil) {
    self.ordered = ordered
    self.maxRetransmits = maxRetransmits
  }
}

// MARK: - DataChannelHandle

/// Wraps a single RTCDataChannel with async send/receive and backpressure.
public final class DataChannelHandle: NSObject, @unchecked Sendable {
  private let logger = Logger(subsystem: "com.peel.webrtc", category: "ChannelHandle")

  public let label: String

  /// The underlying RTCDataChannel.
  public let channel: RTCDataChannel

  private let state = HandleState()

  /// Counter for delegate receive callbacks (incremented on WebRTC's signaling thread).
  private var _delegateRecvCount: Int = 0

  /// Ordered message stream from delegate callbacks.
  /// AsyncStream.yield() is thread-safe and preserves insertion order,
  /// ensuring messages reach the actor in the same order WebRTC delivered them.
  private var messageContinuation: AsyncStream<Data>.Continuation?
  private var messageForwardingTask: Task<Void, Never>?

  // MARK: - State Actor

  private actor HandleState {
    var messageBuffer: [Data] = []
    var messageWaiter: CheckedContinuation<Data, Error>?
    var closedError: Error?
    var openContinuation: CheckedContinuation<Void, Error>?
    var bufferDrainContinuation: CheckedContinuation<Void, Error>?
    /// Monotonic generation counter for messageWaiter. Prevents stale cancel
    /// tasks from resuming a newer continuation after a receive timeout.
    var waiterGeneration: UInt64 = 0

    func onOpen() {
      openContinuation?.resume()
      openContinuation = nil
    }

    func waitForOpen() async throws {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          if Task.isCancelled {
            cont.resume(throwing: CancellationError())
          } else {
            openContinuation = cont
          }
        }
      } onCancel: {
        Task { [weak self] in await self?.cancelOpenWaiter() }
      }
    }

    func cancelOpenWaiter() {
      openContinuation?.resume(throwing: CancellationError())
      openContinuation = nil
    }

    func onMessage(_ data: Data) {
      if let waiter = messageWaiter {
        messageWaiter = nil
        waiter.resume(returning: data)
      } else {
        messageBuffer.append(data)
      }
    }

    func onClosed(_ error: Error) {
      closedError = error
      messageWaiter?.resume(throwing: error)
      messageWaiter = nil
      openContinuation?.resume(throwing: error)
      openContinuation = nil
      bufferDrainContinuation?.resume(throwing: error)
      bufferDrainContinuation = nil
    }

    func receiveMessage() async throws -> Data {
      if let error = closedError { throw error }
      if !messageBuffer.isEmpty {
        return messageBuffer.removeFirst()
      }
      waiterGeneration &+= 1
      let myGeneration = waiterGeneration
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
          if !messageBuffer.isEmpty {
            cont.resume(returning: messageBuffer.removeFirst())
          } else if let error = closedError {
            cont.resume(throwing: error)
          } else if Task.isCancelled {
            cont.resume(throwing: CancellationError())
          } else {
            messageWaiter = cont
          }
        }
      } onCancel: {
        Task { [weak self] in await self?.cancelMessageWaiter(generation: myGeneration) }
      }
    }

    func cancelMessageWaiter(generation: UInt64) {
      guard generation == waiterGeneration else {
        // Stale cancel from a previous receive() — ignore to avoid killing
        // the current waiter.
        return
      }
      messageWaiter?.resume(throwing: CancellationError())
      messageWaiter = nil
    }

    func onBufferDrained() {
      bufferDrainContinuation?.resume()
      bufferDrainContinuation = nil
    }

    func waitForBufferDrain() async throws {
      if let error = closedError { throw error }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          if let error = closedError {
            cont.resume(throwing: error)
          } else if Task.isCancelled {
            cont.resume(throwing: CancellationError())
          } else {
            bufferDrainContinuation = cont
          }
        }
      } onCancel: {
        Task { [weak self] in await self?.cancelBufferDrainWaiter() }
      }
    }

    func cancelBufferDrainWaiter() {
      bufferDrainContinuation?.resume(throwing: CancellationError())
      bufferDrainContinuation = nil
    }
  }

  // MARK: - Init

  public init(channel: RTCDataChannel) {
    self.label = channel.label
    self.channel = channel
    super.init()

    // Set up an ordered message forwarding pipeline.
    // The delegate callback yields to the AsyncStream (thread-safe, preserves order),
    // and a single forwarding task drains the stream into the actor sequentially.
    let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    self.messageContinuation = continuation
    let state = self.state
    self.messageForwardingTask = Task {
      for await data in stream {
        await state.onMessage(data)
      }
    }

    channel.delegate = self
  }

  // MARK: - Properties

  public var isOpen: Bool {
    channel.readyState == .open
  }

  // MARK: - Send

  private static let bufferHighWaterMark: UInt64 = 256 * 1024
  private static let bufferLowWaterMark: UInt64 = 64 * 1024
  private static let bufferDrainTimeout: Duration = .seconds(10)
  private static let maxBufferDrainWaits = 3

  /// Send binary data with backpressure.
  public func send(_ data: Data) async throws {
    guard channel.readyState == .open else {
      throw WebRTCError.dataChannelNotOpen
    }

    var drainWaits = 0
    while channel.bufferedAmount > Self.bufferHighWaterMark {
      drainWaits += 1
      let buffered = channel.bufferedAmount

      logger.debug("[DCH-\(self.label)] send backpressure wait \(drainWaits) buffered=\(buffered)")

      let drained = (try? await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
          try await self.state.waitForBufferDrain()
          return true
        }
        group.addTask {
          try await Task.sleep(for: Self.bufferDrainTimeout)
          return false
        }
        defer { group.cancelAll() }
        return try await group.next() ?? false
      }) ?? false

      guard drained else {
        let stillBuffered = channel.bufferedAmount
        let state = String(describing: channel.readyState)
        logger.error(
          "[DCH-\(self.label)] buffer drain timeout buffered=\(stillBuffered) readyState=\(state), failing send"
        )
        if channel.readyState == .closed {
          throw WebRTCError.dataChannelClosed
        }
        throw WebRTCError.transferFailed(reason: "Data channel backpressure timeout on '\(label)'")
      }

      guard drainWaits < Self.maxBufferDrainWaits else {
        let stillBuffered = channel.bufferedAmount
        logger.error("[DCH-\(self.label)] excessive backpressure waits buffered=\(stillBuffered), failing send")
        throw WebRTCError.transferFailed(reason: "Data channel remained backpressured on '\(label)'")
      }
    }

    let buffer = RTCDataBuffer(data: data, isBinary: true)
    guard channel.sendData(buffer) else {
      throw WebRTCError.sendFailed
    }
  }

  // MARK: - Receive

  /// Receive one message with timeout.
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

  /// Wait for the channel to reach the open state.
  public func waitForOpen(timeout: Duration = .seconds(30)) async throws {
    if channel.readyState == .open { return }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await self.state.waitForOpen() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WebRTCError.dataChannelTimeout
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }
}

// MARK: - RTCDataChannelDelegate

extension DataChannelHandle: RTCDataChannelDelegate {
  public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    if dataChannel.readyState == .open {
      Task { await state.onOpen() }
    } else if dataChannel.readyState == .closed {
      messageContinuation?.finish()
      messageForwardingTask?.cancel()
      Task { await state.onClosed(WebRTCError.dataChannelClosed) }
    }
  }

  public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    let size = buffer.data.count
    _delegateRecvCount += 1
    let seq = _delegateRecvCount
    // Log the first 5 delegate callbacks and any large message in the first 120
    if seq <= 5 || (seq <= 120 && size > 100_000) {
      logger.info("[DCH-\(self.label)] delegate recv seq=\(seq) size=\(size)")
    }
    messageContinuation?.yield(buffer.data)
  }



  public func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
    if amount <= Self.bufferLowWaterMark {
      Task { await state.onBufferDrained() }
    }
  }
}
