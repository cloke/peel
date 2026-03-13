//
//  Worktree.swift
//
//
//  Created by Cory Loken on 5/9/21.
//  Implemented on 1/7/26
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-worktree

import Foundation


/// Represents a git worktree
public struct Worktree: Identifiable, Equatable {
  public let id: String
  public let path: String
  public let head: String
  public let branch: String?
  public let isDetached: Bool
  public let isLocked: Bool
  public let lockReason: String?
  public let isPrunable: Bool
  public let pruneReason: String?
  public let isBare: Bool
  
  /// Whether this is the main worktree (the original repository)
  public var isMain: Bool {
    branch == nil && !isDetached || path.hasSuffix(".git")
  }
  
  public init(
    id: String? = nil,
    path: String,
    head: String,
    branch: String? = nil,
    isDetached: Bool = false,
    isLocked: Bool = false,
    lockReason: String? = nil,
    isPrunable: Bool = false,
    pruneReason: String? = nil,
    isBare: Bool = false
  ) {
    self.id = id ?? path
    self.path = path
    self.head = head
    self.branch = branch
    self.isDetached = isDetached
    self.isLocked = isLocked
    self.lockReason = lockReason
    self.isPrunable = isPrunable
    self.pruneReason = pruneReason
    self.isBare = isBare
  }
  
  /// Display name for the worktree
  public var displayName: String {
    if let branch = branch {
      // Extract just the branch name from refs/heads/...
      if branch.hasPrefix("refs/heads/") {
        return String(branch.dropFirst("refs/heads/".count))
      }
      return branch
    } else if isDetached {
      return "detached @ \(String(head.prefix(7)))"
    } else {
      return URL(fileURLWithPath: path).lastPathComponent
    }
  }
}

extension Commands {
  public enum Worktree {
    
    /// List all worktrees for a repository
    /// Uses porcelain format for reliable parsing
    public static func list(on repository: Model.Repository) async throws -> [Git.Worktree] {
      let lines = try await Commands.simple(
        arguments: ["worktree", "list", "--porcelain"],
        in: repository
      )
      return parseWorktreeList(lines)
    }
    
    /// Add a new worktree
    /// - Parameters:
    ///   - path: Path where the worktree will be created
    ///   - branch: Branch to check out (must exist)
    ///   - repository: The repository to create the worktree in
    public static func add(
      path: String,
      branch: String,
      on repository: Model.Repository
    ) async throws {
      _ = try await Commands.simple(
        arguments: ["worktree", "add", path, branch],
        in: repository
      )
    }
    
    /// Add a new worktree with a new branch
    /// - Parameters:
    ///   - path: Path where the worktree will be created
    ///   - newBranch: Name of the new branch to create
    ///   - startPoint: Optional starting point (commit/branch)
    ///   - repository: The repository to create the worktree in
    public static func addWithNewBranch(
      path: String,
      newBranch: String,
      startPoint: String? = nil,
      on repository: Model.Repository
    ) async throws {
      var args = ["worktree", "add", "-b", newBranch, path]
      if let startPoint = startPoint {
        args.append(startPoint)
      }
      _ = try await Commands.simple(arguments: args, in: repository)
    }
    
    /// Remove a worktree
    /// - Parameters:
    ///   - path: Path of the worktree to remove
    ///   - force: Force removal even if worktree is dirty
    ///   - repository: The repository containing the worktree
    public static func remove(
      path: String,
      force: Bool = false,
      on repository: Model.Repository
    ) async throws {
      var args = ["worktree", "remove"]
      if force {
        args.append("--force")
      }
      args.append(path)
      _ = try await Commands.simple(arguments: args, in: repository)
    }
    
    /// Lock a worktree to prevent pruning
    public static func lock(
      path: String,
      reason: String? = nil,
      on repository: Model.Repository
    ) async throws {
      var args = ["worktree", "lock"]
      if let reason = reason {
        args.append(contentsOf: ["--reason", reason])
      }
      args.append(path)
      _ = try await Commands.simple(arguments: args, in: repository)
    }
    
    /// Unlock a worktree
    public static func unlock(
      path: String,
      on repository: Model.Repository
    ) async throws {
      _ = try await Commands.simple(
        arguments: ["worktree", "unlock", path],
        in: repository
      )
    }
    
    /// Prune stale worktree information
    public static func prune(on repository: Model.Repository) async throws {
      _ = try await Commands.simple(
        arguments: ["worktree", "prune"],
        in: repository
      )
    }
    
    // MARK: - Parsing
    
    /// Parse the porcelain output of `git worktree list --porcelain`
    private static func parseWorktreeList(_ lines: [String]) -> [Git.Worktree] {
      var worktrees: [Git.Worktree] = []
      
      var currentPath: String?
      var currentHead: String?
      var currentBranch: String?
      var isDetached = false
      var isLocked = false
      var lockReason: String?
      var isPrunable = false
      var pruneReason: String?
      var isBare = false
      
      for line in lines {
        if line.isEmpty {
          // End of worktree entry, save it
          if let path = currentPath, let head = currentHead {
            worktrees.append(Git.Worktree(
              path: path,
              head: head,
              branch: currentBranch,
              isDetached: isDetached,
              isLocked: isLocked,
              lockReason: lockReason,
              isPrunable: isPrunable,
              pruneReason: pruneReason,
              isBare: isBare
            ))
          }
          // Reset for next entry
          currentPath = nil
          currentHead = nil
          currentBranch = nil
          isDetached = false
          isLocked = false
          lockReason = nil
          isPrunable = false
          pruneReason = nil
          isBare = false
        } else if line.hasPrefix("worktree ") {
          currentPath = String(line.dropFirst("worktree ".count))
        } else if line.hasPrefix("HEAD ") {
          currentHead = String(line.dropFirst("HEAD ".count))
        } else if line.hasPrefix("branch ") {
          currentBranch = String(line.dropFirst("branch ".count))
        } else if line == "detached" {
          isDetached = true
        } else if line == "locked" {
          isLocked = true
        } else if line.hasPrefix("locked ") {
          isLocked = true
          lockReason = String(line.dropFirst("locked ".count))
        } else if line == "prunable" {
          isPrunable = true
        } else if line.hasPrefix("prunable ") {
          isPrunable = true
          pruneReason = String(line.dropFirst("prunable ".count))
        } else if line == "bare" {
          isBare = true
        }
      }
      
      // Don't forget the last entry (no trailing blank line)
      if let path = currentPath, let head = currentHead {
        worktrees.append(Git.Worktree(
          path: path,
          head: head,
          branch: currentBranch,
          isDetached: isDetached,
          isLocked: isLocked,
          lockReason: lockReason,
          isPrunable: isPrunable,
          pruneReason: pruneReason,
          isBare: isBare
        ))
      }
      
      return worktrees
    }
  }
}
