//
//  WebRTCMCPTransport.swift
//  Peel
//
//  Bridges MCP JSON-RPC messaging over a WebRTC data channel.
//  Supports request-response correlation and bidirectional messaging.
//
//  Part of the WebRTC-first networking replan (Plans/NETWORKING_REPLAN.md).
//

import Foundation
import os.log
import WebRTCTransfer

/// Routes MCP JSON-RPC messages over a WebRTC data channel.
/// Supports both sending requests (with response correlation) and handling incoming requests.
public actor WebRTCMCPTransport {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "MCPTransport")

  private let channel: DataChannelHandle
  private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
  private var incomingRequestHandler: (@Sendable (Data) async -> Data?)?
  private var listenTask: Task<Void, Never>?

  public init(channel: DataChannelHandle) {
    self.channel = channel
  }

  /// Start listening for incoming messages on the channel.
  public func start() {
    guard listenTask == nil else { return }
    listenTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { break }
        do {
          let data = try await self.channel.receive(timeout: .seconds(300))
          await self.routeIncoming(data)
        } catch is CancellationError {
          break
        } catch {
          self.logger.warning("MCP transport receive error: \(error)")
          break
        }
      }
    }
    logger.info("MCP transport started on channel '\(self.channel.label)'")
  }

  /// Stop the transport and cancel all pending requests.
  public func stop() {
    listenTask?.cancel()
    listenTask = nil
    for (_, cont) in pendingRequests {
      cont.resume(throwing: CancellationError())
    }
    pendingRequests.removeAll()
    logger.info("MCP transport stopped")
  }

  // MARK: - Send Request

  /// Send a JSON-RPC request and wait for the correlated response.
  public func sendRequest(_ json: Data, timeout: Duration = .seconds(30)) async throws -> Data {
    guard let parsed = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let id = parsed["id"]
    else {
      throw MCPTransportError.missingRequestId
    }
    let idString = "\(id)"

    // Send the request
    try await channel.send(json)

    // Set up timeout task
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      await self?.timeoutRequest(idString)
    }
    defer { timeoutTask.cancel() }

    // Wait for the correlated response
    return try await withCheckedThrowingContinuation { cont in
      pendingRequests[idString] = cont
    }
  }

  /// Send a JSON-RPC notification (no response expected).
  public func sendNotification(_ json: Data) async throws {
    try await channel.send(json)
  }

  // MARK: - Request Handler

  /// Set a handler for incoming JSON-RPC requests. The handler should return a response to send back,
  /// or nil to not respond.
  public func setRequestHandler(_ handler: @escaping @Sendable (Data) async -> Data?) {
    incomingRequestHandler = handler
  }

  // MARK: - Timeout

  private func timeoutRequest(_ idString: String) {
    if let cont = pendingRequests.removeValue(forKey: idString) {
      cont.resume(throwing: MCPTransportError.responseTimeout)
    }
  }

  // MARK: - Message Routing

  private func routeIncoming(_ data: Data) async {
    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      logger.warning("MCP transport: non-JSON message received")
      return
    }

    if let id = parsed["id"], (parsed["result"] != nil || parsed["error"] != nil) {
      // It's a response — route to pending request
      let idString = "\(id)"
      if let cont = pendingRequests.removeValue(forKey: idString) {
        cont.resume(returning: data)
      } else {
        logger.warning("MCP transport: response for unknown id \(idString)")
      }
    } else if parsed["method"] != nil {
      // It's a request or notification — handle it
      if let handler = incomingRequestHandler {
        if let response = await handler(data) {
          do {
            try await channel.send(response)
          } catch {
            logger.error("MCP transport: failed to send response: \(error)")
          }
        }
      }
    }
  }
}

// MARK: - Errors

public enum MCPTransportError: LocalizedError, Sendable {
  case missingRequestId
  case responseTimeout
  case channelNotAvailable

  public var errorDescription: String? {
    switch self {
    case .missingRequestId: "JSON-RPC request missing 'id' field"
    case .responseTimeout: "Timed out waiting for JSON-RPC response"
    case .channelNotAvailable: "MCP data channel is not available"
    }
  }
}
