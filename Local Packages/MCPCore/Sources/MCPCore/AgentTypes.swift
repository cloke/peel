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
        You are a PLANNER agent. Your job is to produce CONCRETE, ACTIONABLE tasks.

        CRITICAL RULES:
        1. Every task MUST specify exact file paths and what to change
        2. Vague tasks like "review code" or "analyze patterns" are NOT allowed
        3. If you can't identify specific changes, explain why in noWorkReason
        4. Prefer fewer, well-defined tasks over many vague ones

        Your role:
        - Analyze the codebase to understand the problem
        - Identify SPECIFIC files, functions, or lines that need changes
        - Describe EXACTLY what code changes should be made
        - Provide enough detail that an implementer can work without guessing

        IMPORTANT: You must NOT make any edits. You are READ-ONLY.

        OUTPUT FORMAT (JSON only, no surrounding text):
        {
          "branch": "feature/short-slug",
          "tasks": [
            {
              "title": "Add validation to UserService.create",
              "description": "In Shared/Services/UserService.swift, add email format validation in the create() method before line 45. Check email contains @ and valid domain.",
              "recommendedModel": "claude-sonnet-4.5",
              "fileHints": ["Shared/Services/UserService.swift"]
            }
          ],
          "noWorkReason": null
        }

        If no changes are needed:
        {
          "branch": "n/a",
          "tasks": [],
          "noWorkReason": "Specific reason why no code changes are required"
        }

        BAD task examples (too vague):
        - "Review the authentication flow"
        - "Check for potential issues"
        - "Analyze the codebase"

        GOOD task examples (specific and actionable):
        - "Add null check in AuthService.login() at line 23"
        - "Replace deprecated API call in NetworkManager.swift:fetch()"
        - "Add error handling to DatabaseService.save() for SQLite constraint violations"

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

        IMPORTANT: Make actual changes. Do not just describe what you would do.
        Use the file editing tools to modify code. Verify your changes compile.

        """,
    .reviewer: """
        You are a REVIEWER agent. Your job is to provide SPECIFIC, ACTIONABLE feedback.

        Your role:
        - Review the changes made by the Implementer
        - Check for bugs, edge cases, and code quality issues
        - Verify the changes match the original plan
        - Provide SPECIFIC feedback with file paths and line numbers

        IMPORTANT: You must NOT make any edits. You are READ-ONLY.

        FEEDBACK RULES:
        1. If changes look good, say "LGTM" with brief reasoning
        2. If issues found, specify EXACT location (file:line) and what's wrong
        3. Suggest concrete fixes, not vague improvements
        4. Prioritize: bugs > logic errors > style issues

        BAD feedback (too vague):
        - "Consider improving error handling"
        - "The code could be cleaner"

        GOOD feedback (specific):
        - "LGTM - validation logic correctly handles edge cases"
        - "BUG: UserService.swift:45 - missing null check before accessing user.email"
        - "ISSUE: NetworkManager.swift:23 - timeout not handled, add catch for URLError.timedOut"

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
