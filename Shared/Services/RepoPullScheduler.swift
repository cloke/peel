//
//  RepoPullScheduler.swift
//  Peel
//
//  Periodically pulls latest changes for repos marked as "primary" (tracked).
//  Runs a background timer that checks which tracked repos are due for a pull,
//  executes `git pull`, and optionally triggers a RAG re-index.
//

import Foundation
import OSLog
import SwiftData

// MARK: - Pull Result

public enum RepoPullResult: Sendable {
  case upToDate
  case updated(String) // new HEAD SHA
  case error(String)

  var description: String {
    switch self {
    case .upToDate: return "up-to-date"
    case .updated(let sha): return "updated to \(sha)"
    case .error(let msg): return "error: \(msg)"
    }
  }

  var isError: Bool {
    if case .error = self { return true }
    return false
  }
}

// MARK: - Scheduler Delegate

@MainActor
public protocol RepoPullSchedulerDelegate: AnyObject {
  /// Called after a successful pull that changed the repo, so the delegate can trigger re-indexing.
  func repoPullScheduler(_ scheduler: RepoPullScheduler, shouldReindex repoPath: String)
}

// MARK: - Scheduler

@MainActor
@Observable
public final class RepoPullScheduler {
  static let shared = RepoPullScheduler()

  private let logger = Logger(subsystem: "com.peel.services", category: "RepoPullScheduler")

  // MARK: - Dependencies

  /// DataService for reading/writing TrackedRemoteRepo records.
  /// Must be set before calling start().
  weak var dataService: DataService?

  /// Optional delegate for triggering RAG re-index after pull.
  weak var delegate: RepoPullSchedulerDelegate?

  // MARK: - State

  /// Whether the scheduler is actively running.
  public private(set) var isActive = false

  /// How often the scheduler checks for due repos (default: 5 minutes).
  /// The actual pull interval per-repo is stored on each TrackedRemoteRepo.
  public var checkIntervalSeconds: TimeInterval = 300

  /// History of recent pull operations (most recent first, capped at 50).
  public private(set) var pullHistory: [PullHistoryEntry] = []

  /// Whether a pull cycle is currently in progress.
  public private(set) var isPulling = false

  // MARK: - Private

  private var timerTask: Task<Void, Never>?

  private init() {}

  // MARK: - Lifecycle

  /// Start the periodic pull scheduler.
  func start() {
    guard !isActive else { return }
    guard dataService != nil else {
      logger.warning("Cannot start RepoPullScheduler: dataService not set")
      return
    }

    isActive = true
    logger.info("RepoPullScheduler started (check interval: \(self.checkIntervalSeconds)s)")

    timerTask = Task { [weak self] in
      // Initial pull on start (after a short delay to let the app settle)
      try? await Task.sleep(for: .seconds(10))
      await self?.pullDueRepos()

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(self?.checkIntervalSeconds ?? 300))
        guard !Task.isCancelled else { break }
        await self?.pullDueRepos()
      }
    }
  }

  /// Stop the scheduler.
  func stop() {
    timerTask?.cancel()
    timerTask = nil
    isActive = false
    logger.info("RepoPullScheduler stopped")
  }

  // MARK: - Manual Trigger

  /// Manually trigger a pull for all due repos right now.
  func pullDueRepos() async {
    guard let dataService else { return }
    guard !isPulling else {
      logger.info("Pull cycle already in progress, skipping")
      return
    }

    isPulling = true
    defer { isPulling = false }

    let dueRepos = dataService.getDueTrackedRepos()
    guard !dueRepos.isEmpty else {
      logger.debug("No repos due for pull")
      return
    }

    logger.info("Pulling \(dueRepos.count) due repo(s)")

    for repo in dueRepos {
      let result = await pullRepo(repo)

      let entry = PullHistoryEntry(
        repoName: repo.name,
        remoteURL: repo.remoteURL,
        localPath: repo.localPath,
        result: result.description,
        success: !result.isError
      )
      pullHistory.insert(entry, at: 0)
      if pullHistory.count > 50 {
        pullHistory = Array(pullHistory.prefix(50))
      }

      // Update the SwiftData record
      dataService.updateTrackedRepoPullResult(
        repo,
        result: result.isError ? nil : result.description,
        error: result.isError ? result.description : nil
      )

      // Trigger re-index if the pull changed something and reindexing is enabled
      if case .updated = result, repo.reindexAfterPull {
        delegate?.repoPullScheduler(self, shouldReindex: repo.localPath)
      }
    }
  }

  /// Pull a single tracked repo regardless of its schedule.
  func pullRepoNow(remoteURL: String) async -> RepoPullResult? {
    guard let dataService else { return nil }
    guard let repo = dataService.getTrackedRemoteRepo(remoteURL: remoteURL) else { return nil }
    let result = await pullRepo(repo)

    dataService.updateTrackedRepoPullResult(
      repo,
      result: result.isError ? nil : result.description,
      error: result.isError ? result.description : nil
    )

    if case .updated = result, repo.reindexAfterPull {
      delegate?.repoPullScheduler(self, shouldReindex: repo.localPath)
    }

    return result
  }

  // MARK: - Git Operations

  private func pullRepo(_ repo: TrackedRemoteRepo) async -> RepoPullResult {
    let path = repo.localPath

    guard FileManager.default.fileExists(atPath: path) else {
      logger.error("Tracked repo path does not exist: \(path)")
      return .error("Path does not exist: \(path)")
    }

    // Get current HEAD before pull
    let beforeSHA = await gitHeadSHA(at: path)

    // Run git fetch + merge (safer than raw pull in case of worktrees)
    let fetchResult = await runGit(["fetch", repo.remoteName, repo.branch], at: path)
    guard fetchResult.exitCode == 0 else {
      let msg = "git fetch failed: \(fetchResult.stderr)"
      logger.error("\(msg)")
      return .error(msg)
    }

    let mergeResult = await runGit(
      ["merge", "--ff-only", "\(repo.remoteName)/\(repo.branch)"],
      at: path
    )

    if mergeResult.exitCode != 0 {
      // Check if it's just "already up to date"
      let combined = (mergeResult.stdout + mergeResult.stderr).lowercased()
      if combined.contains("already up to date") || combined.contains("already up-to-date") {
        logger.info("Repo \(repo.name) is up to date")
        return .upToDate
      }
      let msg = "git merge --ff-only failed: \(mergeResult.stderr)"
      logger.error("\(msg)")
      return .error(msg)
    }

    // Check if HEAD changed
    let afterSHA = await gitHeadSHA(at: path)
    if let before = beforeSHA, let after = afterSHA, before == after {
      logger.info("Repo \(repo.name) is up to date")
      return .upToDate
    }

    let newSHA = afterSHA ?? "unknown"
    logger.info("Repo \(repo.name) updated to \(newSHA)")
    return .updated(newSHA)
  }

  private func gitHeadSHA(at path: String) async -> String? {
    let result = await runGit(["rev-parse", "HEAD"], at: path)
    guard result.exitCode == 0 else { return nil }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private struct GitResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  private func runGit(_ arguments: [String], at path: String) async -> GitResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
      process.waitUntilExit()

      let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

      return GitResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
      )
    } catch {
      return GitResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
    }
  }
}

// MARK: - Pull History Entry

public struct PullHistoryEntry: Identifiable, Sendable {
  public let id = UUID()
  public let timestamp = Date()
  public let repoName: String
  public let remoteURL: String
  public let localPath: String
  public let result: String
  public let success: Bool
}
