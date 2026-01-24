//
//  WorkspaceManager.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation
import Observation
import Git

/// Manages isolated workspaces for AI agents and chain worktrees using git worktrees
@MainActor
@Observable
public final class AgentWorkspaceService {
  
  /// All managed workspaces
  public private(set) var workspaces: [AgentWorkspace] = []

  /// Active chain worktrees managed by this service
  public private(set) var activeChainWorktrees: [ChainWorktree] = []
  
  /// Workspaces directory relative to repository
  public static let workspacesDirName = ".agent-workspaces"

  /// Base directory for chain worktrees
  private let chainWorktreeBaseDir: URL
  
  public init() {
    let tempDir = FileManager.default.temporaryDirectory
    self.chainWorktreeBaseDir = tempDir.appendingPathComponent("Peel-Worktrees", isDirectory: true)

    // Ensure the base directory exists
    try? FileManager.default.createDirectory(at: chainWorktreeBaseDir, withIntermediateDirectories: true)
  }

  // MARK: - Chain Worktrees

  public struct ChainWorktree: Identifiable {
    public let id: UUID
    public let chainId: UUID
    public let chainName: String
    public let path: String
    public let branch: String
    public let createdAt: Date
    public var status: Status = .active

    public enum Status {
      case active
      case completing
      case failed(String)
    }
  }

  public func createWorktreeForChain(
    chainId: UUID,
    chainName: String,
    projectPath: String,
    branchName: String? = nil
  ) async throws -> String {
    guard FileManager.default.fileExists(atPath: projectPath.appendingPathComponent(".git")) else {
      throw WorktreeError.repositoryNotFound(projectPath)
    }

    let repository = Model.Repository(
      name: URL(fileURLWithPath: projectPath).lastPathComponent,
      path: projectPath
    )

    let timestamp = Int(Date().timeIntervalSince1970)
    let sanitizedChainName = chainName.replacingOccurrences(of: " ", with: "-").lowercased()
    let worktreeName = "chain-\(sanitizedChainName)-\(timestamp)"
    let worktreePath = chainWorktreeBaseDir.appendingPathComponent(worktreeName).path
    let branch = branchName ?? "chain/\(sanitizedChainName)-\(timestamp)"

    do {
      try await Commands.Worktree.addWithNewBranch(
        path: worktreePath,
        newBranch: branch,
        startPoint: "HEAD",
        on: repository
      )

      let chainWorktree = ChainWorktree(
        id: UUID(),
        chainId: chainId,
        chainName: chainName,
        path: worktreePath,
        branch: branch,
        createdAt: Date()
      )
      activeChainWorktrees.append(chainWorktree)

      return worktreePath
    } catch {
      throw WorktreeError.worktreeCreationFailed(error.localizedDescription)
    }
  }

  public func createWorktreesForParallelChain(
    chainId: UUID,
    chainName: String,
    projectPath: String,
    count: Int,
    baseBranch: String? = nil
  ) async throws -> [String] {
    var paths: [String] = []
    let timestamp = Int(Date().timeIntervalSince1970)
    let sanitizedChainName = chainName.replacingOccurrences(of: " ", with: "-").lowercased()
    let baseBranchName = baseBranch ?? "chain/\(sanitizedChainName)-\(timestamp)"

    for index in 0..<count {
      let branchName = "\(baseBranchName)-impl\(index)"
      let path = try await createWorktreeForChain(
        chainId: chainId,
        chainName: "\(chainName) (Impl \(index + 1))",
        projectPath: projectPath,
        branchName: branchName
      )
      paths.append(path)
    }

    return paths
  }

  public func removeWorktreeForChain(chainId: UUID) async throws {
    guard let worktree = activeChainWorktrees.first(where: { $0.chainId == chainId }) else {
      return
    }
    try await removeChainWorktree(worktree)
  }

  public func removeAllWorktreesForChain(chainId: UUID) async throws {
    let worktreesToRemove = activeChainWorktrees.filter { $0.chainId == chainId }
    for worktree in worktreesToRemove {
      try await removeChainWorktree(worktree)
    }
  }

  public func getWorktreePath(for chainId: UUID) -> String? {
    activeChainWorktrees.first { $0.chainId == chainId }?.path
  }

  public func getAllWorktreePaths(for chainId: UUID) -> [String] {
    activeChainWorktrees.filter { $0.chainId == chainId }.map { $0.path }
  }

  public func cleanupAllWorktrees() async {
    for worktree in activeChainWorktrees {
      try? await removeChainWorktree(worktree)
    }
  }

  public func cleanupStaleWorktrees() async {
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: chainWorktreeBaseDir,
      includingPropertiesForKeys: nil
    ) else { return }

    for url in contents {
      guard url.lastPathComponent.hasPrefix("chain-") else { continue }
      let isTracked = activeChainWorktrees.contains { $0.path == url.path }
      if !isTracked {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
  
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
      throw WorktreeError.creationFailed(error)
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
      throw WorktreeError.cannotRemove(reason: "Workspace is locked or in use")
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
      throw WorktreeError.cleanupFailed(error)
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

  // MARK: - Private Helpers (Chain Worktrees)

  private func removeChainWorktree(_ worktree: ChainWorktree) async throws {
    if let index = activeChainWorktrees.firstIndex(where: { $0.id == worktree.id }) {
      activeChainWorktrees[index].status = .completing
    }

    let gitDir = findGitDir(from: worktree.path)
    guard let mainRepoPath = gitDir else {
      throw WorktreeError.worktreeRemovalFailed("Could not find main repository")
    }

    let repository = Model.Repository(
      name: URL(fileURLWithPath: mainRepoPath).lastPathComponent,
      path: mainRepoPath
    )

    do {
      try await Commands.Worktree.remove(path: worktree.path, force: true, on: repository)
      activeChainWorktrees.removeAll { $0.id == worktree.id }
      try? await deleteBranch(worktree.branch, on: repository)
    } catch {
      if let index = activeChainWorktrees.firstIndex(where: { $0.id == worktree.id }) {
        activeChainWorktrees[index].status = .failed(error.localizedDescription)
      }
      throw WorktreeError.worktreeRemovalFailed(error.localizedDescription)
    }
  }

  private func findGitDir(from worktreePath: String) -> String? {
    let gitPath = worktreePath.appendingPathComponent(".git")
    guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8) else {
      return nil
    }

    if content.hasPrefix("gitdir: ") {
      let gitDir = content.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
      if let worktreesRange = gitDir.range(of: "/.git/worktrees/") {
        return String(gitDir[..<worktreesRange.lowerBound])
      }
    }

    return nil
  }

  private func deleteBranch(_ branch: String, on repository: Model.Repository) async throws {
    _ = try await Commands.simple(
      arguments: ["branch", "-D", branch],
      in: repository
    )
  }
}

private extension String {
  func appendingPathComponent(_ component: String) -> String {
    (self as NSString).appendingPathComponent(component)
  }
}


