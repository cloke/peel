//
//  ChainTemplate.swift
//  KitchenSync
//
//  Created on 1/9/26.
//

import Foundation
import MCPCore

/// Template category for organizing templates in the gallery
public enum TemplateCategory: String, Codable, CaseIterable, Sendable {
  case core
  case specialized
  
  public var displayName: String {
    switch self {
    case .core: return "Core Templates"
    case .specialized: return "Specialized Templates"
    }
  }
}

/// A reusable template for creating agent chains
public struct ChainTemplate: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var description: String
  public var steps: [AgentStepTemplate]
  public let createdAt: Date
  public var isBuiltIn: Bool
  public var category: TemplateCategory
  
  #if os(macOS)
  public var validationConfig: ValidationConfiguration
  #endif
  
  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case description
    case steps
    case createdAt
    case isBuiltIn
    case category
    #if os(macOS)
    case validationConfig
    #endif
  }
  
  #if os(macOS)
  public init(
    id: UUID = UUID(),
    name: String,
    description: String = "",
    steps: [AgentStepTemplate] = [],
    isBuiltIn: Bool = false,
    category: TemplateCategory = .core,
    validationConfig: ValidationConfiguration? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.steps = steps
    self.createdAt = Date()
    self.isBuiltIn = isBuiltIn
    self.category = category
    self.validationConfig = validationConfig ?? .default
  }
  #else
  public init(
    id: UUID = UUID(),
    name: String,
    description: String = "",
    steps: [AgentStepTemplate] = [],
    isBuiltIn: Bool = false,
    category: TemplateCategory = .core
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.steps = steps
    self.createdAt = Date()
    self.isBuiltIn = isBuiltIn
    self.category = category
  }
  #endif

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    self.name = try container.decode(String.self, forKey: .name)
    self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    self.steps = try container.decodeIfPresent([AgentStepTemplate].self, forKey: .steps) ?? []
    self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    self.isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    self.category = try container.decodeIfPresent(TemplateCategory.self, forKey: .category) ?? .core
    #if os(macOS)
    self.validationConfig = try container.decodeIfPresent(ValidationConfiguration.self, forKey: .validationConfig) ?? .default
    #endif
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(description, forKey: .description)
    try container.encode(steps, forKey: .steps)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(isBuiltIn, forKey: .isBuiltIn)
    try container.encode(category, forKey: .category)
    #if os(macOS)
    try container.encode(validationConfig, forKey: .validationConfig)
    #endif
  }
  
  /// Built-in templates
  public static var builtInTemplates: [ChainTemplate] {
    let templates: [ChainTemplate] = [
      // CORE TEMPLATES
      
      // 1. Quick Task: Single implementer, free model, fast turnaround
      ChainTemplate(
        name: "Quick Task",
        description: "Fast single-file changes using free models (Cost: Free)",
        steps: [
          AgentStepTemplate(role: .implementer, model: .gpt41, name: "Implementer")
        ],
        isBuiltIn: true,
        category: .core
      ),
      
      // 2. Analyze and Plan: Planner only, outputs task list
      ChainTemplate(
        name: "Analyze and Plan",
        description: "Create implementation plan without executing (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner")
        ],
        isBuiltIn: true,
        category: .core
      ),
      
      // 3. Full Implementation: Planner + Implementer + Reviewer
      ChainTemplate(
        name: "Full Implementation",
        description: "Complete workflow with planning, implementation, and review (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
          AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer"),
          AgentStepTemplate(role: .reviewer, model: .gpt41, name: "Reviewer")
        ],
        isBuiltIn: true,
        category: .core
      ),
      
      // 4. Parallel Implementation: Planner + 2-3 Implementers for multi-file work
      ChainTemplate(
        name: "Parallel Implementation",
        description: "Planner with multiple parallel implementers for complex multi-file tasks (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
          AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer A"),
          AgentStepTemplate(role: .implementer, model: .gpt51Codex, name: "Implementer B")
        ],
        isBuiltIn: true,
        category: .core
      ),
      
      // SPECIALIZED TEMPLATES
      
      // 5. RAG Index Repository: For indexing/chunking workflows
      ChainTemplate(
        name: "RAG Index Repository",
        description: "Index repository for RAG-based code search (Cost: Free)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .gpt41,
            name: "RAG Indexer",
            customInstructions: """
              You are a RAG indexing specialist. Your task is to:
              
              1. **Check RAG status**: Use rag.status to verify the RAG system is available
              2. **Index the repository**: Use rag.index tool with the provided repository path
                 - Set forceReindex: true if re-indexing is needed
                 - Monitor progress and report chunk counts
              3. **Verify indexing**: Use rag.repos.list to confirm the repository appears in the index
              4. **Test search**: Run a sample rag.search query to verify embeddings are working
              
              Report any errors encountered and suggest fixes if indexing fails.
              """
          )
        ],
        isBuiltIn: true,
        category: .specialized
      ),
      
      // 6. Issue Analysis: Keep existing Issue Analyzer template
      ChainTemplate(
        name: "Issue Analysis",
        description: "Analyze GitHub issue and produce structured implementation plan (Cost: Free)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .gpt41,
            name: "Issue Analyzer",
            customInstructions: """
              You are an Issue Analyzer agent. Your task is to:
              
              1. **Fetch the GitHub issue**: Use the github.issue.get tool to fetch issue details (owner, repo, number).
                 - Parse issue number from URL format: https://github.com/owner/repo/issues/123
                 - Or accept direct issue number if provided
              
              2. **Search RAG for relevant code**: Use rag.search to find code related to the issue.
                 - Search for keywords from issue title and body
                 - Try multiple search queries (semantic concepts, file patterns, function names)
                 - Record all search queries used in ragSearchQueries field
              
              3. **Produce structured JSON analysis**: Output a JSON object with this EXACT structure:
              {
                "issueNumber": <int>,
                "issueTitle": "<string>",
                "issueSummary": "<concise 1-2 sentence summary>",
                "affectedFiles": [
                  {
                    "path": "<file path>",
                    "changeType": "create|modify|delete",
                    "description": "<what needs to change>"
                  }
                ],
                "suggestedApproach": "<detailed implementation approach>",
                "estimatedComplexity": "low|medium|high",
                "ragSearchQueries": ["<query1>", "<query2>"],
                "delegationReady": true|false
              }
              
              Set delegationReady to true if you have enough information to delegate to implementers.
              If information is missing or issue is unclear, set to false and explain in suggestedApproach.
              """
          )
        ],
        isBuiltIn: true,
        category: .specialized
      ),
      
      // 7. PR Review: Review PR diff, suggest fixes, check for issues
      ChainTemplate(
        name: "PR Review",
        description: "Review pull request and provide feedback (Cost: Free)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .gpt41,
            name: "PR Reviewer",
            customInstructions: """
              You are a PR Review specialist. Your task is to:
              
              1. **Fetch PR details**: Use github.pr.get to fetch pull request information
                 - Extract owner, repo, and PR number from provided URL or direct input
              2. **Get PR diff**: Use github.pr.diff to retrieve the code changes
              3. **Analyze changes**: Review the diff for:
                 - Code quality issues
                 - Potential bugs or edge cases
                 - Security vulnerabilities
                 - Performance concerns
                 - Style consistency
              4. **Provide feedback**: Output a structured review with:
                 - Summary of changes
                 - List of issues found (if any)
                 - Suggested improvements
                 - Approval recommendation (approve/request changes)
              
              Be constructive and focus on actionable feedback.
              """
          )
        ],
        isBuiltIn: true,
        category: .specialized
      ),
      
      // 8. Refactor: Deep analysis + careful implementation + thorough review
      ChainTemplate(
        name: "Refactor",
        description: "Deep refactoring with premium models for complex restructuring (Cost: Premium)",
        steps: [
          AgentStepTemplate(role: .planner, model: .claudeOpus45, name: "Architect"),
          AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer"),
          AgentStepTemplate(role: .reviewer, model: .claudeSonnet45, name: "Reviewer")
        ],
        isBuiltIn: true,
        category: .specialized
      )
    ]

    return templates
  }
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
    estimatedTotalCost.premiumCostDisplay
  }

  #if os(macOS)
  public var validationSummaryLabel: String? {
    if validationConfig.enabledRules.isEmpty {
      return nil
    }
    if validationConfig == .default {
      return "Validation: Default"
    }
    if validationConfig == .strict {
      return "Validation: Strict"
    }
    if validationConfig == .minimal {
      return "Validation: Minimal"
    }
    return "Validation: Custom"
  }
  #else
  public var validationSummaryLabel: String? {
    nil
  }
  #endif

  /// All providers required by this template's steps
  public var requiredProviders: Set<MCPCopilotModel.ModelProvider> {
    Set(steps.compactMap { $0.model.requiredProvider })
  }

  /// Check if all template models are available with current provider config
  public func isFullyAvailable(copilotAvailable: Bool, claudeAvailable: Bool) -> Bool {
    steps.allSatisfy { step in
      let model = step.model
      switch model.requiredProvider {
      case .copilot: return copilotAvailable
      case .claude: return claudeAvailable
      }
    }
  }

  /// List of models that are unavailable with current provider config
  public func unavailableModels(copilotAvailable: Bool, claudeAvailable: Bool) -> [MCPCopilotModel] {
    steps.compactMap { step in
      let model = step.model
      let available: Bool
      switch model.requiredProvider {
      case .copilot: available = copilotAvailable
      case .claude: available = claudeAvailable
      }
      return available ? nil : model
    }
  }
}
