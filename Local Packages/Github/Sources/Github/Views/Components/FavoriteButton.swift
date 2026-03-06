//
//  FavoriteButton.swift
//  Github
//
//  Created by Copilot on 1/7/26.
//

import SwiftUI

/// A star button for favoriting GitHub repositories
public struct FavoriteButton: View {
  @Environment(\.favoritesProvider) private var favoritesProvider
  
  let repository: Github.Repository
  @State private var isFavorite: Bool = false
  
  public init(repository: Github.Repository) {
    self.repository = repository
  }
  
  public var body: some View {
    Button {
      toggleFavorite()
    } label: {
      Image(systemName: isFavorite ? "star.fill" : "star")
        .foregroundStyle(isFavorite ? .yellow : .secondary)
    }
    .buttonStyle(.plain)
    .help(isFavorite ? "Remove from favorites" : "Add to favorites")
    .onAppear {
      isFavorite = favoritesProvider?.isFavorite(repoId: repository.id) ?? false
    }
  }
  
  private func toggleFavorite() {
    guard let provider = favoritesProvider else { return }
    
    if isFavorite {
      provider.removeFavorite(repoId: repository.id)
      isFavorite = false
    } else {
      provider.addFavorite(repo: repository)
      isFavorite = true
    }
  }
}

/// A row showing a favorited repository with navigation
public struct FavoriteRepositoryRow: View {
  let favorite: FavoriteRepository
  let onTap: () -> Void
  
  public init(favorite: FavoriteRepository, onTap: @escaping () -> Void) {
    self.favorite = favorite
    self.onTap = onTap
  }
  
  public var body: some View {
    Button(action: onTap) {
      HStack {
        Image(systemName: "star.fill")
          .foregroundStyle(.yellow)
        
        VStack(alignment: .leading, spacing: 2) {
          Text(favorite.repoName)
            .font(.callout)
          Text(favorite.ownerLogin)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        Spacer()
        
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A row showing a recently viewed PR
public struct RecentPRRow: View {
  let recentPR: RecentPRInfo
  let onTap: () -> Void
  
  public init(recentPR: RecentPRInfo, onTap: @escaping () -> Void) {
    self.recentPR = recentPR
    self.onTap = onTap
  }
  
  public var body: some View {
    Button(action: onTap) {
      HStack {
        Image(systemName: prStateIcon)
          .foregroundStyle(prStateColor)
        
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: "#\(recentPR.prNumber) \(recentPR.title)")
            .font(.callout)
            .lineLimit(1)
          Text(recentPR.repoFullName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        Spacer()
        
        Text(timeAgo)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
  
  private var prStateIcon: String {
    switch recentPR.state {
    case "open": return "circle.fill"
    case "closed": return "xmark.circle.fill"
    case "merged": return "arrow.triangle.merge"
    default: return "circle"
    }
  }
  
  private var prStateColor: Color {
    switch recentPR.state {
    case "open": return .green
    case "closed": return .red
    case "merged": return .purple
    default: return .secondary
    }
  }
  
  private var timeAgo: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: recentPR.viewedAt, relativeTo: Date())
  }
}
