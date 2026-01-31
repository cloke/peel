//
//  Agent.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation
import SwiftUI
import MCPCore

// MARK: - Type Aliases to MCPCore

/// Available models for Copilot CLI (aliased from MCPCore)
public typealias CopilotModel = MCPCopilotModel

/// Role determines what tools an agent can use (aliased from MCPCore)
public typealias AgentRole = MCPAgentRole

/// The type of AI agent CLI being used (aliased from MCPCore)
public typealias AgentType = MCPAgentType

/// Framework/language hints for specialized agent instructions (aliased from MCPCore)
public typealias FrameworkHint = MCPFrameworkHint

// MARK: - AgentState (SwiftUI-enhanced version)

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
    metadata.displayName
  }
  
  public var iconName: String {
    metadata.iconName
  }
  
  public var isActive: Bool {
    switch self {
    case .planning, .working, .testing: return true
    default: return false
    }
  }
  
  public var color: Color {
    metadata.color
  }

  private struct Metadata {
    let displayName: String
    let iconName: String
    let color: Color
  }

  private static let idleMetadata = Metadata(displayName: "Idle", iconName: "circle", color: .gray)
  private static let planningMetadata = Metadata(displayName: "Planning", iconName: "lightbulb", color: .yellow)
  private static let workingMetadata = Metadata(displayName: "Working", iconName: "gearshape.2", color: .blue)
  private static let blockedMetadata = Metadata(displayName: "Blocked", iconName: "exclamationmark.triangle", color: .orange)
  private static let testingMetadata = Metadata(displayName: "Testing", iconName: "checkmark.circle", color: .purple)
  private static let completeMetadata = Metadata(displayName: "Complete", iconName: "checkmark.circle.fill", color: .green)
  private static let failedMetadata = Metadata(displayName: "Failed", iconName: "xmark.circle.fill", color: .red)

  private var metadata: Metadata {
    switch self {
    case .idle:
      return Self.idleMetadata
    case .planning:
      return Self.planningMetadata
    case .working:
      return Self.workingMetadata
    case .blocked:
      return Self.blockedMetadata
    case .testing:
      return Self.testingMetadata
    case .complete:
      return Self.completeMetadata
    case .failed:
      return Self.failedMetadata
    }
  }
}

// MARK: - Agent Class

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
  
  /// Role determines what tools the agent can use
  public var role: AgentRole
  
  /// Selected model for Copilot agents
  public var model: CopilotModel
  
  /// Framework hint for specialized instructions
  public var frameworkHint: FrameworkHint
  
  /// Custom instructions to append to prompts
  public var customInstructions: String?
  
  /// Working directory for the agent (project folder path)
  public var workingDirectory: String?
  
  /// Custom CLI path for custom agent types
  public var customCLIPath: String?
  
  public init(
    id: UUID = UUID(),
    name: String,
    type: AgentType,
    role: AgentRole = .implementer,
    state: AgentState = .idle,
    model: CopilotModel = .claudeSonnet45,
    frameworkHint: FrameworkHint = .auto,
    customInstructions: String? = nil,
    workingDirectory: String? = nil,
    currentTask: AgentTask? = nil,
    workspace: AgentWorkspace? = nil,
    customCLIPath: String? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.role = role
    self.state = state
    self.model = model
    self.frameworkHint = frameworkHint
    self.customInstructions = customInstructions
    self.workingDirectory = workingDirectory
    self.currentTask = currentTask
    self.workspace = workspace
    self.customCLIPath = customCLIPath
    self.createdAt = Date()
    self.lastActivityAt = Date()
  }
  
  /// Build the full prompt with role and framework instructions
  public func buildPrompt(userPrompt: String, context: String? = nil) -> String {
    var parts: [String] = []
    
    // 1. Role system prompt
    parts.append(role.systemPrompt)
    
    // 2. Framework instructions (if not auto or general)
    if frameworkHint != .auto && frameworkHint != .general {
      parts.append(frameworkHint.instructions)
    }
    
    // 3. Custom instructions
    if let custom = customInstructions, !custom.isEmpty {
      parts.append("ADDITIONAL INSTRUCTIONS:\n\(custom)\n")
    }
    
    // 4. Context from previous agent (if in chain)
    if let ctx = context, !ctx.isEmpty {
      parts.append("CONTEXT FROM PREVIOUS AGENT:\n\(ctx)\n---\n")
    }
    
    // 5. User prompt
    parts.append("TASK:\n\(userPrompt)")
    
    return parts.joined(separator: "\n")
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
  public nonisolated static func == (lhs: Agent, rhs: Agent) -> Bool {
    lhs.id == rhs.id
  }
  
  public nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// NOTE: Premium cost formatting (premiumCostDisplay, premiumMultiplierString) 
// is defined in MCPCore/CopilotModel.swift as a public Double extension
