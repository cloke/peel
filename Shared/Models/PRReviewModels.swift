//
//  PRReviewModels.swift
//  Peel
//
//  Persistent PR review queue SwiftData models.
//  Tracks PRs through the review → fix → push lifecycle so state
//  survives window/sheet dismissal and app restarts.
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData

// MARK: - PR Review Queue Item

/// Persistent record of a PR undergoing agent review.
/// Tracks the full lifecycle: pending → reviewing → reviewed → fixing → fixed → pushing → pushed.
@Model
final class PRReviewQueueItem {
  var id: UUID = UUID()

  // PR identity
  var repoOwner: String = ""
  var repoName: String = ""
  var prNumber: Int = 0
  var prTitle: String = ""
  var headRef: String = ""
  var htmlURL: String = ""

  // Lifecycle state (see PRReviewPhase constants)
  var phase: String = "pending"

  // Review chain tracking
  var reviewChainId: String = ""
  var reviewOutput: String = ""
  var reviewVerdict: String = ""  // "approved", "needsChanges", "rejected", ""
  var reviewModel: String = ""

  // Fix chain tracking
  var fixChainId: String = ""
  var fixModel: String = ""

  // Worktree info
  var worktreePath: String = ""

  // Push tracking
  var pushBranch: String = ""
  var pushResult: String = ""

  // Timestamps
  var createdAt: Date = Date()
  var reviewStartedAt: Date?
  var reviewCompletedAt: Date?
  var fixStartedAt: Date?
  var fixCompletedAt: Date?
  var pushedAt: Date?
  var lastUpdatedAt: Date = Date()

  // Error tracking
  var lastError: String?

  init(
    repoOwner: String,
    repoName: String,
    prNumber: Int,
    prTitle: String,
    headRef: String,
    htmlURL: String = ""
  ) {
    self.id = UUID()
    self.repoOwner = repoOwner
    self.repoName = repoName
    self.prNumber = prNumber
    self.prTitle = prTitle
    self.headRef = headRef
    self.htmlURL = htmlURL
    self.phase = PRReviewPhase.pending
    self.createdAt = Date()
    self.lastUpdatedAt = Date()
  }
}

// MARK: - Phase Constants

/// String constants for PRReviewQueueItem.phase.
/// Using strings for CloudKit compatibility (no enum stored properties).
enum PRReviewPhase {
  static let pending = "pending"
  static let reviewing = "reviewing"
  static let reviewed = "reviewed"
  static let needsFix = "needsFix"
  static let fixing = "fixing"
  static let fixed = "fixed"
  static let readyToPush = "readyToPush"
  static let pushing = "pushing"
  static let pushed = "pushed"
  static let approved = "approved"
  static let failed = "failed"

  static var displayName: [String: String] {
    [
      pending: "Pending Review",
      reviewing: "Reviewing",
      reviewed: "Reviewed",
      needsFix: "Needs Fix",
      fixing: "Fixing",
      fixed: "Fixed",
      readyToPush: "Ready to Push",
      pushing: "Pushing",
      pushed: "Pushed",
      approved: "Approved",
      failed: "Failed",
    ]
  }

  static var systemImage: [String: String] {
    [
      pending: "clock",
      reviewing: "sparkles",
      reviewed: "doc.text.magnifyingglass",
      needsFix: "exclamationmark.triangle",
      fixing: "hammer",
      fixed: "checkmark.circle",
      readyToPush: "arrow.up.circle",
      pushing: "arrow.up.circle.fill",
      pushed: "checkmark.seal.fill",
      approved: "hand.thumbsup.fill",
      failed: "xmark.circle.fill",
    ]
  }

  static var color: [String: String] {
    [
      pending: "secondary",
      reviewing: "purple",
      reviewed: "blue",
      needsFix: "orange",
      fixing: "yellow",
      fixed: "green",
      readyToPush: "blue",
      pushing: "blue",
      pushed: "green",
      approved: "green",
      failed: "red",
    ]
  }
}
