//
//  AgentPersonality.swift
//  Peel
//
//  SwiftData model for agent personalities — distinct roles, expertise,
//  and behavioral traits for multi-agent collaboration.
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData

/// An agent personality defines the role, behavior, and tool access for an agent
/// participating in collaborative chain execution.
@Model
final class AgentPersonality {
  var id: UUID = UUID()
  /// Short identifier (e.g. "planner", "implementer", "reviewer")
  var slug: String = ""
  /// Display name (e.g. "Planner", "Security Auditor")
  var name: String = ""
  /// Role category for routing and collaboration
  var role: String = "implementer"
  /// System prompt that defines this agent's personality, expertise, and behavioral directives
  var systemPrompt: String = ""
  /// Comma-separated expertise tags (e.g. "swift,architecture,security")
  var expertiseTags: String = ""
  /// Comma-separated list of allowed tool names. Empty = all non-sensitive tools.
  /// Use "*" for unrestricted access.
  var allowedTools: String = ""
  /// Comma-separated list of explicitly denied tool names (overrides allowed)
  var deniedTools: String = ""
  /// Collaboration style: how this agent interacts with others
  /// Values: "autonomous", "collaborative", "supervisory", "reactive"
  var collaborationStyle: String = "collaborative"
  /// Whether this is a built-in personality (cannot be deleted, can be customized)
  var isBuiltIn: Bool = false
  /// Whether this personality is active and available for assignment
  var isActive: Bool = true
  /// Slug of the parent personality this extends (for inheritance)
  var extendsSlug: String?
  /// Preferred LLM model tier for cost optimization (e.g. "premium", "standard", "economy")
  var preferredModelTier: String = "standard"
  /// Maximum token budget per step execution
  var maxTokenBudget: Int = 0
  /// Maximum execution time in seconds per step (0 = no limit)
  var maxExecutionSeconds: Int = 0
  var createdAt: Date = Date()
  var updatedAt: Date = Date()

  init(
    slug: String,
    name: String,
    role: String = "implementer",
    systemPrompt: String = "",
    expertiseTags: String = "",
    allowedTools: String = "",
    deniedTools: String = "",
    collaborationStyle: String = "collaborative",
    isBuiltIn: Bool = false,
    preferredModelTier: String = "standard"
  ) {
    self.id = UUID()
    self.slug = slug
    self.name = name
    self.role = role
    self.systemPrompt = systemPrompt
    self.expertiseTags = expertiseTags
    self.allowedTools = allowedTools
    self.deniedTools = deniedTools
    self.collaborationStyle = collaborationStyle
    self.isBuiltIn = isBuiltIn
    self.preferredModelTier = preferredModelTier
    self.createdAt = Date()
    self.updatedAt = Date()
  }

  /// Check if a tool is allowed for this personality
  func isToolAllowed(_ toolName: String) -> Bool {
    let denied = Set(deniedTools.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    if denied.contains(toolName) { return false }
    let allowed = Set(allowedTools.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    if allowed.isEmpty || allowed.contains("*") { return true }
    return allowed.contains(toolName)
  }

  /// Built-in personality definitions
  static func builtInPersonalities() -> [AgentPersonality] {
    [
      AgentPersonality(
        slug: "planner",
        name: "Planner",
        role: "planner",
        systemPrompt: """
          You are a senior software architect and project planner. Your role is to:
          - Analyze requirements and break them into well-defined, actionable sub-tasks
          - Assign tasks to the most appropriate agent roles based on expertise
          - Define clear acceptance criteria for each task
          - Monitor progress and adjust the plan when blockers arise
          - Never write code directly — delegate to implementer agents
          You communicate concisely with clear task descriptions and priorities.
          """,
        expertiseTags: "architecture,planning,task-decomposition,project-management",
        deniedTools: "terminal.run,code.edit",
        collaborationStyle: "supervisory",
        isBuiltIn: true,
        preferredModelTier: "premium"
      ),
      AgentPersonality(
        slug: "implementer",
        name: "Implementer",
        role: "implementer",
        systemPrompt: """
          You are an expert software engineer. Your role is to:
          - Implement code changes according to the plan provided
          - Follow existing codebase patterns and conventions
          - Write clean, well-structured code with appropriate error handling
          - Ask the planner for clarification if requirements are ambiguous
          - Report completion status and any issues encountered
          Focus on correctness first, then performance. Keep changes minimal and focused.
          """,
        expertiseTags: "swift,implementation,debugging,refactoring",
        allowedTools: "*",
        collaborationStyle: "collaborative",
        isBuiltIn: true,
        preferredModelTier: "standard"
      ),
      AgentPersonality(
        slug: "reviewer",
        name: "Reviewer",
        role: "reviewer",
        systemPrompt: """
          You are a thorough code reviewer. Your role is to:
          - Review code changes for correctness, readability, and maintainability
          - Check for security vulnerabilities (OWASP Top 10)
          - Verify adherence to project conventions and patterns
          - Provide specific, actionable feedback with line references
          - Approve only when all issues are resolved
          Be constructive but rigorous. Flag blocking issues vs. suggestions clearly.
          """,
        expertiseTags: "code-review,security,quality,best-practices",
        deniedTools: "terminal.run,code.edit,swarm.direct-command",
        collaborationStyle: "reactive",
        isBuiltIn: true,
        preferredModelTier: "standard"
      ),
      AgentPersonality(
        slug: "security-auditor",
        name: "Security Auditor",
        role: "security-auditor",
        systemPrompt: """
          You are a security-focused code auditor. Your role is to:
          - Analyze code for security vulnerabilities (injection, auth, crypto, SSRF, etc.)
          - Check for sensitive data exposure (tokens, keys, PII)
          - Verify input validation at system boundaries
          - Ensure secure communication patterns (TLS, DTLS, no plaintext fallbacks)
          - Block merges that introduce security regressions
          You have veto power over merges. Be thorough and document all findings.
          """,
        expertiseTags: "security,owasp,authentication,encryption,audit",
        deniedTools: "terminal.run,code.edit,swarm.direct-command,parallel.create",
        collaborationStyle: "reactive",
        isBuiltIn: true,
        preferredModelTier: "premium"
      ),
      AgentPersonality(
        slug: "devops",
        name: "DevOps Engineer",
        role: "devops",
        systemPrompt: """
          You are a DevOps and infrastructure specialist. Your role is to:
          - Handle build, test, and deployment tasks
          - Manage CI/CD pipelines and configurations
          - Monitor system health and performance
          - Set up and maintain development environments
          - Execute shell commands and scripts safely
          Always validate commands before execution. Prefer idempotent operations.
          """,
        expertiseTags: "devops,ci-cd,shell,automation,infrastructure",
        allowedTools: "*",
        collaborationStyle: "autonomous",
        isBuiltIn: true,
        preferredModelTier: "economy"
      ),
    ]
  }
}
