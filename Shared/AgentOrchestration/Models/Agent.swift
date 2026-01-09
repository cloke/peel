//
//  Agent.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation

/// The type of AI agent CLI being used
public enum AgentType: String, Codable, CaseIterable, Identifiable {
  case claude = "claude"
  case copilot = "copilot"
  case custom = "custom"
  
  public var id: String { rawValue }
  
  public var displayName: String {
    switch self {
    case .claude: return "Claude"
    case .copilot: return "GitHub Copilot"
    case .custom: return "Custom"
    }
  }
  
  public var iconName: String {
    switch self {
    case .claude: return "brain.head.profile"
    case .copilot: return "airplane"
    case .custom: return "terminal"
    }
  }
}

/// Current state of an agent
public enum AgentState: Equatable {
  case idle
  case planning
  case working
  case blocked(reason: String)
  case testing
  case complete
  case failed(message: String)
  
  public var displayName: String {
    switch self {
    case .idle: return "Idle"
    case .planning: return "Planning"
    case .working: return "Working"
    case .blocked: return "Blocked"
    case .testing: return "Testing"
    case .complete: return "Complete"
    case .failed: return "Failed"
    }
  }
  
  public var iconName: String {
    switch self {
    case .idle: return "circle"
    case .planning: return "lightbulb"
    case .working: return "gearshape.2"
    case .blocked: return "exclamationmark.triangle"
    case .testing: return "checkmark.circle"
    case .complete: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    }
  }
  
  public var isActive: Bool {
    switch self {
    case .planning, .working, .testing: return true
    default: return false
    }
  }
}

/// Represents an AI coding agent
@MainActor
@Observable
public final class Agent: Identifiable {
  public let id: UUID
  public var name: String
  public let type: AgentType
  public var state: AgentState
  public var currentTask: AgentTask?
  public var workspace: AgentWorkspace?
  public let createdAt: Date
  public var lastActivityAt: Date
  
  /// Custom CLI path for custom agent types
  public var customCLIPath: String?
  
  public init(
    id: UUID = UUID(),
    name: String,
    type: AgentType,
    state: AgentState = .idle,
    currentTask: AgentTask? = nil,
    workspace: AgentWorkspace? = nil,
    customCLIPath: String? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.state = state
    self.currentTask = currentTask
    self.workspace = workspace
    self.customCLIPath = customCLIPath
    self.createdAt = Date()
    self.lastActivityAt = Date()
  }
  
  /// Update the agent's state and record activity
  public func updateState(_ newState: AgentState) {
    state = newState
    lastActivityAt = Date()
  }
  
  /// Assign a task to this agent
  public func assignTask(_ task: AgentTask) {
    currentTask = task
    updateState(.planning)
  }
  
  /// Clear the current task
  public func clearTask() {
    currentTask = nil
    updateState(.idle)
  }
}

// MARK: - Hashable & Equatable
extension Agent: Hashable {
  public static func == (lhs: Agent, rhs: Agent) -> Bool {
    lhs.id == rhs.id
  }
  
  public nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
