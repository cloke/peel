//
//  SwiftDataModels.swift
//  KitchenSync
//
//  Created on 1/18/26.
//

import Foundation
import SwiftData
#if os(iOS)
import UIKit
#endif

// MARK: - SwiftData Models
// CloudKit-compatible: all properties have defaults, no unique constraints

// MARK: - Synced Models (sync to iCloud)

/// A git repository tracked by the app.
@Model
final class SyncedRepository {
  var id: UUID = UUID()
  var name: String = ""
  var remoteURL: String?
  var isFavorite: Bool = false
  var colorTag: String?
  var notes: String?
  var createdAt: Date = Date()
  var modifiedAt: Date = Date()
  
  init(name: String, remoteURL: String? = nil) {
    self.id = UUID()
    self.name = name
    self.remoteURL = remoteURL
    self.isFavorite = false
    self.createdAt = Date()
    self.modifiedAt = Date()
  }
  
  func touch() {
    modifiedAt = Date()
  }
}

/// A GitHub repository marked as favorite.
@Model
final class GitHubFavorite {
  var id: UUID = UUID()
  var githubRepoId: Int = 0
  var fullName: String = ""
  var ownerLogin: String = ""
  var repoName: String = ""
  var htmlURL: String?
  var addedAt: Date = Date()
  var notes: String?
  
  init(githubRepoId: Int, fullName: String, ownerLogin: String, repoName: String, htmlURL: String? = nil) {
    self.id = UUID()
    self.githubRepoId = githubRepoId
    self.fullName = fullName
    self.ownerLogin = ownerLogin
    self.repoName = repoName
    self.htmlURL = htmlURL
    self.addedAt = Date()
  }
}

/// A recently viewed pull request.
@Model
final class RecentPullRequest {
  var id: UUID = UUID()
  var githubPRId: Int = 0
  var prNumber: Int = 0
  var title: String = ""
  var repoFullName: String = ""
  var state: String = "unknown"
  var htmlURL: String?
  var viewedAt: Date = Date()
  
  init(githubPRId: Int, prNumber: Int, title: String, repoFullName: String, state: String, htmlURL: String? = nil) {
    self.id = UUID()
    self.githubPRId = githubPRId
    self.prNumber = prNumber
    self.title = title
    self.repoFullName = repoFullName
    self.state = state
    self.htmlURL = htmlURL
    self.viewedAt = Date()
  }
  
  func markViewed() {
    viewedAt = Date()
  }
}

// MARK: - Device-Local Models (NOT synced to iCloud)

/// Maps a SyncedRepository to its local path on THIS device.
@Model
final class LocalRepositoryPath {
  var id: UUID = UUID()
  var repositoryId: UUID = UUID()
  var localPath: String = ""
  var bookmarkData: Data?
  var lastAccessedAt: Date = Date()
  var isValid: Bool = true
  
  init(repositoryId: UUID, localPath: String, bookmarkData: Data? = nil) {
    self.id = UUID()
    self.repositoryId = repositoryId
    self.localPath = localPath
    self.bookmarkData = bookmarkData
    self.lastAccessedAt = Date()
    self.isValid = true
  }
  
  func markAccessed(validate: Bool = false) {
    lastAccessedAt = Date()
    if validate {
      isValid = FileManager.default.fileExists(atPath: localPath)
    }
  }
}

/// Tracks a worktree created through the app (manual, swarm task, or parallel run).
/// Device-local — not synced to iCloud (paths are machine-specific).
@Model
final class TrackedWorktree {
  var id: UUID = UUID()
  var repositoryId: UUID = UUID()
  var localPath: String = ""
  var branch: String = ""
  var source: String = "manual"   // See TrackedWorktree.Source constants
  var createdAt: Date = Date()
  var purpose: String?
  var linkedPRNumber: Int?
  var linkedPRRepo: String?

  // MARK: Swarm-specific fields (populated when source == "swarm")
  /// The swarm task UUID as a string. Empty string for non-swarm worktrees.
  var taskId: String = ""
  /// Lifecycle status of the swarm task. See TrackedWorktree.Status constants.
  var taskStatus: String = "active"
  /// Absolute path to the main repository (the worktree's parent). Empty for non-swarm.
  var mainRepoPath: String = ""
  /// First 200 chars of the task prompt, for display in the status panel.
  var taskPrompt: String?
  /// Worker device ID that executed the task.
  var workerId: String?
  /// Human-readable reason if taskStatus == "failed".
  var failureReason: String?
  /// When the task finished (committed, failed, or was cleaned up).
  var completedAt: Date?

  init(repositoryId: UUID, localPath: String, branch: String, source: String = "manual", purpose: String? = nil) {
    self.id = UUID()
    self.repositoryId = repositoryId
    self.localPath = localPath
    self.branch = branch
    self.source = source
    self.createdAt = Date()
    self.purpose = purpose
  }

  func linkToPR(number: Int, repo: String) {
    linkedPRNumber = number
    linkedPRRepo = repo
    if purpose == nil {
      purpose = "PR #\(number)"
    }
  }
}

extension TrackedWorktree {
  /// Constants for the `source` field.
  enum Source {
    static let manual = "manual"
    static let swarm = "swarm"
    static let parallel = "parallel"
  }

  /// Constants for the `taskStatus` field (swarm worktrees only).
  enum Status {
    /// Task is actively running; worktree should be on disk.
    static let active = "active"
    /// Task completed and changes were committed + pushed.
    static let committed = "committed"
    /// Task execution failed; changes may or may not be committed.
    static let failed = "failed"
    /// Worktree found in DB but missing from disk/git state — needs cleanup.
    static let orphaned = "orphaned"
    /// Worktree was cleanly removed after task completion.
    static let cleaned = "cleaned"
  }

  /// Convenience: true if this is a swarm-originated worktree.
  var isSwarmWorktree: Bool { source == Source.swarm }

  /// Convenience: true if the swarm task is still in-flight.
  var isActiveSwarmTask: Bool { isSwarmWorktree && taskStatus == Status.active }
}

/// Records a branch reservation made by BranchQueue, so state survives app restarts.
/// Device-local — not synced to iCloud.
@Model
final class SwarmBranchReservation {
  var id: UUID = UUID()
  var taskId: String = ""
  var branchName: String = ""
  var repoPath: String = ""
  var workerId: String = ""
  var createdAt: Date = Date()
  /// When false the reservation has been resolved (completed or released).
  var isInFlight: Bool = true
  /// Raw value of BranchQueue.CompletedBranch.CompletionStatus, or "" while in-flight.
  var completionStatus: String = ""

  init(taskId: UUID, branchName: String, repoPath: String, workerId: String) {
    self.id = UUID()
    self.taskId = taskId.uuidString
    self.branchName = branchName
    self.repoPath = repoPath
    self.workerId = workerId
    self.createdAt = Date()
  }
}

/// App settings for THIS device only.
@Model
final class DeviceSettings {
  var id: UUID = UUID()
  var deviceName: String = "Unknown"
  var currentTool: String = "github"
  var selectedRepositoryId: UUID?
  var sidebarWidth: Double?
  var lastUsedAt: Date = Date()
  
  // Worktree auto-cleanup settings
  var worktreeRetentionDays: Int = 7
  var worktreeMaxDiskGB: Double = 10.0
  var worktreeAutoCleanup: Bool = true
  
  @MainActor
  init() {
    self.id = UUID()
    #if os(macOS)
    self.deviceName = Host.current().localizedName ?? "Mac"
    #else
    self.deviceName = UIDevice.current.name
    #endif
    self.currentTool = "github"
    self.lastUsedAt = Date()
  }
  
  func touch() {
    lastUsedAt = Date()
  }
}

// MARK: - Policy Models (Device-Local)

/// Company scope for policy documents (device-local, not synced).
@Model
final class PolicyCompany {
  var id: UUID = UUID()
  var name: String = ""
  var slug: String = ""
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var lastIndexedAt: Date?

  init(name: String, slug: String) {
    self.id = UUID()
    self.name = name
    self.slug = slug
    self.createdAt = Date()
    self.updatedAt = Date()
  }

  func touch() {
    updatedAt = Date()
  }
}

/// A single imported policy document.
@Model
final class PolicyDocument {
  var id: UUID = UUID()
  var companyId: UUID = UUID()
  var title: String = ""
  var sourcePath: String = ""
  var markdownPath: String = ""
  var profile: String = "high"
  var importedAt: Date = Date()
  var lastIndexedAt: Date?
  var wordCount: Int = 0
  var headingCount: Int = 0
  var tableCount: Int = 0
  var listItemCount: Int = 0
  var lastValidatedAt: Date?
  var violationCount: Int = 0
  var isBaseline: Bool = false

  init(
    companyId: UUID,
    title: String,
    sourcePath: String,
    markdownPath: String,
    profile: String
  ) {
    self.id = UUID()
    self.companyId = companyId
    self.title = title
    self.sourcePath = sourcePath
    self.markdownPath = markdownPath
    self.profile = profile
    self.importedAt = Date()
  }
}

/// Validation rule for a company policy.
@Model
final class PolicyRule {
  var id: UUID = UUID()
  var companyId: UUID = UUID()
  var name: String = ""
  var detail: String = ""
  var severity: String = "warning"
  var pattern: String = ""
  var isEnabled: Bool = true
  var createdAt: Date = Date()

  init(companyId: UUID, name: String, detail: String = "", severity: String = "warning", pattern: String) {
    self.id = UUID()
    self.companyId = companyId
    self.name = name
    self.detail = detail
    self.severity = severity
    self.pattern = pattern
    self.isEnabled = true
    self.createdAt = Date()
  }
}

/// Validation violation for a document.
@Model
final class PolicyViolation {
  var id: UUID = UUID()
  var documentId: UUID = UUID()
  var ruleId: UUID = UUID()
  var lineNumber: Int = 0
  var snippet: String = ""
  var createdAt: Date = Date()

  init(documentId: UUID, ruleId: UUID, lineNumber: Int, snippet: String) {
    self.id = UUID()
    self.documentId = documentId
    self.ruleId = ruleId
    self.lineNumber = lineNumber
    self.snippet = snippet
    self.createdAt = Date()
  }
}

/// Preset for Docling conversions.
@Model
final class PolicyPreset {
  var id: UUID = UUID()
  var name: String = ""
  var profile: String = "high"
  var imagesScale: Double = 2.0
  var doOCR: Bool = true
  var doTables: Bool = true
  var doCode: Bool = true
  var doFormula: Bool = true
  var createdAt: Date = Date()

  init(
    name: String,
    profile: String,
    imagesScale: Double = 2.0,
    doOCR: Bool = true,
    doTables: Bool = true,
    doCode: Bool = true,
    doFormula: Bool = true
  ) {
    self.id = UUID()
    self.name = name
    self.profile = profile
    self.imagesScale = imagesScale
    self.doOCR = doOCR
    self.doTables = doTables
    self.doCode = doCode
    self.doFormula = doFormula
    self.createdAt = Date()
  }
}

/// Persisted MCP run record (device-local)
@Model
final class MCPRunRecord {
  var id: UUID = UUID()
  var chainId: String = ""
  var templateId: String = ""
  var templateName: String = ""
  var prompt: String = ""
  var workingDirectory: String?
  var implementerBranches: String = ""
  var implementerWorkspacePaths: String = ""
  var success: Bool = false
  var errorMessage: String?
  var noWorkReason: String?
  var mergeConflictsCount: Int = 0
  var mergeConflicts: String = ""
  var resultCount: Int = 0
  var validationStatus: String?
  var validationReasons: String?
  var createdAt: Date = Date()
  var screenshotPaths: String = ""

  init(
    chainId: String = "",
    templateId: String = "",
    templateName: String,
    prompt: String,
    workingDirectory: String? = nil,
    implementerBranches: String = "",
    implementerWorkspacePaths: String = "",
    screenshotPaths: String = "",
    success: Bool,
    errorMessage: String? = nil,
    noWorkReason: String? = nil,
    mergeConflictsCount: Int = 0,
    mergeConflicts: String = "",
    resultCount: Int = 0,
    validationStatus: String? = nil,
    validationReasons: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = UUID()
    self.chainId = chainId
    self.templateId = templateId
    self.templateName = templateName
    self.prompt = prompt
    self.workingDirectory = workingDirectory
    self.implementerBranches = implementerBranches
    self.implementerWorkspacePaths = implementerWorkspacePaths
    self.success = success
    self.errorMessage = errorMessage
    self.noWorkReason = noWorkReason
    self.mergeConflictsCount = mergeConflictsCount
    self.mergeConflicts = mergeConflicts
    self.resultCount = resultCount
    self.validationStatus = validationStatus
    self.validationReasons = validationReasons
    self.createdAt = createdAt
    self.screenshotPaths = screenshotPaths
  }
}

/// Persisted MCP run results (device-local)
@Model
final class MCPRunResultRecord {
  var id: UUID = UUID()
  var chainId: String = ""
  var agentId: String = ""
  var agentName: String = ""
  var model: String = ""
  var prompt: String = ""
  var output: String = ""
  var premiumCost: Double = 0
  var reviewVerdict: String?
  var createdAt: Date = Date()

  init(
    chainId: String = "",
    agentId: String,
    agentName: String,
    model: String,
    prompt: String,
    output: String,
    premiumCost: Double = 0,
    reviewVerdict: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = UUID()
    self.chainId = chainId
    self.agentId = agentId
    self.agentName = agentName
    self.model = model
    self.prompt = prompt
    self.output = output
    self.premiumCost = premiumCost
    self.reviewVerdict = reviewVerdict
    self.createdAt = createdAt
  }
}

/// Snapshot of a parallel worktree run (device-local)
@Model
final class ParallelRunSnapshot {
  var id: UUID = UUID()
  var runId: String = ""
  var name: String = ""
  var projectPath: String = ""
  var baseBranch: String = ""
  var targetBranch: String?
  var templateName: String?
  var status: String = ""
  var progress: Double = 0
  var executionCount: Int = 0
  var pendingReviewCount: Int = 0
  var readyToMergeCount: Int = 0
  var mergedCount: Int = 0
  var rejectedCount: Int = 0
  var failedCount: Int = 0
  var hungCount: Int = 0
  var requireReviewGate: Bool = true
  var autoMergeOnApproval: Bool = false
  var operatorGuidanceCount: Int = 0
  var executionsJSON: String = ""
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var lastUpdatedAt: Date?

  init(
    runId: String,
    name: String,
    projectPath: String,
    baseBranch: String,
    targetBranch: String? = nil,
    templateName: String? = nil,
    status: String,
    progress: Double,
    executionCount: Int,
    pendingReviewCount: Int,
    readyToMergeCount: Int,
    mergedCount: Int,
    rejectedCount: Int,
    failedCount: Int,
    hungCount: Int,
    requireReviewGate: Bool,
    autoMergeOnApproval: Bool,
    operatorGuidanceCount: Int,
    executionsJSON: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    lastUpdatedAt: Date? = nil
  ) {
    self.id = UUID()
    self.runId = runId
    self.name = name
    self.projectPath = projectPath
    self.baseBranch = baseBranch
    self.targetBranch = targetBranch
    self.templateName = templateName
    self.status = status
    self.progress = progress
    self.executionCount = executionCount
    self.pendingReviewCount = pendingReviewCount
    self.readyToMergeCount = readyToMergeCount
    self.mergedCount = mergedCount
    self.rejectedCount = rejectedCount
    self.failedCount = failedCount
    self.hungCount = hungCount
    self.requireReviewGate = requireReviewGate
    self.autoMergeOnApproval = autoMergeOnApproval
    self.operatorGuidanceCount = operatorGuidanceCount
    self.executionsJSON = executionsJSON
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastUpdatedAt = lastUpdatedAt
  }
}

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
