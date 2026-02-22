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
  case yolo
  
  public var displayName: String {
    switch self {
    case .core: return "Core Templates"
    case .specialized: return "Specialized Templates"
    case .yolo: return "Yolo Templates"
    }
  }

  public var description: String {
    switch self {
    case .core:
      return "General-purpose templates for common coding workflows"
    case .specialized:
      return "Task-specific templates for indexing, review, and guided execution"
    case .yolo:
      return "Run coding agents with full autonomy inside an isolated VM — safe sandbox for untrusted execution"
    }
  }

  public var iconName: String {
    switch self {
    case .core: return "square.grid.2x2"
    case .specialized: return "slider.horizontal.3"
    case .yolo: return "shield.checkmark"
    }
  }
}

// MARK: - VM Toolchain & Directory Sharing

/// Pre-configured toolchain to bootstrap inside a VM before running agent steps.
/// Each toolchain maps to a setup script that installs packages into the VM.
public enum VMToolchain: String, Codable, Sendable, CaseIterable {
  /// Minimal shell environment (BusyBox / base Alpine). No extra packages.
  case minimal = "minimal"
  /// Git + SSH (git, openssh-client)
  case git = "git"
  /// Swift toolchain (swiftly + latest Swift release)
  case swift = "swift"
  /// Node.js / npm ecosystem
  case node = "node"
  /// Ruby / Bundler / Rake
  case ruby = "ruby"
  /// Ember.js (Node + ember-cli)
  case ember = "ember"
  /// Full-stack: Git + Node + Ruby + common build tools
  case fullStack = "full-stack"

  public var displayName: String {
    switch self {
    case .minimal: "Minimal"
    case .git: "Git"
    case .swift: "Swift"
    case .node: "Node.js"
    case .ruby: "Ruby"
    case .ember: "Ember.js"
    case .fullStack: "Full Stack"
    }
  }

  /// Packages to install via `apk add` (Alpine Linux).
  /// macOS VMs use Homebrew equivalents instead.
  public var alpinePackages: [String] {
    switch self {
    case .minimal: []
    case .git: ["git", "openssh-client"]
    case .swift: ["git", "openssh-client", "bash", "curl", "libstdc++"]
    case .node: ["git", "nodejs", "npm"]
    case .ruby: ["git", "ruby", "ruby-bundler", "build-base"]
    case .ember: ["git", "nodejs", "npm"]
    case .fullStack: ["git", "openssh-client", "nodejs", "npm", "ruby", "ruby-bundler", "build-base", "curl", "bash"]
    }
  }

  /// Extra setup commands to run after package install
  public var postInstallCommands: [String] {
    switch self {
    case .ember: ["npm install -g ember-cli"]
    case .swift: ["curl -L https://swift.org/install.sh | bash"]
    case .fullStack: ["npm install -g ember-cli"]
    default: []
    }
  }

  /// Estimated additional disk space in MB
  public var estimatedDiskMB: Int {
    switch self {
    case .minimal: 0
    case .git: 20
    case .swift: 800
    case .node: 100
    case .ruby: 80
    case .ember: 200
    case .fullStack: 500
    }
  }
}

/// Describes a directory to share between host and VM via VirtioFS.
public struct VMDirectoryShare: Codable, Hashable, Sendable {
  /// Host-side directory path to share
  public var hostPath: String
  /// Mount tag visible inside the VM (e.g. "workspace", "output")
  public var tag: String
  /// Whether the VM can write to this share
  public var readOnly: Bool

  public init(hostPath: String, tag: String, readOnly: Bool = false) {
    self.hostPath = hostPath
    self.tag = tag
    self.readOnly = readOnly
  }

  /// Standard share for the agent workspace (worktree)
  public static func workspace(_ path: String) -> VMDirectoryShare {
    VMDirectoryShare(hostPath: path, tag: "workspace", readOnly: false)
  }

  /// Read-only share for reference data (e.g. RAG index, docs)
  public static func reference(_ path: String, tag: String = "reference") -> VMDirectoryShare {
    VMDirectoryShare(hostPath: path, tag: tag, readOnly: true)
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

  /// Where chain steps execute: host (default), linux VM, or macOS VM
  public var executionEnvironment: ExecutionEnvironment

  /// Toolchain to bootstrap inside the VM before running steps (ignored when environment is .host)
  public var toolchain: VMToolchain

  /// Extra directories to share between host and VM via VirtioFS
  public var directoryShares: [VMDirectoryShare]
  
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
    case executionEnvironment
    case toolchain
    case directoryShares
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
    executionEnvironment: ExecutionEnvironment = .host,
    toolchain: VMToolchain = .minimal,
    directoryShares: [VMDirectoryShare] = [],
    validationConfig: ValidationConfiguration? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.steps = steps
    self.createdAt = Date()
    self.isBuiltIn = isBuiltIn
    self.category = category
    self.executionEnvironment = executionEnvironment
    self.toolchain = toolchain
    self.directoryShares = directoryShares
    self.validationConfig = validationConfig ?? .default
  }
  #else
  public init(
    id: UUID = UUID(),
    name: String,
    description: String = "",
    steps: [AgentStepTemplate] = [],
    isBuiltIn: Bool = false,
    category: TemplateCategory = .core,
    executionEnvironment: ExecutionEnvironment = .host,
    toolchain: VMToolchain = .minimal,
    directoryShares: [VMDirectoryShare] = []
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.steps = steps
    self.createdAt = Date()
    self.isBuiltIn = isBuiltIn
    self.category = category
    self.executionEnvironment = executionEnvironment
    self.toolchain = toolchain
    self.directoryShares = directoryShares
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
    self.executionEnvironment = try container.decodeIfPresent(ExecutionEnvironment.self, forKey: .executionEnvironment) ?? .host
    self.toolchain = try container.decodeIfPresent(VMToolchain.self, forKey: .toolchain) ?? .minimal
    self.directoryShares = try container.decodeIfPresent([VMDirectoryShare].self, forKey: .directoryShares) ?? []
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
    // Only encode VM fields when non-default to keep JSON clean
    if executionEnvironment != .host {
      try container.encode(executionEnvironment, forKey: .executionEnvironment)
    }
    if toolchain != .minimal {
      try container.encode(toolchain, forKey: .toolchain)
    }
    if !directoryShares.isEmpty {
      try container.encode(directoryShares, forKey: .directoryShares)
    }
    #if os(macOS)
    try container.encode(validationConfig, forKey: .validationConfig)
    #endif
  }
  
  // MARK: - Stable Built-in Template IDs
  // These must never change once shipped — external tools and MCP clients reference them.
  private static let quickTaskId             = UUID(uuidString: "A0000001-0001-4000-8000-000000000001")!
  private static let analyzePlanId           = UUID(uuidString: "A0000001-0002-4000-8000-000000000002")!
  private static let fullImplementationId    = UUID(uuidString: "A0000001-0003-4000-8000-000000000003")!
  private static let parallelImplementationId = UUID(uuidString: "A0000001-0004-4000-8000-000000000004")!
  private static let ragIndexId              = UUID(uuidString: "A0000001-0005-4000-8000-000000000005")!
  private static let issueAnalysisId         = UUID(uuidString: "A0000001-0006-4000-8000-000000000006")!
  private static let prReviewId              = UUID(uuidString: "A0000001-0007-4000-8000-000000000007")!
  private static let refactorId              = UUID(uuidString: "A0000001-0008-4000-8000-000000000008")!
  private static let guardedImplementationId = UUID(uuidString: "A0000001-0009-4000-8000-000000000009")!
  private static let vmQuickTaskId           = UUID(uuidString: "A0000001-000A-4000-8000-00000000000A")!
  private static let vmFullBuildId           = UUID(uuidString: "A0000001-000B-4000-8000-00000000000B")!
  private static let vmEmberBuildId          = UUID(uuidString: "A0000001-000C-4000-8000-00000000000C")!
  private static let yoloAgentAnyCLIId       = UUID(uuidString: "A0000001-000D-4000-8000-00000000000D")!
  private static let yoloReviewId            = UUID(uuidString: "A0000001-000E-4000-8000-00000000000E")!
  private static let yoloCopilotId           = UUID(uuidString: "A0000001-000F-4000-8000-00000000000F")!
  private static let yoloClaudeId            = UUID(uuidString: "A0000001-0010-4000-8000-000000000010")!

  /// Built-in templates
  public static var builtInTemplates: [ChainTemplate] {
    let templates: [ChainTemplate] = [
      // CORE TEMPLATES
      
      // 1. Quick Task: Single implementer, free model, fast turnaround
      ChainTemplate(
        id: quickTaskId,
        name: "Quick Task",
        description: "Fast single-file changes using free models (Cost: Free)",
        steps: [
          AgentStepTemplate(role: .implementer, model: .bestFree, name: "Implementer")
        ],
        isBuiltIn: true,
        category: .core
      ),
      
      // 2. Analyze and Plan: Planner only, outputs task list
      ChainTemplate(
        id: analyzePlanId,
        name: "Analyze and Plan",
        description: "Create implementation plan without executing (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner")
        ],
        isBuiltIn: true,
        category: .core
      ),
      
      // 3. Full Implementation: Planner + Implementer + Build Gate + Reviewer
      ChainTemplate(
        id: fullImplementationId,
        name: "Full Implementation",
        description: "Complete workflow with planning, implementation, build verification, and review (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer"),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "Build Check",
            stepType: .gate,
            command: "swift build 2>&1 || xcodebuild -scheme \"$(xcodebuild -list -json 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin)['project']['schemes'][0])\" 2>/dev/null || echo 'default')\" build 2>&1"
          ),
          AgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true,
        category: .core
      ),
      
      // 4. Parallel Implementation: Planner + 2-3 Implementers for multi-file work
      ChainTemplate(
        id: parallelImplementationId,
        name: "Parallel Implementation",
        description: "Planner with multiple parallel implementers for complex multi-file tasks (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer A"),
          AgentStepTemplate(role: .implementer, model: .gpt51Codex, name: "Implementer B")
        ],
        isBuiltIn: true,
        category: .core
      ),
      
      // SPECIALIZED TEMPLATES
      
      // 5. RAG Index Repository: For indexing/chunking workflows
      ChainTemplate(
        id: ragIndexId,
        name: "RAG Index Repository",
        description: "Index repository for RAG-based code search (Cost: Free)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .bestFree,
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
        id: issueAnalysisId,
        name: "Issue Analysis",
        description: "Analyze GitHub issue and produce structured implementation plan (Cost: Free)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .bestFree,
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
        id: prReviewId,
        name: "PR Review",
        description: "Review pull request and provide feedback (Cost: Free)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .bestFree,
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
        id: refactorId,
        name: "Refactor",
        description: "Deep refactoring with premium models for complex restructuring (Cost: Premium)",
        steps: [
          AgentStepTemplate(role: .planner, model: .bestPremium, name: "Architect"),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer"),
          AgentStepTemplate(role: .reviewer, model: .bestStandard, name: "Reviewer")
        ],
        isBuiltIn: true,
        category: .specialized
      ),

      // 9. Guarded Implementation: git stash + plan + implement + build gate + commit
      ChainTemplate(
        id: guardedImplementationId,
        name: "Guarded Implementation",
        description: "Deterministic setup, agentic work, then gate checks before completion (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "Setup",
            stepType: .deterministic,
            command: "git fetch origin && git diff --stat HEAD"
          ),
          AgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer"),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "Build Gate",
            stepType: .gate,
            command: "swift build 2>&1"
          ),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "Commit",
            stepType: .deterministic,
            command: "git add -A && git commit -m 'Agent implementation' --allow-empty"
          )
        ],
        isBuiltIn: true,
        category: .specialized
      ),

      // VM ISOLATED TEMPLATES

      // 10. VM Quick Task (Linux): Run a quick command inside an isolated Linux VM
      ChainTemplate(
        id: vmQuickTaskId,
        name: "VM Quick Task (Linux)",
        description: "Run a single command inside an isolated Linux VM with Git toolchain (Cost: Free)",
        steps: [
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "VM Exec",
            stepType: .deterministic,
            command: "cd /mnt/workspace && git status && ls -la"
          )
        ],
        isBuiltIn: true,
        category: .specialized,
        executionEnvironment: .linux,
        toolchain: .git
      ),

      // 11. VM Full Build (Linux): Plan on host, build+test inside Linux VM
      ChainTemplate(
        id: vmFullBuildId,
        name: "VM Full Build (Linux)",
        description: "Plan on host, execute build and tests inside an isolated Linux VM (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer"),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "VM Build Gate",
            stepType: .gate,
            command: "cd /mnt/workspace && swift build 2>&1"
          ),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "VM Test Gate",
            stepType: .gate,
            command: "cd /mnt/workspace && swift test 2>&1"
          ),
          AgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true,
        category: .specialized,
        executionEnvironment: .linux,
        toolchain: .swift
      ),

      // 12. VM Ember Build: Plan on host, build+lint Ember.js project inside Linux VM
      ChainTemplate(
        id: vmEmberBuildId,
        name: "VM Ember Build (Linux)",
        description: "Plan on host, build and lint Ember.js project inside an isolated Linux VM (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer"),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "VM Install Gate",
            stepType: .gate,
            command: "cd /mnt/workspace && npm ci 2>&1"
          ),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "VM Lint Gate",
            stepType: .gate,
            command: "cd /mnt/workspace && npm run lint 2>&1"
          ),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "VM Build Gate",
            stepType: .gate,
            command: "cd /mnt/workspace && ember build 2>&1"
          ),
          AgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true,
        category: .specialized,
        executionEnvironment: .linux,
        toolchain: .ember
      ),

      // YOLO TEMPLATES

      // 13. Yolo Agent (Any CLI): single autonomous agent step in Linux VM
      ChainTemplate(
        id: yoloAgentAnyCLIId,
        name: "Yolo Agent (Any CLI)",
        description: "Run a fully autonomous coding agent inside an isolated Linux VM. Specify agent binary and flags in your task prompt.",
        steps: [
          AgentStepTemplate(
            role: .implementer,
            model: .bestStandard,
            name: "VM Yolo Agent",
            customInstructions: """
              Execute the requested coding agent fully inside the Linux VM workspace.
              Treat the user's prompt as the source of truth for which CLI binary and flags to use.
              Prefer full-autonomy flags when provided, and complete the task end-to-end inside /mnt/workspace.
              """
          )
        ],
        isBuiltIn: true,
        category: .yolo,
        executionEnvironment: .linux,
        toolchain: .fullStack
      ),

      // 14. Yolo + Review: autonomous VM agent + gates + host review
      ChainTemplate(
        id: yoloReviewId,
        name: "Yolo + Review",
        description: "Autonomous VM execution followed by build/test gates and reviewer feedback (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .implementer,
            model: .bestStandard,
            name: "VM Yolo Agent",
            customInstructions: """
              Execute the coding task autonomously inside the Linux VM.
              Make all required code changes in /mnt/workspace before handing off to verification gates.
              """
          ),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "VM Build Gate",
            stepType: .gate,
            command: "cd /mnt/workspace && swift build 2>&1"
          ),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "VM Test Gate",
            stepType: .gate,
            command: "cd /mnt/workspace && swift test 2>&1"
          ),
          AgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true,
        category: .yolo,
        executionEnvironment: .linux,
        toolchain: .fullStack
      ),

      // 15. Yolo Copilot: pre-configured autonomous Copilot CLI usage in VM
      ChainTemplate(
        id: yoloCopilotId,
        name: "Yolo Copilot",
        description: "Pre-configured for Copilot CLI autonomous mode in isolated Linux VM (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .implementer,
            model: .bestStandard,
            name: "VM Copilot Yolo",
            customInstructions: """
              Run Copilot CLI inside the VM with full autonomy.
              Use flags equivalent to: --allow-all-tools --yolo.
              Complete the user's task end-to-end in /mnt/workspace and summarize changed files.
              """
          )
        ],
        isBuiltIn: true,
        category: .yolo,
        executionEnvironment: .linux,
        toolchain: .node
      ),

      // 16. Yolo Claude: pre-configured autonomous Claude CLI usage in VM
      ChainTemplate(
        id: yoloClaudeId,
        name: "Yolo Claude",
        description: "Pre-configured for Claude CLI with skip-permissions mode in isolated Linux VM (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .implementer,
            model: .claudeSonnet45,
            name: "VM Claude Yolo",
            customInstructions: """
              Run Claude CLI inside the VM in full-autonomy mode.
              Use flags equivalent to: --dangerously-skip-permissions.
              Complete all requested code changes in /mnt/workspace before finishing.
              """
          )
        ],
        isBuiltIn: true,
        category: .yolo,
        executionEnvironment: .linux,
        toolchain: .node
      )
    ]

    return templates
  }
}

/// Determines how a step in a chain is executed
public enum StepType: String, Codable, Hashable, Sendable, CaseIterable {
  /// Normal LLM-driven agent step (default)
  case agentic
  /// Shell command executed deterministically — no LLM involved
  case deterministic
  /// Shell command that acts as a quality gate — exit 0 passes, non-zero halts the chain
  case gate

  public var displayName: String {
    switch self {
    case .agentic: "Agentic"
    case .deterministic: "Deterministic"
    case .gate: "Gate"
    }
  }

  public var description: String {
    switch self {
    case .agentic: "LLM-driven agent step"
    case .deterministic: "Shell command (no LLM)"
    case .gate: "Quality gate — halts chain on failure"
    }
  }

  public var iconName: String {
    switch self {
    case .agentic: "brain"
    case .deterministic: "terminal"
    case .gate: "checkmark.shield"
    }
  }

  /// Whether this step type requires an LLM call
  public var requiresLLM: Bool {
    self == .agentic
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

  /// How this step executes: agentic (LLM), deterministic (shell), or gate (check)
  public var stepType: StepType

  /// Shell command to run for deterministic/gate steps (ignored for agentic)
  public var command: String?

  /// Tools explicitly allowed for this step (overrides role defaults; agentic only)
  public var allowedTools: [String]?

  /// Tools explicitly denied for this step (merged with role defaults; agentic only)
  public var deniedTools: [String]?
  
  public init(
    id: UUID = UUID(),
    role: AgentRole,
    model: CopilotModel,
    name: String,
    frameworkHint: FrameworkHint = .auto,
    customInstructions: String? = nil,
    stepType: StepType = .agentic,
    command: String? = nil,
    allowedTools: [String]? = nil,
    deniedTools: [String]? = nil
  ) {
    self.id = id
    self.role = role
    self.model = model
    self.name = name
    self.frameworkHint = frameworkHint
    self.customInstructions = customInstructions
    self.stepType = stepType
    self.command = command
    self.allowedTools = allowedTools
    self.deniedTools = deniedTools
  }
  
  /// Effective denied tools: merges per-step overrides with role defaults
  public var effectiveDeniedTools: [String] {
    let roleDenied = role.deniedTools
    let stepDenied = deniedTools ?? []
    return Array(Set(roleDenied + stepDenied)).sorted()
  }

  /// Estimated premium cost for this step
  public var estimatedCost: Double {
    // Deterministic/gate steps cost nothing
    guard stepType.requiresLLM else { return 0 }
    return model.premiumCost
  }
}

extension ChainTemplate {
  /// Total estimated premium cost for all steps
  public var estimatedTotalCost: Double {
    steps.reduce(0) { $0 + $1.estimatedCost }
  }

  /// Whether this template runs inside a VM
  public var requiresVM: Bool {
    executionEnvironment != .host
  }

  /// Human-readable execution environment label
  public var environmentLabel: String {
    if executionEnvironment == .host { return "Host" }
    let env = executionEnvironment.displayName
    if toolchain == .minimal { return env }
    return "\(env) (\(toolchain.displayName))"
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
  /// Note: This returns .copilot for GPT/Gemini only, since Copilot can run ALL models
  public var requiredProviders: Set<MCPCopilotModel.ModelProvider> {
    Set(steps.compactMap { $0.model.requiredProvider })
  }

  /// Check if all template models are available with current provider config
  /// - Copilot: Can run ALL models (Claude, GPT, Gemini)
  /// - Claude CLI: Can only run Claude models
  public func isFullyAvailable(copilotAvailable: Bool, claudeAvailable: Bool) -> Bool {
    steps.allSatisfy { step in
      let model = step.model
      // Copilot can run any model
      if copilotAvailable { return true }
      // Claude CLI can only run Claude models
      if claudeAvailable && model.modelFamily == .claude { return true }
      return false
    }
  }

  /// List of models that are unavailable with current provider config
  public func unavailableModels(copilotAvailable: Bool, claudeAvailable: Bool) -> [MCPCopilotModel] {
    steps.compactMap { step in
      let model = step.model
      // Copilot can run any model
      if copilotAvailable { return nil }
      // Claude CLI can only run Claude models
      if claudeAvailable && model.modelFamily == .claude { return nil }
      return model    }
  }
}