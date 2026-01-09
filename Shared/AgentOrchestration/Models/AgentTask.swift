//
//  AgentTask.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation

/// Priority level for agent tasks
public enum TaskPriority: Int, Codable, CaseIterable, Comparable {
  case low = 0
  case medium = 1
  case high = 2
  case critical = 3
  
  public var displayName: String {
    switch self {
    case .low: return "Low"
    case .medium: return "Medium"
    case .high: return "High"
    case .critical: return "Critical"
    }
  }
  
  public var iconName: String {
    switch self {
    case .low: return "arrow.down"
    case .medium: return "minus"
    case .high: return "arrow.up"
    case .critical: return "exclamationmark.2"
    }
  }
  
  public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// Status of a task
public enum TaskStatus: String, Codable, CaseIterable {
  case pending
  case assigned
  case inProgress
  case review
  case completed
  case cancelled
  
  public var displayName: String {
    switch self {
    case .pending: return "Pending"
    case .assigned: return "Assigned"
    case .inProgress: return "In Progress"
    case .review: return "In Review"
    case .completed: return "Completed"
    case .cancelled: return "Cancelled"
    }
  }
  
  public var isTerminal: Bool {
    self == .completed || self == .cancelled
  }
}

/// Represents a task assigned to an agent
@MainActor
@Observable
public final class AgentTask: Identifiable {
  public let id: UUID
  public var title: String
  public var description: String
  public var priority: TaskPriority
  public var status: TaskStatus
  
  /// The prompt or instructions for the agent
  public var prompt: String
  
  /// Source context (e.g., PR number, issue number)
  public var sourceReference: String?
  
  /// Repository path this task relates to
  public var repositoryPath: String?
  
  /// Branch name to work on
  public var branchName: String?
  
  /// Timestamps
  public let createdAt: Date
  public var startedAt: Date?
  public var completedAt: Date?
  
  /// Output/result from the agent
  public var result: String?
  
  /// Files modified during this task
  public var modifiedFiles: [String] = []
  
  public init(
    id: UUID = UUID(),
    title: String,
    description: String = "",
    prompt: String,
    priority: TaskPriority = .medium,
    status: TaskStatus = .pending,
    sourceReference: String? = nil,
    repositoryPath: String? = nil,
    branchName: String? = nil
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.prompt = prompt
    self.priority = priority
    self.status = status
    self.sourceReference = sourceReference
    self.repositoryPath = repositoryPath
    self.branchName = branchName
    self.createdAt = Date()
  }
  
  /// Mark the task as started
  public func start() {
    status = .inProgress
    startedAt = Date()
  }
  
  /// Mark the task as completed
  public func complete(result: String? = nil) {
    status = .completed
    completedAt = Date()
    self.result = result
  }
  
  /// Mark the task as cancelled
  public func cancel() {
    status = .cancelled
    completedAt = Date()
  }
  
  /// Duration of the task (if started)
  public var duration: TimeInterval? {
    guard let start = startedAt else { return nil }
    let end = completedAt ?? Date()
    return end.timeIntervalSince(start)
  }
}

// MARK: - Hashable & Equatable
extension AgentTask: Hashable {
  public static func == (lhs: AgentTask, rhs: AgentTask) -> Bool {
    lhs.id == rhs.id
  }
  
  public nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// MARK: - Convenience Initializers
extension AgentTask {
  /// Create a task from a GitHub PR
  public static func fromPullRequest(
    number: Int,
    title: String,
    body: String?,
    repositoryPath: String
  ) -> AgentTask {
    AgentTask(
      title: "PR #\(number): \(title)",
      description: body ?? "",
      prompt: body ?? title,
      sourceReference: "PR #\(number)",
      repositoryPath: repositoryPath,
      branchName: "pr-\(number)-work"
    )
  }
  
  /// Create a task from a GitHub Issue
  public static func fromIssue(
    number: Int,
    title: String,
    body: String?,
    repositoryPath: String
  ) -> AgentTask {
    AgentTask(
      title: "Issue #\(number): \(title)",
      description: body ?? "",
      prompt: body ?? title,
      sourceReference: "Issue #\(number)",
      repositoryPath: repositoryPath,
      branchName: "issue-\(number)"
    )
  }
}
