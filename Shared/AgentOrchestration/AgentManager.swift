//
//  AgentManager.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation
import Observation

#if os(macOS)
import Git

/// Manages the lifecycle of AI coding agents
@MainActor
@Observable
public final class AgentManager {
  
  /// All registered agents
  public private(set) var agents: [Agent] = []
  
  /// All agent chains
  public private(set) var chains: [AgentChain] = []
  
  /// The workspace manager for creating isolated workspaces
  public let workspaceManager = WorkspaceManager()
  
  /// Currently selected agent (for UI)
  public var selectedAgent: Agent?
  
  /// Currently selected chain (for UI)
  public var selectedChain: AgentChain?
  
  public init() {
    // Add a sample agent for testing
    addSampleData()
  }
  
  // MARK: - Agent Lifecycle
  
  /// Create and register a new agent
  public func createAgent(
    name: String,
    type: AgentType,
    model: CopilotModel = .claudeSonnet45,
    workingDirectory: String? = nil,
    customCLIPath: String? = nil
  ) -> Agent {
    let agent = Agent(
      name: name,
      type: type,
      model: model,
      workingDirectory: workingDirectory,
      customCLIPath: customCLIPath
    )
    agents.append(agent)
    return agent
  }
  
  /// Remove an agent
  public func removeAgent(_ agent: Agent) async {
    // Clean up workspace if exists
    if let workspace = agent.workspace {
      try? await workspaceManager.cleanupWorkspace(workspace, force: true)
    }
    agents.removeAll { $0.id == agent.id }
    if selectedAgent?.id == agent.id {
      selectedAgent = nil
    }
  }
  
  /// Assign a task to an agent and optionally create a workspace
  public func assignTask(
    _ task: AgentTask,
    to agent: Agent,
    repository: Model.Repository? = nil
  ) async throws {
    agent.assignTask(task)
    
    // Create workspace if repository provided
    if let repo = repository {
      let workspace = try await workspaceManager.createWorkspace(
        for: repo,
        task: task,
        agentId: agent.id
      )
      agent.workspace = workspace
    }
  }
  
  /// Start an agent working on its current task
  public func startAgent(_ agent: Agent) {
    guard agent.currentTask != nil else { return }
    agent.updateState(.working)
    agent.currentTask?.start()
  }
  
  /// Mark an agent as complete
  public func completeAgent(_ agent: Agent, result: String? = nil) {
    agent.currentTask?.complete(result: result)
    agent.updateState(.complete)
  }
  
  /// Mark an agent as blocked
  public func blockAgent(_ agent: Agent, reason: String) {
    agent.updateState(.blocked(reason: reason))
  }
  
  /// Reset an agent to idle state
  public func resetAgent(_ agent: Agent) async {
    if let workspace = agent.workspace {
      try? await workspaceManager.cleanupWorkspace(workspace)
      agent.workspace = nil
    }
    agent.clearTask()
  }
  
  // MARK: - Chain Management
  
  /// Create a new agent chain
  public func createChain(name: String, workingDirectory: String? = nil) -> AgentChain {
    let chain = AgentChain(name: name, workingDirectory: workingDirectory)
    chains.append(chain)
    return chain
  }
  
  /// Remove a chain
  public func removeChain(_ chain: AgentChain) {
    chains.removeAll { $0.id == chain.id }
    if selectedChain?.id == chain.id {
      selectedChain = nil
    }
  }
  
  // MARK: - Queries
  
  /// Get agents filtered by state
  public func agents(in state: AgentState) -> [Agent] {
    agents.filter { $0.state == state }
  }
  
  /// Get active agents (planning, working, or testing)
  public var activeAgents: [Agent] {
    agents.filter { $0.state.isActive }
  }
  
  /// Get idle agents
  public var idleAgents: [Agent] {
    agents.filter { $0.state == .idle }
  }
  
  // MARK: - Sample Data (for development/testing)
  
  private func addSampleData() {
    // Create sample agents to show in UI
    let claude = Agent(
      name: "Claude Assistant",
      type: .claude,
      state: .idle
    )
    agents.append(claude)
    
    let copilot = Agent(
      name: "Copilot Helper",
      type: .copilot,
      state: .idle
    )
    agents.append(copilot)
    
    // Add a working agent with a task
    let workingAgent = Agent(
      name: "Feature Builder",
      type: .claude,
      state: .working
    )
    let task = AgentTask(
      title: "Implement login flow",
      description: "Add OAuth login with GitHub",
      prompt: "Please implement a GitHub OAuth login flow using SwiftUI..."
    )
    task.start()
    workingAgent.currentTask = task
    agents.append(workingAgent)
  }
}

#else
// iOS stub
@MainActor
@Observable
public final class AgentManager {
  public private(set) var agents: [Agent] = []
  public let workspaceManager = WorkspaceManager()
  public var selectedAgent: Agent?
  public init() {}
}
#endif
