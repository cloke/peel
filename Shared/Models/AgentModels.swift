//
//  AgentModels.swift
//  Peel
//
//  Agent guidance and CI feedback SwiftData models (device-local).
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData

/// Repo-scoped guidance skill (device-local)
@Model
final class RepoGuidanceSkill {
  var id: UUID = UUID()
  var repoPath: String = ""
  var repoRemoteURL: String = ""
  var repoName: String = ""
  var title: String = ""
  var body: String = ""
  var source: String = "manual"
  var tags: String = ""
  var priority: Int = 0
  var isActive: Bool = true
  var appliedCount: Int = 0
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var lastAppliedAt: Date?

  init(
    repoPath: String,
    repoRemoteURL: String = "",
    repoName: String = "",
    title: String,
    body: String,
    source: String = "manual",
    tags: String = "",
    priority: Int = 0,
    isActive: Bool = true,
    appliedCount: Int = 0,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    lastAppliedAt: Date? = nil
  ) {
    self.id = UUID()
    self.repoPath = repoPath
    self.repoRemoteURL = repoRemoteURL
    self.repoName = repoName
    self.title = title
    self.body = body
    self.source = source
    self.tags = tags
    self.priority = priority
    self.isActive = isActive
    self.appliedCount = appliedCount
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastAppliedAt = lastAppliedAt
  }
}

// MARK: - CI Failure Feedback (device-local)

/// Records CI failures from MCP-generated PRs for feedback loop
@Model
final class CIFailureRecord {
  var id: UUID = UUID()
  var mcpRunId: UUID = UUID()
  var repoPath: String = ""
  var prNumber: Int = 0
  var prBranch: String = ""
  var checkName: String = ""
  var failureType: String = ""  // "build", "test", "lint"
  var failureSummary: String = ""
  var failureDetails: String = ""
  var normalizedPattern: String = ""  // Deduplicated pattern key
  var guidanceGenerated: String?
  var occurrenceCount: Int = 1
  var isResolved: Bool = false
  var isIndexedInRAG: Bool = false
  var createdAt: Date = Date()
  var lastSeenAt: Date = Date()

  init(
    mcpRunId: UUID,
    repoPath: String,
    prNumber: Int,
    prBranch: String,
    checkName: String,
    failureType: String,
    failureSummary: String,
    failureDetails: String = "",
    normalizedPattern: String = ""
  ) {
    self.id = UUID()
    self.mcpRunId = mcpRunId
    self.repoPath = repoPath
    self.prNumber = prNumber
    self.prBranch = prBranch
    self.checkName = checkName
    self.failureType = failureType
    self.failureSummary = failureSummary
    self.failureDetails = failureDetails
    self.normalizedPattern = normalizedPattern
    self.occurrenceCount = 1
    self.isResolved = false
    self.isIndexedInRAG = false
    self.createdAt = Date()
    self.lastSeenAt = Date()
  }

  /// Increment occurrence count and update last seen
  func recordOccurrence() {
    occurrenceCount += 1
    lastSeenAt = Date()
  }

  /// Generate guidance snippet from this failure
  func generateGuidance() -> String? {
    guard !failureSummary.isEmpty else { return nil }

    let guidance = """
    ## CI Failure Pattern: \(checkName)
    
    **Type:** \(failureType)
    **Pattern:** \(normalizedPattern.isEmpty ? "N/A" : normalizedPattern)
    **Occurrences:** \(occurrenceCount)
    
    ### Summary
    \(failureSummary)
    
    ### Recommended Actions
    - Review the failure details and fix the underlying issue
    - Ensure tests pass locally before pushing
    - Consider adding this pattern to prompt rules if recurring
    """

    guidanceGenerated = guidance
    return guidance
  }
}

// MARK: - Chain Learnings (auto-captured institutional memory)

/// Auto-captured learning from chain runs, scoped to a repository.
/// Injected into future chain prompts so agents learn from past mistakes and successes.
@Model
final class ChainLearning {
  var id: UUID = UUID()
  var repoPath: String = ""
  var repoRemoteURL: String = ""
  var category: String = ""        // "mistake", "pattern", "tool-usage", "build-fix", "process"
  var summary: String = ""         // One-line: "Always run `npm install` before build gate"
  var detail: String = ""          // Full context
  var source: String = "auto"      // "auto" (post-chain extraction) or "manual"
  var chainTemplateName: String = ""
  var confidenceScore: Double = 0.5
  var appliedCount: Int = 0
  var wasHelpful: Int = 0
  var wasUnhelpful: Int = 0
  var isActive: Bool = true
  var createdAt: Date = Date()
  var updatedAt: Date = Date()

  init(
    repoPath: String,
    repoRemoteURL: String = "",
    category: String,
    summary: String,
    detail: String = "",
    source: String = "auto",
    chainTemplateName: String = "",
    confidenceScore: Double = 0.5
  ) {
    self.id = UUID()
    self.repoPath = repoPath
    self.repoRemoteURL = repoRemoteURL
    self.category = category
    self.summary = summary
    self.detail = detail
    self.source = source
    self.chainTemplateName = chainTemplateName
    self.confidenceScore = confidenceScore
    self.appliedCount = 0
    self.wasHelpful = 0
    self.wasUnhelpful = 0
    self.isActive = true
    self.createdAt = Date()
    self.updatedAt = Date()
  }
}
