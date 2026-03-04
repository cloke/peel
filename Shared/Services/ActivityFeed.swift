//
//  ActivityFeed.swift
//  Peel
//
//  Aggregates timeline events from MCPRunRecord, pull history, chain state,
//  and worktree lifecycle into a unified [ActivityItem] stream.
//
//  Like RepositoryAggregator, this is a computed snapshot — call `rebuild()`
//  whenever underlying data changes.
//

import Foundation
import OSLog
import SwiftData

@MainActor
@Observable
final class ActivityFeed {

  // MARK: - Output

  /// All activity items, newest first.
  private(set) var items: [ActivityItem] = []

  /// Items for a specific repository (by normalized URL).
  func items(for normalizedURL: String) -> [ActivityItem] {
    items.filter { $0.repoNormalizedURL == normalizedURL }
  }

  /// Only error items, newest first.
  var errorItems: [ActivityItem] {
    items.filter(\.isError)
  }

  // MARK: - Dependencies

  weak var dataService: DataService?
  weak var agentManager: AgentManager?
  weak var pullScheduler: RepoPullScheduler?

  // MARK: - Config

  /// Maximum number of items to keep (prevents unbounded growth).
  var maxItems = 200

  // MARK: - Private

  private let logger = Logger(subsystem: "com.peel.services", category: "ActivityFeed")

  // MARK: - Rebuild

  /// Rebuild the activity feed from all data sources.
  func rebuild() {
    guard let dataService else {
      logger.warning("Cannot rebuild: dataService not set")
      return
    }

    var result: [ActivityItem] = []

    // 1. Chain run history (MCPRunRecord)
    result.append(contentsOf: buildChainRunItems(dataService: dataService))

    // 2. Pull history
    result.append(contentsOf: buildPullItems())

    // 3. Active/recent chain state changes
    result.append(contentsOf: buildChainStateItems())

    // 4. Worktree lifecycle
    result.append(contentsOf: buildWorktreeItems(dataService: dataService))

    // 5. Recent PRs
    result.append(contentsOf: buildPRItems(dataService: dataService))

    // Sort newest first, cap
    result.sort { $0.timestamp > $1.timestamp }
    if result.count > maxItems {
      result = Array(result.prefix(maxItems))
    }

    items = result
    logger.info("Rebuilt activity feed: \(result.count) items")
  }

  // MARK: - Data Source Builders

  private func buildChainRunItems(dataService: DataService) -> [ActivityItem] {
    let descriptor = FetchDescriptor<MCPRunRecord>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    let records = (try? dataService.modelContext.fetch(descriptor)) ?? []

    return records.prefix(50).map { record in
      let repoURL = record.workingDirectory.flatMap {
        RepoRegistry.shared.getCachedRemoteURL(for: resolveRepoPath(from: $0))
      }

      return ActivityItem(
        id: record.id,
        timestamp: record.createdAt,
        kind: .chainCompleted(chainId: UUID(uuidString: record.chainId) ?? record.id, success: record.success),
        repoNormalizedURL: repoURL,
        repoDisplayName: record.templateName,
        title: record.success
          ? "Chain completed: \(record.templateName)"
          : "Chain failed: \(record.templateName)",
        subtitle: record.prompt.prefix(120).isEmpty ? nil : String(record.prompt.prefix(120)),
        isError: !record.success
      )
    }
  }

  private func buildPullItems() -> [ActivityItem] {
    let history = pullScheduler?.pullHistory ?? []

    return history.prefix(30).map { entry in
      let repoURL = RepoRegistry.shared.normalizeRemoteURL(entry.remoteURL)

      return ActivityItem(
        id: entry.id,
        timestamp: entry.timestamp,
        kind: .pullCompleted(success: entry.success),
        repoNormalizedURL: repoURL,
        repoDisplayName: entry.repoName,
        title: entry.success
          ? "Pulled \(entry.repoName): \(entry.result)"
          : "Pull failed: \(entry.repoName)",
        subtitle: entry.success ? nil : entry.result,
        isError: !entry.success
      )
    }
  }

  private func buildChainStateItems() -> [ActivityItem] {
    let chains = agentManager?.chains ?? []
    var items: [ActivityItem] = []

    for chain in chains {
      let repoURL = chain.workingDirectory.flatMap {
        RepoRegistry.shared.getCachedRemoteURL(for: resolveRepoPath(from: $0))
      }

      // Represent chain start
      if let started = chain.runStartTime {
        items.append(ActivityItem(
          id: UUID(uuidString: "\(chain.id.uuidString)-start".data(using: .utf8)!.base64EncodedString()) ?? UUID(),
          timestamp: started,
          kind: .chainStarted(chainId: chain.id),
          repoNormalizedURL: repoURL,
          repoDisplayName: chain.name,
          title: "Chain started: \(chain.name)",
          subtitle: chain.initialPrompt.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) },
          isError: false
        ))
      }

      // If terminal, represent completion
      if chain.state.isTerminal, let completed = chain.runStartTime {
        let success = chain.state.isComplete
        items.append(ActivityItem(
          id: UUID(uuidString: "\(chain.id.uuidString)-end".data(using: .utf8)!.base64EncodedString()) ?? UUID(),
          timestamp: completed,
          kind: .chainCompleted(chainId: chain.id, success: success),
          repoNormalizedURL: repoURL,
          repoDisplayName: chain.name,
          title: success
            ? "Chain completed: \(chain.name)"
            : "Chain failed: \(chain.name)",
          subtitle: nil,
          isError: !success
        ))
      }
    }

    return items
  }

  private func buildWorktreeItems(dataService: DataService) -> [ActivityItem] {
    let worktrees = dataService.getTrackedWorktrees()
    var items: [ActivityItem] = []

    for wt in worktrees.prefix(30) {
      // Find repo URL
      let repoURL: String? = {
        if !wt.mainRepoPath.isEmpty {
          return RepoRegistry.shared.getCachedRemoteURL(for: wt.mainRepoPath)
        }
        return nil
      }()

      let isClean = wt.taskStatus == TrackedWorktree.Status.cleaned

      items.append(ActivityItem(
        id: wt.id,
        timestamp: isClean ? (wt.completedAt ?? wt.createdAt) : wt.createdAt,
        kind: isClean
          ? .worktreeCleaned(worktreeId: wt.id)
          : .worktreeCreated(worktreeId: wt.id),
        repoNormalizedURL: repoURL,
        repoDisplayName: wt.branch,
        title: isClean
          ? "Worktree cleaned: \(wt.branch)"
          : "Worktree created: \(wt.branch)",
        subtitle: wt.purpose,
        isError: wt.taskStatus == TrackedWorktree.Status.failed
      ))
    }

    return items
  }

  private func buildPRItems(dataService: DataService) -> [ActivityItem] {
    let prs = dataService.getRecentPRs(limit: 20)

    return prs.map { pr in
      let ownerRepo = pr.repoFullName.lowercased()
      let repoURL = ownerRepo.isEmpty ? nil : "github.com/\(ownerRepo)"

      return ActivityItem(
        id: pr.id,
        timestamp: pr.viewedAt,
        kind: .prActivity(prNumber: pr.prNumber),
        repoNormalizedURL: repoURL,
        repoDisplayName: pr.repoFullName,
        title: "PR #\(pr.prNumber): \(pr.title)",
        subtitle: pr.state,
        isError: false
      )
    }
  }

  // MARK: - Helpers

  private func resolveRepoPath(from workDir: String) -> String {
    if let range = workDir.range(of: "/.agent-workspaces/") {
      return String(workDir[workDir.startIndex..<range.lowerBound])
    }
    return workDir
  }
}
