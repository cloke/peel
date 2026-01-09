//
//  AgentChain.swift
//  KitchenSync
//
//  Created on 1/8/26.
//

import Foundation

/// A chain of agents that execute sequentially, passing output as context
@MainActor
@Observable
public final class AgentChain: Identifiable {
  public let id: UUID
  public var name: String
  public var agents: [Agent]
  public var state: ChainState
  public var currentAgentIndex: Int
  public var results: [AgentChainResult]
  
  /// Shared working directory for all agents in the chain
  public var workingDirectory: String?
  
  public enum ChainState: Equatable {
    case idle
    case running(agentIndex: Int)
    case complete
    case failed(message: String)
    
    public var displayName: String {
      switch self {
      case .idle: return "Idle"
      case .running(let idx): return "Running Agent \(idx + 1)"
      case .complete: return "Complete"
      case .failed: return "Failed"
      }
    }
  }
  
  public init(
    id: UUID = UUID(),
    name: String,
    agents: [Agent] = [],
    workingDirectory: String? = nil
  ) {
    self.id = id
    self.name = name
    self.agents = agents
    self.workingDirectory = workingDirectory
    self.state = .idle
    self.currentAgentIndex = 0
    self.results = []
  }
  
  /// Add an agent to the chain
  public func addAgent(_ agent: Agent) {
    // Inherit working directory if not set
    if agent.workingDirectory == nil {
      agent.workingDirectory = workingDirectory
    }
    agents.append(agent)
  }
  
  /// Get combined context from all previous agent results
  public func contextForAgent(at index: Int) -> String {
    guard index > 0 else { return "" }
    
    let previousResults = results.prefix(index)
    return previousResults.map { result in
      """
      --- Output from \(result.agentName) (\(result.model)) ---
      \(result.output)
      """
    }.joined(separator: "\n\n")
  }
  
  /// Reset the chain for a new run
  public func reset() {
    state = .idle
    currentAgentIndex = 0
    results = []
    for agent in agents {
      agent.clearTask()
    }
  }
}

/// Result from a single agent in the chain
public struct AgentChainResult: Identifiable {
  public let id: UUID
  public let agentId: UUID
  public let agentName: String
  public let model: String
  public let prompt: String
  public let output: String
  public let duration: String?
  public let premiumCost: Int
  public let timestamp: Date
  
  public init(
    agentId: UUID,
    agentName: String,
    model: String,
    prompt: String,
    output: String,
    duration: String? = nil,
    premiumCost: Int = 1
  ) {
    self.id = UUID()
    self.agentId = agentId
    self.agentName = agentName
    self.model = model
    self.prompt = prompt
    self.output = output
    self.duration = duration
    self.premiumCost = premiumCost
    self.timestamp = Date()
  }
}

// MARK: - Hashable
extension AgentChain: Hashable {
  public static func == (lhs: AgentChain, rhs: AgentChain) -> Bool {
    lhs.id == rhs.id
  }
  
  public nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
