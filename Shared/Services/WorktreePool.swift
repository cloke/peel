//
//  WorktreePool.swift
//  Peel
//
//  Pre-creates git worktrees so task dispatch is instant instead of waiting 10-30s.
//

import Foundation

// MARK: - Config & Status

public enum RecyclePolicy: Sendable {
  case resetAndReuse
  case destroyAndReplace
}

public struct WorktreePoolConfig: Sendable {
  public var poolSize: Int
  public var baseBranch: String
  public var recyclePolicy: RecyclePolicy
  public var repoPath: String

  public init(
    repoPath: String,
    poolSize: Int = 3,
    baseBranch: String = "main",
    recyclePolicy: RecyclePolicy = .resetAndReuse
  ) {
    self.repoPath = repoPath
    self.poolSize = poolSize
    self.baseBranch = baseBranch
    self.recyclePolicy = recyclePolicy
  }
}

public struct PoolStatus: Sendable {
  public let warmCount: Int
  public let totalCount: Int
  public let config: WorktreePoolConfig
}

// MARK: - Internal representation

struct PooledWorktree: Sendable {
  let path: String
  let branch: String
  let id: UUID
}

// MARK: - Actor

public actor WorktreePool {
  private var pool: [PooledWorktree] = []
  private var totalCreated: Int = 0
  public let config: WorktreePoolConfig
  private let mcpLog = MCPLogService.shared

  public init(config: WorktreePoolConfig) {
    self.config = config
  }

  // MARK: - Public API

  /// Pre-creates `config.poolSize` worktrees so the pool is ready for immediate use.
  public func warmUp() async throws {
    for _ in 0..<config.poolSize {
      let wt = try await createWorktree()
      pool.append(wt)
    }
    await mcpLog.info("WorktreePool warmed up", metadata: [
      "poolSize": "\(pool.count)",
      "repoPath": config.repoPath
    ])
  }

  /// Returns a warm worktree path and branch, removing it from the pool.
  /// Triggers background replenishment automatically.
  public func claim() async throws -> (path: String, branch: String) {
    let worktree: PooledWorktree
    if pool.isEmpty {
      await mcpLog.info("WorktreePool cold-path claim", metadata: ["repoPath": config.repoPath])
      worktree = try await createWorktree()
    } else {
      worktree = pool.removeFirst()
    }

    // Background replenishment — fire and forget
    Task { await replenish() }

    await mcpLog.info("WorktreePool claimed worktree", metadata: [
      "path": worktree.path,
      "branch": worktree.branch,
      "warmRemaining": "\(pool.count)"
    ])

    return (path: worktree.path, branch: worktree.branch)
  }

  /// Creates a new warm worktree to replace a claimed one.
  public func replenish() async {
    do {
      let wt = try await createWorktree()
      pool.append(wt)
      await mcpLog.info("WorktreePool replenished", metadata: [
        "path": wt.path,
        "poolSize": "\(pool.count)"
      ])
    } catch {
      await mcpLog.error(error, context: "WorktreePool replenishment failed", metadata: [
        "repoPath": config.repoPath
      ])
    }
  }

  /// Recycles a worktree after use: either reset+reuse or destroy+replace.
  public func recycle(path: String) async {
    switch config.recyclePolicy {
    case .resetAndReuse:
      await mcpLog.info("WorktreePool recycling (reset)", metadata: ["path": path])
      let (_, resetCode) = await runGit(["reset", "--hard"], in: path)
      let (_, checkoutCode) = await runGit(["checkout", config.baseBranch], in: path)
      let (_, pullCode) = await runGit(["pull"], in: path)
      if resetCode == 0, checkoutCode == 0, pullCode == 0 {
        // Find original branch from the path if we stored it; reconstruct a PooledWorktree stub
        let branch = pool.first(where: { $0.path == path })?.branch
          ?? "pool/recycled-\(UUID().uuidString.lowercased().prefix(8))"
        let wt = PooledWorktree(path: path, branch: branch, id: UUID())
        pool.append(wt)
        await mcpLog.info("WorktreePool worktree recycled and returned to pool", metadata: ["path": path])
      } else {
        await mcpLog.warning("WorktreePool reset failed, falling back to destroy+replace", metadata: ["path": path])
        await destroyAndReplace(path: path)
      }

    case .destroyAndReplace:
      await destroyAndReplace(path: path)
    }
  }

  /// Returns pool status.
  public func status() -> PoolStatus {
    PoolStatus(warmCount: pool.count, totalCount: totalCreated, config: config)
  }

  // MARK: - Private helpers

  private func destroyAndReplace(path: String) async {
    let (_, removeCode) = await runGit(["worktree", "remove", "--force", path], in: config.repoPath)
    if removeCode != 0 {
      try? FileManager.default.removeItem(atPath: path)
    }
    do {
      let wt = try await createWorktree()
      pool.append(wt)
      await mcpLog.info("WorktreePool replaced destroyed worktree", metadata: [
        "newPath": wt.path,
        "poolSize": "\(pool.count)"
      ])
    } catch {
      await mcpLog.error(error, context: "WorktreePool failed to replace destroyed worktree", metadata: [
        "repoPath": config.repoPath
      ])
    }
  }

  private func createWorktree() async throws -> PooledWorktree {
    let uuid = UUID()
    let poolDir = URL(fileURLWithPath: config.repoPath)
      .deletingLastPathComponent()
      .appendingPathComponent(".agent-workspaces/pool-\(uuid.uuidString.lowercased())")
    let path = poolDir.path
    let branch = "pool/\(uuid.uuidString.lowercased().prefix(8))"

    try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)

    let (output, exitCode) = await runGit(
      ["worktree", "add", "-b", branch, path, config.baseBranch],
      in: config.repoPath
    )

    guard exitCode == 0 else {
      try? FileManager.default.removeItem(at: poolDir)
      throw WorktreeError.worktreeCreationFailed(output)
    }

    totalCreated += 1
    return PooledWorktree(path: path, branch: branch, id: uuid)
  }

  private func runGit(_ arguments: [String], in directoryPath: String) async -> (String, Int32) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: directoryPath)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
          try process.run()
          process.waitUntilExit()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          let output = String(data: data, encoding: .utf8) ?? ""
          continuation.resume(returning: (output, process.terminationStatus))
        } catch {
          continuation.resume(returning: (error.localizedDescription, -1))
        }
      }
    }
  }
}
