//
//  ChainTemplate.swift
//  KitchenSync
//
//  Created on 1/9/26.
//

import Foundation

/// A reusable template for creating agent chains
public struct ChainTemplate: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var description: String
  public var steps: [AgentStepTemplate]
  public let createdAt: Date
  public var isBuiltIn: Bool
  
  #if os(macOS)
  public var validationConfig: ValidationConfiguration
  #endif
  
  #if os(macOS)
  public init(
    id: UUID = UUID(),
    name: String,
    description: String = "",
    steps: [AgentStepTemplate] = [],
    isBuiltIn: Bool = false,
    validationConfig: ValidationConfiguration? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.steps = steps
    self.createdAt = Date()
    self.isBuiltIn = isBuiltIn
    self.validationConfig = validationConfig ?? .default
  }
  #else
  public init(
    id: UUID = UUID(),
    name: String,
    description: String = "",
    steps: [AgentStepTemplate] = [],
    isBuiltIn: Bool = false
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.steps = steps
    self.createdAt = Date()
    self.isBuiltIn = isBuiltIn
  }
  #endif
  
  /// Built-in templates
  public static let builtInTemplates: [ChainTemplate] = [
    // Code Review: Planner analyzes, Implementer fixes, Reviewer checks
    ChainTemplate(
      name: "Code Review",
      description: "Analyze code, implement fixes, then review changes",
      steps: [
        AgentStepTemplate(role: .planner, model: .claudeOpus45, name: "Analyzer"),
        AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Fixer"),
        AgentStepTemplate(role: .reviewer, model: .gpt41, name: "Reviewer")
      ],
      isBuiltIn: true
    ),
    
    // Quick Fix: Just plan and implement
    ChainTemplate(
      name: "Quick Fix",
      description: "Fast analysis and implementation (no review)",
      steps: [
        AgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
        AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer")
      ],
      isBuiltIn: true
    ),
    
    // Free Review: Use free models for cost-effective review
    ChainTemplate(
      name: "Free Review",
      description: "Cost-effective review using free tier models",
      steps: [
        AgentStepTemplate(role: .planner, model: .gpt41, name: "Analyzer"),
        AgentStepTemplate(role: .implementer, model: .gpt41, name: "Implementer"),
        AgentStepTemplate(role: .reviewer, model: .gemini3Pro, name: "Reviewer")
      ],
      isBuiltIn: true
    ),
    
    // Deep Analysis: Thorough planning with Opus
    ChainTemplate(
      name: "Deep Analysis",
      description: "Thorough analysis with premium reasoning model",
      steps: [
        AgentStepTemplate(role: .planner, model: .claudeOpus45, name: "Deep Planner")
      ],
      isBuiltIn: true
    ),
    
    // Multi-Implementer: One planner, multiple implementers
    ChainTemplate(
      name: "Multi-Implementer",
      description: "One planner with two implementers for parallel tasks",
      steps: [
        AgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
        AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer 1"),
        AgentStepTemplate(role: .implementer, model: .gpt51Codex, name: "Implementer 2")
      ],
      isBuiltIn: true
    ),

    // MCP Test Harness: Planner + parallel implementers + reviewer
    #if os(macOS)
    ChainTemplate(
      name: "MCP Harness",
      description: "Planner with parallel implementers and a reviewer (MCP validation)",
      steps: [
        AgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
        AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer A"),
        AgentStepTemplate(role: .implementer, model: .gpt51Codex, name: "Implementer B"),
        AgentStepTemplate(role: .reviewer, model: .gpt41, name: "Reviewer")
      ],
      isBuiltIn: true,
      validationConfig: .default
    ),
    #else
    ChainTemplate(
      name: "MCP Harness",
      description: "Planner with parallel implementers and a reviewer (MCP validation)",
      steps: [
        AgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
        AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer A"),
        AgentStepTemplate(role: .implementer, model: .gpt51Codex, name: "Implementer B"),
        AgentStepTemplate(role: .reviewer, model: .gpt41, name: "Reviewer")
      ],
      isBuiltIn: true
    ),
    #endif

    // Roadmap MCP (Cost-Conscious): Planner + 3 implementers + reviewer
    ChainTemplate(
      name: "MCP Roadmap (3x Cost)",
      description: "Planner + 3 implementers + reviewer using free/low-cost models",
      steps: [
        AgentStepTemplate(role: .planner, model: .gpt41, name: "Planner"),
        AgentStepTemplate(role: .implementer, model: .gpt5Mini, name: "Implementer A"),
        AgentStepTemplate(role: .implementer, model: .gpt41, name: "Implementer B"),
        AgentStepTemplate(role: .implementer, model: .gemini3Pro, name: "Implementer C"),
        AgentStepTemplate(role: .reviewer, model: .gpt41, name: "Reviewer")
      ],
      isBuiltIn: true
    )
  ]
}

/// A step within a chain template
public struct AgentStepTemplate: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var role: AgentRole
  public var model: CopilotModel
  public var name: String
  public var frameworkHint: FrameworkHint
  public var customInstructions: String?
  
  public init(
    id: UUID = UUID(),
    role: AgentRole,
    model: CopilotModel,
    name: String,
    frameworkHint: FrameworkHint = .auto,
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

extension ChainTemplate {
  /// Total estimated premium cost for all steps
  public var estimatedTotalCost: Double {
    steps.reduce(0) { $0 + $1.estimatedCost }
  }
  
  /// Cost display string
  public var costDisplay: String {
    let total = estimatedTotalCost
    if total == 0 {
      return "Free"
    } else if total == Double(Int(total)) {
      return "\(Int(total))× Premium"
    } else {
      return String(format: "%.1f× Premium", total)
    }
  }
}
