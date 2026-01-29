// PeelWorker.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// The distributed actor that represents a Peel worker node.

import Foundation
import Distributed
import os.log

// MARK: - Peel Actor

/// A distributed actor representing a Peel worker that can execute chains
@available(macOS 15.0, iOS 18.0, *)
public distributed actor PeelWorker {
  public typealias ActorSystem = LocalNetworkActorSystem
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "PeelWorker")
  
  /// The capabilities of this worker
  public let capabilities: WorkerCapabilities
  
  /// Current status of this worker
  private var status: WorkerStatus
  
  /// The chain executor (injected dependency)
  private let chainExecutor: ChainExecutorProtocol?
  
  /// Tasks completed since start
  private var tasksCompleted = 0
  private var tasksFailed = 0
  
  /// Start time for uptime calculation
  private let startTime = Date()
  
  // MARK: - Initialization
  
  public init(
    actorSystem: LocalNetworkActorSystem,
    capabilities: WorkerCapabilities? = nil,
    chainExecutor: ChainExecutorProtocol? = nil
  ) {
    let caps = capabilities ?? WorkerCapabilities.current()
    self.actorSystem = actorSystem
    self.capabilities = caps
    self.chainExecutor = chainExecutor
    self.status = WorkerStatus(
      deviceId: caps.deviceId,
      state: .idle
    )
    
    logger.info("PeelWorker initialized: \(caps.deviceName)")
  }
  
  // MARK: - Distributed Methods
  
  /// Execute a chain request and return the result
  public distributed func executeChain(_ request: ChainRequest) async throws -> ChainResult {
    logger.info("Executing chain: \(request.templateName) - \(request.id)")
    
    // Update status to busy
    status = WorkerStatus(
      deviceId: capabilities.deviceId,
      state: .busy,
      currentTaskId: request.id,
      lastHeartbeat: Date(),
      uptimeSeconds: Date().timeIntervalSince(startTime),
      tasksCompleted: tasksCompleted,
      tasksFailed: tasksFailed
    )
    
    let startTime = Date()
    
    do {
      // Execute the chain
      let outputs: [ChainOutput]
      
      if let executor = chainExecutor {
        outputs = try await executor.execute(request: request)
      } else {
        // Mock execution for testing
        logger.warning("No chain executor configured, returning mock result")
        try await Task.sleep(for: .seconds(1))
        outputs = [
          ChainOutput(
            type: .text,
            name: "mock_output",
            content: "Mock execution completed for: \(request.prompt)"
          )
        ]
      }
      
      let duration = Date().timeIntervalSince(startTime)
      tasksCompleted += 1
      
      // Update status back to idle
      status = WorkerStatus(
        deviceId: capabilities.deviceId,
        state: .idle,
        lastHeartbeat: Date(),
        uptimeSeconds: Date().timeIntervalSince(self.startTime),
        tasksCompleted: tasksCompleted,
        tasksFailed: tasksFailed
      )
      
      logger.info("Chain completed: \(request.id) in \(duration)s")
      
      return ChainResult(
        requestId: request.id,
        status: .completed,
        outputs: outputs,
        duration: duration,
        workerDeviceId: capabilities.deviceId,
        workerDeviceName: capabilities.deviceName
      )
      
    } catch {
      tasksFailed += 1
      
      // Update status to error then idle
      status = WorkerStatus(
        deviceId: capabilities.deviceId,
        state: .idle,
        lastHeartbeat: Date(),
        uptimeSeconds: Date().timeIntervalSince(self.startTime),
        tasksCompleted: tasksCompleted,
        tasksFailed: tasksFailed
      )
      
      let duration = Date().timeIntervalSince(startTime)
      
      logger.error("Chain failed: \(request.id) - \(error)")
      
      return ChainResult(
        requestId: request.id,
        status: .failed,
        duration: duration,
        workerDeviceId: capabilities.deviceId,
        workerDeviceName: capabilities.deviceName,
        errorMessage: error.localizedDescription
      )
    }
  }
  
  /// Get this worker's capabilities
  public distributed func getCapabilities() async -> WorkerCapabilities {
    capabilities
  }
  
  /// Get current worker status
  public distributed func getStatus() async -> WorkerStatus {
    WorkerStatus(
      deviceId: capabilities.deviceId,
      state: status.state,
      currentTaskId: status.currentTaskId,
      lastHeartbeat: Date(),
      uptimeSeconds: Date().timeIntervalSince(startTime),
      tasksCompleted: tasksCompleted,
      tasksFailed: tasksFailed
    )
  }
  
  /// Health check / heartbeat
  public distributed func heartbeat() async -> WorkerStatus {
    await getStatus()
  }
  
  /// Check if this worker can handle a request
  public distributed func canHandle(_ request: ChainRequest) async -> Bool {
    // Check if we're busy
    if status.state == .busy {
      return false
    }
    
    // Check capabilities
    if let required = request.requiredCapabilities {
      return required.isSatisfiedBy(capabilities)
    }
    
    return true
  }
}

// MARK: - Chain Executor Protocol

/// Protocol for executing chains (allows dependency injection for testing)
public protocol ChainExecutorProtocol: Sendable {
  func execute(request: ChainRequest) async throws -> [ChainOutput]
}

// MARK: - Default Chain Executor

/// Default implementation that delegates to the existing AgentChainRunner
@available(macOS 15.0, iOS 18.0, *)
@MainActor
public final class DefaultChainExecutor: ChainExecutorProtocol, Sendable {
  private let chainRunner: AgentChainRunner
  private let agentManager: AgentManager
  
  public init(chainRunner: AgentChainRunner, agentManager: AgentManager) {
    self.chainRunner = chainRunner
    self.agentManager = agentManager
  }
  
  public func execute(request: ChainRequest) async throws -> [ChainOutput] {
    // Validate working directory exists
    guard FileManager.default.fileExists(atPath: request.workingDirectory) else {
      throw DistributedError.taskExecutionFailed(
        taskId: request.id,
        reason: "Working directory not found: \(request.workingDirectory)"
      )
    }
    
    // Load or find the template
    let template = try loadTemplate(name: request.templateName)
    
    // Create the chain from template using AgentManager
    let chain = agentManager.createChainFromTemplate(template, workingDirectory: request.workingDirectory)
    
    // Run the chain
    let summary = await chainRunner.runChain(
      chain,
      prompt: request.prompt
    )
    
    // Convert summary to outputs
    var outputs: [ChainOutput] = []
    
    // Add individual agent outputs from results
    for (index, result) in summary.results.enumerated() {
      outputs.append(ChainOutput(
        type: .text,
        name: "agent_\(index)_\(result.agentName)",
        content: result.output
      ))
    }
    
    // Calculate totals from results
    let totalPremiumCost = summary.results.reduce(0.0) { $0 + $1.premiumCost }
    let hasError = summary.errorMessage != nil
    
    // Add summary info
    outputs.append(ChainOutput(
      type: .log,
      name: "summary",
      content: """
        Chain: \(summary.chainName)
        State: \(summary.stateDescription)
        Agents Run: \(summary.results.count)
        Premium Cost: \(String(format: "%.2f", totalPremiumCost))
        Status: \(hasError ? "failed" : "completed")
        """
    ))
    
    if let error = summary.errorMessage {
      throw DistributedError.taskExecutionFailed(
        taskId: request.id,
        reason: error
      )
    }
    
    return outputs
  }
  
  private func loadTemplate(name: String) throws -> ChainTemplate {
    // First try to find by name in all templates (built-in + saved)
    if let template = agentManager.allTemplates.first(where: { $0.name == name }) {
      return template
    }
    
    // Try case-insensitive match
    if let template = agentManager.allTemplates.first(where: { $0.name.lowercased() == name.lowercased() }) {
      return template
    }
    
    // Try to load default template
    if name == "default" || name.isEmpty {
      if let defaultTemplate = agentManager.allTemplates.first {
        return defaultTemplate
      }
    }
    
    throw DistributedError.taskExecutionFailed(
      taskId: UUID(),
      reason: "Template not found: \(name). Available templates: \(agentManager.allTemplates.map { $0.name }.joined(separator: ", "))"
    )
  }
}

// MARK: - Mock Chain Executor (for testing)

/// Mock executor for testing distributed communication
@available(macOS 15.0, iOS 18.0, *)
public final class MockChainExecutor: ChainExecutorProtocol, Sendable {
  public let delay: Duration
  public let shouldFail: Bool
  
  public init(delay: Duration = .seconds(1), shouldFail: Bool = false) {
    self.delay = delay
    self.shouldFail = shouldFail
  }
  
  public func execute(request: ChainRequest) async throws -> [ChainOutput] {
    try await Task.sleep(for: delay)
    
    if shouldFail {
      throw DistributedError.taskExecutionFailed(
        taskId: request.id,
        reason: "Mock failure"
      )
    }
    
    return [
      ChainOutput(
        type: .text,
        name: "result",
        content: "Mock result for: \(request.prompt)"
      ),
      ChainOutput(
        type: .log,
        name: "execution_log",
        content: """
          [Mock Executor]
          Template: \(request.templateName)
          Working Dir: \(request.workingDirectory)
          Duration: \(delay)
          """
      )
    ]
  }
}
