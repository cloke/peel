// LocalNetworkActorSystem.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// A DistributedActorSystem implementation for LAN communication using WebSocket.

import Foundation
import Distributed
import os.log

// MARK: - Actor Identity

/// Unique identifier for a distributed actor in the local network
public struct LocalNetworkActorID: Hashable, Sendable, Codable {
  public let deviceId: String
  public let actorType: String
  public let instanceId: UUID
  
  public init(deviceId: String, actorType: String, instanceId: UUID = UUID()) {
    self.deviceId = deviceId
    self.actorType = actorType
    self.instanceId = instanceId
  }
  
  /// Create an ID for an actor on the local device
  public static func local(actorType: String) -> LocalNetworkActorID {
    LocalNetworkActorID(
      deviceId: LocalNetworkActorSystem.currentDeviceId,
      actorType: actorType
    )
  }
}

// MARK: - Invocation Encoder/Decoder

/// Encodes distributed method invocations for wire transmission
public struct LocalNetworkInvocationEncoder: DistributedTargetInvocationEncoder {
  public typealias SerializationRequirement = Codable
  
  var methodName: String = ""
  var arguments: [Data] = []
  
  public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
    // Generic substitutions not needed for our simple protocol
  }
  
  public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
    let data = try JSONEncoder().encode(argument.value)
    arguments.append(data)
  }
  
  public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {
    // Return type recorded implicitly in response
  }
  
  public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
    // Error type recorded implicitly
  }
  
  public mutating func doneRecording() throws {
    // All arguments recorded
  }
}

/// Decodes distributed method invocations from wire format
public struct LocalNetworkInvocationDecoder: DistributedTargetInvocationDecoder {
  public typealias SerializationRequirement = Codable
  
  var arguments: [Data]
  var argumentIndex = 0
  
  public init(arguments: [Data]) {
    self.arguments = arguments
  }
  
  public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
    []
  }
  
  public mutating func decodeNextArgument<Value: Codable>() throws -> Value {
    guard argumentIndex < arguments.count else {
      throw DistributedError.serializationFailed(reason: "Not enough arguments")
    }
    let data = arguments[argumentIndex]
    argumentIndex += 1
    return try JSONDecoder().decode(Value.self, from: data)
  }
  
  public mutating func decodeReturnType() throws -> Any.Type? {
    nil
  }
  
  public mutating func decodeErrorType() throws -> Any.Type? {
    nil
  }
}

/// Encodes results for wire transmission
public struct LocalNetworkResultHandler: DistributedTargetInvocationResultHandler {
  public typealias SerializationRequirement = Codable
  
  let completion: (Result<Data, Error>) -> Void
  
  public func onReturn<Success: Codable>(value: Success) async throws {
    let data = try JSONEncoder().encode(value)
    completion(.success(data))
  }
  
  public func onReturnVoid() async throws {
    // Encode empty success
    completion(.success(Data()))
  }
  
  public func onThrow<Err: Error>(error: Err) async throws {
    completion(.failure(error))
  }
}

// MARK: - Wire Protocol

/// A method invocation sent over the wire
struct WireInvocation: Codable {
  let callId: UUID
  let targetId: LocalNetworkActorID
  let methodName: String
  let arguments: [Data]
}

/// A response to a method invocation
struct WireResponse: Codable {
  let callId: UUID
  let success: Bool
  let resultData: Data?
  let errorMessage: String?
}

// MARK: - Internal State Actor

/// Internal actor for managing state safely in async contexts
@available(macOS 15.0, iOS 18.0, *)
private actor ActorSystemState {
  var peers: [String: PeerConnection] = [:]
  var localActors: [LocalNetworkActorID: any DistributedActor] = [:]
  var pendingCalls: [UUID: CheckedContinuation<Data, Error>] = [:]
  
  func addPeer(_ peer: PeerConnection, for deviceId: String) {
    peers[deviceId] = peer
  }
  
  func removePeer(for deviceId: String) -> PeerConnection? {
    peers.removeValue(forKey: deviceId)
  }
  
  func getPeer(for deviceId: String) -> PeerConnection? {
    peers[deviceId]
  }
  
  func getAllPeers() -> [PeerConnection] {
    Array(peers.values)
  }
  
  var peerDeviceIds: [String] {
    Array(peers.keys)
  }
  
  func addLocalActor(_ actor: any DistributedActor, for id: LocalNetworkActorID) {
    localActors[id] = actor
  }
  
  func removeLocalActor(for id: LocalNetworkActorID) {
    localActors.removeValue(forKey: id)
  }
  
  func getLocalActor<Act: DistributedActor>(for id: LocalNetworkActorID) -> Act? {
    localActors[id] as? Act
  }
  
  func getAnyLocalActor(for id: LocalNetworkActorID) -> (any DistributedActor)? {
    localActors[id]
  }
  
  func addPendingCall(_ continuation: CheckedContinuation<Data, Error>, for callId: UUID) {
    pendingCalls[callId] = continuation
  }
  
  func removePendingCall(for callId: UUID) -> CheckedContinuation<Data, Error>? {
    pendingCalls.removeValue(forKey: callId)
  }
  
  func clearAllPeers() {
    for peer in peers.values {
      peer.disconnect()
    }
    peers.removeAll()
  }
}

// MARK: - Actor System

/// A distributed actor system for LAN communication
@available(macOS 15.0, iOS 18.0, *)
public final class LocalNetworkActorSystem: DistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = LocalNetworkActorID
  public typealias InvocationEncoder = LocalNetworkInvocationEncoder
  public typealias InvocationDecoder = LocalNetworkInvocationDecoder
  public typealias ResultHandler = LocalNetworkResultHandler
  public typealias SerializationRequirement = Codable
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "ActorSystem")
  
  /// The port this system listens on
  public let port: UInt16
  
  /// Current device ID (persistent across launches)
  public static var currentDeviceId: String {
    WorkerCapabilities.current().deviceId
  }
  
  /// Internal state actor for thread-safe state management
  private let state = ActorSystemState()
  
  /// WebSocket server task
  private var serverTask: URLSessionWebSocketTask?
  private var serverSession: URLSession?
  
  /// Whether the system is running
  public private(set) var isRunning = false
  
  // MARK: - Initialization
  
  public init(port: UInt16 = 8766) {
    self.port = port
    logger.info("LocalNetworkActorSystem initialized on port \(port)")
  }
  
  // MARK: - Lifecycle
  
  /// Start listening for connections
  public func start() async throws {
    guard !isRunning else { return }
    
    // Note: URLSession doesn't support WebSocket server directly
    // We'll use Network framework for the server side
    // For now, this is a client-only implementation
    // Server support will be added via NWListener in BonjourDiscoveryService
    
    isRunning = true
    logger.info("Actor system started")
  }
  
  /// Stop the actor system
  public func stop() async {
    isRunning = false
    await state.clearAllPeers()
    logger.info("Actor system stopped")
  }
  
  // MARK: - Peer Management
  
  /// Connect to a peer at the given address
  public func connect(to address: String, port: UInt16, deviceId: String) async throws {
    let url = URL(string: "ws://\(address):\(port)/peel")!
    let session = URLSession(configuration: .default)
    let task = session.webSocketTask(with: url)
    
    let connection = PeerConnection(
      deviceId: deviceId,
      address: address,
      port: port,
      task: task
    )
    
    await state.addPeer(connection, for: deviceId)
    
    task.resume()
    
    // Start receiving messages
    Task {
      await receiveMessages(from: connection)
    }
    
    logger.info("Connected to peer: \(deviceId) at \(address):\(port)")
  }
  
  /// Disconnect from a peer
  public func disconnect(from deviceId: String) async {
    if let peer = await state.removePeer(for: deviceId) {
      peer.disconnect()
    }
    logger.info("Disconnected from peer: \(deviceId)")
  }
  
  /// Get all connected peers
  public func getConnectedPeers() async -> [String] {
    await state.peerDeviceIds
  }
  
  // MARK: - DistributedActorSystem Protocol
  
  public func resolve<Act>(id: LocalNetworkActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == LocalNetworkActorID
  {
    // Note: This is synchronous, so we use a detached task to access actor state
    // This is a limitation - in production, consider caching locally
    // For now, return nil and require explicit resolution via async method
    return nil
  }
  
  /// Async version of resolve for when you can await
  public func resolveAsync<Act>(id: LocalNetworkActorID, as actorType: Act.Type) async -> Act?
    where Act: DistributedActor, Act.ID == LocalNetworkActorID
  {
    await state.getLocalActor(for: id)
  }
  
  public func assignID<Act>(_ actorType: Act.Type) -> LocalNetworkActorID
    where Act: DistributedActor, Act.ID == LocalNetworkActorID
  {
    LocalNetworkActorID.local(actorType: String(describing: actorType))
  }
  
  public func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == LocalNetworkActorID
  {
    // Use Task to bridge sync -> async
    Task {
      await state.addLocalActor(actor, for: actor.id)
      logger.debug("Actor ready: \(actor.id.actorType) - \(actor.id.instanceId)")
    }
  }
  
  public func resignID(_ id: LocalNetworkActorID) {
    Task {
      await state.removeLocalActor(for: id)
      logger.debug("Actor resigned: \(id.actorType) - \(id.instanceId)")
    }
  }
  
  public func makeInvocationEncoder() -> LocalNetworkInvocationEncoder {
    LocalNetworkInvocationEncoder()
  }
  
  // MARK: - Remote Calls
  
  public func remoteCall<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing: Err.Type,
    returning: Res.Type
  ) async throws -> Res
    where Act: DistributedActor,
          Act.ID == LocalNetworkActorID,
          Err: Error,
          Res: Codable
  {
    let actorId = actor.id
    
    // Find the peer for this actor
    guard let peer = await state.getPeer(for: actorId.deviceId) else {
      throw DistributedError.workerNotFound(deviceId: actorId.deviceId)
    }
    
    // Create the wire invocation
    let callId = UUID()
    let wireInvocation = WireInvocation(
      callId: callId,
      targetId: actorId,
      methodName: target.identifier,
      arguments: invocation.arguments
    )
    
    // Encode and send
    let data = try JSONEncoder().encode(wireInvocation)
    
    // Set up continuation for response
    let resultData: Data = try await withCheckedThrowingContinuation { continuation in
      Task {
        await state.addPendingCall(continuation, for: callId)
        
        do {
          try await peer.send(data)
        } catch {
          if let cont = await state.removePendingCall(for: callId) {
            cont.resume(throwing: error)
          }
        }
      }
    }
    
    // Decode result
    return try JSONDecoder().decode(Res.self, from: resultData)
  }
  
  public func remoteCallVoid<Act, Err>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing: Err.Type
  ) async throws
    where Act: DistributedActor,
          Act.ID == LocalNetworkActorID,
          Err: Error
  {
    // Same as remoteCall but ignore result
    let _: Data = try await remoteCall(
      on: actor,
      target: target,
      invocation: &invocation,
      throwing: throwing,
      returning: Data.self
    )
  }
  
  // MARK: - Message Handling
  
  private func receiveMessages(from peer: PeerConnection) async {
    while peer.isConnected {
      do {
        let message = try await peer.receive()
        await handleMessage(message, from: peer)
      } catch {
        logger.error("Error receiving from \(peer.deviceId): \(error)")
        break
      }
    }
  }
  
  private func handleMessage(_ data: Data, from peer: PeerConnection) async {
    // Try to decode as invocation
    if let invocation = try? JSONDecoder().decode(WireInvocation.self, from: data) {
      await handleInvocation(invocation, from: peer)
      return
    }
    
    // Try to decode as response
    if let response = try? JSONDecoder().decode(WireResponse.self, from: data) {
      await handleResponse(response)
      return
    }
    
    logger.warning("Unknown message type from \(peer.deviceId)")
  }
  
  private func handleInvocation(_ invocation: WireInvocation, from peer: PeerConnection) async {
    // Find the local actor
    guard let _ = await state.getAnyLocalActor(for: invocation.targetId) else {
      // Send error response
      let response = WireResponse(
        callId: invocation.callId,
        success: false,
        resultData: nil,
        errorMessage: "Actor not found: \(invocation.targetId)"
      )
      if let data = try? JSONEncoder().encode(response) {
        try? await peer.send(data)
      }
      return
    }
    
    // Execute the invocation
    // Note: This requires the actor to conform to a known protocol
    // For now, we'll need to register handlers for each actor type
    // This is a limitation of Swift's distributed actors - we can't dynamically invoke
    
    // TODO: Implement executeDistributedTarget when we have concrete actor types
    let response = WireResponse(
      callId: invocation.callId,
      success: false,
      resultData: nil,
      errorMessage: "Dynamic invocation not yet implemented"
    )
    
    if let data = try? JSONEncoder().encode(response) {
      try? await peer.send(data)
    }
  }
  
  private func handleResponse(_ response: WireResponse) async {
    guard let continuation = await state.removePendingCall(for: response.callId) else {
      logger.warning("No pending call for response: \(response.callId)")
      return
    }
    
    if response.success, let data = response.resultData {
      continuation.resume(returning: data)
    } else {
      let error = DistributedError.taskExecutionFailed(
        taskId: response.callId,
        reason: response.errorMessage ?? "Unknown error"
      )
      continuation.resume(throwing: error)
    }
  }
}

// MARK: - Peer Connection

/// Represents a WebSocket connection to a peer
@available(macOS 15.0, iOS 18.0, *)
private final class PeerConnection: @unchecked Sendable {
  let deviceId: String
  let address: String
  let port: UInt16
  let task: URLSessionWebSocketTask
  
  private(set) var isConnected = true
  
  init(deviceId: String, address: String, port: UInt16, task: URLSessionWebSocketTask) {
    self.deviceId = deviceId
    self.address = address
    self.port = port
    self.task = task
  }
  
  func send(_ data: Data) async throws {
    let message = URLSessionWebSocketTask.Message.data(data)
    try await task.send(message)
  }
  
  func receive() async throws -> Data {
    let message = try await task.receive()
    switch message {
    case .data(let data):
      return data
    case .string(let string):
      return Data(string.utf8)
    @unknown default:
      throw DistributedError.invalidMessage(reason: "Unknown message type")
    }
  }
  
  func disconnect() {
    isConnected = false
    task.cancel(with: .goingAway, reason: nil)
  }
}
