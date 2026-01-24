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
#if canImport(Github)
import Github
#endif

#if canImport(Github)
struct Github_RootView: View {
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
  @Environment(\.reviewWithAgentProvider) private var reviewWithAgentProvider
  let recentPR: RecentPRInfo
  
  @State private var isLoading = true
  @State private var error: String?
  @State private var pullRequest: Github.PullRequest?
  @State private var repository: Github.Repository?
  @State private var owner: Github.User?
  @State private var descriptionText: String = ""
  @State private var showingReviewLocally = false
  
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
      } else if let pullRequest, let repository {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            headerView(pullRequest: pullRequest, repository: repository)

            Divider()

            if !descriptionText.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                  .font(.headline)
                Text(.init(descriptionText))
                  .font(.body)
                  .foregroundStyle(.primary)
              }
            }

            metadataGrid(pullRequest: pullRequest, repository: repository)

            HStack(spacing: 12) {
              if let urlString = pullRequest.html_url ?? recentPR.htmlURL,
                 let url = URL(string: urlString) {
                Link(destination: url) {
                  Label("Open in Browser", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
              }
              Button {
                showingReviewLocally = true
              } label: {
                Label("Review Locally", systemImage: "arrow.down.to.line.circle")
              }
              .buttonStyle(.bordered)
              #if !os(macOS)
              .hidden()
              #endif

              Button {
                reviewWithAgentProvider?.reviewWithAgent(pr: pullRequest, repo: repository)
              } label: {
                Label("Review with Agent", systemImage: "sparkles")
              }
              .buttonStyle(.borderedProminent)
              .disabled(reviewWithAgentProvider == nil)
            }
          }
          .padding()
        }
      } else {
        Text("PR details unavailable")
          .foregroundStyle(.secondary)
      }
    }
    .task {
      await loadPullRequestDetails()
    }
    #if os(macOS)
    .sheet(isPresented: $showingReviewLocally) {
      if let pullRequest, let repository {
        ReviewLocallySheet(pullRequest: pullRequest, repository: repository)
      }
    }
    #endif
  }

  private func loadPullRequestDetails() async {
    isLoading = true
    error = nil
    defer { isLoading = false }

    let parts = recentPR.repoFullName.split(separator: "/")
    guard parts.count == 2 else {
      error = "Invalid repository name"
      return
    }

    let ownerLogin = String(parts[0])
    let repoName = String(parts[1])

    do {
      async let repoTask = Github.repository(owner: ownerLogin, name: repoName)
      async let prTask = Github.pullRequest(owner: ownerLogin, repository: repoName, number: recentPR.prNumber)
      let (repo, pr) = try await (repoTask, prTask)
      repository = repo
      pullRequest = pr
      owner = pr.base.user ?? repo.owner
      descriptionText = (pr.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      self.error = error.localizedDescription
    }
  }

  @ViewBuilder
  private func headerView(pullRequest: Github.PullRequest, repository: Github.Repository) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(pullRequest.title ?? recentPR.title)
        .font(.title2)
      Text("#\(pullRequest.number) · \(recentPR.repoFullName)")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        if let state = pullRequest.state {
          Label(state.capitalized, systemImage: state == "open" ? "circle.fill" : "checkmark.circle.fill")
            .foregroundStyle(state == "open" ? .green : .purple)
        }
        Label(pullRequest.head.ref, systemImage: "arrow.triangle.branch")
        if pullRequest.draft == true {
          Label("Draft", systemImage: "square.and.pencil")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func metadataGrid(pullRequest: Github.PullRequest, repository: Github.Repository) -> some View {
    let created = formattedDate(pullRequest.created_at)
    let updated = formattedDate(pullRequest.updated_at)
    let author = pullRequest.user?.publicName ?? "Unknown"
    let reviewers = (pullRequest.requested_reviewers ?? []).map { $0.publicName }.filter { !$0.isEmpty }
    let labels = (pullRequest.labels ?? []).map { $0.name }.filter { !$0.isEmpty }

    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 16) {
        metadataItem("Author", author)
        metadataItem("Updated", updated)
        metadataItem("Created", created)
      }
      HStack(spacing: 16) {
        metadataItem("Commits", pullRequest.commits.map(String.init) ?? "–")
        metadataItem("Files", pullRequest.changed_files.map(String.init) ?? "–")
        metadataItem("+/-", diffSummary(for: pullRequest))
      }
      if !reviewers.isEmpty {
        metadataItem("Reviewers", reviewers.joined(separator: ", "))
      }
      if !labels.isEmpty {
        metadataItem("Labels", labels.joined(separator: ", "))
      }
    }
  }

  private func metadataItem(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout)
    }
  }

  private func formattedDate(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "–" }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) {
      return date.formatted(date: .abbreviated, time: .shortened)
    }
    return value
  }

  private func diffSummary(for pullRequest: Github.PullRequest) -> String {
    let additions = pullRequest.additions ?? 0
    let deletions = pullRequest.deletions ?? 0
    if additions == 0 && deletions == 0 {
      return "–"
    }
    return "+\(additions) / -\(deletions)"
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
