//
//  WorktreeService.swift
//  KitchenSync
//
//  Created on 1/10/26.
//
//  Service for managing git worktrees for agent chains.
//  Each chain gets an isolated worktree to work in, preventing conflicts
//  when multiple chains run on the same project.
//

import Foundation
import Git

#if os(macOS)

/// Manages git worktrees for agent chain isolation
@MainActor
@Observable
public final class WorktreeService {
  
  // MARK: - Types
  
  /// Represents an active worktree being used by a chain
  public struct ActiveWorktree: Identifiable {
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
  
  // MARK: - Properties
  
  /// Currently active worktrees managed by this service
  public private(set) var activeWorktrees: [ActiveWorktree] = []
  
  /// Base directory for chain worktrees
  private let worktreeBaseDir: URL
  
  // MARK: - Init
  
  public init() {
    // Use a subdirectory in the app's temp folder
    let tempDir = FileManager.default.temporaryDirectory
    self.worktreeBaseDir = tempDir.appendingPathComponent("Peel-Worktrees", isDirectory: true)
    
    // Ensure the base directory exists
    try? FileManager.default.createDirectory(at: worktreeBaseDir, withIntermediateDirectories: true)
  }
  
  // MARK: - Public API
  
  /// Create an isolated worktree for a chain to work in
  /// - Parameters:
  ///   - chainId: The chain's unique identifier
  ///   - chainName: Human-readable name for the chain
  ///   - projectPath: Path to the main repository
  ///   - branchName: Name for the new branch (will be created)
  /// - Returns: Path to the new worktree
  public func createWorktreeForChain(
    chainId: UUID,
    chainName: String,
    projectPath: String,
    branchName: String? = nil
  ) async throws -> String {
    // Verify the project is a git repository
    guard FileManager.default.fileExists(atPath: projectPath.appendingPathComponent(".git")) else {
      throw WorktreeError.repositoryNotFound(projectPath)
    }
    
    // Create repository reference
    let repository = Model.Repository(
      name: URL(fileURLWithPath: projectPath).lastPathComponent,
      path: projectPath
    )
    
    // Generate unique worktree path and branch name
    let timestamp = Int(Date().timeIntervalSince1970)
    let sanitizedChainName = chainName.replacingOccurrences(of: " ", with: "-").lowercased()
    let worktreeName = "chain-\(sanitizedChainName)-\(timestamp)"
    let worktreePath = worktreeBaseDir.appendingPathComponent(worktreeName).path
    let branch = branchName ?? "chain/\(sanitizedChainName)-\(timestamp)"
    
    do {
      // Create worktree with new branch from HEAD
      try await Commands.Worktree.addWithNewBranch(
        path: worktreePath,
        newBranch: branch,
        startPoint: "HEAD",
        on: repository
      )
      
      // Track the active worktree
      let activeWorktree = ActiveWorktree(
        id: UUID(),
        chainId: chainId,
        chainName: chainName,
        path: worktreePath,
        branch: branch,
        createdAt: Date()
      )
      activeWorktrees.append(activeWorktree)
      
      return worktreePath
      
    } catch {
      throw WorktreeError.worktreeCreationFailed(error.localizedDescription)
    }
  }
  
  /// Create multiple worktrees for parallel implementers
  /// - Parameters:
  ///   - chainId: The chain's unique identifier
  ///   - chainName: Human-readable name for the chain
  ///   - projectPath: Path to the main repository
  ///   - count: Number of worktrees to create
  ///   - baseBranch: Base branch name (each worktree gets a numbered variant)
  /// - Returns: Array of worktree paths
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
  
  /// Remove a worktree when a chain completes
  /// - Parameter chainId: The chain's unique identifier
  public func removeWorktreeForChain(chainId: UUID) async throws {
    guard let worktree = activeWorktrees.first(where: { $0.chainId == chainId }) else {
      return // No worktree for this chain, nothing to do
    }
    
    try await removeWorktree(worktree)
  }
  
  /// Remove all worktrees for a chain (for parallel chains)
  public func removeAllWorktreesForChain(chainId: UUID) async throws {
    let worktreesToRemove = activeWorktrees.filter { $0.chainId == chainId }
    
    for worktree in worktreesToRemove {
      try await removeWorktree(worktree)
    }
  }
  
  /// Remove a specific worktree
  private func removeWorktree(_ worktree: ActiveWorktree) async throws {
    // Update status
    if let index = activeWorktrees.firstIndex(where: { $0.id == worktree.id }) {
      activeWorktrees[index].status = .completing
    }
    
    // Find the main repository (parent of worktree)
    // We need to run git worktree remove from a valid git context
    let gitDir = findGitDir(from: worktree.path)
    guard let mainRepoPath = gitDir else {
      throw WorktreeError.worktreeRemovalFailed("Could not find main repository")
    }
    
    let repository = Model.Repository(
      name: URL(fileURLWithPath: mainRepoPath).lastPathComponent,
      path: mainRepoPath
    )
    
    do {
      // Force remove (in case there are uncommitted changes from agent work)
      try await Commands.Worktree.remove(path: worktree.path, force: true, on: repository)
      
      // Remove from active list
      activeWorktrees.removeAll { $0.id == worktree.id }
      
      // Also delete the branch if it exists
      // (branches from worktrees stick around after removal)
      try? await deleteBranch(worktree.branch, on: repository)
      
    } catch {
      // Mark as failed but still remove from tracking
      if let index = activeWorktrees.firstIndex(where: { $0.id == worktree.id }) {
        activeWorktrees[index].status = .failed(error.localizedDescription)
      }
      throw WorktreeError.worktreeRemovalFailed(error.localizedDescription)
    }
  }
  
  /// Get worktree path for a chain (if one exists)
  public func getWorktreePath(for chainId: UUID) -> String? {
    activeWorktrees.first { $0.chainId == chainId }?.path
  }
  
  /// Get all worktree paths for a chain (for parallel chains)
  public func getAllWorktreePaths(for chainId: UUID) -> [String] {
    activeWorktrees.filter { $0.chainId == chainId }.map { $0.path }
  }
  
  /// Cleanup all worktrees (e.g., on app quit)
  public func cleanupAllWorktrees() async {
    for worktree in activeWorktrees {
      try? await removeWorktree(worktree)
    }
  }
  
  /// Cleanup stale worktrees from previous sessions
  public func cleanupStaleWorktrees() async {
    // Remove any worktree directories that exist but aren't tracked
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: worktreeBaseDir,
      includingPropertiesForKeys: nil
    ) else { return }
    
    for url in contents {
      // Only remove chain- directories
      guard url.lastPathComponent.hasPrefix("chain-") else { continue }
      
      // Check if it's tracked
      let isTracked = activeWorktrees.contains { $0.path == url.path }
      if !isTracked {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
  
  // MARK: - Private Helpers
  
  /// Find the main .git directory from a worktree path
  private func findGitDir(from worktreePath: String) -> String? {
    // In a worktree, .git is a file pointing to the real git dir
    let gitPath = worktreePath.appendingPathComponent(".git")
    
    guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8) else {
      return nil
    }
    
    // Format: "gitdir: /path/to/main/repo/.git/worktrees/worktree-name"
    if content.hasPrefix("gitdir: ") {
      let gitDir = content.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
      // Go up from .git/worktrees/name to .git to main repo
      if let worktreesRange = gitDir.range(of: "/.git/worktrees/") {
        return String(gitDir[..<worktreesRange.lowerBound])
      }
    }
    
    return nil
  }
  
  /// Delete a branch
  private func deleteBranch(_ branch: String, on repository: Model.Repository) async throws {
    _ = try await Commands.simple(
      arguments: ["branch", "-D", branch],
      in: repository
    )
  }
}

// MARK: - String Extension

private extension String {
  func appendingPathComponent(_ component: String) -> String {
    (self as NSString).appendingPathComponent(component)
  }
}

#else

// iOS stub
@MainActor
@Observable
public final class WorktreeService {
  public struct ActiveWorktree: Identifiable {
    public let id = UUID()
  }
  public private(set) var activeWorktrees: [ActiveWorktree] = []
  public init() {}
}

#endif
