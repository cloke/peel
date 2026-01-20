//
//  ReviewLocallyService.swift
//  Github
//
//  Created by Copilot on 1/7/26.
//

import Foundation
import Git

#if os(macOS)
import AppKit

/// Service for reviewing GitHub PRs locally using git worktrees
@MainActor
@Observable
public final class ReviewLocallyService {
  public static let shared = ReviewLocallyService()
  
  /// Current state of the review setup
  public enum State: Equatable {
    case idle
    case checkingRepository
    case fetchingRemote
    case creatingWorktree
    case openingVSCode
    case complete(worktreePath: String)
    case error(String)
  }
  
  public var state: State = .idle
  
  /// Recent local repositories that could be used for PR review
  public var recentRepositories: [LocalRepository] = []

  public var lastSelectedRepoPath: String? {
    get { UserDefaults.standard.string(forKey: lastRepoPathKey) }
    set {
      if let newValue, !newValue.isEmpty {
        UserDefaults.standard.set(newValue, forKey: lastRepoPathKey)
      } else {
        UserDefaults.standard.removeObject(forKey: lastRepoPathKey)
      }
    }
  }
  
  private init() {
    loadRecentRepositories()
  }
  
  /// A local repository that can be used for PR review
  public struct LocalRepository: Identifiable, Equatable, Codable {
    public let id: UUID
    public let path: String
    public let name: String
    public let remoteURL: String?
    public let lastUsed: Date
    
    public init(path: String, name: String, remoteURL: String?) {
      self.id = UUID()
      self.path = path
      self.name = name
      self.remoteURL = remoteURL
      self.lastUsed = Date()
    }
  }
  
  /// Check if a local repository matches the GitHub repository
  public func repositoryMatches(local: LocalRepository, githubRepo: Github.Repository) -> Bool {
    guard let remoteURL = local.remoteURL else { return false }
    
    // Check various URL formats
    let githubURLs = [
      "git@github.com:\(githubRepo.full_name ?? "").git",
      "https://github.com/\(githubRepo.full_name ?? "").git",
      "https://github.com/\(githubRepo.full_name ?? "")",
      "git@github.com:\(githubRepo.full_name ?? "")"
    ]
    
    return githubURLs.contains { remoteURL.lowercased().contains($0.lowercased()) }
      || remoteURL.lowercased().contains((githubRepo.full_name ?? "").lowercased())
  }
  
  /// Create a worktree for reviewing a PR
  /// - Parameters:
  ///   - pullRequest: The PR to review
  ///   - localRepoPath: Path to the local git repository
  ///   - worktreeBasePath: Base path for creating worktrees (defaults to sibling of repo)
  ///   - openInVSCode: Whether to open the worktree in VS Code
  public func reviewLocally(
    pullRequest: Github.PullRequest,
    localRepoPath: String,
    worktreeBasePath: String? = nil,
    openInVSCode: Bool = true
  ) async {
    state = .checkingRepository

    if !localRepoPath.isEmpty {
      lastSelectedRepoPath = localRepoPath
    }
    
    // Verify the local repository exists
    guard FileManager.default.fileExists(atPath: localRepoPath) else {
      state = .error("Repository not found at: \(localRepoPath)")
      return
    }
    
    // Create Model.Repository for Git commands
    let repoURL = URL(fileURLWithPath: localRepoPath)
    let repository = Model.Repository(
      name: repoURL.lastPathComponent,
      path: localRepoPath
    )
    
    // Determine branch name from PR
    let branchName = pullRequest.head.ref
    let prNumber = pullRequest.number
    
    // Create worktree path
    let basePath = worktreeBasePath ?? repoURL.deletingLastPathComponent().path
    let worktreeName = "pr-\(prNumber)-\(sanitizeBranchName(branchName))"
    let worktreePath = (basePath as NSString).appendingPathComponent(worktreeName)
    
    // Check if worktree already exists
    if FileManager.default.fileExists(atPath: worktreePath) {
      // Worktree exists, just open it
      if openInVSCode {
        state = .openingVSCode
        do {
          try VSCodeLauncher.open(path: worktreePath)
          state = .complete(worktreePath: worktreePath)
        } catch {
          state = .error("Failed to open VS Code: \(error.localizedDescription)")
        }
      } else {
        state = .complete(worktreePath: worktreePath)
      }
      return
    }
    
    // Fetch the remote to get the PR branch
    state = .fetchingRemote
    do {
      // First, fetch the PR branch from origin
      try await Commands.fetch(refspec: branchName, on: repository)
    } catch {
      // Fetch may fail if branch doesn't exist remotely yet, try to continue
      print("Note: fetch failed (may be expected): \(error)")
    }
    
    // Create the worktree
    state = .creatingWorktree
    do {
      // Try to create worktree from the remote branch
      try await Commands.Worktree.add(
        path: worktreePath,
        branch: "origin/\(branchName)",
        on: repository
      )
    } catch {
      // If that fails, try creating a new branch tracking the remote
      do {
        try await Commands.Worktree.addWithNewBranch(
          path: worktreePath,
          newBranch: branchName,
          startPoint: "origin/\(branchName)",
          on: repository
        )
      } catch {
        state = .error("Failed to create worktree: \(error.localizedDescription)")
        return
      }
    }
    
    // Save this repository to recents
    saveRecentRepository(path: localRepoPath, name: repoURL.lastPathComponent)
    
    // Open in VS Code
    if openInVSCode {
      state = .openingVSCode
      do {
        try VSCodeLauncher.open(path: worktreePath)
      } catch {
        // Don't fail completely if VS Code fails
        print("Failed to open VS Code: \(error)")
      }
    }
    
    state = .complete(worktreePath: worktreePath)
  }
  
  /// Sanitize a branch name for use in a folder name
  private func sanitizeBranchName(_ name: String) -> String {
    String(name
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: " ", with: "-")
      .prefix(50))
      .trimmingCharacters(in: .whitespaces)
  }
  
  // MARK: - Recent Repositories Persistence
  
  private let recentReposKey = "ReviewLocallyService.recentRepositories"
  private let lastRepoPathKey = "ReviewLocallyService.lastSelectedRepoPath"
  
  private func loadRecentRepositories() {
    guard let data = UserDefaults.standard.data(forKey: recentReposKey),
          let repos = try? JSONDecoder().decode([LocalRepository].self, from: data) else {
      return
    }
    recentRepositories = repos
  }
  
  private func saveRecentRepository(path: String, name: String) {
    // Get remote URL asynchronously
    Task {
      let repository = Model.Repository(name: name, path: path)
      let remoteURL = await Commands.getRemoteURL(on: repository)
      
      // Update recent repositories
      let newRepo = LocalRepository(path: path, name: name, remoteURL: remoteURL)
      recentRepositories.removeAll { $0.path == path }
      recentRepositories.insert(newRepo, at: 0)
      
      // Keep only 10 most recent
      if recentRepositories.count > 10 {
        recentRepositories = Array(recentRepositories.prefix(10))
      }
      
      // Save
      if let data = try? JSONEncoder().encode(recentRepositories) {
        UserDefaults.standard.set(data, forKey: recentReposKey)
      }
    }
  }
  
  /// Reset state to idle
  public func reset() {
    state = .idle
  }
  
  /// Browse for a local repository
  public func browseForRepository() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "Select the local git repository for this project"
    panel.prompt = "Select"
    
    guard panel.runModal() == .OK,
          let url = panel.url else {
      return nil
    }
    
    return url.path
  }
}

#endif
