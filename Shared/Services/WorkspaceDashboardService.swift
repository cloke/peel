//
//  WorkspaceDashboardService.swift
//  KitchenSync
//
//  Created on 1/15/26.
//
//  Generic service for managing worktrees across any workspace/project.
//  Supports multi-repo workspaces (like tio-workspace) and single-repo projects.
//

import Foundation
import Git
import AppKit
import OSLog
import SwiftData

public enum WorkspaceValidationError: LocalizedError {
  case pathTooBroad(String)

  public var errorDescription: String? {
    switch self {
    case .pathTooBroad(let path):
      return "Select a specific project folder. The workspace path \(path) is too broad."
    }
  }
}

/// Represents a configured workspace that can contain multiple repositories
public struct Workspace: Identifiable, Codable, Hashable {
  public let id: UUID
  public var name: String
  public var path: String
  public var type: WorkspaceType
  public var addedAt: Date
  
  public enum WorkspaceType: String, Codable {
    case multiRepo    // Contains submodules (like tio-workspace)
    case singleRepo   // Single git repository
    case folder       // Just a folder (may have multiple git repos inside)
  }
  
  public init(id: UUID = UUID(), name: String, path: String, type: WorkspaceType, addedAt: Date = Date()) {
    self.id = id
    self.name = name
    self.path = path
    self.type = type
    self.addedAt = addedAt
  }
}

/// Represents a submodule or repository within a workspace
public struct WorkspaceRepo: Identifiable, Hashable {
  public let id: UUID
  public let name: String
  public let path: String
  public let relativePath: String
  public let isSubmodule: Bool
  
  public init(name: String, path: String, relativePath: String, isSubmodule: Bool) {
    self.id = UUID()
    self.name = name
    self.path = path
    self.relativePath = relativePath
    self.isSubmodule = isSubmodule
  }
}

/// Status of a worktree including uncommitted changes
public struct WorktreeStatus {
  public let worktree: Git.Worktree
  public let hasUncommittedChanges: Bool
  public let changedFileCount: Int
  public let lastCommitDate: Date?
  public let lastCommitMessage: String?
}

/// Service for managing worktrees across workspaces
@MainActor
@Observable
public final class WorkspaceDashboardService {
  
  // MARK: - Properties
  
  /// Configured workspaces
  public private(set) var workspaces: [Workspace] = []
  
  /// Currently selected workspace
  public var selectedWorkspace: Workspace?
  
  /// Repositories in the selected workspace
  public private(set) var repos: [WorkspaceRepo] = []
  
  /// All worktrees across all repos in selected workspace
  public private(set) var worktrees: [Git.Worktree] = []

  /// Tracked worktrees persisted in SwiftData
  private(set) var trackedWorktreesByPath: [String: TrackedWorktree] = [:]
  
  /// Loading state
  public private(set) var isLoading = false
  
  /// Error message
  public private(set) var errorMessage: String?
  
  /// Worktree root directory
  public let worktreeRoot: String

  /// Last cleanup timestamp
  public private(set) var lastCleanupAt: Date?

  /// Count of worktrees cleaned up in last run
  public private(set) var lastCleanupCount: Int = 0

  private var dataService: DataService?
  private var worktreeRepoNames: [String: String] = [:]
  private var worktreeWorkspaceNames: [String: String] = [:]
  private var cleanupTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "com.peel.workspaces", category: "WorkspaceDashboardService")
  
  // MARK: - Storage Keys
  
  private let workspacesKey = "WorkspaceDashboard.workspaces"
  
  // MARK: - Init
  
  public init() {
    self.worktreeRoot = NSHomeDirectory() + "/code/worktrees"
    logger.debug("init worktreeRoot=\(self.worktreeRoot, privacy: .public)")
    loadWorkspaces()
    
    // Ensure worktree root exists
    try? FileManager.default.createDirectory(
      atPath: worktreeRoot,
      withIntermediateDirectories: true
    )
  }

  public func configure(modelContext: ModelContext) {
    if dataService == nil {
      logger.debug("configure modelContext")
      dataService = DataService(modelContext: modelContext)
      dataService?.deduplicateTrackedWorktrees()
      reloadTrackedWorktrees()
      
      // Start periodic cleanup
      startPeriodicCleanup()
    }
  }

  /// Start periodic worktree cleanup (runs every hour)
  private func startPeriodicCleanup() {
    cleanupTask?.cancel()
    cleanupTask = Task { [weak self] in
      // Initial delay - wait 5 minutes after app start
      try? await Task.sleep(for: .seconds(300))

      while !Task.isCancelled {
        guard let self else { return }

        // Get settings from DeviceSettings
        let settings = self.dataService?.getDeviceSettings()
        let autoCleanup = settings?.worktreeAutoCleanup ?? true
        let retentionDays = settings?.worktreeRetentionDays ?? 7
        let maxDiskGB = settings?.worktreeMaxDiskGB ?? 10.0

        if autoCleanup {
          let cleaned = await self.cleanupOldWorktrees(
            retentionDays: retentionDays,
            maxDiskGB: maxDiskGB
          )
          await MainActor.run {
            self.lastCleanupAt = Date()
            self.lastCleanupCount = cleaned.count
          }
          if !cleaned.isEmpty {
            print("Auto-cleanup: Removed \(cleaned.count) worktrees")
          }
        }

        // Sleep for 1 hour between cleanup runs
        try? await Task.sleep(for: .seconds(3600))
      }
    }
  }

  /// Stop periodic cleanup
  public func stopPeriodicCleanup() {
    cleanupTask?.cancel()
    cleanupTask = nil
  }
  
  // MARK: - Workspace Management
  
  /// Add a new workspace
  public func addWorkspace(_ workspace: Workspace) {
    workspaces.append(workspace)
    saveWorkspaces()
  }
  
  /// Remove a workspace
  public func removeWorkspace(_ workspace: Workspace) {
    workspaces.removeAll { $0.id == workspace.id }
    if selectedWorkspace?.id == workspace.id {
      selectedWorkspace = workspaces.first
    }
    saveWorkspaces()
  }
  
  /// Add workspace from path (auto-detects type)
  public func addWorkspaceFromPath(_ path: String) async throws {
    let normalizedPath = normalizePath(path)
    if isTooBroadWorkspacePath(normalizedPath) {
      throw WorkspaceValidationError.pathTooBroad(normalizedPath)
    }
    let url = URL(fileURLWithPath: normalizedPath)
    let name = url.lastPathComponent
    
    // Detect workspace type
    let type = try await detectWorkspaceType(normalizedPath)
    
    let workspace = Workspace(
      name: name,
      path: normalizedPath,
      type: type
    )
    
    addWorkspace(workspace)
    selectedWorkspace = workspace
    await loadReposAndWorktrees()
  }
  
  /// Detect the type of workspace
  private func detectWorkspaceType(_ path: String) async throws -> Workspace.WorkspaceType {
    let gitmodulesPath = path + "/.gitmodules"
    let gitPath = path + "/.git"
    
    if FileManager.default.fileExists(atPath: gitmodulesPath) {
      return .multiRepo
    } else if FileManager.default.fileExists(atPath: gitPath) {
      return .singleRepo
    } else {
      return .folder
    }
  }
  
  // MARK: - Loading Data
  
  /// Load repositories and worktrees for selected workspace
  public func loadReposAndWorktrees() async {
    guard let workspace = selectedWorkspace else {
      logger.debug("loadReposAndWorktrees skipped (no selectedWorkspace)")
      return
    }
    
    isLoading = true
    errorMessage = nil
    worktreeRepoNames = [:]
    worktreeWorkspaceNames = [:]
    logger.debug("loadReposAndWorktrees start workspace=\(workspace.name, privacy: .public)")

    let normalizedPath = normalizePath(workspace.path)
    if isTooBroadWorkspacePath(normalizedPath) {
      errorMessage = WorkspaceValidationError.pathTooBroad(normalizedPath).localizedDescription
      logger.error("loadReposAndWorktrees invalid path: \(normalizedPath, privacy: .public)")
      isLoading = false
      return
    }
    
    do {
      // Load repos based on workspace type
      switch workspace.type {
      case .multiRepo:
        let normalizedWorkspace = Workspace(id: workspace.id, name: workspace.name, path: normalizedPath, type: workspace.type, addedAt: workspace.addedAt)
        repos = try await loadSubmodules(in: normalizedWorkspace)
        logger.debug("loadReposAndWorktrees submodules repos=\(self.repos.count)")
      case .singleRepo:
        repos = [WorkspaceRepo(
          name: workspace.name,
          path: normalizedPath,
          relativePath: ".",
          isSubmodule: false
        )]
        logger.debug("loadReposAndWorktrees single repo")
      case .folder:
        let normalizedWorkspace = Workspace(id: workspace.id, name: workspace.name, path: normalizedPath, type: workspace.type, addedAt: workspace.addedAt)
        repos = try await findGitRepos(in: normalizedWorkspace)
        logger.debug("loadReposAndWorktrees folder repos=\(self.repos.count)")
      }
      
      // Load worktrees for all repos
      var allWorktrees: [Git.Worktree] = []
      for repo in repos {
        let repoWorktrees = try await loadWorktrees(for: repo, in: workspace)
        allWorktrees.append(contentsOf: repoWorktrees)
      }
      worktrees = allWorktrees
      syncTrackedWorktrees()
      logger.debug("loadReposAndWorktrees done worktrees=\(self.worktrees.count)")
      
    } catch {
      errorMessage = error.localizedDescription
      logger.error("loadReposAndWorktrees failed: \(error.localizedDescription)")
    }
    
    isLoading = false
  }
  
  /// Load submodules from .gitmodules file
  private func loadSubmodules(in workspace: Workspace) async throws -> [WorkspaceRepo] {
    let gitmodulesPath = workspace.path + "/.gitmodules"
    
    guard let content = try? String(contentsOfFile: gitmodulesPath, encoding: .utf8) else {
      return []
    }
    
    var repos: [WorkspaceRepo] = []
    var currentPath: String?
    
    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      
      if trimmed.hasPrefix("path = ") {
        currentPath = String(trimmed.dropFirst("path = ".count))
        
        if let path = currentPath {
          let fullPath = workspace.path + "/" + path
          let name = URL(fileURLWithPath: path).lastPathComponent
          
          repos.append(WorkspaceRepo(
            name: name,
            path: fullPath,
            relativePath: path,
            isSubmodule: true
          ))
        }
      }
    }
    
    return repos.sorted { $0.name < $1.name }
  }
  
  /// Find git repos in a folder
  private func findGitRepos(in workspace: Workspace) async throws -> [WorkspaceRepo] {
    var repos: [WorkspaceRepo] = []
    let fm = FileManager.default
    
    guard let contents = try? fm.contentsOfDirectory(atPath: workspace.path) else {
      return []
    }
    
    for item in contents {
      let itemPath = workspace.path + "/" + item
      let gitPath = itemPath + "/.git"
      
      if fm.fileExists(atPath: gitPath) {
        repos.append(WorkspaceRepo(
          name: item,
          path: itemPath,
          relativePath: item,
          isSubmodule: false
        ))
      }
    }
    
    return repos.sorted { $0.name < $1.name }
  }
  
  /// Load worktrees for a repository
  private func loadWorktrees(for repo: WorkspaceRepo, in workspace: Workspace) async throws -> [Git.Worktree] {
    let repository = Model.Repository(name: repo.name, path: repo.path)
    let gitWorktrees = try await Commands.Worktree.list(on: repository)
    for worktree in gitWorktrees {
      worktreeRepoNames[worktree.path] = repo.name
      worktreeWorkspaceNames[worktree.path] = workspace.name
    }
    return gitWorktrees
  }

  public func repoName(for worktree: Git.Worktree) -> String? {
    worktreeRepoNames[worktree.path]
  }

  public func workspaceName(for worktree: Git.Worktree) -> String? {
    worktreeWorkspaceNames[worktree.path]
  }

  func trackedWorktree(for worktree: Git.Worktree) -> TrackedWorktree? {
    trackedWorktreesByPath[worktree.path]
  }
  
  // MARK: - Worktree Operations
  
  /// Create a new worktree
  public func createWorktree(
    for repo: WorkspaceRepo,
    description: String,
    baseBranch: String = "main",
    detached: Bool = true
  ) async throws -> Git.Worktree {
    // Generate safe name from description
    let safeName = description
      .lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    
    let worktreePath = "\(worktreeRoot)/\(repo.name)-\(safeName)"
    let repository = Model.Repository(name: repo.name, path: repo.path)
    
    // Remove existing if present
    if FileManager.default.fileExists(atPath: worktreePath) {
      _ = try await Commands.simple(arguments: ["worktree", "remove", "--force", worktreePath], in: repository)
    }
    
    // Create worktree
    if detached {
      _ = try await Commands.simple(arguments: ["worktree", "add", "--detach", worktreePath, baseBranch], in: repository)
    } else {
      let branchName = "feature/\(safeName)"
      _ = try await Commands.simple(arguments: ["worktree", "add", "-b", branchName, worktreePath, baseBranch], in: repository)
    }
    
    // Reload worktrees
    await loadReposAndWorktrees()

    let trackedBranch = detached ? "detached" : "feature/\(safeName)"
    trackWorktree(
      path: worktreePath,
      branch: trackedBranch,
      repo: repo,
      source: "manual",
      purpose: description
    )
    
    // Return the newly created worktree
    return worktrees.first { $0.path == worktreePath } ?? Git.Worktree(
      path: worktreePath,
      head: "HEAD",
      branch: detached ? nil : "feature/\(safeName)",
      isDetached: detached
    )
  }
  
  /// Create worktree for a PR
  public func createWorktreeForPR(
    for repo: WorkspaceRepo,
    prNumber: Int
  ) async throws -> Git.Worktree {
    let worktreePath = "\(worktreeRoot)/\(repo.name)-pr-\(prNumber)"
    let repository = Model.Repository(name: repo.name, path: repo.path)
    
    // Fetch PR branch info using gh CLI
    let prInfo = try await runCommand("gh", args: ["pr", "view", "\(prNumber)", "--json", "headRefName", "-q", ".headRefName"], in: repo.path)
    let branch = prInfo.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Fetch the branch
    _ = try await Commands.simple(arguments: ["fetch", "origin", "\(branch):\(branch)"], in: repository)
    
    // Remove existing if present
    if FileManager.default.fileExists(atPath: worktreePath) {
      _ = try await Commands.simple(arguments: ["worktree", "remove", "--force", worktreePath], in: repository)
    }
    
    // Create worktree on that branch
    _ = try await Commands.simple(arguments: ["worktree", "add", worktreePath, branch], in: repository)
    
    // Reload worktrees
    await loadReposAndWorktrees()

    trackWorktree(
      path: worktreePath,
      branch: branch,
      repo: repo,
      source: "pr-review",
      purpose: "PR #\(prNumber)",
      linkedPRNumber: prNumber,
      linkedPRRepo: repo.name
    )
    
    return worktrees.first { $0.path == worktreePath } ?? Git.Worktree(
      path: worktreePath,
      head: "HEAD",
      branch: branch,
      isDetached: false
    )
  }
  
  /// Remove a worktree
  public func removeWorktree(_ worktree: Git.Worktree) async throws {
    guard !worktree.isMain else {
      throw WorktreeError.cannotRemoveMain
    }
    
    // Find the repo this worktree belongs to
    guard let repoName = repoName(for: worktree), let repo = repos.first(where: { $0.name == repoName }) else {
      throw WorktreeError.repositoryNotFound(worktree.path)
    }

    let repository = Model.Repository(name: repo.name, path: repo.path)
    
    _ = try await Commands.simple(arguments: ["worktree", "remove", "--force", worktree.path], in: repository)
    
    // Prune
    _ = try await Commands.simple(arguments: ["worktree", "prune"], in: repository)
    
    // Reload
    await loadReposAndWorktrees()
    dataService?.removeTrackedWorktree(localPath: worktree.path)
  }

  // MARK: - Auto-Cleanup

  /// Clean up worktrees older than retention period
  /// - Parameters:
  ///   - retentionDays: Number of days to keep worktrees
  ///   - maxDiskGB: Maximum disk space for worktrees (0 = unlimited)
  ///   - dryRun: If true, only reports what would be cleaned up
  /// - Returns: Array of cleaned up worktree paths (or would-be cleaned up in dry run)
  public func cleanupOldWorktrees(
    retentionDays: Int = 7,
    maxDiskGB: Double = 0,
    dryRun: Bool = false
  ) async -> [String] {
    var cleanedPaths: [String] = []
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()

    // Get tracked worktrees that are past retention and auto-created (not manual)
    let trackedWorktrees = dataService?.getTrackedWorktrees() ?? []
    let eligibleForCleanup = trackedWorktrees.filter { tracked in
      // Only cleanup auto-created worktrees (from swarm, parallel runs, etc.)
      guard tracked.source != "manual" else { return false }
      // Check age
      return tracked.createdAt < cutoffDate
    }

    for tracked in eligibleForCleanup {
      // Find the actual worktree
      guard let worktree = worktrees.first(where: { $0.path == tracked.localPath }) else {
        // Worktree no longer exists on disk, just clean up the tracking record
        if !dryRun {
          dataService?.removeTrackedWorktree(localPath: tracked.localPath)
        }
        cleanedPaths.append(tracked.localPath + " (record only)")
        continue
      }

      // Skip if has uncommitted changes
      let hasChanges = await hasUncommittedChanges(worktree)
      if hasChanges {
        continue
      }

      if dryRun {
        cleanedPaths.append(worktree.path)
      } else {
        do {
          try await removeWorktree(worktree)
          cleanedPaths.append(worktree.path)
        } catch {
          print("Failed to cleanup worktree \(worktree.path): \(error)")
        }
      }
    }

    // TODO: Implement disk space limit cleanup (maxDiskGB)
    // Would need to calculate total worktree disk usage and remove oldest until under limit

    return cleanedPaths
  }

  /// Get worktrees eligible for cleanup with details
  public func getCleanupCandidates(retentionDays: Int = 7) async -> [(path: String, age: Int, source: String, hasChanges: Bool)] {
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
    var candidates: [(path: String, age: Int, source: String, hasChanges: Bool)] = []

    let trackedWorktrees = dataService?.getTrackedWorktrees() ?? []

    for tracked in trackedWorktrees {
      guard tracked.source != "manual" else { continue }
      guard tracked.createdAt < cutoffDate else { continue }

      let ageInDays = Calendar.current.dateComponents([.day], from: tracked.createdAt, to: Date()).day ?? 0

      // Check if still exists on disk
      if let worktree = worktrees.first(where: { $0.path == tracked.localPath }) {
        let hasChanges = await hasUncommittedChanges(worktree)
        candidates.append((path: tracked.localPath, age: ageInDays, source: tracked.source, hasChanges: hasChanges))
      } else {
        // Worktree doesn't exist on disk but tracking record does
        candidates.append((path: tracked.localPath + " (orphaned)", age: ageInDays, source: tracked.source, hasChanges: false))
      }
    }

    return candidates.sorted { $0.age > $1.age }
  }
  
  /// Check if worktree has uncommitted changes
  public func hasUncommittedChanges(_ worktree: Git.Worktree) async -> Bool {
    do {
      let repository = Model.Repository(
        name: URL(fileURLWithPath: worktree.path).lastPathComponent,
        path: worktree.path
      )
      let output = try await Commands.simple(arguments: ["status", "--porcelain"], in: repository)
      let joined = output.joined(separator: "\n")
      return !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    } catch {
      return false
    }
  }
  
  /// Get status for a worktree
  public func getWorktreeStatus(_ worktree: Git.Worktree) async -> WorktreeStatus {
    let hasChanges = await hasUncommittedChanges(worktree)
    var changedCount = 0
    var lastMessage: String?
    var lastDate: Date?
    
    do {
      let repository = Model.Repository(
        name: URL(fileURLWithPath: worktree.path).lastPathComponent,
        path: worktree.path
      )
      let statusOutput = try await Commands.simple(arguments: ["status", "--porcelain"], in: repository)
      changedCount = statusOutput.filter { !$0.isEmpty }.count
      
      let logOutput = try await Commands.simple(arguments: ["log", "-1", "--format=%s|%aI"], in: repository)
      let joined = logOutput.joined(separator: "\n")
      let parts = joined.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
      if parts.count >= 2 {
        lastMessage = parts[0]
        let formatter = ISO8601DateFormatter()
        lastDate = formatter.date(from: parts[1])
      }
    } catch {
      // Ignore errors
    }
    
    return WorktreeStatus(
      worktree: worktree,
      hasUncommittedChanges: hasChanges,
      changedFileCount: changedCount,
      lastCommitDate: lastDate,
      lastCommitMessage: lastMessage
    )
  }
  
  // MARK: - VS Code Integration
  
  /// Open worktree in VS Code
  public func openInVSCode(_ worktree: Git.Worktree) async throws {
    try await VSCodeService.shared.open(paths: vscodePaths(for: worktree), newWindow: true)
  }
  
  /// Open worktree in VS Code and copy prompt to clipboard
  public func openInVSCodeWithPrompt(_ worktree: Git.Worktree, prompt: String) async throws {
    // Copy prompt to clipboard
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(prompt, forType: .string)
    
    // Open in VS Code
    try await VSCodeService.shared.open(paths: vscodePaths(for: worktree), newWindow: true)
  }
  
  private func vscodePaths(for worktree: Git.Worktree) -> [String] {
    let fm = FileManager.default
    var paths: [String] = []
    if fm.fileExists(atPath: worktree.path) {
      paths.append(worktree.path)
    }
    if let workspace = workspaceForWorktree(worktree) {
      switch workspace.type {
      case .multiRepo, .folder:
        if fm.fileExists(atPath: workspace.path) {
          paths.append(workspace.path)
        }
      case .singleRepo:
        break
      }
    }
    return paths.isEmpty ? [worktree.path] : paths
  }
  
  private func workspaceForWorktree(_ worktree: Git.Worktree) -> Workspace? {
    if let selectedWorkspace {
      return selectedWorkspace
    }
    if let workspaceName = workspaceName(for: worktree) {
      return workspaces.first { $0.name == workspaceName }
    }
    return nil
  }

  private func trackWorktree(
    path: String,
    branch: String,
    repo: WorkspaceRepo,
    source: String,
    purpose: String? = nil,
    linkedPRNumber: Int? = nil,
    linkedPRRepo: String? = nil
  ) {
    guard let dataService else { return }
    let repositoryId = dataService.getRepositoryId(forLocalPath: repo.path) ?? UUID()
    _ = dataService.upsertTrackedWorktree(
      repositoryId: repositoryId,
      localPath: path,
      branch: branch,
      source: source,
      purpose: purpose,
      linkedPRNumber: linkedPRNumber,
      linkedPRRepo: linkedPRRepo
    )
    reloadTrackedWorktrees()
  }

  private func syncTrackedWorktrees() {
    guard let dataService else { return }
    reloadTrackedWorktrees()

    for worktree in worktrees where !worktree.isMain {
      guard let repoName = repoName(for: worktree),
            let repo = repos.first(where: { $0.name == repoName }) else {
        continue
      }

      let existing = trackedWorktreesByPath[worktree.path]
      let inferred = inferTrackingData(for: worktree, repo: repo)
      let repositoryId = dataService.getRepositoryId(forLocalPath: repo.path)

      _ = dataService.upsertTrackedWorktree(
        repositoryId: repositoryId,
        localPath: worktree.path,
        branch: worktree.branch ?? "detached",
        source: existing?.source ?? inferred.source,
        purpose: existing?.purpose ?? inferred.purpose,
        linkedPRNumber: existing?.linkedPRNumber ?? inferred.linkedPRNumber,
        linkedPRRepo: existing?.linkedPRRepo ?? inferred.linkedPRRepo
      )
    }

    reloadTrackedWorktrees()
  }

  private func reloadTrackedWorktrees() {
    guard let dataService else {
      trackedWorktreesByPath = [:]
      return
    }
    let tracked = dataService.getTrackedWorktrees()
    // Use reduce to handle potential duplicate paths (keep last entry)
    trackedWorktreesByPath = tracked.reduce(into: [:]) { dict, worktree in
      dict[worktree.localPath] = worktree
    }
  }

  private func inferTrackingData(
    for worktree: Git.Worktree,
    repo: WorkspaceRepo
  ) -> (source: String, purpose: String?, linkedPRNumber: Int?, linkedPRRepo: String?) {
    let path = worktree.path
    if path.contains(AgentWorkspaceService.workspacesDirName) {
      return ("agent", nil, nil, nil)
    }

    if let prNumber = extractPRNumber(from: path) {
      return ("pr-review", "PR #\(prNumber)", prNumber, repo.name)
    }

    return ("manual", nil, nil, nil)
  }

  private func extractPRNumber(from path: String) -> Int? {
    let pattern = "-pr-(\\d+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(path.startIndex..<path.endIndex, in: path)
    guard let match = regex.firstMatch(in: path, range: range), match.numberOfRanges > 1,
          let numberRange = Range(match.range(at: 1), in: path) else {
      return nil
    }
    return Int(path[numberRange])
  }
  
  // MARK: - Persistence
  
  private func loadWorkspaces() {
    if let data = UserDefaults.standard.data(forKey: workspacesKey),
       let decoded = try? JSONDecoder().decode([Workspace].self, from: data) {
      workspaces = decoded
      selectedWorkspace = workspaces.first
      logger.debug("loadWorkspaces loaded count=\(self.workspaces.count)")
    } else {
      logger.debug("loadWorkspaces none")
    }
  }
  
  private func saveWorkspaces() {
    if let encoded = try? JSONEncoder().encode(workspaces) {
      UserDefaults.standard.set(encoded, forKey: workspacesKey)
    }
  }

  // MARK: - Path Validation

  private func normalizePath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func isTooBroadWorkspacePath(_ path: String) -> Bool {
    let normalized = normalizePath(path)
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    return normalized == "/" || normalized == "/Users" || normalized == home
  }
  
  // MARK: - Git Helpers
  
  @discardableResult
  private func runCommand(_ command: String, args: [String], in directory: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      let pipe = Pipe()
      
      process.executableURL = URL(fileURLWithPath: command)
      process.arguments = args
      process.currentDirectoryURL = URL(fileURLWithPath: directory)
      process.standardOutput = pipe
      process.standardError = pipe
      
      do {
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        if process.terminationStatus == 0 {
          continuation.resume(returning: output)
        } else {
          continuation.resume(throwing: WorktreeError.commandFailed(output))
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
