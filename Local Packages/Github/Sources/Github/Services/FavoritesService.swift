//
//  FavoritesService.swift
//  Github
//
//  Created by Copilot on 1/7/26.
//

import SwiftUI

/// Protocol for managing GitHub favorites - implemented by main app
@MainActor
public protocol GitHubFavoritesProvider {
  func isFavorite(repoId: Int) -> Bool
  func addFavorite(repo: Github.Repository)
  func removeFavorite(repoId: Int)
  func getFavorites() -> [FavoriteRepository]
}

/// Protocol for tracking recent PRs - implemented by main app
@MainActor
public protocol RecentPRsProvider {
  func recordView(pr: Github.PullRequest, repo: Github.Repository)
  func getRecentPRs() -> [RecentPRInfo]
}

/// Protocol for starting PR review with agents - implemented by main app
@MainActor
public protocol PRReviewAgentProvider {
  func reviewWithAgent(pr: Github.PullRequest, repo: Github.Repository)
}

/// Lightweight agent review status for display in PR views.
public struct PRAgentReviewStatus: Sendable {
  public let phase: String
  public let displayName: String
  public let systemImage: String
  public let isActive: Bool

  public init(phase: String, displayName: String, systemImage: String, isActive: Bool) {
    self.phase = phase
    self.displayName = displayName
    self.systemImage = systemImage
    self.isActive = isActive
  }

  public var badgeColor: Color {
    switch phase {
    case "reviewing", "fixing", "pushing": return .purple
    case "reviewed", "needsFix": return .orange
    case "fixed", "readyToPush": return .blue
    case "pushed", "approved": return .green
    case "failed": return .red
    default: return .secondary
    }
  }
}

/// Protocol for querying agent review status — implemented by main app
@MainActor
public protocol PRReviewStatusProvider {
  func reviewStatus(owner: String, repo: String, prNumber: Int) -> PRAgentReviewStatus?
}

/// Protocol for resolving a GitHub repository to its local clone path - implemented by main app
@MainActor
public protocol LocalRepoResolver {
  /// Given a GitHub repository, returns the local path if this device has a clone
  func localPath(for githubRepo: Github.Repository) -> String?
}

/// Lightweight struct for favorite repository info
public struct FavoriteRepository: Identifiable, Sendable {
  public let id: Int
  public let fullName: String
  public let ownerLogin: String
  public let repoName: String
  public let htmlURL: String?
  public let addedAt: Date
  
  public init(id: Int, fullName: String, ownerLogin: String, repoName: String, htmlURL: String?, addedAt: Date) {
    self.id = id
    self.fullName = fullName
    self.ownerLogin = ownerLogin
    self.repoName = repoName
    self.htmlURL = htmlURL
    self.addedAt = addedAt
  }
}

/// Lightweight struct for recent PR info
public struct RecentPRInfo: Identifiable, Sendable {
  public let id: Int
  public let prNumber: Int
  public let title: String
  public let repoFullName: String
  public let state: String
  public let htmlURL: String?
  public let viewedAt: Date
  
  public init(id: Int, prNumber: Int, title: String, repoFullName: String, state: String, htmlURL: String?, viewedAt: Date) {
    self.id = id
    self.prNumber = prNumber
    self.title = title
    self.repoFullName = repoFullName
    self.state = state
    self.htmlURL = htmlURL
    self.viewedAt = viewedAt
  }
}

// MARK: - Environment Keys

private struct FavoritesProviderKey: EnvironmentKey {
  static let defaultValue: GitHubFavoritesProvider? = nil
}

private struct RecentPRsProviderKey: EnvironmentKey {
  static let defaultValue: RecentPRsProvider? = nil
}

private struct PRReviewAgentProviderKey: EnvironmentKey {
  static let defaultValue: PRReviewAgentProvider? = nil
}

private struct PRReviewStatusProviderKey: EnvironmentKey {
  static let defaultValue: PRReviewStatusProvider? = nil
}

private struct LocalRepoResolverKey: EnvironmentKey {
  static let defaultValue: LocalRepoResolver? = nil
}

public extension EnvironmentValues {
  var favoritesProvider: GitHubFavoritesProvider? {
    get { self[FavoritesProviderKey.self] }
    set { self[FavoritesProviderKey.self] = newValue }
  }
  
  var recentPRsProvider: RecentPRsProvider? {
    get { self[RecentPRsProviderKey.self] }
    set { self[RecentPRsProviderKey.self] = newValue }
  }

  var reviewWithAgentProvider: PRReviewAgentProvider? {
    get { self[PRReviewAgentProviderKey.self] }
    set { self[PRReviewAgentProviderKey.self] = newValue }
  }

  var prReviewStatusProvider: PRReviewStatusProvider? {
    get { self[PRReviewStatusProviderKey.self] }
    set { self[PRReviewStatusProviderKey.self] = newValue }
  }
  
  var localRepoResolver: LocalRepoResolver? {
    get { self[LocalRepoResolverKey.self] }
    set { self[LocalRepoResolverKey.self] = newValue }
  }
}

// MARK: - View Modifier for Favorites

public extension View {
  func favoritesProvider(_ provider: GitHubFavoritesProvider?) -> some View {
    environment(\.favoritesProvider, provider)
  }
  
  func recentPRsProvider(_ provider: RecentPRsProvider?) -> some View {
    environment(\.recentPRsProvider, provider)
  }

  func reviewWithAgentProvider(_ provider: PRReviewAgentProvider?) -> some View {
    environment(\.reviewWithAgentProvider, provider)
  }

  func prReviewStatusProvider(_ provider: PRReviewStatusProvider?) -> some View {
    environment(\.prReviewStatusProvider, provider)
  }

  func localRepoResolver(_ resolver: LocalRepoResolver?) -> some View {
    environment(\.localRepoResolver, resolver)
  }
}
