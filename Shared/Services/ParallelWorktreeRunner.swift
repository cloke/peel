//
//  ParallelWorktreeRunner.swift
//  Peel
//
//  Created on 1/21/26.
//

import Foundation
import Observation

#if os(macOS)
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
  case approved
  case rejected(String)
  case merging
  case merged
  case failed(String)
  case cancelled
  
  var isTerminal: Bool {
    switch self {
    case .merged, .failed, .cancelled, .rejected: return true
    default: return false
    }
  }
  
  var displayName: String {
    switch self {
    case .pending: return "Pending"
    case .creatingWorktree: return "Creating Worktree"
    case .running: return "Running"
    case .awaitingReview: return "Awaiting Review"
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
  var status: ParallelWorktreeStatus = .pending
  var startedAt: Date?
  var completedAt: Date?
  var output: String = ""
  var diffSummary: String?
  var filesChanged: Int = 0
  var insertions: Int = 0
  var deletions: Int = 0
  var mergeConflicts: [String] = []
  var ragSnippets: [RAGSnippet] = []
  
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
  var executions: [ParallelWorktreeExecution] = []
  var createdAt: Date
  var startedAt: Date?
  var completedAt: Date?
  var status: RunStatus = .pending
  var requireReviewGate: Bool = true
  var autoMergeOnApproval: Bool = false
  
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
      case .merged, .approved, .awaitingReview:
        return true
      default:
        return false
      }
    }.count
    return Double(completed) / Double(executions.count)
  }
  
  var pendingReviewCount: Int {
    executions.filter { $0.status == .awaitingReview }.count
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
  /// All parallel runs managed by this runner
  private(set) var runs: [ParallelWorktreeRun] = []
  
  /// Currently active run (if any)
  var activeRun: ParallelWorktreeRun? {
    runs.first { $0.status == .running || $0.status == .awaitingReview }
  }
  
  /// The workspace service for worktree management
  private let workspaceService: AgentWorkspaceService
  
  /// Local RAG store for grounding
  private var ragStore: LocalRAGStore?
  
  /// Max concurrent worktrees
  var maxConcurrentWorktrees: Int = 4
  
  /// Active tasks for each execution
  private var executionTasks: [UUID: Task<Void, Never>] = [:]
  
  init(workspaceService: AgentWorkspaceService) {
    self.workspaceService = workspaceService
  }
  
  /// Set the RAG store for grounding
  func setRAGStore(_ store: LocalRAGStore) {
    self.ragStore = store
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
    autoMergeOnApproval: Bool = false
  ) -> ParallelWorktreeRun {
    let run = ParallelWorktreeRun(
      name: name,
      projectPath: projectPath,
      baseBranch: baseBranch,
      requireReviewGate: requireReviewGate
    )
    run.targetBranch = targetBranch
    run.autoMergeOnApproval = autoMergeOnApproval
    
    // Create executions for each task
    for task in tasks {
      let execution = ParallelWorktreeExecution(task: task)
      run.executions.append(execution)
    }
    
    runs.append(run)
    return run
  }
  
  /// Start a parallel run
  func startRun(_ run: ParallelWorktreeRun) async throws {
    guard run.status == .pending else {
      throw ParallelRunError.invalidState("Run is not in pending state")
    }
    
    run.status = .running
    run.startedAt = Date()
    
    // Ground each task with RAG snippets
    await groundTasksWithRAG(run)
    
    // Execute tasks in parallel with concurrency limit
    await withTaskGroup(of: Void.self) { group in
      var activeCount = 0
      var pendingExecutions = run.executions.filter { $0.status == .pending }
      
      while !pendingExecutions.isEmpty || activeCount > 0 {
        // Start new tasks up to the limit
        while activeCount < maxConcurrentWorktrees, let execution = pendingExecutions.first {
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
  }
  
  /// Execute a single worktree task
  private func executeWorktree(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun) async {
    execution.status = .creatingWorktree
    execution.startedAt = Date()
    
    do {
      // Create worktree
      let timestamp = Int(Date().timeIntervalSince1970)
      let sanitizedName = sanitizeBranchComponent(execution.task.title)
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
      
      // Build the grounded prompt
      let groundedPrompt = buildGroundedPrompt(for: execution)
      
      // Execute the task (this would integrate with your existing chain runner)
      // For now, we simulate the execution
      let result = await executeTask(
        prompt: groundedPrompt,
        worktreePath: worktreePath,
        task: execution.task
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
      } else {
        execution.status = .approved
      }
      
      execution.completedAt = Date()
      
    } catch {
      execution.status = .failed(error.localizedDescription)
      execution.completedAt = Date()
    }
  }

  private func sanitizeBranchComponent(_ title: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let slug = title
      .lowercased()
      .map { allowed.contains($0.unicodeScalars.first!) ? $0 : "-" }
      .reduce(into: "") { result, character in
        if character == "-" {
          if !result.hasSuffix("-") {
            result.append(character)
          }
        } else {
          result.append(character)
        }
      }
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    return slug.isEmpty ? "task" : slug
  }
  
  /// Build a prompt grounded with RAG snippets
  private func buildGroundedPrompt(for execution: ParallelWorktreeExecution) -> String {
    var prompt = execution.task.prompt
    
    if !execution.ragSnippets.isEmpty {
      var contextSection = "\n\n## Relevant Code Context\n\n"
      contextSection += "The following code snippets are relevant to this task:\n\n"
      
      for snippet in execution.ragSnippets.prefix(5) {
        contextSection += "### \(snippet.filePath) (lines \(snippet.startLine)-\(snippet.endLine))\n"
        contextSection += "```\n\(snippet.snippet)\n```\n\n"
      }
      
      prompt = contextSection + "\n## Task\n\n" + prompt
    }
    
    return prompt
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
  
  /// Execute a task in a worktree (stub for integration)
  private func executeTask(
    prompt: String,
    worktreePath: String,
    task: WorktreeTask
  ) async -> TaskExecutionResult {
    // This would integrate with your existing chain runner
    // For now, return a placeholder result
    
    // Simulate some work
    try? await Task.sleep(for: .milliseconds(100))
    
    return TaskExecutionResult(
      output: "Task executed successfully",
      diffSummary: nil,
      filesChanged: 0,
      insertions: 0,
      deletions: 0,
      mergeConflicts: nil
    )
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
    } else if anyAwaitingReview {
      run.status = .awaitingReview
    } else if allTerminal {
      run.completedAt = Date()
      run.status = .completed
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
  func rejectExecution(_ execution: ParallelWorktreeExecution, reason: String) {
    guard execution.status == .awaitingReview else { return }
    execution.status = .rejected(reason)
  }
  
  /// Approve all pending executions
  func approveAllPending(in run: ParallelWorktreeRun) {
    for execution in run.executions where execution.status == .awaitingReview {
      approveExecution(execution, in: run)
    }
  }
  
  // MARK: - Merge Operations
  
  /// Merge a single execution
  func mergeExecution(_ execution: ParallelWorktreeExecution, in run: ParallelWorktreeRun) async throws {
    guard execution.status == .approved else {
      throw ParallelRunError.invalidState("Execution must be approved before merging")
    }
    
    guard let worktreePath = execution.worktreePath,
          let branchName = execution.branchName else {
      throw ParallelRunError.missingWorktree
    }
    
    execution.status = .merging
    
    do {
      // Merge the branch into target (or base)
      let targetBranch = run.targetBranch ?? run.baseBranch
      
      // Use git commands directly for checkout and merge
      let checkoutProcess = Process()
      checkoutProcess.currentDirectoryURL = URL(fileURLWithPath: run.projectPath)
      checkoutProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      checkoutProcess.arguments = ["checkout", targetBranch]
      try checkoutProcess.run()
      checkoutProcess.waitUntilExit()
      
      guard checkoutProcess.terminationStatus == 0 else {
        throw ParallelRunError.checkoutFailed(targetBranch)
      }
      
      // Merge the worktree branch
      let mergeProcess = Process()
      mergeProcess.currentDirectoryURL = URL(fileURLWithPath: run.projectPath)
      mergeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      mergeProcess.arguments = ["merge", branchName, "--no-edit"]
      
      let pipe = Pipe()
      mergeProcess.standardOutput = pipe
      mergeProcess.standardError = pipe
      
      try mergeProcess.run()
      mergeProcess.waitUntilExit()
      
      if mergeProcess.terminationStatus != 0 {
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        if output.contains("CONFLICT") || output.contains("conflict") {
          throw ParallelRunError.mergeConflict(branchName)
        }
        throw ParallelRunError.mergeFailed(output)
      }
      
      execution.status = .merged
      
      // Cleanup the worktree
      try? await workspaceService.removeWorktreeForChain(chainId: execution.id)
      
    } catch let error as ParallelRunError {
      // Check if it's a merge conflict
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
  
  /// Merge all approved executions
  func mergeAllApproved(in run: ParallelWorktreeRun) async throws {
    run.status = .merging
    
    for execution in run.executions where execution.isReadyToMerge {
      try await mergeExecution(execution, in: run)
    }
    
    updateRunStatus(run)
  }
  
  // MARK: - Run Control
  
  /// Cancel a run
  func cancelRun(_ run: ParallelWorktreeRun) async {
    run.status = .cancelled
    
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

#endif
