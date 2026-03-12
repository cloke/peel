// PeerConnectionManager.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// Manages peer-to-peer TCP connections using Network framework.
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │  ARCHITECTURE INVARIANT — P2P IS ONLY FOR FILE TRANSFERS            │
// │                                                                     │
// │  This TCP connection layer exists SOLELY for transferring large      │
// │  binary data (RAG indexes, embedding files) between peers.          │
// │                                                                     │
// │  DO NOT use PeerConnectionManager for:                              │
// │    • Task dispatch (use FirebaseService.submitTask)                  │
// │    • Heartbeats or status (use Firestore worker registration)       │
// │    • Direct commands (use Firestore messaging)                      │
// │    • Any coordination message                                       │
// │                                                                     │
// │  A missing TCP connection must NEVER prevent task dispatch or        │
// │  worker communication. Firestore handles all coordination.          │
// └─────────────────────────────────────────────────────────────────────┘
//

import Foundation
import Network
import os.log

// MARK: - Connection Delegate

/// Delegate for receiving peer connection events
@MainActor
public protocol PeerConnectionDelegate: AnyObject {
  func connectionManager(_ manager: PeerConnectionManager, didConnect peer: ConnectedPeer)
  func connectionManager(_ manager: PeerConnectionManager, didDisconnect peerId: String)
  func connectionManager(_ manager: PeerConnectionManager, didReceive message: PeerMessage, from peerId: String)
  func connectionManager(_ manager: PeerConnectionManager, didFailWithError error: Error)
}

// MARK: - Connected Peer

/// Represents a connected peer with its capabilities
public struct ConnectedPeer: Identifiable, Sendable {
  public let id: String
  public let name: String              // Raw hostname
  public let capabilities: WorkerCapabilities
  public let isIncoming: Bool  // true if they connected to us
  public let connectedAt: Date
  
  /// Friendly display name - uses custom name if configured, otherwise hostname
  public var displayName: String {
    capabilities.displayName ?? name
  }
  
  public init(id: String, name: String, capabilities: WorkerCapabilities, isIncoming: Bool) {
    self.id = id
    self.name = name
    self.capabilities = capabilities
    self.isIncoming = isIncoming
    self.connectedAt = Date()
  }
}

// MARK: - Continuation Box

/// Thread-safe helper for ensuring continuation is resumed exactly once.
final class ContinuationBox: @unchecked Sendable {
  private var _hasResumed = false
  private let lock = NSLock()
  
  var hasResumed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _hasResumed
  }
  
  func tryResume() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if _hasResumed { return false }
    _hasResumed = true
    return true
  }
}

// MARK: - Peer Connection

/// Wraps an NWConnection with framing for our protocol.
actor PeerConnectionActor {
  let connection: NWConnection
  let peerId: String
  var capabilities: WorkerCapabilities?
  private let logger = Logger(subsystem: "com.peel.distributed", category: "PeerConnection")
  
  init(connection: NWConnection, peerId: String) {
    self.connection = connection
    self.peerId = peerId
  }
  
  func setCapabilities(_ caps: WorkerCapabilities) {
    self.capabilities = caps
  }
  
  func send(_ message: PeerMessage) async throws {
    let data = try JSONEncoder().encode(message)
    // Frame the message with length prefix (4 bytes, big endian)
    var length = UInt32(data.count).bigEndian
    var framedData = Data(bytes: &length, count: 4)
    framedData.append(data)
    
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: framedData, completion: .contentProcessed { error in
        if let error = error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      })
    }
  }
  
  func receiveMessage() async throws -> PeerMessage {
    // First read 4 bytes for length
    let lengthData = try await receiveExact(4)
    let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    
    // Then read the message
    let messageData = try await receiveExact(Int(length))
    return try JSONDecoder().decode(PeerMessage.self, from: messageData)
  }
  
  private func receiveExact(_ count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else if let data = data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: DistributedError.connectionFailed(deviceId: self.peerId, reason: "No data received"))
        }
      }
    }
  }
  
  func close() {
    connection.cancel()
  }
}

// MARK: - Peer Connection Manager

/// Manages all peer connections - both as server and client
@MainActor
public final class PeerConnectionManager: @unchecked Sendable {
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "ConnectionManager")
  
  /// Our capabilities
  public let capabilities: WorkerCapabilities
  
  /// The port we listen on
  public let port: UInt16
  
  /// Delegate for events
  public weak var delegate: PeerConnectionDelegate?
  
  /// The listener for incoming connections
  private var listener: NWListener?
  
  /// Connected peers by ID
  private var connections: [String: PeerConnectionActor] = [:]
  private var connectedPeers: [String: ConnectedPeer] = [:]
  /// Monotonic generation counter — each new connection gets a unique ID so
  /// the receive-loop can detect if it was replaced (dual-connect race).
  private var connectionGeneration: [String: UInt64] = [:]
  private var nextGeneration: UInt64 = 1

  /// Pending outbound NWConnections keyed by endpoint description.
  /// Used to cancel a previous attempt before retrying the same endpoint.
  private var pendingConnections: [String: NWConnection] = [:]

  /// Dedicated queue for NWConnection callbacks (keeps main thread free).
  private let connectionQueue = DispatchQueue(label: "com.peel.distributed.connections", qos: .utility)

  /// How long to wait for a TCP connection before giving up.
  private let connectionTimeout: Duration = .seconds(10)

  /// Whether we're running
  public private(set) var isRunning = false
  
  // MARK: - Initialization
  
  public init(capabilities: WorkerCapabilities? = nil, port: UInt16 = 8766) {
    self.capabilities = capabilities ?? WorkerCapabilities.current()
    self.port = port
  }
  
  // MARK: - Lifecycle
  
  /// Start listening for incoming connections
  public func start() throws {
    guard !isRunning else { return }
    
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    parameters.allowLocalEndpointReuse = true  // Allow STUN TCP connections to share port
    
    // Allow local network access
    if let options = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
      options.version = .any
    }
    
    listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    
    listener?.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        self?.handleListenerState(state)
      }
    }
    
    listener?.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        await self?.handleIncomingConnection(connection)
      }
    }
    
    listener?.start(queue: connectionQueue)
    isRunning = true
    
    logger.info("PeerConnectionManager started on port \(self.port)")
  }
  
  /// Stop the manager and close all connections
  public func stop() {
    isRunning = false
    
    listener?.cancel()
    listener = nil

    // Cancel any pending outbound connections
    for (_, conn) in pendingConnections {
      conn.cancel()
    }
    pendingConnections.removeAll()
    
    for (_, conn) in connections {
      Task {
        await conn.close()
      }
    }
    connections.removeAll()
    connectedPeers.removeAll()
    connectionGeneration.removeAll()
    
    logger.info("PeerConnectionManager stopped")
  }

  // MARK: - Connection Helpers

  /// Wait for an NWConnection to become ready, with a timeout.
  /// Cancels the connection if the timeout expires.
  private func waitForConnection(_ connection: NWConnection, endpointKey: String) async throws {
    let box = ContinuationBox()
    let queue = connectionQueue
    try await withThrowingTaskGroup(of: Void.self) { group in
      // Timeout task
      group.addTask {
        try await Task.sleep(for: self.connectionTimeout)
        if box.tryResume() {
          // Timed out — cancel the connection so the state handler fires .cancelled
          connection.cancel()
        }
      }

      // Connection task
      group.addTask {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
              if box.tryResume() {
                connection?.stateUpdateHandler = nil
                continuation.resume()
              }
            case .failed(let error):
              if box.tryResume() {
                connection?.stateUpdateHandler = nil
                continuation.resume(throwing: error)
              }
            case .waiting(let error):
              // Connection is waiting (e.g. SYN_SENT with no response).
              // Let the timeout handle it rather than waiting indefinitely.
              self.logger.debug("Connection to \(endpointKey) waiting: \(error)")
            case .cancelled:
              if box.tryResume() {
                connection?.stateUpdateHandler = nil
                continuation.resume(throwing: DistributedError.connectionFailed(
                  deviceId: "unknown", reason: "Connection timed out or cancelled"))
              }
            default:
              break
            }
          }
          connection.start(queue: queue)
        }
      }

      // Wait for the first task to complete, then cancel the other
      _ = try await group.next()
      group.cancelAll()
    }
  }
  
  // MARK: - Connection Management
  
  /// Store a new connection for a peer, closing any previous connection.
  /// Returns a generation token the receive loop uses to detect replacement.
  /// Old connections are closed after a grace period to allow in-flight
  /// transfers to drain rather than being killed immediately.
  private func storeConnection(_ conn: PeerConnectionActor, peer: ConnectedPeer) -> UInt64 {
    let peerId = peer.id
    // Close previous connection for this peer (dual-connect race protection)
    if let old = connections.removeValue(forKey: peerId) {
      logger.info("Replacing existing connection for peer \(peerId) — deferring old connection close")
      // Defer close to let the old receive loop drain any in-flight data
      // (e.g. RAG chunks). The old receive loop will exit cleanly via the
      // generation check, and the deferred close ensures the NWConnection
      // is eventually released even if the remote side doesn't close it.
      Task {
        try? await Task.sleep(for: .seconds(60))
        await old.close()
      }
    }
    connections[peerId] = conn
    connectedPeers[peerId] = peer
    let gen = nextGeneration
    nextGeneration += 1
    connectionGeneration[peerId] = gen
    return gen
  }
  
  /// Connect to a peer at the given address
  public func connect(to address: String, port: UInt16) async throws {
    let host = NWEndpoint.Host(address)
    let port = NWEndpoint.Port(rawValue: port)!
    let endpoint = NWEndpoint.hostPort(host: host, port: port)
    
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    
    let endpointKey = "\(address):\(port)"

    // Cancel any pending connection attempt to the same endpoint
    if let pending = pendingConnections.removeValue(forKey: endpointKey) {
      pending.cancel()
      logger.info("Cancelled pending connection to \(endpointKey)")
    }
    
    let connection = NWConnection(to: endpoint, using: parameters)
    pendingConnections[endpointKey] = connection
    
    // Wait for connection to be ready, with a timeout
    do {
      try await waitForConnection(connection, endpointKey: endpointKey)
    } catch {
      pendingConnections.removeValue(forKey: endpointKey)
      throw error
    }
    pendingConnections.removeValue(forKey: endpointKey)
    
    // Perform handshake
    let tempId = UUID().uuidString
    let peerConn = PeerConnectionActor(connection: connection, peerId: tempId)
    
    // Send hello
    try await peerConn.send(.hello(capabilities: capabilities))
    
    // Wait for helloAck
    let response = try await peerConn.receiveMessage()
    guard case let .helloAck(peerCapabilities) = response else {
      await peerConn.close()
      throw DistributedError.invalidMessage(reason: "Expected helloAck, got \(response.messageType)")
    }
    
    // Use their deviceId as the connection key
    let peerId = peerCapabilities.deviceId
    await peerConn.setCapabilities(peerCapabilities)
    
    let peer = ConnectedPeer(
      id: peerId,
      name: peerCapabilities.deviceName,
      capabilities: peerCapabilities,
      isIncoming: false
    )
    let gen = storeConnection(peerConn, peer: peer)
    
    // Start receive loop
    Task {
      await receiveLoop(for: peerConn, peerId: peerId, generation: gen)
    }
    
    delegate?.connectionManager(self, didConnect: peer)
    logger.info("Connected to peer: \(peerCapabilities.deviceName) (\(peerId))")
  }
  
  /// Connect to a peer via an NWEndpoint (e.g. Bonjour service endpoint).
  /// Skips the address string → host conversion, letting Network.framework
  /// resolve the endpoint directly (avoids IPv6 scope-ID issues).
  public func connect(to endpoint: NWEndpoint) async throws {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true

    let endpointKey = "\(endpoint)"

    // Cancel any pending connection attempt to the same endpoint
    if let pending = pendingConnections.removeValue(forKey: endpointKey) {
      pending.cancel()
      logger.info("Cancelled pending connection to \(endpointKey)")
    }

    let connection = NWConnection(to: endpoint, using: parameters)
    pendingConnections[endpointKey] = connection

    // Wait for connection to be ready, with a timeout
    do {
      try await waitForConnection(connection, endpointKey: endpointKey)
    } catch {
      pendingConnections.removeValue(forKey: endpointKey)
      throw error
    }
    pendingConnections.removeValue(forKey: endpointKey)

    // Perform handshake (same as address-based connect)
    let tempId = UUID().uuidString
    let peerConn = PeerConnectionActor(connection: connection, peerId: tempId)

    try await peerConn.send(.hello(capabilities: capabilities))

    let response = try await peerConn.receiveMessage()
    guard case let .helloAck(peerCapabilities) = response else {
      await peerConn.close()
      throw DistributedError.invalidMessage(reason: "Expected helloAck, got \(response.messageType)")
    }

    let peerId = peerCapabilities.deviceId
    await peerConn.setCapabilities(peerCapabilities)

    let peer = ConnectedPeer(
      id: peerId,
      name: peerCapabilities.deviceName,
      capabilities: peerCapabilities,
      isIncoming: false
    )
    let gen = storeConnection(peerConn, peer: peer)

    Task {
      await receiveLoop(for: peerConn, peerId: peerId, generation: gen)
    }

    delegate?.connectionManager(self, didConnect: peer)
    logger.info("Connected to peer via endpoint: \(peerCapabilities.deviceName) (\(peerId))")
  }
  
  /// Disconnect from a peer
  public func disconnect(from peerId: String) async {
    connectionGeneration.removeValue(forKey: peerId)
    if let conn = connections.removeValue(forKey: peerId) {
      await conn.close()
    }
    if connectedPeers.removeValue(forKey: peerId) != nil {
      delegate?.connectionManager(self, didDisconnect: peerId)
    }
  }
  
  /// Get all connected peers
  public func getConnectedPeers() -> [ConnectedPeer] {
    Array(connectedPeers.values)
  }
  
  /// Send a message to a specific peer
  public func send(_ message: PeerMessage, to peerId: String) async throws {
    guard let conn = connections[peerId] else {
      throw DistributedError.workerNotFound(deviceId: peerId)
    }
    try await conn.send(message)
  }
  
  /// Send a task request and wait for result
  /// Note: Results come back via delegate. This is a convenience for fire-and-forget dispatch.
  public func sendTask(_ request: ChainRequest, to peerId: String) async throws {
    guard let conn = connections[peerId] else {
      throw DistributedError.workerNotFound(deviceId: peerId)
    }
    
    // Send task request (result will come via receiveLoop -> delegate)
    try await conn.send(.taskRequest(request: request))
  }
  
  // MARK: - Private Methods
  
  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
      if let port = listener?.port {
        logger.info("Listener ready on port \(port.rawValue)")
      }
    case .failed(let error):
      logger.error("Listener failed: \(error)")
      delegate?.connectionManager(self, didFailWithError: error)
    case .cancelled:
      logger.info("Listener cancelled")
    default:
      break
    }
  }
  
  private func handleIncomingConnection(_ connection: NWConnection) async {
    logger.info("Incoming connection from \(String(describing: connection.endpoint))")
    
    // Wait for connection to be ready
    let box = ContinuationBox()
    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { [weak connection] state in
          switch state {
          case .ready:
            if box.tryResume() {
              connection?.stateUpdateHandler = nil
              continuation.resume()
            }
          case .failed(let error):
            if box.tryResume() {
              connection?.stateUpdateHandler = nil
              continuation.resume(throwing: error)
            }
          case .cancelled:
            if box.tryResume() {
              connection?.stateUpdateHandler = nil
              continuation.resume(throwing: DistributedError.connectionFailed(deviceId: "unknown", reason: "Cancelled"))
            }
          default:
            break
          }
        }
        connection.start(queue: connectionQueue)
      }
    } catch {
      logger.error("Incoming connection failed to become ready: \(error)")
      return
    }
    
    let tempId = UUID().uuidString
    let peerConn = PeerConnectionActor(connection: connection, peerId: tempId)
    
    do {
      // Wait for hello
      let message = try await peerConn.receiveMessage()
      guard case let .hello(peerCapabilities) = message else {
        logger.warning("Expected hello, got \(message.messageType)")
        await peerConn.close()
        return
      }
      
      // Send helloAck
      try await peerConn.send(.helloAck(capabilities: capabilities))
      
      let peerId = peerCapabilities.deviceId
      await peerConn.setCapabilities(peerCapabilities)
      
      let peer = ConnectedPeer(
        id: peerId,
        name: peerCapabilities.deviceName,
        capabilities: peerCapabilities,
        isIncoming: true
      )
      let gen = storeConnection(peerConn, peer: peer)
      
      // Start receive loop
      Task {
        await receiveLoop(for: peerConn, peerId: peerId, generation: gen)
      }
      
      delegate?.connectionManager(self, didConnect: peer)
      logger.info("Accepted connection from: \(peerCapabilities.deviceName) (\(peerId))")
      
    } catch {
      logger.error("Handshake failed: \(error)")
      await peerConn.close()
    }
  }
  
  private func receiveLoop(for conn: PeerConnectionActor, peerId: String, generation: UInt64) async {
    while isRunning {
      do {
        let message = try await conn.receiveMessage()
        await MainActor.run {
          handleMessage(message, from: peerId)
        }
      } catch {
        logger.error("Receive error from \(peerId): \(error)")
        await MainActor.run {
          // Only tear down if we're still the active connection for this peer.
          // A newer connection may have replaced us (dual-connect race).
          guard connectionGeneration[peerId] == generation else {
            logger.info("Receive loop for \(peerId) gen \(generation) exiting (superseded by gen \(self.connectionGeneration[peerId] ?? 0))")
            return
          }
          connectionGeneration.removeValue(forKey: peerId)
          connections.removeValue(forKey: peerId)
          if connectedPeers.removeValue(forKey: peerId) != nil {
            delegate?.connectionManager(self, didDisconnect: peerId)
          }
        }
        break
      }
    }
  }
  
  private func handleMessage(_ message: PeerMessage, from peerId: String) {
    switch message {
    case .taskResult(let result):
      logger.info("Received result for task \(result.requestId)")
      // Forward to delegate for handling
      delegate?.connectionManager(self, didReceive: message, from: peerId)
      
    case .heartbeat(let status):
      // Update peer status
      logger.debug("Heartbeat from \(peerId): \(status.state.rawValue)")
      delegate?.connectionManager(self, didReceive: message, from: peerId)
      
    default:
      // Forward to delegate
      delegate?.connectionManager(self, didReceive: message, from: peerId)
    }
  }
}
