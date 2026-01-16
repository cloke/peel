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

public extension EnvironmentValues {
  var favoritesProvider: GitHubFavoritesProvider? {
    get { self[FavoritesProviderKey.self] }
    set { self[FavoritesProviderKey.self] = newValue }
  }
  
  var recentPRsProvider: RecentPRsProvider? {
    get { self[RecentPRsProviderKey.self] }
    set { self[RecentPRsProviderKey.self] = newValue }
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
}
