//
//  Agent.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation

/// Available models for Copilot CLI
public enum CopilotModel: String, Codable, CaseIterable, Identifiable {
  // Claude models
  case claudeSonnet45 = "claude-sonnet-4.5"
  case claudeHaiku45 = "claude-haiku-4.5"
  case claudeOpus45 = "claude-opus-4.5"
  case claudeSonnet4 = "claude-sonnet-4"
  
  // GPT models
  case gpt51CodexMax = "gpt-5.1-codex-max"
  case gpt51Codex = "gpt-5.1-codex"
  case gpt52 = "gpt-5.2"
  case gpt51 = "gpt-5.1"
  case gpt5 = "gpt-5"
  case gpt51CodexMini = "gpt-5.1-codex-mini"
  case gpt5Mini = "gpt-5-mini"
  case gpt41 = "gpt-4.1"  // Often free/cheaper
  
  // Gemini
  case gemini3Pro = "gemini-3-pro-preview"
  
  public var id: String { rawValue }
  
  public var displayName: String {
    switch self {
    case .claudeSonnet45: return "Claude Sonnet 4.5"
    case .claudeHaiku45: return "Claude Haiku 4.5"
    case .claudeOpus45: return "Claude Opus 4.5"
    case .claudeSonnet4: return "Claude Sonnet 4"
    case .gpt51CodexMax: return "GPT 5.1 Codex Max"
    case .gpt51Codex: return "GPT 5.1 Codex"
    case .gpt52: return "GPT 5.2"
    case .gpt51: return "GPT 5.1"
    case .gpt5: return "GPT 5"
    case .gpt51CodexMini: return "GPT 5.1 Codex Mini"
    case .gpt5Mini: return "GPT 5 Mini"
    case .gpt41: return "GPT 4.1"
    case .gemini3Pro: return "Gemini 3 Pro"
    }
  }
  
  /// Display name with premium cost (right-aligned)
  public var displayNameWithCost: String {
    let costStr: String
    if premiumCost == 0 {
      costStr = "Free"
    } else {
      costStr = "\(premiumCost)×"
    }
    // Pad to align costs on the right
    let padding = String(repeating: " ", count: max(0, 22 - displayName.count))
    return "\(displayName)\(padding)\(costStr)"
  }
  
  /// Premium requests cost per use (0 = free tier)
  public var premiumCost: Int {
    switch self {
    case .claudeOpus45: return 3
    case .gpt41: return 0  // Free tier
    case .gpt5Mini: return 0  // Free tier (likely)
    case .gemini3Pro: return 0  // Free tier (likely)
    default: return 1
    }
  }
  
  /// Whether this is a free-tier model
  public var isFree: Bool {
    premiumCost == 0
  }
  
  public var shortName: String {
    switch self {
    case .claudeSonnet45: return "Sonnet 4.5"
    case .claudeHaiku45: return "Haiku 4.5"
    case .claudeOpus45: return "Opus 4.5"
    case .claudeSonnet4: return "Sonnet 4"
    case .gpt51CodexMax: return "Codex Max"
    case .gpt51Codex: return "Codex"
    case .gpt52: return "5.2"
    case .gpt51: return "5.1"
    case .gpt5: return "5"
    case .gpt51CodexMini: return "Codex Mini"
    case .gpt5Mini: return "5 Mini"
    case .gpt41: return "4.1"
    case .gemini3Pro: return "Gemini 3"
    }
  }
  
  public var isClaude: Bool {
    switch self {
    case .claudeSonnet45, .claudeHaiku45, .claudeOpus45, .claudeSonnet4:
      return true
    default:
      return false
    }
  }
  
  public var isGPT: Bool {
    rawValue.hasPrefix("gpt")
  }
  
  public var isGemini: Bool {
    rawValue.hasPrefix("gemini")
  }
  
  /// Group header for picker
  public var family: String {
    if isClaude { return "Claude" }
    if isGemini { return "Gemini" }
    return "GPT"
  }
}

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
  
  /// Selected model for Copilot agents
  public var model: CopilotModel
  
  /// Working directory for the agent (project folder path)
  public var workingDirectory: String?
  
  /// Custom CLI path for custom agent types
  public var customCLIPath: String?
  
  public init(
    id: UUID = UUID(),
    name: String,
    type: AgentType,
    state: AgentState = .idle,
    model: CopilotModel = .claudeSonnet45,
    workingDirectory: String? = nil,
    currentTask: AgentTask? = nil,
    workspace: AgentWorkspace? = nil,
    customCLIPath: String? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.state = state
    self.model = model
    self.workingDirectory = workingDirectory
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
