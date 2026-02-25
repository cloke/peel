// SwarmWorktreeManager.swift
// Peel
//
// Created on 2026-01-28.
// Manages isolated git worktrees for swarm task execution.

import Foundation
import SwiftData
import os.log

/// Manages git worktrees for isolated swarm task execution
@MainActor
public final class SwarmWorktreeManager {

  private let logger = Logger(subsystem: "com.peel.distributed", category: "WorktreeManager")

  /// Base directory for worktrees (default: ~/peel-worktrees)
  private let worktreeBaseDir: String

  /// SwiftData context for persisting worktree records across restarts.
  /// Optional so tests can run without a full model container.
  public var modelContext: ModelContext?

  /// Track active worktrees (taskId -> worktreePath)
  private var activeWorktrees: [UUID: WorktreeInfo] = [:]
  
  /// Info about an active worktree
  public struct WorktreeInfo: Sendable {
    public let taskId: UUID
    public let worktreePath: String
    public let branchName: String
    public let repoPath: String
    public let createdAt: Date
    public var diskSizeBytes: Int64?

    public init(
      taskId: UUID,
      worktreePath: String,
      branchName: String,
      repoPath: String,
      createdAt: Date,
      diskSizeBytes: Int64? = nil
    ) {
      self.taskId = taskId
      self.worktreePath = worktreePath
      self.branchName = branchName
      self.repoPath = repoPath
      self.createdAt = createdAt
      self.diskSizeBytes = diskSizeBytes
    }
  }
  
  public init(baseDir: String? = nil, modelContext: ModelContext? = nil) {
    if let baseDir = baseDir {
      self.worktreeBaseDir = baseDir
    } else {
      // Default to ~/peel-worktrees
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      self.worktreeBaseDir = "\(home)/peel-worktrees"
    }
    self.modelContext = modelContext

    // Ensure base directory exists
    try? FileManager.default.createDirectory(
      atPath: worktreeBaseDir,
      withIntermediateDirectories: true
    )

    logger.info("SwarmWorktreeManager initialized with base: \(self.worktreeBaseDir)")

    // Recover in-memory state from SwiftData on startup
    if modelContext != nil {
      recoverFromPersistence()
      // Schedule orphan prune asynchronously so init returns immediately
      Task { await self.recoverAndPrune() }
    }
  }
  
  /// Create an isolated worktree for a swarm task
  /// - Parameters:
  ///   - taskId: The task ID (used for worktree directory name)
  ///   - repoPath: Path to the main git repository
  ///   - branchName: Branch name to create (should be unique per task)
  ///   - baseBranch: Base branch to create from (default: origin/main)
  /// - Returns: Path to the created worktree
  public func createWorktree(
    taskId: UUID,
    repoPath: String,
    branchName: String,
    baseBranch: String = "origin/main"
  ) async throws -> String {
    let shortId = taskId.uuidString.prefix(8)
    let worktreePath = "\(worktreeBaseDir)/task-\(shortId)"
    
    logger.info("Creating worktree for task \(shortId): \(worktreePath)")

    // Remove existing worktree at this path if it exists
    if FileManager.default.fileExists(atPath: worktreePath) {
      logger.warning("Worktree path exists, removing: \(worktreePath)")
      try await removeWorktreeAtPath(worktreePath, repoPath: repoPath)
    }

    // Only block on fetch if the base branch ref is missing locally.
    // If origin/main already exists we skip the network round-trip entirely.
    let baseRefExists = await refExists(baseBranch, in: repoPath)
    if !baseRefExists {
      logger.info("Base ref \(baseBranch) not found locally — fetching origin (timeout 15s)")
      let fetchResult = try await runGitCommandWithTimeout(
        args: ["fetch", "origin"],
        in: repoPath,
        timeout: 15
      )
      if fetchResult.exitCode != 0 {
        logger.warning("Git fetch failed (will try worktree anyway): \(fetchResult.stderr)")
      }
    } else {
      // Fire-and-forget background fetch to keep refs fresh without blocking task start
      Task { [weak self, repoPath] in
        guard let self else { return }
        _ = try? await self.runGitCommand(args: ["fetch", "origin"], in: repoPath)
      }
    }

    // Check if branch already exists (locally or remotely)
    let branchCheck = try await runGitCommand(
      args: ["rev-parse", "--verify", branchName],
      in: repoPath
    )
    
    if branchCheck.exitCode == 0 {
      // Branch exists, create worktree without -b
      logger.info("Branch \(branchName) exists, checking out in worktree")
      let result = try await runGitCommand(
        args: ["worktree", "add", worktreePath, branchName],
        in: repoPath
      )
      
      if result.exitCode != 0 {
        throw WorktreeError.worktreeCreationFailed(result.stderr)
      }
    } else {
      // Branch doesn't exist, create new branch
      let result = try await runGitCommand(
        args: ["worktree", "add", "-b", branchName, worktreePath, baseBranch],
        in: repoPath
      )
      
      if result.exitCode != 0 {
        throw WorktreeError.worktreeCreationFailed(result.stderr)
      }
    }
    
    // Track the worktree in memory and persist to SwiftData
    let info = WorktreeInfo(
      taskId: taskId,
      worktreePath: worktreePath,
      branchName: branchName,
      repoPath: repoPath,
      createdAt: Date()
    )
    activeWorktrees[taskId] = info
    persistWorktreeRecord(info)

    logger.info("Worktree created - taskId: \(taskId.uuidString), path: \(worktreePath), branch: \(branchName)")
    logger.info("activeWorktrees after create: \(self.activeWorktrees.count) entries, keys: \(self.activeWorktrees.keys.map { $0.uuidString })")
    return worktreePath
  }
  
  /// Commit and push any changes in the worktree
  /// - Parameters:
  ///   - taskId: The task ID
  ///   - commitMessage: Message for the commit
  /// - Returns: True if changes were committed and pushed, false if no changes
  public func commitAndPushChanges(
    taskId: UUID,
    commitMessage: String
  ) async throws -> Bool {
    logger.info("commitAndPushChanges called for task \(taskId)")
    logger.info("Active worktrees count: \(self.activeWorktrees.count)")
    logger.info("Active worktree keys: \(self.activeWorktrees.keys.map { $0.uuidString })")
    
    // Try in-memory first; fall back to SwiftData for post-restart recovery
    var info = activeWorktrees[taskId]
    if info == nil, let context = modelContext {
      logger.info("Task \(taskId) not in memory — querying SwiftData for restart recovery")
      let idString = taskId.uuidString
      let descriptor = FetchDescriptor<TrackedWorktree>(
        predicate: #Predicate { $0.taskId == idString }
      )
      if let record = try? context.fetch(descriptor).first {
        let recovered = WorktreeInfo(
          taskId: taskId,
          worktreePath: record.localPath,
          branchName: record.branch,
          repoPath: record.mainRepoPath,
          createdAt: record.createdAt
        )
        activeWorktrees[taskId] = recovered
        info = recovered
        logger.info("Recovered worktree from SwiftData for task \(taskId): \(record.localPath)")
      }
    }
    guard let info else {
      logger.warning("No worktree found for task \(taskId) — neither in memory nor in SwiftData")
      return false
    }
    
    let worktreePath = info.worktreePath
    let branchName = info.branchName
    
    // Check if there are any uncommitted changes to stage and commit
    let statusResult = try await runGitCommand(
      args: ["status", "--porcelain"],
      in: worktreePath
    )
    
    let hasDirtyChanges = !statusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    
    if hasDirtyChanges {
      logger.info("Committing uncommitted changes in worktree for task \(taskId)")
      
      // Stage all changes
      let addResult = try await runGitCommand(
        args: ["add", "."],
        in: worktreePath
      )
      if addResult.exitCode != 0 {
        logger.error("git add failed: \(addResult.stderr)")
        throw WorktreeError.gitCommandFailed("git add failed: \(addResult.stderr)")
      }
      
      // Commit
      let commitResult = try await runGitCommand(
        args: ["commit", "-m", commitMessage],
        in: worktreePath
      )
      if commitResult.exitCode != 0 {
        logger.error("git commit failed: \(commitResult.stderr)")
        throw WorktreeError.gitCommandFailed("git commit failed: \(commitResult.stderr)")
      }
    } else {
      logger.info("No uncommitted changes for task \(taskId), checking for unpushed commits")
    }
    
    // Always check if the branch has commits ahead of origin — the agent may have
    // committed inside the chain execution, leaving a clean working dir but unpushed commits.
    let logResult = try await runGitCommand(
      args: ["log", "origin/main..\(branchName)", "--oneline"],
      in: worktreePath
    )
    let hasUnpushedCommits = !logResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    
    guard hasDirtyChanges || hasUnpushedCommits else {
      logger.info("No changes to commit or push in worktree for task \(taskId)")
      return false
    }
    
    // Push to origin
    let pushResult = try await runGitCommand(
      args: ["push", "-u", "origin", branchName],
      in: worktreePath
    )
    if pushResult.exitCode != 0 {
      logger.error("git push failed: \(pushResult.stderr)")
      throw WorktreeError.gitCommandFailed("git push failed: \(pushResult.stderr)")
    }
    
    logger.info("Successfully committed and pushed changes for task \(taskId) on branch \(branchName)")
    updateWorktreeStatus(taskId: taskId, status: TrackedWorktree.Status.committed)
    return true
  }
  
  /// Remove a worktree for a completed/failed task
  /// - Parameters:
  ///   - taskId: The task ID
  ///   - force: Force removal even if there are uncommitted changes
  ///   - failed: If true, marks the SwiftData record as failed instead of cleaned
  public func removeWorktree(taskId: UUID, force: Bool = false, failed: Bool = false) async throws {
    guard let info = activeWorktrees[taskId] else {
      logger.warning("No worktree found for task \(taskId)")
      return
    }

    try await removeWorktreeAtPath(info.worktreePath, repoPath: info.repoPath, force: force)
    activeWorktrees.removeValue(forKey: taskId)
    let finalStatus = failed ? TrackedWorktree.Status.failed : TrackedWorktree.Status.cleaned
    updateWorktreeStatus(taskId: taskId, status: finalStatus)
  }
  
  /// Remove a worktree at a specific path
  private func removeWorktreeAtPath(_ path: String, repoPath: String, force: Bool = false) async throws {
    logger.info("Removing worktree: \(path)")
    
    var args = ["worktree", "remove"]
    if force {
      args.append("--force")
    }
    args.append(path)
    
    let result = try await runGitCommand(args: args, in: repoPath)
    
    if result.exitCode != 0 {
      // If worktree remove fails, try to clean up manually
      if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
      }
      // Also prune stale worktrees
      _ = try? await runGitCommand(args: ["worktree", "prune"], in: repoPath)
    }
  }
  
  /// Get info about an active worktree
  public func getWorktreeInfo(taskId: UUID) -> WorktreeInfo? {
    activeWorktrees[taskId]
  }
  
  /// Get all active worktrees
  public func getActiveWorktrees() -> [WorktreeInfo] {
    Array(activeWorktrees.values)
  }

  /// Get the base directory path for worktrees
  public func getWorktreeBaseDir() -> String {
    worktreeBaseDir
  }

  /// Calculate disk size for a directory
  /// - Parameter path: Path to the directory
  /// - Returns: Total size in bytes, or nil if calculation fails
  public static func calculateDiskSize(for path: String) -> Int64? {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
      at: URL(fileURLWithPath: path),
      includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }

    var totalSize: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]),
            let isDirectory = resourceValues.isDirectory,
            !isDirectory,
            let fileSize = resourceValues.totalFileAllocatedSize else {
        continue
      }
      totalSize += Int64(fileSize)
    }
    return totalSize
  }
  
  /// Get debug info about active worktrees
  public func getDebugInfo() -> [String: Any] {
    return [
      "activeCount": activeWorktrees.count,
      "activeTaskIds": activeWorktrees.keys.map { $0.uuidString },
      "baseDir": worktreeBaseDir,
      "worktrees": activeWorktrees.values.map { info in
        [
          "taskId": info.taskId.uuidString,
          "path": info.worktreePath,
          "branch": info.branchName,
          "repoPath": info.repoPath,
          "createdAt": Formatter.iso8601.string(from: info.createdAt)
        ]
      }
    ]
  }
  
  /// Generate a unique branch name for a swarm task
  public static func generateBranchName(
    taskId: UUID,
    prefix: String = "swarm",
    hint: String? = nil
  ) -> String {
    let shortId = String(taskId.uuidString.prefix(8)).lowercased()
    if let hint = hint {
      // Sanitize hint: lowercase, replace spaces with dashes, remove special chars
      let sanitized = hint
        .lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        .prefix(30)
      return "\(prefix)/\(sanitized)-\(shortId)"
    }
    return "\(prefix)/task-\(shortId)"
  }
  
  /// Cleanup old worktrees that may have been left behind
  public func cleanupStaleWorktrees(olderThan: TimeInterval = 86400) async {
    logger.info("Cleaning up stale worktrees older than \(olderThan) seconds")
    
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: worktreeBaseDir) else {
      return
    }
    
    let now = Date()
    for item in contents where item.hasPrefix("task-") {
      let path = "\(worktreeBaseDir)/\(item)"
      guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let modDate = attrs[.modificationDate] as? Date else {
        continue
      }
      
      if now.timeIntervalSince(modDate) > olderThan {
        logger.info("Removing stale worktree: \(path)")
        try? FileManager.default.removeItem(atPath: path)
      }
    }
  }
  
  // MARK: - SwiftData Persistence

  /// Persists a new worktree record to SwiftData. No-op if modelContext is nil.
  private func persistWorktreeRecord(_ info: WorktreeInfo) {
    guard let context = modelContext else { return }
    let record = TrackedWorktree(
      repositoryId: UUID(), // No SyncedRepository link for swarm worktrees
      localPath: info.worktreePath,
      branch: info.branchName,
      source: TrackedWorktree.Source.swarm
    )
    record.taskId = info.taskId.uuidString
    record.taskStatus = TrackedWorktree.Status.active
    record.mainRepoPath = info.repoPath
    context.insert(record)
    try? context.save()
    logger.debug("Persisted worktree record for task \(info.taskId.uuidString)")
  }

  /// Updates the `taskStatus` (and optionally `completedAt`) on an existing SwiftData record.
  private func updateWorktreeStatus(taskId: UUID, status: String, failureReason: String? = nil) {
    guard let context = modelContext else { return }
    let idString = taskId.uuidString
    let descriptor = FetchDescriptor<TrackedWorktree>(
      predicate: #Predicate { $0.taskId == idString }
    )
    guard let record = try? context.fetch(descriptor).first else { return }
    record.taskStatus = status
    record.completedAt = Date()
    if let reason = failureReason {
      record.failureReason = reason
    }
    try? context.save()
  }

  /// Reloads in-memory `activeWorktrees` from SwiftData records with `taskStatus == "active"`.
  /// Called automatically from `init` when a modelContext is provided.
  private func recoverFromPersistence() {
    guard let context = modelContext else { return }
    let activeStatus = TrackedWorktree.Status.active
    let swarmSource = TrackedWorktree.Source.swarm
    let descriptor = FetchDescriptor<TrackedWorktree>(
      predicate: #Predicate { $0.taskStatus == activeStatus && $0.source == swarmSource }
    )
    let records = (try? context.fetch(descriptor)) ?? []
    var recovered = 0
    for record in records {
      guard let taskId = UUID(uuidString: record.taskId), !record.localPath.isEmpty else { continue }
      // Only recover if the worktree path still exists on disk
      if FileManager.default.fileExists(atPath: record.localPath) {
        activeWorktrees[taskId] = WorktreeInfo(
          taskId: taskId,
          worktreePath: record.localPath,
          branchName: record.branch,
          repoPath: record.mainRepoPath,
          createdAt: record.createdAt
        )
        recovered += 1
      } else {
        // Disk is gone but DB says active — mark as orphaned
        record.taskStatus = TrackedWorktree.Status.orphaned
        record.completedAt = Date()
      }
    }
    if !records.isEmpty {
      try? context.save()
    }
    if recovered > 0 {
      logger.info("Recovered \(recovered) active swarm worktrees from SwiftData")
    }
  }

  /// Prunes orphaned worktrees: filesystem entries with no DB record and DB records
  /// whose worktree directory is gone. Safe to call at startup.
  public func recoverAndPrune() async {
    guard let context = modelContext else { return }
    logger.info("Starting orphan worktree recovery and prune")

    // 1. Find filesystem worktrees with no DB record
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: worktreeBaseDir) {
      for item in contents where item.hasPrefix("task-") {
        let path = "\(worktreeBaseDir)/\(item)"
        // Check if any DB record matches this path
        let descriptor = FetchDescriptor<TrackedWorktree>(
          predicate: #Predicate { $0.localPath == path }
        )
        if let records = try? context.fetch(descriptor), records.isEmpty {
          logger.warning("Orphaned fs worktree (no DB record): \(path) — removing")
          try? FileManager.default.removeItem(atPath: path)
        }
      }
    }

    // 2. Find DB records whose path no longer exists on disk
    let swarmSource = TrackedWorktree.Source.swarm
    let notCleaned = TrackedWorktree.Status.cleaned
    let descriptor = FetchDescriptor<TrackedWorktree>(
      predicate: #Predicate { $0.source == swarmSource && $0.taskStatus != notCleaned }
    )
    let records = (try? context.fetch(descriptor)) ?? []
    var changed = false
    for record in records {
      guard !record.localPath.isEmpty,
            !FileManager.default.fileExists(atPath: record.localPath) else { continue }
      if record.taskStatus == TrackedWorktree.Status.active {
        logger.warning("Marking task \(record.taskId) orphaned: path missing \(record.localPath)")
        record.taskStatus = TrackedWorktree.Status.orphaned
        record.completedAt = record.completedAt ?? Date()
        changed = true
        // Attempt git worktree prune for the parent repo
        if !record.mainRepoPath.isEmpty {
          _ = try? await runGitCommand(args: ["worktree", "prune"], in: record.mainRepoPath)
        }
      }
    }
    if changed { try? context.save() }
    logger.info("Orphan recovery complete")
  }

  // MARK: - Git Utilities

  /// Returns true if the given git ref exists locally in the repo.
  private func refExists(_ ref: String, in repoPath: String) async -> Bool {
    guard let result = try? await runGitCommand(
      args: ["rev-parse", "--verify", ref],
      in: repoPath
    ) else { return false }
    return result.exitCode == 0
  }

  /// Runs a git command with a wall-clock timeout (seconds). Returns the result or a
  /// synthetic failure result if the process exceeds the timeout.
  private func runGitCommandWithTimeout(
    args: [String],
    in directory: String,
    timeout: TimeInterval
  ) async throws -> GitResult {
    try await withThrowingTaskGroup(of: GitResult.self) { group in
      group.addTask { try await self.runGitCommand(args: args, in: directory) }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return GitResult(exitCode: -1, stdout: "", stderr: "git command timed out after \(timeout)s")
      }
      let result = try await group.next()!
      group.cancelAll()
      return result
    }
  }

  // MARK: - Git Command Execution

  private struct GitResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }
  
  private func runGitCommand(args: [String], in directory: String) async throws -> GitResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    
    return try await withCheckedThrowingContinuation { continuation in
      do {
        try process.run()
        
        process.terminationHandler = { proc in
          let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
          let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
          
          let result = GitResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
          )
          continuation.resume(returning: result)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
