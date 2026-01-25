//
//  ChainTemplate.swift
//  MCPCore
//
//  Chain template definitions for MCP automation.
//

import Foundation

// MARK: - Chain Template

/// A reusable template for creating agent chains
public struct MCPChainTemplate: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var description: String
  public var steps: [MCPAgentStepTemplate]
  public let createdAt: Date
  public var isBuiltIn: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case description
    case steps
    case createdAt
    case isBuiltIn
  }

  public init(
    id: UUID = UUID(),
    name: String,
    description: String = "",
    steps: [MCPAgentStepTemplate] = [],
    isBuiltIn: Bool = false
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.steps = steps
    self.createdAt = Date()
    self.isBuiltIn = isBuiltIn
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    self.name = try container.decode(String.self, forKey: .name)
    self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    self.steps = try container.decodeIfPresent([MCPAgentStepTemplate].self, forKey: .steps) ?? []
    self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    self.isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
  }

  /// Total estimated premium cost for all steps
  public var estimatedTotalCost: Double {
    steps.reduce(0) { $0 + $1.estimatedCost }
  }

  /// Cost display string
  public var costDisplay: String {
    estimatedTotalCost.premiumCostDisplay
  }
}

// MARK: - Agent Step Template

/// A step within a chain template
public struct MCPAgentStepTemplate: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var role: MCPAgentRole
  public var model: MCPCopilotModel
  public var name: String
  public var frameworkHint: MCPFrameworkHint
  public var customInstructions: String?

  public init(
    id: UUID = UUID(),
    role: MCPAgentRole,
    model: MCPCopilotModel,
    name: String,
    frameworkHint: MCPFrameworkHint = .auto,
    customInstructions: String? = nil
  ) {
    self.id = id
    self.role = role
    self.model = model
    self.name = name
    self.frameworkHint = frameworkHint
    self.customInstructions = customInstructions
  }

  /// Estimated premium cost for this step
  public var estimatedCost: Double {
    model.premiumCost
  }
}

// MARK: - Built-in Templates

extension MCPChainTemplate {
  /// Built-in templates (without validation config - that's added by the app)
  public static var builtInTemplates: [MCPChainTemplate] {
    [
      // Code Review: Planner analyzes, Implementer fixes, Reviewer checks
      MCPChainTemplate(
        name: "Code Review",
        description: "Analyze code, implement fixes, then review changes",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .claudeOpus45, name: "Analyzer"),
          MCPAgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Fixer"),
          MCPAgentStepTemplate(role: .reviewer, model: .gpt41, name: "Reviewer")
        ],
        isBuiltIn: true
      ),

      // Quick Fix: Just plan and implement
      MCPChainTemplate(
        name: "Quick Fix",
        description: "Fast analysis and implementation (no review)",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
          MCPAgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer")
        ],
        isBuiltIn: true
      ),

      // Free Review: Use free models for cost-effective review
      MCPChainTemplate(
        name: "Free Review",
        description: "Cost-effective review using free/low-cost models",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .gpt41, name: "Analyzer"),
          MCPAgentStepTemplate(role: .implementer, model: .gpt41, name: "Implementer"),
          MCPAgentStepTemplate(role: .reviewer, model: .gpt41, name: "Reviewer")
        ],
        isBuiltIn: true
      ),

      // Deep Analysis: Thorough planning with Opus
      MCPChainTemplate(
        name: "Deep Analysis",
        description: "Thorough analysis with premium reasoning model",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .claudeOpus45, name: "Deep Planner")
        ],
        isBuiltIn: true
      ),

      // Multi-Implementer: One planner, multiple implementers
      MCPChainTemplate(
        name: "Multi-Implementer",
        description: "One planner with two implementers for parallel tasks",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
          MCPAgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer 1"),
          MCPAgentStepTemplate(role: .implementer, model: .gpt51Codex, name: "Implementer 2")
        ],
        isBuiltIn: true
      ),

      // Parallel Validation: Planner + parallel implementers + reviewer
      MCPChainTemplate(
        name: "Parallel Validation",
        description: "Planner with parallel implementers and a reviewer",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
          MCPAgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer A"),
          MCPAgentStepTemplate(role: .implementer, model: .gpt5Mini, name: "Implementer B"),
          MCPAgentStepTemplate(role: .reviewer, model: .gpt41, name: "Reviewer")
        ],
        isBuiltIn: true
      ),

      // Parallel Validation (Free): Same but with free/low-cost models
      MCPChainTemplate(
        name: "Parallel Validation (Free)",
        description: "Planner with parallel implementers and a reviewer using free/low-cost models",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .gpt5Mini, name: "Planner"),
          MCPAgentStepTemplate(role: .implementer, model: .gpt5Mini, name: "Implementer A"),
          MCPAgentStepTemplate(role: .implementer, model: .gpt5Mini, name: "Implementer B"),
          MCPAgentStepTemplate(role: .reviewer, model: .gpt41, name: "Reviewer")
        ],
        isBuiltIn: true
      )
    ]
  }
}
