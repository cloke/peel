//
//  PRReviewQueue.swift
//  Peel
//
//  Persistent queue managing PR review lifecycle.
//  Tracks PRs through review → fix → push stages.
//  State persists to SwiftData so closing a window doesn't lose progress.
//

import Foundation
import Github
import SwiftData
import os

@MainActor
@Observable
final class PRReviewQueue {

  private let logger = Logger(subsystem: "com.peel.review", category: "PRReviewQueue")

  /// SwiftData context for persistence. Set after app launch.
  var modelContext: ModelContext? {
    didSet {
      if modelContext != nil {
        loadFromPersistence()
      }
    }
  }

  /// In-memory cache of active items, kept in sync with SwiftData.
  private(set) var items: [PRReviewQueueItem] = []

  // MARK: - Queue Operations

  /// Enqueue a new PR for review. Returns the queue item.
  @discardableResult
  func enqueue(
    repoOwner: String,
    repoName: String,
    prNumber: Int,
    prTitle: String,
    headRef: String,
    htmlURL: String = ""
  ) -> PRReviewQueueItem {
    // Check for existing item for same PR
    if let existing = find(repoOwner: repoOwner, repoName: repoName, prNumber: prNumber) {
      logger.info("PR #\(prNumber) already in queue (phase: \(existing.phase))")
      return existing
    }

    let item = PRReviewQueueItem(
      repoOwner: repoOwner,
      repoName: repoName,
      prNumber: prNumber,
      prTitle: prTitle,
      headRef: headRef,
      htmlURL: htmlURL
    )
    items.append(item)
    persist(item)
    logger.info("Enqueued PR #\(prNumber) for review")
    return item
  }

  /// Find an existing queue item for a PR.
  func find(repoOwner: String, repoName: String, prNumber: Int) -> PRReviewQueueItem? {
    items.first {
      $0.repoOwner == repoOwner && $0.repoName == repoName && $0.prNumber == prNumber
    }
  }

  /// Find by queue item ID.
  func find(id: UUID) -> PRReviewQueueItem? {
    items.first { $0.id == id }
  }

  /// Find by chain ID (review or fix).
  func findByChainId(_ chainId: String) -> PRReviewQueueItem? {
    items.first { $0.reviewChainId == chainId || $0.fixChainId == chainId }
  }

  // MARK: - State Transitions

  func markReviewing(_ item: PRReviewQueueItem, chainId: String, worktreePath: String, model: String = "") {
    item.phase = PRReviewPhase.reviewing
    item.reviewChainId = chainId
    item.worktreePath = worktreePath
    item.reviewModel = model
    item.reviewStartedAt = Date()
    item.lastUpdatedAt = Date()
    item.lastError = nil
    save()
  }

  func markReviewed(_ item: PRReviewQueueItem, output: String, verdict: String) {
    item.phase = verdict == "approved" ? PRReviewPhase.approved : PRReviewPhase.reviewed
    item.reviewOutput = output
    item.reviewVerdict = verdict
    item.reviewCompletedAt = Date()
    item.lastUpdatedAt = Date()
    item.lastError = nil
    save()
  }

  func markNeedsFix(_ item: PRReviewQueueItem) {
    item.phase = PRReviewPhase.needsFix
    item.lastUpdatedAt = Date()
    save()
  }

  func markFixing(_ item: PRReviewQueueItem, chainId: String, model: String = "") {
    item.phase = PRReviewPhase.fixing
    item.fixChainId = chainId
    item.fixModel = model
    item.fixStartedAt = Date()
    item.lastUpdatedAt = Date()
    item.lastError = nil
    save()
  }

  func markFixed(_ item: PRReviewQueueItem) {
    item.phase = PRReviewPhase.fixed
    item.fixCompletedAt = Date()
    item.lastUpdatedAt = Date()
    item.lastError = nil
    save()
  }

  func markReadyToPush(_ item: PRReviewQueueItem) {
    item.phase = PRReviewPhase.readyToPush
    item.lastUpdatedAt = Date()
    save()
  }

  func markPushing(_ item: PRReviewQueueItem) {
    item.phase = PRReviewPhase.pushing
    item.lastUpdatedAt = Date()
    save()
  }

  func markPushed(_ item: PRReviewQueueItem, result: String) {
    item.phase = PRReviewPhase.pushed
    item.pushResult = result
    item.pushedAt = Date()
    item.lastUpdatedAt = Date()
    item.lastError = nil
    save()
  }

  func markFailed(_ item: PRReviewQueueItem, error: String) {
    item.phase = PRReviewPhase.failed
    item.lastError = error
    item.lastUpdatedAt = Date()
    save()
  }

  /// Reset a failed item back to its previous actionable state.
  func retry(_ item: PRReviewQueueItem) {
    item.lastError = nil
    item.lastUpdatedAt = Date()
    // Determine which phase to retry from
    if !item.fixChainId.isEmpty {
      item.phase = PRReviewPhase.needsFix
      item.fixChainId = ""
    } else if !item.reviewChainId.isEmpty {
      item.phase = PRReviewPhase.pending
      item.reviewChainId = ""
      item.reviewOutput = ""
      item.reviewVerdict = ""
    } else {
      item.phase = PRReviewPhase.pending
    }
    save()
  }

  /// Remove an item from the queue entirely.
  func remove(_ item: PRReviewQueueItem) {
    if let idx = items.firstIndex(where: { $0.id == item.id }) {
      items.remove(at: idx)
    }
    modelContext?.delete(item)
    save()
  }

  /// Remove completed/pushed items older than the given interval.
  func pruneOlderThan(_ interval: TimeInterval) {
    let cutoff = Date().addingTimeInterval(-interval)
    let terminalPhases: Set<String> = [PRReviewPhase.pushed, PRReviewPhase.approved]
    let toRemove = items.filter { terminalPhases.contains($0.phase) && $0.lastUpdatedAt < cutoff }
    for item in toRemove {
      modelContext?.delete(item)
    }
    items.removeAll { item in toRemove.contains { $0.id == item.id } }
    save()
  }

  // MARK: - Filtered Views

  var activeItems: [PRReviewQueueItem] {
    let terminalPhases: Set<String> = [PRReviewPhase.pushed, PRReviewPhase.approved]
    return items.filter { !terminalPhases.contains($0.phase) }
  }

  var completedItems: [PRReviewQueueItem] {
    let terminalPhases: Set<String> = [PRReviewPhase.pushed, PRReviewPhase.approved]
    return items.filter { terminalPhases.contains($0.phase) }
  }

  // MARK: - Summary for MCP

  func summary() -> [[String: Any]] {
    items.map { item in
      var dict: [String: Any] = [
        "id": item.id.uuidString,
        "repo": "\(item.repoOwner)/\(item.repoName)",
        "prNumber": item.prNumber,
        "prTitle": item.prTitle,
        "phase": item.phase,
        "phaseDisplay": PRReviewPhase.displayName[item.phase] ?? item.phase,
        "createdAt": ISO8601DateFormatter().string(from: item.createdAt),
        "lastUpdatedAt": ISO8601DateFormatter().string(from: item.lastUpdatedAt),
      ]
      if !item.reviewVerdict.isEmpty { dict["reviewVerdict"] = item.reviewVerdict }
      if !item.reviewChainId.isEmpty { dict["reviewChainId"] = item.reviewChainId }
      if !item.fixChainId.isEmpty { dict["fixChainId"] = item.fixChainId }
      if !item.worktreePath.isEmpty { dict["worktreePath"] = item.worktreePath }
      if let error = item.lastError { dict["lastError"] = error }
      return dict
    }
  }

  // MARK: - Persistence

  private func persist(_ item: PRReviewQueueItem) {
    modelContext?.insert(item)
    save()
  }

  func save() {
    do {
      try modelContext?.save()
    } catch {
      logger.error("Failed to save PR review queue: \(error.localizedDescription)")
    }
  }

  private func loadFromPersistence() {
    guard let ctx = modelContext else { return }
    let descriptor = FetchDescriptor<PRReviewQueueItem>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    do {
      let persisted = try ctx.fetch(descriptor)
      // Merge: keep any in-memory items that aren't yet persisted (created before
      // modelContext was set) and persist them now, then combine with DB results.
      let persistedIDs = Set(persisted.map(\.id))
      let orphaned = items.filter { !persistedIDs.contains($0.id) }
      for item in orphaned {
        ctx.insert(item)
      }
      if !orphaned.isEmpty {
        try ctx.save()
        logger.info("Persisted \(orphaned.count) orphaned in-memory items")
      }
      items = persisted + orphaned
      logger.info("Loaded \(self.items.count) PR review queue items from persistence")
      recoverStuckItems()
      startReconciliationTimer()
    } catch {
      logger.error("Failed to load PR review queue: \(error.localizedDescription)")
    }
  }

  /// Reset items stuck in transient phases (reviewing/fixing) back to
  /// actionable states. These phases require a live background monitor
  /// task that does not survive app restart.
  private func recoverStuckItems() {
    let inFlightPhases: Set<String> = [
      PRReviewPhase.reviewing, PRReviewPhase.fixing, PRReviewPhase.pushing
    ]
    var recovered = 0
    for item in items where inFlightPhases.contains(item.phase) {
      let oldPhase = item.phase
      switch item.phase {
      case PRReviewPhase.reviewing:
        item.phase = PRReviewPhase.pending
        item.reviewChainId = ""
        item.lastError = "Recovery: review was interrupted (app restarted)"
      case PRReviewPhase.fixing:
        item.phase = PRReviewPhase.needsFix
        item.fixChainId = ""
        item.lastError = "Recovery: fix was interrupted (app restarted)"
      case PRReviewPhase.pushing:
        item.phase = PRReviewPhase.readyToPush
        item.lastError = "Recovery: push was interrupted (app restarted)"
      default:
        continue
      }
      item.lastUpdatedAt = Date()
      recovered += 1
      logger.warning("Recovered stuck item PR #\(item.prNumber): \(oldPhase) → \(item.phase)")
    }
    if recovered > 0 {
      save()
      logger.info("Recovered \(recovered) stuck PR review queue item(s)")
    }
  }

  // MARK: - GitHub Reconciliation

  private var reconciliationTask: Task<Void, Never>?

  /// Start a background timer that periodically checks GitHub for PR state changes.
  private func startReconciliationTimer() {
    reconciliationTask?.cancel()
    reconciliationTask = Task { [weak self] in
      // Initial reconciliation after a short delay
      try? await Task.sleep(for: .seconds(10))
      while !Task.isCancelled {
        self?.recoverStuckReviews()
        await self?.reconcileWithGitHub()
        // Prune terminal items older than 7 days from SwiftData/CloudKit
        self?.pruneOlderThan(7 * 24 * 60 * 60)
        try? await Task.sleep(for: .seconds(300)) // Every 5 minutes
      }
    }
  }

  /// Recover items stuck in "reviewing" phase for too long (background monitor died).
  /// The background monitor has a 900s (15 min) timeout, so if we're still "reviewing"
  /// after 20 minutes, the monitor task is dead and we should fail the item.
  private func recoverStuckReviews() {
    let stuckThreshold: TimeInterval = 20 * 60 // 20 minutes
    var recovered = 0
    for item in items where item.phase == PRReviewPhase.reviewing {
      guard let startedAt = item.reviewStartedAt,
            Date().timeIntervalSince(startedAt) > stuckThreshold else { continue }
      let minutes = Int(Date().timeIntervalSince(startedAt) / 60)
      item.phase = PRReviewPhase.pending
      item.reviewChainId = ""
      item.lastError = "Recovery: review stuck for \(minutes)m (background monitor lost)"
      item.lastUpdatedAt = Date()
      recovered += 1
      logger.warning("Recovered stuck reviewing item PR #\(item.prNumber) after \(minutes)m")
    }
    if recovered > 0 {
      save()
      logger.info("Recovered \(recovered) stuck reviewing item(s)")
    }
  }

  /// Check GitHub API for each non-terminal queue item and update phase if the PR
  /// has been merged or closed since we last checked.
  func reconcileWithGitHub() async {
    let terminalPhases: Set<String> = [PRReviewPhase.pushed, PRReviewPhase.approved]
    let toCheck = items.filter { !terminalPhases.contains($0.phase) }
    guard !toCheck.isEmpty else { return }

    logger.info("Reconciling \(toCheck.count) queue items with GitHub")
    var changed = false

    for item in toCheck {
      do {
        let pr = try await Github.pullRequest(
          owner: item.repoOwner, repository: item.repoName, number: item.prNumber
        )

        if pr.merged_at != nil {
          // PR was merged — mark as pushed
          item.phase = PRReviewPhase.pushed
          item.pushResult = "Merged on GitHub"
          item.pushedAt = Date()
          item.lastUpdatedAt = Date()
          item.lastError = nil
          changed = true
          logger.info("PR #\(item.prNumber) was merged — updated to pushed")
        } else if pr.state == "closed" {
          // PR was closed without merge — remove from queue
          items.removeAll { $0.id == item.id }
          modelContext?.delete(item)
          changed = true
          logger.info("PR #\(item.prNumber) was closed — removed from queue")
        } else if let title = pr.title, title != item.prTitle {
          // Title updated on GitHub
          item.prTitle = title
          item.lastUpdatedAt = Date()
          changed = true
        }
      } catch {
        // Don't fail the whole reconciliation for one PR
        logger.debug("Failed to check PR #\(item.prNumber): \(error.localizedDescription)")
      }
    }

    if changed {
      save()
    }
  }
}
