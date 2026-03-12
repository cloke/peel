//
//  ChainExecutor.swift
//  Peel
//
//  Protocol and default implementation for chain execution in worker/hybrid mode.
//  Extracted from the deleted PeelWorker.swift during networking replan Phase 3.
//

import Foundation

// MARK: - Protocol

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
    // Resolve working directory via RepoRegistry (maps remote URLs to local paths)
    let resolvedDir = RepoRegistry.shared.resolveWorkingDirectory(for: request)

    // Validate working directory exists
    guard FileManager.default.fileExists(atPath: resolvedDir) else {
      throw DistributedError.taskExecutionFailed(
        taskId: request.id,
        reason: "Working directory not found: \(resolvedDir) (original: \(request.workingDirectory), remoteURL: \(request.repoRemoteURL ?? "none")). Register this repo with swarm.register-repo."
      )
    }

    // Load or find the template
    let template = try loadTemplate(name: request.templateName)

    // Create the chain from template using AgentManager (use resolved path)
    let chain = agentManager.createChainFromTemplate(template, workingDirectory: resolvedDir)

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
    if let template = agentManager.allTemplates.first(where: { $0.name == name }) {
      return template
    }

    if let template = agentManager.allTemplates.first(where: { $0.name.lowercased() == name.lowercased() }) {
      return template
    }

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
