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

/// Tracks a worktree created through the app.
@Model
final class TrackedWorktree {
  var id: UUID = UUID()
  var repositoryId: UUID = UUID()
  var localPath: String = ""
  var branch: String = ""
  var source: String = "manual"
  var createdAt: Date = Date()
  var purpose: String?
  var linkedPRNumber: Int?
  var linkedPRRepo: String?
  
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

/// App settings for THIS device only.
@Model
final class DeviceSettings {
  var id: UUID = UUID()
  var deviceName: String = "Unknown"
  var currentTool: String = "github"
  var selectedRepositoryId: UUID?
  var sidebarWidth: Double?
  var lastUsedAt: Date = Date()
  
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
