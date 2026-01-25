//
//  AgentTypes.swift
//  MCPCore
//
//  Core agent type definitions.
//

import Foundation

// MARK: - Agent Role

/// Role determines what tools an agent can use
public enum MCPAgentRole: String, Codable, CaseIterable, Identifiable, Sendable {
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
    Self.systemPrompts[self] ?? ""
  }

  private static let systemPrompts: [MCPAgentRole: String] = [
    .planner: """
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

        """,
    .implementer: """
        You are an IMPLEMENTER agent. Your role is to:
        - Execute the plan provided by the Planner
        - Make precise, targeted code changes
        - Follow the specific instructions given
        - Run tests if needed to verify changes

        You have FULL ACCESS to edit files, run commands, and make changes.
        Focus on implementing exactly what was planned. If the plan is unclear,
        make reasonable decisions but stay close to the original intent.

        """,
    .reviewer: """
        You are a REVIEWER agent. Your role is to:
        - Review the changes made by the Implementer
        - Check for bugs, edge cases, and code quality issues
        - Verify the changes match the original plan
        - Suggest improvements or flag concerns

        IMPORTANT: You must NOT make any edits or modifications to files.
        You are READ-ONLY. Your job is to review and provide feedback only.
        Be specific about any issues found and suggest how to fix them.

        """
  ]

  public static func fromString(_ value: String) -> MCPAgentRole? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return MCPAgentRole.allCases.first { $0.rawValue == normalized }
  }
}

// MARK: - Agent Type

/// The type of AI agent CLI being used
public enum MCPAgentType: String, Codable, CaseIterable, Identifiable, Sendable {
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

// MARK: - Agent State

/// Current state of an agent (for UI display)
public enum MCPAgentState: Equatable, Sendable {
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

// MARK: - Framework Hint

/// Framework/language hints for specialized agent instructions
public enum MCPFrameworkHint: String, Codable, CaseIterable, Identifiable, Sendable {
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
