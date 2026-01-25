//
//  MCPDataTypes.swift
//  MCPCore
//
//  Data transfer objects for MCP run records.
//

import Foundation

// MARK: - MCP Run Record DTO

/// Data transfer object for MCP run records (decoupled from SwiftData)
public struct MCPRunRecordDTO: Identifiable, Codable, Sendable {
  public let id: UUID
  public let chainId: String
  public let templateId: String
  public let templateName: String
  public let prompt: String
  public let workingDirectory: String?
  public let implementerBranches: [String]
  public let implementerWorkspacePaths: [String]
  public let success: Bool
  public let errorMessage: String?
  public let noWorkReason: String?
  public let mergeConflictsCount: Int
  public let mergeConflicts: [String]
  public let resultCount: Int
  public let validationStatus: String?
  public let validationReasons: [String]?
  public let createdAt: Date
  public let screenshotPaths: [String]

  public init(
    id: UUID = UUID(),
    chainId: String = "",
    templateId: String = "",
    templateName: String,
    prompt: String,
    workingDirectory: String? = nil,
    implementerBranches: [String] = [],
    implementerWorkspacePaths: [String] = [],
    success: Bool,
    errorMessage: String? = nil,
    noWorkReason: String? = nil,
    mergeConflictsCount: Int = 0,
    mergeConflicts: [String] = [],
    resultCount: Int = 0,
    validationStatus: String? = nil,
    validationReasons: [String]? = nil,
    createdAt: Date = Date(),
    screenshotPaths: [String] = []
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

// MARK: - MCP Run Result DTO

/// Data transfer object for individual agent results
public struct MCPRunResultDTO: Identifiable, Codable, Sendable {
  public let id: UUID
  public let chainId: String
  public let agentId: String
  public let agentName: String
  public let model: String
  public let prompt: String
  public let output: String
  public let premiumCost: Double
  public let reviewVerdict: String?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
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
    self.id = id
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

// MARK: - Chain Run Status

/// Status of a chain run (for MCP status queries)
public struct MCPChainRunStatus: Codable, Sendable {
  public let chainId: String
  public let templateName: String
  public let status: String
  public let currentAgent: String?
  public let completedAgents: [String]
  public let pendingAgents: [String]
  public let startedAt: Date
  public let elapsedSeconds: Double
  public let isPaused: Bool

  public init(
    chainId: String,
    templateName: String,
    status: String,
    currentAgent: String? = nil,
    completedAgents: [String] = [],
    pendingAgents: [String] = [],
    startedAt: Date,
    elapsedSeconds: Double,
    isPaused: Bool = false
  ) {
    self.chainId = chainId
    self.templateName = templateName
    self.status = status
    self.currentAgent = currentAgent
    self.completedAgents = completedAgents
    self.pendingAgents = pendingAgents
    self.startedAt = startedAt
    self.elapsedSeconds = elapsedSeconds
    self.isPaused = isPaused
  }
}

// MARK: - Server Status

/// MCP server status response
public struct MCPServerStatus: Codable, Sendable {
  public let isRunning: Bool
  public let port: Int
  public let activeRequests: Int
  public let lastRequestMethod: String?
  public let lastRequestAt: Date?
  public let sleepPreventionEnabled: Bool
  public let sleepPreventionActive: Bool
  public let activeChains: Int
  public let queuedChains: Int

  public init(
    isRunning: Bool,
    port: Int,
    activeRequests: Int = 0,
    lastRequestMethod: String? = nil,
    lastRequestAt: Date? = nil,
    sleepPreventionEnabled: Bool = false,
    sleepPreventionActive: Bool = false,
    activeChains: Int = 0,
    queuedChains: Int = 0
  ) {
    self.isRunning = isRunning
    self.port = port
    self.activeRequests = activeRequests
    self.lastRequestMethod = lastRequestMethod
    self.lastRequestAt = lastRequestAt
    self.sleepPreventionEnabled = sleepPreventionEnabled
    self.sleepPreventionActive = sleepPreventionActive
    self.activeChains = activeChains
    self.queuedChains = queuedChains
  }
}
