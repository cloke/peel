//
//  OrganizationRepositoryView.swift
//  Lazy-loading organization repository list
//
//  Created by Cory Loken on 7/19/21.
//

import PeelUI
import SwiftUI

public struct OrganizationRepositoryView: View {
  @Environment(\.favoritesProvider) private var favoritesProvider
  @State private var state: ViewState<[Github.Repository]> = .idle
  @State private var isExpanded = false
  @State private var showHidden = false
  @AppStorage("github-show-archived") private var showArchivedRepos = false
  @AppStorage("github-repo-sort") private var sortOrder: RepoSortOrder = .favoritesFirst
  @AppStorage("github-hidden-repos") private var hiddenReposJSON: String = "[]"
  
  let organization: Github.User

  public init(organization: Github.User) {
    self.organization = organization
  }
  
  private var hiddenRepoIds: Set<Int> {
    guard let data = hiddenReposJSON.data(using: .utf8),
          let ids = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
    return Set(ids)
  }
  
  private func setHiddenRepoIds(_ ids: Set<Int>) {
    if let data = try? JSONEncoder().encode(Array(ids)),
       let json = String(data: data, encoding: .utf8) {
      hiddenReposJSON = json
    }
  }
  
  private var visibleRepositories: [Github.Repository] {
    guard case .loaded(let repos) = state else { return [] }
    let filtered = showArchivedRepos ? repos : repos.filter { $0.archived != true }
    let hidden = hiddenRepoIds
    return sortedRepositories(filtered.filter { !hidden.contains($0.id) })
  }
  
  private var hiddenRepositories: [Github.Repository] {
    guard case .loaded(let repos) = state else { return [] }
    let filtered = showArchivedRepos ? repos : repos.filter { $0.archived != true }
    let hidden = hiddenRepoIds
    return filtered.filter { hidden.contains($0.id) }.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }
  
  private func sortedRepositories(_ repos: [Github.Repository]) -> [Github.Repository] {
    switch sortOrder {
    case .favoritesFirst:
      return repos.sorted { lhs, rhs in
        let lhsFav = favoritesProvider?.isFavorite(repoId: lhs.id) ?? false
        let rhsFav = favoritesProvider?.isFavorite(repoId: rhs.id) ?? false
        if lhsFav != rhsFav { return lhsFav }
        return (lhs.name).localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
    case .alphabetical:
      return repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    case .recentlyUpdated:
      return repos.sorted { ($0.pushed_at ?? "") > ($1.pushed_at ?? "") }
    case .stars:
      return repos.sorted { ($0.stargazers_count ?? 0) > ($1.stargazers_count ?? 0) }
    }
  }
  
  public var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      switch state {
      case .idle:
        EmptyView()
      case .loading:
        ProgressView()
      case .error(let message):
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
          .font(.caption)
      case .loaded:
        ForEach(visibleRepositories) { repository in
          NavigationLink(destination: RepositoryContainerView(organization: organization, repository: repository)) {
            repoLabel(for: repository)
          }
          .contextMenu { repoContextMenu(for: repository) }
        }
        
        if !hiddenRepositories.isEmpty {
          DisclosureGroup(
            isExpanded: $showHidden,
            content: {
              ForEach(hiddenRepositories) { repository in
                NavigationLink(destination: RepositoryContainerView(organization: organization, repository: repository)) {
                  repoLabel(for: repository)
                    .foregroundStyle(.secondary)
                }
                .contextMenu { repoContextMenu(for: repository) }
              }
            },
            label: {
              Text("\(hiddenRepositories.count) hidden")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          )
        }
      }
    } label: {
      Text(organization.login ?? "")
        .contentShape(Rectangle())
        .contextMenu {
          Picker("Sort", selection: $sortOrder) {
            ForEach(RepoSortOrder.allCases) { order in
              Label(order.label, systemImage: order.icon).tag(order)
            }
          }
        }
    }
    .onChange(of: isExpanded) { _, expanded in
      guard expanded, case .idle = state else { return }
      Task { await loadRepositories() }
    }
  }
  
  @ViewBuilder
  private func repoLabel(for repository: Github.Repository) -> some View {
    Label {
      Text(repository.name)
        .font(.callout)
    } icon: {
      Image(systemName: favoritesProvider?.isFavorite(repoId: repository.id) == true ? "star.fill" : "book.closed")
        .foregroundStyle(favoritesProvider?.isFavorite(repoId: repository.id) == true ? .yellow : .secondary)
    }
  }
  
  @ViewBuilder
  private func repoContextMenu(for repository: Github.Repository) -> some View {
    let isFav = favoritesProvider?.isFavorite(repoId: repository.id) ?? false
    let isHidden = hiddenRepoIds.contains(repository.id)
    
    Button {
      if isFav {
        favoritesProvider?.removeFavorite(repoId: repository.id)
      } else {
        favoritesProvider?.addFavorite(repo: repository)
      }
    } label: {
      Label(isFav ? "Remove from Favorites" : "Add to Favorites",
            systemImage: isFav ? "star.slash" : "star.fill")
    }
    
    Divider()
    
    Button {
      var ids = hiddenRepoIds
      if isHidden {
        ids.remove(repository.id)
      } else {
        ids.insert(repository.id)
      }
      setHiddenRepoIds(ids)
    } label: {
      Label(isHidden ? "Unhide" : "Hide",
            systemImage: isHidden ? "eye" : "eye.slash")
    }
  }
  
  private func loadRepositories() async {
    state = .loading
    do {
      let repos = try await Github.loadRepositories(organization: organization.login ?? "")
      state = .loaded(repos)
    } catch {
      state = .error(error.localizedDescription)
    }
  }
}

// MARK: - Sort Order

public enum RepoSortOrder: String, CaseIterable, Identifiable {
  case favoritesFirst
  case alphabetical
  case recentlyUpdated
  case stars
  
  public var id: String { rawValue }
  
  public var label: String {
    switch self {
    case .favoritesFirst: "Favorites First"
    case .alphabetical: "Name"
    case .recentlyUpdated: "Recently Updated"
    case .stars: "Stars"
    }
  }
  
  public var icon: String {
    switch self {
    case .favoritesFirst: "star.fill"
    case .alphabetical: "textformat.abc"
    case .recentlyUpdated: "clock"
    case .stars: "star"
    }
  }
}
