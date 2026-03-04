// PRQueue.swift
// Peel
//
// Created on 2026-01-28.
// Manages PR creation and tracking for swarm-completed branches.

import Foundation
import os.log
import SwiftData

/// Labels applied to swarm-created PRs
public enum PeelPRLabel: String, Sendable, CaseIterable {
  case created = "peel:created"           // PR was created by Peel
  case approved = "peel:approved"         // PR passed validation, ready for human review
  case needsReview = "peel:needs-review"  // Awaiting human review
  case needsHelp = "peel:needs-help"      // PR needs human intervention
  case conflict = "peel:conflict"         // Merge conflicts detected
  case merged = "peel:merged"             // PR was auto-merged (if enabled)
  
  public var description: String {
    switch self {
    case .created: return "Created by Peel swarm"
    case .approved: return "Validated and approved by Peel"
    case .needsReview: return "Awaiting human review"
    case .needsHelp: return "Needs human intervention"
    case .conflict: return "Merge conflicts detected"
    case .merged: return "Auto-merged by Peel"
    }
  }
  
  public var color: String {
    switch self {
    case .created: return "0366d6"     // Blue
    case .approved: return "28a745"    // Green
    case .needsReview: return "f9c513" // Yellow
    case .needsHelp: return "d73a49"   // Red
    case .conflict: return "b60205"    // Dark red
    case .merged: return "6f42c1"      // Purple
    }
  }
}

/// Manages the queue of PRs to create and track
@MainActor
@Observable
public final class PRQueue {
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "PRQueue")
  
  /// Queue of pending PR operations.
  /// Uses a head index to avoid O(n) `removeFirst()` churn under load.
  private var pendingOperations: [QueuedOperation] = []
  private var queueHeadIndex = 0

  /// Retry policy for transient failures.
  private let maxRetryAttempts = 3

  /// SwiftData context for persisting queue state across app restarts.
  public var modelContext: ModelContext? {
    didSet {
      if modelContext != nil {
        recoverFromPersistence()
      }
    }
  }
  
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

  private enum OperationType: String {
    case createPR
    case updateLabel
    case addComment
  }

  private struct QueuedOperation: Sendable {
    let id: UUID
    let operation: PROperation
    let attempt: Int

    init(id: UUID = UUID(), operation: PROperation, attempt: Int = 0) {
      self.id = id
      self.operation = operation
      self.attempt = attempt
    }
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
    enqueueOperation(.createPR(request))
    processNextIfIdle()
  }
  
  /// Enqueue a label update
  public func enqueueUpdateLabel(taskId: UUID, prNumber: Int, label: PeelPRLabel) {
    logger.info("Enqueuing label update: PR #\(prNumber) -> \(label.rawValue)")
    enqueueOperation(.updateLabel(taskId: taskId, prNumber: prNumber, label: label))
    processNextIfIdle()
  }
  
  /// Enqueue a comment
  public func enqueueComment(taskId: UUID, prNumber: Int, comment: String) {
    enqueueOperation(.addComment(taskId: taskId, prNumber: prNumber, comment: comment))
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
    upsertCreatedPRRecord(prInfo)
    logger.info("Created PR #\(prNumber): \(prURL)")
    
    return prInfo
  }
  
  // MARK: - Queue Processing
  
  private func processNextIfIdle() {
    guard !isProcessing, pendingCount > 0, let next = dequeueOperation() else { return }
    
    isProcessing = true
    
    Task {
      defer {
        isProcessing = false
        processNextIfIdle()
      }
      
      do {
        switch next.operation {
        case .createPR(let request):
          _ = try await createPRNow(request)
          
        case .updateLabel(let taskId, let prNumber, let label):
          try await updatePRLabel(taskId: taskId, prNumber: prNumber, label: label)
          
        case .addComment(let taskId, let prNumber, let comment):
          try await addPRComment(taskId: taskId, prNumber: prNumber, comment: comment)
        }
        markOperationCompleted(next.id)
      } catch {
        if shouldRetry(error: error, attempt: next.attempt) {
          scheduleRetry(for: next)
        } else {
          logger.error("PR operation failed permanently after \(next.attempt + 1) attempt(s): \(error.localizedDescription)")
          markOperationCompleted(next.id)
        }
      }
    }
  }

  private func enqueueOperation(
    _ operation: PROperation,
    attempt: Int = 0,
    id: UUID = UUID(),
    persist: Bool = true
  ) {
    let queued = QueuedOperation(id: id, operation: operation, attempt: attempt)
    pendingOperations.append(queued)
    if persist {
      persistQueuedOperation(queued)
    }
  }

  private func dequeueOperation() -> QueuedOperation? {
    guard queueHeadIndex < pendingOperations.count else {
      pendingOperations.removeAll(keepingCapacity: true)
      queueHeadIndex = 0
      return nil
    }

    let item = pendingOperations[queueHeadIndex]
    queueHeadIndex += 1

    if queueHeadIndex > 64 && queueHeadIndex * 2 > pendingOperations.count {
      pendingOperations.removeFirst(queueHeadIndex)
      queueHeadIndex = 0
    }

    return item
  }

  private func scheduleRetry(for queued: QueuedOperation) {
    let nextAttempt = queued.attempt + 1
    let delayNanos = retryDelayNanos(for: nextAttempt)
    logger.warning("PR operation failed (attempt \(nextAttempt)); retrying in \(delayNanos / 1_000_000_000)s")
    updateQueuedOperationAttempt(id: queued.id, attempt: nextAttempt)

    Task {
      try? await Task.sleep(nanoseconds: delayNanos)
      enqueueOperation(queued.operation, attempt: nextAttempt, id: queued.id, persist: false)
      processNextIfIdle()
    }
  }

  private func shouldRetry(error: Error, attempt: Int) -> Bool {
    guard attempt < maxRetryAttempts else { return false }

    if case PRQueueError.noDelegateConfigured = error {
      return false
    }

    // Assume transient unless explicitly non-retryable.
    return true
  }

  private func retryDelayNanos(for attempt: Int) -> UInt64 {
    let exponentialSeconds = min(30.0, pow(2.0, Double(attempt)))
    let jitterSeconds = Double(Int.random(in: 0...750)) / 1000.0
    return UInt64((exponentialSeconds + jitterSeconds) * 1_000_000_000)
  }
  
  private func updatePRLabel(taskId: UUID, prNumber: Int, label: PeelPRLabel) async throws {
    guard let delegate = delegate else { return }
    guard var prInfo = createdPRs[taskId] else { return }
    
    try await delegate.prQueue(self, addLabel: label.rawValue, toPR: prNumber, in: prInfo.repoPath)
    
    if !prInfo.labels.contains(label) {
      prInfo.labels.append(label)
      createdPRs[taskId] = prInfo
      upsertCreatedPRRecord(prInfo)
    }
  }
  
  private func addPRComment(taskId: UUID, prNumber: Int, comment: String) async throws {
    guard let delegate = delegate else { return }
    guard let prInfo = createdPRs[taskId] else { return }
    
    try await delegate.prQueue(self, addComment: comment, toPR: prNumber, in: prInfo.repoPath)
  }
  
  private func pushBranch(_ branchName: String, in repoPath: String) async throws {
    let result = try await runGitCommand(["push", "-u", "origin", branchName], in: repoPath)

    if result.exitCode != 0 {
      let errorMessage = result.stderr.isEmpty ? "Unknown error" : result.stderr
      throw PRQueueError.pushFailed(errorMessage)
    }
    
    logger.info("Pushed branch '\(branchName)' to origin")
  }

  private struct GitCommandResult {
    let exitCode: Int32
    let stderr: String
  }

  private func runGitCommand(_ arguments: [String], in repoPath: String) async throws -> GitCommandResult {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

      let stderr = Pipe()
      process.standardError = stderr
      process.standardOutput = FileHandle.nullDevice

      process.terminationHandler = { process in
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
        continuation.resume(returning: GitCommandResult(exitCode: process.terminationStatus, stderr: errorMessage))
      }

      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  // MARK: - Persistence

  private func recoverFromPersistence() {
    guard let ctx = modelContext else { return }
    guard pendingOperations.isEmpty, createdPRs.isEmpty else { return }

    let pendingDescriptor = FetchDescriptor<PRQueueOperationRecord>(
      sortBy: [SortDescriptor(\PRQueueOperationRecord.createdAt, order: .forward)]
    )
    if let pendingRecords = try? ctx.fetch(pendingDescriptor) {
      for record in pendingRecords {
        guard let queued = queuedOperation(from: record) else { continue }
        enqueueOperation(
          queued.operation,
          attempt: queued.attempt,
          id: queued.id,
          persist: false
        )
      }
      if !pendingRecords.isEmpty {
        logger.info("Recovered \(pendingRecords.count) pending PR operation(s) from SwiftData")
      }
    }

    let createdDescriptor = FetchDescriptor<PRQueueCreatedPRRecord>(
      sortBy: [SortDescriptor(\PRQueueCreatedPRRecord.createdAt, order: .reverse)]
    )
    if let createdRecords = try? ctx.fetch(createdDescriptor) {
      for record in createdRecords {
        guard let taskId = UUID(uuidString: record.taskId) else { continue }
        let labels = parseLabelsCSV(record.labelsCSV)
        let status = PRInfo.PRStatus(rawValue: record.status) ?? .open
        createdPRs[taskId] = PRInfo(
          taskId: taskId,
          prNumber: record.prNumber,
          prURL: record.prURL,
          branchName: record.branchName,
          repoPath: record.repoPath,
          createdAt: record.createdAt,
          labels: labels,
          status: status
        )
      }
      if !createdRecords.isEmpty {
        logger.info("Recovered \(createdRecords.count) created PR record(s) from SwiftData")
      }
    }
  }

  private func persistQueuedOperation(_ queued: QueuedOperation) {
    guard let ctx = modelContext,
          let record = operationRecord(from: queued)
    else { return }
    ctx.insert(record)
    try? ctx.save()
  }

  private func markOperationCompleted(_ id: UUID) {
    guard let ctx = modelContext else { return }
    let targetId = id
    let descriptor = FetchDescriptor<PRQueueOperationRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    if let record = try? ctx.fetch(descriptor).first {
      ctx.delete(record)
      try? ctx.save()
    }
  }

  private func updateQueuedOperationAttempt(id: UUID, attempt: Int) {
    guard let ctx = modelContext else { return }
    let targetId = id
    let descriptor = FetchDescriptor<PRQueueOperationRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    if let record = try? ctx.fetch(descriptor).first {
      record.attempt = attempt
      try? ctx.save()
    }
  }

  private func upsertCreatedPRRecord(_ prInfo: PRInfo) {
    guard let ctx = modelContext else { return }
    let taskId = prInfo.taskId.uuidString
    let descriptor = FetchDescriptor<PRQueueCreatedPRRecord>(
      predicate: #Predicate { $0.taskId == taskId }
    )
    if let record = try? ctx.fetch(descriptor).first {
      record.prNumber = prInfo.prNumber
      record.prURL = prInfo.prURL
      record.branchName = prInfo.branchName
      record.repoPath = prInfo.repoPath
      record.createdAt = prInfo.createdAt
      record.labelsCSV = labelsCSV(from: prInfo.labels)
      record.status = prInfo.status.rawValue
      try? ctx.save()
      return
    }

    let newRecord = PRQueueCreatedPRRecord(
      taskId: prInfo.taskId.uuidString,
      prNumber: prInfo.prNumber,
      prURL: prInfo.prURL,
      branchName: prInfo.branchName,
      repoPath: prInfo.repoPath,
      createdAt: prInfo.createdAt,
      labelsCSV: labelsCSV(from: prInfo.labels),
      status: prInfo.status.rawValue
    )
    ctx.insert(newRecord)
    try? ctx.save()
  }

  private func operationRecord(from queued: QueuedOperation) -> PRQueueOperationRecord? {
    let record: PRQueueOperationRecord

    switch queued.operation {
    case .createPR(let request):
      record = PRQueueOperationRecord(id: queued.id, operationType: OperationType.createPR.rawValue, attempt: queued.attempt)
      record.taskId = request.taskId.uuidString
      record.branchName = request.branchName
      record.repoPath = request.repoPath
      record.baseBranch = request.baseBranch
      record.title = request.title
      record.body = request.body
      record.labelsCSV = labelsCSV(from: request.labels)
      record.isDraft = request.isDraft

    case .updateLabel(let taskId, let prNumber, let label):
      record = PRQueueOperationRecord(id: queued.id, operationType: OperationType.updateLabel.rawValue, attempt: queued.attempt)
      record.taskId = taskId.uuidString
      record.prNumber = prNumber
      record.labelRaw = label.rawValue

    case .addComment(let taskId, let prNumber, let comment):
      record = PRQueueOperationRecord(id: queued.id, operationType: OperationType.addComment.rawValue, attempt: queued.attempt)
      record.taskId = taskId.uuidString
      record.prNumber = prNumber
      record.commentText = comment
    }

    return record
  }

  private func queuedOperation(from record: PRQueueOperationRecord) -> QueuedOperation? {
    guard let type = OperationType(rawValue: record.operationType) else { return nil }

    switch type {
    case .createPR:
      guard let taskId = UUID(uuidString: record.taskId),
            !record.branchName.isEmpty,
            !record.repoPath.isEmpty,
            !record.title.isEmpty
      else { return nil }

      let request = CreatePRRequest(
        taskId: taskId,
        branchName: record.branchName,
        repoPath: record.repoPath,
        baseBranch: record.baseBranch.isEmpty ? "main" : record.baseBranch,
        title: record.title,
        body: record.body,
        labels: parseLabelsCSV(record.labelsCSV),
        isDraft: record.isDraft
      )
      return QueuedOperation(id: record.id, operation: .createPR(request), attempt: record.attempt)

    case .updateLabel:
      guard let taskId = UUID(uuidString: record.taskId),
            let label = PeelPRLabel(rawValue: record.labelRaw),
            record.prNumber > 0
      else { return nil }
      return QueuedOperation(
        id: record.id,
        operation: .updateLabel(taskId: taskId, prNumber: record.prNumber, label: label),
        attempt: record.attempt
      )

    case .addComment:
      guard let taskId = UUID(uuidString: record.taskId),
            record.prNumber > 0,
            !record.commentText.isEmpty
      else { return nil }
      return QueuedOperation(
        id: record.id,
        operation: .addComment(taskId: taskId, prNumber: record.prNumber, comment: record.commentText),
        attempt: record.attempt
      )
    }
  }

  private func labelsCSV(from labels: [PeelPRLabel]) -> String {
    labels.map(\.rawValue).joined(separator: ",")
  }

  private func parseLabelsCSV(_ csv: String) -> [PeelPRLabel] {
    csv
      .split(separator: ",")
      .compactMap { PeelPRLabel(rawValue: String($0)) }
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
    max(0, pendingOperations.count - queueHeadIndex)
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
  
  /// Ensure all Peel labels exist in a repo
  func prQueue(_ queue: PRQueue, ensureLabelsExistIn repoPath: String) async throws
}

// MARK: - Extension for Label Setup

extension PRQueue {
  /// Ensure all Peel PR labels exist in a repo (call once per repo setup)
  public func ensureLabelsExist(in repoPath: String) async throws {
    guard let delegate = delegate else {
      throw PRQueueError.noDelegateConfigured
    }
    try await delegate.prQueue(self, ensureLabelsExistIn: repoPath)
  }
  
  /// Get shell commands to create all Peel labels (for manual setup)
  public static func labelSetupCommands(repoPath: String) -> [String] {
    PeelPRLabel.allCases.map { label in
      """
      gh label create "\(label.rawValue)" \
        --description "\(label.description)" \
        --color "\(label.color)" \
        --force 2>/dev/null || true
      """
    }
  }
}

// MARK: - Errors

public enum PRQueueError: LocalizedError {
  case noDelegateConfigured
  case pushFailed(String)
  case prCreationFailed(String)
  case labelSetupFailed(String)
  
  public var errorDescription: String? {
    switch self {
    case .noDelegateConfigured:
      return "No PR queue delegate configured"
    case .pushFailed(let reason):
      return "Failed to push branch: \(reason)"
    case .prCreationFailed(let reason):
      return "Failed to create PR: \(reason)"
    case .labelSetupFailed(let reason):
      return "Failed to set up labels: \(reason)"
    }
  }
}
