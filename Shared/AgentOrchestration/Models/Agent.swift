//
//  Agent.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation

/// Available models for Copilot CLI
public enum CopilotModel: String, Codable, CaseIterable, Identifiable, Sendable {
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
    } else if premiumCost < 1.0 {
      // Format fractional costs like 0.33 as "0.3×"
      costStr = String(format: "%.1f×", premiumCost)
    } else if premiumCost == floor(premiumCost) {
      // Integer costs like 1.0 or 3.0 as "1×" or "3×"
      costStr = "\(Int(premiumCost))×"
    } else {
      // Decimal costs like 2.5 as "2.5×"
      costStr = String(format: "%.1f×", premiumCost)
    }
    // Pad to align costs on the right
    let padding = String(repeating: " ", count: max(0, 22 - displayName.count))
    return "\(displayName)\(padding)\(costStr)"
  }
  
  /// Premium requests cost per use (0 = free tier)
  public var premiumCost: Double {
    switch self {
    case .claudeOpus45: return 3.0
    case .claudeHaiku45: return 0.33
    case .gpt41: return 0.0  // Free tier
    case .gpt5Mini: return 0.0  // Free tier (likely)
    case .gemini3Pro: return 0.0  // Free tier (likely)
    default: return 1.0
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

  public static func fromString(_ value: String) -> CopilotModel? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let direct = CopilotModel(rawValue: normalized) {
      return direct
    }
    return CopilotModel.allCases.first { model in
      model.displayName.lowercased() == normalized || model.shortName.lowercased() == normalized
    }
  }
}

/// Role determines what tools an agent can use
public enum AgentRole: String, Codable, CaseIterable, Identifiable, Sendable {
  case planner     // Read-only: analyze, plan, but NOT edit
  case implementer // Full access: can edit files, run commands
  case reviewer    // Read-only: review changes, suggest fixes
  
  public var id: String { rawValue }
  
  public var displayName: String {
    switch self {
    case .planner: return "Planner"
    case .implementer: return "Implementer"
    case .reviewer: return "Reviewer"
    }
  }
  
  public var description: String {
    switch self {
    case .planner: return "Analyzes code and creates plans (read-only)"
    case .implementer: return "Makes code changes and runs commands"
    case .reviewer: return "Reviews changes and suggests fixes (read-only)"
    }
  }
  
  public var iconName: String {
    switch self {
    case .planner: return "map"
    case .implementer: return "hammer"
    case .reviewer: return "eye"
    }
  }
  
  /// Whether this role can write/edit files
  public var canWrite: Bool {
    self == .implementer
  }
  
  /// Tools to deny for this role (passed to --deny-tool)
  public var deniedTools: [String] {
    switch self {
    case .planner, .reviewer:
      return ["write_file", "edit_file", "create_file", "delete_file"]
    case .implementer:
      return []
    }
  }
  
  /// System prompt prefix that defines the agent's role clearly
  public var systemPrompt: String {
    switch self {
    case .planner:
      return """
        You are a PLANNER agent. Your role is to:
        - Analyze code and understand the codebase
        - Create detailed plans and identify issues
        - List specific files and line numbers that need changes
        - Describe what changes should be made and why
        
        IMPORTANT: You must NOT make any edits or modifications to files.
        You are READ-ONLY. Your job is to analyze and plan, not implement.
        Output a clear, actionable plan that an Implementer agent can follow.

        OUTPUT FORMAT:
        Return a single JSON object with this shape and no surrounding text:
        {
          "branch": "feature/short-slug",
          "tasks": [
            {
              "title": "short task title",
              "description": "what to do",
              "recommendedModel": "claude-sonnet-4.5",
              "fileHints": ["Shared/Path/File.swift"]
            }
          ],
          "noWorkReason": "optional reason if tasks is empty"
        }

        If no changes are needed, return:
        {
          "branch": "n/a",
          "tasks": [],
          "noWorkReason": "Why no work is required"
        }
        
        """
    case .implementer:
      return """
        You are an IMPLEMENTER agent. Your role is to:
        - Execute the plan provided by the Planner
        - Make precise, targeted code changes
        - Follow the specific instructions given
        - Run tests if needed to verify changes
        
        You have FULL ACCESS to edit files, run commands, and make changes.
        Focus on implementing exactly what was planned. If the plan is unclear,
        make reasonable decisions but stay close to the original intent.
        
        """
    case .reviewer:
      return """
        You are a REVIEWER agent. Your role is to:
        - Review the changes made by the Implementer
        - Check for bugs, edge cases, and code quality issues
        - Verify the changes match the original plan
        - Suggest improvements or flag concerns
        
        IMPORTANT: You must NOT make any edits or modifications to files.
        You are READ-ONLY. Your job is to review and provide feedback only.
        Be specific about any issues found and suggest how to fix them.
        
        """
    }
  }

  public static func fromString(_ value: String) -> AgentRole? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return AgentRole.allCases.first { $0.rawValue == normalized }
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
  
  public var color: String {
    switch self {
    case .idle: return "gray"
    case .planning: return "yellow"
    case .working: return "blue"
    case .blocked: return "orange"
    case .testing: return "purple"
    case .complete: return "green"
    case .failed: return "red"
    }
  }
}

/// Framework/language hints for specialized agent instructions
public enum FrameworkHint: String, Codable, CaseIterable, Identifiable, Sendable {
  case auto = "auto"           // Detect from project
  case swift = "swift"         // Swift/SwiftUI/iOS/macOS
  case ember = "ember"         // Ember.js
  case react = "react"         // React/Next.js
  case python = "python"       // Python/Django/Flask
  case rust = "rust"           // Rust
  case general = "general"     // No specific framework
  
  public var id: String { rawValue }
  
  public var displayName: String {
    switch self {
    case .auto: return "Auto-detect"
    case .swift: return "Swift/SwiftUI"
    case .ember: return "Ember.js"
    case .react: return "React"
    case .python: return "Python"
    case .rust: return "Rust"
    case .general: return "General"
    }
  }
  
  public var iconName: String {
    switch self {
    case .auto: return "wand.and.stars"
    case .swift: return "swift"
    case .ember: return "flame"
    case .react: return "atom"
    case .python: return "chevron.left.forwardslash.chevron.right"
    case .rust: return "gearshape.2"
    case .general: return "doc.text"
    }
  }
  
  /// Framework-specific instructions to inject into prompts
  public var instructions: String {
    switch self {
    case .auto:
      return ""  // Will be filled in based on detected project type
    case .swift:
      return """
        
        FRAMEWORK: Swift/SwiftUI (iOS/macOS)
        - Use modern Swift 6 patterns: @Observable, async/await, actors
        - Prefer NavigationStack over NavigationView
        - Use @MainActor for UI code
        - Follow Apple HIG for UI design
        - Use 2-space indentation
        
        """
    case .ember:
      return """
        
        FRAMEWORK: Ember.js
        - Use Ember Octane patterns (native classes, tracked properties)
        - Follow Ember conventions for file structure
        - Use Glimmer components where possible
        - Prefer native getters over computed properties
        
        """
    case .react:
      return """
        
        FRAMEWORK: React/Next.js
        - Use functional components with hooks
        - Prefer TypeScript
        - Follow React best practices for state management
        - Use proper key props in lists
        
        """
    case .python:
      return """
        
        FRAMEWORK: Python
        - Follow PEP 8 style guide
        - Use type hints where appropriate
        - Prefer async/await for I/O operations
        - Use virtual environments and requirements.txt
        
        """
    case .rust:
      return """
        
        FRAMEWORK: Rust
        - Follow Rust idioms and ownership patterns
        - Use Result types for error handling
        - Prefer iterators over manual loops
        - Document public APIs
        
        """
    case .general:
      return ""
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
