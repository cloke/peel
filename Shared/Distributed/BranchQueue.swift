// BranchQueue.swift
// Peel
//
// Created on 2026-01-28.
// Tracks in-flight branches to prevent collisions across swarm tasks.

import Foundation
import os.log
import SwiftData

/// Tracks branches being worked on across the swarm to prevent name collisions
@MainActor
@Observable
public final class BranchQueue {
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "BranchQueue")
  
  /// Branches currently being worked on (taskId -> reservation)
  private var inFlightBranches: [UUID: BranchReservation] = [:]
  
  /// Completed branches waiting for PR creation or merge
  private var completedBranches: [UUID: CompletedBranch] = [:]

  /// SwiftData context for persisting reservations across app restarts.
  public var modelContext: ModelContext? {
    didSet {
      if modelContext != nil {
        recoverFromPersistence()
      }
    }
  }
  
  /// Information about a reserved branch
  public struct BranchReservation: Sendable {
    public let taskId: UUID
    public let branchName: String
    public let repoPath: String
    public let workerId: String
    public let createdAt: Date
    
    public init(taskId: UUID, branchName: String, repoPath: String, workerId: String, createdAt: Date = Date()) {
      self.taskId = taskId
      self.branchName = branchName
      self.repoPath = repoPath
      self.workerId = workerId
      self.createdAt = createdAt
    }
  }
  
  /// Information about a completed branch ready for PR/merge
  public struct CompletedBranch: Sendable {
    public let taskId: UUID
    public let branchName: String
    public let repoPath: String
    public let workerId: String
    public let completedAt: Date
    public let status: CompletionStatus
    
    public enum CompletionStatus: String, Sendable {
      case success       // Task completed successfully, ready for PR
      case failed        // Task failed, branch may have partial work
      case needsReview   // Task needs human review before PR
    }
  }
  
  public init() {}
  
  // MARK: - Branch Reservation
  
  /// Reserve a branch name for a task, ensuring uniqueness
  /// - Parameters:
  ///   - taskId: The task ID
  ///   - preferredName: The preferred branch name
  ///   - repoPath: Path to the repository
  ///   - workerId: ID of the worker that will execute the task
  /// - Returns: The actual branch name (may differ if preferred was taken)
  public func reserveBranch(
    taskId: UUID,
    preferredName: String,
    repoPath: String,
    workerId: String
  ) -> String {
    // Check if this task already has a reservation
    if let existing = inFlightBranches[taskId] {
      logger.warning("Task \(taskId) already has branch reserved: \(existing.branchName)")
      return existing.branchName
    }
    
    // Check for conflicts with in-flight branches
    var branchName = preferredName
    var attempt = 0
    while !isBranchAvailable(branchName, in: repoPath) {
      attempt += 1
      let suffix = String(taskId.uuidString.prefix(4)).lowercased()
      branchName = "\(preferredName)-\(suffix)\(attempt > 1 ? "-\(attempt)" : "")"
      
      if attempt > 10 {
        // Fallback to fully unique name
        branchName = "swarm/task-\(taskId.uuidString.lowercased())"
        break
      }
    }
    
    let reservation = BranchReservation(
      taskId: taskId,
      branchName: branchName,
      repoPath: repoPath,
      workerId: workerId
    )
    inFlightBranches[taskId] = reservation

    // Persist so the reservation survives app restart
    if let ctx = modelContext {
      let record = SwarmBranchReservation(
        taskId: taskId,
        branchName: branchName,
        repoPath: repoPath,
        workerId: workerId
      )
      ctx.insert(record)
      try? ctx.save()
    }

    if branchName != preferredName {
      logger.info("Branch '\(preferredName)' was taken, reserved '\(branchName)' instead")
    } else {
      logger.info("Reserved branch '\(branchName)' for task \(taskId)")
    }
    
    return branchName
  }
  
  /// Release a branch reservation when task completes
  /// - Parameters:
  ///   - taskId: The task ID
  ///   - status: The completion status
  public func completeBranch(taskId: UUID, status: CompletedBranch.CompletionStatus) {
    guard let reservation = inFlightBranches.removeValue(forKey: taskId) else {
      logger.warning("No branch reservation found for task \(taskId)")
      return
    }
    
    let completed = CompletedBranch(
      taskId: reservation.taskId,
      branchName: reservation.branchName,
      repoPath: reservation.repoPath,
      workerId: reservation.workerId,
      completedAt: Date(),
      status: status
    )
    completedBranches[taskId] = completed

    // Update persisted record
    if let ctx = modelContext {
      let taskIdStr = taskId.uuidString
      let descriptor = FetchDescriptor<SwarmBranchReservation>(
        predicate: #Predicate { $0.taskId == taskIdStr && $0.isInFlight == true }
      )
      if let record = try? ctx.fetch(descriptor).first {
        record.isInFlight = false
        record.completionStatus = status.rawValue
        try? ctx.save()
      }
    }

    logger.info("Branch '\(reservation.branchName)' completed with status: \(status.rawValue)")
  }
  
  /// Release a branch entirely (after PR merged or abandoned)
  public func releaseBranch(taskId: UUID) {
    if let reservation = inFlightBranches.removeValue(forKey: taskId) {
      logger.info("Released in-flight branch '\(reservation.branchName)'")
    }
    if let completed = completedBranches.removeValue(forKey: taskId) {
      logger.info("Released completed branch '\(completed.branchName)'")
    }
  }
  
  // MARK: - Query Methods
  
  /// Check if a branch name is available in a repo
  public func isBranchAvailable(_ name: String, in repoPath: String) -> Bool {
    // Check in-flight branches
    let inFlightConflict = inFlightBranches.values.contains {
      $0.branchName == name && $0.repoPath == repoPath
    }
    
    // Check completed branches (still holding the name until merged)
    let completedConflict = completedBranches.values.contains {
      $0.branchName == name && $0.repoPath == repoPath
    }
    
    return !inFlightConflict && !completedConflict
  }
  
  /// Get the reservation for a task
  public func getReservation(taskId: UUID) -> BranchReservation? {
    inFlightBranches[taskId]
  }
  
  /// Get the completed branch info for a task
  public func getCompleted(taskId: UUID) -> CompletedBranch? {
    completedBranches[taskId]
  }
  
  /// Get all in-flight branch reservations
  public func getAllInFlight() -> [BranchReservation] {
    Array(inFlightBranches.values)
  }
  
  /// Get all completed branches awaiting PR/merge
  public func getAllCompleted() -> [CompletedBranch] {
    Array(completedBranches.values)
  }
  
  /// Get completed branches that are ready for PR creation
  public func getBranchesReadyForPR() -> [CompletedBranch] {
    completedBranches.values.filter { $0.status == .success }
  }
  
  /// Get branches that need human review
  public func getBranchesNeedingReview() -> [CompletedBranch] {
    completedBranches.values.filter { $0.status == .needsReview || $0.status == .failed }
  }
  
  // MARK: - Statistics
  
  /// Get queue statistics
  public func getStats() -> QueueStats {
    QueueStats(
      inFlightCount: inFlightBranches.count,
      completedCount: completedBranches.count,
      readyForPRCount: getBranchesReadyForPR().count,
      needingReviewCount: getBranchesNeedingReview().count
    )
  }
  
  public struct QueueStats: Sendable {
    public let inFlightCount: Int
    public let completedCount: Int
    public let readyForPRCount: Int
    public let needingReviewCount: Int
  }

  // MARK: - Persistence Recovery

  /// Repopulate `inFlightBranches` from SwiftData after an app restart.
  private func recoverFromPersistence() {
    guard let ctx = modelContext else { return }
    let descriptor = FetchDescriptor<SwarmBranchReservation>(
      predicate: #Predicate { $0.isInFlight == true }
    )
    guard let records = try? ctx.fetch(descriptor) else { return }
    var recovered = 0
    for record in records {
      guard let taskUUID = UUID(uuidString: record.taskId),
            inFlightBranches[taskUUID] == nil else { continue }
      let reservation = BranchReservation(
        taskId: taskUUID,
        branchName: record.branchName,
        repoPath: record.repoPath,
        workerId: record.workerId,
        createdAt: record.createdAt
      )
      inFlightBranches[taskUUID] = reservation
      recovered += 1
    }
    if recovered > 0 {
      logger.info("BranchQueue recovered \(recovered) in-flight reservation(s) from SwiftData")
    }
  }
}
