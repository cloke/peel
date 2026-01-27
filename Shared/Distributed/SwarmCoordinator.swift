// SwarmCoordinator.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// Coordinates the distributed swarm - manages workers and task dispatch.

import Foundation
import os.log

// MARK: - Swarm Mode

/// The role of this Peel instance in the swarm
public enum SwarmRole: String, Sendable {
  case brain     // Coordinates work, dispatches tasks
  case worker    // Executes tasks, reports back
  case hybrid    // Both brain and worker
}

// MARK: - Swarm Event

/// Events emitted by the swarm coordinator
public enum SwarmEvent: Sendable {
  case workerConnected(ConnectedPeer)
  case workerDisconnected(String)
  case taskReceived(ChainRequest)
  case taskStarted(UUID)
  case taskCompleted(ChainResult)
  case taskFailed(UUID, Error)
}

// MARK: - Swarm Delegate

/// Delegate for swarm events
@MainActor
public protocol SwarmCoordinatorDelegate: AnyObject {
  func swarmCoordinator(_ coordinator: SwarmCoordinator, didEmit event: SwarmEvent)
  func swarmCoordinator(_ coordinator: SwarmCoordinator, shouldExecute request: ChainRequest) -> Bool
}

// MARK: - Swarm Coordinator

/// Main coordinator for distributed Peel swarm
@MainActor
@Observable
public final class SwarmCoordinator {
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "SwarmCoordinator")
  
  // MARK: - Public State
  
  /// Our role in the swarm
  public let role: SwarmRole
  
  /// Our capabilities
  public let capabilities: WorkerCapabilities
  
  /// Whether the swarm is active
  public private(set) var isActive = false
  
  /// Connected workers (for brain mode)
  public private(set) var connectedWorkers: [ConnectedPeer] = []
  
  /// Current task being executed (for worker mode)
  public private(set) var currentTask: ChainRequest?
  
  /// Tasks completed since start
  public private(set) var tasksCompleted = 0
  
  /// Tasks failed since start
  public private(set) var tasksFailed = 0
  
  /// Discovered peers (for debugging - from Bonjour discovery)
  public var discoveredPeers: [DiscoveredPeer] {
    Array(discoveryService?.discoveredPeers.values ?? [:].values)
  }
  
  // MARK: - Private State
  
  /// Connection manager
  private var connectionManager: PeerConnectionManager?
  
  /// Discovery service
  private var discoveryService: BonjourDiscoveryService?
  
  /// Delegate
  public weak var delegate: SwarmCoordinatorDelegate?
  
  /// Chain executor for worker mode
  private var chainExecutor: ChainExecutorProtocol?
  
  // MARK: - Initialization
  
  public init(
    role: SwarmRole,
    capabilities: WorkerCapabilities? = nil,
    chainExecutor: ChainExecutorProtocol? = nil
  ) {
    self.role = role
    self.capabilities = capabilities ?? WorkerCapabilities.current()
    self.chainExecutor = chainExecutor
  }
  
  // MARK: - Lifecycle
  
  /// Start the swarm coordinator
  public func start(port: UInt16 = 8766) throws {
    guard !isActive else { return }
    
    // Create connection manager
    connectionManager = PeerConnectionManager(capabilities: capabilities, port: port)
    connectionManager?.delegate = self
    try connectionManager?.start()
    
    // Create and start discovery
    discoveryService = BonjourDiscoveryService()
    discoveryService?.delegate = self
    
    // Start advertising ourselves
    try discoveryService?.startAdvertising(capabilities: capabilities, port: port)
    
    // Start discovering peers
    discoveryService?.startDiscovery()
    
    isActive = true
    logger.info("SwarmCoordinator started as \(self.role.rawValue)")
  }
  
  /// Stop the swarm coordinator
  public func stop() {
    isActive = false
    
    discoveryService?.stopAdvertising()
    discoveryService?.stopDiscovery()
    discoveryService = nil
    
    connectionManager?.stop()
    connectionManager = nil
    
    connectedWorkers.removeAll()
    currentTask = nil
    
    logger.info("SwarmCoordinator stopped")
  }
  
  // MARK: - Brain Methods
  
  /// Connect to a worker at the given address (brain mode)
  public func connectToWorker(address: String, port: UInt16 = 8766) async throws {
    guard role == .brain || role == .hybrid else {
      throw DistributedError.actorSystemNotReady
    }
    
    try await connectionManager?.connect(to: address, port: port)
  }
  
  /// Dispatch a chain to the best available worker (brain mode)
  public func dispatchChain(_ request: ChainRequest) async throws -> ChainResult {
    guard role == .brain || role == .hybrid else {
      throw DistributedError.actorSystemNotReady
    }
    
    // Find best worker
    guard let worker = selectWorker(for: request) else {
      throw DistributedError.noWorkersAvailable
    }
    
    logger.info("Dispatching task \(request.id) to worker \(worker.name)")
    
    // Send task and wait for result
    try await connectionManager?.send(.taskRequest(request: request), to: worker.id)
    
    // For now, we'll implement a simple polling approach
    // In a full implementation, we'd use continuations properly
    
    // Wait for result with timeout
    let deadline = Date().addingTimeInterval(TimeInterval(request.timeoutSeconds))
    while Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
      // Result will come via delegate
    }
    
    throw DistributedError.taskTimeout(taskId: request.id)
  }
  
  /// Select the best worker for a request
  private func selectWorker(for request: ChainRequest) -> ConnectedPeer? {
    let candidates = connectedWorkers.filter { peer in
      // Check capabilities
      if let required = request.requiredCapabilities {
        return required.isSatisfiedBy(peer.capabilities)
      }
      return true
    }
    
    // Prefer workers with more resources
    return candidates.max { a, b in
      a.capabilities.gpuCores < b.capabilities.gpuCores
    }
  }
  
  // MARK: - Worker Methods
  
  /// Handle incoming task (worker mode)
  private func handleTaskRequest(_ request: ChainRequest, from peerId: String) async {
    guard role == .worker || role == .hybrid else { return }
    
    // Check with delegate if we should execute
    if let delegate = delegate, !delegate.swarmCoordinator(self, shouldExecute: request) {
      // Reject task
      try? await connectionManager?.send(
        .taskRejected(taskId: request.id, reason: "Worker declined"),
        to: peerId
      )
      return
    }
    
    currentTask = request
    delegate?.swarmCoordinator(self, didEmit: .taskReceived(request))
    delegate?.swarmCoordinator(self, didEmit: .taskStarted(request.id))
    
    // Accept task
    try? await connectionManager?.send(.taskAccepted(taskId: request.id), to: peerId)
    
    // Execute
    let startTime = Date()
    var result: ChainResult
    
    do {
      let outputs: [ChainOutput]
      
      if let executor = chainExecutor {
        outputs = try await executor.execute(request: request)
      } else {
        // Mock execution
        logger.warning("No chain executor, returning mock result")
        try await Task.sleep(for: .seconds(2))
        outputs = [
          ChainOutput(type: .text, name: "mock", content: "Mock result for: \(request.prompt)")
        ]
      }
      
      let duration = Date().timeIntervalSince(startTime)
      result = ChainResult(
        requestId: request.id,
        status: .completed,
        outputs: outputs,
        duration: duration,
        workerDeviceId: capabilities.deviceId,
        workerDeviceName: capabilities.deviceName
      )
      tasksCompleted += 1
      
    } catch {
      let duration = Date().timeIntervalSince(startTime)
      result = ChainResult(
        requestId: request.id,
        status: .failed,
        duration: duration,
        workerDeviceId: capabilities.deviceId,
        workerDeviceName: capabilities.deviceName,
        errorMessage: error.localizedDescription
      )
      tasksFailed += 1
      delegate?.swarmCoordinator(self, didEmit: .taskFailed(request.id, error))
    }
    
    // Send result
    try? await connectionManager?.send(.taskResult(result: result), to: peerId)
    
    currentTask = nil
    delegate?.swarmCoordinator(self, didEmit: .taskCompleted(result))
    
    logger.info("Task \(request.id) completed: \(result.status.rawValue)")
  }
}

// MARK: - PeerConnectionDelegate

extension SwarmCoordinator: PeerConnectionDelegate {
  public func connectionManager(_ manager: PeerConnectionManager, didConnect peer: ConnectedPeer) {
    connectedWorkers.append(peer)
    delegate?.swarmCoordinator(self, didEmit: .workerConnected(peer))
    logger.info("Worker connected: \(peer.name)")
  }
  
  public func connectionManager(_ manager: PeerConnectionManager, didDisconnect peerId: String) {
    connectedWorkers.removeAll { $0.id == peerId }
    delegate?.swarmCoordinator(self, didEmit: .workerDisconnected(peerId))
    logger.info("Worker disconnected: \(peerId)")
  }
  
  public func connectionManager(_ manager: PeerConnectionManager, didReceive message: PeerMessage, from peerId: String) {
    switch message {
    case .taskRequest(let request):
      Task {
        await handleTaskRequest(request, from: peerId)
      }
      
    case .taskProgress(let taskId, let progress, let message):
      logger.debug("Task \(taskId) progress: \(progress) - \(message ?? "")")
      
    case .taskResult(let result):
      delegate?.swarmCoordinator(self, didEmit: .taskCompleted(result))
      
    default:
      logger.debug("Received message: \(message.messageType) from \(peerId)")
    }
  }
  
  public func connectionManager(_ manager: PeerConnectionManager, didFailWithError error: Error) {
    logger.error("Connection error: \(error)")
  }
}

// MARK: - BonjourDiscoveryDelegate

extension SwarmCoordinator: BonjourDiscoveryDelegate {
  public func discoveryService(_ service: BonjourDiscoveryService, didDiscover peer: DiscoveredPeer) {
    // Auto-connect to discovered peers if we're the brain
    guard role == .brain || role == .hybrid else { return }
    
    // Skip if already connected
    if connectedWorkers.contains(where: { $0.id == peer.id }) { return }
    
    logger.info("Discovered peer: \(peer.name), resolving...")
    
    Task {
      do {
        let resolved = try await service.resolvePeer(peer.id)
        if let address = resolved.resolvedAddress, let port = resolved.resolvedPort {
          try await connectionManager?.connect(to: address, port: port)
        }
      } catch {
        logger.error("Failed to connect to discovered peer: \(error)")
      }
    }
  }
  
  public func discoveryService(_ service: BonjourDiscoveryService, didLose peerId: String) {
    logger.info("Lost peer: \(peerId)")
  }
  
  public func discoveryService(_ service: BonjourDiscoveryService, didResolve peer: DiscoveredPeer) {
    logger.debug("Resolved peer: \(peer.name) at \(peer.resolvedAddress ?? "?")")
  }
  
  public func discoveryService(_ service: BonjourDiscoveryService, didFailWithError error: Error) {
    logger.error("Discovery error: \(error)")
  }
}
