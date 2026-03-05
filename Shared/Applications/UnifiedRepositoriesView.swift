//
//  UnifiedRepositoriesView.swift
//  Peel
//
//  The new unified Repositories tab. Every repository the app knows about appears
//  here as a single identity — no local/remote split. Sidebar lists repos with
//  status badges; detail pane shows branches, activity, RAG, and skills.
//

import SwiftUI
import SwiftData
import Git

// MARK: - Unified Repositories Root

struct UnifiedRepositoriesView: View {
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(DataService.self) private var dataService

  @State private var selectedRepoId: UUID?
  @State private var searchText = ""
  @State private var showAddSheet = false
  @State private var filterMode: FilterMode = .all

  enum FilterMode: String, CaseIterable {
    case all = "All"
    case cloned = "Cloned"
    case indexed = "Indexed"
    case tracked = "Tracked"
    case active = "Active"
    case favorites = "Favorites"
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    .navigationTitle("Repositories")
    .searchable(text: $searchText, prompt: "Search repositories…")
    .toolbar {
      #if os(macOS)
      ToolSelectionToolbar()
      ChainActivityToolbar()
      #endif
      ToolbarItem(placement: .primaryAction) {
        Button {
          showAddSheet = true
        } label: {
          Image(systemName: "plus")
        }
        .help("Add Repository")
      }
      ToolbarItem(placement: .automatic) {
        Button {
          aggregator.rebuild()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh")
      }
    }
    .sheet(isPresented: $showAddSheet) {
      AddRepositorySheet()
    }
    .task {
      // Rebuild when this view appears
      aggregator.rebuild()
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    VStack(spacing: 0) {
      // Filter chips
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(FilterMode.allCases, id: \.self) { mode in
            FilterChip(
              title: mode.rawValue,
              count: countForFilter(mode),
              isSelected: filterMode == mode
            ) {
              withAnimation(.easeInOut(duration: 0.15)) {
                filterMode = mode
              }
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }

      Divider()

      // Repository list
      List(selection: $selectedRepoId) {
        ForEach(filteredRepositories) { repo in
          RepoSidebarRow(repo: repo)
            .tag(repo.id)
        }
      }
      .listStyle(.sidebar)
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    if let repoId = selectedRepoId,
       let repo = aggregator.repositoryById[repoId] {
      RepoDetailView(repo: repo)
    } else {
      RepositoriesCommandCenter()
    }
  }

  // MARK: - Filtering

  private var filteredRepositories: [UnifiedRepository] {
    var repos = aggregator.repositories

    // Apply filter mode
    switch filterMode {
    case .all: break
    case .cloned: repos = repos.filter(\.isClonedLocally)
    case .indexed: repos = repos.filter(\.isRAGIndexed)
    case .tracked: repos = repos.filter(\.isTracked)
    case .active: repos = repos.filter(\.hasActiveWork)
    case .favorites: repos = repos.filter(\.isFavorite)
    }

    // Apply search
    if !searchText.isEmpty {
      let query = searchText.lowercased()
      repos = repos.filter { repo in
        repo.displayName.lowercased().contains(query)
          || repo.normalizedRemoteURL.lowercased().contains(query)
          || (repo.ownerSlashRepo?.lowercased().contains(query) ?? false)
      }
    }

    return repos
  }

  private func countForFilter(_ mode: FilterMode) -> Int {
    switch mode {
    case .all: return aggregator.repositories.count
    case .cloned: return aggregator.repositories.filter(\.isClonedLocally).count
    case .indexed: return aggregator.repositories.filter(\.isRAGIndexed).count
    case .tracked: return aggregator.repositories.filter(\.isTracked).count
    case .active: return aggregator.repositories.filter(\.hasActiveWork).count
    case .favorites: return aggregator.repositories.filter(\.isFavorite).count
    }
  }
}

// MARK: - Sidebar Row

struct RepoSidebarRow: View {
  let repo: UnifiedRepository

  var body: some View {
    HStack(spacing: 8) {
      // Status indicator dot
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          if repo.isFavorite {
            Image(systemName: "star.fill")
              .font(.caption2)
              .foregroundStyle(.yellow)
          }
          if repo.isSubPackage {
            Image(systemName: "shippingbox")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Text(repo.displayName)
            .fontWeight(.medium)
            .lineLimit(1)
        }

        Text(repo.statusSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      // Activity badges
      HStack(spacing: 4) {
        if repo.activeChainCount > 0 {
          BadgePill(
            text: "\(repo.activeChainCount)",
            systemImage: "bolt.fill",
            color: .blue
          )
        }
        if repo.worktreeCount > 0 {
          BadgePill(
            text: "\(repo.worktreeCount)",
            systemImage: "arrow.triangle.branch",
            color: .purple
          )
        }
        if !repo.recentPRs.isEmpty {
          BadgePill(
            text: "\(repo.recentPRs.count)",
            systemImage: "arrow.triangle.pull",
            color: .green
          )
        }
        if let rag = repo.ragStatus, rag != .notIndexed {
          Image(systemName: rag.systemImage)
            .font(.caption2)
            .foregroundStyle(ragStatusColor(rag))
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var statusColor: Color {
    if repo.activeChainCount > 0 { return .blue }
    if repo.isTracked { return .green }
    if repo.isClonedLocally { return .primary.opacity(0.5) }
    return .secondary.opacity(0.3)
  }

  private func ragStatusColor(_ status: UnifiedRepository.RAGStatus) -> Color {
    switch status {
    case .notIndexed: return .secondary
    case .indexing: return .orange
    case .indexed: return .green
    case .analyzing: return .blue
    case .analyzed: return .green
    case .stale: return .orange
    }
  }
}

// MARK: - Filter Chip

struct FilterChip: View {
  let title: String
  let count: Int
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title)
        if count > 0 {
          Text("\(count)")
            .fontWeight(.semibold)
        }
      }
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
      )
      .foregroundStyle(isSelected ? Color.accentColor : .secondary)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Badge Pill

struct BadgePill: View {
  let text: String
  let systemImage: String
  let color: Color

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: systemImage)
      Text(text)
    }
    .font(.caption2)
    .fontWeight(.medium)
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(
      Capsule()
        .fill(color.opacity(0.12))
    )
    .foregroundStyle(color)
  }
}

// MARK: - Add Repository Sheet

struct AddRepositorySheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(DataService.self) private var dataService

  enum Mode: Hashable {
    case picker
    case trackRemote
  }

  @State private var mode: Mode = .picker
  @State private var remoteURL = ""
  @State private var repoName = ""
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 20) {
      switch mode {
      case .picker:
        pickerView
      case .trackRemote:
        trackRemoteView
      }
    }
    .padding(24)
    .frame(width: 520)
  }

  // MARK: - Picker

  private var pickerView: some View {
    VStack(spacing: 20) {
      Text("Add Repository")
        .font(.headline)

      Text("Choose how to add a repository:")
        .foregroundStyle(.secondary)

      HStack(spacing: 16) {
        #if os(macOS)
        Button {
          openLocalRepository()
        } label: {
          AddOptionCard(
            title: "Open Local",
            subtitle: "Browse to existing clone",
            systemImage: "folder"
          )
        }
        .buttonStyle(.plain)
        #endif

        Button {
          mode = .trackRemote
        } label: {
          AddOptionCard(
            title: "Track Remote",
            subtitle: "Auto-pull a remote repo",
            systemImage: "antenna.radiowaves.left.and.right"
          )
        }
        .buttonStyle(.plain)
      }

      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
  }

  // MARK: - Track Remote

  private var trackRemoteView: some View {
    VStack(spacing: 16) {
      Text("Track Remote Repository")
        .font(.headline)

      Text("Enter a GitHub URL or clone URL to track:")
        .foregroundStyle(.secondary)

      TextField("https://github.com/owner/repo", text: $remoteURL)
        .textFieldStyle(.roundedBorder)
        .onSubmit { deriveRepoName() }

      TextField("Display name", text: $repoName)
        .textFieldStyle(.roundedBorder)

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Button("Back") { mode = .picker }
        Spacer()
        Button("Track") { trackRemote() }
          .keyboardShortcut(.defaultAction)
          .disabled(remoteURL.isEmpty)
      }
    }
  }

  // MARK: - Actions

  #if os(macOS)
  private func openLocalRepository() {
    let panel = NSOpenPanel()
    panel.title = "Choose a git repository"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK, let url = panel.url else { return }

    let gitDir = url.appendingPathComponent(".git")
    guard FileManager.default.fileExists(atPath: gitDir.path) else {
      errorMessage = "Not a git repository (no .git directory)."
      return
    }

    let name = url.lastPathComponent
    let path = url.path

    // Track as local repo in DataService so aggregator picks it up
    dataService.trackRemoteRepo(
      remoteURL: path,
      name: name,
      localPath: path,
      branch: "main"
    )

    aggregator.rebuild()
    dismiss()
  }
  #endif

  private func deriveRepoName() {
    guard repoName.isEmpty else { return }
    // Extract repo name from URL: github.com/owner/repo → repo
    let cleaned = remoteURL
      .replacingOccurrences(of: ".git", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if let last = cleaned.split(separator: "/").last {
      repoName = String(last)
    }
  }

  private func trackRemote() {
    deriveRepoName()
    guard !remoteURL.isEmpty else {
      errorMessage = "URL is required."
      return
    }
    let name = repoName.isEmpty ? "Untitled" : repoName
    dataService.trackRemoteRepo(
      remoteURL: remoteURL,
      name: name,
      localPath: "",
      branch: "main"
    )
    aggregator.rebuild()
    dismiss()
  }
}

struct AddOptionCard: View {
  let title: String
  let subtitle: String
  let systemImage: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.title)
        .foregroundStyle(.blue)
      Text(title)
        .fontWeight(.medium)
        .font(.callout)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.secondary.opacity(0.05))
        .stroke(Color.secondary.opacity(0.15))
    )
  }
}

// MARK: - Command Center (No-Selection View)

/// Cross-repo dashboard shown when no repository is selected.
/// Surfaces actionable items across all repos instead of RAG stats.
struct RepositoriesCommandCenter: View {
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(ActivityFeed.self) private var activityFeed

  /// All non-terminal parallel runs across the workspace.
  private var allActiveRuns: [ParallelWorktreeRun] {
    guard let runner = mcpServer.parallelWorktreeRunner else { return [] }
    return runner.runs.filter { run in
      switch run.status {
      case .completed, .failed, .cancelled: return false
      default: return true
      }
    }
  }

  /// Runs with pending reviews across all repos.
  private var pendingApprovalRuns: [ParallelWorktreeRun] {
    allActiveRuns.filter { $0.pendingReviewCount > 0 || $0.readyToMergeCount > 0 }
  }

  /// All open PRs aggregated across repos.
  private var allOpenPRs: [(repo: UnifiedRepository, pr: UnifiedRepository.PRSummary)] {
    aggregator.repositories.flatMap { repo in
      repo.recentPRs.filter { $0.state == "open" }.map { (repo, $0) }
    }
  }

  /// All active chains across repos.
  private var allActiveChains: [(repo: UnifiedRepository, chain: UnifiedRepository.ChainSummary)] {
    aggregator.repositories.flatMap { repo in
      repo.activeChains.map { (repo, $0) }
    }
  }

  /// All active worktrees across repos.
  private var allWorktrees: [(repo: UnifiedRepository, wt: UnifiedRepository.WorktreeSummary)] {
    aggregator.repositories.flatMap { repo in
      repo.activeWorktrees.map { (repo, $0) }
    }
  }

  private var hasActionItems: Bool {
    !pendingApprovalRuns.isEmpty || !allOpenPRs.isEmpty
  }

  private var hasAgentWork: Bool {
    !allActiveChains.isEmpty || !allActiveRuns.isEmpty || !allWorktrees.isEmpty
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Header
        headerSection

        // Needs Attention
        if hasActionItems {
          needsAttentionSection
        }

        // Agent Work
        if hasAgentWork {
          agentWorkSection
        }

        // Repository Cards
        repositoryCardsSection

        // RAG Status (compact, collapsed)
        ragCompactSection
      }
      .padding(20)
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Command Center")
        .font(.title2)
        .fontWeight(.bold)

      HStack(spacing: 16) {
        quickStat(
          value: "\(aggregator.repositories.count)",
          label: "repos",
          icon: "folder",
          color: .blue
        )
        quickStat(
          value: "\(allOpenPRs.count)",
          label: "open PRs",
          icon: "arrow.triangle.pull",
          color: .green
        )
        quickStat(
          value: "\(allActiveChains.count)",
          label: "chains",
          icon: "bolt.fill",
          color: .orange
        )
        quickStat(
          value: "\(allWorktrees.count)",
          label: "worktrees",
          icon: "arrow.triangle.branch",
          color: .purple
        )
        if pendingApprovalRuns.count > 0 {
          quickStat(
            value: "\(pendingApprovalRuns.count)",
            label: "pending",
            icon: "bell.badge.fill",
            color: .red
          )
        }
      }
      .font(.caption)
    }
  }

  private func quickStat(value: String, label: String, icon: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .foregroundStyle(color)
      Text(value)
        .fontWeight(.semibold)
      Text(label)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(color.opacity(0.06))
    )
  }

  // MARK: - Needs Attention

  private var needsAttentionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Needs Your Attention", systemImage: "bell.badge.fill")
        .font(.headline)
        .foregroundStyle(.orange)

      // Pending approvals
      ForEach(pendingApprovalRuns) { run in
        GroupBox {
          HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
              .font(.title3)
              .foregroundStyle(.purple)
              .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
              Text(run.name)
                .fontWeight(.medium)
                .lineLimit(1)
              HStack(spacing: 6) {
                Text("\(run.pendingReviewCount) pending review")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if run.readyToMergeCount > 0 {
                  Text("· \(run.readyToMergeCount) ready to merge")
                    .font(.caption)
                    .foregroundStyle(.green)
                }
              }
            }
            Spacer()
            Text("Review")
              .font(.caption2)
              .fontWeight(.bold)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Capsule().fill(.purple.opacity(0.15)))
              .foregroundStyle(.purple)
          }
          .padding(2)
        }
      }

      // Open PRs across repos
      ForEach(allOpenPRs.prefix(5), id: \.pr.id) { item in
        GroupBox {
          HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.pull")
              .font(.title3)
              .foregroundStyle(.green)
              .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
              Text("#\(item.pr.number) \(item.pr.title)")
                .fontWeight(.medium)
                .lineLimit(1)
              HStack(spacing: 6) {
                Text(item.repo.displayName)
                  .font(.caption)
                  .foregroundStyle(.blue)
                if let ref = item.pr.headRef {
                  Text("· \(ref)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
            }

            Spacer()

            if let url = item.pr.htmlURL, let nsurl = URL(string: url) {
              Button {
                #if os(macOS)
                NSWorkspace.shared.open(nsurl)
                #endif
              } label: {
                Image(systemName: "arrow.up.right.square")
                  .font(.caption)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
            }
          }
          .padding(2)
        }
      }

      if allOpenPRs.count > 5 {
        Text("+ \(allOpenPRs.count - 5) more open PRs")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 4)
      }
    }
  }

  // MARK: - Agent Work

  private var agentWorkSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Agent Work")

      ForEach(allActiveChains, id: \.chain.id) { item in
        GroupBox {
          HStack(spacing: 10) {
            if !item.chain.isTerminal {
              ProgressView()
                .controlSize(.small)
                .frame(width: 28)
            } else {
              Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
              Text(item.chain.name)
                .fontWeight(.medium)
              HStack(spacing: 6) {
                Text(item.repo.displayName)
                  .font(.caption)
                  .foregroundStyle(.blue)
                Text("· \(item.chain.stateDisplay)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
          }
          .padding(2)
        }
      }

      // Active runs that aren't in the approval section
      let nonApprovalRuns = allActiveRuns.filter { run in
        !pendingApprovalRuns.contains(where: { $0.id == run.id })
      }
      ForEach(nonApprovalRuns) { run in
        GroupBox {
          HStack(spacing: 10) {
            if run.status == .running {
              ProgressView()
                .controlSize(.small)
                .frame(width: 28)
            } else {
              Image(systemName: "bolt.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
              Text(run.name)
                .fontWeight(.medium)
              Text(run.status.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if run.executions.count > 0 {
              Text("\(run.executions.count) tasks")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            ProgressView(value: run.progress)
              .frame(width: 60)
          }
          .padding(2)
        }
      }

      if !allWorktrees.isEmpty {
        ForEach(allWorktrees.prefix(5), id: \.wt.id) { item in
          GroupBox {
            HStack(spacing: 10) {
              Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

              VStack(alignment: .leading, spacing: 2) {
                Text(item.wt.branch)
                  .fontWeight(.medium)
                  .lineLimit(1)
                HStack(spacing: 6) {
                  Text(item.repo.displayName)
                    .font(.caption)
                    .foregroundStyle(.blue)
                  Text("· \(item.wt.taskStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
            }
            .padding(2)
          }
        }
      }
    }
  }

  // MARK: - Repository Cards

  private var repositoryCardsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Repositories")

      let repos = aggregator.repositories.sorted { $0.sortPriority > $1.sortPriority }

      LazyVStack(spacing: 1) {
        ForEach(repos) { repo in
          HStack(spacing: 10) {
            // Status dot
            Circle()
              .fill(repo.hasActiveWork ? Color.green : Color.secondary.opacity(0.3))
              .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 4) {
                if repo.isFavorite {
                  Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                }
                Text(repo.displayName)
                  .fontWeight(.medium)
              }

              HStack(spacing: 8) {
                if !repo.recentPRs.isEmpty {
                  let openCount = repo.recentPRs.filter { $0.state == "open" }.count
                  if openCount > 0 {
                    Label("\(openCount) PR\(openCount == 1 ? "" : "s")", systemImage: "arrow.triangle.pull")
                      .foregroundStyle(.green)
                  }
                }
                if repo.activeChainCount > 0 {
                  Label("\(repo.activeChainCount) chain\(repo.activeChainCount == 1 ? "" : "s")", systemImage: "bolt.fill")
                    .foregroundStyle(.orange)
                }
                if repo.worktreeCount > 0 {
                  Label("\(repo.worktreeCount) worktree\(repo.worktreeCount == 1 ? "" : "s")", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.purple)
                }
                if let rag = repo.ragStatus, rag != .notIndexed {
                  Label(rag.displayName, systemImage: rag.systemImage)
                    .foregroundStyle(.secondary)
                }
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
        }
      }
      #if os(macOS)
      .background(Color(nsColor: .controlBackgroundColor))
      #else
      .background(Color(.systemGroupedBackground))
      #endif
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }

  // MARK: - RAG Compact

  private var ragCompactSection: some View {
    let repos = mcpServer.ragRepos
    guard !repos.isEmpty else { return AnyView(EmptyView()) }

    let totalFiles = repos.reduce(0) { $0 + $1.fileCount }
    let totalChunks = repos.reduce(0) { $0 + $1.chunkCount }

    return AnyView(
      VStack(alignment: .leading, spacing: 8) {
        SectionHeader("RAG Index", style: .secondary)

        HStack(spacing: 12) {
          Label("\(repos.count) repos", systemImage: "folder")
          Label("\(totalFiles) files", systemImage: "doc")
          Label("\(totalChunks) chunks", systemImage: "text.alignleft")
          if let model = mcpServer.ragStatus?.embeddingModelName {
            Label(model, systemImage: "cpu")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    )
  }
}
