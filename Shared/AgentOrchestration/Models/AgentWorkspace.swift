//
//  AgentWorkspace.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation

/// Status of a workspace
public enum WorkspaceStatus: String, Codable, CaseIterable {
  case creating
  case ready
  case active
  case cleaning
  case error
  
  public var displayName: String {
    switch self {
    case .creating: return "Creating"
    case .ready: return "Ready"
    case .active: return "Active"
    case .cleaning: return "Cleaning Up"
    case .error: return "Error"
    }
  }
}

/// Represents an isolated workspace for an agent (backed by git worktree)
@MainActor
@Observable
public final class AgentWorkspace: Identifiable {
  public let id: UUID
  
  /// Display name for the workspace
  public var name: String
  
  /// Path to the worktree directory
  public let path: URL
  
  /// Path to the parent/main repository
  public let parentRepositoryPath: URL
  
  /// Branch checked out in this workspace
  public var branch: String
  
  /// Current HEAD commit
  public var headCommit: String?
  
  /// Status of the workspace
  public var status: WorkspaceStatus
  
  /// ID of the agent assigned to this workspace (if any)
  public var assignedAgentId: UUID?
  
  /// Timestamps
  public let createdAt: Date
  public var lastAccessedAt: Date
  
  /// Whether the workspace is locked
  public var isLocked: Bool = false
  public var lockReason: String?
  
  /// Files currently being edited
  public var activeFiles: [String] = []
  
  /// Current file content (for preview)
  public var currentFileContent: String?
  public var currentFilePath: String?
  
  /// Error message if status is .error
  public var errorMessage: String?
  
  public init(
    id: UUID = UUID(),
    name: String,
    path: URL,
    parentRepositoryPath: URL,
    branch: String,
    headCommit: String? = nil,
    status: WorkspaceStatus = .creating
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.parentRepositoryPath = parentRepositoryPath
    self.branch = branch
    self.headCommit = headCommit
    self.status = status
    self.createdAt = Date()
    self.lastAccessedAt = Date()
  }
  
  /// Mark workspace as ready for use
  public func markReady(headCommit: String? = nil) {
    status = .ready
    if let commit = headCommit {
      self.headCommit = commit
    }
    lastAccessedAt = Date()
  }
  
  /// Mark workspace as active (agent is working)
  public func markActive() {
    status = .active
    lastAccessedAt = Date()
  }
  
  /// Lock the workspace
  public func lock(reason: String? = nil) {
    isLocked = true
    lockReason = reason
  }
  
  /// Unlock the workspace
  public func unlock() {
    isLocked = false
    lockReason = nil
  }
  
  /// Mark workspace as having an error
  public func markError(_ message: String) {
    status = .error
    errorMessage = message
  }
  
  /// Assign an agent to this workspace
  public func assign(to agentId: UUID) {
    assignedAgentId = agentId
    markActive()
  }
  
  /// Unassign the current agent
  public func unassign() {
    assignedAgentId = nil
    status = .ready
  }
  
  /// Whether the workspace can be safely removed
  public var canRemove: Bool {
    !isLocked && status != .active && status != .creating
  }
}

// MARK: - Hashable & Equatable
extension AgentWorkspace: Hashable {
  public nonisolated static func == (lhs: AgentWorkspace, rhs: AgentWorkspace) -> Bool {
    lhs.id == rhs.id
  }
  
  public nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// MARK: - Convenience
extension AgentWorkspace {
  /// Generate a workspace path from repository and task info
  public static func generatePath(
    from repositoryPath: URL,
    taskId: UUID
  ) -> URL {
    let workspacesDir = repositoryPath
      .deletingLastPathComponent()
      .appendingPathComponent(".agent-workspaces", isDirectory: true)
    
    return workspacesDir.appendingPathComponent(
      "workspace-\(taskId.uuidString.prefix(8))",
      isDirectory: true
    )
  }
  
  /// Generate a branch name for a task
  public static func generateBranchName(for task: AgentTask) -> String {
    if let branch = task.branchName {
      return branch
    }
    
    let sanitized = String(BranchNameSanitizer.sanitize(task.title).prefix(40))
    return "agent/\(sanitized)-\(task.id.uuidString.prefix(8))"
  }
}
