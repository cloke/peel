//
//  MCPRunModels.swift
//  Peel
//
//  MCP run record and parallel run SwiftData models (device-local).
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData

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
    id: UUID = UUID(),
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
    self.id = id
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
    status: String = "",
    progress: Double = 0,
    executionCount: Int = 0,
    pendingReviewCount: Int = 0,
    readyToMergeCount: Int = 0,
    mergedCount: Int = 0,
    rejectedCount: Int = 0,
    failedCount: Int = 0,
    hungCount: Int = 0,
    requireReviewGate: Bool = true,
    autoMergeOnApproval: Bool = false,
    operatorGuidanceCount: Int = 0,
    executionsJSON: String = "",
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
