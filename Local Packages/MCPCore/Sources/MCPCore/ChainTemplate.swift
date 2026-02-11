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

  /// Highest cost tier among all steps
  public var costTier: MCPCopilotModel.CostTier {
    let tiers = steps.map { $0.model.costTier }
    if tiers.contains(.premium) {
      return .premium
    } else if tiers.contains(.standard) {
      return .standard
    } else if tiers.contains(.low) {
      return .low
    } else {
      return .free
    }
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
  /// Built-in templates use dynamic model selection via `MCPCopilotModel.recommended(for:)`
  /// so they automatically pick the best model as availability changes.
  public static var builtInTemplates: [MCPChainTemplate] {
    [
      // --- Review Templates (read-only, no code changes) ---

      // Quick PR Review: Single free reviewer for small/trivial PRs
      MCPChainTemplate(
        name: "Quick PR Review",
        description: "Single reviewer reads the code and provides feedback. Free, fast, good for small PRs under ~200 lines.",
        steps: [
          MCPAgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true
      ),

      // Deep PR Review: Premium analysis + standard reviewer for complex PRs
      MCPChainTemplate(
        name: "Deep PR Review",
        description: "Premium analyzer examines architecture and edge cases, then a reviewer summarizes findings. Best for large or complex PRs.",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .bestPremium, name: "Deep Analyzer"),
          MCPAgentStepTemplate(role: .reviewer, model: .bestStandard, name: "Reviewer")
        ],
        isBuiltIn: true
      ),

      // --- Implementation Templates (plan + code changes) ---

      // Code Review: Full pipeline — plan, fix, review
      MCPChainTemplate(
        name: "Code Review",
        description: "Premium planner identifies issues, implementer fixes them, free reviewer verifies. Full pipeline for fixing code.",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .bestPremium, name: "Analyzer"),
          MCPAgentStepTemplate(role: .implementer, model: .bestStandard, name: "Fixer"),
          MCPAgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true
      ),

      // Quick Fix: Plan and implement without review
      MCPChainTemplate(
        name: "Quick Fix",
        description: "Planner analyzes the task, implementer executes it. No review step — fast turnaround for well-understood changes.",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          MCPAgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer")
        ],
        isBuiltIn: true
      ),

      // Free Review: Full pipeline with free models
      MCPChainTemplate(
        name: "Free Review",
        description: "Same as Code Review but all free models. Good for routine fixes, formatting, and well-defined tasks.",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .bestFree, name: "Analyzer"),
          MCPAgentStepTemplate(role: .implementer, model: .bestFree, name: "Implementer"),
          MCPAgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true
      ),

      // --- Analysis Templates (read-only, no code changes) ---

      // Deep Analysis: Thorough planning/analysis only
      MCPChainTemplate(
        name: "Deep Analysis",
        description: "Premium model does thorough analysis and produces a detailed plan. Read-only — no code changes made.",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .bestPremium, name: "Deep Planner")
        ],
        isBuiltIn: true
      ),

      // --- Parallel Templates (multiple implementers) ---

      // Multi-Implementer: One planner, two parallel implementers
      MCPChainTemplate(
        name: "Multi-Implementer",
        description: "Planner splits work into tasks, two implementers execute in parallel. Fast for multi-file changes.",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          MCPAgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer 1"),
          MCPAgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer 2")
        ],
        isBuiltIn: true
      ),

      // Parallel Validation: Parallel implementers + reviewer
      MCPChainTemplate(
        name: "Parallel Validation",
        description: "Planner splits work, two implementers run in parallel, reviewer checks the merged result.",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          MCPAgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer A"),
          MCPAgentStepTemplate(role: .implementer, model: .bestFree, name: "Implementer B"),
          MCPAgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true
      ),

      // Parallel Validation (Free): Same but all free models
      MCPChainTemplate(
        name: "Parallel Validation (Free)",
        description: "Same as Parallel Validation but all free models. Good for routine multi-file tasks.",
        steps: [
          MCPAgentStepTemplate(role: .planner, model: .bestFree, name: "Planner"),
          MCPAgentStepTemplate(role: .implementer, model: .bestFree, name: "Implementer A"),
          MCPAgentStepTemplate(role: .implementer, model: .bestFree, name: "Implementer B"),
          MCPAgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true
      )
    ]
  }
}
