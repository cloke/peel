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

#if os(macOS)
import AppKit

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

/// Represents a git worktree
public struct WorktreeInfo: Identifiable, Hashable {
  public let id: UUID
  public let path: String
  public let branch: String?
  public let commit: String
  public let isMain: Bool
  public let isDetached: Bool
  public let repoName: String
  public let workspaceName: String
  
  // Derived properties
  public var displayName: String {
    if isMain {
      return "main"
    }
    // Extract meaningful name from path
    let url = URL(fileURLWithPath: path)
    return url.lastPathComponent
  }
  
  public var statusIcon: String {
    if isMain { return "house.fill" }
    if isDetached { return "arrow.triangle.branch" }
    return "arrow.branch"
  }
  
  public init(
    path: String,
    branch: String?,
    commit: String,
    isMain: Bool,
    isDetached: Bool,
    repoName: String,
    workspaceName: String
  ) {
    self.id = UUID()
    self.path = path
    self.branch = branch
    self.commit = commit
    self.isMain = isMain
    self.isDetached = isDetached
    self.repoName = repoName
    self.workspaceName = workspaceName
  }
}

/// Status of a worktree including uncommitted changes
public struct WorktreeStatus {
  public let worktree: WorktreeInfo
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
  public private(set) var worktrees: [WorktreeInfo] = []
  
  /// Loading state
  public private(set) var isLoading = false
  
  /// Error message
  public private(set) var errorMessage: String?
  
  /// Worktree root directory
  public let worktreeRoot: String
  
  // MARK: - Storage Keys
  
  private let workspacesKey = "WorkspaceDashboard.workspaces"
  
  // MARK: - Init
  
  public init() {
    self.worktreeRoot = NSHomeDirectory() + "/code/worktrees"
    loadWorkspaces()
    
    // Ensure worktree root exists
    try? FileManager.default.createDirectory(
      atPath: worktreeRoot,
      withIntermediateDirectories: true
    )
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
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    
    // Detect workspace type
    let type = try await detectWorkspaceType(path)
    
    let workspace = Workspace(
      name: name,
      path: path,
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
    guard let workspace = selectedWorkspace else { return }
    
    isLoading = true
    errorMessage = nil
    
    do {
      // Load repos based on workspace type
      switch workspace.type {
      case .multiRepo:
        repos = try await loadSubmodules(in: workspace)
      case .singleRepo:
        repos = [WorkspaceRepo(
          name: workspace.name,
          path: workspace.path,
          relativePath: ".",
          isSubmodule: false
        )]
      case .folder:
        repos = try await findGitRepos(in: workspace)
      }
      
      // Load worktrees for all repos
      var allWorktrees: [WorktreeInfo] = []
      for repo in repos {
        let repoWorktrees = try await loadWorktrees(for: repo, in: workspace)
        allWorktrees.append(contentsOf: repoWorktrees)
      }
      worktrees = allWorktrees
      
    } catch {
      errorMessage = error.localizedDescription
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
  private func loadWorktrees(for repo: WorkspaceRepo, in workspace: Workspace) async throws -> [WorktreeInfo] {
    let repository = Model.Repository(name: repo.name, path: repo.path)
    let gitWorktrees = try await Commands.Worktree.list(on: repository)
    return gitWorktrees.map { worktree in
      WorktreeInfo(
        path: worktree.path,
        branch: normalizedBranch(worktree.branch),
        commit: String(worktree.head.prefix(7)),
        isMain: worktree.isMain,
        isDetached: worktree.isDetached,
        repoName: repo.name,
        workspaceName: workspace.name
      )
    }
  }

  private func normalizedBranch(_ branch: String?) -> String? {
    guard let branch else { return nil }
    if branch.hasPrefix("refs/heads/") {
      return String(branch.dropFirst("refs/heads/".count))
    }
    return branch
  }
  
  // MARK: - Worktree Operations
  
  /// Create a new worktree
  public func createWorktree(
    for repo: WorkspaceRepo,
    description: String,
    baseBranch: String = "main",
    detached: Bool = true
  ) async throws -> WorktreeInfo {
    // Generate safe name from description
    let safeName = description
      .lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    
    let worktreePath = "\(worktreeRoot)/\(repo.name)-\(safeName)"
    
    // Remove existing if present
    if FileManager.default.fileExists(atPath: worktreePath) {
      try await runGit(["worktree", "remove", "--force", worktreePath], in: repo.path)
    }
    
    // Create worktree
    if detached {
      try await runGit(["worktree", "add", "--detach", worktreePath, baseBranch], in: repo.path)
    } else {
      let branchName = "feature/\(safeName)"
      try await runGit(["worktree", "add", "-b", branchName, worktreePath, baseBranch], in: repo.path)
    }
    
    // Reload worktrees
    await loadReposAndWorktrees()
    
    // Return the newly created worktree
    return worktrees.first { $0.path == worktreePath } ?? WorktreeInfo(
      path: worktreePath,
      branch: detached ? nil : "feature/\(safeName)",
      commit: "HEAD",
      isMain: false,
      isDetached: detached,
      repoName: repo.name,
      workspaceName: selectedWorkspace?.name ?? ""
    )
  }
  
  /// Create worktree for a PR
  public func createWorktreeForPR(
    for repo: WorkspaceRepo,
    prNumber: Int
  ) async throws -> WorktreeInfo {
    let worktreePath = "\(worktreeRoot)/\(repo.name)-pr-\(prNumber)"
    
    // Fetch PR branch info using gh CLI
    let prInfo = try await runCommand("gh", args: ["pr", "view", "\(prNumber)", "--json", "headRefName", "-q", ".headRefName"], in: repo.path)
    let branch = prInfo.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Fetch the branch
    try await runGit(["fetch", "origin", "\(branch):\(branch)"], in: repo.path)
    
    // Remove existing if present
    if FileManager.default.fileExists(atPath: worktreePath) {
      try await runGit(["worktree", "remove", "--force", worktreePath], in: repo.path)
    }
    
    // Create worktree on that branch
    try await runGit(["worktree", "add", worktreePath, branch], in: repo.path)
    
    // Reload worktrees
    await loadReposAndWorktrees()
    
    return worktrees.first { $0.path == worktreePath } ?? WorktreeInfo(
      path: worktreePath,
      branch: branch,
      commit: "HEAD",
      isMain: false,
      isDetached: false,
      repoName: repo.name,
      workspaceName: selectedWorkspace?.name ?? ""
    )
  }
  
  /// Remove a worktree
  public func removeWorktree(_ worktree: WorktreeInfo) async throws {
    guard !worktree.isMain else {
      throw WorktreeError.cannotRemoveMain
    }
    
    // Find the repo this worktree belongs to
    guard let repo = repos.first(where: { $0.name == worktree.repoName }) else {
      throw WorktreeError.repoNotFound
    }
    
    try await runGit(["worktree", "remove", "--force", worktree.path], in: repo.path)
    
    // Prune
    try await runGit(["worktree", "prune"], in: repo.path)
    
    // Reload
    await loadReposAndWorktrees()
  }
  
  /// Check if worktree has uncommitted changes
  public func hasUncommittedChanges(_ worktree: WorktreeInfo) async -> Bool {
    do {
      let output = try await runGit(["status", "--porcelain"], in: worktree.path)
      return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    } catch {
      return false
    }
  }
  
  /// Get status for a worktree
  public func getWorktreeStatus(_ worktree: WorktreeInfo) async -> WorktreeStatus {
    let hasChanges = await hasUncommittedChanges(worktree)
    var changedCount = 0
    var lastMessage: String?
    var lastDate: Date?
    
    do {
      let statusOutput = try await runGit(["status", "--porcelain"], in: worktree.path)
      changedCount = statusOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
      
      let logOutput = try await runGit(["log", "-1", "--format=%s|%aI"], in: worktree.path)
      let parts = logOutput.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
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
  public func openInVSCode(_ worktree: WorktreeInfo) async throws {
    try await VSCodeService.shared.open(paths: vscodePaths(for: worktree), newWindow: true)
  }
  
  /// Open worktree in VS Code and copy prompt to clipboard
  public func openInVSCodeWithPrompt(_ worktree: WorktreeInfo, prompt: String) async throws {
    // Copy prompt to clipboard
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(prompt, forType: .string)
    
    // Open in VS Code
    try await VSCodeService.shared.open(paths: vscodePaths(for: worktree), newWindow: true)
  }
  
  private func vscodePaths(for worktree: WorktreeInfo) -> [String] {
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
  
  private func workspaceForWorktree(_ worktree: WorktreeInfo) -> Workspace? {
    if let workspace = selectedWorkspace, workspace.name == worktree.workspaceName {
      return workspace
    }
    return workspaces.first { $0.name == worktree.workspaceName }
  }
  
  // MARK: - Persistence
  
  private func loadWorkspaces() {
    if let data = UserDefaults.standard.data(forKey: workspacesKey),
       let decoded = try? JSONDecoder().decode([Workspace].self, from: data) {
      workspaces = decoded
      selectedWorkspace = workspaces.first
    }
  }
  
  private func saveWorkspaces() {
    if let encoded = try? JSONEncoder().encode(workspaces) {
      UserDefaults.standard.set(encoded, forKey: workspacesKey)
    }
  }
  
  // MARK: - Git Helpers
  
  @discardableResult
  private func runGit(_ args: [String], in directory: String) async throws -> String {
    let repoURL = URL(fileURLWithPath: directory)
    let repository = Model.Repository(name: repoURL.lastPathComponent, path: directory)
    let lines = try await Commands.simple(arguments: args, in: repository)
    return lines.joined(separator: "\n")
  }
  
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

// MARK: - Errors

public enum WorktreeError: LocalizedError {
  case cannotRemoveMain
  case repoNotFound
  case commandFailed(String)
  
  public var errorDescription: String? {
    switch self {
    case .cannotRemoveMain:
      return "Cannot remove the main worktree"
    case .repoNotFound:
      return "Repository not found"
    case .commandFailed(let output):
      return "Command failed: \(output)"
    }
  }
}

#else

// iOS stubs - Workspaces feature is macOS only
public struct Workspace: Identifiable, Codable, Hashable {
  public let id: UUID
  public var name: String
  public var path: String
  public var type: WorkspaceType
  public var addedAt: Date
  
  public enum WorkspaceType: String, Codable {
    case multiRepo, singleRepo, folder
  }
  
  public init(id: UUID = UUID(), name: String, path: String, type: WorkspaceType, addedAt: Date = Date()) {
    self.id = id
    self.name = name
    self.path = path
    self.type = type
    self.addedAt = addedAt
  }
}

public struct WorkspaceRepo: Identifiable, Hashable {
  public let id = UUID()
  public let name: String
  public let path: String
  public let relativePath: String
  public let isSubmodule: Bool
}

public struct WorktreeInfo: Identifiable, Hashable {
  public let id = UUID()
  public let path: String
  public let branch: String?
  public let commit: String
  public let isMain: Bool
  public let isDetached: Bool
  public let repoName: String
  public let workspaceName: String
  public var displayName: String { "main" }
}

public struct WorktreeStatus {
  public let worktree: WorktreeInfo
  public let hasUncommittedChanges: Bool
  public let changedFileCount: Int
  public let lastCommitDate: Date?
  public let lastCommitMessage: String?
}

@MainActor
@Observable
public final class WorkspaceDashboardService {
  public var workspaces: [Workspace] = []
  public var selectedWorkspace: Workspace?
  public var repos: [WorkspaceRepo] = []
  public var worktrees: [WorktreeInfo] = []
  public var isLoading = false
  public var worktreeRoot: String { "" }
  
  public init() {}
  public func loadReposAndWorktrees() async {}
  public func addWorkspaceFromPath(_ path: String) async throws {}
  public func removeWorkspace(_ workspace: Workspace) {}
  public func getWorktreeStatus(_ worktree: WorktreeInfo) async -> WorktreeStatus {
    WorktreeStatus(worktree: worktree, hasUncommittedChanges: false, changedFileCount: 0, lastCommitDate: nil, lastCommitMessage: nil)
  }
  public func openInVSCode(_ worktree: WorktreeInfo) async throws {}
  public func removeWorktree(_ worktree: WorktreeInfo) async throws {}
  public func createWorktree(for repo: WorkspaceRepo, description: String, baseBranch: String, detached: Bool) async throws -> WorktreeInfo {
    WorktreeInfo(path: "", branch: nil, commit: "", isMain: false, isDetached: true, repoName: "", workspaceName: "")
  }
}

#endif
