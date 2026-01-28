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
  
  /// Shared instance for app-wide access
  public static let shared = SwarmCoordinator()
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "SwarmCoordinator")
  
  // MARK: - Public State
  
  /// Our role in the swarm (set when starting)
  public private(set) var role: SwarmRole = .worker
  
  /// Our capabilities
  public private(set) var capabilities: WorkerCapabilities = WorkerCapabilities.current()
  
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
  
  /// Completed task results (most recent first, capped at 50)
  public private(set) var completedResults: [ChainResult] = []
  
  /// Maximum number of results to keep
  private let maxStoredResults = 50
  
  /// Pending direct command continuations (for awaiting results)
  private var pendingDirectCommands: [UUID: CheckedContinuation<DirectCommandResult, Never>] = [:]
  
  /// Result from a direct command execution
  public struct DirectCommandResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let error: String?
  }
  
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
  
  /// Pending task continuations (for async result delivery)
  private var pendingTasks: [UUID: CheckedContinuation<ChainResult, Error>] = [:]
  
  // MARK: - Initialization
  
  /// Private init for singleton pattern
  private init() {}
  
  /// Configure with a chain executor (for worker mode task execution)
  public func configure(chainExecutor: ChainExecutorProtocol?) {
    self.chainExecutor = chainExecutor
  }
  
  // MARK: - Lifecycle
  
  /// Start the swarm coordinator with the given role
  public func start(role: SwarmRole, port: UInt16 = 8766) throws {
    guard !isActive else { return }
    
    self.role = role
    self.capabilities = WorkerCapabilities.current()
    
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
    
    // Send task and wait for result using continuation
    let result: ChainResult = try await withCheckedThrowingContinuation { continuation in
      // Store continuation for when result arrives
      pendingTasks[request.id] = continuation
      
      // Send task to worker
      Task {
        do {
          try await connectionManager?.send(.taskRequest(request: request), to: worker.id)
        } catch {
          pendingTasks.removeValue(forKey: request.id)
          continuation.resume(throwing: error)
        }
      }
      
      // Setup timeout
      Task {
        try? await Task.sleep(for: .seconds(Double(request.timeoutSeconds)))
        if let cont = pendingTasks.removeValue(forKey: request.id) {
          cont.resume(throwing: DistributedError.taskTimeout(taskId: request.id))
        }
      }
    }
    
    return result
  }
  
  /// Dispatch a chain to a specific worker (fire-and-forget for updates)
  public func dispatchToWorker(_ request: ChainRequest, workerId: String) async throws {
    guard role == .brain || role == .hybrid else {
      throw DistributedError.actorSystemNotReady
    }
    
    guard connectedWorkers.contains(where: { $0.id == workerId }) else {
      throw DistributedError.noWorkersAvailable
    }
    
    logger.info("Dispatching task \(request.id) to specific worker \(workerId)")
    
    // Fire and forget - don't wait for result (worker will restart)
    try await connectionManager?.send(.taskRequest(request: request), to: workerId)
  }
  
  /// Send a direct shell command to a specific worker (no LLM involved)
  /// - Parameters:
  ///   - command: The executable path
  ///   - args: Arguments to pass
  ///   - workingDirectory: Optional working directory
  ///   - workerId: Target worker ID
  /// - Note: Fire and forget - result comes back via delegate
  public func sendDirectCommand(_ command: String, args: [String] = [], workingDirectory: String? = nil, to workerId: String) async throws {
    guard role == .brain || role == .hybrid else {
      throw DistributedError.actorSystemNotReady
    }
    
    guard connectedWorkers.contains(where: { $0.id == workerId }) else {
      throw DistributedError.noWorkersAvailable
    }
    
    let id = UUID()
    print("📤 sendDirectCommand: id=\(id), command=\(command), to=\(workerId)")
    logger.info("Sending direct command to \(workerId): \(command)")
    
    let message = PeerMessage.directCommand(id: id, command: command, args: args, workingDirectory: workingDirectory)
    print("📤 Message created: \(message)")
    try await connectionManager?.send(message, to: workerId)
    print("📤 Message sent successfully")
  }
  
  /// Send a direct shell command and wait for result (with timeout)
  /// - Parameters:
  ///   - command: The executable path
  ///   - args: Arguments to pass
  ///   - workingDirectory: Optional working directory
  ///   - workerId: Target worker ID
  ///   - timeout: Maximum time to wait for result (default 30s)
  /// - Returns: The command result with exit code, stdout, and stderr
  public func sendDirectCommandAndWait(
    _ command: String,
    args: [String] = [],
    workingDirectory: String? = nil,
    to workerId: String,
    timeout: Duration = .seconds(30)
  ) async throws -> DirectCommandResult {
    guard role == .brain || role == .hybrid else {
      throw DistributedError.actorSystemNotReady
    }
    
    guard connectedWorkers.contains(where: { $0.id == workerId }) else {
      throw DistributedError.noWorkersAvailable
    }
    
    let id = UUID()
    logger.info("Sending direct command (waiting): \(command) to \(workerId)")
    
    // Set up continuation to receive result
    let result: DirectCommandResult = await withCheckedContinuation { continuation in
      pendingDirectCommands[id] = continuation
      
      Task {
        let message = PeerMessage.directCommand(id: id, command: command, args: args, workingDirectory: workingDirectory)
        do {
          try await connectionManager?.send(message, to: workerId)
        } catch {
          // If send fails, resume with error result
          pendingDirectCommands.removeValue(forKey: id)
          continuation.resume(returning: DirectCommandResult(exitCode: -1, output: "", error: error.localizedDescription))
        }
      }
      
      // Set up timeout
      Task {
        try? await Task.sleep(for: timeout)
        if let cont = pendingDirectCommands.removeValue(forKey: id) {
          cont.resume(returning: DirectCommandResult(exitCode: -1, output: "", error: "Timeout waiting for command result"))
        }
      }
    }
    
    return result
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
  
  /// Handle direct command execution (worker mode) - no LLM involved
  private func handleDirectCommand(id: UUID, command: String, args: [String], workingDirectory: String?, from peerId: String) async {
    print("📥 handleDirectCommand called: command=\(command), role=\(String(describing: role)), from=\(peerId)")
    logger.info("handleDirectCommand called: command=\(command), role=\(String(describing: self.role))")
    
    guard role == .worker || role == .hybrid else {
      print("⚠️ handleDirectCommand: Not in worker mode (role=\(String(describing: role))), ignoring")
      return
    }
    
    logger.info("Executing direct command: \(command) \(args.joined(separator: " "))")
    
    // Determine the working directory
    // If none specified, try to find the Peel repo from the running app's bundle
    let effectiveWorkingDir: String
    if let dir = workingDirectory, !dir.isEmpty {
      effectiveWorkingDir = dir
    } else {
      // Detect repo from bundle location
      let bundlePath = Bundle.main.bundlePath
      // e.g., /Users/user/code/KitchenSink/build/Build/Products/Debug/Peel.app
      // We want: /Users/user/code/KitchenSink
      let components = bundlePath.components(separatedBy: "/")
      if let buildIndex = components.firstIndex(of: "build") {
        effectiveWorkingDir = components.prefix(buildIndex).joined(separator: "/")
      } else if let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) {
        effectiveWorkingDir = components.prefix(appIndex).joined(separator: "/")
      } else {
        effectiveWorkingDir = FileManager.default.currentDirectoryPath
      }
    }
    
    // Resolve the command - use /bin/sh -c for shell commands to get PATH resolution
    // If command is absolute path, use it directly; otherwise use shell
    let useShell = !command.hasPrefix("/")
    
    let process = Process()
    if useShell {
      // Use shell to resolve command via PATH
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      let fullCommand = ([command] + args).map { arg in
        // Escape arguments for shell
        arg.contains(" ") || arg.contains("\"") ? "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'" : arg
      }.joined(separator: " ")
      process.arguments = ["-c", fullCommand]
      logger.info("Executing via shell: /bin/zsh -c '\(fullCommand)' in \(effectiveWorkingDir)")
    } else {
      process.executableURL = URL(fileURLWithPath: command)
      process.arguments = args
      logger.info("Executing direct: \(command) \(args.joined(separator: " ")) in \(effectiveWorkingDir)")
    }
    process.currentDirectoryURL = URL(fileURLWithPath: effectiveWorkingDir)
    
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    
    var output = ""
    var errorOutput: String? = nil
    var exitCode: Int32 = -1
    
    do {
      try process.run()
      process.waitUntilExit()
      exitCode = process.terminationStatus
      
      let outData = stdout.fileHandleForReading.readDataToEndOfFile()
      output = String(data: outData, encoding: .utf8) ?? ""
      
      let errData = stderr.fileHandleForReading.readDataToEndOfFile()
      let errStr = String(data: errData, encoding: .utf8) ?? ""
      if !errStr.isEmpty {
        errorOutput = errStr
      }
      
    } catch {
      errorOutput = error.localizedDescription
    }
    
    // Send result back
    try? await connectionManager?.send(
      .directCommandResult(id: id, exitCode: exitCode, output: output, error: errorOutput),
      to: peerId
    )
    
    logger.info("Direct command \(id) finished with exit code \(exitCode)")
  }
}

// MARK: - PeerConnectionDelegate

extension SwarmCoordinator: PeerConnectionDelegate {
  public func connectionManager(_ manager: PeerConnectionManager, didConnect peer: ConnectedPeer) {
    // Remove any existing entry with the same ID (handles reconnect case)
    connectedWorkers.removeAll { $0.id == peer.id }
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
      // Resume the waiting continuation
      if let continuation = pendingTasks.removeValue(forKey: result.requestId) {
        continuation.resume(returning: result)
      }
      // Update counters and store result
      if result.status == .completed {
        tasksCompleted += 1
      } else {
        tasksFailed += 1
      }
      // Store result (most recent first, capped)
      completedResults.insert(result, at: 0)
      if completedResults.count > maxStoredResults {
        completedResults.removeLast()
      }
      delegate?.swarmCoordinator(self, didEmit: .taskCompleted(result))
      
    case .directCommand(let id, let command, let args, let workingDirectory):
      print("📨 Received .directCommand message: id=\(id), command=\(command), from=\(peerId)")
      logger.info("Received directCommand: \(command) from \(peerId)")
      Task {
        await handleDirectCommand(id: id, command: command, args: args, workingDirectory: workingDirectory, from: peerId)
      }
      
    case .directCommandResult(let id, let exitCode, let output, let error):
      logger.info("Direct command \(id) completed with exit code \(exitCode)")
      if let error = error, !error.isEmpty {
        logger.warning("Direct command stderr: \(error)")
      }
      if !output.isEmpty {
        logger.debug("Direct command output: \(output.prefix(500))")
      }
      // Resume any pending continuation waiting for this result
      if let continuation = pendingDirectCommands.removeValue(forKey: id) {
        continuation.resume(returning: DirectCommandResult(exitCode: exitCode, output: output, error: error))
      }
      
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
