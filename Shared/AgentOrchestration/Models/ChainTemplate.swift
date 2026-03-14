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

/// Criteria for validating chain completion beyond simple file-change detection.
/// Attached to templates to enforce that implementation chains produce real code, not plans.
public struct CompletionCriteria: Codable, Hashable, Sendable {
  /// Require at least one file to be modified (default true for implementation chains)
  public var requiresFileChanges: Bool
  /// Glob patterns that changed files must match (e.g., ["*.swift", "*.ts"]). Empty = no restriction.
  public var requiredFilePatterns: [String]
  /// Glob patterns that changed files must NOT match (e.g., ["Plans/*.md"]). Empty = no restriction.
  public var forbiddenFilePatterns: [String]
  /// Require the build gate to pass before marking complete
  public var requiresBuildPass: Bool

  public init(
    requiresFileChanges: Bool = true,
    requiredFilePatterns: [String] = [],
    forbiddenFilePatterns: [String] = [],
    requiresBuildPass: Bool = false
  ) {
    self.requiresFileChanges = requiresFileChanges
    self.requiredFilePatterns = requiredFilePatterns
    self.forbiddenFilePatterns = forbiddenFilePatterns
    self.requiresBuildPass = requiresBuildPass
  }

  /// Default for implementation chains: require file changes, forbid plan-only output
  public static let implementation = CompletionCriteria(
    requiresFileChanges: true,
    forbiddenFilePatterns: ["Plans/*.md", "plans/*.md"]
  )

  /// No validation — for analysis/review-only chains
  public static let noValidation = CompletionCriteria(requiresFileChanges: false)
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

  /// When true, the parallel worktree run skips the review gate after chain completion.
  /// Useful for review-only chains (e.g. PR Review) that don't produce code to merge.
  public var skipReviewGate: Bool

  /// Post-completion validation criteria (file change requirements, forbidden patterns, etc.)
  public var completionCriteria: CompletionCriteria
  
  public var validationConfig: ValidationConfiguration
  
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
    case skipReviewGate
    case completionCriteria
    case validationConfig
  }
  
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
    skipReviewGate: Bool = false,
    completionCriteria: CompletionCriteria? = nil,
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
    self.skipReviewGate = skipReviewGate
    self.completionCriteria = completionCriteria ?? .implementation
    self.validationConfig = validationConfig ?? .default
  }

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
    self.skipReviewGate = try container.decodeIfPresent(Bool.self, forKey: .skipReviewGate) ?? false
    self.completionCriteria = try container.decodeIfPresent(CompletionCriteria.self, forKey: .completionCriteria) ?? .implementation
    self.validationConfig = try container.decodeIfPresent(ValidationConfiguration.self, forKey: .validationConfig) ?? .default
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
    if skipReviewGate {
      try container.encode(skipReviewGate, forKey: .skipReviewGate)
    }
    if completionCriteria != .implementation {
      try container.encode(completionCriteria, forKey: .completionCriteria)
    }
    try container.encode(validationConfig, forKey: .validationConfig)
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
  private static let deepPRReviewId           = UUID(uuidString: "A0000001-0011-4000-8000-000000000011")!
  private static let uxAuditId                = UUID(uuidString: "A0000001-0012-4000-8000-000000000012")!
  private static let uxRegressionId           = UUID(uuidString: "A0000001-0013-4000-8000-000000000013")!
  private static let uxFlowTestId             = UUID(uuidString: "A0000001-0014-4000-8000-000000000014")!
  private static let metaAgentId               = UUID(uuidString: "A0000001-0015-4000-8000-000000000015")!

  // MARK: - Auto-detect Shell Commands
  // Fallback commands used when no .peel/profile.json buildCommand is configured.

  /// Auto-detect build system and run the appropriate build command.
  /// Checks: package.json → Package.swift → *.xcodeproj → Makefile → skip.
  static let autoDetectBuildCommand = #"if [ -f package.json ]; then if grep -q '"build"' package.json; then if [ -f pnpm-lock.yaml ]; then pnpm run build 2>&1; elif [ -f yarn.lock ]; then yarn build 2>&1; elif [ -f bun.lockb ]; then bun run build 2>&1; else npm run build 2>&1; fi; else echo 'package.json found but no build script — skipping' >&2; exit 0; fi; elif [ -f Package.swift ]; then swift build 2>&1; elif ls *.xcodeproj 1>/dev/null 2>&1; then PROJ=$(basename *.xcodeproj .xcodeproj); SCHEME=$(xcodebuild -list -json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); schemes=d['project']['schemes']; name=d['project'].get('projectName',''); matches=[s for s in schemes if '(macOS)' in s]; matches=matches or [s for s in schemes if name and name.lower() in s.lower()]; matches=matches or [s for s in schemes if 'watchOS' not in s and 'iOS' not in s and 'tvOS' not in s]; print(matches[0] if matches else schemes[0])" 2>/dev/null || echo "$PROJ"); xcodebuild -quiet -scheme "$SCHEME" -destination 'platform=macOS' -derivedDataPath "$PWD/.build-gate-dd" build 2>&1; EXIT=$?; rm -rf "$PWD/.build-gate-dd" 2>/dev/null; exit $EXIT; elif [ -f Makefile ] || [ -f makefile ]; then make 2>&1; else echo 'No build system detected — skipping build gate' >&2; exit 0; fi"#

  /// Auto-detect lint:fix (simple — Full Implementation template).
  static let autoDetectLintFixCommand = """
    if [ -f package.json ]; then \
      if grep -q '"lint:fix"' package.json; then \
        if [ -f pnpm-lock.yaml ]; then pnpm run lint:fix 2>&1 || true; \
        elif [ -f yarn.lock ]; then yarn lint:fix 2>&1 || true; \
        else npm run lint:fix 2>&1 || true; fi; \
      fi; \
    fi
    """

  /// Auto-detect lint with fallback and multi-ecosystem support (Parallel Implementation template).
  static let autoDetectLintFullCommand = """
    if [ -f package.json ]; then \
      if grep -q '"lint:fix"' package.json; then \
        if [ -f pnpm-lock.yaml ]; then pnpm run lint:fix 2>&1 || true; \
        elif [ -f yarn.lock ]; then yarn lint:fix 2>&1 || true; \
        else npm run lint:fix 2>&1 || true; fi; \
      elif grep -q '"lint"' package.json; then \
        if [ -f pnpm-lock.yaml ]; then pnpm run lint 2>&1 || true; \
        elif [ -f yarn.lock ]; then yarn lint 2>&1 || true; \
        else npm run lint 2>&1 || true; fi; \
      fi; \
    elif [ -f Cargo.toml ]; then cargo clippy --fix --allow-staged 2>&1 || true; \
    elif [ -f Package.swift ]; then swift build 2>&1 || true; \
    fi
    """

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
        category: .core,
        completionCriteria: .noValidation
      ),
      
      // 3. Full Implementation: Planner + Implementer + Build Gate + Reviewer
      ChainTemplate(
        id: fullImplementationId,
        name: "Full Implementation",
        description: "Complete workflow with planning, implementation, build verification, lint fix, and review (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer"),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "Build Check",
            stepType: .gate,
            command: autoDetectBuildCommand
          ),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "Lint Fix",
            stepType: .deterministic,
            command: autoDetectLintFixCommand
          ),
          AgentStepTemplate(role: .reviewer, model: .bestFree, name: "Reviewer")
        ],
        isBuiltIn: true,
        category: .core
      ),
      
      // 4. Parallel Implementation: Planner + 2-3 Implementers + Lint Fix for multi-file work
      ChainTemplate(
        id: parallelImplementationId,
        name: "Parallel Implementation",
        description: "Planner with multiple parallel implementers for complex multi-file tasks (Cost: Standard)",
        steps: [
          AgentStepTemplate(role: .planner, model: .bestStandard, name: "Planner"),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer A"),
          AgentStepTemplate(role: .implementer, model: .gpt51Codex, name: "Implementer B"),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "Lint Fix",
            stepType: .deterministic,
            command: autoDetectLintFullCommand
          )
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
        category: .specialized,
        completionCriteria: .noValidation
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
        category: .specialized,
        completionCriteria: .noValidation
      ),
      
      // 7. PR Review: Review PR diff, suggest fixes, check for issues
      ChainTemplate(
        id: prReviewId,
        name: "PR Review",
        description: "Review pull request and provide feedback (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .bestStandard,
            name: "PR Reviewer",
            customInstructions: """
              You are a PR Review specialist. Analyze the pull request and provide thorough, actionable feedback.

              ## Step-by-step workflow

              1. **Fetch PR metadata**: Use `github.pr.get` with the owner, repo, and PR number.
                 - Note the title, description, author, labels, and size (additions/deletions).
                 - Record the `head_sha` for checking CI status later.

              2. **Get changed files**: Use `github.pr.files` to see the list of files changed with per-file patches.
                 - This gives you structured per-file diffs and stats.

              3. **Check existing reviews and comments**: Use `github.pr.reviews` and `github.pr.comments` to see what feedback has already been given. Don't repeat existing review feedback.

              4. **Check CI status**: Use `github.pr.checks` with the `head_sha` from step 1 as the `ref`.
                 - Note any failing checks.

              5. **If a worktree is available**, use `rag.search` to find related code patterns and understand the broader codebase context for the changes.

              6. **Analyze changes** — review the patches for:
                 - Code quality issues (naming, structure, complexity)
                 - Potential bugs, edge cases, or logic errors
                 - Security vulnerabilities (injection, auth, data exposure)
                 - Performance concerns (N+1 queries, unnecessary allocations)
                 - Missing error handling or test coverage
                 - Style consistency with the rest of the codebase

              7. **Produce a structured review** with:
                 - **Summary**: What the PR does in 1-2 sentences
                 - **Risk Assessment**: Low / Medium / High with reasoning
                 - **Issues Found**: Numbered list with severity and file/line references
                 - **Suggestions**: Improvements that aren't blocking
                 - **CI Status**: Pass/fail summary
                 - **Verdict**: APPROVE, REQUEST_CHANGES, or COMMENT with reasoning

              Be constructive—focus on actionable, specific feedback. Reference exact file paths and line numbers.
              """
          )
        ],
        isBuiltIn: true,
        category: .specialized,
        skipReviewGate: true,
        completionCriteria: .noValidation
      ),
      
      // 7b. Deep PR Review: Multi-step review with codebase analysis for large PRs
      ChainTemplate(
        id: deepPRReviewId,
        name: "Deep PR Review",
        description: "Multi-step PR review with codebase context and optional posting (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .bestStandard,
            name: "PR Analyzer",
            customInstructions: """
              You are a PR analysis specialist. Gather all context needed for a thorough review.

              1. Use `github.pr.get` to fetch PR metadata (title, body, size, labels, author).
              2. Use `github.pr.files` to get the list of changed files with patches.
              3. Use `github.pr.reviews` and `github.pr.comments` to read existing feedback.
              4. Use `github.pr.checks` with the `head_sha` to check CI status.
              5. If a worktree is available, use `rag.search` to find code related to each changed file—look for callers, tests, and related patterns.

              Output a structured analysis:
              - PR Summary (what it does, why)
              - Files changed with categorization (new feature / bug fix / refactor / test / config)
              - CI status summary
              - Existing review feedback summary
              - For each file: the patch, related code context from RAG, and initial observations
              """
          ),
          AgentStepTemplate(
            role: .reviewer,
            model: .bestStandard,
            name: "Code Reviewer",
            customInstructions: """
              You are an expert code reviewer. Using the analysis from step 1, perform a thorough review.

              For each changed file, evaluate:
              - **Correctness**: Logic errors, edge cases, off-by-one, null handling
              - **Security**: Injection, auth bypass, data exposure, unsafe deserialization
              - **Performance**: N+1 queries, unnecessary allocations, blocking calls
              - **Maintainability**: Naming, complexity, duplication, missing abstractions
              - **Testing**: Are changes tested? Are edge cases covered?
              - **Compatibility**: Breaking changes, API contract violations

              Produce a final review:
              ## Summary
              1-2 sentence overview.

              ## Risk Assessment
              LOW / MEDIUM / HIGH with reasoning.

              ## Critical Issues
              Numbered list. Each: severity (🔴 critical / 🟡 warning / 🔵 suggestion), file:line, description, suggested fix.

              ## Suggestions
              Non-blocking improvements.

              ## CI Status
              Pass/fail with details on failures.

              ## Verdict
              APPROVE / REQUEST_CHANGES / COMMENT with one-line reasoning.
              """
          ),
          AgentStepTemplate(
            role: .reviewer,
            model: .bestFree,
            name: "Review Confirmation",
            customInstructions: "Pause for user to review the analysis and confirm the verdict before posting to GitHub",
            stepType: .confirmationGate
          ),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "Review Poster",
            customInstructions: """
              You are a review posting assistant. Take the review from step 2 and post it to GitHub.

              IMPORTANT: You MUST use the `github.pr.review.create` MCP tool to post the review. \
              Do NOT use `gh` CLI, shell commands, or any other method — they will fail with \
              permission errors. The MCP tool is the only authorized way to post reviews.

              1. Parse the verdict from the review output:
                 - If verdict is APPROVE → event = "APPROVE"
                 - If verdict is REQUEST_CHANGES → event = "REQUEST_CHANGES"
                 - Otherwise → event = "COMMENT"

              2. Extract the owner, repo, and pull_number from the original prompt or \
                 prior step output.

              3. Use `github.pr.review.create` with these arguments:
                 - `owner`: the repository owner
                 - `repo`: the repository name
                 - `pull_number`: the PR number
                 - `body`: the full review text
                 - `event`: based on the verdict
                 - If there are file-specific issues with line numbers, include them as \
                   `comments` array entries

              4. Report what was posted (review ID, event type, number of inline comments).

              If the review text is unclear or you can't parse it, post as COMMENT to be safe.
              """
          )
        ],
        isBuiltIn: true,
        category: .specialized,
        skipReviewGate: true,
        completionCriteria: .noValidation
      ),

      // 8. Refactor: Deep analysis + careful implementation + thorough review
      ChainTemplate(
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
            command: autoDetectBuildCommand
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
      ),

      // SPECIALIZED: UX TESTING

      // 17. UX Audit: Parallel per-page visual audit using Chrome tools
      ChainTemplate(
        id: uxAuditId,
        name: "UX Audit",
        description: "Parallel per-page visual audit — discovers routes, screenshots each page, flags UI issues (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .bestStandard,
            name: "Route Discovery & Task Creation",
            customInstructions: """
              You are a UX audit planner. Your job is to discover the app's pages/routes and create parallel audit tasks.

              **Inputs** (from the user prompt):
              - `repoPath`: path to the repository
              - `appURL`: base URL of the running app (e.g. http://localhost:4200)
              - Optionally a list of specific routes to audit

              **Steps:**
              1. If specific routes were provided, use those. Otherwise, discover routes by:
                 - Search the codebase for route definitions (e.g. `router.js`, `Routes.swift`, `urls.py`, Next.js `pages/`)
                 - Look for navigation components, sidebar menus, or route configs
                 - List all unique user-facing pages/routes

              2. For each discovered route, create a parallel audit task using `parallel.create`:
                 - Set run-level `templateName: "Quick Task"` in the `parallel.create` call (avoids Build Check gates during UX audits)
                 - Set `useUXTesting: true` on every task
                 - Set `installDependencies: true` on every task (each worktree gets its own dev server)
                 - Do NOT set `apiBaseURL` — each task runs its own isolated app instance
                 - Each task prompt should instruct the agent to:
                   a. Navigate to its assigned route using `chrome.navigate`
                   b. Wait for the page to load using `chrome.wait`
                   c. Take a full-page screenshot using `chrome.screenshot` with a descriptive `savePath`
                   d. Take a DOM snapshot using `chrome.snapshot`
                   e. Evaluate the page against UX criteria (see below)
                   f. Report findings in structured Markdown

              3. Use `parallel.start` to begin execution.

              **UX Criteria for each task prompt:**
              - Layout: alignment, spacing, overflow, responsive issues
              - Typography: readability, hierarchy, contrast
              - Interactive elements: buttons, links, forms — are they accessible and labeled?
              - Error states: what happens with empty data? Missing content?
              - Accessibility: color contrast, alt text, ARIA labels, keyboard focus indicators
              - Performance: large images, excessive DOM nodes
              - Consistency: does the page match the style of the rest of the app?

              **Output:** A summary of how many routes were discovered and tasks created.
              """
          ),
          AgentStepTemplate(
            role: .reviewer,
            model: .bestStandard,
            name: "UX Audit Aggregator",
            customInstructions: """
              You are a UX audit reviewer. Aggregate the results from parallel page audits into a single report.

              **Steps:**
              1. Use `parallel.status` to check that all tasks completed.
              2. Collect the output from each completed task.
              3. Produce a unified UX Audit Report in Markdown:

              ## UX Audit Report

              ### Summary
              - Total pages audited: N
              - Issues found: N (critical: N, warning: N, info: N)
              - Screenshots collected: N

              ### Per-Page Findings
              For each page, summarize:
              - **Route**: /path
              - **Screenshot**: file path
              - **Issues**: numbered list with severity (🔴 critical / 🟡 warning / 🔵 info)
              - **Notes**: any positive observations

              ### Cross-Cutting Issues
              Issues that appear on multiple pages (e.g. inconsistent spacing, missing nav labels).

              ### Recommendations
              Prioritized list of fixes, grouped by effort (quick wins vs. larger changes).

              If any tasks failed, note them and explain what went wrong.
              """
          )
        ],
        isBuiltIn: true,
        category: .specialized,
        completionCriteria: .noValidation
      ),

      // 18. UX Regression: Before/after visual regression using screenshot diffing
      ChainTemplate(
        id: uxRegressionId,
        name: "UX Regression",
        description: "Parallel before/after visual regression checks with screenshot diffs (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .bestStandard,
            name: "Regression Task Planner",
            customInstructions: """
              You are a UX regression planner. Build parallel visual comparison tasks.

              Inputs expected in prompt:
              - `beforeBaseURL` (baseline app) and `afterBaseURL` (candidate app)
              - Optional `routes` list

              Steps:
              1. If routes are not provided, discover user-facing routes from router/navigation files.
              2. Create one parallel task per route using `parallel.create` with:
                 - run-level `templateName: "Quick Task"`
                 - task `useUXTesting: true`
                 - task `installDependencies: false` (external URLs)
              3. Each task must:
                 - `chrome.launch` in browser-only mode (`skipDevServer: true`)
                 - Navigate to `beforeBaseURL + route`, wait for stable selector, screenshot to `beforePath`
                 - Navigate to `afterBaseURL + route`, wait for same selector, screenshot to `afterPath`
                 - Run `chrome.diff` with `beforePath` and `afterPath`
                 - Return a structured result with diff metrics and artifact paths
              4. Start execution with `parallel.start`.

              Output: number of routes and created tasks.
              """
          ),
          AgentStepTemplate(
            role: .reviewer,
            model: .bestStandard,
            name: "Regression Report Aggregator",
            customInstructions: """
              Aggregate results from `parallel.status` into a UX Regression Report.

              Report sections:
              - Summary (pages compared, diffs over threshold)
              - Top regressions ranked by percent changed
              - Per-route details (before path, after path, diff path, metrics)
              - Recommended fixes and release risk
              """
          )
        ],
        isBuiltIn: true,
        category: .specialized,
        completionCriteria: .noValidation
      ),

      // 19. UX Flow Test: Multi-step UX validation for critical user journeys
      ChainTemplate(
        id: uxFlowTestId,
        name: "UX Flow Test",
        description: "Parallel flow validation for multi-step UX journeys (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .bestStandard,
            name: "Flow Decomposition Planner",
            customInstructions: """
              You are a UX flow planner. Convert high-level journeys into executable flow tasks.

              Inputs expected in prompt:
              - One or more named flows (example: login -> dashboard -> create record -> verify)
              - Base URL and optional credentials from repo profile

              Steps:
              1. Split each flow into deterministic UI checkpoints.
              2. Create one parallel task per flow using `parallel.create` with:
                 - run-level `templateName: "Quick Task"`
                 - task `useUXTesting: true`
                 - per-task prompt with exact steps, expected selectors, and success criteria
              3. Task prompt should require:
                 - `chrome.launch`
                 - `chrome.navigate`/`chrome.fill`/`chrome.click`/`chrome.wait` per checkpoint
                 - screenshot + DOM snapshot at key checkpoints
                 - immediate failure report at first broken checkpoint
              4. Start tasks via `parallel.start`.

              Output: created flow tasks and expected checkpoints per flow.
              """
          ),
          AgentStepTemplate(
            role: .reviewer,
            model: .bestStandard,
            name: "Flow Results Aggregator",
            customInstructions: """
              Build a UX Flow Test report from `parallel.status` results.

              Include:
              - Pass/fail per flow
              - First failing checkpoint and evidence artifacts
              - Common breakpoints across flows
              - Prioritized remediation list
              """
          )
        ],
        isBuiltIn: true,
        category: .specialized,
        completionCriteria: .noValidation
      ),

      // Meta-Agent: Self-improvement loop — analyze, plan, dispatch sub-chains
      ChainTemplate(
        id: metaAgentId,
        name: "Meta-Agent",
        description: "Self-improvement loop: reads mission, analyzes codebase via RAG, identifies work, dispatches sub-chains (Cost: Standard)",
        steps: [
          AgentStepTemplate(
            role: .planner,
            model: .bestStandard,
            name: "Meta Planner",
            customInstructions: """
              You are a Meta-Agent planner. Your job is to identify the highest-value
              improvements for this project and create implementation tasks.
              
              ## Steps
              1. Read the project mission: call `mission.get` with the repo path
              2. Search the codebase: use `rag.search` to understand structure and find issues
              3. Check open GitHub issues: use `github.issue.list` for existing work items
              4. Identify 3-5 high-value, mission-aligned improvements
              5. For each, write a detailed implementation prompt
              
              ## Output
              Output your findings as a structured plan. Each task should be:
              - Specific enough for a single coding agent to complete
              - Aligned with the project mission
              - Independent of other tasks (no ordering dependencies)
              
              Focus on: code quality, dead code removal, missing tests,
              deprecated pattern migration, and incomplete features.
              """
          ),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer A"),
          AgentStepTemplate(role: .implementer, model: .bestStandard, name: "Implementer B"),
          AgentStepTemplate(
            role: .implementer,
            model: .bestFree,
            name: "Build Check",
            stepType: .gate,
            command: autoDetectBuildCommand
          ),
          AgentStepTemplate(role: .reviewer, model: .bestFree, name: "Quality Reviewer")
        ],
        isBuiltIn: true,
        category: .specialized
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
  /// LLM coding agent running inside a VM sandbox (the VM agent CLI calls the LLM, not Peel)
  case vmAgentic
  /// Pauses the chain for user confirmation before continuing — no LLM or shell involved
  case confirmationGate
  /// Supervisor step that monitors child runs and can intervene (re-prompt, cancel, adjust)
  case manager
  /// Saves chain state to disk and optionally triggers app rebuild + relaunch.
  /// The chain resumes from this point after restart.
  case checkpoint

  public var displayName: String {
    switch self {
    case .agentic: "Agentic"
    case .deterministic: "Deterministic"
    case .gate: "Gate"
    case .vmAgentic: "VM Agent"
    case .confirmationGate: "Confirmation Gate"
    case .manager: "Manager"
    case .checkpoint: "Checkpoint"
    }
  }

  public var description: String {
    switch self {
    case .agentic: "LLM-driven agent step"
    case .deterministic: "Shell command (no LLM)"
    case .gate: "Quality gate — halts chain on failure"
    case .vmAgentic: "LLM agent running inside VM sandbox"
    case .confirmationGate: "Pauses chain for user confirmation"
    case .manager: "Supervisor that monitors and manages child runs"
    case .checkpoint: "Saves state and optionally rebuilds app"
    }
  }

  public var iconName: String {
    switch self {
    case .agentic: "brain"
    case .deterministic: "terminal"
    case .gate: "checkmark.shield"
    case .vmAgentic: "shield.checkmark"
    case .confirmationGate: "hand.raised.circle"
    case .manager: "person.badge.shield.checkmark"
    case .checkpoint: "arrow.clockwise.circle"
    }
  }

  /// Whether this step type requires an LLM call from Peel
  public var requiresLLM: Bool {
    self == .agentic || self == .manager
  }

  /// Whether this step type is an LLM-driven agent (agentic or vmAgentic).
  /// Used to distinguish real coding agents from gate/deterministic post-steps
  /// when deciding which steps to run in parallel.
  public var isAgentic: Bool {
    self == .agentic || self == .vmAgentic || self == .manager
  }
}

/// Configuration for a VM-sandboxed LLM coding agent (e.g. copilot, claude, aider)
public struct VMAgentConfig: Codable, Sendable, Hashable, Equatable {
  /// CLI binary name (e.g. "copilot", "claude", "aider")
  public var binaryName: String
  /// Shell command to install the binary inside the VM (nil if pre-installed)
  public var installCommand: String?
  /// CLI arguments passed to the agent binary
  public var arguments: [String]
  /// Extra environment variables to set before invoking the agent
  public var environment: [String: String]
  /// Maximum seconds to wait for the agent to complete (default 600)
  public var timeoutSeconds: Int

  public init(
    binaryName: String,
    installCommand: String? = nil,
    arguments: [String] = [],
    environment: [String: String] = [:],
    timeoutSeconds: Int = 600
  ) {
    self.binaryName = binaryName
    self.installCommand = installCommand
    self.arguments = arguments
    self.environment = environment
    self.timeoutSeconds = timeoutSeconds
  }

  public static func copilot(model: String = "gpt-4o") -> VMAgentConfig {
    VMAgentConfig(
      binaryName: "copilot",
      installCommand: "npm install -g @github/copilot-cli",
      arguments: ["--model", model, "--yolo"]
    )
  }

  public static func claude(model: String = "claude-sonnet-4-20250514") -> VMAgentConfig {
    VMAgentConfig(
      binaryName: "claude",
      installCommand: nil,
      arguments: ["--model", model, "--allowedTools", "all"]
    )
  }

  public static func aider(model: String = "gpt-4o") -> VMAgentConfig {
    VMAgentConfig(
      binaryName: "aider",
      installCommand: "pip install aider-chat",
      arguments: ["--model", model, "--yes"]
    )
  }

  public static func custom(
    binary: String,
    install: String?,
    args: [String],
    env: [String: String] = [:]
  ) -> VMAgentConfig {
    VMAgentConfig(
      binaryName: binary,
      installCommand: install,
      arguments: args,
      environment: env
    )
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

  /// Configuration for a VM-sandboxed agent (vmAgentic steps only)
  public var vmAgentConfig: VMAgentConfig?
  
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
    deniedTools: [String]? = nil,
    vmAgentConfig: VMAgentConfig? = nil
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
    self.vmAgentConfig = vmAgentConfig
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