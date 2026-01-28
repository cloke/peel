// PRQueue.swift
// Peel
//
// Created on 2026-01-28.
// Manages PR creation and tracking for swarm-completed branches.

import Foundation
import os.log

/// Labels applied to swarm-created PRs
public enum PeelPRLabel: String, Sendable, CaseIterable {
  case created = "peel:created"       // PR was created by Peel
  case approved = "peel:approved"     // PR passed validation, ready for human review
  case needsHelp = "peel:needs-help"  // PR needs human intervention
  case merged = "peel:merged"         // PR was auto-merged (if enabled)
  
  public var description: String {
    switch self {
    case .created: return "Created by Peel swarm"
    case .approved: return "Validated and approved by Peel"
    case .needsHelp: return "Needs human review"
    case .merged: return "Auto-merged by Peel"
    }
  }
  
  public var color: String {
    switch self {
    case .created: return "0366d6"    // Blue
    case .approved: return "28a745"   // Green
    case .needsHelp: return "d73a49"  // Red
    case .merged: return "6f42c1"     // Purple
    }
  }
}

/// Manages the queue of PRs to create and track
@MainActor
@Observable
public final class PRQueue {
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "PRQueue")
  
  /// Queue of pending PR operations
  private var pendingOperations: [PROperation] = []
  
  /// Currently processing
  private var isProcessing = false
  
  /// Created PRs (taskId -> PR info)
  private var createdPRs: [UUID: PRInfo] = [:]
  
  /// Delegate for PR operations
  public weak var delegate: PRQueueDelegate?
  
  /// Operation to perform
  public enum PROperation: Sendable {
    case createPR(CreatePRRequest)
    case updateLabel(taskId: UUID, prNumber: Int, label: PeelPRLabel)
    case addComment(taskId: UUID, prNumber: Int, comment: String)
  }
  
  /// Request to create a PR
  public struct CreatePRRequest: Sendable {
    public let taskId: UUID
    public let branchName: String
    public let repoPath: String
    public let baseBranch: String
    public let title: String
    public let body: String
    public let labels: [PeelPRLabel]
    public let isDraft: Bool
    
    public init(
      taskId: UUID,
      branchName: String,
      repoPath: String,
      baseBranch: String = "main",
      title: String,
      body: String,
      labels: [PeelPRLabel] = [.created],
      isDraft: Bool = false
    ) {
      self.taskId = taskId
      self.branchName = branchName
      self.repoPath = repoPath
      self.baseBranch = baseBranch
      self.title = title
      self.body = body
      self.labels = labels
      self.isDraft = isDraft
    }
  }
  
  /// Information about a created PR
  public struct PRInfo: Sendable {
    public let taskId: UUID
    public let prNumber: Int
    public let prURL: String
    public let branchName: String
    public let repoPath: String
    public let createdAt: Date
    public var labels: [PeelPRLabel]
    public var status: PRStatus
    
    public enum PRStatus: String, Sendable {
      case open
      case merged
      case closed
    }
  }
  
  public init() {}
  
  // MARK: - Queue Operations
  
  /// Enqueue a PR creation request
  public func enqueueCreatePR(_ request: CreatePRRequest) {
    logger.info("Enqueuing PR creation for branch '\(request.branchName)'")
    pendingOperations.append(.createPR(request))
    processNextIfIdle()
  }
  
  /// Enqueue a label update
  public func enqueueUpdateLabel(taskId: UUID, prNumber: Int, label: PeelPRLabel) {
    logger.info("Enqueuing label update: PR #\(prNumber) -> \(label.rawValue)")
    pendingOperations.append(.updateLabel(taskId: taskId, prNumber: prNumber, label: label))
    processNextIfIdle()
  }
  
  /// Enqueue a comment
  public func enqueueComment(taskId: UUID, prNumber: Int, comment: String) {
    pendingOperations.append(.addComment(taskId: taskId, prNumber: prNumber, comment: comment))
    processNextIfIdle()
  }
  
  /// Create a PR immediately (bypassing queue)
  public func createPRNow(_ request: CreatePRRequest) async throws -> PRInfo {
    guard let delegate = delegate else {
      throw PRQueueError.noDelegateConfigured
    }
    
    logger.info("Creating PR for branch '\(request.branchName)' in \(request.repoPath)")
    
    // Push the branch first
    try await pushBranch(request.branchName, in: request.repoPath)
    
    // Create the PR via delegate
    let (prNumber, prURL) = try await delegate.prQueue(
      self,
      createPRForBranch: request.branchName,
      baseBranch: request.baseBranch,
      title: request.title,
      body: request.body,
      labels: request.labels.map(\.rawValue),
      isDraft: request.isDraft,
      in: request.repoPath
    )
    
    let prInfo = PRInfo(
      taskId: request.taskId,
      prNumber: prNumber,
      prURL: prURL,
      branchName: request.branchName,
      repoPath: request.repoPath,
      createdAt: Date(),
      labels: request.labels,
      status: .open
    )
    
    createdPRs[request.taskId] = prInfo
    logger.info("Created PR #\(prNumber): \(prURL)")
    
    return prInfo
  }
  
  // MARK: - Queue Processing
  
  private func processNextIfIdle() {
    guard !isProcessing, !pendingOperations.isEmpty else { return }
    
    isProcessing = true
    let operation = pendingOperations.removeFirst()
    
    Task {
      defer {
        isProcessing = false
        processNextIfIdle()
      }
      
      do {
        switch operation {
        case .createPR(let request):
          _ = try await createPRNow(request)
          
        case .updateLabel(let taskId, let prNumber, let label):
          try await updatePRLabel(taskId: taskId, prNumber: prNumber, label: label)
          
        case .addComment(let taskId, let prNumber, let comment):
          try await addPRComment(taskId: taskId, prNumber: prNumber, comment: comment)
        }
      } catch {
        logger.error("PR operation failed: \(error.localizedDescription)")
      }
    }
  }
  
  private func updatePRLabel(taskId: UUID, prNumber: Int, label: PeelPRLabel) async throws {
    guard let delegate = delegate else { return }
    guard var prInfo = createdPRs[taskId] else { return }
    
    try await delegate.prQueue(self, addLabel: label.rawValue, toPR: prNumber, in: prInfo.repoPath)
    
    if !prInfo.labels.contains(label) {
      prInfo.labels.append(label)
      createdPRs[taskId] = prInfo
    }
  }
  
  private func addPRComment(taskId: UUID, prNumber: Int, comment: String) async throws {
    guard let delegate = delegate else { return }
    guard let prInfo = createdPRs[taskId] else { return }
    
    try await delegate.prQueue(self, addComment: comment, toPR: prNumber, in: prInfo.repoPath)
  }
  
  private func pushBranch(_ branchName: String, in repoPath: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["push", "-u", "origin", branchName]
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = FileHandle.nullDevice
    
    try process.run()
    process.waitUntilExit()
    
    if process.terminationStatus != 0 {
      let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
      let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
      throw PRQueueError.pushFailed(errorMessage)
    }
    
    logger.info("Pushed branch '\(branchName)' to origin")
  }
  
  // MARK: - Query Methods
  
  /// Get PR info for a task
  public func getPRInfo(taskId: UUID) -> PRInfo? {
    createdPRs[taskId]
  }
  
  /// Get all created PRs
  public func getAllPRs() -> [PRInfo] {
    Array(createdPRs.values)
  }
  
  /// Get PRs by label
  public func getPRs(withLabel label: PeelPRLabel) -> [PRInfo] {
    createdPRs.values.filter { $0.labels.contains(label) }
  }
  
  /// Get pending operations count
  public var pendingCount: Int {
    pendingOperations.count
  }
  
  // MARK: - Convenience Methods
  
  /// Create a PR from a completed swarm task
  public func createPRFromTask(
    taskId: UUID,
    branchName: String,
    repoPath: String,
    prompt: String,
    outputs: String? = nil
  ) {
    let title = generatePRTitle(from: prompt, branchName: branchName)
    let body = generatePRBody(taskId: taskId, prompt: prompt, outputs: outputs)
    
    let request = CreatePRRequest(
      taskId: taskId,
      branchName: branchName,
      repoPath: repoPath,
      title: title,
      body: body,
      labels: [.created]
    )
    
    enqueueCreatePR(request)
  }
  
  private func generatePRTitle(from prompt: String, branchName: String) -> String {
    // Try to extract a meaningful title from the prompt
    let firstLine = prompt.split(separator: "\n").first.map(String.init) ?? prompt
    let truncated = String(firstLine.prefix(60))
    
    if truncated.count < firstLine.count {
      return truncated + "..."
    }
    return truncated
  }
  
  private func generatePRBody(taskId: UUID, prompt: String, outputs: String?) -> String {
    var body = """
    ## 🤖 Generated by Peel Swarm
    
    **Task ID:** `\(taskId.uuidString)`
    
    ### Prompt
    \(prompt)
    """
    
    if let outputs = outputs, !outputs.isEmpty {
      body += """
      
      
      ### Agent Output
      <details>
      <summary>Click to expand</summary>
      
      ```
      \(outputs.prefix(2000))
      ```
      
      </details>
      """
    }
    
    body += """
    
    
    ---
    *This PR was automatically created by [Peel](https://github.com/cloke/peel) swarm.*
    """
    
    return body
  }
}

// MARK: - Delegate Protocol

/// Delegate for PR operations (allows injection of GitHub/Git operations)
@MainActor
public protocol PRQueueDelegate: AnyObject {
  /// Create a PR and return (prNumber, prURL)
  func prQueue(
    _ queue: PRQueue,
    createPRForBranch branch: String,
    baseBranch: String,
    title: String,
    body: String,
    labels: [String],
    isDraft: Bool,
    in repoPath: String
  ) async throws -> (Int, String)
  
  /// Add a label to a PR
  func prQueue(_ queue: PRQueue, addLabel label: String, toPR prNumber: Int, in repoPath: String) async throws
  
  /// Add a comment to a PR
  func prQueue(_ queue: PRQueue, addComment comment: String, toPR prNumber: Int, in repoPath: String) async throws
}

// MARK: - Errors

public enum PRQueueError: LocalizedError {
  case noDelegateConfigured
  case pushFailed(String)
  case prCreationFailed(String)
  
  public var errorDescription: String? {
    switch self {
    case .noDelegateConfigured:
      return "No PR queue delegate configured"
    case .pushFailed(let reason):
      return "Failed to push branch: \(reason)"
    case .prCreationFailed(let reason):
      return "Failed to create PR: \(reason)"
    }
  }
}
