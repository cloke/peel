//
//  WorktreeModels.swift
//  Peel
//
//  Worktree and branch reservation SwiftData models.
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData

/// Tracks a worktree created through the app (manual, swarm task, or parallel run).
/// Device-local — not synced to iCloud (paths are machine-specific).
@Model
final class TrackedWorktree {
  var id: UUID = UUID()
  var repositoryId: UUID = UUID()
  var localPath: String = ""
  var branch: String = ""
  var source: String = "manual"   // See TrackedWorktree.Source constants
  var createdAt: Date = Date()
  var purpose: String?
  var linkedPRNumber: Int?
  var linkedPRRepo: String?

  // MARK: Swarm-specific fields (populated when source == "swarm")
  /// The swarm task UUID as a string. Empty string for non-swarm worktrees.
  var taskId: String = ""
  /// Lifecycle status of the swarm task. See TrackedWorktree.Status constants.
  var taskStatus: String = "active"
  /// Absolute path to the main repository (the worktree's parent). Empty for non-swarm.
  var mainRepoPath: String = ""
  /// First 200 chars of the task prompt, for display in the status panel.
  var taskPrompt: String?
  /// Worker device ID that executed the task.
  var workerId: String?
  /// Human-readable reason if taskStatus == "failed".
  var failureReason: String?
  /// When the task finished (committed, failed, or was cleaned up).
  var completedAt: Date?

  init(repositoryId: UUID, localPath: String, branch: String, source: String = "manual", purpose: String? = nil) {
    self.id = UUID()
    self.repositoryId = repositoryId
    self.localPath = localPath
    self.branch = branch
    self.source = source
    self.createdAt = Date()
    self.purpose = purpose
  }

  func linkToPR(number: Int, repo: String) {
    linkedPRNumber = number
    linkedPRRepo = repo
    if purpose == nil {
      purpose = "PR #\(number)"
    }
  }
}

extension TrackedWorktree {
  /// Constants for the `source` field.
  enum Source {
    static let manual = "manual"
    static let swarm = "swarm"
    static let parallel = "parallel"
  }

  /// Constants for the `taskStatus` field (swarm worktrees only).
  enum Status {
    /// Task is actively running; worktree should be on disk.
    static let active = "active"
    /// Task completed and changes were committed + pushed.
    static let committed = "committed"
    /// Task execution failed; changes may or may not be committed.
    static let failed = "failed"
    /// Worktree found in DB but missing from disk/git state — needs cleanup.
    static let orphaned = "orphaned"
    /// Worktree was cleanly removed after task completion.
    static let cleaned = "cleaned"
  }

  /// Convenience: true if this is a swarm-originated worktree.
  var isSwarmWorktree: Bool { source == Source.swarm }

  /// Convenience: true if the swarm task is still in-flight.
  var isActiveSwarmTask: Bool { isSwarmWorktree && taskStatus == Status.active }
}

/// Records a branch reservation made by BranchQueue, so state survives app restarts.
/// Device-local — not synced to iCloud.
@Model
final class SwarmBranchReservation {
  var id: UUID = UUID()
  var taskId: String = ""
  var branchName: String = ""
  var repoPath: String = ""
  var workerId: String = ""
  var createdAt: Date = Date()
  /// When false the reservation has been resolved (completed or released).
  var isInFlight: Bool = true
  /// Raw value of BranchQueue.CompletedBranch.CompletionStatus, or "" while in-flight.
  var completionStatus: String = ""

  init(taskId: UUID, branchName: String, repoPath: String, workerId: String) {
    self.id = UUID()
    self.taskId = taskId.uuidString
    self.branchName = branchName
    self.repoPath = repoPath
    self.workerId = workerId
    self.createdAt = Date()
  }
}
