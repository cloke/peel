//
//  WorkspaceManager.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation
import Observation

#if os(macOS)
import Git

/// Manages isolated workspaces for AI agents using git worktrees
@MainActor
@Observable
public final class WorkspaceManager {
  
  /// All managed workspaces
  public private(set) var workspaces: [AgentWorkspace] = []
  
  /// Workspaces directory relative to repository
  public static let workspacesDirName = ".agent-workspaces"
  
  public init() {}
  
  // MARK: - Workspace Lifecycle
  
  /// Creates an isolated workspace for an agent using git worktree
  /// - Parameters:
  ///   - repository: The repository model to create the worktree in
  ///   - task: The task that needs a workspace
  ///   - agentId: Optional agent to assign immediately
  /// - Returns: A new AgentWorkspace
  public func createWorkspace(
    for repository: Model.Repository,
    task: AgentTask,
    agentId: UUID? = nil
  ) async throws -> AgentWorkspace {
    let repoPath = URL(fileURLWithPath: repository.path)
    let workspacePath = AgentWorkspace.generatePath(from: repoPath, taskId: task.id)
    let branchName = AgentWorkspace.generateBranchName(for: task)
    
    // Create the workspace object first (status: creating)
    let workspace = AgentWorkspace(
      name: task.title,
      path: workspacePath,
      parentRepositoryPath: repoPath,
      branch: branchName,
      status: .creating
    )
    
    if let agentId = agentId {
      workspace.assignedAgentId = agentId
    }
    
    workspaces.append(workspace)
    
    do {
      // Ensure workspaces directory exists
      let workspacesDir = workspacePath.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: workspacesDir,
        withIntermediateDirectories: true
      )
      
      // Create the git worktree with a new branch
      try await Commands.Worktree.addWithNewBranch(
        path: workspacePath.path,
        newBranch: branchName,
        startPoint: nil, // Defaults to HEAD
        on: repository
      )
      
      // Get the HEAD commit for the new worktree
      let worktrees = try await Commands.Worktree.list(on: repository)
      let headCommit = worktrees.first { $0.path == workspacePath.path }?.head
      
      workspace.markReady(headCommit: headCommit)
      
      return workspace
      
    } catch {
      workspace.markError(error.localizedDescription)
      throw WorkspaceError.creationFailed(error)
    }
  }
  
  /// Creates a workspace from an existing worktree
  /// - Parameters:
  ///   - worktree: The existing Git worktree
  ///   - repository: The parent repository
  /// - Returns: A new AgentWorkspace wrapping the worktree
  public func importWorktree(
    _ worktree: Git.Worktree,
    from repository: Model.Repository
  ) -> AgentWorkspace {
    let workspace = AgentWorkspace(
      name: worktree.displayName,
      path: URL(fileURLWithPath: worktree.path),
      parentRepositoryPath: URL(fileURLWithPath: repository.path),
      branch: worktree.branch ?? "detached",
      headCommit: worktree.head,
      status: worktree.isLocked ? .active : .ready
    )
    
    if worktree.isLocked {
      workspace.lock(reason: worktree.lockReason)
    }
    
    if !workspaces.contains(where: { $0.path == workspace.path }) {
      workspaces.append(workspace)
    }
    
    return workspace
  }
  
  /// Cleans up a workspace by removing its worktree
  /// - Parameters:
  ///   - workspace: The workspace to clean up
  ///   - force: Force removal even if dirty
  public func cleanupWorkspace(
    _ workspace: AgentWorkspace,
    force: Bool = false
  ) async throws {
    guard workspace.canRemove || force else {
      throw WorkspaceError.cannotRemove(reason: "Workspace is locked or in use")
    }
    
    workspace.status = .cleaning
    
    // Create a temporary repository model for the parent
    let parentRepo = Model.Repository(
      name: workspace.parentRepositoryPath.lastPathComponent,
      path: workspace.parentRepositoryPath.path
    )
    
    do {
      // Unlock if needed
      if workspace.isLocked {
        try await Commands.Worktree.unlock(
          path: workspace.path.path,
          on: parentRepo
        )
      }
      
      // Remove the worktree
      try await Commands.Worktree.remove(
        path: workspace.path.path,
        force: force,
        on: parentRepo
      )
      
      // Remove from our list
      workspaces.removeAll { $0.id == workspace.id }
      
    } catch {
      workspace.markError(error.localizedDescription)
      throw WorkspaceError.cleanupFailed(error)
    }
  }
  
  /// Cleans up all workspaces for a repository
  public func cleanupAllWorkspaces(
    for repository: Model.Repository,
    force: Bool = false
  ) async throws {
    let repoPath = URL(fileURLWithPath: repository.path)
    let toRemove = workspaces.filter { $0.parentRepositoryPath == repoPath }
    
    for workspace in toRemove {
      try await cleanupWorkspace(workspace, force: force)
    }
    
    // Prune any stale worktree references
    try await Commands.Worktree.prune(on: repository)
  }
  
  // MARK: - Workspace Queries
  
  /// Refresh the workspace list from git worktrees
  public func refreshWorkspaces(for repository: Model.Repository) async throws {
    let gitWorktrees = try await Commands.Worktree.list(on: repository)
    let repoPath = URL(fileURLWithPath: repository.path)
    
    // Update existing workspaces and add new ones
    for worktree in gitWorktrees {
      // Skip the main worktree (original repo)
      guard !worktree.isMain else { continue }
      
      let worktreePath = URL(fileURLWithPath: worktree.path)
      
      if let existing = workspaces.first(where: { $0.path == worktreePath }) {
        // Update existing
        existing.headCommit = worktree.head
        existing.branch = worktree.branch ?? existing.branch
        existing.isLocked = worktree.isLocked
        existing.lockReason = worktree.lockReason
      } else {
        // Import as new
        _ = importWorktree(worktree, from: repository)
      }
    }
    
    // Remove workspaces that no longer exist
    let gitPaths = Set(gitWorktrees.map { URL(fileURLWithPath: $0.path) })
    workspaces.removeAll { workspace in
      workspace.parentRepositoryPath == repoPath && !gitPaths.contains(workspace.path)
    }
  }
  
  /// Get workspaces for a specific repository
  public func workspaces(for repositoryPath: URL) -> [AgentWorkspace] {
    workspaces.filter { $0.parentRepositoryPath == repositoryPath }
  }
  
  /// Get workspace for a specific agent
  public func workspace(for agentId: UUID) -> AgentWorkspace? {
    workspaces.first { $0.assignedAgentId == agentId }
  }
  
  /// Get available (unassigned) workspaces
  public var availableWorkspaces: [AgentWorkspace] {
    workspaces.filter { $0.assignedAgentId == nil && $0.status == .ready }
  }
  
  // MARK: - Workspace Operations
  
  /// Lock a workspace to prevent cleanup
  public func lockWorkspace(
    _ workspace: AgentWorkspace,
    reason: String? = nil,
    repository: Model.Repository
  ) async throws {
    try await Commands.Worktree.lock(
      path: workspace.path.path,
      reason: reason,
      on: repository
    )
    workspace.lock(reason: reason)
  }
  
  /// Unlock a workspace
  public func unlockWorkspace(
    _ workspace: AgentWorkspace,
    repository: Model.Repository
  ) async throws {
    try await Commands.Worktree.unlock(
      path: workspace.path.path,
      on: repository
    )
    workspace.unlock()
  }
}

// MARK: - Errors

public enum WorkspaceError: LocalizedError {
  case creationFailed(Error)
  case cleanupFailed(Error)
  case cannotRemove(reason: String)
  case notFound
  
  public var errorDescription: String? {
    switch self {
    case .creationFailed(let error):
      return "Failed to create workspace: \(error.localizedDescription)"
    case .cleanupFailed(let error):
      return "Failed to cleanup workspace: \(error.localizedDescription)"
    case .cannotRemove(let reason):
      return "Cannot remove workspace: \(reason)"
    case .notFound:
      return "Workspace not found"
    }
  }
}

#else
// iOS stub - workspaces not supported
@MainActor
@Observable
public final class WorkspaceManager {
  public private(set) var workspaces: [AgentWorkspace] = []
  public init() {}
}

public enum WorkspaceError: LocalizedError {
  case notSupported
  
  public var errorDescription: String? {
    "Workspaces are only supported on macOS"
  }
}
#endif
