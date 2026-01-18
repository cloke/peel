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
  @State private var mcpServer = MCPServerService()
  
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
      MCPRunRecord.self,
      MCPRunResultRecord.self,
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
        .environment(mcpServer)
    }
    .modelContainer(sharedModelContainer)
    
#if os(macOS)
    Settings {
      SettingsView()
        .environment(mcpServer)
    }
    .modelContainer(sharedModelContainer)
#endif
  }
}

// MARK: - SwiftData Models
// Models live in Shared/Models/SwiftDataModels.swift
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

  // MARK: - MCP Run History

  @discardableResult
  func recordMCPRun(
    chainId: String? = nil,
    templateId: String?,
    templateName: String,
    prompt: String,
    workingDirectory: String?,
    implementerBranches: [String] = [],
    implementerWorkspacePaths: [String] = [],
    success: Bool,
    errorMessage: String?,
    mergeConflictsCount: Int,
    resultCount: Int,
    validationStatus: String? = nil,
    validationReasons: [String] = [],
    noWorkReason: String? = nil
  ) -> MCPRunRecord {
    let record = MCPRunRecord(
      chainId: chainId ?? "",
      templateId: templateId ?? "",
      templateName: templateName,
      prompt: prompt,
      workingDirectory: workingDirectory,
      implementerBranches: implementerBranches.joined(separator: "\n"),
      implementerWorkspacePaths: implementerWorkspacePaths.joined(separator: "\n"),
      success: success,
      errorMessage: errorMessage,
      noWorkReason: noWorkReason,
      mergeConflictsCount: mergeConflictsCount,
      resultCount: resultCount,
      validationStatus: validationStatus,
      validationReasons: validationReasons.isEmpty ? nil : validationReasons.joined(separator: "\n"),
      createdAt: Date()
    )
    modelContext.insert(record)
    cleanupOldMCPRuns()
    try? modelContext.save()
    return record
  }

  func getRecentMCPRuns(limit: Int = 20) -> [MCPRunRecord] {
    var descriptor = FetchDescriptor<MCPRunRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    descriptor.fetchLimit = limit
    return (try? modelContext.fetch(descriptor)) ?? []
  }

  func getMCPRun(forChainId chainId: String) -> MCPRunRecord? {
    guard !chainId.isEmpty else { return nil }
    let descriptor = FetchDescriptor<MCPRunRecord>(
      predicate: #Predicate { $0.chainId == chainId }
    )
    return try? modelContext.fetch(descriptor).first
  }

  // MARK: - MCP Run Results

  @discardableResult
  func recordMCPRunResult(
    chainId: String,
    agentId: String,
    agentName: String,
    model: String,
    prompt: String,
    output: String,
    premiumCost: Double,
    reviewVerdict: String?
  ) -> MCPRunResultRecord {
    let record = MCPRunResultRecord(
      chainId: chainId,
      agentId: agentId,
      agentName: agentName,
      model: model,
      prompt: prompt,
      output: output,
      premiumCost: premiumCost,
      reviewVerdict: reviewVerdict,
      createdAt: Date()
    )
    modelContext.insert(record)
    try? modelContext.save()
    return record
  }

  func getMCPRunResults(chainId: String) -> [MCPRunResultRecord] {
    guard !chainId.isEmpty else { return [] }
    let descriptor = FetchDescriptor<MCPRunResultRecord>(
      predicate: #Predicate { $0.chainId == chainId },
      sortBy: [SortDescriptor(\.createdAt, order: .forward)]
    )
    return (try? modelContext.fetch(descriptor)) ?? []
  }

  private func cleanupOldMCPRuns(keeping limit: Int = 100) {
    let descriptor = FetchDescriptor<MCPRunRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    guard let records = try? modelContext.fetch(descriptor), records.count > limit else {
      return
    }
    let toDelete = records.suffix(from: limit)
    for record in toDelete {
      modelContext.delete(record)
    }
  }

  // MARK: - Tracked Worktrees

  func getRepositoryId(forLocalPath path: String) -> UUID? {
    let descriptor = FetchDescriptor<LocalRepositoryPath>(
      predicate: #Predicate { $0.localPath == path }
    )
    return try? modelContext.fetch(descriptor).first?.repositoryId
  }

  func getTrackedWorktree(localPath: String) -> TrackedWorktree? {
    let descriptor = FetchDescriptor<TrackedWorktree>(
      predicate: #Predicate { $0.localPath == localPath }
    )
    return try? modelContext.fetch(descriptor).first
  }

  @discardableResult
  func upsertTrackedWorktree(
    repositoryId: UUID?,
    localPath: String,
    branch: String,
    source: String,
    purpose: String? = nil,
    linkedPRNumber: Int? = nil,
    linkedPRRepo: String? = nil
  ) -> TrackedWorktree {
    if let existing = getTrackedWorktree(localPath: localPath) {
      existing.repositoryId = repositoryId ?? existing.repositoryId
      existing.branch = branch
      existing.source = source
      existing.purpose = purpose ?? existing.purpose
      existing.linkedPRNumber = linkedPRNumber ?? existing.linkedPRNumber
      existing.linkedPRRepo = linkedPRRepo ?? existing.linkedPRRepo
      try? modelContext.save()
      return existing
    }
    
    let resolvedId = repositoryId ?? UUID()
    let tracked = TrackedWorktree(
      repositoryId: resolvedId,
      localPath: localPath,
      branch: branch,
      source: source,
      purpose: purpose
    )
    tracked.linkedPRNumber = linkedPRNumber
    tracked.linkedPRRepo = linkedPRRepo
    modelContext.insert(tracked)
    try? modelContext.save()
    return tracked
  }

  func removeTrackedWorktree(localPath: String) {
    if let existing = getTrackedWorktree(localPath: localPath) {
      modelContext.delete(existing)
      try? modelContext.save()
    }
  }

  func getTrackedWorktrees() -> [TrackedWorktree] {
    let descriptor = FetchDescriptor<TrackedWorktree>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    return (try? modelContext.fetch(descriptor)) ?? []
  }
}
