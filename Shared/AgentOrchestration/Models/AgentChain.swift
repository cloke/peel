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
  
  /// Enable review loop - if reviewer requests changes, re-run implementer
  public var enableReviewLoop: Bool = false
  
  /// Maximum review iterations before giving up
  public var maxReviewIterations: Int = 3
  
  /// Current review iteration (0 = first pass)
  public var currentReviewIteration: Int = 0
  
  // MARK: - Live Status (for UI updates during execution)
  
  /// When the current run started
  public var runStartTime: Date?
  
  /// When the current agent started
  public var currentAgentStartTime: Date?
  
  /// Live status messages for the current agent
  public var liveStatusMessages: [LiveStatusMessage] = []
  
  /// Update the live status
  public func addStatusMessage(_ message: String, type: LiveStatusMessage.MessageType = .info) {
    liveStatusMessages.append(LiveStatusMessage(message: message, type: type))
    // Keep only last 50 messages
    if liveStatusMessages.count > 50 {
      liveStatusMessages.removeFirst()
    }
  }
  
  /// Clear live status when starting new run
  public func clearLiveStatus() {
    liveStatusMessages = []
    runStartTime = Date()
    currentAgentStartTime = nil
  }
  
  public enum ChainState: Equatable {
    case idle
    case running(agentIndex: Int)
    case reviewing(iteration: Int)
    case complete
    case failed(message: String)
    
    public var displayName: String {
      switch self {
      case .idle: return "Idle"
      case .running(let idx): return "Running Agent \(idx + 1)"
      case .reviewing(let iter): return "Review Loop \(iter + 1)"
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
    currentReviewIteration = 0
    results = []
    clearLiveStatus()
    for agent in agents {
      agent.clearTask()
    }
  }
}

/// A live status message during chain execution
public struct LiveStatusMessage: Identifiable {
  public let id = UUID()
  public let timestamp = Date()
  public let message: String
  public let type: MessageType
  
  public enum MessageType {
    case info
    case tool
    case progress
    case error
    case complete
    
    public var icon: String {
      switch self {
      case .info: return "info.circle"
      case .tool: return "wrench.and.screwdriver"
      case .progress: return "arrow.right"
      case .error: return "exclamationmark.triangle"
      case .complete: return "checkmark.circle"
      }
    }
    
    public var color: String {
      switch self {
      case .info: return "secondary"
      case .tool: return "purple"
      case .progress: return "blue"
      case .error: return "red"
      case .complete: return "green"
      }
    }
  }
  
  public init(message: String, type: MessageType = .info) {
    self.message = message
    self.type = type
  }
}

/// Result from a single agent in the chain
public struct AgentChainResult: Identifiable, Sendable {
  public let id: UUID
  public let agentId: UUID
  public let agentName: String
  public let model: String
  public let prompt: String
  public let output: String
  public let duration: String?
  public let premiumCost: Double
  public let timestamp: Date
  
  /// For reviewer agents, the parsed verdict
  public var reviewVerdict: ReviewVerdict?
  
  public init(
    agentId: UUID,
    agentName: String,
    model: String,
    prompt: String,
    output: String,
    duration: String? = nil,
    premiumCost: Double = 1.0,
    reviewVerdict: ReviewVerdict? = nil
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
    self.reviewVerdict = reviewVerdict
  }
}

/// Verdict from a reviewer agent
public enum ReviewVerdict: String, Codable, Sendable {
  case approved = "approved"
  case needsChanges = "needs_changes"
  case rejected = "rejected"
  
  public var displayName: String {
    switch self {
    case .approved: return "Approved"
    case .needsChanges: return "Needs Changes"
    case .rejected: return "Rejected"
    }
  }
  
  public var iconName: String {
    switch self {
    case .approved: return "checkmark.seal.fill"
    case .needsChanges: return "arrow.triangle.2.circlepath"
    case .rejected: return "xmark.seal.fill"
    }
  }
  
  public var color: String {
    switch self {
    case .approved: return "green"
    case .needsChanges: return "orange"
    case .rejected: return "red"
    }
  }
  
  /// Try to parse a verdict from the reviewer's output
  public static func parse(from output: String) -> ReviewVerdict {
    let lowercased = output.lowercased()
    
    // Look for explicit markers
    if lowercased.contains("✅ **approve") ||
       lowercased.contains("✅ approve") ||
       lowercased.contains("verdict: approve") ||
       lowercased.contains("recommendation: approve") ||
       lowercased.contains("lgtm") ||
       lowercased.contains("looks good to me") {
      return .approved
    }
    
    if lowercased.contains("❌ **reject") ||
       lowercased.contains("❌ reject") ||
       lowercased.contains("verdict: reject") ||
       lowercased.contains("recommendation: reject") ||
       lowercased.contains("cannot approve") ||
       lowercased.contains("must be fixed before") {
      return .rejected
    }
    
    // Check for change requests
    if lowercased.contains("needs changes") ||
       lowercased.contains("need changes") ||
       lowercased.contains("requires changes") ||
       lowercased.contains("should be changed") ||
       lowercased.contains("please fix") ||
       lowercased.contains("issues found") ||
       lowercased.contains("concerns:") ||
       lowercased.contains("suggestions:") && lowercased.contains("should") {
      return .needsChanges
    }
    
    // Default to approved if no issues mentioned
    if lowercased.contains("no issues") ||
       lowercased.contains("correct") ||
       lowercased.contains("well-implemented") ||
       lowercased.contains("properly implemented") {
      return .approved
    }
    
    // Conservative default - if uncertain, assume approved
    // (The reviewer said something but we couldn't parse it)
    return .approved
  }
}

// MARK: - Hashable
extension AgentChain: Hashable {
  public nonisolated static func == (lhs: AgentChain, rhs: AgentChain) -> Bool {
    lhs.id == rhs.id
  }
  
  public nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
