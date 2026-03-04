//
//  ActivityItem.swift
//  Peel
//
//  A timeline event for the Activity feed. Each item represents something
//  meaningful that happened to a repository: a chain completed, a pull finished,
//  RAG indexing progressed, a worktree was created, etc.
//
//  ActivityItems are ephemeral (not persisted in SwiftData) — they are rebuilt
//  by ActivityFeed from MCPRunRecord, pull history, chain state changes, etc.
//

import Foundation

// MARK: - ActivityItem

struct ActivityItem: Identifiable, Hashable, Sendable {
  let id: UUID
  let timestamp: Date
  let kind: Kind
  let repoNormalizedURL: String?
  let repoDisplayName: String?
  let title: String
  let subtitle: String?
  let isError: Bool

  // MARK: - Kind

  enum Kind: Hashable, Sendable {
    /// An agent chain completed or failed.
    case chainCompleted(chainId: UUID, success: Bool)

    /// An agent chain started running.
    case chainStarted(chainId: UUID)

    /// A git pull completed.
    case pullCompleted(success: Bool)

    /// RAG indexing finished.
    case ragIndexed

    /// RAG analysis completed.
    case ragAnalyzed

    /// A worktree was created.
    case worktreeCreated(worktreeId: UUID)

    /// A worktree was cleaned up.
    case worktreeCleaned(worktreeId: UUID)

    /// A PR was viewed or updated.
    case prActivity(prNumber: Int)

    /// Swarm task dispatched to a worker.
    case swarmDispatched(taskId: String)

    /// Generic informational event.
    case info

    var systemImage: String {
      switch self {
      case .chainCompleted(_, let success):
        return success ? "checkmark.circle.fill" : "xmark.circle.fill"
      case .chainStarted:
        return "play.circle.fill"
      case .pullCompleted(let success):
        return success ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill"
      case .ragIndexed:
        return "magnifyingglass.circle.fill"
      case .ragAnalyzed:
        return "checkmark.seal.fill"
      case .worktreeCreated:
        return "plus.circle.fill"
      case .worktreeCleaned:
        return "trash.circle.fill"
      case .prActivity:
        return "arrow.triangle.pull"
      case .swarmDispatched:
        return "antenna.radiowaves.left.and.right"
      case .info:
        return "info.circle"
      }
    }

    var tintColorName: String {
      switch self {
      case .chainCompleted(_, let success):
        return success ? "green" : "red"
      case .chainStarted:
        return "blue"
      case .pullCompleted(let success):
        return success ? "green" : "orange"
      case .ragIndexed, .ragAnalyzed:
        return "purple"
      case .worktreeCreated:
        return "blue"
      case .worktreeCleaned:
        return "gray"
      case .prActivity:
        return "orange"
      case .swarmDispatched:
        return "teal"
      case .info:
        return "secondary"
      }
    }
  }

  // MARK: - Hashable

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: ActivityItem, rhs: ActivityItem) -> Bool {
    lhs.id == rhs.id
  }
}

// MARK: - Relative Time Formatting

extension ActivityItem {
  /// Human-readable relative time, e.g. "2m ago", "1h ago", "yesterday".
  var relativeTime: String {
    let interval = Date().timeIntervalSince(timestamp)
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    if interval < 172800 { return "yesterday" }
    return "\(Int(interval / 86400))d ago"
  }
}
