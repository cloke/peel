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
import PeelUI
#if canImport(Github)
import Github
#endif

#if canImport(Github)
struct Github_RootView: View {
  var showToolSelectionToolbar = true

  #if os(macOS)
  @Environment(MCPServerService.self) private var mcpServer
  #endif
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \GitHubFavorite.addedAt, order: .reverse) private var favoriteRecords: [GitHubFavorite]
  @Query(sort: \RecentPullRequest.viewedAt, order: .reverse) private var recentPRRecords: [RecentPullRequest]
  @State public var viewModel = Github.ViewModel()
  @State private var dataProvider: GitHubDataProvider?
  #if os(macOS)
  @State private var reviewAgentCoordinator = PRReviewAgentCoordinator()
  @State private var reviewAgentTarget: PRReviewAgentTarget?
  #endif
  
  @State private var organizations = [Github.User]()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var hasToken = false
  @State private var isLoading = false
  @State private var errorMessage: String?
  @AppStorage("github-show-archived") private var showArchivedRepos = false
  @AppStorage("github.automationSelectedFavoriteKey") private var automationSelectedFavoriteKey: String = ""
  @AppStorage("github.automationSelectedRecentPRKey") private var automationSelectedRecentPRKey: String = ""
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
          Section {
            ForEach(groupedFavorites, id: \.owner) { group in
              if groupedFavorites.count > 1 {
                ForEach(group.repos) { favorite in
                  NavigationLink(destination: FavoriteRepositoryDestination(favorite: favorite)) {
                    Label {
                      Text(favorite.fullName)
                        .font(.callout)
                    } icon: {
                      Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                  }
                }
              } else {
                ForEach(group.repos) { favorite in
                  NavigationLink(destination: FavoriteRepositoryDestination(favorite: favorite)) {
                    Label {
                      Text(favorite.repoName)
                        .font(.callout)
                    } icon: {
                      Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                  }
                }
              }
            }
          } header: {
            HStack(alignment: .center, spacing: 4) {
              Label("Favorites", systemImage: "star.fill")
              Spacer()
              Text("\(favoriteItems.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
          }
        }
        
        // Recent PRs section
        if !recentPRItems.isEmpty {
          Section {
            ForEach(recentPRItems.prefix(5)) { recent in
              NavigationLink(destination: RecentPRDestination(recentPR: recent)) {
                HStack(spacing: 6) {
                  Image(systemName: recentPRIcon(for: recent.state))
                    .foregroundStyle(recentPRColor(for: recent.state))
                    .font(.system(size: 8))
                  VStack(alignment: .leading, spacing: 1) {
                    Text(recent.title)
                      .font(.callout)
                      .lineLimit(1)
                    Text("\(recent.repoFullName)  #\(recent.prNumber)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                    Text(recentPRTimeAgo(recent.viewedAt))
                      .font(.caption2)
                      .foregroundStyle(.tertiary)
                      .monospacedDigit()
                  }
                }
                .contentShape(Rectangle())
              }
              .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
            }
          } header: {
            Label("Recent PRs", systemImage: "clock")
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
          Section {
            ForEach(organizations) { organization in
              OrganizationRepositoryView(organization: organization)
            }
          } header: {
            Label("Organizations", systemImage: "building.2")
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

        // Profile link at bottom of sidebar
        if hasToken, let me = viewModel.me {
          Section {
            NavigationLink(destination: PersonalView(organizations: organizations)) {
              ProfileNameView(me: me)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
          }
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
    .localRepoResolver(dataProvider)
    #if os(macOS)
    .reviewWithAgentProvider(reviewAgentCoordinator)
    .sheet(item: $reviewAgentTarget) { target in
      GithubReviewAgentSheet(target: target)
    }
    #else
    .reviewWithAgentProvider(nil)
    #endif
    .onAppear {
      dataProvider = GitHubDataProvider(modelContext: modelContext)
      persistAutomationTargets()
      syncAutomationSelection()
      #if os(macOS)
      reviewAgentCoordinator.onReview = { pr, repo in
        reviewAgentTarget = PRReviewAgentTarget.from(pullRequest: pr, repository: repo)
      }
      #endif
    }
    .onChange(of: favoriteRecords) { _, _ in
      persistAutomationTargets()
      syncAutomationSelection()
    }
    .onChange(of: recentPRRecords) { _, _ in
      persistAutomationTargets()
      syncAutomationSelection()
    }
    .onChange(of: automationSelectedFavoriteKey) { _, _ in
      syncAutomationSelection()
    }
    .onChange(of: automationSelectedRecentPRKey) { _, _ in
      syncAutomationSelection()
    }
    .frame(idealHeight: 400)
    .toolbar {
      #if os(macOS)
      if showToolSelectionToolbar {
        ToolSelectionToolbar()
      }
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
    // Deduplicate by githubRepoId AND by ownerLogin+repoName.
    // CloudKit sync can create duplicate rows (no @Attribute(.unique) with iCloud),
    // and repos recreated on GitHub get new IDs but keep the same name.
    var seenIds = Set<Int>()
    var seenNames = Set<String>()
    return favoriteRecords.compactMap { record in
      guard seenIds.insert(record.githubRepoId).inserted else { return nil }
      let nameKey = "\(record.ownerLogin)/\(record.repoName)".lowercased()
      guard seenNames.insert(nameKey).inserted else { return nil }
      return FavoriteRepository(
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

  private struct FavoriteGroup {
    let owner: String
    let repos: [FavoriteRepository]
  }

  private var groupedFavorites: [FavoriteGroup] {
    let grouped = Dictionary(grouping: favoriteItems) { $0.ownerLogin }
    return grouped.keys.sorted().map { owner in
      FavoriteGroup(owner: owner, repos: grouped[owner] ?? [])
    }
  }

  private func recentPRIcon(for state: String) -> String {
    switch state {
    case "open": "circle.fill"
    case "closed": "xmark.circle.fill"
    case "merged": "arrow.triangle.merge"
    default: "circle"
    }
  }

  private func recentPRColor(for state: String) -> Color {
    switch state {
    case "open": .green
    case "closed": .red
    case "merged": .purple
    default: .secondary
    }
  }

  private func recentPRTimeAgo(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
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
    if !automationSelectedFavoriteKey.isEmpty,
       favoriteItems.contains(where: { favoriteAutomationKey(for: $0) == automationSelectedFavoriteKey }) {
      selectedAutomationDestination = .favorite(automationSelectedFavoriteKey)
    } else if !automationSelectedRecentPRKey.isEmpty,
              recentPRItems.contains(where: { recentPRAutomationKey(for: $0) == automationSelectedRecentPRKey }) {
      selectedAutomationDestination = .recentPR(automationSelectedRecentPRKey)
    } else if automationSelectedFavoriteKey.isEmpty && automationSelectedRecentPRKey.isEmpty {
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
    } else if viewModel.me != nil {
      PersonalView(organizations: organizations)
        .id(organizations.count)
    } else if isLoading {
      ProgressView("Loading profile…")
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
  
  var body: some View {
    AsyncContentView(
      load: {
        async let repoTask = Github.repository(owner: favorite.ownerLogin, name: favorite.repoName)
        async let ownerTask = Github.user(login: favorite.ownerLogin)
        return try await (repo: repoTask, owner: ownerTask)
      },
      isEmpty: { _ in false },
      content: { data in
        RepositoryContainerView(organization: data.owner, repository: data.repo)
      },
      loadingView: { ProgressView("Loading repository...") },
      emptyView: { EmptyView() }
    )
  }
}

/// Loads and displays a recent PR using the shared PullRequestDetailView
struct RecentPRDestination: View {
  let recentPR: RecentPRInfo

  private enum LoadState {
    case loading
    case loaded(pr: Github.PullRequest, repo: Github.Repository, owner: Github.User?)
    case error(String)
  }

  @State private var state: LoadState = .loading

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView("Loading PR...")
      case .error(let message):
        ErrorView(title: "Failed to load PR", message: message) {
          Task { await loadPullRequestDetails() }
        }
      case .loaded(let pr, let repo, let owner):
        PullRequestDetailView(organization: owner, repository: repo, pullRequest: pr)
      }
    }
    .task(id: recentPR.id) {
      await loadPullRequestDetails()
    }
  }

  private func loadPullRequestDetails() async {
    state = .loading

    let parts = recentPR.repoFullName.split(separator: "/")
    guard parts.count == 2 else {
      state = .error("Invalid repository name")
      return
    }

    let ownerLogin = String(parts[0])
    let repoName = String(parts[1])

    do {
      async let repoTask = Github.repository(owner: ownerLogin, name: repoName)
      async let prTask = Github.pullRequest(owner: ownerLogin, repository: repoName, number: recentPR.prNumber)
      let (repo, pr) = try await (repoTask, prTask)
      state = .loaded(pr: pr, repo: repo, owner: pr.base.user ?? repo.owner)
    } catch is CancellationError {
      return
    } catch let urlError as URLError where urlError.code == .cancelled {
      return
    } catch {
      state = .error(error.localizedDescription)
    }
  }
}

// MARK: - GitHub Data Provider

@MainActor
final class PRReviewAgentCoordinator: PRReviewAgentProvider {
  var onReview: ((Github.PullRequest, Github.Repository) -> Void)?

  func reviewWithAgent(pr: Github.PullRequest, repo: Github.Repository) {
    onReview?(pr, repo)
  }
}

/// Provides GitHub favorites and recent PRs backed by SwiftData
@MainActor
@Observable
final class GitHubDataProvider: GitHubFavoritesProvider, RecentPRsProvider, LocalRepoResolver {
  private let modelContext: ModelContext
  
  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }
  
  // MARK: - LocalRepoResolver
  
  func localPath(for githubRepo: Github.Repository) -> String? {
    guard let fullName = githubRepo.full_name else { return nil }
    let possibleURLs = [
      "git@github.com:\(fullName).git",
      "https://github.com/\(fullName).git",
      "https://github.com/\(fullName)",
      "git@github.com:\(fullName)"
    ].map { $0.lowercased() }
    
    // Fetch all synced repos and check their remote URLs
    let descriptor = FetchDescriptor<SyncedRepository>()
    guard let syncedRepos = try? modelContext.fetch(descriptor) else { return nil }
    
    for syncedRepo in syncedRepos {
      guard let remoteURL = syncedRepo.remoteURL?.lowercased() else { continue }
      if possibleURLs.contains(where: { remoteURL.contains($0) }) || remoteURL.contains(fullName.lowercased()) {
        // Found a match in SyncedRepository, now get its local path
        let repoId = syncedRepo.id
        let pathDescriptor = FetchDescriptor<LocalRepositoryPath>(
          predicate: #Predicate { $0.repositoryId == repoId && $0.isValid == true }
        )
        if let localPath = try? modelContext.fetch(pathDescriptor).first {
          return localPath.localPath
        }
      }
    }
    
    // Also check by name as a fallback (e.g. "tio-api" matches repo named "tio-api")
    let repoName = githubRepo.name.lowercased()
    for syncedRepo in syncedRepos {
      if syncedRepo.name.lowercased() == repoName {
        let repoId = syncedRepo.id
        let pathDescriptor = FetchDescriptor<LocalRepositoryPath>(
          predicate: #Predicate { $0.repositoryId == repoId && $0.isValid == true }
        )
        if let localPath = try? modelContext.fetch(pathDescriptor).first {
          return localPath.localPath
        }
      }
    }
    
    return nil
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

    // Also check by owner+name — the repo may have been recreated with a new ID.
    // Remove stale records for the same owner/name before inserting.
    let ownerLogin = repo.owner?.login ?? "unknown"
    let repoName = repo.name
    let nameDescriptor = FetchDescriptor<GitHubFavorite>(
      predicate: #Predicate { $0.ownerLogin == ownerLogin && $0.repoName == repoName }
    )
    if let staleRecords = try? modelContext.fetch(nameDescriptor), !staleRecords.isEmpty {
      for stale in staleRecords {
        modelContext.delete(stale)
      }
    }

    let favorite = GitHubFavorite(
      githubRepoId: repo.id,
      fullName: repo.full_name ?? repo.name,
      ownerLogin: ownerLogin,
      repoName: repoName,
      htmlURL: repo.html_url
    )
    modelContext.insert(favorite)
    try? modelContext.save()
  }
  
  func removeFavorite(repoId: Int) {
    let descriptor = FetchDescriptor<GitHubFavorite>(
      predicate: #Predicate { $0.githubRepoId == repoId }
    )
    guard let favorite = try? modelContext.fetch(descriptor).first else { return }

    // Also remove any stale duplicates with the same owner+name but different IDs
    let ownerLogin = favorite.ownerLogin
    let repoName = favorite.repoName
    let nameDescriptor = FetchDescriptor<GitHubFavorite>(
      predicate: #Predicate { $0.ownerLogin == ownerLogin && $0.repoName == repoName }
    )
    if let allMatches = try? modelContext.fetch(nameDescriptor) {
      for match in allMatches {
        modelContext.delete(match)
      }
    } else {
      modelContext.delete(favorite)
    }
    try? modelContext.save()
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
#else
struct Github_RootView: View {
  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("GitHub Unavailable", systemImage: "person.2.fill")
      } description: {
        Text("This build does not include the GitHub package.")
      }
      .navigationTitle("GitHub")
    }
  }
}
#endif
