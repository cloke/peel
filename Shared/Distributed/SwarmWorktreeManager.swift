// SwarmWorktreeManager.swift
// Peel
//
// Created on 2026-01-28.
// Manages isolated git worktrees for swarm task execution.

import Foundation
import os.log

/// Manages git worktrees for isolated swarm task execution
@MainActor
public final class SwarmWorktreeManager {
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "WorktreeManager")
  
  /// Base directory for worktrees (default: ~/peel-worktrees)
  private let worktreeBaseDir: String
  
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
  
  public init(baseDir: String? = nil) {
    if let baseDir = baseDir {
      self.worktreeBaseDir = baseDir
    } else {
      // Default to ~/peel-worktrees
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      self.worktreeBaseDir = "\(home)/peel-worktrees"
    }
    
    // Ensure base directory exists
    try? FileManager.default.createDirectory(
      atPath: worktreeBaseDir,
      withIntermediateDirectories: true
    )
    
    logger.info("SwarmWorktreeManager initialized with base: \(self.worktreeBaseDir)")
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
    
    // Fetch latest from origin first
    let fetchResult = try await runGitCommand(
      args: ["fetch", "origin"],
      in: repoPath
    )
    if fetchResult.exitCode != 0 {
      logger.warning("Git fetch failed: \(fetchResult.stderr)")
      // Continue anyway, might work with local refs
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
    
    // Track the worktree
    let info = WorktreeInfo(
      taskId: taskId,
      worktreePath: worktreePath,
      branchName: branchName,
      repoPath: repoPath,
      createdAt: Date()
    )
    activeWorktrees[taskId] = info
    
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
    
    guard let info = activeWorktrees[taskId] else {
      logger.warning("No worktree found for task \(taskId) - activeWorktrees: \(self.activeWorktrees.keys.map { $0.uuidString })")
      return false
    }
    
    let worktreePath = info.worktreePath
    let branchName = info.branchName
    
    // Check if there are any changes to commit
    let statusResult = try await runGitCommand(
      args: ["status", "--porcelain"],
      in: worktreePath
    )
    
    if statusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      logger.info("No changes to commit in worktree for task \(taskId)")
      return false
    }
    
    logger.info("Committing changes in worktree for task \(taskId)")
    
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
    return true
  }
  
  /// Remove a worktree for a completed/failed task
  /// - Parameters:
  ///   - taskId: The task ID
  ///   - force: Force removal even if there are uncommitted changes
  public func removeWorktree(taskId: UUID, force: Bool = false) async throws {
    guard let info = activeWorktrees[taskId] else {
      logger.warning("No worktree found for task \(taskId)")
      return
    }
    
    try await removeWorktreeAtPath(info.worktreePath, repoPath: info.repoPath, force: force)
    activeWorktrees.removeValue(forKey: taskId)
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
          "createdAt": ISO8601DateFormatter().string(from: info.createdAt)
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
