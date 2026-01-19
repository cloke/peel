//
//  Github_RootView.swift
//  KitchenSync (macOS)
//
//  Created by Cory Loken on 7/14/21.
//  Modernized to @Observable on 1/5/26
//  Updated for Keychain storage on 1/6/26
//

import SwiftUI
import SwiftData
import Github

struct Github_RootView: View {
#if os(macOS)
  @Environment(MCPServerService.self) private var mcpServer
#endif
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \GitHubFavorite.addedAt, order: .reverse) private var favoriteRecords: [GitHubFavorite]
  @Query(sort: \RecentPullRequest.viewedAt, order: .reverse) private var recentPRRecords: [RecentPullRequest]
  @State public var viewModel = Github.ViewModel()
  @State private var dataProvider: GitHubDataProvider?
  
  @State private var organizations = [Github.User]()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var hasToken = false
  @State private var isLoading = false
  @State private var errorMessage: String?
  @AppStorage("github-show-archived") private var showArchivedRepos = false
  @AppStorage("github.selectedFavoriteKey") private var selectedFavoriteKey: String = ""
  @AppStorage("github.selectedRecentPRKey") private var selectedRecentPRKey: String = ""
  @State private var selectedAutomationDestination: GitHubAutomationDestination?

  private enum GitHubAutomationDestination: Hashable {
    case favorite(String)
    case recentPR(String)
  }

  private func loadProfile() async {
    hasToken = await Github.hasToken
    guard hasToken else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      viewModel.me = try await Github.me()
      organizations = try await Github.loadOrganizations()
    } catch {
      errorMessage = "Failed to load: \(error.localizedDescription)"
    }
  }

  private func authorizeAndLoad() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      try await Github.authorize()
      await loadProfile()
    } catch {
      errorMessage = "Login failed: \(error.localizedDescription)"
    }
  }
  
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List {
        // Favorites section
        if !favoriteItems.isEmpty {
          Section("Favorites") {
            ForEach(favoriteItems) { favorite in
              NavigationLink(destination: FavoriteRepositoryDestination(favorite: favorite)) {
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
                }
              }
            }
          }
        }
        
        // Recent PRs section
        if !recentPRItems.isEmpty {
          Section("Recent PRs") {
            ForEach(recentPRItems.prefix(5)) { recent in
              NavigationLink(destination: RecentPRDestination(recentPR: recent)) {
                HStack {
                  Image(systemName: recent.state == "open" ? "circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(recent.state == "open" ? .green : .purple)
                    .font(.caption)
                  VStack(alignment: .leading, spacing: 2) {
                    Text("#\(recent.prNumber) \(recent.title)")
                      .font(.callout)
                      .lineLimit(1)
                    Text(recent.repoFullName)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }
        
        if isLoading {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .listRowBackground(Color.clear)
        } else if let error = errorMessage {
          Section {
            VStack(spacing: 12) {
              Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
              Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
              Button("Retry") {
                Task {
                  await loadProfile()
                }
              }
              .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
          }
          .listRowBackground(Color.clear)
        } else if hasToken && viewModel.me != nil {
          Section("Organizations") {
            ForEach(organizations) { organization in
              OrganizationRepositoryView(organization: organization)
            }
          }
        } else if hasToken {
          // Token exists but user data not loaded yet - show loading
          HStack {
            Spacer()
            ProgressView("Loading profile...")
            Spacer()
          }
          .listRowBackground(Color.clear)
        } else {
          Button("Login") {
            Task {
              await authorizeAndLoad()
            }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        // User profile pinned to bottom
        if hasToken, let me = viewModel.me {
          VStack(spacing: 0) {
            Divider()
            NavigationLink(destination: PersonalView(organizations: organizations)) {
              ProfileNameView(me: me)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 10)
          }
          #if os(macOS)
          .background(Color(nsColor: .windowBackgroundColor))
          #else
          .background(Color(.systemBackground))
          #endif
        }
      }
      .task {
        await loadProfile()
        persistAutomationTargets()
        syncAutomationSelection()
      }
#if os(macOS)
      .onChange(of: mcpServer.lastUIAction?.id) {
        guard let action = mcpServer.lastUIAction else { return }
        switch action.controlId {
        case "github.login":
          Task { await authorizeAndLoad() }
          mcpServer.recordUIActionHandled(action.controlId)
        case "github.refresh":
          Task { await loadProfile() }
          mcpServer.recordUIActionHandled(action.controlId)
        case "github.logout":
          Task {
            await Github.reauthorize()
            hasToken = false
            viewModel.me = nil
            organizations = []
          }
          mcpServer.recordUIActionHandled(action.controlId)
        default:
          break
        }
        mcpServer.lastUIAction = nil
      }
#endif
      } detail: {
        NavigationStack {
          detailRootView
        }
      }
    .navigationSplitViewStyle(.balanced)
    .environment(viewModel)
    .favoritesProvider(dataProvider)
    .recentPRsProvider(dataProvider)
    .onAppear {
      dataProvider = GitHubDataProvider(modelContext: modelContext)
      persistAutomationTargets()
      syncAutomationSelection()
    }
    .onChange(of: favoriteRecords) { _, _ in
      persistAutomationTargets()
      syncAutomationSelection()
    }
    .onChange(of: recentPRRecords) { _, _ in
      persistAutomationTargets()
      syncAutomationSelection()
    }
    .onChange(of: selectedFavoriteKey) { _, _ in
      syncAutomationSelection()
    }
    .onChange(of: selectedRecentPRKey) { _, _ in
      syncAutomationSelection()
    }
    .frame(idealHeight: 400)
    .toolbar {
#if os(macOS)
      ToolSelectionToolbar()
#endif
      ToolbarItem(placement: .navigation) {
        Menu {
          Toggle("Show Archived Repos", isOn: $showArchivedRepos)
          Divider()
          Button {
            Task {
              await Github.reauthorize()
              hasToken = false
              viewModel.me = nil
              organizations = []
            }
          } label: {
            Text("Logout")
            Image(systemName: "figure.wave")
          }
        } label: {
          Image(systemName: "gear")
        }
      }
    }
  }

  private var favoriteItems: [FavoriteRepository] {
    favoriteRecords.map { record in
      FavoriteRepository(
        id: record.githubRepoId,
        fullName: record.fullName,
        ownerLogin: record.ownerLogin,
        repoName: record.repoName,
        htmlURL: record.htmlURL,
        addedAt: record.addedAt
      )
    }
  }

  private var recentPRItems: [RecentPRInfo] {
    recentPRRecords.map { record in
      RecentPRInfo(
        id: record.githubPRId,
        prNumber: record.prNumber,
        title: record.title,
        repoFullName: record.repoFullName,
        state: record.state,
        htmlURL: record.htmlURL,
        viewedAt: record.viewedAt
      )
    }
  }

  private func favoriteAutomationKey(for favorite: FavoriteRepository) -> String {
    let key = favorite.fullName.isEmpty ? "\(favorite.ownerLogin)/\(favorite.repoName)" : favorite.fullName
    return key
  }

  private func recentPRAutomationKey(for recent: RecentPRInfo) -> String {
    "\(recent.repoFullName)#\(recent.prNumber)"
  }

  private func persistAutomationTargets() {
    let favoriteKeys = favoriteItems.map { favoriteAutomationKey(for: $0) }
    let recentPRKeys = recentPRItems.map { recentPRAutomationKey(for: $0) }
    UserDefaults.standard.set(favoriteKeys, forKey: "github.availableFavoriteKeys")
    UserDefaults.standard.set(recentPRKeys, forKey: "github.availableRecentPRKeys")
  }

  private func syncAutomationSelection() {
    if !selectedFavoriteKey.isEmpty,
       favoriteItems.contains(where: { favoriteAutomationKey(for: $0) == selectedFavoriteKey }) {
      selectedAutomationDestination = .favorite(selectedFavoriteKey)
    } else if !selectedRecentPRKey.isEmpty,
              recentPRItems.contains(where: { recentPRAutomationKey(for: $0) == selectedRecentPRKey }) {
      selectedAutomationDestination = .recentPR(selectedRecentPRKey)
    } else if selectedFavoriteKey.isEmpty && selectedRecentPRKey.isEmpty {
      selectedAutomationDestination = nil
    }
  }

  @ViewBuilder
  private var detailRootView: some View {
    if let selection = selectedAutomationDestination {
      switch selection {
      case .favorite(let key):
        if let favorite = favoriteItems.first(where: { favoriteAutomationKey(for: $0) == key }) {
          FavoriteRepositoryDestination(favorite: favorite)
        } else {
          Text("Favorite not found")
            .foregroundStyle(.secondary)
        }
      case .recentPR(let key):
        if let recent = recentPRItems.first(where: { recentPRAutomationKey(for: $0) == key }) {
          RecentPRDestination(recentPR: recent)
        } else {
          Text("PR not found")
            .foregroundStyle(.secondary)
        }
      }
    } else {
      Text("Select an organization or repository")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Destination Views

/// Loads and displays a favorited repository
struct FavoriteRepositoryDestination: View {
  let favorite: FavoriteRepository
  
  @State private var repository: Github.Repository?
  @State private var owner: Github.User?
  @State private var isLoading = true
  @State private var error: String?
  
  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading repository...")
      } else if let error {
        VStack {
          Text("Failed to load repository")
            .font(.headline)
          Text(error)
            .foregroundStyle(.secondary)
          Button("Retry") {
            Task { await loadRepository() }
          }
        }
      } else if let repository, let owner {
        RepositoryContainerView(organization: owner, repository: repository)
      }
    }
    .task {
      await loadRepository()
    }
  }
  
  private func loadRepository() async {
    isLoading = true
    error = nil
    do {
      async let repoTask = Github.repository(owner: favorite.ownerLogin, name: favorite.repoName)
      async let ownerTask = Github.user(login: favorite.ownerLogin)
      (repository, owner) = try await (repoTask, ownerTask)
    } catch {
      self.error = error.localizedDescription
    }
    isLoading = false
  }
}

/// Loads and displays a recent PR
struct RecentPRDestination: View {
  let recentPR: RecentPRInfo
  
  @State private var isLoading = true
  @State private var error: String?
  
  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading PR...")
      } else if let error {
        VStack {
          Text("Failed to load PR")
            .font(.headline)
          Text(error)
            .foregroundStyle(.secondary)
        }
      } else {
        VStack(spacing: 16) {
          Text("#\(recentPR.prNumber)")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text(recentPR.title)
            .font(.title2)
          Text(recentPR.repoFullName)
            .foregroundStyle(.secondary)
          
          if let urlString = recentPR.htmlURL, let url = URL(string: urlString) {
            Link(destination: url) {
              Label("Open in Browser", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
          }
        }
        .padding()
      }
    }
    .task {
      isLoading = false
    }
  }
}

// MARK: - GitHub Data Provider

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

#Preview {
  Github_RootView()
}
