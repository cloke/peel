//
//  ContentView.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Combine
import Git
import Github

// MARK: - Navigation Model

/// Top-level sections in the sidebar. Kept compatible with the `current-tool`
/// AppStorage key used by Cmd+1/Cmd+2 and MCP UI automation.
enum CurrentTool: String, Identifiable, CaseIterable {
  case repositories = "repositories"
  case activity = "activity"
  // Legacy cases — kept for AppStorage migration only (old stored values must deserialize).
  // Do NOT remove. These are excluded from visibleCases so they don't appear in UI.
  case agents = "agents"
  case workspaces = "workspaces"
  case brew = "brew"
  case git = "git"
  case github = "github"
  case swarm = "swarm"
  var id: String { rawValue }

  /// Active sidebar sections shown in UI. Legacy migration cases are intentionally excluded.
  static var visibleCases: [CurrentTool] { [.repositories, .activity] }
}

/// What the user selected in the sidebar. The detail pane renders based on this.
enum SidebarSelection: Hashable {
  // Repositories
  case repo(String)
  case repoCommandCenter  // No repo selected → overview

  // Activity
  case activityDashboard
  case activityItem(UUID)  // Non-chain activity item → shows dashboard
  case chain(UUID)
  case prReviews
  case templates

  // Swarm
  case swarmConsole

  // Brew
  case brew
}

// MARK: - Content View

/// Entry point for macOS — source-list sidebar + detail layout.
struct ContentView: View {
  @AppStorage(wrappedValue: .repositories, "current-tool") private var currentSection: CurrentTool
  @AppStorage("feature.showBrew") private var showBrew = false
  @AppStorage("onboarding.checklistDismissed") private var checklistDismissed = false
  @AppStorage("repositories.selectedRepoKey") private var automationSelectedRepoKey = ""
  @AppStorage("repositories.searchText") private var automationRepoSearchText = ""

  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(ActivityFeed.self) private var activityFeed
  @Environment(DataService.self) private var dataService

  @State private var firebaseService = FirebaseService.shared
  @State private var swarm = SwarmCoordinator.shared

  @State private var sidebarSelection: SidebarSelection? = .repoCommandCenter
  @State private var repoSearchText = ""
  @State private var repoFilterMode: RepoFilterMode = .all
  @State private var showAddRepoSheet = false
  @State private var showingInvitePreview = false
  @State private var showChecklist = false
  @State private var showCommandPalette = false
  @State private var activeLabFeature: LabFeature?

  private struct RepositoryAutomationEntry {
    let key: String
    let name: String
  }

  var body: some View {
    NavigationSplitView {
      sidebarContent
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      detailContent
    }
    .navigationTitle(navigationTitle)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        toolbarActions
      }
      ChainActivityToolbar()
      if !checklistDismissed {
        ToolbarItem(placement: .automatic) {
          Button { showChecklist = true } label: {
            Image(systemName: "checklist")
          }
          .help("Feature Discovery Checklist")
        }
      }
      LabsToolbarItem(activeLabFeature: $activeLabFeature)
    }
    .searchable(
      text: $repoSearchText,
      placement: .sidebar,
      prompt: "Search repositories…"
    )
    .onAppear {
      migrateLegacySection(currentSection)
      persistRepositoryAutomationState()
      syncRepoSelectionFromAutomation()
      syncSelectionToSection()
      if !checklistDismissed { showChecklist = true }
    }
    .onChange(of: currentSection) { _, newValue in
      migrateLegacySection(newValue)
      syncSelectionToSection()
    }
    .onChange(of: aggregator.repositories.map(\ .normalizedRemoteURL)) { _, _ in
      persistRepositoryAutomationState()
      syncRepoSelectionFromAutomation()
      reconcileRepoSelection()
    }
    .onChange(of: automationSelectedRepoKey) { _, _ in
      syncRepoSelectionFromAutomation()
    }
    .onChange(of: automationRepoSearchText) { _, newValue in
      if repoSearchText != newValue {
        repoSearchText = newValue
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      // Sync navigation first — MCP writes current-tool via UserDefaults.
      // Must run before syncRepoSelectionFromAutomation which can override it.
      if let raw = UserDefaults.standard.string(forKey: "current-tool"),
         let tool = CurrentTool(rawValue: raw),
         tool != currentSection {
        currentSection = tool
      }
      // Only sync repo selection when on repositories view to avoid
      // overriding MCP navigation to other views.
      if currentSection == .repositories {
        syncRepoSelectionFromAutomation()
      }
      if repoSearchText != automationRepoSearchText {
        repoSearchText = automationRepoSearchText
      }
    }
    .onChange(of: sidebarSelection) { _, newValue in
      // Keep currentSection in sync so Cmd+1/2 and MCP still work
      if let sel = newValue {
        switch sel {
        case .repo, .repoCommandCenter: currentSection = .repositories
        case .activityDashboard, .activityItem, .chain, .prReviews, .templates: currentSection = .activity
        case .swarmConsole: currentSection = .activity
        case .brew: currentSection = .brew
        }
      }
      persistSelectedRepoAutomationState()
    }
    .onChange(of: showBrew) { _, newValue in
      if !newValue && currentSection == .brew { currentSection = .repositories }
    }
    .onChange(of: firebaseService.pendingInvitePreview) { _, newValue in
      if newValue != nil { showingInvitePreview = true }
    }
    .onChange(of: firebaseService.memberSwarms) {
      guard swarm.isActive, firebaseService.isSignedIn else { return }
      for membership in firebaseService.memberSwarms where membership.role.canRegisterWorkers {
        firebaseService.startWorkerListener(swarmId: membership.id)
        firebaseService.startMessageListener(swarmId: membership.id)
      }
    }
    .sheet(isPresented: $showingInvitePreview) {
      if let preview = firebaseService.pendingInvitePreview {
        InvitePreviewSheet(preview: preview, firebaseService: firebaseService)
      }
    }
    .sheet(isPresented: $showChecklist) {
      FeatureDiscoveryChecklistView()
    }
    .sheet(item: $activeLabFeature) { feature in
      LabFeatureSheetContent(feature: feature)
    }
    .sheet(isPresented: $showAddRepoSheet) {
      AddRepositorySheet()
    }
    .overlay {
      if showCommandPalette {
        ZStack {
          Color.black.opacity(0.3)
            .ignoresSafeArea()
            .onTapGesture { showCommandPalette = false }
          CommandPaletteView(isPresented: $showCommandPalette)
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .animation(.spring(response: 0.25), value: showCommandPalette)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openCommandPalette)) { _ in
      showCommandPalette.toggle()
    }
    .onReceive(NotificationCenter.default.publisher(for: .navigateToTool)) { notification in
      if let tool = notification.object as? CurrentTool {
        currentSection = tool
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .navigateToSwarmConsole)) { _ in
      currentSection = .activity
      sidebarSelection = .swarmConsole
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RepositoryAutomationRepoSelected"))) { notification in
      guard let repoKey = notification.object as? String else { return }
      currentSection = .repositories
      if aggregator.repositoryByURL[repoKey] != nil {
        sidebarSelection = .repo(repoKey)
      } else {
        syncRepoSelectionFromAutomation()
      }
    }
    .task {
      await populateRepoRegistry()
      aggregator.rebuild()
    }
  }

  private var navigationTitle: String {
    switch currentSection {
    case .repositories: "Repositories"
    case .activity, .agents, .workspaces, .swarm: "Activity"
    case .brew: "Homebrew"
    case .git, .github: "Repositories"
    }
  }

  // MARK: - Sidebar

  private var sidebarContent: some View {
    List(selection: $sidebarSelection) {
      // Top-level navigation
      Section {
        Label("Repositories", systemImage: "tray.full")
          .tag(SidebarSelection.repoCommandCenter)
        Label("Activity", systemImage: "bolt.fill")
          .badge(runningChainCount)
          .tag(SidebarSelection.activityDashboard)
        if showBrew {
          Label("Homebrew", systemImage: "mug")
            .tag(SidebarSelection.brew)
        }
      }

      // Contextual content based on active section
      switch currentSection {
      case .repositories, .git, .github:
        repoSidebarSection
      case .activity, .agents, .workspaces, .swarm:
        activitySidebarSection
      case .brew:
        EmptyView()
      }

      // Swarm status — always visible
      swarmSidebarSection
    }
    .listStyle(.sidebar)
  }

  // MARK: - Repo Sidebar Section

  private var repoSidebarSection: some View {
    Section("Repositories") {
      // Filter chips
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(RepoFilterMode.allCases, id: \.self) { mode in
            FilterChip(
              title: mode.rawValue,
              count: countForFilter(mode),
              isSelected: repoFilterMode == mode
            ) {
              withAnimation(.easeInOut(duration: 0.15)) {
                repoFilterMode = mode
              }
            }
          }
        }
      }

      ForEach(filteredRepositories) { repo in
        RepoSidebarRow(repo: repo)
          .tag(SidebarSelection.repo(repo.normalizedRemoteURL))
          .contextMenu {
            repoContextMenu(for: repo)
          }
      }

      if filteredRepositories.isEmpty {
        if repoSearchText.isEmpty {
          ContentUnavailableView(
            "No Repositories",
            systemImage: "folder",
            description: Text("No repositories match this filter.")
          )
        } else {
          ContentUnavailableView.search(text: repoSearchText)
        }
      }
    }
  }

  // MARK: - Activity Sidebar Section

  private var activitySidebarSection: some View {
    Group {
      // Running chains
      let runningChains = aggregator.allActiveChains
      if !runningChains.isEmpty {
        Section("Running") {
          ForEach(runningChains) { chain in
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.mini)
              VStack(alignment: .leading, spacing: 2) {
                Text(chain.name)
                  .font(.callout)
                  .lineLimit(1)
                if let prompt = chain.initialPrompt {
                  Text(prompt.prefix(60))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
            }
            .tag(SidebarSelection.chain(chain.id))
          }
        }
      }

      Section("Activity") {
        Label("Dashboard", systemImage: "gauge.medium")
          .tag(SidebarSelection.activityDashboard)
        Label("PR Reviews", systemImage: "text.badge.checkmark")
          .badge(prReviewCount)
          .tag(SidebarSelection.prReviews)
        Label("Templates", systemImage: "rectangle.stack")
          .tag(SidebarSelection.templates)
      }

      // Recent activity feed in sidebar
      let recentItems = Array(activityFeed.items.prefix(15))
      if !recentItems.isEmpty {
        Section("Recent") {
          ForEach(recentItems) { item in
            activitySidebarRow(item)
          }
        }
      }
    }
  }

  // MARK: - Swarm Sidebar Section

  private var swarmSidebarSection: some View {
    Section("Swarm") {
      if swarm.isActive {
        let onlineWAN = wanWorkers.filter { $0.status == .online }.count
        let totalOnline = swarm.connectedWorkers.count + 1 + onlineWAN

        Label {
          HStack(spacing: 4) {
            Text("\(totalOnline) online")
              .font(.caption)
            if swarm.tasksCompleted > 0 {
              Text("· \(swarm.tasksCompleted) done")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } icon: {
          Circle()
            .fill(.green)
            .frame(width: 8, height: 8)
        }
        .tag(SidebarSelection.swarmConsole)

        // Show individual workers inline
        ForEach(swarm.connectedWorkers) { peer in
          HStack(spacing: 6) {
            Circle()
              .fill(.green)
              .frame(width: 6, height: 6)
            Text(peer.displayName)
              .font(.caption)
              .lineLimit(1)
          }
          .padding(.leading, 4)
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
          .onTapGesture {
            sidebarSelection = .swarmConsole
          }
        }

        ForEach(wanWorkers.filter { $0.status == .online }, id: \.id) { worker in
          HStack(spacing: 6) {
            Circle()
              .fill(.green)
              .frame(width: 6, height: 6)
            Text(worker.displayName)
              .font(.caption)
              .lineLimit(1)
            Text("WAN")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          .padding(.leading, 4)
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
          .onTapGesture {
            sidebarSelection = .swarmConsole
          }
        }
      } else {
        Label("Start Swarm", systemImage: "network.slash")
          .font(.caption)
          .foregroundStyle(.secondary)
          .tag(SidebarSelection.swarmConsole)
      }
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private var detailContent: some View {
    switch sidebarSelection {
    case .repo(let normalizedRemoteURL):
      if let repo = aggregator.repositoryByURL[normalizedRemoteURL] {
        RepoDetailView(repo: repo)
      } else {
        ContentUnavailableView("Repository Not Found", systemImage: "questionmark.folder")
      }

    case .repoCommandCenter:
      RepositoriesCommandCenter()

    case .activityDashboard:
      ActivityDashboardView()

    case .chain(let id):
      if let chain = mcpServer.agentManager.chains.first(where: { $0.id == id }) {
        ChainDetailView(
          chain: chain,
          agentManager: mcpServer.agentManager,
          cliService: mcpServer.cliService,
          sessionTracker: mcpServer.sessionTracker
        )
      } else {
        ContentUnavailableView("Chain Not Found", systemImage: "bolt.slash")
      }

    case .activityItem(let id):
      if let item = activityFeed.items.first(where: { $0.id == id }) {
        ActivityItemDetailView(item: item)
      } else {
        ActivityDashboardView()
      }

    case .prReviews:
      PRReviewQueueDetailView()

    case .templates:
      TemplateBrowserDetailView { chainId in
        sidebarSelection = .chain(chainId)
      }

    case .swarmConsole:
      SwarmManagementView()

    case .brew:
      Brew_RootView()

    case .none:
      ContentUnavailableView("Select an Item", systemImage: "sidebar.leading")
    }
  }

  // MARK: - Toolbar Actions

  @ViewBuilder
  private var toolbarActions: some View {
    switch currentSection {
    case .repositories, .git, .github:
      HStack(spacing: 8) {
        Button { showAddRepoSheet = true } label: {
          Image(systemName: "plus")
        }
        .help("Add Repository")
        Button { aggregator.rebuild() } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh")
      }
    case .activity, .agents, .workspaces, .swarm:
      Button { sidebarSelection = .templates } label: {
        Label("Run Task", systemImage: "play.fill")
      }
    case .brew:
      EmptyView()
    }
  }

  // MARK: - Helpers

  private var runningChainCount: Int {
    aggregator.allActiveChains.count
  }

  private var prReviewCount: Int {
    mcpServer.prReviewQueue.activeItems.count
  }

  private var wanWorkers: [FirestoreWorker] {
    let localDeviceId = swarm.capabilities.deviceId
    let lanPeerIds = Set(swarm.connectedWorkers.map(\.id))
    return firebaseService.swarmWorkers.filter { worker in
      worker.id != localDeviceId && !lanPeerIds.contains(worker.id)
    }
  }

  private func activityItemTag(_ item: ActivityItem) -> SidebarSelection {
    if let chainId = activityItemChainId(item) {
      return .chain(chainId)
    }
    return .activityDashboard
  }

  private func activityItemChainId(_ item: ActivityItem) -> UUID? {
    switch item.kind {
    case .chainStarted(let id), .chainCompleted(let id, _):
      return id
    default:
      return nil
    }
  }

  /// Sidebar row for a recent activity item. Chain items are tagged for selection;
  /// non-chain items are display-only to avoid the multi-select highlight bug.
  @ViewBuilder
  private func activitySidebarRow(_ item: ActivityItem) -> some View {
    let row = HStack(spacing: 8) {
      Image(systemName: item.kind.systemImage)
        .font(.caption)
        .foregroundStyle(item.isError ? .red : .secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title)
          .font(.caption)
          .lineLimit(1)
        Text(item.relativeTime)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }

    if let chainId = activityItemChainId(item) {
      row.tag(SidebarSelection.chain(chainId))
    } else {
      row.tag(SidebarSelection.activityItem(item.id))
    }
  }

  private func syncSelectionToSection() {
    switch currentSection {
    case .repositories, .git, .github:
      if case .repo = sidebarSelection { return }
      sidebarSelection = .repoCommandCenter
    case .activity, .agents, .workspaces, .swarm:
      if case .chain = sidebarSelection { return }
      if case .prReviews = sidebarSelection { return }
      if case .activityItem = sidebarSelection { return }
      if case .swarmConsole = sidebarSelection { return }
      sidebarSelection = .activityDashboard
    case .brew:
      sidebarSelection = .brew
    }
  }

  private func reconcileRepoSelection() {
    guard case .repo(let normalizedRemoteURL) = sidebarSelection else { return }
    guard aggregator.repositoryByURL[normalizedRemoteURL] == nil else { return }
    sidebarSelection = .repoCommandCenter
    persistSelectedRepoAutomationState()
  }

  private func syncRepoSelectionFromAutomation() {
    guard !automationSelectedRepoKey.isEmpty,
          aggregator.repositoryByURL[automationSelectedRepoKey] != nil else { return }
    if sidebarSelection != .repo(automationSelectedRepoKey) {
      currentSection = .repositories
      sidebarSelection = .repo(automationSelectedRepoKey)
    }
  }

  private func persistRepositoryAutomationState() {
    let repos = aggregator.repositories
    let automationEntries = repositoryAutomationEntries(for: repos)
    let keys = automationEntries.map(\.key)
    let names = automationEntries.map(\.name)
    let nameAliases = automationEntries.map { ($0.name, $0.key) }
      + repos.map { ($0.displayName, $0.normalizedRemoteURL) }
    let nameMap = Dictionary(
      nameAliases,
      uniquingKeysWith: { first, _ in first }
    )

    UserDefaults.standard.set(keys, forKey: "repositories.availableRepoKeys")
    UserDefaults.standard.set(names, forKey: "repositories.availableRepoNames")
    if let data = try? JSONEncoder().encode(nameMap) {
      UserDefaults.standard.set(data, forKey: "repositories.repoKeyByName")
    }
    persistSelectedRepoAutomationState()
  }

  private func persistSelectedRepoAutomationState() {
    guard case .repo(let normalizedRemoteURL) = sidebarSelection,
          let repo = aggregator.repositoryByURL[normalizedRemoteURL] else {
      UserDefaults.standard.set("", forKey: "repositories.selectedRepoKey")
      UserDefaults.standard.set("", forKey: "repositories.selectedRepoName")
      return
    }

    UserDefaults.standard.set(repo.normalizedRemoteURL, forKey: "repositories.selectedRepoKey")
    let selectedName = repositoryAutomationEntries(for: aggregator.repositories)
      .first(where: { $0.key == repo.normalizedRemoteURL })?.name ?? repo.displayName
    UserDefaults.standard.set(selectedName, forKey: "repositories.selectedRepoName")
  }

  private func repositoryAutomationEntries(for repos: [UnifiedRepository]) -> [RepositoryAutomationEntry] {
    let duplicateCounts = Dictionary(
      repos.map { ($0.displayName, 1) },
      uniquingKeysWith: +
    )
    var usedNames = Set<String>()

    return repos.map { repo in
      var name = automationRepositoryName(for: repo, duplicateCounts: duplicateCounts)
      if usedNames.contains(name) {
        name = "\(name) — \(repo.normalizedRemoteURL)"
      }
      usedNames.insert(name)
      return RepositoryAutomationEntry(key: repo.normalizedRemoteURL, name: name)
    }
  }

  private func automationRepositoryName(
    for repo: UnifiedRepository,
    duplicateCounts: [String: Int]
  ) -> String {
    guard duplicateCounts[repo.displayName, default: 0] > 1 else {
      return repo.displayName
    }

    if let ownerSlashRepo = repo.ownerSlashRepo,
       !ownerSlashRepo.isEmpty {
      return "\(repo.displayName) — \(ownerSlashRepo)"
    }

    if let localPath = repo.localPath,
       !localPath.isEmpty {
      return "\(repo.displayName) — \(localPath)"
    }

    return "\(repo.displayName) — \(repo.normalizedRemoteURL)"
  }

  private func migrateLegacySection(_ tool: CurrentTool) {
    switch tool {
    case .agents, .workspaces, .swarm: currentSection = .activity
    case .git, .github: currentSection = .repositories
    case .brew: if !showBrew { currentSection = .repositories }
    case .repositories, .activity: break
    }
  }

  // MARK: - Repo Filtering

  private var filteredRepositories: [UnifiedRepository] {
    var repos = aggregator.repositories
    switch repoFilterMode {
    case .all: break
    case .cloned: repos = repos.filter(\.isClonedLocally)
    case .indexed: repos = repos.filter(\.isRAGIndexed)
    case .tracked: repos = repos.filter(\.isTracked)
    case .active: repos = repos.filter(\.hasActiveWork)
    case .favorites: repos = repos.filter(\.isFavorite)
    }
    if !repoSearchText.isEmpty {
      let query = repoSearchText.lowercased()
      repos = repos.filter { repo in
        repo.displayName.lowercased().contains(query)
          || repo.normalizedRemoteURL.lowercased().contains(query)
          || (repo.ownerSlashRepo?.lowercased().contains(query) ?? false)
      }
    }
    return repos
  }

  private func countForFilter(_ mode: RepoFilterMode) -> Int {
    switch mode {
    case .all: return aggregator.repositories.count
    case .cloned: return aggregator.repositories.filter(\.isClonedLocally).count
    case .indexed: return aggregator.repositories.filter(\.isRAGIndexed).count
    case .tracked: return aggregator.repositories.filter(\.isTracked).count
    case .active: return aggregator.repositories.filter(\.hasActiveWork).count
    case .favorites: return aggregator.repositories.filter(\.isFavorite).count
    }
  }

  // MARK: - Repo Context Menu

  @ViewBuilder
  private func repoContextMenu(for repo: UnifiedRepository) -> some View {
    if repo.isClonedLocally, let path = repo.localPath {
      Button("Reveal in Finder") {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
      }
    }

    if repo.isFavorite, let favoriteId = repo.githubFavoriteId {
      Button("Remove from Favorites") {
        dataService.removeGitHubFavorite(id: favoriteId)
        aggregator.rebuild()
      }
    }

    if repo.isTracked, let trackedId = repo.trackedRemoteRepoId {
      Button("Stop Tracking") {
        _ = dataService.untrackRemoteRepo(id: trackedId)
        aggregator.rebuild()
      }
    }

    if repo.syncedRepositoryId != nil || repo.trackedRemoteRepoId != nil || repo.isClonedLocally {
      Divider()
      Button("Remove from Peel", role: .destructive) {
        // Remove tracked repo record
        if let trackedId = repo.trackedRemoteRepoId {
          _ = dataService.untrackRemoteRepo(id: trackedId)
        }
        // Remove synced repo record
        if let syncedId = repo.syncedRepositoryId {
          dataService.deleteRepository(id: syncedId)
        }
        // Unregister from in-memory RepoRegistry
        if let path = repo.localPath {
          RepoRegistry.shared.unregister(localPath: path)
          dataService.removeLocalRepositoryPath(path: path)
        }
        RepoRegistry.shared.unregister(remoteURL: repo.normalizedRemoteURL)
        // Remove from RAG index if indexed
        if repo.isRAGIndexed, let path = repo.localPath {
          Task {
            _ = try? await mcpServer.deleteRagRepo(repoId: nil, repoPath: path)
            aggregator.rebuild()
          }
        }
        if sidebarSelection == .repo(repo.normalizedRemoteURL) {
          sidebarSelection = .repoCommandCenter
        }
        aggregator.rebuild()
      }
    }
  }

  private func populateRepoRegistry() async {
    let registry = RepoRegistry.shared
    let localRepoPaths = Array(Set(dataService.getAllLocalRepositoryPaths(validOnly: true).map(\.localPath)))
    await registry.registerAllPaths(localRepoPaths)
    let recentPaths = ReviewLocallyService.shared.recentRepositories.map(\.path)
    await registry.registerAllPaths(recentPaths)
  }
}

/// Shared filter mode for repo list — used by ContentView sidebar and UnifiedRepositoriesView.
enum RepoFilterMode: String, CaseIterable {
  case all = "All"
  case cloned = "Cloned"
  case indexed = "Indexed"
  case tracked = "Tracked"
  case active = "Active"
  case favorites = "Favorites"
}

#Preview {
  ContentView()
}
