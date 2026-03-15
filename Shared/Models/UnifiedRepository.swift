//
//  UnifiedRepository.swift
//  Peel
//
//  A view-layer aggregate that unifies all repository data sources into a single
//  identity. This is NOT a SwiftData model — it's a computed snapshot produced by
//  RepositoryAggregator. Every concept the app knows about a repository
//  (local clone, GitHub metadata, RAG status, active chains, worktrees, pull scheduling)
//  is surfaced through this type via the normalized remote URL join key.
//

import Foundation

// MARK: - UnifiedRepository

/// Represents a single repository identity aggregated from multiple data sources.
/// The join key is `normalizedRemoteURL` (produced by `RepoRegistry.normalizeRemoteURL`).
/// Properties are populated from whichever data source provides them; missing sources
/// leave their fields nil.
struct UnifiedRepository: Identifiable, Hashable, Sendable {
  // MARK: - Identity

  /// Stable identifier — prefers SyncedRepository.id when available; falls back to
  /// a UUID derived deterministically from the normalized remote URL.
  let id: UUID

  /// The canonical join key, e.g. "github.com/cloke/peel"
  let normalizedRemoteURL: String

  /// Best display name — prefers SyncedRepository.name, then TrackedRemoteRepo.name,
  /// then the last path component of the URL.
  let displayName: String

  /// Full remote URL in its original form (HTTPS or SSH), if known.
  let remoteURL: String?

  // MARK: - Presence Flags

  /// Whether this repo has a local clone on this machine.
  let isClonedLocally: Bool

  /// The local file-system path to the clone (from LocalRepositoryPath or TrackedRemoteRepo).
  let localPath: String?

  /// Whether this repo is a GitHub Favorite.
  let isFavorite: Bool

  /// Whether this repo has auto-pull tracking enabled.
  let isTracked: Bool

  /// Whether this is a sub-package of a larger repo (e.g. a Local Package within a monorepo).
  let isSubPackage: Bool

  // MARK: - GitHub Metadata

  /// Owner and repo segments, e.g. "cloke/peel".
  let ownerSlashRepo: String?

  /// GitHub HTML URL, if known.
  let htmlURL: String?

  // MARK: - RAG Status

  /// Current RAG indexing/analysis status (nil = not indexed).
  let ragStatus: RAGStatus?

  /// Number of indexed files in RAG, if available.
  let ragFileCount: Int?

  /// Number of chunks in RAG, if available.
  let ragChunkCount: Int?

  /// Embedding model used for this repo's RAG index.
  let ragEmbeddingModel: String?

  /// When this repo was last RAG-indexed.
  let ragLastIndexedAt: Date?

  // MARK: - Pull Scheduling

  /// Auto-pull status, if tracking is enabled.
  let pullStatus: PullStatus?

  /// Branch being tracked for pulls.
  let trackedBranch: String?

  /// Pull interval in seconds.
  let pullIntervalSeconds: Int?

  /// How RAG indexing is handled after pulls: rebuild locally or sync from crown.
  let syncMode: TrackedRepoSyncMode?

  // MARK: - Active Work

  /// Number of agent chains currently operating on this repo.
  let activeChainCount: Int

  /// Summary of active chains (id, name, state display).
  let activeChains: [ChainSummary]

  /// Number of worktrees associated with this repo.
  let worktreeCount: Int

  /// Active (non-cleaned) worktrees.
  let activeWorktrees: [WorktreeSummary]

  /// Recent pull requests associated with this repo.
  let recentPRs: [PRSummary]

  // MARK: - Timestamps

  /// When this repo was first added to the app (earliest createdAt across all sources).
  let addedAt: Date?

  /// Most recent meaningful activity timestamp across all sources.
  let lastActivityAt: Date?

  // MARK: - Source Refs (for drill-down)

  /// The SyncedRepository id, if one exists.
  let syncedRepositoryId: UUID?

  /// The TrackedRemoteRepo id, if one exists.
  let trackedRemoteRepoId: UUID?

  /// The GitHubFavorite id, if one exists.
  let githubFavoriteId: UUID?

  // MARK: - User Customization (from SyncedRepository)

  /// Color tag for sidebar/list display.
  let colorTag: String?

  /// User notes on this repo.
  let notes: String?

  // MARK: - Hashable

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: UnifiedRepository, rhs: UnifiedRepository) -> Bool {
    lhs.id == rhs.id
  }
}

// MARK: - Nested Summary Types

extension UnifiedRepository {

  /// Lightweight chain reference for display in the repo card.
  struct ChainSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let stateDisplay: String
    let isTerminal: Bool
  }

  /// Lightweight worktree reference.
  struct WorktreeSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let branch: String
    let source: String      // "manual" | "swarm" | "parallel"
    let taskStatus: String   // "active" | "committed" | "failed" etc.
    let purpose: String?
  }

  /// Lightweight PR reference.
  struct PRSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let number: Int
    let title: String
    let state: String
    let htmlURL: String?
    let headRef: String?
    let updatedAt: String?
  }
}

// MARK: - RAG Status (view-layer)

extension UnifiedRepository {
  /// Simplified RAG status for the unified repo card.
  enum RAGStatus: Hashable, Sendable {
    case notIndexed
    case indexing
    case indexed
    case analyzing(progress: Double)
    case analyzed
    case needsUpdate
    case stale

    var displayName: String {
      switch self {
      case .notIndexed: return "Not Indexed"
      case .indexing: return "Indexing…"
      case .indexed: return "Indexed"
      case .analyzing(let p): return "Analyzing \(Int(p * 100))%"
      case .analyzed: return "Analyzed"
      case .needsUpdate: return "Needs Update"
      case .stale: return "Stale"
      }
    }

    var systemImage: String {
      switch self {
      case .notIndexed: return "magnifyingglass.circle"
      case .indexing: return "arrow.triangle.2.circlepath"
      case .indexed: return "checkmark.circle"
      case .analyzing: return "gearshape.2"
      case .analyzed: return "checkmark.seal"
      case .needsUpdate: return "arrow.triangle.2.circlepath"
      case .stale: return "exclamationmark.triangle"
      }
    }
  }
}

// MARK: - Pull Status (view-layer)

extension UnifiedRepository {
  /// Auto-pull status for the unified repo card.
  enum PullStatus: Hashable, Sendable {
    case disabled
    case idle(lastPull: Date?)
    case pulling
    case upToDate
    case updated(sha: String)
    case error(message: String)

    var displayName: String {
      switch self {
      case .disabled: return "Disabled"
      case .idle: return "Scheduled"
      case .pulling: return "Pulling…"
      case .upToDate: return "Up to Date"
      case .updated: return "Updated"
      case .error: return "Error"
      }
    }

    var systemImage: String {
      switch self {
      case .disabled: return "pause.circle"
      case .idle: return "clock"
      case .pulling: return "arrow.down.circle"
      case .upToDate: return "checkmark.circle"
      case .updated: return "arrow.down.circle.fill"
      case .error: return "exclamationmark.triangle"
      }
    }
  }
}

// MARK: - Convenience Computed Properties

extension UnifiedRepository {

  /// Whether this repo has RAG indexing data.
  var isRAGIndexed: Bool {
    if let rag = ragStatus, rag != .notIndexed { return true }
    return false
  }

  /// A single-line status summary for the repo card.
  var statusSummary: String {
    var parts: [String] = []

    if isSubPackage {
      parts.append("Package")
    } else if isClonedLocally {
      parts.append("Local")
    }

    if let rag = ragStatus, rag != .notIndexed {
      parts.append("RAG: \(rag.displayName)")
    }

    if activeChainCount > 0 {
      parts.append("\(activeChainCount) chain\(activeChainCount == 1 ? "" : "s")")
    }

    if worktreeCount > 0 {
      parts.append("\(worktreeCount) worktree\(worktreeCount == 1 ? "" : "s")")
    }

    if let pull = pullStatus {
      switch pull {
      case .error: parts.append("Pull error")
      case .pulling: parts.append("Pulling")
      default: break
      }
    }

    return parts.isEmpty ? "Remote only" : parts.joined(separator: " · ")
  }

  /// Whether this repo has any active work (chains, worktrees, pulling).
  var hasActiveWork: Bool {
    activeChainCount > 0 || worktreeCount > 0 || pullStatus == .pulling
  }

  /// Sort priority: repos with active work first, then by last activity.
  var sortPriority: Int {
    if activeChainCount > 0 { return 3 }
    if worktreeCount > 0 { return 2 }
    if isTracked { return 1 }
    return 0
  }
}
