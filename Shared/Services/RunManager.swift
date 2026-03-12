//
//  RunManager.swift
//  Peel
//
//  Single source of truth for ALL runs — PR reviews, code changes,
//  investigations, long-lived ideas. Wraps ParallelWorktreeRunner
//  (the execution engine) and absorbs PRReviewQueue lifecycle tracking.
//

import Foundation
import Observation

@MainActor
@Observable
final class RunManager {

  // MARK: - Dependencies

  /// The execution engine — creates worktrees, runs chains, manages merge.
  let worktreeRunner: ParallelWorktreeRunner

  /// Legacy PR review queue — kept during migration, will be removed.
  let prReviewQueue: PRReviewQueue

  // MARK: - Init

  init(worktreeRunner: ParallelWorktreeRunner, prReviewQueue: PRReviewQueue) {
    self.worktreeRunner = worktreeRunner
    self.prReviewQueue = prReviewQueue
  }

  // MARK: - All Runs (unified view)

  /// All active (in-memory) runs from the worktree runner.
  var runs: [ParallelWorktreeRun] {
    worktreeRunner.runs
  }

  /// Historical runs loaded from persistence.
  var historicalRuns: [ParallelRunSnapshot] {
    worktreeRunner.historicalRuns
  }

  // MARK: - Queries

  /// Runs awaiting human review.
  func runsNeedingReview() -> [ParallelWorktreeRun] {
    runs.filter { $0.status == .awaitingReview }
  }

  /// Running runs.
  func runningRuns() -> [ParallelWorktreeRun] {
    runs.filter { $0.status == .running }
  }

  /// Filter by run kind.
  func runsByKind(_ kind: RunKind) -> [ParallelWorktreeRun] {
    runs.filter { $0.kind == kind }
  }

  /// PR review runs (convenience).
  var prReviewRuns: [ParallelWorktreeRun] {
    runsByKind(.prReview)
  }

  /// Find a run by ID.
  func findRun(id: UUID) -> ParallelWorktreeRun? {
    runs.first { $0.id == id }
  }

  /// Find a run by the original chain run ID (backward compat with `chains.run.status`).
  func findRunBySourceChainRunId(_ chainRunId: UUID) -> ParallelWorktreeRun? {
    worktreeRunner.findRunBySourceChainRunId(chainRunId)
  }

  // MARK: - Hierarchy Queries

  /// Child runs spawned by a parent (manager) run.
  func childRuns(of parentId: UUID) -> [ParallelWorktreeRun] {
    runs.filter { $0.parentRunId == parentId }
  }

  /// The parent run, if this run was spawned as a child.
  func parentRun(of run: ParallelWorktreeRun) -> ParallelWorktreeRun? {
    guard let pid = run.parentRunId else { return nil }
    return findRun(id: pid)
  }

  /// Top-level runs (no parent). These are the roots of the hierarchy.
  func topLevelRuns() -> [ParallelWorktreeRun] {
    runs.filter { $0.parentRunId == nil }
  }

  /// Whether a run is a manager run with active children.
  func isActiveManager(_ run: ParallelWorktreeRun) -> Bool {
    run.kind == .managerRun && !childRuns(of: run.id).isEmpty
  }

  /// Summary stats for a manager run's children.
  func childRunStats(of parentId: UUID) -> (total: Int, running: Int, completed: Int, failed: Int, needsReview: Int) {
    let children = childRuns(of: parentId)
    return (
      total: children.count,
      running: children.filter { $0.status == .running }.count,
      completed: children.filter { $0.status == .completed }.count,
      failed: children.filter { if case .failed = $0.status { return true }; return false }.count,
      needsReview: children.filter { $0.status == .awaitingReview }.count
    )
  }

  // MARK: - Create Runs

  /// Create and start a code change run (the common path for `chains.run`).
  @discardableResult
  func createCodeChangeRun(
    prompt: String,
    projectPath: String,
    templateName: String? = nil,
    baseBranch: String = "HEAD",
    requireReviewGate: Bool = true,
    runOptions: AgentChainRunner.ChainRunOptions? = nil,
    sourceChainRunId: UUID? = nil,
    operatorGuidance: [String] = []
  ) -> ParallelWorktreeRun {
    worktreeRunner.createAndStartSingleTaskRun(
      prompt: prompt,
      projectPath: projectPath,
      templateName: templateName,
      baseBranch: baseBranch,
      requireReviewGate: requireReviewGate,
      runOptions: runOptions,
      sourceChainRunId: sourceChainRunId,
      operatorGuidance: operatorGuidance,
      kind: .codeChange
    )
  }

  /// Create and start a PR review run.
  @discardableResult
  func createPRReviewRun(
    repoOwner: String,
    repoName: String,
    prNumber: Int,
    prTitle: String,
    headRef: String,
    htmlURL: String = "",
    prompt: String,
    projectPath: String,
    templateName: String? = nil,
    baseBranch: String = "HEAD",
    runOptions: AgentChainRunner.ChainRunOptions? = nil,
    sourceChainRunId: UUID? = nil,
    operatorGuidance: [String] = []
  ) -> ParallelWorktreeRun {
    let ctx = PRRunContext(
      repoOwner: repoOwner,
      repoName: repoName,
      prNumber: prNumber,
      prTitle: prTitle,
      headRef: headRef,
      htmlURL: htmlURL,
      phase: PRReviewPhase.reviewing
    )
    let run = worktreeRunner.createAndStartSingleTaskRun(
      prompt: prompt,
      projectPath: projectPath,
      templateName: templateName,
      baseBranch: baseBranch,
      requireReviewGate: true,
      runOptions: runOptions,
      sourceChainRunId: sourceChainRunId,
      operatorGuidance: operatorGuidance,
      kind: .prReview,
      prContext: ctx
    )
    return run
  }

  /// Create a long-lived idea run (starts paused).
  @discardableResult
  func createIdeaRun(
    name: String,
    prompt: String,
    projectPath: String,
    baseBranch: String = "HEAD",
    parentRunId: UUID? = nil
  ) -> ParallelWorktreeRun {
    let task = WorktreeTask(
      title: name,
      description: prompt,
      prompt: prompt
    )
    let run = worktreeRunner.createRun(
      name: name,
      projectPath: projectPath,
      tasks: [task],
      baseBranch: baseBranch,
      requireReviewGate: true
    )
    run.kind = .investigation
    run.prompt = prompt
    run.ideaContext = IdeaRunContext()
    run.parentRunId = parentRunId
    run.isPaused = true
    return run
  }

  /// Create a manager run that supervises child runs.
  @discardableResult
  func createManagerRun(
    name: String,
    prompt: String,
    projectPath: String,
    baseBranch: String = "HEAD"
  ) -> ParallelWorktreeRun {
    let task = WorktreeTask(
      title: name,
      description: prompt,
      prompt: prompt
    )
    let run = worktreeRunner.createRun(
      name: name,
      projectPath: projectPath,
      tasks: [task],
      baseBranch: baseBranch,
      requireReviewGate: true
    )
    run.kind = .managerRun
    run.prompt = prompt
    return run
  }

  /// Spawn a child run under a parent manager run.
  @discardableResult
  func spawnChildRun(
    parentRunId: UUID,
    prompt: String,
    projectPath: String,
    templateName: String? = nil,
    baseBranch: String = "HEAD",
    runOptions: AgentChainRunner.ChainRunOptions? = nil,
    operatorGuidance: [String] = []
  ) -> ParallelWorktreeRun {
    let run = worktreeRunner.createAndStartSingleTaskRun(
      prompt: prompt,
      projectPath: projectPath,
      templateName: templateName,
      baseBranch: baseBranch,
      requireReviewGate: true,
      runOptions: runOptions,
      operatorGuidance: operatorGuidance,
      kind: .codeChange
    )
    run.parentRunId = parentRunId
    return run
  }

  // MARK: - Run Lifecycle

  /// Start a run (for runs created in pending state).
  func startRun(_ run: ParallelWorktreeRun) async throws {
    try await worktreeRunner.startRun(run)
  }

  /// Wait for a run to reach a terminal or review state.
  func waitForCompletion(_ run: ParallelWorktreeRun, timeoutSeconds: Double? = nil) async -> ParallelWorktreeRun.RunStatus {
    await worktreeRunner.waitForRunCompletion(run, timeoutSeconds: timeoutSeconds)
  }

  /// Stop/cancel a run.
  func stopRun(_ run: ParallelWorktreeRun) async {
    await worktreeRunner.cancelRun(run)
  }

  /// Pause a run (for long-lived ideas).
  func pauseRun(_ run: ParallelWorktreeRun) {
    run.isPaused = true
  }

  /// Resume a paused run.
  func resumeRun(_ run: ParallelWorktreeRun) async throws {
    run.isPaused = false
    if run.status == .pending {
      try await worktreeRunner.startRun(run)
    }
  }

  // MARK: - Execution Review

  func approveExecution(
    _ execution: ParallelWorktreeExecution,
    in run: ParallelWorktreeRun,
    reviewerExecutionId: UUID? = nil,
    reviewerLabel: String? = nil,
    notes: String? = nil
  ) {
    worktreeRunner.approveExecution(
      execution,
      in: run,
      reviewerExecutionId: reviewerExecutionId,
      reviewerLabel: reviewerLabel,
      notes: notes
    )
  }

  func rejectExecution(
    _ execution: ParallelWorktreeExecution,
    in run: ParallelWorktreeRun,
    reason: String,
    reviewerExecutionId: UUID? = nil,
    reviewerLabel: String? = nil,
    notes: String? = nil
  ) {
    worktreeRunner.rejectExecution(
      execution,
      in: run,
      reason: reason,
      reviewerExecutionId: reviewerExecutionId,
      reviewerLabel: reviewerLabel,
      notes: notes
    )
  }

  func markReviewed(
    _ execution: ParallelWorktreeExecution,
    in run: ParallelWorktreeRun,
    reviewerExecutionId: UUID? = nil,
    reviewerLabel: String? = nil,
    notes: String? = nil
  ) {
    worktreeRunner.markReviewed(
      execution,
      in: run,
      reviewerExecutionId: reviewerExecutionId,
      reviewerLabel: reviewerLabel,
      notes: notes
    )
  }

  func mergeExecution(
    _ execution: ParallelWorktreeExecution,
    in run: ParallelWorktreeRun
  ) async throws {
    try await worktreeRunner.mergeExecution(execution, in: run)
  }

  // MARK: - PR Review Lifecycle (on the unified Run)

  /// Update PR review phase on a run.
  func updatePRPhase(_ run: ParallelWorktreeRun, phase: String) {
    run.prContext?.phase = phase
  }

  /// Mark a PR review run as reviewed with output.
  func markPRReviewed(_ run: ParallelWorktreeRun, output: String, verdict: String) {
    run.prContext?.reviewOutput = output
    run.prContext?.reviewVerdict = verdict
    run.prContext?.phase = PRReviewPhase.reviewed
  }

  /// Mark a PR review run's fix chain.
  func markPRFixing(_ run: ParallelWorktreeRun, chainId: UUID, model: String = "") {
    run.prContext?.fixChainId = chainId
    run.prContext?.fixModel = model
    run.prContext?.phase = PRReviewPhase.fixing
  }

  /// Mark a PR review run as pushed.
  func markPRPushed(_ run: ParallelWorktreeRun, result: String) {
    run.prContext?.pushResult = result
    run.prContext?.pushedAt = Date()
    run.prContext?.phase = PRReviewPhase.pushed
  }

  // MARK: - Summary for MCP

  /// Build a summary dict suitable for MCP tool responses.
  func runSummary(_ run: ParallelWorktreeRun) -> [String: Any] {
    var d: [String: Any] = [
      "runId": run.id.uuidString,
      "name": run.name,
      "kind": run.kind.rawValue,
      "status": run.status.displayName,
      "projectPath": run.projectPath,
      "baseBranch": run.baseBranch,
      "executionCount": run.executions.count,
      "progress": run.progress,
      "createdAt": ISO8601DateFormatter().string(from: run.createdAt),
    ]
    if !run.prompt.isEmpty { d["prompt"] = String(run.prompt.prefix(500)) }
    if let t = run.templateName { d["templateName"] = t }
    if let p = run.parentRunId { d["parentRunId"] = p.uuidString }
    if let pr = run.prContext { d["prContext"] = pr.asDictionary }
    if run.isPaused { d["isPaused"] = true }
    if let sid = run.sourceChainRunId { d["sourceChainRunId"] = sid.uuidString }

    // Execution summaries
    d["executions"] = run.executions.map { exec -> [String: Any] in
      var e: [String: Any] = [
        "executionId": exec.id.uuidString,
        "status": exec.status.displayName,
        "task": exec.task.title,
      ]
      if let branch = exec.branchName { e["branchName"] = branch }
      if exec.filesChanged > 0 {
        e["filesChanged"] = exec.filesChanged
        e["insertions"] = exec.insertions
        e["deletions"] = exec.deletions
      }
      if !exec.output.isEmpty { e["output"] = String(exec.output.prefix(500)) }
      return e
    }
    return d
  }
}
