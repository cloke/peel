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
  /// UUIDs of other tasks in the same run that must be .merged before this one starts
  var dependsOn: [UUID]
  /// When true, the runner will create a UX test session (dev server + headless Chrome)
  /// for this task and inject browser tool instructions into the prompt.
  var useUXTesting: Bool
  /// Base URL for the shared backend API (e.g., "http://localhost:3000" for Rails).
  /// Only used when useUXTesting is true.
  var apiBaseURL: String?

  init(
    id: UUID = UUID(),
    title: String,
    description: String,
    prompt: String,
    focusPaths: [String] = [],
    dependsOn: [UUID] = [],
    useUXTesting: Bool = false,
    apiBaseURL: String? = nil
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.prompt = prompt
    self.focusPaths = focusPaths
    self.dependsOn = dependsOn
    self.useUXTesting = useUXTesting
    self.apiBaseURL = apiBaseURL
  }
}

// MARK: - Conflict Resolution

/// A file that has merge conflicts, with its raw content (including conflict markers)
struct MergeConflictFile: Identifiable, Sendable {
  let id = UUID()
  let filePath: String
  var content: String
}

/// How to resolve a single conflicted file
enum ConflictResolution: Equatable {
  case ours
  case theirs
  case editor  // user edited the file directly in an external editor
}

/// Status of a single worktree in a parallel run
enum ParallelWorktreeStatus: Sendable, Equatable {
  case pending
  case waitingForDependencies
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
  case conflicted([String])  // associated value = list of conflicted file paths

  var isTerminal: Bool {
    switch self {
    case .merged, .failed, .cancelled, .rejected: return true
    default: return false
    }
  }

  var displayName: String {
    switch self {
    case .pending: return "Pending"
    case .waitingForDependencies: return "Waiting for Dependencies"
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
    case .conflicted: return "Conflicted"
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
  var conflictFiles: [MergeConflictFile] = []
  var ragSnippets: [RAGSnippet] = []
  var operatorGuidance: [String] = []
  /// Overrides task.prompt for this execution (set via parallel.retry amendedPrompt)
  var amendedPrompt: String?
  
  /// Per-step results from the agent chain (planner decisions, review verdicts, gate results)
  var chainStepResults: [ChainStepSummary] = []

  /// Compact per-step summary for logging and status exposure
  struct ChainStepSummary: Identifiable, Sendable {
    let id = UUID()
    let stepName: String
    let role: String
    let model: String
    let durationSeconds: Double?
    let premiumCost: Double
    let reviewVerdict: String?
    let plannerDecision: String?
    let gateResult: String?
    let outputPreview: String
  }

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
    status == .approved && conflictFiles.isEmpty
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
  /// When this run was created by `chains.run`, stores the original chain run UUID
  /// so `chains.run.status` / `chains.run.results` can find it.
  var sourceChainRunId: UUID?
  
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

  var reviewedCount: Int {
    executions.filter { $0.status == .reviewed }.count
  }

  var activeCount: Int {
    executions.filter {
      switch $0.status {
      case .pending, .waitingForDependencies, .creatingWorktree, .running: return true
      default: return false
      }
    }.count
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

  /// UX test orchestrator for Chrome-based parallel testing
  private var uxTestOrchestrator: UXTestOrchestrator?

  private let mcpLog = MCPLogService.shared
  
  /// Max concurrent worktrees
  var maxConcurrentWorktrees: Int = 4
  
  /// Active tasks for each execution
  private var executionTasks: [UUID: Task<Void, Never>] = [:]
  private var runGates: [UUID: ParallelRunGate] = [:]
  private var activeChainIds: [UUID: UUID] = [:]
  private var dataService: DataService?

  // Serial queue for auto-merge to prevent concurrent git index.lock collisions
  private var autoMergeQueue: [(ParallelWorktreeExecution, ParallelWorktreeRun)] = []
  private var isAutoMerging = false
  
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

  /// Set the UX test orchestrator for Chrome-based parallel testing
  func setUXTestOrchestrator(_ orchestrator: UXTestOrchestrator) {
    self.uxTestOrchestrator = orchestrator
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

  /// Create a single-task parallel run from a `chains.run` invocation, and start it immediately.
  ///
  /// This bridges the chain execution path into the parallel worktree infrastructure so that
  /// every MCP-dispatched chain appears in the Parallel Worktrees panel with the same
  /// review/approve/merge workflow.
  ///
  /// - Returns: The created `ParallelWorktreeRun` (already started in a background task).
  func createAndStartSingleTaskRun(
    prompt: String,
    projectPath: String,
    templateName: String? = nil,
    baseBranch: String = "HEAD",
    requireReviewGate: Bool = true,
    runOptions: AgentChainRunner.ChainRunOptions? = nil,
    sourceChainRunId: UUID? = nil,
    operatorGuidance: [String] = []
  ) -> ParallelWorktreeRun {
    let taskTitle = templateName.map { "Chain: \($0)" } ?? "Chain Run"
    let task = WorktreeTask(
      title: taskTitle,
      description: prompt,
      prompt: prompt
    )
    let run = createRun(
      name: taskTitle,
      projectPath: projectPath,
      tasks: [task],
      baseBranch: baseBranch,
      requireReviewGate: requireReviewGate,
      templateName: templateName,
      runOptions: runOptions
    )
    run.sourceChainRunId = sourceChainRunId
    run.operatorGuidance = operatorGuidance

    // Fire-and-forget start (same pattern as parallel.start handler)
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.startRun(run)
      } catch {
        await self.mcpLog.error("Single-task parallel run failed to start: \(error)", metadata: [
          "runId": run.id.uuidString
        ])
      }
    }
    return run
  }

  /// Wait for a parallel run to reach a terminal state.
  ///
  /// Polls the run's status at short intervals. Returns when the run is completed,
  /// failed, or cancelled — or when the optional timeout expires.
  func waitForRunCompletion(_ run: ParallelWorktreeRun, timeoutSeconds: Double? = nil) async -> ParallelWorktreeRun.RunStatus {
    let deadline: Date? = timeoutSeconds.map { Date().addingTimeInterval($0) }
    while true {
      switch run.status {
      case .completed, .failed, .cancelled:
        return run.status
      case .awaitingReview:
        // If there's no review gate, this is terminal-ish, but we should still wait
        // for the user to approve/merge. If there IS a review gate, also wait.
        // However, if ALL executions are in terminal states, we're done.
        let allTerminal = run.executions.allSatisfy { $0.status.isTerminal || $0.status == .awaitingReview || $0.status == .approved }
        if allTerminal && run.executions.contains(where: { $0.status == .awaitingReview }) {
          // Run is waiting for review — return so caller can report this state
          return run.status
        }
      default:
        break
      }
      if let deadline, Date() >= deadline {
        return run.status
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
  }

  /// Find a parallel run that was created by a specific `chains.run` invocation.
  func findRunBySourceChainRunId(_ chainRunId: UUID) -> ParallelWorktreeRun? {
    runs.first { $0.sourceChainRunId == chainRunId }
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
    
    await runSchedulingLoop(for: run)
    updateRunStatus(run)
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
  
  // MARK: - Scheduling Primitives

  /// Update dependency-blocked executions: transitions .waitingForDependencies → .pending when
  /// all upstream executions have been merged, and .pending → .waitingForDependencies when not.
  private func resolveWaitingExecutions(in run: ParallelWorktreeRun) {
    guard run.executions.contains(where: { !$0.task.dependsOn.isEmpty }) else { return }
    let mergedIds = Set(run.executions.filter { $0.status == .merged }.map { $0.id })
    // Build set of IDs that are permanently non-mergeable (failed/rejected/cancelled only — NOT .reviewed)
    let blockedIds: Set<UUID> = Set(run.executions.compactMap { exec -> UUID? in
      switch exec.status {
      case .failed, .rejected, .cancelled: return exec.id
      default: return nil
      }
    })
    // Cascade-fail executions whose dependency is permanently blocked
    var didCascade = false
    for execution in run.executions where execution.status == .pending || execution.status == .waitingForDependencies {
      if let blockedDep = execution.task.dependsOn.first(where: { blockedIds.contains($0) }),
         let depTitle = run.executions.first(where: { $0.id == blockedDep })?.task.title {
        execution.status = .failed("Dependency \"\(depTitle)\" failed or was rejected")
        didCascade = true
      }
    }
    if didCascade { recordSnapshot(for: run) }
    // Transition waiting ↔ pending based on merged deps
    for execution in run.executions where execution.status == .pending || execution.status == .waitingForDependencies {
      let satisfied = execution.task.dependsOn.allSatisfy { mergedIds.contains($0) }
      if satisfied {
        if execution.status == .waitingForDependencies { execution.status = .pending }
      } else {
        execution.status = .waitingForDependencies
      }
    }
  }

  /// Core scheduling loop. Handles dependsOn resolution and tasks appended mid-run.
  /// Uses execution.status = .creatingWorktree as a synchronous claim to prevent
  /// multiple concurrent drain loops from double-scheduling the same execution.
  private func runSchedulingLoop(for run: ParallelWorktreeRun) async {
    let concurrencyLimit = run.templateName == "Free Review" ? 1 : maxConcurrentWorktrees
    await withTaskGroup(of: Void.self) { [weak self] group in
      guard let self else { return }
      // Initial scheduling pass
      self.resolveWaitingExecutions(in: run)
      let initialFlight = run.executions.filter { $0.status == .creatingWorktree || $0.status == .running }.count
      for execution in run.executions.filter({ $0.status == .pending }).prefix(max(0, concurrencyLimit - initialFlight)) {
        execution.status = .creatingWorktree  // Claim synchronously before suspension
        group.addTask { [weak self] in await self?.executeWorktree(execution, in: run) }
      }
      // Drain loop
      while await group.next() != nil {
        self.resolveWaitingExecutions(in: run)
        let active = run.executions.filter { $0.status == .creatingWorktree || $0.status == .running }.count
        for execution in run.executions.filter({ $0.status == .pending }).prefix(max(0, concurrencyLimit - active)) {
          execution.status = .creatingWorktree
          group.addTask { [weak self] in await self?.executeWorktree(execution, in: run) }
        }
      }
    }
  }

  // MARK: - Append & Retry (#295–#298)

  /// Append new tasks to an active or paused run. Kicks a new scheduling pass if the
  /// run's own loop has already completed (e.g. all current tasks are awaiting review).
  /// - Throws: `ParallelRunError.invalidState` if the run is completed, cancelled, or failed.
  func appendTasks(_ tasks: [WorktreeTask], to run: ParallelWorktreeRun) throws {
    switch run.status {
    case .completed, .cancelled, .failed:
      throw ParallelRunError.invalidState("Cannot append tasks to a \(run.status.displayName) run")
    default: break
    }
    for task in tasks {
      run.executions.append(ParallelWorktreeExecution(task: task))
    }
    recordSnapshot(for: run)
    // If the scheduler loop is still active (run.status == .running), it will pick up the new
    // pending executions via scheduleNext(). Otherwise kick a fresh drain.
    if run.status != .running {
      run.status = .running
      Task { [weak self] in
        guard let self else { return }
        await self.runSchedulingLoop(for: run)
        self.updateRunStatus(run)
      }
    }
  }

  /// Re-queue a failed, rejected, reviewed, or cancelled execution, optionally with an
  /// amended prompt and/or additional guidance.
  func retryExecution(
    _ execution: ParallelWorktreeExecution,
    in run: ParallelWorktreeRun,
    amendedPrompt: String? = nil,
    guidance: String? = nil
  ) async throws {
    guard execution.status.isTerminal else {
      throw ParallelRunError.invalidState(
        "Only terminal executions can be retried (current: \(execution.status.displayName))"
      )
    }
    let runIsTerminal: Bool
    switch run.status {
    case .cancelled: throw ParallelRunError.invalidState("Cannot retry in a cancelled run")
    case .completed, .failed, .awaitingReview: runIsTerminal = true
    default: runIsTerminal = false
    }
    // Clean up old worktree
    try? await workspaceService.removeWorktreeForChain(chainId: execution.id)
    // Reset execution state
    execution.status = .pending
    execution.output = ""
    execution.diffSummary = nil
    execution.filesChanged = 0
    execution.insertions = 0
    execution.deletions = 0
    execution.conflictFiles = []
    execution.worktreePath = nil
    execution.branchName = nil
    execution.chainId = nil
    execution.startedAt = nil
    execution.completedAt = nil
    if let p = amendedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
      execution.amendedPrompt = p
    }
    if let g = guidance?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
      execution.operatorGuidance.append(g)
    }
    if runIsTerminal {
      run.status = .running
    }
    recordSnapshot(for: run)
    if runIsTerminal {
      Task { [weak self] in
        guard let self else { return }
        await self.runSchedulingLoop(for: run)
        self.updateRunStatus(run)
      }
    }
  }

  /// Return the unified git diff for an execution's branch vs the run's base branch.
  /// Safe to call on @MainActor — delegates blocking subprocess to a background queue.
  func diffExecution(
    _ execution: ParallelWorktreeExecution,
    in run: ParallelWorktreeRun,
    maxLines: Int? = nil
  ) async -> String {
    guard let branchName = execution.branchName else {
      return "(no branch — execution has not started yet)"
    }
    let base = run.baseBranch == "HEAD" ? "HEAD" : run.baseBranch
    let (diff, _) = await runGit(["diff", "\(base)...\(branchName)"], in: run.projectPath)
    let result = diff.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.isEmpty { return "(no changes compared to \(base))" }
    guard let maxLines else { return result }
    let lines = result.components(separatedBy: "\n")
    guard lines.count > maxLines else { return result }
    return lines.prefix(maxLines).joined(separator: "\n")
      + "\n\n... (truncated: \(lines.count - maxLines) more lines)"
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
      PeonPingService.shared.agentStarted(name: execution.task.title)
      recordSnapshot(for: run)

      // Create UX test session if this task needs browser access
      if execution.task.useUXTesting, let orchestrator = uxTestOrchestrator {
        do {
          let uxSession = try await orchestrator.createSession(
            sessionId: execution.id,
            worktreePath: worktreePath
          )
          await mcpLog.info("UX session created for worktree", metadata: [
            "executionId": execution.id.uuidString,
            "devServerPort": "\(uxSession.devServerPort)",
            "chromeDebugPort": "\(uxSession.chromeDebugPort)",
            "devServerURL": uxSession.devServerURL
          ])
        } catch {
          await mcpLog.warning("UX session creation failed, continuing without browser: \(error.localizedDescription)", metadata: [
            "executionId": execution.id.uuidString
          ])
        }
      }

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
      execution.chainStepResults = result.chainStepResults
      
      // Populate conflict files from pre-merge detection (if any)
      if let conflicts = result.mergeConflicts, !conflicts.isEmpty {
        execution.conflictFiles = conflicts.map { MergeConflictFile(filePath: $0, content: "") }
      }
      
      // Set status based on review verdict, review gate, and chain outcome
      if !result.chainSucceeded {
        execution.status = .failed("Chain failed — check output for gate or step errors")
        PeonPingService.shared.worktreeFailed(taskTitle: execution.task.title, error: "Gate or step failed")
      } else if let verdict = result.reviewVerdict, verdict == .rejected {
        execution.status = .rejected("Reviewer rejected: see chain log for details")
      } else if run.requireReviewGate {
        execution.status = .awaitingReview
        PeonPingService.shared.worktreeNeedsReview(taskTitle: execution.task.title)
      } else {
        execution.status = .approved
        PeonPingService.shared.worktreeCompleted(taskTitle: execution.task.title)
      }
      
      execution.completedAt = Date()
      recordSnapshot(for: run)

      // Tear down UX session if one was created
      if execution.task.useUXTesting, let orchestrator = uxTestOrchestrator {
        await orchestrator.teardownSession(sessionId: execution.id)
      }

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
      // Tear down UX session on failure too
      if execution.task.useUXTesting, let orchestrator = uxTestOrchestrator {
        await orchestrator.teardownSession(sessionId: execution.id)
      }
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
    var prompt = execution.amendedPrompt ?? execution.task.prompt

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

    // Inject UX testing context if a browser session exists for this execution
    if execution.task.useUXTesting, let orchestrator = uxTestOrchestrator,
       let uxContext = orchestrator.buildPromptContext(for: execution.id) {
      prompt += "\n\n" + uxContext + "\n"
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

    // Extract per-step summaries from chain results
    var stepSummaries: [ParallelWorktreeExecution.ChainStepSummary] = []
    var reviewVerdict: ReviewVerdict?

    if let runSummary = lastSummary {
      for result in runSummary.results {
        let outputPreview = String(result.output.prefix(500))
        let durationSec: Double? = result.duration.flatMap { Double($0) }

        let verdictStr = result.reviewVerdict?.rawValue
        let plannerStr: String? = result.plannerDecision.map { decision in
          if decision.shouldSkipWork { return "skip: \(decision.noWorkReason ?? "no work needed")" }
          return "\(decision.tasks.count) tasks planned"
        }
        let gateStr = result.gateResult?.displayName

        stepSummaries.append(ParallelWorktreeExecution.ChainStepSummary(
          stepName: result.agentName,
          role: result.agentName.lowercased().contains("planner") ? "planner"
            : result.agentName.lowercased().contains("review") ? "reviewer"
            : result.gateResult != nil ? "gate"
            : "implementer",
          model: result.model,
          durationSeconds: durationSec,
          premiumCost: result.premiumCost,
          reviewVerdict: verdictStr,
          plannerDecision: plannerStr,
          gateResult: gateStr,
          outputPreview: outputPreview
        ))

        // Capture last reviewer verdict
        if let verdict = result.reviewVerdict {
          reviewVerdict = verdict
        }

        // Record per-step result to SwiftData for post-mortem
        dataService?.recordMCPRunResult(
          chainId: result.agentId.uuidString,
          agentId: result.id.uuidString,
          agentName: result.agentName,
          model: result.model,
          prompt: result.prompt,
          output: result.output,
          premiumCost: result.premiumCost,
          reviewVerdict: result.reviewVerdict?.rawValue
        )
      }

      // Write chain log JSON to worktree for post-mortem analysis
      writeChainLogFile(
        worktreePath: worktreePath,
        runSummary: runSummary,
        taskTitle: task.title,
        stepSummaries: stepSummaries
      )

      // Log per-step summary
      await mcpLog.info("Parallel worktree run summary", metadata: [
        "chainId": runSummary.chainId.uuidString,
        "taskTitle": task.title,
        "state": runSummary.stateDescription,
        "noWork": runSummary.noWorkReason ?? "",
        "steps": "\(stepSummaries.count)",
        "reviewVerdict": reviewVerdict?.rawValue ?? "none",
        "templateName": template?.name ?? "bare-implementer"
      ])
    }

    let diffStats = computeDiffStats(in: worktreePath)
    let gitStatus = runGit(args: ["status", "-sb"], at: worktreePath)

    if let runSummary = lastSummary {
      await mcpLog.info("Parallel worktree diff stats", metadata: [
        "chainId": runSummary.chainId.uuidString,
        "taskTitle": task.title,
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
      mergeConflicts: lastSummary?.mergeConflicts ?? [],
      chainSucceeded: lastSummary?.stateDescription.lowercased() != "failed",
      reviewVerdict: reviewVerdict,
      chainStepResults: stepSummaries
    )
  }

  private func recordSnapshot(for run: ParallelWorktreeRun) {
    dataService?.recordParallelRunSnapshot(run: run)
  }

  /// Write a structured JSON chain log file to the worktree for post-mortem analysis
  private func writeChainLogFile(
    worktreePath: String,
    runSummary: AgentChainRunner.RunSummary,
    taskTitle: String,
    stepSummaries: [ParallelWorktreeExecution.ChainStepSummary]
  ) {
    let formatter = Formatter.iso8601
    let steps: [[String: Any]] = runSummary.results.map { result in
      var step: [String: Any] = [
        "agentName": result.agentName,
        "model": result.model,
        "premiumCost": result.premiumCost,
        "timestamp": formatter.string(from: result.timestamp),
        "output": result.output
      ]
      if let duration = result.duration {
        step["duration"] = duration
      }
      if let verdict = result.reviewVerdict {
        step["reviewVerdict"] = verdict.rawValue
      }
      if let decision = result.plannerDecision {
        step["plannerDecision"] = [
          "branch": decision.branch,
          "taskCount": decision.tasks.count,
          "noWorkReason": decision.noWorkReason as Any,
          "tasks": decision.tasks.map { ["title": $0.title, "description": $0.description] }
        ] as [String: Any]
      }
      if let gate = result.gateResult {
        step["gateResult"] = gate.displayName
      }
      if let screenshot = result.screenshotPath {
        step["screenshotPath"] = screenshot
      }
      return step
    }

    let logPayload: [String: Any] = [
      "chainId": runSummary.chainId.uuidString,
      "chainName": runSummary.chainName,
      "taskTitle": taskTitle,
      "state": runSummary.stateDescription,
      "noWorkReason": runSummary.noWorkReason as Any,
      "errorMessage": runSummary.errorMessage as Any,
      "timestamp": formatter.string(from: Date()),
      "steps": steps
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: logPayload, options: [.prettyPrinted, .sortedKeys]),
          let json = String(data: data, encoding: .utf8) else { return }

    let logPath = (worktreePath as NSString).appendingPathComponent(".peel-chain-log.json")
    try? json.write(toFile: logPath, atomically: true, encoding: .utf8)
  }

  private func preferredTemplate(for run: ParallelWorktreeRun) -> ChainTemplate? {
    let templates = agentManager.allTemplates
    // 1. Explicit template name from the run takes priority
    if let templateName = run.templateName,
       let match = templates.first(where: { $0.name == templateName }) {
      return match
    }
    // 2. When run options request advanced features, use Full Implementation
    //    (Planner + Implementer + Build Gate + Reviewer)
    if let runOptions = run.runOptions,
       runOptions.allowPlannerModelSelection
        || runOptions.allowPlannerImplementerScaling
        || runOptions.maxImplementers != nil
        || runOptions.maxPremiumCost != nil {
      if let full = templates.first(where: { $0.name == "Full Implementation" }) {
        return full
      }
    }
    // 3. Default: Full Implementation — every parallel worktree task deserves
    //    at least a planner + implementer + reviewer to catch problems early
    if let full = templates.first(where: { $0.name == "Full Implementation" }) {
      return full
    }
    // 4. Fallback: Quick Task (single implementer, free model)
    if let quick = templates.first(where: { $0.name == "Quick Task" }) {
      return quick
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
    let chainSucceeded: Bool
    let reviewVerdict: ReviewVerdict?
    let chainStepResults: [ParallelWorktreeExecution.ChainStepSummary]
  }
  
  /// Update run status based on execution results and record a snapshot.
  private func updateRunStatus(_ run: ParallelWorktreeRun) {
    let allTerminal = run.executions.allSatisfy {
      if $0.status.isTerminal { return true }
      if $0.status == .approved { return true }
      if $0.status == .awaitingReview { return true }
      if case .conflicted = $0.status { return true }
      return false
    }
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
      // Run integration build check in the background after all merges land
      Task { [weak self] in
        await self?.runPostMergeBuildCheck(for: run)
      }
    }

    // Always persist the latest state so history snapshots are never stale.
    recordSnapshot(for: run)
  }
  
  // MARK: - Review Gate
  
  /// Approve an execution (from awaitingReview or reviewed state)
  func approveExecution(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun) {
    guard execution.status == .awaitingReview || execution.status == .reviewed else { return }
    execution.status = .approved
    
    // Check if auto-merge is enabled
    if run.autoMergeOnApproval && execution.isReadyToMerge {
      enqueueAutoMerge(execution, in: run)
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

  /// Enqueue an auto-merge and start processing if not already running.
  /// Serializes merges to prevent concurrent git index.lock collisions.
  private func enqueueAutoMerge(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun) {
    autoMergeQueue.append((execution, run))
    if !isAutoMerging {
      processAutoMergeQueue()
    }
  }

  private func processAutoMergeQueue() {
    guard !autoMergeQueue.isEmpty else {
      isAutoMerging = false
      return
    }
    isAutoMerging = true
    let (execution, run) = autoMergeQueue.removeFirst()
    Task {
      do {
        try await mergeExecution(execution, in: run)
      } catch {
        // mergeExecution already sets execution.status on failure;
        // log and record a snapshot so the UI reflects the failure immediately.
        await mcpLog.error(error, context: "Auto-merge failed", metadata: [
          "runId": run.id.uuidString,
          "executionId": execution.id.uuidString,
          "task": execution.task.title
        ])
        recordSnapshot(for: run)
      }
      // Continue draining the queue regardless of success/failure
      processAutoMergeQueue()
    }
  }

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

  /// Run a shell command off the main thread and return (stdout+stderr, exitCode).
  private func runShell(_ command: String, in directoryPath: String) async -> (String, Int32) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: directoryPath)
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        process.environment = env

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

  /// Run a build check after all merges in a run have completed.
  /// Catches integration issues where branches compile individually but conflict together.
  private func runPostMergeBuildCheck(for run: ParallelWorktreeRun) async {
    let mergedCount = run.executions.filter { $0.status == .merged }.count
    guard mergedCount > 0 else { return }

    await mcpLog.info("Running post-merge integration build check", metadata: [
      "runId": run.id.uuidString,
      "mergedCount": "\(mergedCount)"
    ])

    let command = #"if [ -f Package.swift ]; then swift build 2>&1; elif ls *.xcodeproj 1>/dev/null 2>&1; then xcodebuild -quiet build 2>&1; elif [ -f Makefile ] || [ -f makefile ]; then make 2>&1; else echo 'SKIP: No build system detected'; exit 0; fi"#

    let (output, exitCode) = await runShell(command, in: run.projectPath)
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

    if exitCode == 0 {
      await mcpLog.info("Post-merge integration build PASSED", metadata: [
        "runId": run.id.uuidString
      ])
      run.operatorGuidance.append("Post-merge integration build passed")
    } else {
      await mcpLog.warning("Post-merge integration build FAILED", metadata: [
        "runId": run.id.uuidString,
        "output": String(trimmed.suffix(1000))
      ])
      run.operatorGuidance.append("Post-merge integration build FAILED — manual review needed. Last output: \(String(trimmed.suffix(500)))")
    }
    recordSnapshot(for: run)
  }

  /// Merge a single execution
  func mergeExecution(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun) async throws {
    guard execution.status == .approved else {
      throw ParallelRunError.invalidState("Execution must be approved before merging")
    }

    guard let branchName = execution.branchName else {
      throw ParallelRunError.missingWorktree
    }

    // Check if the branch still exists — if not, it was likely already merged and cleaned up
    let (_, branchCheckExit) = await runGit(
      ["rev-parse", "--verify", branchName],
      in: run.projectPath
    )
    if branchCheckExit != 0 {
      // Branch doesn't exist. Verify it's already been merged into the target.
      let targetBranch = (try? await resolveTargetBranch(for: run)) ?? "main"
      let (mergedBranches, _) = await runGit(
        ["branch", "--merged", targetBranch, "--list", branchName],
        in: run.projectPath
      )
      // Also check if the branch name appears in the log (it may have been deleted after merge)
      let (logCheck, logExit) = await runGit(
        ["log", "--oneline", "--grep=Merge branch '\(branchName)'", "-1", targetBranch],
        in: run.projectPath
      )
      let wasLikelyMerged = !mergedBranches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || (logExit == 0 && !logCheck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      if wasLikelyMerged || execution.worktreePath == nil {
        // Branch was already merged — just update state
        await mcpLog.info("Branch already merged (or removed), marking execution as merged", metadata: [
          "branch": branchName,
          "executionId": execution.id.uuidString
        ])
        execution.status = .merged
        PeonPingService.shared.worktreeCompleted(taskTitle: execution.task.title)
        recordSnapshot(for: run)
        return
      }
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

      // Rebase the branch onto the current target to minimize merge conflicts.
      // This is important when prior branches in the same batch have already merged,
      // advancing the target branch beyond the common base.
      let (rebaseOutput, rebaseExit) = await runGit(
        ["rebase", targetBranch, branchName],
        in: run.projectPath
      )
      if rebaseExit != 0 {
        // Abort the failed rebase so the repo stays clean
        _ = await runGit(["rebase", "--abort"], in: run.projectPath)
        await mcpLog.warning("Pre-merge rebase failed, falling back to direct merge", metadata: [
          "branch": branchName,
          "target": targetBranch,
          "output": rebaseOutput.prefix(500).description
        ])
        // Ensure we're back on the target branch after aborting rebase
        _ = await runGit(["checkout", targetBranch], in: run.projectPath)
      } else {
        // Rebase succeeded — switch back to target for the merge
        _ = await runGit(["checkout", targetBranch], in: run.projectPath)
      }

      // Merge the worktree branch (fast-forward if rebase succeeded)
      let (mergeOutput, mergeExit) = await runGit(
        ["merge", branchName, "--no-edit"],
        in: run.projectPath
      )

      if mergeExit != 0 {
        if mergeOutput.contains("CONFLICT") || mergeOutput.contains("conflict") {
          // Leave the working tree in the conflicted state for user resolution
          // Enumerate the conflicted files so the UI can show them
          let (conflictList, _) = await runGit(
            ["diff", "--name-only", "--diff-filter=U"],
            in: run.projectPath
          )
          let conflictPaths = conflictList
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
          execution.conflictFiles = conflictPaths.isEmpty
            ? [MergeConflictFile(filePath: branchName, content: "")]
            : conflictPaths.map { MergeConflictFile(filePath: $0, content: "") }
          execution.status = .conflicted(conflictPaths)
          throw ParallelRunError.mergeConflict(branchName)
        }
        throw ParallelRunError.mergeFailed(mergeOutput.trimmingCharacters(in: .whitespacesAndNewlines))
      }

      // Push the merge to origin so work is not lost if the app closes
      let (pushOutput, pushExit) = await runGit(
        ["push", "origin", targetBranch],
        in: run.projectPath
      )
      if pushExit != 0 {
        await mcpLog.warning("Post-merge push failed (merge is local-only)", metadata: [
          "branch": targetBranch,
          "output": pushOutput.prefix(500).description
        ])
      }

      execution.status = .merged
      PeonPingService.shared.worktreeCompleted(taskTitle: execution.task.title)
      recordSnapshot(for: run)

      // Cleanup the worktree
      try? await workspaceService.removeWorktreeForChain(chainId: execution.id)

      // Kick a new scheduling pass if any executions were waiting on this branch (#297)
      if run.executions.contains(where: { $0.status == .waitingForDependencies }) {
        if run.status != .running {
          run.status = .running
          Task { [weak self] in
            guard let self else { return }
            await self.runSchedulingLoop(for: run)
            self.updateRunStatus(run)
          }
        }
      }

    } catch let error as ParallelRunError {
      if case .mergeConflict = error {
        // Status + conflictFiles already set inside the do block above; just re-throw
      } else {
        execution.status = .failed("Merge failed: \(error.localizedDescription)")
      }
      throw error
    } catch {
      execution.status = .failed("Merge failed: \(error.localizedDescription)")
      throw error
    }
  }

  /// Resolve conflicts for an execution and complete the merge.
  /// `resolutions` maps each conflicted filePath to the chosen resolution strategy.
  func resolveAndMerge(
    _ execution: ParallelWorktreeExecution,
    in run: ParallelWorktreeRun,
    resolutions: [String: ConflictResolution]
  ) async throws {
    guard case .conflicted = execution.status else {
      throw ParallelRunError.invalidState("Execution is not in conflicted state")
    }
    guard let branchName = execution.branchName else {
      throw ParallelRunError.missingWorktree
    }

    let targetBranch = try await resolveTargetBranch(for: run)

    // Checkout target branch (the merge is already in progress in the working tree)
    let (checkoutOut, checkoutExit) = await runGit(["checkout", targetBranch], in: run.projectPath)
    guard checkoutExit == 0 else {
      throw ParallelRunError.checkoutFailed("\(targetBranch): \(checkoutOut)")
    }

    // Attempt the merge; exit == 0 means it resolved cleanly (e.g. user fixed externally)
    let (mergeOut, mergeExit) = await runGit(["merge", branchName, "--no-edit"], in: run.projectPath)
    if mergeExit == 0 {
      execution.conflictFiles = []
      execution.status = .merged
      PeonPingService.shared.worktreeCompleted(taskTitle: execution.task.title)
      try? await workspaceService.removeWorktreeForChain(chainId: execution.id)
      updateRunStatus(run)
      return
    }

    guard mergeOut.contains("CONFLICT") || mergeOut.contains("conflict") else {
      throw ParallelRunError.mergeFailed(mergeOut.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Apply per-file resolutions
    for (filePath, resolution) in resolutions {
      switch resolution {
      case .ours:
        _ = await runGit(["checkout", "--ours", "--", filePath], in: run.projectPath)
        _ = await runGit(["add", "--", filePath], in: run.projectPath)
      case .theirs:
        _ = await runGit(["checkout", "--theirs", "--", filePath], in: run.projectPath)
        _ = await runGit(["add", "--", filePath], in: run.projectPath)
      case .editor:
        // User already edited the file; just stage it
        _ = await runGit(["add", "--", filePath], in: run.projectPath)
      }
    }

    // Commit the resolved merge
    let (commitOut, commitExit) = await runGit(
      ["commit", "--no-edit", "-m", "Merge \(branchName) (conflict resolved)"],
      in: run.projectPath
    )
    guard commitExit == 0 else {
      throw ParallelRunError.mergeFailed("Commit failed: \(commitOut)")
    }

    execution.conflictFiles = []
    execution.status = .merged
    PeonPingService.shared.worktreeCompleted(taskTitle: execution.task.title)
    try? await workspaceService.removeWorktreeForChain(chainId: execution.id)
    updateRunStatus(run)
  }

  /// Abort an in-progress merge (called when user cancels conflict resolution).
  func abortMerge(in run: ParallelWorktreeRun) async {
    _ = await runGit(["merge", "--abort"], in: run.projectPath)
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

  /// Re-hydrate a historical snapshot into an active run so full review UX is available.
  /// Returns the existing run immediately if it is already active.
  @discardableResult
  func restoreFromSnapshot(_ snapshot: ParallelRunSnapshot) -> ParallelWorktreeRun {
    if let existing = runs.first(where: { $0.id.uuidString.uppercased() == snapshot.runId.uppercased() }) {
      return existing
    }

    let run = ParallelWorktreeRun(
      id: UUID(uuidString: snapshot.runId) ?? UUID(),
      name: snapshot.name,
      projectPath: snapshot.projectPath,
      baseBranch: snapshot.baseBranch,
      requireReviewGate: snapshot.requireReviewGate
    )
    run.targetBranch = snapshot.targetBranch
    run.templateName = snapshot.templateName
    run.autoMergeOnApproval = snapshot.autoMergeOnApproval
    run.createdAt = snapshot.createdAt

    if let data = snapshot.executionsJSON.data(using: .utf8),
       let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      for dict in array {
        guard let idStr = dict["id"] as? String,
              let taskId = UUID(uuidString: idStr),
              let title = dict["taskTitle"] as? String else { continue }
        let task = WorktreeTask(
          id: taskId,
          title: title,
          description: dict["taskDescription"] as? String ?? "",
          prompt: title
        )
        let execution = ParallelWorktreeExecution(task: task)
        execution.filesChanged = dict["filesChanged"] as? Int ?? 0
        execution.insertions   = dict["insertions"] as? Int ?? 0
        execution.deletions    = dict["deletions"] as? Int ?? 0
        execution.branchName   = dict["branchName"] as? String
        execution.status = restoredExecutionStatus(
          from: dict["status"] as? String ?? "",
          hasBranch: execution.branchName != nil
        )
        run.executions.append(execution)
      }
    }

    let hasActionable = run.executions.contains { $0.status == .awaitingReview || $0.status == .reviewed }
    let allDone = !run.executions.isEmpty && run.executions.allSatisfy { $0.status.isTerminal || $0.status == .merged }
    run.status = allDone ? .completed : (hasActionable ? .awaitingReview : .awaitingReview)

    runs.append(run)
    recordSnapshot(for: run)
    return run
  }

  private func restoredExecutionStatus(from displayName: String, hasBranch: Bool) -> ParallelWorktreeStatus {
    switch displayName {
    case "Awaiting Review": return .awaitingReview
    case "Reviewed":        return .reviewed
    case "Approved":        return .approved
    case "Merged":          return .merged
    case "Rejected":        return .rejected("(historical)")
    case "Failed":          return .failed("(historical)")
    case "Running":         return hasBranch ? .awaitingReview : .cancelled
    default:                return .cancelled
    }
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
