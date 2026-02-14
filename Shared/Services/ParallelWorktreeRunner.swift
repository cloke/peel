//
//  ParallelWorktreeRunner.swift
//  Peel
//
//  Created on 1/21/26.
//

import Foundation
import Observation
import Git

// MARK: - Models

/// A task to be executed in a parallel worktree
struct WorktreeTask: Identifiable, Sendable {
  let id: UUID
  let title: String
  let description: String
  let prompt: String
  /// Optional file paths to focus on (for RAG grounding)
  var focusPaths: [String]
  
  init(
    id: UUID = UUID(),
    title: String,
    description: String,
    prompt: String,
    focusPaths: [String] = []
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.prompt = prompt
    self.focusPaths = focusPaths
  }
}

/// Status of a single worktree in a parallel run
enum ParallelWorktreeStatus: Sendable, Equatable {
  case pending
  case creatingWorktree
  case running
  case awaitingReview
  case reviewed
  case approved
  case rejected(String)
  case merging
  case merged
  case failed(String)
  case cancelled
  
  var isTerminal: Bool {
    switch self {
    case .merged, .failed, .cancelled, .rejected, .reviewed: return true
    default: return false
    }
  }
  
  var displayName: String {
    switch self {
    case .pending: return "Pending"
    case .creatingWorktree: return "Creating Worktree"
    case .running: return "Running"
    case .awaitingReview: return "Awaiting Review"
    case .reviewed: return "Reviewed"
    case .approved: return "Approved"
    case .rejected: return "Rejected"
    case .merging: return "Merging"
    case .merged: return "Merged"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    }
  }
}

/// Represents a worktree executing a task in a parallel run
@Observable
final class ParallelWorktreeExecution: Identifiable, @unchecked Sendable {
  let id: UUID
  let task: WorktreeTask
  var worktreePath: String?
  var branchName: String?
  var chainId: UUID?
  var status: ParallelWorktreeStatus = .pending {
    didSet {
      guard oldValue != status else { return }
      lastStatusChangeAt = Date()
    }
  }
  var lastStatusChangeAt: Date = Date()
  var startedAt: Date?
  var completedAt: Date?
  var output: String = ""
  var diffSummary: String?
  var filesChanged: Int = 0
  var insertions: Int = 0
  var deletions: Int = 0
  var mergeConflicts: [String] = []
  var ragSnippets: [RAGSnippet] = []
  var operatorGuidance: [String] = []
  
  /// RAG snippet injected into the prompt
  struct RAGSnippet: Identifiable, Sendable {
    let id = UUID()
    let filePath: String
    let startLine: Int
    let endLine: Int
    let snippet: String
    let relevanceScore: Float
  }
  
  init(task: WorktreeTask) {
    self.id = UUID()
    self.task = task
  }
  
  var duration: TimeInterval? {
    guard let start = startedAt else { return nil }
    let end = completedAt ?? Date()
    return end.timeIntervalSince(start)
  }
  
  var isReadyToMerge: Bool {
    status == .approved && mergeConflicts.isEmpty
  }
}

/// A parallel worktree run containing multiple executions
@Observable
final class ParallelWorktreeRun: Identifiable, @unchecked Sendable, Hashable {
  let id: UUID
  let name: String
  let projectPath: String
  let baseBranch: String
  var targetBranch: String?
  var templateName: String?
  var runOptions: AgentChainRunner.ChainRunOptions?
  var executions: [ParallelWorktreeExecution] = []
  var createdAt: Date
  var startedAt: Date?
  var completedAt: Date?
  var status: RunStatus = .pending
  var requireReviewGate: Bool = true
  var autoMergeOnApproval: Bool = false
  var isPaused: Bool = false
  var operatorGuidance: [String] = []
  
  enum RunStatus: Sendable, Equatable {
    case pending
    case running
    case awaitingReview
    case merging
    case completed
    case failed(String)
    case cancelled
    
    var displayName: String {
      switch self {
      case .pending: return "Pending"
      case .running: return "Running"
      case .awaitingReview: return "Awaiting Review"
      case .merging: return "Merging"
      case .completed: return "Completed"
      case .failed: return "Failed"
      case .cancelled: return "Cancelled"
      }
    }
  }
  
  init(
    id: UUID = UUID(),
    name: String,
    projectPath: String,
    baseBranch: String = "HEAD",
    requireReviewGate: Bool = true
  ) {
    self.id = id
    self.name = name
    self.projectPath = projectPath
    self.baseBranch = baseBranch
    self.requireReviewGate = requireReviewGate
    self.createdAt = Date()
  }
  
  static func == (lhs: ParallelWorktreeRun, rhs: ParallelWorktreeRun) -> Bool {
    lhs.id == rhs.id
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
  
  var progress: Double {
    guard !executions.isEmpty else { return 0 }
    // Only count successful completions (merged, approved, awaiting review) - not cancelled/failed
    let completed = executions.filter { execution in
      switch execution.status {
      case .merged, .approved, .awaitingReview, .reviewed:
        return true
      default:
        return false
      }
    }.count
    return Double(completed) / Double(executions.count)
  }

  static let hungThreshold: TimeInterval = 15 * 60

  var lastUpdatedAt: Date? {
    executions.map(\.lastStatusChangeAt).max()
  }

  var hungExecutionCount: Int {
    executions.filter { execution in
      switch execution.status {
      case .running, .creatingWorktree:
        return Date().timeIntervalSince(execution.lastStatusChangeAt) > Self.hungThreshold
      default:
        return false
      }
    }.count
  }

  var hasHungExecutions: Bool {
    hungExecutionCount > 0
  }
  
  var pendingReviewCount: Int {
    executions.filter { $0.status == .awaitingReview }.count
  }

  var rejectedCount: Int {
    executions.filter { if case .rejected = $0.status { return true }; return false }.count
  }
  
  var readyToMergeCount: Int {
    executions.filter { $0.isReadyToMerge }.count
  }
  
  var failedCount: Int {
    executions.filter { if case .failed = $0.status { return true }; return false }.count
  }
  
  var mergedCount: Int {
    executions.filter { $0.status == .merged }.count
  }
}

// MARK: - Runner Service

/// Orchestrates parallel worktree execution with Local RAG grounding
@MainActor
@Observable
final class ParallelWorktreeRunner {
  private actor ParallelRunGate {
    enum Mode {
      case running
      case paused
      case step
    }

    private var mode: Mode = .running
    private var continuation: CheckedContinuation<Void, Never>?

    func waitIfPaused() async {
      switch mode {
      case .running:
        return
      case .step:
        mode = .paused
        return
      case .paused:
        await withCheckedContinuation { continuation in
          self.continuation = continuation
        }
        if mode == .step {
          mode = .paused
        }
      }
    }

    func pause() {
      mode = .paused
    }

    func resume() {
      mode = .running
      continuation?.resume()
      continuation = nil
    }

    func step() {
      switch mode {
      case .running:
        mode = .step
      case .paused:
        mode = .step
        continuation?.resume()
        continuation = nil
      case .step:
        return
      }
    }
  }
  /// All parallel runs managed by this runner
  private(set) var runs: [ParallelWorktreeRun] = []

  /// Historical runs loaded from persistence (read-only snapshots)
  private(set) var historicalRuns: [ParallelRunSnapshot] = []
  
  /// Currently active run (if any)
  var activeRun: ParallelWorktreeRun? {
    runs.first { $0.status == .running || $0.status == .awaitingReview }
  }
  
  /// The workspace service for worktree management
  private let workspaceService: AgentWorkspaceService

  /// Agent manager for creating chains/agents
  private let agentManager: AgentManager

  /// Chain runner for executing tasks
  private let chainRunner: AgentChainRunner
  
  /// Local RAG store for grounding
  private var ragStore: LocalRAGStore?

  private let mcpLog = MCPLogService.shared
  
  /// Max concurrent worktrees
  var maxConcurrentWorktrees: Int = 4
  
  /// Active tasks for each execution
  private var executionTasks: [UUID: Task<Void, Never>] = [:]
  private var runGates: [UUID: ParallelRunGate] = [:]
  private var activeChainIds: [UUID: UUID] = [:]
  private var dataService: DataService?
  
  init(
    workspaceService: AgentWorkspaceService,
    agentManager: AgentManager,
    chainRunner: AgentChainRunner
  ) {
    self.workspaceService = workspaceService
    self.agentManager = agentManager
    self.chainRunner = chainRunner
  }
  
  /// Set the RAG store for grounding
  func setRAGStore(_ store: LocalRAGStore) {
    self.ragStore = store
  }

  func setDataService(_ service: DataService) {
    dataService = service
    // Load historical runs when data service is set
    loadHistoricalRuns()
  }

  /// Load historical runs from persistence
  func loadHistoricalRuns() {
    guard let dataService else { return }
    // Load recent snapshots, excluding any that match current in-memory runs
    let activeRunIds = Set(runs.map { $0.id.uuidString })
    historicalRuns = dataService.getRecentParallelRunSnapshots(limit: 50)
      .filter { !activeRunIds.contains($0.runId) }
  }
  
  // MARK: - Run Management
  
  /// Create a new parallel run with tasks
  func createRun(
    name: String,
    projectPath: String,
    tasks: [WorktreeTask],
    baseBranch: String = "HEAD",
    targetBranch: String? = nil,
    requireReviewGate: Bool = true,
    autoMergeOnApproval: Bool = false,
    templateName: String? = nil,
    runOptions: AgentChainRunner.ChainRunOptions? = nil
  ) -> ParallelWorktreeRun {
    let run = ParallelWorktreeRun(
      name: name,
      projectPath: projectPath,
      baseBranch: baseBranch,
      requireReviewGate: requireReviewGate
    )
    run.targetBranch = targetBranch
    run.autoMergeOnApproval = autoMergeOnApproval
    run.templateName = templateName
    run.runOptions = runOptions
    
    // Create executions for each task
    for task in tasks {
      let execution = ParallelWorktreeExecution(task: task)
      run.executions.append(execution)
    }
    
    runs.append(run)
    recordSnapshot(for: run)
    Task {
      await mcpLog.info("Parallel run created", metadata: [
        "runId": run.id.uuidString,
        "name": name,
        "taskCount": "\(tasks.count)",
        "templateName": templateName ?? "",
        "plannerModelSelection": "\(runOptions?.allowPlannerModelSelection ?? false)",
        "plannerScaling": "\(runOptions?.allowPlannerImplementerScaling ?? false)"
      ])
    }
    return run
  }
  
  /// Start a parallel run
  func startRun(_ run: ParallelWorktreeRun) async throws {
    guard run.status == .pending else {
      throw ParallelRunError.invalidState("Run is not in pending state")
    }
    let gate = ParallelRunGate()
    runGates[run.id] = gate
    defer { runGates[run.id] = nil }
    run.status = .running
    run.startedAt = Date()
    recordSnapshot(for: run)
    PeonPingService.shared.chainStarted(name: run.name)
    if let guidance = await buildRepoGuidance(repoPath: run.projectPath) {
      run.operatorGuidance.append(guidance)
      recordSnapshot(for: run)
    }
    await mcpLog.info("Parallel run started", metadata: [
      "runId": run.id.uuidString,
      "templateName": run.templateName ?? "",
      "taskCount": "\(run.executions.count)",
      "projectPath": run.projectPath
    ])
    
    // Ground each task with RAG snippets
    await groundTasksWithRAG(run)
    
    // Execute tasks in parallel with concurrency limit
    let concurrencyLimit = run.templateName == "Free Review" ? 1 : maxConcurrentWorktrees
    await withTaskGroup(of: Void.self) { group in
      var activeCount = 0
      var pendingExecutions = run.executions.filter { $0.status == .pending }
      
      while !pendingExecutions.isEmpty || activeCount > 0 {
        // Start new tasks up to the limit
        while activeCount < concurrencyLimit, let execution = pendingExecutions.first {
          pendingExecutions.removeFirst()
          activeCount += 1
          
          group.addTask { [weak self] in
            await self?.executeWorktree(execution, in: run)
          }
        }
        
        // Wait for one to complete
        if activeCount > 0 {
          await group.next()
          activeCount -= 1
        }
      }
    }
    
    // Update run status based on results
    updateRunStatus(run)
    recordSnapshot(for: run)
  }

  func pauseRun(_ run: ParallelWorktreeRun) async {
    run.isPaused = true
    if let gate = runGates[run.id] {
      await gate.pause()
    }
    let chainIds: [UUID] = run.executions.compactMap { execution in
      guard execution.status == .running, let chainId = execution.chainId else { return nil }
      return chainId
    }
    for chainId in chainIds {
      await chainRunner.pause(chainId: chainId)
    }
    recordSnapshot(for: run)
  }

  func resumeRun(_ run: ParallelWorktreeRun) async {
    run.isPaused = false
    if let gate = runGates[run.id] {
      await gate.resume()
    }
    let chainIds: [UUID] = run.executions.compactMap { execution in
      guard execution.status == .running, let chainId = execution.chainId else { return nil }
      return chainId
    }
    for chainId in chainIds {
      await chainRunner.resume(chainId: chainId)
    }
    recordSnapshot(for: run)
  }

  func addGuidance(_ guidance: String, to run: ParallelWorktreeRun, executionId: UUID? = nil) {
    let trimmed = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let executionId,
       let execution = run.executions.first(where: { $0.id == executionId }) {
      execution.operatorGuidance.append(trimmed)
    } else {
      run.operatorGuidance.append(trimmed)
    }
    recordSnapshot(for: run)
  }
  
  /// Execute a single worktree task
  private func executeWorktree(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun) async {
    if let gate = runGates[run.id] {
      await gate.waitIfPaused()
    }
    execution.status = .creatingWorktree
    execution.startedAt = Date()
    recordSnapshot(for: run)

    await mcpLog.info("Parallel worktree starting", metadata: [
      "runId": run.id.uuidString,
      "executionId": execution.id.uuidString,
      "taskTitle": execution.task.title
    ])
    
    do {
      // Create worktree
      let timestamp = Int(Date().timeIntervalSince1970)
      let sanitizedName = BranchNameSanitizer.sanitize(execution.task.title)
      let branchName = "parallel/\(sanitizedName)-\(timestamp)"
      
      let worktreePath = try await workspaceService.createWorktreeForChain(
        chainId: execution.id,
        chainName: execution.task.title,
        projectPath: run.projectPath,
        branchName: branchName
      )
      
      execution.worktreePath = worktreePath
      execution.branchName = branchName
      execution.status = .running
      recordSnapshot(for: run)
      
      // Build the grounded prompt
      let includeRAG = run.templateName != "Free Review"
      let groundedPrompt = buildGroundedPrompt(for: execution, run: run, includeRAG: includeRAG)
      
      // Execute the task (this would integrate with your existing chain runner)
      // For now, we simulate the execution
      let result = await executeTask(
        prompt: groundedPrompt,
        worktreePath: worktreePath,
        task: execution.task,
        run: run,
        execution: execution
      )
      
      // Update execution with results
      execution.output = result.output
      execution.diffSummary = result.diffSummary
      execution.filesChanged = result.filesChanged
      execution.insertions = result.insertions
      execution.deletions = result.deletions
      
      // Check for merge conflicts
      if let conflicts = result.mergeConflicts {
        execution.mergeConflicts = conflicts
      }
      
      // Set status based on review gate
      if run.requireReviewGate {
        execution.status = .awaitingReview
        PeonPingService.shared.worktreeNeedsReview(taskTitle: execution.task.title)
      } else {
        execution.status = .approved
        PeonPingService.shared.worktreeCompleted(taskTitle: execution.task.title)
      }
      
      execution.completedAt = Date()
      recordSnapshot(for: run)

      await mcpLog.info("Parallel worktree completed", metadata: [
        "runId": run.id.uuidString,
        "executionId": execution.id.uuidString,
        "filesChanged": "\(execution.filesChanged)",
        "insertions": "\(execution.insertions)",
        "deletions": "\(execution.deletions)",
        "status": execution.status.displayName
      ])
      
    } catch {
      execution.status = .failed(error.localizedDescription)
      execution.completedAt = Date()
      recordSnapshot(for: run)
      PeonPingService.shared.worktreeFailed(taskTitle: execution.task.title, error: error.localizedDescription)
      await mcpLog.error(error, context: "Parallel worktree failed", metadata: [
        "runId": run.id.uuidString,
        "executionId": execution.id.uuidString
      ])
    }
  }
  
  /// Build a prompt grounded with RAG snippets
  private func buildGroundedPrompt(
    for execution: ParallelWorktreeExecution,
    run: ParallelWorktreeRun,
    includeRAG: Bool
  ) -> String {
    var prompt = execution.task.prompt

    if includeRAG, !execution.ragSnippets.isEmpty {
      var contextSection = "\n\n## Relevant Code Context\n\n"
      contextSection += "The following code snippets are relevant to this task:\n\n"
      
      for snippet in execution.ragSnippets.prefix(2) {
        contextSection += "### \(snippet.filePath) (lines \(snippet.startLine)-\(snippet.endLine))\n"
        contextSection += "```\n\(snippet.snippet)\n```\n\n"
      }
      
      prompt = contextSection + "\n## Task\n\n" + prompt
    }
    
    let guidance = (run.operatorGuidance + execution.operatorGuidance)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if !guidance.isEmpty {
      let guidanceBlock = guidance.enumerated()
        .map { index, entry in "\(index + 1). \(entry)" }
        .joined(separator: "\n")
      prompt += "\n\n## Operator Guidance\n\n" + guidanceBlock + "\n"
    }

    return prompt
  }

  private func buildRepoGuidance(repoPath: String) async -> String? {
    var sections: [String] = []
    
    // Auto-seed Ember skills if this is an Ember project (Issue #263)
    if let dataService {
      let seededCount = await MainActor.run {
        DefaultSkillsService.autoSeedEmberSkillsIfNeeded(context: dataService.modelContext, repoPath: repoPath)
      }
      if seededCount > 0 {
        await mcpLog.info("Auto-seeded Ember skills", metadata: [
          "repoPath": repoPath,
          "skillsAdded": "\(seededCount)"
        ])
      }
    }
    
    if let dataService {
      let repoRemoteURL = await RepoRegistry.shared.registerRepo(at: repoPath)
      let skillsBlock = await MainActor.run {
        dataService.repoGuidanceSkillsBlockAndMarkApplied(repoPath: repoPath, repoRemoteURL: repoRemoteURL)
      }
      if let block = skillsBlock {
        sections.append(block)
      }
    }
    guard let ragStore else {
      return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
    let queries = [
      ".rubocop.yml",
      "rubocop",
      ".eslintrc",
      "eslint",
      "ruff",
      "flake8",
      "pyproject.toml lint",
      "swiftlint",
      "prettier",
      "style guide",
      "lint"
    ]
    var snippets: [LocalRAGSearchResult] = []
    for query in queries {
      do {
        let results = try await ragStore.search(query: query, repoPath: repoPath, limit: 2)
        snippets.append(contentsOf: results)
      } catch {
        await mcpLog.warning("Repo guidance search failed", metadata: [
          "query": query,
          "error": error.localizedDescription
        ])
      }
    }

    let unique = Dictionary(grouping: snippets, by: { $0.filePath })
      .compactMap { $0.value.first }
      .prefix(4)
    if !unique.isEmpty {
      let guidance = unique.map { result in
        let header = "- Follow repo lint/style rules in \(result.filePath)"
        let snippet = result.snippet
          .split(separator: "\n")
          .prefix(8)
          .joined(separator: "\n")
        return "\(header)\n\n\(snippet)"
      }.joined(separator: "\n\n")
      sections.append("## Repo Guidance\n\n\(guidance)")
    }

    guard !sections.isEmpty else { return nil }
    return sections.joined(separator: "\n\n")
  }
  
  /// Ground tasks with RAG snippets
  private func groundTasksWithRAG(_ run: ParallelWorktreeRun) async {
    guard let ragStore else { return }
    
    for execution in run.executions {
      // Search RAG for relevant snippets
      let query = execution.task.title + " " + execution.task.description
      
      do {
        let results = try await ragStore.search(
          query: query,
          repoPath: run.projectPath,
          limit: 5
        )
        
        execution.ragSnippets = results.map { result in
          ParallelWorktreeExecution.RAGSnippet(
            filePath: result.filePath,
            startLine: result.startLine,
            endLine: result.endLine,
            snippet: result.snippet,
            relevanceScore: 0.8 // RAG doesn't return scores yet
          )
        }
      } catch {
        // Continue without RAG grounding
        print("RAG grounding failed for task \(execution.task.title): \(error)")
      }
    }
  }
  
  /// Execute a task in a worktree using the agent chain runner
  private func executeTask(
    prompt: String,
    worktreePath: String,
    task: WorktreeTask,
    run: ParallelWorktreeRun,
    execution: ParallelWorktreeExecution
  ) async -> TaskExecutionResult {
    let template = preferredTemplate(for: run)
    let maxAttempts = 2
    var attempt = 1
    var lastSummary: AgentChainRunner.RunSummary?
    var lastOutput = ""

    while attempt <= maxAttempts {
      let chain = makeChain(from: template, workingDirectory: worktreePath, taskTitle: task.title)
      if let gate = runGates[run.id] {
        await gate.waitIfPaused()
      }
      execution.chainId = chain.id
      activeChainIds[execution.id] = chain.id

      let validationConfig = template?.validationConfig

      let runSummary = await chainRunner.runChain(
        chain,
        prompt: prompt,
        validationConfig: validationConfig,
        runOptions: run.runOptions
      )

      lastSummary = runSummary
      lastOutput = summarizeOutputs(runSummary.results, errorMessage: runSummary.errorMessage)

      let normalizedOutput = lastOutput.lowercased()
      let hitRateLimit = normalizedOutput.contains("rate limit")
        || normalizedOutput.contains("copilot failed")
        || (runSummary.errorMessage?.lowercased().contains("rate limit") ?? false)

      if hitRateLimit && attempt < maxAttempts {
        await mcpLog.warning("Rate limit detected, retrying task", metadata: [
          "taskTitle": task.title,
          "attempt": "\(attempt)",
          "nextAttempt": "\(attempt + 1)"
        ])
        await cleanupChain(chain)
        try? await Task.sleep(for: .seconds(60))
        attempt += 1
        continue
      }

      await cleanupChain(chain)
      activeChainIds.removeValue(forKey: execution.id)
      break
    }

    let diffStats = computeDiffStats(in: worktreePath)
    let gitStatus = runGit(args: ["status", "-sb"], at: worktreePath)

    if let runSummary = lastSummary {
      await mcpLog.info("Parallel worktree run summary", metadata: [
        "chainId": runSummary.chainId.uuidString,
        "taskTitle": task.title,
        "state": runSummary.stateDescription,
        "noWork": runSummary.noWorkReason ?? "",
        "filesChanged": "\(diffStats.filesChanged)",
        "insertions": "\(diffStats.insertions)",
        "deletions": "\(diffStats.deletions)",
        "gitStatus": gitStatus.replacingOccurrences(of: "\n", with: " ")
      ])
    }

    return TaskExecutionResult(
      output: lastOutput,
      diffSummary: diffStats.summary,
      filesChanged: diffStats.filesChanged,
      insertions: diffStats.insertions,
      deletions: diffStats.deletions,
      mergeConflicts: lastSummary?.mergeConflicts ?? []
    )
  }

  private func recordSnapshot(for run: ParallelWorktreeRun) {
    dataService?.recordParallelRunSnapshot(run: run)
  }

  private func preferredTemplate(for run: ParallelWorktreeRun) -> ChainTemplate? {
    let templates = agentManager.allTemplates
    if let templateName = run.templateName,
       let match = templates.first(where: { $0.name == templateName }) {
      return match
    }
    if let runOptions = run.runOptions,
       runOptions.allowPlannerModelSelection
        || runOptions.allowPlannerImplementerScaling
        || runOptions.maxImplementers != nil
        || runOptions.maxPremiumCost != nil {
      if let codeReview = templates.first(where: { $0.name == "Code Review" }) {
        return codeReview
      }
      if let harness = templates.first(where: { $0.name == "MCP Harness" }) {
        return harness
      }
    }
    if let freeReview = templates.first(where: { $0.name == "Free Review" }) {
      return freeReview
    }
    if let quick = templates.first(where: { $0.name == "Quick Fix" }) {
      return quick
    }
    if let free = templates.first(where: { $0.name == "MCP Harness (Free)" }) {
      return free
    }
    return templates.first
  }

  private func makeChain(
    from template: ChainTemplate?,
    workingDirectory: String,
    taskTitle: String
  ) -> AgentChain {
    if let template {
      return agentManager.createChainFromTemplate(template, workingDirectory: workingDirectory)
    }

    let chain = agentManager.createChain(name: taskTitle, workingDirectory: workingDirectory)
    let agent = agentManager.createAgent(
      name: "Implementer",
      type: .copilot,
      role: .implementer,
      model: .gpt5Mini,
      workingDirectory: workingDirectory
    )
    chain.addAgent(agent)
    return chain
  }

  private func summarizeOutputs(_ results: [AgentChainResult], errorMessage: String?) -> String {
    var sections: [String] = []
    if let errorMessage, !errorMessage.isEmpty {
      sections.append("Error: \(errorMessage)")
    }
    for result in results {
      sections.append("[\(result.agentName)]\n\(result.output)")
    }
    return sections.joined(separator: "\n\n")
  }

  private func computeDiffStats(in worktreePath: String) -> (summary: String?, filesChanged: Int, insertions: Int, deletions: Int) {
    let numstat = runGit(args: ["diff", "--numstat"], at: worktreePath)
    let lines = numstat.split(separator: "\n")
    var filesChanged = 0
    var insertions = 0
    var deletions = 0
    for line in lines {
      let parts = line.split(separator: "\t")
      guard parts.count >= 3 else { continue }
      filesChanged += 1
      if let ins = Int(parts[0]) {
        insertions += ins
      }
      if let del = Int(parts[1]) {
        deletions += del
      }
    }
    let summary = filesChanged > 0 ? runGit(args: ["diff", "--stat"], at: worktreePath) : nil
    return (summary?.isEmpty == false ? summary : nil, filesChanged, insertions, deletions)
  }

  private func runGit(args: [String], at path: String) -> String {
    let process = Process()
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func cleanupChain(_ chain: AgentChain) async {
    for agent in chain.agents {
      await agentManager.removeAgent(agent)
    }
    agentManager.removeChain(chain)
  }
  
  private struct TaskExecutionResult {
    let output: String
    let diffSummary: String?
    let filesChanged: Int
    let insertions: Int
    let deletions: Int
    let mergeConflicts: [String]?
  }
  
  /// Update run status based on execution results
  private func updateRunStatus(_ run: ParallelWorktreeRun) {
    let allTerminal = run.executions.allSatisfy { $0.status.isTerminal || $0.status == .approved || $0.status == .awaitingReview }
    let anyFailed = run.executions.contains { if case .failed = $0.status { return true }; return false }
    let anyAwaitingReview = run.executions.contains { $0.status == .awaitingReview }
    
    if anyFailed && run.executions.filter({ if case .failed = $0.status { return true }; return false }).count == run.executions.count {
      run.status = .failed("All tasks failed")
      PeonPingService.shared.chainFailed(name: run.name, error: "All tasks failed")
    } else if anyAwaitingReview {
      run.status = .awaitingReview
      PeonPingService.shared.needsReview(name: run.name)
    } else if allTerminal {
      run.completedAt = Date()
      run.status = .completed
      PeonPingService.shared.chainCompleted(name: run.name)
    }
  }
  
  // MARK: - Review Gate
  
  /// Approve an execution
  func approveExecution(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun) {
    guard execution.status == .awaitingReview else { return }
    execution.status = .approved
    
    // Check if auto-merge is enabled
    if run.autoMergeOnApproval && execution.isReadyToMerge {
      Task {
        try? await mergeExecution(execution, in: run)
      }
    }
    
    updateRunStatus(run)
  }
  
  /// Reject an execution
  func rejectExecution(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun, reason: String) {
    guard execution.status == .awaitingReview else { return }
    execution.status = .rejected(reason)
    updateRunStatus(run)
  }

  /// Mark an execution as reviewed (without approval)
  func markReviewed(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun) {
    guard execution.status == .awaitingReview else { return }
    execution.status = .reviewed
    updateRunStatus(run)
  }
  
  /// Approve all pending executions
  func approveAllPending(in run: ParallelWorktreeRun) {
    for execution in run.executions where execution.status == .awaitingReview {
      approveExecution(execution, in: run)
    }
  }

  /// Mark all pending executions as reviewed
  func markAllReviewed(in run: ParallelWorktreeRun) {
    for execution in run.executions where execution.status == .awaitingReview {
      markReviewed(execution, in: run)
    }
  }
  
  // MARK: - Merge Operations

  /// Resolve the actual branch name to merge into.
  /// If `targetBranch` is set, use that. Otherwise fall back to `baseBranch`.
  /// When baseBranch is "HEAD", resolve it to the concrete branch name so we
  /// don't accidentally merge into a detached HEAD state (which loses all work).
  private func resolveTargetBranch(for run: ParallelWorktreeRun) async throws -> String {
    let candidate = run.targetBranch ?? run.baseBranch

    // "HEAD" is not a real branch — resolve it to the current branch name
    if candidate == "HEAD" {
      let (output, exitCode) = await runGit(
        ["rev-parse", "--abbrev-ref", "HEAD"],
        in: run.projectPath
      )
      let resolved = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard exitCode == 0, !resolved.isEmpty, resolved != "HEAD" else {
        throw ParallelRunError.checkoutFailed(
          "Cannot merge: the project is in detached HEAD state and no target branch was specified"
        )
      }
      return resolved
    }
    return candidate
  }

  /// Run a git command off the main thread and return (stdout+stderr, exitCode).
  private func runGit(_ arguments: [String], in directoryPath: String) async -> (String, Int32) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: directoryPath)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
          try process.run()
          process.waitUntilExit()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          let output = String(data: data, encoding: .utf8) ?? ""
          continuation.resume(returning: (output, process.terminationStatus))
        } catch {
          continuation.resume(returning: (error.localizedDescription, -1))
        }
      }
    }
  }

  /// Merge a single execution
  func mergeExecution(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun) async throws {
    guard execution.status == .approved else {
      throw ParallelRunError.invalidState("Execution must be approved before merging")
    }

    guard execution.worktreePath != nil,
          let branchName = execution.branchName else {
      throw ParallelRunError.missingWorktree
    }

    execution.status = .merging

    do {
      // Resolve the real branch name (not "HEAD")
      let targetBranch = try await resolveTargetBranch(for: run)

      // Checkout the target branch (runs off main thread)
      let (checkoutOutput, checkoutExit) = await runGit(
        ["checkout", targetBranch],
        in: run.projectPath
      )

      guard checkoutExit == 0 else {
        throw ParallelRunError.checkoutFailed(
          "\(targetBranch): \(checkoutOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
      }

      // Merge the worktree branch
      let (mergeOutput, mergeExit) = await runGit(
        ["merge", branchName, "--no-edit"],
        in: run.projectPath
      )

      if mergeExit != 0 {
        if mergeOutput.contains("CONFLICT") || mergeOutput.contains("conflict") {
          // Abort the failed merge so the working tree is clean for the next execution
          _ = await runGit(["merge", "--abort"], in: run.projectPath)
          throw ParallelRunError.mergeConflict(branchName)
        }
        throw ParallelRunError.mergeFailed(mergeOutput.trimmingCharacters(in: .whitespacesAndNewlines))
      }

      execution.status = .merged

      // Cleanup the worktree
      try? await workspaceService.removeWorktreeForChain(chainId: execution.id)

    } catch let error as ParallelRunError {
      if case .mergeConflict = error {
        execution.mergeConflicts = ["Merge conflict detected"]
        execution.status = .approved // Reset to approved so user can resolve
      } else {
        execution.status = .failed("Merge failed: \(error.localizedDescription)")
      }
      throw error
    } catch {
      execution.status = .failed("Merge failed: \(error.localizedDescription)")
      throw error
    }
  }

  /// Merge all approved executions, continuing past individual failures.
  func mergeAllApproved(in run: ParallelWorktreeRun) async throws {
    run.status = .merging

    var firstError: Error?
    for execution in run.executions where execution.isReadyToMerge {
      do {
        try await mergeExecution(execution, in: run)
      } catch {
        // Record the first error but keep trying remaining executions
        if firstError == nil { firstError = error }
      }
    }

    updateRunStatus(run)

    // Surface the first error after attempting all merges
    if let firstError { throw firstError }
  }
  
  // MARK: - Run Control
  
  /// Cancel a run
  func cancelRun(_ run: ParallelWorktreeRun) async {
    run.status = .cancelled
    recordSnapshot(for: run)
    
    // Cancel all pending executions
    for execution in run.executions {
      if !execution.status.isTerminal {
        execution.status = .cancelled
      }
      
      // Cancel any running tasks
      if let task = executionTasks[execution.id] {
        task.cancel()
      }
    }
    
    // Cleanup worktrees
    for execution in run.executions {
      if execution.worktreePath != nil {
        try? await workspaceService.removeWorktreeForChain(chainId: execution.id)
      }
    }
    
    run.completedAt = Date()
    recordSnapshot(for: run)
  }
  
  /// Remove a completed run
  func removeRun(_ run: ParallelWorktreeRun) async {
    // Cleanup any remaining worktrees
    for execution in run.executions {
      try? await workspaceService.removeWorktreeForChain(chainId: execution.id)
    }
    
    runs.removeAll { $0.id == run.id }
  }
  
  /// Get a run by ID
  func getRun(id: UUID) -> ParallelWorktreeRun? {
    runs.first { $0.id == id }
  }
  
  /// Get an execution by ID
  func getExecution(id: UUID) -> (ParallelWorktreeExecution, ParallelWorktreeRun)? {
    for run in runs {
      if let execution = run.executions.first(where: { $0.id == id }) {
        return (execution, run)
      }
    }
    return nil
  }
}

// MARK: - Errors

enum ParallelRunError: LocalizedError {
  case invalidState(String)
  case missingWorktree
  case mergeConflict(String)
  case checkoutFailed(String)
  case mergeFailed(String)
  case taskFailed(String)
  
  var errorDescription: String? {
    switch self {
    case .invalidState(let message): return "Invalid state: \(message)"
    case .missingWorktree: return "Worktree not found"
    case .mergeConflict(let branch): return "Merge conflict with branch: \(branch)"
    case .checkoutFailed(let branch): return "Failed to checkout branch: \(branch)"
    case .mergeFailed(let message): return "Merge failed: \(message)"
    case .taskFailed(let message): return "Task failed: \(message)"
    }
  }
}
