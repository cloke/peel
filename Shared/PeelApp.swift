//
//  PeelApp.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//  Updated for SwiftData on 1/7/26
//

import Foundation
import SwiftUI
import SwiftData
import OAuthSwift

@main
struct PeelApp: App {
  @Environment(\.openURL) var openURL
  
  /// SwiftData model container
  /// To enable iCloud later, change cloudKitDatabase to .automatic
  var sharedModelContainer: ModelContainer = {
    let schema = Schema([
      // Synced to iCloud (when enabled)
      SyncedRepository.self,
      GitHubFavorite.self,
      RecentPullRequest.self,
      // Device-local only
      LocalRepositoryPath.self,
      TrackedWorktree.self,
      DeviceSettings.self,
    ])
    
    let modelConfiguration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: false,
      cloudKitDatabase: .automatic  // Change to .automatic when ready for iCloud
    )
    
    do {
      return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
      fatalError("Could not create ModelContainer: \(error)")
    }
  }()
  
  var body: some Scene {
    WindowGroup {
      ContentView()
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
          OAuthSwift.handle(url: url)
        }
    }
    .modelContainer(sharedModelContainer)
    
#if os(macOS)
    Settings {
      SettingsView()
    }
    .modelContainer(sharedModelContainer)
#endif
  }
}

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
  var lastAccessedAt: Date = Date()
  var isValid: Bool = true
  
  init(repositoryId: UUID, localPath: String) {
    self.id = UUID()
    self.repositoryId = repositoryId
    self.localPath = localPath
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
  var createdAt: Date = Date()
  var purpose: String?
  var linkedPRNumber: Int?
  var linkedPRRepo: String?
  
  init(repositoryId: UUID, localPath: String, branch: String) {
    self.id = UUID()
    self.repositoryId = repositoryId
    self.localPath = localPath
    self.branch = branch
    self.createdAt = Date()
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
// MARK: - Data Service

/// Service for managing app data with SwiftData
@MainActor
@Observable
final class DataService {
  private let modelContext: ModelContext
  
  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }
  
  // MARK: - Device Settings
  
  func getDeviceSettings() -> DeviceSettings {
    let descriptor = FetchDescriptor<DeviceSettings>()
    if let existing = try? modelContext.fetch(descriptor).first {
      return existing
    }
    let settings = DeviceSettings()
    modelContext.insert(settings)
    try? modelContext.save()
    return settings
  }
  
  func setCurrentTool(_ tool: String) {
    let settings = getDeviceSettings()
    settings.currentTool = tool
    settings.touch()
    try? modelContext.save()
  }
  
  // MARK: - Repositories
  
  func getAllRepositories() -> [SyncedRepository] {
    let descriptor = FetchDescriptor<SyncedRepository>(sortBy: [SortDescriptor(\.name)])
    return (try? modelContext.fetch(descriptor)) ?? []
  }
  
  @discardableResult
  func addRepository(name: String, localPath: String, remoteURL: String? = nil) -> SyncedRepository {
    let repo = SyncedRepository(name: name, remoteURL: remoteURL)
    modelContext.insert(repo)
    
    let pathMapping = LocalRepositoryPath(repositoryId: repo.id, localPath: localPath)
    modelContext.insert(pathMapping)
    
    try? modelContext.save()
    return repo
  }
  
  func getLocalPath(for repository: SyncedRepository) -> LocalRepositoryPath? {
    let repoId = repository.id
    let descriptor = FetchDescriptor<LocalRepositoryPath>(
      predicate: #Predicate { $0.repositoryId == repoId }
    )
    return try? modelContext.fetch(descriptor).first
  }
  
  func deleteRepository(_ repository: SyncedRepository) {
    if let pathMapping = getLocalPath(for: repository) {
      modelContext.delete(pathMapping)
    }
    modelContext.delete(repository)
    try? modelContext.save()
  }
  
  func toggleFavorite(_ repository: SyncedRepository) {
    repository.isFavorite.toggle()
    repository.touch()
    try? modelContext.save()
  }
  
  func setSelectedRepository(_ repository: SyncedRepository?) {
    let settings = getDeviceSettings()
    settings.selectedRepositoryId = repository?.id
    settings.touch()
    try? modelContext.save()
  }
  
  func getSelectedRepository() -> SyncedRepository? {
    guard let selectedId = getDeviceSettings().selectedRepositoryId else { return nil }
    let descriptor = FetchDescriptor<SyncedRepository>(
      predicate: #Predicate { $0.id == selectedId }
    )
    return try? modelContext.fetch(descriptor).first
  }
  
  // MARK: - GitHub Favorites
  
  @discardableResult
  func addGitHubFavorite(githubRepoId: Int, fullName: String, ownerLogin: String, repoName: String, htmlURL: String?) -> GitHubFavorite {
    let descriptor = FetchDescriptor<GitHubFavorite>(
      predicate: #Predicate { $0.githubRepoId == githubRepoId }
    )
    if let existing = try? modelContext.fetch(descriptor).first {
      return existing
    }
    
    let favorite = GitHubFavorite(githubRepoId: githubRepoId, fullName: fullName, ownerLogin: ownerLogin, repoName: repoName, htmlURL: htmlURL)
    modelContext.insert(favorite)
    try? modelContext.save()
    return favorite
  }
  
  func getGitHubFavorites() -> [GitHubFavorite] {
    let descriptor = FetchDescriptor<GitHubFavorite>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
    return (try? modelContext.fetch(descriptor)) ?? []
  }
  
  func isGitHubFavorite(githubRepoId: Int) -> Bool {
    let descriptor = FetchDescriptor<GitHubFavorite>(
      predicate: #Predicate { $0.githubRepoId == githubRepoId }
    )
    return (try? modelContext.fetchCount(descriptor)) ?? 0 > 0
  }
  
  func removeGitHubFavorite(githubRepoId: Int) {
    let descriptor = FetchDescriptor<GitHubFavorite>(
      predicate: #Predicate { $0.githubRepoId == githubRepoId }
    )
    if let favorite = try? modelContext.fetch(descriptor).first {
      modelContext.delete(favorite)
      try? modelContext.save()
    }
  }
  
  // MARK: - Recent PRs
  
  @discardableResult
  func recordPRView(githubPRId: Int, prNumber: Int, title: String, repoFullName: String, state: String, htmlURL: String?) -> RecentPullRequest {
    let descriptor = FetchDescriptor<RecentPullRequest>(
      predicate: #Predicate { $0.githubPRId == githubPRId }
    )
    
    if let existing = try? modelContext.fetch(descriptor).first {
      existing.title = title
      existing.state = state
      existing.markViewed()
      try? modelContext.save()
      return existing
    }
    
    let recent = RecentPullRequest(githubPRId: githubPRId, prNumber: prNumber, title: title, repoFullName: repoFullName, state: state, htmlURL: htmlURL)
    modelContext.insert(recent)
    try? modelContext.save()
    return recent
  }
  
  func getRecentPRs(limit: Int = 20) -> [RecentPullRequest] {
    var descriptor = FetchDescriptor<RecentPullRequest>(sortBy: [SortDescriptor(\.viewedAt, order: .reverse)])
    descriptor.fetchLimit = limit
    return (try? modelContext.fetch(descriptor)) ?? []
  }
}

// MARK: - GitHub Data Provider

import Github

/// Provides GitHub favorites and recent PRs backed by SwiftData
@MainActor
@Observable
final class GitHubDataProvider: GitHubFavoritesProvider, RecentPRsProvider {
  private let modelContext: ModelContext
  
  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }
  
  // MARK: - GitHubFavoritesProvider
  
  func isFavorite(repoId: Int) -> Bool {
    let descriptor = FetchDescriptor<GitHubFavorite>(
      predicate: #Predicate { $0.githubRepoId == repoId }
    )
    return (try? modelContext.fetchCount(descriptor)) ?? 0 > 0
  }
  
  func addFavorite(repo: Github.Repository) {
    let repoId = repo.id
    let descriptor = FetchDescriptor<GitHubFavorite>(
      predicate: #Predicate { $0.githubRepoId == repoId }
    )
    if (try? modelContext.fetch(descriptor).first) != nil {
      return
    }
    
    let favorite = GitHubFavorite(
      githubRepoId: repo.id,
      fullName: repo.full_name ?? repo.name,
      ownerLogin: repo.owner?.login ?? "unknown",
      repoName: repo.name,
      htmlURL: repo.html_url
    )
    modelContext.insert(favorite)
    try? modelContext.save()
  }
  
  func removeFavorite(repoId: Int) {
    let descriptor = FetchDescriptor<GitHubFavorite>(
      predicate: #Predicate { $0.githubRepoId == repoId }
    )
    if let favorite = try? modelContext.fetch(descriptor).first {
      modelContext.delete(favorite)
      try? modelContext.save()
    }
  }
  
  func getFavorites() -> [FavoriteRepository] {
    let descriptor = FetchDescriptor<GitHubFavorite>(
      sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
    )
    let favorites = (try? modelContext.fetch(descriptor)) ?? []
    return favorites.map { fav in
      FavoriteRepository(
        id: fav.githubRepoId,
        fullName: fav.fullName,
        ownerLogin: fav.ownerLogin,
        repoName: fav.repoName,
        htmlURL: fav.htmlURL,
        addedAt: fav.addedAt
      )
    }
  }
  
  // MARK: - RecentPRsProvider
  
  func recordView(pr: Github.PullRequest, repo: Github.Repository) {
    let prId = pr.id
    let descriptor = FetchDescriptor<RecentPullRequest>(
      predicate: #Predicate { $0.githubPRId == prId }
    )
    
    if let existing = try? modelContext.fetch(descriptor).first {
      existing.title = pr.title ?? "Untitled"
      existing.state = pr.state ?? "unknown"
      existing.markViewed()
      try? modelContext.save()
      return
    }
    
    let recent = RecentPullRequest(
      githubPRId: pr.id,
      prNumber: pr.number,
      title: pr.title ?? "Untitled",
      repoFullName: repo.full_name ?? repo.name,
      state: pr.state ?? "unknown",
      htmlURL: pr.html_url
    )
    modelContext.insert(recent)
    cleanupOldPRs()
    try? modelContext.save()
  }
  
  func getRecentPRs() -> [RecentPRInfo] {
    var descriptor = FetchDescriptor<RecentPullRequest>(
      sortBy: [SortDescriptor(\.viewedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 20
    let recents = (try? modelContext.fetch(descriptor)) ?? []
    return recents.map { recent in
      RecentPRInfo(
        id: recent.githubPRId,
        prNumber: recent.prNumber,
        title: recent.title,
        repoFullName: recent.repoFullName,
        state: recent.state,
        htmlURL: recent.htmlURL,
        viewedAt: recent.viewedAt
      )
    }
  }
  
  private func cleanupOldPRs() {
    let descriptor = FetchDescriptor<RecentPullRequest>(
      sortBy: [SortDescriptor(\.viewedAt, order: .reverse)]
    )
    if let all = try? modelContext.fetch(descriptor), all.count > 50 {
      for old in all.dropFirst(50) {
        modelContext.delete(old)
      }
    }
  }
}
