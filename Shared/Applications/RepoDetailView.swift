//
//  RepoDetailView.swift
//  Peel
//
//  Detail pane for a single UnifiedRepository. Shows sub-tabs:
//  Overview (default), Branches, Activity, RAG, and Skills.
//

import Git
import Github
import SwiftData
import SwiftUI

// MARK: - Detail Tab

enum RepoDetailTab: String, CaseIterable {
  case overview = "Overview"
  case branches = "Branches"
  case rag = "RAG"
  case skills = "Skills"

  var systemImage: String {
    switch self {
    case .overview: return "square.grid.2x2"
    case .branches: return "arrow.triangle.branch"
    case .rag: return "magnifyingglass"
    case .skills: return "hammer"
    }
  }

  var automationValue: String {
    rawValue.lowercased()
  }

  init?(automationValue: String) {
    if let match = Self.allCases.first(where: { $0.automationValue == automationValue.lowercased() }) {
      self = match
    } else {
      return nil
    }
  }
}

// MARK: - Repo Detail View

struct RepoDetailView: View {
  let repo: UnifiedRepository

  @AppStorage("repositories.selectedTab") private var selectedTabValue = RepoDetailTab.overview.automationValue

  private var selectedTab: Binding<RepoDetailTab> {
    Binding(
      get: { RepoDetailTab(automationValue: selectedTabValue) ?? .overview },
      set: { selectedTabValue = $0.automationValue }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      repoHeader

      Divider()

      // Tab picker
      Picker("", selection: selectedTab) {
        ForEach(RepoDetailTab.allCases, id: \.self) { tab in
          Label(tab.rawValue, systemImage: tab.systemImage)
            .tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      // Tab content
      tabContent
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  // MARK: - Header

  private var repoHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            if repo.isFavorite {
              Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
            }
            Text(repo.displayName)
              .font(.title2)
              .fontWeight(.bold)
          }

          if let ownerRepo = repo.ownerSlashRepo {
            Text(ownerRepo)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        // Status pills
        HStack(spacing: 8) {
          if repo.isClonedLocally {
            RepoStatusPill(text: "Cloned", systemImage: "checkmark.circle.fill", color: .green)
          } else {
            RepoStatusPill(text: "Remote", systemImage: "cloud", color: .secondary)
          }

          if repo.isTracked {
            if let mode = repo.syncMode {
              RepoStatusPill(text: mode.displayName, systemImage: mode.systemImage, color: mode == .pullAndSyncIndex ? .cyan : .blue)
            } else {
              RepoStatusPill(text: "Auto-Pull", systemImage: "arrow.down.circle", color: .blue)
            }
          }

          if let rag = repo.ragStatus, rag != .notIndexed {
            RepoStatusPill(text: rag.displayName, systemImage: rag.systemImage, color: .purple)
          }
        }
      }

      // Summary stats
      HStack(spacing: 16) {
        if repo.activeChainCount > 0 {
          Label("\(repo.activeChainCount) active chain\(repo.activeChainCount == 1 ? "" : "s")", systemImage: "bolt.fill")
            .foregroundStyle(.blue)
        }
        if repo.worktreeCount > 0 {
          Label("\(repo.worktreeCount) worktree\(repo.worktreeCount == 1 ? "" : "s")", systemImage: "arrow.triangle.branch")
            .foregroundStyle(.purple)
        }
        if !repo.recentPRs.isEmpty {
          Label("\(repo.recentPRs.count) recent PR\(repo.recentPRs.count == 1 ? "" : "s")", systemImage: "arrow.triangle.pull")
            .foregroundStyle(.orange)
        }
        if let pull = repo.pullStatus {
          Label(pull.displayName, systemImage: pull.systemImage)
            .foregroundStyle(pullStatusColor(pull))
        }
      }
      .font(.caption)
    }
    .padding(16)
  }

  // MARK: - Tab Content

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab.wrappedValue {
    case .overview:
      #if os(macOS)
      OverviewTabView(repo: repo)
      #else
      iOSOverviewTabView(repo: repo)
      #endif
    case .branches:
      #if os(macOS)
      BranchesTabView(repo: repo)
      #else
      iOSBranchesTabView(repo: repo)
      #endif
    case .rag:
      #if os(macOS)
      RAGTabView(repo: repo)
      #else
      ContentUnavailableView("RAG", systemImage: "magnifyingglass", description: Text("RAG indexing is available on macOS."))
      #endif
    case .skills:
      SkillsTabView(repo: repo)
    }
  }

  private func pullStatusColor(_ status: UnifiedRepository.PullStatus) -> Color {
    switch status {
    case .disabled: return .secondary
    case .idle: return .secondary
    case .pulling: return .blue
    case .upToDate: return .green
    case .updated: return .green
    case .error: return .red
    }
  }
}

// MARK: - Status Pill

struct RepoStatusPill: View {
  let text: String
  let systemImage: String
  let color: Color

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption)
      .fontWeight(.medium)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        Capsule()
          .fill(color.opacity(0.1))
      )
      .foregroundStyle(color)
  }
}

#if os(macOS)
// MARK: - Overview Tab

/// The default landing view for a repository. Surfaces actionable items:
/// PRs, pending approvals, agent work, and a compact health summary.
struct OverviewTabView: View {
  let repo: UnifiedRepository

  @Environment(MCPServerService.self) private var mcpServer
  @Environment(DataService.self) private var dataService
  @Environment(RepositoryAggregator.self) private var aggregator
  @State private var fetchedPRs: [UnifiedRepository.PRSummary] = []
  @State private var isLoadingPRs = false
  @State private var selectedPRDetail: PRDetailIdentifier?
  @State private var justTrackedId: UUID?
  @State private var selectedChain: AgentChain?
  @State private var selectedRunForReview: ParallelWorktreeRun?
  @State private var expandedExecutions: Set<UUID> = []
  @State private var refreshTimer: Timer?

  private var repoRuns: [ParallelWorktreeRun] {
    guard let runner = mcpServer.parallelWorktreeRunner,
          let localPath = repo.localPath else { return [] }
    return runner.runs.filter { run in
      guard run.projectPath == localPath else { return false }
      switch run.status {
      case .completed, .failed, .cancelled: return false
      default:
        // Exclude stale runs with no actionable executions
        let hasWork = run.activeCount > 0 || run.pendingReviewCount > 0 || run.readyToMergeCount > 0
        return hasWork
      }
    }
  }

  private var pendingApprovalRuns: [ParallelWorktreeRun] {
    repoRuns.filter { $0.pendingReviewCount > 0 }
  }

  private var displayPRs: [UnifiedRepository.PRSummary] {
    fetchedPRs.isEmpty ? repo.recentPRs : fetchedPRs
  }

  private var openPRs: [UnifiedRepository.PRSummary] {
    displayPRs.filter { $0.state == "open" }
  }

  var body: some View {
    if let detail = selectedPRDetail {
      PRDetailInlineView(
        ownerRepo: detail.ownerRepo,
        prNumber: detail.prNumber
      ) {
        selectedPRDetail = nil
      }
    } else if let run = selectedRunForReview,
              let runner = mcpServer.parallelWorktreeRunner {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Button {
            selectedRunForReview = nil
          } label: {
            Label("Back to Overview", systemImage: "chevron.left")
          }
          .buttonStyle(.plain)

          WorktreeRunApprovalCard(
            run: run,
            runner: runner,
            expandedExecutions: $expandedExecutions,
            onDismiss: { selectedRunForReview = nil }
          )
        }
        .padding(16)
      }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // 1. Needs Attention — action items that need human input
          if !pendingApprovalRuns.isEmpty || !openPRs.isEmpty {
            needsAttentionSection
          }

          // 2. Open Pull Requests — always visible and prominent
          pullRequestsSection

          // 3. Agent Work — active chains and worktrees
          if !repo.activeChains.isEmpty || !repo.activeWorktrees.isEmpty || !repoRuns.isEmpty {
            agentWorkSection
          }

          // 4. Start Tracking — for repos not yet tracked
          if !repo.isTracked, justTrackedId == nil, repo.localPath != nil, repo.remoteURL != nil {
            startTrackingSection
          }
        }
        .padding(16)
      }
      .task(id: repo.ownerSlashRepo) {
        await fetchOpenPRs()
      }
      .onAppear {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
          Task { @MainActor in
            await fetchOpenPRs()
          }
        }
      }
      .onDisappear {
        refreshTimer?.invalidate()
        refreshTimer = nil
      }
      .sheet(item: $selectedChain) { chain in
        NavigationStack {
          ChainDetailView(
            chain: chain,
            agentManager: mcpServer.agentManager,
            cliService: mcpServer.cliService,
            sessionTracker: mcpServer.sessionTracker
          )
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") { selectedChain = nil }
            }
          }
        }
        .frame(minWidth: 700, minHeight: 500)
      }
    }
  }

  // MARK: - Needs Attention

  private var needsAttentionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Needs Your Attention", systemImage: "bell.badge.fill")
        .font(.headline)
        .foregroundStyle(.orange)

      if !pendingApprovalRuns.isEmpty, let _ = mcpServer.parallelWorktreeRunner {
        ForEach(pendingApprovalRuns) { run in
          runAttentionCard(run: run)
            .contentShape(Rectangle())
            .onTapGesture {
              selectedRunForReview = run
            }
            .accessibilityIdentifier("parallel.run.\(run.id.uuidString).review")
        }
      }

      ForEach(openPRs.prefix(3)) { pr in
        attentionCard(
          icon: "arrow.triangle.pull",
          color: .green,
          title: "#\(pr.number) \(pr.title)",
          subtitle: pr.headRef ?? "open",
          badge: "Open"
        )
        .contentShape(Rectangle())
        .onTapGesture {
          if let ownerRepo = repo.ownerSlashRepo {
            selectedPRDetail = PRDetailIdentifier(ownerRepo: ownerRepo, prNumber: pr.number)
          }
        }
      }
    }
  }

  private func runAttentionCard(run: ParallelWorktreeRun) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
          Image(systemName: "checkmark.shield")
            .font(.title3)
            .foregroundStyle(.purple)
            .frame(width: 28)

          VStack(alignment: .leading, spacing: 2) {
            Text(run.name)
              .fontWeight(.medium)
              .lineLimit(1)
            Text("\(run.pendingReviewCount) task\(run.pendingReviewCount == 1 ? "" : "s") awaiting review")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer()

          Text("Review")
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.purple.opacity(0.15)))
            .foregroundStyle(.purple)
        }

        // Aggregate stats row
        HStack(spacing: 12) {
          let totalExecs = run.executions.count
          let totalFiles = run.totalFilesChanged
          let totalIns = run.totalInsertions
          let totalDel = run.totalDeletions

          if totalExecs > 0 {
            Text("\(totalExecs) task\(totalExecs == 1 ? "" : "s")")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }

          if totalFiles > 0 {
            HStack(spacing: 3) {
              Text("\(totalFiles) file\(totalFiles == 1 ? "" : "s")")
              Text("+\(totalIns)")
                .foregroundStyle(.green)
              Text("-\(totalDel)")
                .foregroundStyle(.red)
            }
            .font(.caption2.monospaced())
          }

          // Review progress
          let reviewed = run.reviewedCount + run.mergedCount
          if reviewed > 0 || run.pendingReviewCount > 0 {
            Text("\(reviewed)/\(reviewed + run.pendingReviewCount) reviewed")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }

          Spacer()
        }
        .padding(.leading, 40) // align with title text
      }
      .padding(2)
    }
  }

  private func attentionCard(icon: String, color: Color, title: String, subtitle: String, badge: String) -> some View {
    GroupBox {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.title3)
          .foregroundStyle(color)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .fontWeight(.medium)
            .lineLimit(1)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer()

        Text(badge)
          .font(.caption2)
          .fontWeight(.bold)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Capsule().fill(color.opacity(0.15)))
          .foregroundStyle(color)
      }
      .padding(2)
    }
  }

  // MARK: - Pull Requests

  private var pullRequestsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionHeader("Pull Requests")
        Spacer()
        if isLoadingPRs {
          ProgressView()
            .controlSize(.small)
        }
        if !displayPRs.isEmpty {
          Text("\(displayPRs.count)")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
        }
      }

      if displayPRs.isEmpty && !isLoadingPRs {
        GroupBox {
          HStack {
            Image(systemName: "arrow.triangle.pull")
              .foregroundStyle(.secondary)
            Text("No open pull requests")
              .foregroundStyle(.secondary)
            Spacer()
          }
          .padding(4)
        }
      } else {
        LazyVStack(spacing: 1) {
          ForEach(displayPRs) { pr in
            PRRowWithReview(
              pr: pr,
              ownerRepo: repo.ownerSlashRepo,
              repoPath: repo.localPath
            )
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
  }

  // MARK: - Agent Work

  private var agentWorkSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Agent Work")

      // Active chains
      ForEach(repo.activeChains) { chain in
        RepoChainRow(chain: chain)
          .contentShape(Rectangle())
          .onTapGesture {
            if let agentChain = mcpServer.agentManager.chains.first(where: { $0.id == chain.id }) {
              selectedChain = agentChain
            }
          }
      }

      // Active worktrees (non-approval ones)
      let nonApprovalRuns = repoRuns.filter { run in
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
              HStack(spacing: 8) {
                Text(run.status.displayName)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if run.executions.count > 0 {
                  Text("\(run.executions.count) task\(run.executions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
              }
            }
            Spacer()
            ProgressView(value: run.progress)
              .frame(width: 60)
          }
          .padding(4)
        }
      }

      // Standalone worktrees
      ForEach(repo.activeWorktrees) { wt in
        RepoWorktreeRow(worktree: wt) {
          dismissWorktree(wt)
        }
      }
    }
  }

  // MARK: - Start Tracking

  private var startTrackingSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Tracking")

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text("This repository is not tracked for automatic pulling.")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            startTracking()
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "arrow.down.circle")
              Text("Enable Auto-Pull")
            }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
        .padding(4)
      }
    }
  }

  private func startTracking() {
    guard let localPath = repo.localPath,
          let remoteURL = repo.remoteURL else { return }
    let tracked = dataService.trackRemoteRepo(
      remoteURL: remoteURL,
      name: repo.displayName,
      localPath: localPath
    )
    justTrackedId = tracked.id
    aggregator.rebuild()
  }

  // MARK: - Data Loading

  private func fetchOpenPRs() async {
    guard let ownerRepo = repo.ownerSlashRepo else { return }
    let parts = ownerRepo.split(separator: "/")
    guard parts.count == 2 else { return }
    let owner = String(parts[0])
    let repoName = String(parts[1])

    isLoadingPRs = true
    defer { isLoadingPRs = false }

    do {
      let prs = try await Github.pullRequests(owner: owner, repository: repoName, state: "open")
      let openNumbers = Set(prs.map(\.number))
      fetchedPRs = prs.map { pr in
        UnifiedRepository.PRSummary(
          id: UUID(),
          number: pr.number,
          title: pr.title ?? "Untitled",
          state: pr.state ?? "open",
          htmlURL: pr.html_url,
          headRef: pr.head.ref
        )
      }
      // Update SwiftData records that are no longer open
      dataService.markMergedPRs(repoFullName: "\(owner)/\(repoName)", openNumbers: openNumbers)
      aggregator.rebuild()
    } catch {
      // keep existing data on failure
    }
  }

  private func dismissWorktree(_ wt: UnifiedRepository.WorktreeSummary) {
    dataService.markWorktreeCleaned(id: wt.id)
    aggregator.rebuild()
  }
}

// MARK: - Branches Tab

struct BranchesTabView: View {
  let repo: UnifiedRepository

  @Environment(MCPServerService.self) private var mcpServer
  @State private var gitRepository: Git.Model.Repository?
  @State private var showRemoteBranches = false
  @State private var fetchedPRs: [UnifiedRepository.PRSummary] = []
  @State private var isLoadingPRs = false
  @State private var isPulling = false
  @State private var isFetching = false
  @State private var recentCommits: [Git.Model.LogEntry] = []
  @State private var gitError: String?

  /// Parallel worktree runs associated with this repo that have pending reviews or active work.
  private var repoRuns: [ParallelWorktreeRun] {
    guard let runner = mcpServer.parallelWorktreeRunner,
          let localPath = repo.localPath else { return [] }
    return runner.runs.filter { run in
      // Match by project path, exclude terminal runs
      guard run.projectPath == localPath else { return false }
      switch run.status {
      case .completed, .failed, .cancelled: return false
      default: return true
      }
    }
  }

  /// Runs that have at least one execution needing approval.
  private var pendingApprovalRuns: [ParallelWorktreeRun] {
    repoRuns.filter { $0.pendingReviewCount > 0 || $0.readyToMergeCount > 0 }
  }

  /// Runs that are active but don't have pending reviews (running or completed).
  private var activeRuns: [ParallelWorktreeRun] {
    repoRuns.filter { run in
      !pendingApprovalRuns.contains(where: { $0.id == run.id })
    }
  }

  /// Recent historical runs for this repo (completed/terminal, from snapshots).
  private var repoHistoricalSnapshots: [ParallelRunSnapshot] {
    guard let runner = mcpServer.parallelWorktreeRunner,
          let localPath = repo.localPath else { return [] }
    let activeIds = Set(runner.runs.map { $0.id.uuidString })
    var seen = Set<String>()
    return runner.historicalRuns.filter { snapshot in
      guard snapshot.projectPath == localPath else { return false }
      guard !activeIds.contains(snapshot.runId) else { return false }
      return seen.insert(snapshot.runId).inserted
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        #if os(macOS)
        if repo.isClonedLocally {
          if let gitRepo = gitRepository {
            clonedRepoContent(gitRepo)
          } else {
            ProgressView("Loading repository…")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } else {
          remoteRepoContent
        }
        #else
        notClonedPlaceholder
        #endif
      }
      .padding(16)
    }
    .task(id: repo.localPath) {
      await loadGitRepo()
    }
    .task(id: repo.ownerSlashRepo) {
      await fetchOpenPRs()
    }
  }

  #if os(macOS)
  // MARK: Cloned Repo Content

  @ViewBuilder
  private func clonedRepoContent(_ gitRepo: Git.Model.Repository) -> some View {
    // Active branch hero card
    activeBranchCard(gitRepo)

    // Error banner
    if let gitError {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
        Text(gitError)
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Dismiss") { self.gitError = nil }
          .buttonStyle(.borderless)
          .font(.caption)
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.1)))
    }

    // Local changes
    if !gitRepo.status.isEmpty {
      localChangesCard(gitRepo)
    }

    // Recent commits
    if !recentCommits.isEmpty {
      recentCommitsSection
    }

    // Pending approvals (from parallel worktree runner)
    if !pendingApprovalRuns.isEmpty, let runner = mcpServer.parallelWorktreeRunner {
      WorktreeApprovalsSection(
        runs: pendingApprovalRuns,
        runner: runner
      )
    }

    // Active runs (non-review)
    if !activeRuns.isEmpty, let runner = mcpServer.parallelWorktreeRunner {
      activeRunsSection(runner: runner)
    }

    // Recent completed runs (from snapshots — survive app restart)
    if !repoHistoricalSnapshots.isEmpty, let runner = mcpServer.parallelWorktreeRunner {
      recentRunsSection(runner: runner)
    }

    // Pull Requests
    prsSection

    // Branches
    branchesSection(gitRepo)

    // Worktrees
    if !repo.activeWorktrees.isEmpty {
      worktreesSection
    }

    // Agent chains
    if !repo.activeChains.isEmpty {
      chainsSection
    }
  }

  private func activeBranchCard(_ gitRepo: Git.Model.Repository) -> some View {
    let activeBranch = gitRepo.localBranches.first(where: \.isActive)

    return GroupBox {
      HStack(spacing: 12) {
        Image(systemName: "arrow.triangle.branch")
          .font(.title2)
          .foregroundStyle(.green)
          .frame(width: 32)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(activeBranch?.name ?? "detached HEAD")
              .font(.headline)

            if activeBranch != nil {
              Text("active")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.green.opacity(0.15)))
                .foregroundStyle(.green)
            }
          }

          HStack(spacing: 12) {
            Label("\(gitRepo.localBranches.count) local", systemImage: "arrow.triangle.branch")
            Label("\(gitRepo.remoteBranches.count) remote", systemImage: "cloud")
            if !gitRepo.status.isEmpty {
              Label("\(gitRepo.status.count) changed", systemImage: "doc.badge.ellipsis")
                .foregroundStyle(.orange)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Spacer()

        HStack(spacing: 6) {
          Button {
            Task { await pullCurrentBranch() }
          } label: {
            if isPulling {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "arrow.down.circle")
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isPulling || isFetching)
          .help("Pull from remote")

          Button {
            Task { await fetchRemote() }
          } label: {
            if isFetching {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "arrow.triangle.2.circlepath")
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isPulling || isFetching)
          .help("Fetch from remote")

          Button {
            Task { await refreshGitRepo() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .padding(4)
    }
  }

  private func localChangesCard(_ gitRepo: Git.Model.Repository) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label("Local Changes", systemImage: "doc.badge.ellipsis")
            .font(.subheadline)
            .fontWeight(.medium)

          Spacer()

          Text("\(gitRepo.status.count) file\(gitRepo.status.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Divider()

        ForEach(gitRepo.status.prefix(10), id: \.id) { file in
          HStack(spacing: 8) {
            fileStatusBadge(file.status)

            Text(file.path)
              .font(.callout)
              .monospaced()
              .lineLimit(1)
              .truncationMode(.middle)

            Spacer()
          }
        }

        if gitRepo.status.count > 10 {
          Text("+ \(gitRepo.status.count - 10) more files")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(4)
    }
  }

  @ViewBuilder
  private func branchesSection(_ gitRepo: Git.Model.Repository) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Branches")

      // Local branches
      LazyVStack(spacing: 1) {
        ForEach(gitRepo.localBranches, id: \.name) { branch in
          BranchRow(branch: branch) {
            Task { await checkoutBranch(branch.name, gitRepo: gitRepo) }
          }
        }
      }
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))

      // Remote branches (collapsible)
      if !gitRepo.remoteBranches.isEmpty {
        DisclosureGroup(isExpanded: $showRemoteBranches) {
          LazyVStack(spacing: 1) {
            ForEach(gitRepo.remoteBranches, id: \.name) { branch in
              BranchRow(branch: branch, isRemote: true) {
                // Strip remote prefix (e.g. "origin/feature" → "feature")
                let localName = branch.name.replacingOccurrences(
                  of: #"^[^/]+/"#, with: "", options: .regularExpression
                )
                Task { await checkoutBranch(localName, gitRepo: gitRepo) }
              }
            }
          }
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "cloud")
              .foregroundStyle(.secondary)
            Text("Remote Branches")
              .fontWeight(.medium)
            Text("(\(gitRepo.remoteBranches.count))")
              .foregroundStyle(.secondary)
          }
          .font(.subheadline)
        }
      }
    }
  }

  /// PRs to display: prefer live-fetched open PRs, fall back to aggregator's recent PRs.
  private var displayPRs: [UnifiedRepository.PRSummary] {
    fetchedPRs.isEmpty ? repo.recentPRs : fetchedPRs
  }

  private var prsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionHeader("Pull Requests")
        Spacer()
        if isLoadingPRs {
          ProgressView()
            .controlSize(.small)
        }
      }

      if displayPRs.isEmpty && !isLoadingPRs {
        Text("No open pull requests")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        LazyVStack(spacing: 1) {
          ForEach(displayPRs) { pr in
            PRRowWithReview(
              pr: pr,
              ownerRepo: repo.ownerSlashRepo,
              repoPath: repo.localPath
            )
          }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func activeRunsSection(runner: ParallelWorktreeRunner) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Active Runs")

      ForEach(activeRuns) { run in
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
                .fontWeight(.semibold)
              HStack(spacing: 8) {
                Text(run.status.displayName)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if run.executions.count > 0 {
                  Text("\(run.executions.count) task\(run.executions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
              }
            }

            Spacer()

            // Progress bar
            ProgressView(value: run.progress)
              .frame(width: 60)
          }
          .padding(4)
        }
      }
    }
  }

  @State private var showRecentRuns = false

  private func recentRunsSection(runner: ParallelWorktreeRunner) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          showRecentRuns.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: showRecentRuns ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 12)
          SectionHeader("Recent Runs (\(repoHistoricalSnapshots.count))")
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showRecentRuns {
        ForEach(repoHistoricalSnapshots.prefix(5)) { snapshot in
          recentRunRow(snapshot: snapshot, runner: runner)
        }
      }
    }
  }

  private func recentRunRow(snapshot: ParallelRunSnapshot, runner: ParallelWorktreeRunner) -> some View {
    let statusIcon: String = {
      switch snapshot.status {
      case "Completed": return "checkmark.circle.fill"
      case "Awaiting Review": return "eye.circle.fill"
      case "Failed": return "xmark.circle.fill"
      case "Cancelled": return "slash.circle.fill"
      default: return "clock.arrow.circlepath"
      }
    }()
    let statusColor: Color = {
      switch snapshot.status {
      case "Completed": return .green
      case "Awaiting Review": return .orange
      case "Failed": return .red
      case "Cancelled": return .gray
      default: return .secondary
      }
    }()
    let hasActionable = {
      guard let data = snapshot.executionsJSON.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
      return array.contains { dict in
        let s = dict["status"] as? String ?? ""
        return s == "Awaiting Review" || s == "Reviewed" || s == "Approved"
      }
    }()

    return GroupBox {
      HStack(spacing: 10) {
        Image(systemName: statusIcon)
          .font(.title3)
          .foregroundStyle(statusColor)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 2) {
          Text(snapshot.name)
            .fontWeight(.medium)
          HStack(spacing: 8) {
            Text(snapshot.status)
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("\(snapshot.executionCount) task\(snapshot.executionCount == 1 ? "" : "s")")
              .font(.caption)
              .foregroundStyle(.tertiary)
            if snapshot.mergedCount > 0 {
              Label("\(snapshot.mergedCount) merged", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
            }
          }
          Text(snapshot.updatedAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        Spacer()

        if hasActionable {
          Button {
            let run = runner.restoreFromSnapshot(snapshot)
            _ = run // triggers UI refresh since runner.runs is @Observable
          } label: {
            Label("Restore", systemImage: "arrow.uturn.backward.circle")
              .font(.caption)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Re-load this run with full approve/reject/merge controls")
        }
      }
      .padding(4)
    }
  }

  private var worktreesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Worktrees")

      ForEach(repo.activeWorktrees) { wt in
        RepoWorktreeRow(worktree: wt)
      }
    }
  }

  private var chainsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Agent Chains")

      ForEach(repo.activeChains) { chain in
        RepoChainRow(chain: chain)
      }
    }
  }

  private func fileStatusBadge(_ status: Git.FileStatus) -> some View {
    let (label, color): (String, Color) = {
      switch status {
      case .staged: return ("S", .blue)
      case .modifiedMe: return ("M", .yellow)
      case .new: return ("A", .green)
      case .deleted: return ("D", .red)
      case .untracked: return ("?", .purple)
      case .renamedMe: return ("R", .teal)
      case .ignored: return ("I", .gray)
      case .unknown: return ("?", .secondary)
      }
    }()

    return Text(label)
      .font(.caption2.monospaced().weight(.bold))
      .foregroundStyle(color)
      .frame(width: 20)
  }

  // MARK: Remote-Only Repo Content

  private var remoteRepoContent: some View {
    VStack(spacing: 16) {
      // Always show PRs section for remote repos (will fetch from API)
      prsSection

      if !repo.activeWorktrees.isEmpty {
        worktreesSection
      }
      if !repo.activeChains.isEmpty {
        chainsSection
      }

      if displayPRs.isEmpty && !isLoadingPRs && repo.activeWorktrees.isEmpty && repo.activeChains.isEmpty {
        ContentUnavailableView {
          Label("Not Cloned", systemImage: "arrow.down.to.line")
        } description: {
          Text("Clone this repository locally to view branches, commits, and local changes.")
        }
      }
    }
  }
  #endif

  private var notClonedPlaceholder: some View {
    ContentUnavailableView {
      Label("Branches", systemImage: "arrow.triangle.branch")
    } description: {
      Text("Branch and commit viewing is available on macOS.")
    }
  }

  // MARK: Data Loading

  private func loadGitRepo() async {
    #if os(macOS)
    if let localPath = repo.localPath, repo.isClonedLocally {
      let repository = Git.Model.Repository(name: repo.displayName, path: localPath)
      await repository.load(includeRemote: true)
      gitRepository = repository
      await loadRecentCommits(repository)
    } else {
      gitRepository = nil
    }
    #endif
  }

  private func refreshGitRepo() async {
    #if os(macOS)
    if let gitRepo = gitRepository {
      await gitRepo.load(includeRemote: true)
      await loadRecentCommits(gitRepo)
    }
    #endif
  }

  private func pullCurrentBranch() async {
    #if os(macOS)
    guard let gitRepo = gitRepository else { return }
    isPulling = true
    gitError = nil
    defer { isPulling = false }
    do {
      let activeBranch = gitRepo.localBranches.first(where: \.isActive)?.name
      try await Git.Commands.pull(branch: activeBranch, on: gitRepo)
      await gitRepo.load(includeRemote: true)
      await loadRecentCommits(gitRepo)
    } catch {
      gitError = "Pull failed: \(error.localizedDescription)"
    }
    #endif
  }

  private func fetchRemote() async {
    #if os(macOS)
    guard let gitRepo = gitRepository else { return }
    isFetching = true
    gitError = nil
    defer { isFetching = false }
    do {
      try await Git.Commands.fetch(on: gitRepo)
      await gitRepo.load(includeRemote: true)
      await loadRecentCommits(gitRepo)
    } catch {
      gitError = "Fetch failed: \(error.localizedDescription)"
    }
    #endif
  }

  private func checkoutBranch(_ branchName: String, gitRepo: Git.Model.Repository) async {
    #if os(macOS)
    gitError = nil
    do {
      _ = try await Git.Commands.checkout(branch: branchName, from: gitRepo)
      await gitRepo.load(includeRemote: true)
      await loadRecentCommits(gitRepo)
    } catch {
      gitError = "Checkout failed: \(error.localizedDescription)"
    }
    #endif
  }

  private func loadRecentCommits(_ gitRepo: Git.Model.Repository) async {
    #if os(macOS)
    let activeBranch = gitRepo.localBranches.first(where: \.isActive)?.name ?? "HEAD"
    recentCommits = Array(await Git.Commands.log(branch: activeBranch, on: gitRepo).prefix(10))
    #endif
  }

  // MARK: Recent Commits UI

  #if os(macOS)
  private var recentCommitsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Recent Commits")

      LazyVStack(spacing: 1) {
        ForEach(recentCommits) { entry in
          HStack(spacing: 10) {
            Text(entry.commit)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .frame(width: 60, alignment: .leading)

            Text(entry.message)
              .font(.callout)
              .lineLimit(1)
              .truncationMode(.tail)

            Spacer()

            Text(entry.date, style: .relative)
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
        }
      }
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }
  #endif

  /// Fetch open PRs from the GitHub API for this repo.
  private func fetchOpenPRs() async {
    guard let ownerRepo = repo.ownerSlashRepo else { return }
    let parts = ownerRepo.split(separator: "/")
    guard parts.count == 2 else { return }
    let owner = String(parts[0])
    let repoName = String(parts[1])

    isLoadingPRs = true
    defer { isLoadingPRs = false }

    do {
      let prs = try await Github.pullRequests(owner: owner, repository: repoName, state: "open")
      fetchedPRs = prs.map { pr in
        UnifiedRepository.PRSummary(
          id: UUID(),
          number: pr.number,
          title: pr.title ?? "Untitled",
          state: pr.state ?? "open",
          htmlURL: pr.html_url,
          headRef: pr.head.ref
        )
      }
    } catch {
      // Fall back to aggregator's recent PRs on failure
      fetchedPRs = []
    }
  }
}

// MARK: - Branch Row

private struct BranchRow: View {
  let branch: Git.Model.Branch
  var isRemote: Bool = false
  var onCheckout: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      if branch.isActive {
        Image(systemName: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else {
        Image(systemName: isRemote ? "cloud" : "arrow.triangle.branch")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(branch.name)
        .font(.callout)
        .fontWeight(branch.isActive ? .semibold : .regular)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      if branch.isActive {
        Text("current")
          .font(.caption2)
          .foregroundStyle(.green)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .contextMenu {
      if !branch.isActive, let onCheckout {
        Button {
          onCheckout()
        } label: {
          Label("Checkout", systemImage: "arrow.right.arrow.left")
        }
      }
    }
  }
}
#endif // os(macOS)

// MARK: - iOS Tab Views

#if os(iOS)
/// Simplified overview tab for iOS — shows PRs and basic repo info.
struct iOSOverviewTabView: View {
  let repo: UnifiedRepository
  @Environment(RepositoryAggregator.self) private var aggregator

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // PRs section
        if !repo.recentPRs.isEmpty {
          SectionHeader("Pull Requests")
          LazyVStack(spacing: 1) {
            ForEach(repo.recentPRs, id: \.id) { pr in
              RepoPRRow(pr: pr)
            }
          }
          .background(Color(.systemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        // Worktrees section
        if !repo.activeWorktrees.isEmpty {
          SectionHeader("Active Worktrees")
          LazyVStack(spacing: 1) {
            ForEach(repo.activeWorktrees, id: \.id) { wt in
              RepoWorktreeRow(worktree: wt)
            }
          }
          .background(Color(.systemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        // Chains section
        if !repo.activeChains.isEmpty {
          SectionHeader("Active Chains")
          LazyVStack(spacing: 1) {
            ForEach(repo.activeChains, id: \.id) { chain in
              RepoChainRow(chain: chain)
            }
          }
          .background(Color(.systemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if repo.recentPRs.isEmpty && repo.activeWorktrees.isEmpty && repo.activeChains.isEmpty {
          ContentUnavailableView {
            Label("No Activity", systemImage: "tray")
          } description: {
            Text("No recent pull requests, worktrees, or agent chains for this repository.")
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 40)
        }
      }
      .padding(16)
    }
  }
}

/// Simplified branches tab for iOS — shows local and remote branches.
struct iOSBranchesTabView: View {
  let repo: UnifiedRepository
  @State private var gitRepository: Git.Model.Repository?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let gitRepo = gitRepository {
          if !gitRepo.localBranches.isEmpty {
            SectionHeader("Branches")
            LazyVStack(spacing: 1) {
              ForEach(gitRepo.localBranches, id: \.name) { branch in
                HStack(spacing: 10) {
                  if branch.isActive {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.caption)
                      .foregroundStyle(.green)
                  } else {
                    Image(systemName: "arrow.triangle.branch")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Text(branch.name)
                    .font(.callout)
                    .fontWeight(branch.isActive ? .semibold : .regular)
                    .lineLimit(1)
                  Spacer()
                  if branch.isActive {
                    Text("current")
                      .font(.caption2)
                      .foregroundStyle(.green)
                  }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
              }
            }
            .background(Color(.systemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
        } else if repo.isClonedLocally {
          ProgressView("Loading branches…")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
          ContentUnavailableView {
            Label("Not Cloned", systemImage: "externaldrive.badge.xmark")
          } description: {
            Text("Clone this repository locally to view branches.")
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 40)
        }
      }
      .padding(16)
    }
    .task {
      if let path = repo.localPath {
        gitRepository = try? await Git.Model.Repository(name: repo.displayName, path: path)
      }
    }
  }
}
#endif

struct SkillsTabView: View {
  let repo: UnifiedRepository
  @Environment(DataService.self) private var dataService

  @State private var skills: [RepoGuidanceSkill] = []
  @State private var showInactive = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Header
        HStack {
          SectionHeader("Guidance Skills")

          Spacer()

          Toggle("Show Inactive", isOn: $showInactive)
            .toggleStyle(.switch)
            .controlSize(.small)

          Text("\(skills.count)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if skills.isEmpty {
          ContentUnavailableView {
            Label("No Skills", systemImage: "lightbulb.slash")
          } description: {
            Text("No guidance skills configured for this repository. Skills help agents understand your codebase conventions, patterns, and best practices.")
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 40)
        } else {
          LazyVStack(spacing: 1) {
            ForEach(skills, id: \.id) { skill in
              SkillRow(skill: skill)
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
      .padding(16)
    }
    .task(id: "\(repo.normalizedRemoteURL)-\(showInactive)") {
      loadSkills()
    }
  }

  private func loadSkills() {
    skills = dataService.listRepoGuidanceSkills(
      repoPath: repo.localPath,
      repoRemoteURL: repo.normalizedRemoteURL,
      includeInactive: showInactive,
      limit: nil
    )
  }
}

// MARK: - Skill Row

private struct SkillRow: View {
  let skill: RepoGuidanceSkill
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: skill.isActive ? "lightbulb.fill" : "lightbulb.slash")
          .foregroundStyle(skill.isActive ? .green : .gray)

        Text(skill.title.isEmpty ? "Untitled Skill" : skill.title)
          .fontWeight(.medium)

        Spacer()

        if !skill.tags.isEmpty {
          HStack(spacing: 4) {
            ForEach(skill.tags.components(separatedBy: ",").prefix(3), id: \.self) { tag in
              Text(tag.trimmingCharacters(in: .whitespaces))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.blue.opacity(0.1)))
                .foregroundStyle(.blue)
            }
          }
        }

        Text("P\(skill.priority)")
          .font(.caption)
          .foregroundStyle(priorityColor)
          .fontWeight(.semibold)

        if skill.appliedCount > 0 {
          Label("\(skill.appliedCount)×", systemImage: "checkmark.circle")
            .font(.caption2)
            .foregroundStyle(.green)
        }

        Button {
          withAnimation(.spring(response: 0.25)) { isExpanded.toggle() }
        } label: {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2)
        }
        .buttonStyle(.borderless)
      }

      HStack(spacing: 12) {
        Text(skill.source.isEmpty ? "manual" : skill.source)
          .font(.caption)
          .foregroundStyle(.secondary)

        Text(skill.updatedAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      if isExpanded, !skill.body.isEmpty {
        Divider()
        Text(skill.body)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var priorityColor: Color {
    if skill.priority >= 80 { return .red }
    if skill.priority >= 50 { return .orange }
    return .secondary
  }
}

// MARK: - Subview: Worktree Row

struct RepoWorktreeRow: View {
  let worktree: UnifiedRepository.WorktreeSummary
  var onDismiss: (() -> Void)?

  var body: some View {
    GroupBox {
      HStack(spacing: 12) {
        Image(systemName: "arrow.triangle.branch")
          .font(.title3)
          .foregroundStyle(.blue)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 4) {
          Text(worktree.branch)
            .fontWeight(.semibold)

          HStack(spacing: 8) {
            Text(worktree.source)
              .font(.caption)
              .foregroundStyle(.secondary)

            if let purpose = worktree.purpose {
              Text("·")
                .foregroundStyle(.tertiary)
              Text(purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }

        Spacer()

        Text(worktree.taskStatus)
          .font(.caption)
          .fontWeight(.medium)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(
            Capsule()
              .fill(worktreeStatusColor.opacity(0.1))
          )
          .foregroundStyle(worktreeStatusColor)
      }
      .padding(4)
    }
    .contextMenu {
      if let onDismiss {
        Button(role: .destructive) {
          onDismiss()
        } label: {
          Label("Remove from List", systemImage: "trash")
        }
      }
    }
  }

  private var worktreeStatusColor: Color {
    switch worktree.taskStatus {
    case TrackedWorktree.Status.active: return .blue
    case TrackedWorktree.Status.committed: return .green
    case TrackedWorktree.Status.failed: return .red
    case TrackedWorktree.Status.orphaned: return .orange
    default: return .secondary
    }
  }
}

// MARK: - Subview: PR Row

struct RepoPRRow: View {
  let pr: UnifiedRepository.PRSummary

  var body: some View {
    HStack(spacing: 10) {
      // State icon
      Image(systemName: prIcon)
        .font(.callout)
        .foregroundStyle(prColor)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(pr.title)
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)

        HStack(spacing: 6) {
          Text(verbatim: "#\(pr.number)")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text(pr.state.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(prColor.opacity(0.1)))
            .foregroundStyle(prColor)
        }
      }

      Spacer()

      if let url = pr.htmlURL, let _ = URL(string: url) {
        Image(systemName: "arrow.up.right.square")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Image(systemName: "chevron.right")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }

  private var prIcon: String {
    switch pr.state {
    case "open": return "arrow.triangle.pull"
    case "closed": return "xmark.circle.fill"
    case "merged": return "arrow.triangle.merge"
    default: return "arrow.triangle.pull"
    }
  }

  private var prColor: Color {
    switch pr.state {
    case "open": return .green
    case "closed": return .red
    case "merged": return .purple
    default: return .secondary
    }
  }
}

// MARK: - Subview: Chain Row

struct RepoChainRow: View {
  let chain: UnifiedRepository.ChainSummary

  var body: some View {
    GroupBox {
      HStack(spacing: 12) {
        if !chain.isTerminal {
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
          Text(chain.name)
            .fontWeight(.semibold)
          Text(chain.stateDisplay)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if !chain.isTerminal {
          Text("Running")
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.blue.opacity(0.1)))
            .foregroundStyle(.blue)
        }
      }
      .padding(4)
    }
  }
}

// MARK: - Subview: Activity Item Row

struct RepoActivityItemRow: View {
  let item: ActivityItem

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.kind.systemImage)
        .font(.callout)
        .foregroundStyle(colorForTint(item.kind.tintColorName))
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.callout)
          .lineLimit(1)
        if let subtitle = item.subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Spacer()

      Image(systemName: "chevron.right")
        .font(.caption2)
        .foregroundStyle(.tertiary)

      Text(item.relativeTime)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private func colorForTint(_ name: String) -> Color {
    switch name {
    case "green": return .green
    case "red": return .red
    case "blue": return .blue
    case "orange": return .orange
    case "purple": return .purple
    case "teal": return .teal
    case "gray": return .gray
    default: return .secondary
    }
  }
}
