//
//  MCPServerService+WorktreeToolsDelegate.swift
//  KitchenSync
//
//  Extracted from MCPServerService.swift for maintainability.
//

import Foundation
import Git
import OSLog

// MARK: - WorktreeToolsHandlerDelegate

extension MCPServerService: WorktreeToolsHandlerDelegate {
  func worktreeBaseDir() -> String {
    SwarmCoordinator.shared.getWorktreeDebugInfo()["baseDir"] as? String
      ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/peel-worktrees"
  }

  func listAllWorktrees() async throws -> [WorktreeToolInfo] {
    #if os(macOS)
    var allWorktrees: [WorktreeToolInfo] = []
    let fileManager = FileManager.default
    let start = Date()
    logger.debug("listAllWorktrees start")

    // Get worktrees from peel-worktrees base directory
    let baseDir = worktreeBaseDir()
    logger.debug("listAllWorktrees baseDir=\(baseDir, privacy: .public)")
    if fileManager.fileExists(atPath: baseDir),
       let baseDirContents = try? fileManager.contentsOfDirectory(atPath: baseDir) {
      logger.debug("listAllWorktrees baseDir items=\(baseDirContents.count)")
      for item in baseDirContents where item.hasPrefix("task-") {
        let wtPath = "\(baseDir)/\(item)"
        // Read .git file to find parent repo
        let gitFilePath = "\(wtPath)/.git"
        if fileManager.fileExists(atPath: gitFilePath),
           let gitContent = try? String(contentsOfFile: gitFilePath, encoding: .utf8),
           gitContent.hasPrefix("gitdir:") {
          // Parse parent repo path from gitdir
          let gitDir = gitContent.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "gitdir: ", with: "")
          // gitdir points to .git/worktrees/<name>, so go up 3 levels for repo
          let repoPath = URL(fileURLWithPath: gitDir)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path

          // Get branch from HEAD
          let headPath = "\(gitDir)/HEAD"
          var branch: String?
          var head = "unknown"
          if let headContent = try? String(contentsOfFile: headPath, encoding: .utf8) {
            let trimmed = headContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("ref: ") {
              branch = String(trimmed.dropFirst("ref: ".count))
              head = branch ?? "unknown"
            } else {
              head = trimmed
            }
          }

          // Get creation date from directory
          let attrs = try? fileManager.attributesOfItem(atPath: wtPath)
          let createdAt = attrs?[.creationDate] as? Date

          // Calculate disk size
          let diskSize = SwarmWorktreeManager.calculateDiskSize(for: wtPath)

          allWorktrees.append(WorktreeToolInfo(
            path: wtPath,
            head: head,
            branch: branch,
            repoPath: repoPath,
            isMain: false,
            isDetached: branch == nil,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            pruneReason: nil,
            diskSizeBytes: diskSize,
            createdAt: createdAt
          ))
        } else {
          logger.debug("listAllWorktrees missing gitdir for \(wtPath, privacy: .public)")
        }
      }
    } else {
      logger.debug("listAllWorktrees baseDir missing or unreadable")
    }

    // Also get worktrees from registered repos using Git package
    if RepoRegistry.shared.registeredRepos.isEmpty {
      let bootstrapService = WorkspaceDashboardService()
      await bootstrapService.loadReposAndWorktrees()
      logger.debug("listAllWorktrees bootstrap repos=\(bootstrapService.repos.count)")
      for repo in bootstrapService.repos {
        _ = await RepoRegistry.shared.registerRepo(at: repo.path)
      }
    }

    let registeredRepos = RepoRegistry.shared.registeredRepos
    logger.debug("listAllWorktrees registeredRepos=\(registeredRepos.count)")
    for (_, localPath) in registeredRepos {
      let repoName = URL(fileURLWithPath: localPath).lastPathComponent
      let repository = Git.Model.Repository(name: repoName, path: localPath)
      if let worktrees = try? await Git.Commands.Worktree.list(on: repository) {
        logger.debug("listAllWorktrees repo=\(repoName, privacy: .public) worktrees=\(worktrees.count)")
        for wt in worktrees {
          // Skip if we already have this worktree (from base dir scan)
          if allWorktrees.contains(where: { $0.path == wt.path }) {
            continue
          }

          let diskSize = SwarmWorktreeManager.calculateDiskSize(for: wt.path)
          let attrs = try? fileManager.attributesOfItem(atPath: wt.path)
          let createdAt = attrs?[.creationDate] as? Date

          allWorktrees.append(WorktreeToolInfo(
            path: wt.path,
            head: wt.head,
            branch: wt.branch,
            repoPath: localPath,
            isMain: wt.isMain,
            isDetached: wt.isDetached,
            isLocked: wt.isLocked,
            lockReason: wt.lockReason,
            isPrunable: wt.isPrunable,
            pruneReason: wt.pruneReason,
            diskSizeBytes: diskSize,
            createdAt: createdAt
          ))
        }
      } else {
        logger.debug("listAllWorktrees failed for repo=\(repoName, privacy: .public) path=\(localPath, privacy: .public)")
      }
    }

    let elapsed = Date().timeIntervalSince(start)
    logger.debug("listAllWorktrees done count=\(allWorktrees.count) elapsed=\(elapsed, format: .fixed(precision: 2))s")

    return allWorktrees
    #else
    return []
    #endif
  }

  func removeWorktree(path: String, force: Bool) async throws {
    #if os(macOS)
    let fileManager = FileManager.default
    let resolvedPath = (path as NSString).expandingTildeInPath
    let gitFilePath = "\(resolvedPath)/.git"

    func parentRepoPath(from gitFilePath: String) -> String? {
      guard fileManager.fileExists(atPath: gitFilePath),
            let gitContent = try? String(contentsOfFile: gitFilePath, encoding: .utf8),
            gitContent.hasPrefix("gitdir:") else {
        return nil
      }

      let gitDir = gitContent.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "gitdir: ", with: "")

      return URL(fileURLWithPath: gitDir)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .path
    }

    if let repoPath = parentRepoPath(from: gitFilePath) {
      let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
      let repository = Git.Model.Repository(name: repoName, path: repoPath)

      if !fileManager.fileExists(atPath: resolvedPath) {
        try? await Git.Commands.Worktree.prune(on: repository)
        return
      }

      let knownWorktrees = try? await Git.Commands.Worktree.list(on: repository)
      let isKnown = knownWorktrees?.contains(where: { $0.path == resolvedPath }) ?? false
      if isKnown {
        do {
          try await Git.Commands.Worktree.remove(path: resolvedPath, force: force, on: repository)
          try? await Git.Commands.Worktree.prune(on: repository)
          return
        } catch {
          if force {
            if fileManager.fileExists(atPath: resolvedPath) {
              try fileManager.removeItem(atPath: resolvedPath)
            }
            try? await Git.Commands.Worktree.prune(on: repository)
            return
          }

          throw WorktreeError.worktreeRemovalFailed(error.localizedDescription)
        }
      }

      if force {
        try fileManager.removeItem(atPath: resolvedPath)
        try? await Git.Commands.Worktree.prune(on: repository)
        return
      }

      throw WorktreeError.worktreeRemovalFailed("Path is not a registered worktree: \(resolvedPath)")
    }

    // Fallback: just remove the directory if we can't find the repo
    if force {
      if fileManager.fileExists(atPath: resolvedPath) {
        try fileManager.removeItem(atPath: resolvedPath)
      }
    } else {
      throw WorktreeError.worktreeRemovalFailed("Cannot find parent repository for worktree")
    }
    #endif
  }

  func createWorktree(repoPath: String, branchName: String, baseBranch: String) async throws -> String {
    #if os(macOS)
    let baseDir = worktreeBaseDir()
    let sanitizedName = branchName.replacingOccurrences(of: "/", with: "-")
    let worktreePath = "\(baseDir)/\(sanitizedName)"

    // Ensure base directory exists
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: baseDir) {
      try fileManager.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
    }

    // Remove existing worktree at this path if it exists
    if fileManager.fileExists(atPath: worktreePath) {
      try await removeWorktree(path: worktreePath, force: true)
    }

    let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
    let repository = Git.Model.Repository(name: repoName, path: repoPath)

    // Fetch latest
    _ = try? await Git.Commands.fetch(remote: "origin", on: repository)

    // Check if branch already exists
    let branchExists = await checkBranchExists(branchName, in: repoPath)

    if branchExists {
      // Checkout existing branch in worktree
      try await Git.Commands.Worktree.add(
        path: worktreePath,
        branch: branchName,
        on: repository
      )
    } else {
      // Create new branch from base
      try await Git.Commands.Worktree.addWithNewBranch(
        path: worktreePath,
        newBranch: branchName,
        startPoint: baseBranch,
        on: repository
      )
    }

    return worktreePath
    #else
    throw WorktreeError.worktreeCreationFailed("Worktree creation is only available on macOS")
    #endif
  }

  private func checkBranchExists(_ branchName: String, in repoPath: String) async -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--verify", branchName]
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  func diskSize(for path: String) -> Int64? {
    SwarmWorktreeManager.calculateDiskSize(for: path)
  }
}
