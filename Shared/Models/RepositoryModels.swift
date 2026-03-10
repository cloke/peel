//
//  RepositoryModels.swift
//  Peel
//
//  Repository-related SwiftData models.
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData

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
  /// When non-nil the user (or auto-refresh) dismissed this PR from "Needs Attention".
  /// CloudKit-safe: once set, should never be cleared by other devices.
  var dismissedAt: Date?
  
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

// MARK: - Device-Local Models

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

/// How a tracked repo handles RAG indexing after a pull.
enum TrackedRepoSyncMode: String, Codable, CaseIterable {
  /// Pull code and rebuild the RAG index locally.
  case pullAndRebuild = "pull_and_rebuild"
  /// Pull code and sync the RAG index from a swarm crown/brain node.
  case pullAndSyncIndex = "pull_and_sync_index"

  var displayName: String {
    switch self {
    case .pullAndRebuild: return "Pull & Rebuild"
    case .pullAndSyncIndex: return "Pull & Sync Index"
    }
  }

  var description: String {
    switch self {
    case .pullAndRebuild: return "Pulls code and rebuilds the RAG index locally"
    case .pullAndSyncIndex: return "Pulls code and syncs the RAG index from a crown node"
    }
  }

  var systemImage: String {
    switch self {
    case .pullAndRebuild: return "hammer.circle"
    case .pullAndSyncIndex: return "arrow.triangle.swap"
    }
  }
}

/// A remote repo marked as "primary" for automatic periodic pulling.
/// Synced via CloudKit so all devices share the same tracking configuration.
/// Device-specific state (localPath, pull results) is in TrackedRepoDeviceState.
@Model
final class TrackedRemoteRepo {
  var id: UUID = UUID()

  /// Normalized remote URL (e.g., "github.com/org/repo")
  var remoteURL: String = ""

  /// Display name for this tracked repo
  var name: String = ""

  /// The git remote name to pull from (default: "origin")
  var remoteName: String = "origin"

  /// The branch to track (default: "main")
  var branch: String = "main"

  /// Pull interval in seconds (default: 3600 = 1 hour)
  var pullIntervalSeconds: Int = 3600

  /// Whether auto-pull is enabled for this repo
  var isEnabled: Bool = true

  /// Whether to re-index the RAG after pulling
  var reindexAfterPull: Bool = true

  /// How this repo handles RAG indexing: rebuild locally or sync from crown.
  /// Stored as raw string for CloudKit compatibility.
  var syncModeRaw: String = TrackedRepoSyncMode.pullAndRebuild.rawValue

  /// Typed accessor for syncMode.
  var syncMode: TrackedRepoSyncMode {
    get { TrackedRepoSyncMode(rawValue: syncModeRaw) ?? .pullAndRebuild }
    set { syncModeRaw = newValue.rawValue }
  }

  /// When this tracking was created
  var createdAt: Date = Date()

  /// When this tracking was last modified
  var modifiedAt: Date = Date()

  init(
    remoteURL: String,
    name: String,
    branch: String = "main",
    remoteName: String = "origin",
    pullIntervalSeconds: Int = 3600,
    reindexAfterPull: Bool = true,
    syncMode: TrackedRepoSyncMode = .pullAndRebuild
  ) {
    self.id = UUID()
    self.remoteURL = remoteURL
    self.name = name
    self.branch = branch
    self.remoteName = remoteName
    self.pullIntervalSeconds = pullIntervalSeconds
    self.reindexAfterPull = reindexAfterPull
    self.syncModeRaw = syncMode.rawValue
    self.isEnabled = true
    self.createdAt = Date()
    self.modifiedAt = Date()
  }

  func touch() {
    modifiedAt = Date()
  }
}

/// Device-local state for a tracked repo. Not synced via CloudKit.
/// Each machine maintains its own local path, pull history, and error state.
@Model
final class TrackedRepoDeviceState {
  var id: UUID = UUID()

  /// The TrackedRemoteRepo.id this state belongs to
  var trackedRepoId: UUID = UUID()

  /// Local path on this device where the repo is cloned
  var localPath: String = ""

  /// Last time a pull was attempted on this device
  var lastPullAt: Date?

  /// Last successful pull result ("up-to-date", "updated", etc.)
  var lastPullResult: String?

  /// Last error message if pull failed
  var lastPullError: String?

  init(trackedRepoId: UUID, localPath: String) {
    self.id = UUID()
    self.trackedRepoId = trackedRepoId
    self.localPath = localPath
  }

  /// Whether a pull is due based on the interval
  func isPullDue(interval: Int) -> Bool {
    guard let lastPull = lastPullAt else { return true }
    return Date().timeIntervalSince(lastPull) >= Double(interval)
  }
}
