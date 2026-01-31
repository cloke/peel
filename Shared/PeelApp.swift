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
import AppKit

@main
struct PeelApp: App {
  @Environment(\.openURL) var openURL
  @State private var vmIsolationService = VMIsolationService()
  @State private var mcpServer: MCPServerService
  @State private var workerModeActive = false

  init() {
    // Configure Firebase first (before other services)
    FirebaseService.shared.configure()
    
    let vmService = VMIsolationService()
    _vmIsolationService = State(initialValue: vmService)
    _mcpServer = State(initialValue: MCPServerService(vmIsolationService: vmService))
    
    // Check for worker mode (--worker flag)
    if WorkerMode.shared.shouldRunInWorkerMode {
      _workerModeActive = State(initialValue: true)
      Task { @MainActor in
        do {
          try WorkerMode.shared.start()
        } catch {
          print("Failed to start worker mode: \(error)")
        }
      }
    }
  }
  
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
      ParallelRunSnapshot.self,
      RepoGuidanceSkill.self,
      CIFailureRecord.self,
    ])
    
    let modelConfiguration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: false,
      cloudKitDatabase: .automatic  // Change to .automatic when ready for iCloud
    )
    
    do {
      return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
      // Log error and attempt recovery with in-memory fallback
      print("⚠️ Failed to create persistent ModelContainer: \(error)")
      print("⚠️ Falling back to in-memory storage. Data will not persist.")
      
      let fallbackConfig = ModelConfiguration(
        schema: schema,
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
      )
      
      do {
        return try ModelContainer(for: schema, configurations: [fallbackConfig])
      } catch {
        // If even in-memory fails, we have a schema problem - this is a programming error
        fatalError("Could not create ModelContainer even with in-memory fallback: \(error)")
      }
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
        .environment(vmIsolationService)
    }
    .modelContainer(sharedModelContainer)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Peel") {
          showAboutPanel()
        }
      }
      CommandGroup(replacing: .help) {
        Button("Peel Help") {
          openHelpWindow()
        }
        .keyboardShortcut("?", modifiers: .command)
      }
    }

    Settings {
      SettingsView()
        .environment(mcpServer)
        .environment(vmIsolationService)
    }
    .modelContainer(sharedModelContainer)
  }

  private func showAboutPanel() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let versionText = build.isEmpty ? version : "\(version) (\(build))"

    let credits = NSMutableAttributedString(
      string: "Peel keeps GitHub, git, and Homebrew close at hand so you can stay in flow.\n\nSupport development: "
    )
    let donateLink = NSAttributedString(
      string: "github.com/sponsors/crunchybananas",
      attributes: [
        .link: URL(string: "https://github.com/sponsors/crunchybananas")!,
        .foregroundColor: NSColor.linkColor
      ]
    )
    credits.append(donateLink)

    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Peel",
      .applicationVersion: versionText,
      .credits: credits
    ])
    NSApp.activate(ignoringOtherApps: true)
  }
  
  private func openHelpWindow() {
    // Create a new window for the help view
    let helpView = HelpView()
    let hostingController = NSHostingController(rootView: helpView)
    
    let window = NSWindow(contentViewController: hostingController)
    window.title = "Peel Help"
    window.setContentSize(NSSize(width: 900, height: 700))
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.center()
    window.makeKeyAndOrderFront(nil)
    
    // Keep a reference to prevent deallocation
    NSApp.activate(ignoringOtherApps: true)
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
    screenshotPaths: [String] = [],
    success: Bool,
    errorMessage: String?,
    mergeConflictsCount: Int,
    mergeConflicts: [String] = [],
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
      screenshotPaths: screenshotPaths.joined(separator: "\n"),
      success: success,
      errorMessage: errorMessage,
      noWorkReason: noWorkReason,
      mergeConflictsCount: mergeConflictsCount,
      mergeConflicts: mergeConflicts.joined(separator: "\n"),
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

  func clearMCPRunHistory() {
    let runDescriptor = FetchDescriptor<MCPRunRecord>()
    if let runs = try? modelContext.fetch(runDescriptor) {
      for run in runs {
        modelContext.delete(run)
      }
    }

    let resultDescriptor = FetchDescriptor<MCPRunResultRecord>()
    if let results = try? modelContext.fetch(resultDescriptor) {
      for result in results {
        modelContext.delete(result)
      }
    }

    let snapshotDescriptor = FetchDescriptor<ParallelRunSnapshot>()
    if let snapshots = try? modelContext.fetch(snapshotDescriptor) {
      for snapshot in snapshots {
        modelContext.delete(snapshot)
      }
    }

    try? modelContext.save()
  }

  // MARK: - Parallel Run Snapshots

  @discardableResult
  func recordParallelRunSnapshot(run: ParallelWorktreeRun) -> ParallelRunSnapshot {
    let snapshot = ParallelRunSnapshot(
      runId: run.id.uuidString,
      name: run.name,
      projectPath: run.projectPath,
      baseBranch: run.baseBranch,
      targetBranch: run.targetBranch,
      templateName: run.templateName,
      status: run.status.displayName,
      progress: run.progress,
      executionCount: run.executions.count,
      pendingReviewCount: run.pendingReviewCount,
      readyToMergeCount: run.readyToMergeCount,
      mergedCount: run.mergedCount,
      rejectedCount: run.rejectedCount,
      failedCount: run.failedCount,
      hungCount: run.hungExecutionCount,
      requireReviewGate: run.requireReviewGate,
      autoMergeOnApproval: run.autoMergeOnApproval,
      operatorGuidanceCount: run.operatorGuidance.count,
      executionsJSON: encodeParallelExecutions(run),
      createdAt: run.createdAt,
      updatedAt: Date(),
      lastUpdatedAt: run.lastUpdatedAt
    )
    modelContext.insert(snapshot)
    cleanupOldParallelRunSnapshots()
    try? modelContext.save()
    return snapshot
  }

  func getLatestParallelRunSnapshot(runId: String) -> ParallelRunSnapshot? {
    guard !runId.isEmpty else { return nil }
    let descriptor = FetchDescriptor<ParallelRunSnapshot>(
      predicate: #Predicate { $0.runId == runId },
      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
    )
    return try? modelContext.fetch(descriptor).first
  }

  func getRecentParallelRunSnapshots(limit: Int = 10) -> [ParallelRunSnapshot] {
    var descriptor = FetchDescriptor<ParallelRunSnapshot>(
      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    return (try? modelContext.fetch(descriptor)) ?? []
  }

  private func cleanupOldParallelRunSnapshots(keeping limit: Int = 200) {
    let descriptor = FetchDescriptor<ParallelRunSnapshot>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    guard let records = try? modelContext.fetch(descriptor), records.count > limit else {
      return
    }
    for record in records.suffix(from: limit) {
      modelContext.delete(record)
    }
    try? modelContext.save()
  }

  private func encodeParallelExecutions(_ run: ParallelWorktreeRun) -> String {
    let formatter = ISO8601DateFormatter()
    let payload = run.executions.map { execution in
      var result: [String: Any] = [
        "id": execution.id.uuidString,
        "taskTitle": execution.task.title,
        "taskDescription": execution.task.description,
        "status": execution.status.displayName,
        "filesChanged": execution.filesChanged,
        "insertions": execution.insertions,
        "deletions": execution.deletions,
        "mergeConflictCount": execution.mergeConflicts.count,
        "guidanceCount": execution.operatorGuidance.count
      ]
      if let chainId = execution.chainId {
        result["chainId"] = chainId.uuidString
      }
      if let worktreePath = execution.worktreePath {
        result["worktreePath"] = worktreePath
      }
      if let branchName = execution.branchName {
        result["branchName"] = branchName
      }
      result["lastStatusChangeAt"] = formatter.string(from: execution.lastStatusChangeAt)
      if let startedAt = execution.startedAt {
        result["startedAt"] = formatter.string(from: startedAt)
      }
      if let completedAt = execution.completedAt {
        result["completedAt"] = formatter.string(from: completedAt)
      }
      if !execution.mergeConflicts.isEmpty {
        result["mergeConflicts"] = execution.mergeConflicts
      }
      return result
    }

    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
          let json = String(data: data, encoding: .utf8) else {
      return ""
    }
    return json
  }

  // MARK: - Repo Guidance Skills

  @discardableResult
  func addRepoGuidanceSkill(
    repoPath: String,
    title: String,
    body: String,
    source: String = "manual",
    tags: String = "",
    priority: Int = 0,
    isActive: Bool = true
  ) -> RepoGuidanceSkill {
    let trimmedRepo = repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedTags = tags.trimmingCharacters(in: .whitespacesAndNewlines)
    let skill = RepoGuidanceSkill(
      repoPath: trimmedRepo,
      title: trimmedTitle.isEmpty ? "Skill" : trimmedTitle,
      body: trimmedBody,
      source: trimmedSource.isEmpty ? "manual" : trimmedSource,
      tags: trimmedTags,
      priority: priority,
      isActive: isActive,
      appliedCount: 0,
      createdAt: Date(),
      updatedAt: Date(),
      lastAppliedAt: nil
    )
    modelContext.insert(skill)
    try? modelContext.save()
    return skill
  }

  func updateRepoGuidanceSkill(
    id: UUID,
    repoPath: String? = nil,
    title: String? = nil,
    body: String? = nil,
    source: String? = nil,
    tags: String? = nil,
    priority: Int? = nil,
    isActive: Bool? = nil
  ) -> RepoGuidanceSkill? {
    let descriptor = FetchDescriptor<RepoGuidanceSkill>(predicate: #Predicate { $0.id == id })
    guard let skill = try? modelContext.fetch(descriptor).first else { return nil }
    if let repoPath {
      let trimmed = repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        skill.repoPath = trimmed
      }
    }
    if let title {
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        skill.title = trimmed
      }
    }
    if let body {
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        skill.body = trimmed
      }
    }
    if let source {
      let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        skill.source = trimmed
      }
    }
    if let tags {
      skill.tags = tags.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let priority {
      skill.priority = priority
    }
    if let isActive {
      skill.isActive = isActive
    }
    skill.updatedAt = Date()
    try? modelContext.save()
    return skill
  }

  @discardableResult
  func deleteRepoGuidanceSkill(id: UUID) -> Bool {
    let descriptor = FetchDescriptor<RepoGuidanceSkill>(predicate: #Predicate { $0.id == id })
    guard let skill = try? modelContext.fetch(descriptor).first else { return false }
    modelContext.delete(skill)
    try? modelContext.save()
    return true
  }

  func listRepoGuidanceSkills(
    repoPath: String? = nil,
    includeInactive: Bool = false,
    limit: Int? = nil
  ) -> [RepoGuidanceSkill] {
    let trimmedRepo = repoPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    let predicate: Predicate<RepoGuidanceSkill>?
    if let trimmedRepo, !trimmedRepo.isEmpty {
      if includeInactive {
        predicate = #Predicate { $0.repoPath == trimmedRepo }
      } else {
        predicate = #Predicate { $0.repoPath == trimmedRepo && $0.isActive }
      }
    } else if includeInactive {
      predicate = nil
    } else {
      predicate = #Predicate { $0.isActive }
    }

    let sort = [
      SortDescriptor(\RepoGuidanceSkill.priority, order: .reverse),
      SortDescriptor(\RepoGuidanceSkill.updatedAt, order: .reverse)
    ]

    let descriptor: FetchDescriptor<RepoGuidanceSkill>
    if let predicate {
      descriptor = FetchDescriptor(predicate: predicate, sortBy: sort)
    } else {
      descriptor = FetchDescriptor(sortBy: sort)
    }
    if let limit {
      var limited = descriptor
      limited.fetchLimit = limit
      return (try? modelContext.fetch(limited)) ?? []
    }
    return (try? modelContext.fetch(descriptor)) ?? []
  }

  func repoGuidanceSkillsBlock(repoPath: String, limit: Int = 6) -> (String, [RepoGuidanceSkill])? {
    let skills = listRepoGuidanceSkills(repoPath: repoPath, includeInactive: false, limit: limit)
    guard !skills.isEmpty else { return nil }
    let body = skills.enumerated().map { index, skill in
      let title = skill.title.isEmpty ? "Skill \(index + 1)" : skill.title
      let tags = skill.tags.trimmingCharacters(in: .whitespacesAndNewlines)
      let source = skill.source.trimmingCharacters(in: .whitespacesAndNewlines)
      let meta = [
        tags.isEmpty ? nil : "Tags: \(tags)",
        source.isEmpty ? nil : "Source: \(source)"
      ].compactMap { $0 }.joined(separator: " · ")
      let metaLine = meta.isEmpty ? "" : "\n\(meta)"
      return "- \(title)\(metaLine)\n\n\(skill.body)"
    }.joined(separator: "\n\n")
    return ("## Repo Skills\n\n\(body)", skills)
  }

  func repoGuidanceSkillsBlockAndMarkApplied(repoPath: String, limit: Int = 6) -> String? {
    let skills = listRepoGuidanceSkills(repoPath: repoPath, includeInactive: false, limit: limit)
    guard !skills.isEmpty else { return nil }
    let body = skills.enumerated().map { index, skill in
      let title = skill.title.isEmpty ? "Skill \(index + 1)" : skill.title
      let tags = skill.tags.trimmingCharacters(in: .whitespacesAndNewlines)
      let source = skill.source.trimmingCharacters(in: .whitespacesAndNewlines)
      let meta = [
        tags.isEmpty ? nil : "Tags: \(tags)",
        source.isEmpty ? nil : "Source: \(source)"
      ].compactMap { $0 }.joined(separator: " · ")
      let metaLine = meta.isEmpty ? "" : "\n\(meta)"
      return "- \(title)\(metaLine)\n\n\(skill.body)"
    }.joined(separator: "\n\n")
    markRepoGuidanceSkillsApplied(skills)
    return "## Repo Skills\n\n\(body)"
  }

  func markRepoGuidanceSkillsApplied(_ skills: [RepoGuidanceSkill]) {
    guard !skills.isEmpty else { return }
    let now = Date()
    for skill in skills {
      skill.appliedCount += 1
      skill.lastAppliedAt = now
      skill.updatedAt = now
    }
    try? modelContext.save()
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

  /// Remove duplicate TrackedWorktree entries (keep newest by createdAt for each localPath)
  func deduplicateTrackedWorktrees() {
    let all = getTrackedWorktrees() // Already sorted by createdAt descending (newest first)
    var seenPaths = Set<String>()
    var toDelete: [TrackedWorktree] = []
    
    for worktree in all {
      if seenPaths.contains(worktree.localPath) {
        toDelete.append(worktree)
      } else {
        seenPaths.insert(worktree.localPath)
      }
    }
    
    if !toDelete.isEmpty {
      print("🧹 Removing \(toDelete.count) duplicate TrackedWorktree entries")
      for worktree in toDelete {
        modelContext.delete(worktree)
      }
      try? modelContext.save()
    }
  }
}
