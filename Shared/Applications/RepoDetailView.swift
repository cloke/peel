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
  case activity = "Activity"
  case rag = "RAG"
  case skills = "Skills"

  var systemImage: String {
    switch self {
    case .overview: return "square.grid.2x2"
    case .branches: return "arrow.triangle.branch"
    case .activity: return "clock"
    case .rag: return "magnifyingglass"
    case .skills: return "hammer"
    }
  }
}

// MARK: - Repo Detail View

struct RepoDetailView: View {
  let repo: UnifiedRepository

  @Environment(ActivityFeed.self) private var activityFeed
  @State private var selectedTab: RepoDetailTab = .overview

  var body: some View {
    VStack(spacing: 0) {
      // Header
      repoHeader

      Divider()

      // Tab picker
      Picker("", selection: $selectedTab) {
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
    switch selectedTab {
    case .overview:
      OverviewTabView(repo: repo)
    case .branches:
      BranchesTabView(repo: repo)
    case .activity:
      ActivityTabView(repo: repo)
    case .rag:
      RAGTabView(repo: repo)
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

// MARK: - Overview Tab

/// The default landing view for a repository. Surfaces actionable items:
/// PRs, pending approvals, agent work, and a compact health summary.
struct OverviewTabView: View {
  let repo: UnifiedRepository

  @Environment(MCPServerService.self) private var mcpServer
  @Environment(ActivityFeed.self) private var activityFeed
  @Environment(DataService.self) private var dataService
  @Environment(RepositoryAggregator.self) private var aggregator
  @State private var fetchedPRs: [UnifiedRepository.PRSummary] = []
  @State private var isLoadingPRs = false
  @State private var selectedPRDetail: PRDetailIdentifier?
  @State private var justTrackedId: UUID?
  @State private var isPullingSyncIndex = false
  @State private var syncPullResult: String?

  private var repoRuns: [ParallelWorktreeRun] {
    guard let runner = mcpServer.parallelWorktreeRunner,
          let localPath = repo.localPath else { return [] }
    return runner.runs.filter { run in
      guard run.projectPath == localPath else { return false }
      switch run.status {
      case .completed, .failed, .cancelled: return false
      default: return true
      }
    }
  }

  private var pendingApprovalRuns: [ParallelWorktreeRun] {
    repoRuns.filter { $0.pendingReviewCount > 0 || $0.readyToMergeCount > 0 }
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

          // 4. Repository Health — compact at-a-glance stats
          repoHealthSection

          // 5. Tracking Configuration — sync mode for tracked repos
          if repo.isTracked, let trackedId = repo.trackedRemoteRepoId {
            trackingConfigSection(trackedId: trackedId)
          } else if let trackedId = justTrackedId {
            trackingConfigSection(trackedId: trackedId)
          } else if !repo.isTracked, repo.localPath != nil, repo.remoteURL != nil {
            startTrackingSection
          }
        }
        .padding(16)
      }
      .task(id: repo.ownerSlashRepo) {
        await fetchOpenPRs()
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
          attentionCard(
            icon: "checkmark.shield",
            color: .purple,
            title: run.name,
            subtitle: "\(run.pendingReviewCount) task\(run.pendingReviewCount == 1 ? "" : "s") awaiting review",
            badge: "Review"
          )
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
        RepoWorktreeRow(worktree: wt)
      }
    }
  }

  // MARK: - Repository Health

  private var repoHealthSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Repository Health")

      GroupBox {
        LazyVGrid(columns: [
          GridItem(.flexible(), spacing: 12),
          GridItem(.flexible(), spacing: 12),
        ], spacing: 10) {
          healthItem(
            icon: "arrow.triangle.branch",
            color: .green,
            label: "Status",
            value: repo.isClonedLocally ? "Cloned" : "Remote"
          )

          if let pull = repo.pullStatus {
            healthItem(
              icon: pull.systemImage,
              color: pullIsHealthy(pull) ? .green : .secondary,
              label: "Auto-Pull",
              value: pull.displayName
            )
          } else {
            healthItem(
              icon: "arrow.down.circle",
              color: .secondary,
              label: "Auto-Pull",
              value: "Disabled"
            )
          }

          if let mode = repo.syncMode {
            healthItem(
              icon: mode.systemImage,
              color: mode == .pullAndSyncIndex ? .cyan : .blue,
              label: "RAG Strategy",
              value: mode.displayName
            )
          }

          if let rag = repo.ragStatus, rag != .notIndexed {
            healthItem(
              icon: rag.systemImage,
              color: .purple,
              label: "RAG Index",
              value: rag.displayName
            )
          } else {
            healthItem(
              icon: "magnifyingglass",
              color: .secondary,
              label: "RAG Index",
              value: "Not Indexed"
            )
          }

          healthItem(
            icon: "clock",
            color: .secondary,
            label: "Recent Activity",
            value: recentActivitySummary
          )
        }
        .padding(6)
      }
    }
  }

  private func healthItem(icon: String, color: Color, label: String, value: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.callout)
        .foregroundStyle(color)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 1) {
        Text(label)
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(value)
          .font(.caption)
          .fontWeight(.medium)
      }

      Spacer()
    }
  }

  private var recentActivitySummary: String {
    let items = activityFeed.items(for: repo.normalizedRemoteURL)
    if items.isEmpty { return "None" }
    let today = items.filter { Calendar.current.isDateInToday($0.timestamp) }
    if !today.isEmpty { return "\(today.count) today" }
    return items.first?.relativeTime ?? "None"
  }

  private func pullIsHealthy(_ status: UnifiedRepository.PullStatus) -> Bool {
    switch status {
    case .upToDate, .updated: return true
    default: return false
    }
  }

  // MARK: - Tracking Configuration

  private func trackingConfigSection(trackedId: UUID) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Tracking")

      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          Text("RAG Index Strategy")
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack(spacing: 8) {
            ForEach(TrackedRepoSyncMode.allCases, id: \.self) { mode in
              let isSelected = repo.syncMode == mode
              Button {
                updateSyncMode(trackedId: trackedId, mode: mode)
              } label: {
                HStack(spacing: 4) {
                  Image(systemName: mode.systemImage)
                    .font(.caption)
                  Text(mode.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                  isSelected
                    ? (mode == .pullAndSyncIndex ? Color.cyan.opacity(0.2) : Color.blue.opacity(0.2))
                    : Color.clear,
                  in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? .clear : Color.secondary.opacity(0.3), lineWidth: 1)
                )
              }
              .buttonStyle(.plain)
            }
          }

          Text((repo.syncMode ?? .pullAndRebuild).description)
            .font(.caption2)
            .foregroundStyle(.tertiary)

          // Show sync source info when Pull & Sync Index is selected
          if (repo.syncMode ?? .pullAndRebuild) == .pullAndSyncIndex {
            syncSourceInfo
          }
        }
        .padding(4)
      }
    }
  }

  @ViewBuilder
  private var syncSourceInfo: some View {
    let coordinator = RAGSyncCoordinator.shared
    let repoIdentifierCandidates = Set([
      repo.normalizedRemoteURL,
      repo.ownerSlashRepo.map { "github.com/\($0)".lowercased() },
      repo.ownerSlashRepo?.lowercased(),
      repo.remoteURL
    ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map { RepoRegistry.shared.normalizeRemoteURL($0) })
    let matchingSource = coordinator.availableUpdates.first(where: {
      repoIdentifierCandidates.contains(RepoRegistry.shared.normalizeRemoteURL($0.source.repoIdentifier))
        || $0.source.repoName == repo.displayName
    })

    Divider()

    if let source = matchingSource {
      HStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.caption)
          .foregroundStyle(.green)
        VStack(alignment: .leading, spacing: 1) {
          Text("Source: \(source.source.workerName)")
            .font(.caption)
            .fontWeight(.medium)
          Text("v\(source.source.version) · \(source.source.chunkCount) chunks · \(source.source.embeddingModel)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isPullingSyncIndex {
          ProgressView()
            .controlSize(.mini)
        } else if let result = syncPullResult {
          Text(result)
            .font(.caption2)
            .foregroundStyle(.green)
        } else {
          Button {
            Task { await pullFromSyncSource(source.source) }
          } label: {
            Label("Pull Now", systemImage: "arrow.down.circle")
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
        }
      }
    } else if coordinator.isActive {
      HStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.caption)
          .foregroundStyle(.orange)
        Text("No crown/brain peer has this index yet")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      HStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
        Text("Swarm not active — start swarm to discover sync sources")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func pullFromSyncSource(_ source: RAGIndexVersion) async {
    isPullingSyncIndex = true
    syncPullResult = nil
    do {
      let repoIdentifier = source.repoIdentifier
      let workerId = source.workerId
      // Try TCP peer first, fall back to on-demand
      let peers = SwarmCoordinator.shared.connectedWorkers
      if peers.contains(where: { $0.id == workerId }) {
        let transferId = try await SwarmCoordinator.shared.requestRagArtifactSync(
          direction: .pull,
          workerId: workerId,
          repoIdentifier: repoIdentifier
        )
        // Wait for completion
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(0.5))
          if let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) {
            if transfer.status == .complete {
              syncPullResult = "✓ Pulled"
              break
            } else if transfer.status == .failed {
              syncPullResult = "Failed"
              break
            }
          }
        }
      } else {
        try await SwarmCoordinator.shared.requestRagSyncOnDemand(
          repoIdentifier: repoIdentifier,
          fromWorkerId: workerId
        )
        syncPullResult = "✓ Pulled"
      }
      await mcpServer.refreshRagSummary()
    } catch {
      syncPullResult = "Failed"
    }
    isPullingSyncIndex = false
    // Auto-dismiss result
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(6))
      syncPullResult = nil
    }
  }

  private func updateSyncMode(trackedId: UUID, mode: TrackedRepoSyncMode) {
    guard let tracked = dataService.getTrackedRemoteRepo(id: trackedId) else { return }
    tracked.syncMode = mode
    tracked.reindexAfterPull = (mode == .pullAndRebuild)
    tracked.touch()
    try? dataService.modelContext.save()
    aggregator.rebuild()
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
      fetchedPRs = []
    }
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

    // Local changes
    if !gitRepo.status.isEmpty {
      localChangesCard(gitRepo)
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

        Button {
          Task { await refreshGitRepo() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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
          BranchRow(branch: branch)
        }
      }
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))

      // Remote branches (collapsible)
      if !gitRepo.remoteBranches.isEmpty {
        DisclosureGroup(isExpanded: $showRemoteBranches) {
          LazyVStack(spacing: 1) {
            ForEach(gitRepo.remoteBranches, id: \.name) { branch in
              BranchRow(branch: branch, isRemote: true)
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
    } else {
      gitRepository = nil
    }
    #endif
  }

  private func refreshGitRepo() async {
    #if os(macOS)
    if let gitRepo = gitRepository {
      await gitRepo.load(includeRemote: true)
    }
    #endif
  }

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
  }
}

// MARK: - Activity Tab

struct ActivityTabView: View {
  let repo: UnifiedRepository
  @Environment(ActivityFeed.self) private var activityFeed
  @State private var selectedItem: ActivityItem?
  @State private var filterMode: RepoActivityFilter = .all

  var body: some View {
    let repoItems = filteredItems

    if activityFeed.items(for: repo.normalizedRemoteURL).isEmpty {
      ContentUnavailableView {
        Label("No Activity", systemImage: "clock")
      } description: {
        Text("No recent activity for this repository.")
      }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          // Filter bar
          HStack {
            SectionHeader("Activity")
            Spacer()
            Picker("Filter", selection: $filterMode) {
              ForEach(RepoActivityFilter.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
              }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
          }

          if repoItems.isEmpty {
            ContentUnavailableView {
              Label("No Matching Activity", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
              Text("No \(filterMode.rawValue.lowercased()) activity for this repository.")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
          } else {
            // Grouped by day
            let grouped = groupedByDay(repoItems)
            ForEach(grouped, id: \.date) { group in
              VStack(alignment: .leading, spacing: 4) {
                Text(group.label)
                  .font(.caption)
                  .fontWeight(.medium)
                  .foregroundStyle(.secondary)
                  .padding(.top, 4)

                LazyVStack(spacing: 1) {
                  ForEach(group.items) { item in
                    RepoActivityItemRow(item: item)
                      .contentShape(Rectangle())
                      .onTapGesture { selectedItem = item }
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
        }
        .padding(16)
      }
      #if os(macOS)
      .sheet(item: $selectedItem) { item in
        ActivityItemDetailSheet(item: item)
      }
      #endif
    }
  }

  private var filteredItems: [ActivityItem] {
    let all = activityFeed.items(for: repo.normalizedRemoteURL)
    switch filterMode {
    case .all: return all
    case .chains:
      return all.filter { item in
        switch item.kind {
        case .chainStarted, .chainCompleted: return true
        default: return false
        }
      }
    case .pulls:
      return all.filter { item in
        if case .pullCompleted = item.kind { return true }
        return false
      }
    case .errors:
      return all.filter(\.isError)
    }
  }

  private struct DayGroup {
    let date: Date
    let label: String
    let items: [ActivityItem]
  }

  private func groupedByDay(_ items: [ActivityItem]) -> [DayGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: items) { item in
      calendar.startOfDay(for: item.timestamp)
    }

    return grouped.keys.sorted(by: >).map { date in
      let label: String
      if calendar.isDateInToday(date) {
        label = "Today"
      } else if calendar.isDateInYesterday(date) {
        label = "Yesterday"
      } else {
        label = date.formatted(.dateTime.month(.wide).day().year())
      }
      return DayGroup(date: date, label: label, items: grouped[date]!.sorted { $0.timestamp > $1.timestamp })
    }
  }
}

enum RepoActivityFilter: String, CaseIterable {
  case all = "All"
  case chains = "Chains"
  case pulls = "Pulls"
  case errors = "Errors"
}

// MARK: - RAG Tab

struct RAGTabView: View {
  let repo: UnifiedRepository
  @Environment(MCPServerService.self) private var mcpServer

  @State private var isIndexing = false
  @State private var indexError: String?
  @State private var searchQuery = ""
  @State private var searchMode: MCPServerService.RAGSearchMode = .vector
  @State private var searchResults: [LocalRAGSearchResult] = []
  @State private var isSearching = false
  @State private var searchError: String?
  @State private var lessons: [LocalRAGLesson] = []
  @State private var isAnalyzing = false
  @State private var analyzeError: String?
  @State private var analyzedChunks = 0
  @State private var isEnriching = false
  @State private var enrichError: String?
  @State private var enrichedChunks = 0
  @State private var enrichResult: String?
  @State private var enrichBatchProgress: (current: Int, total: Int)?

  // Swarm sync state
  @State private var swarm = SwarmCoordinator.shared
  @State private var isSyncing = false
  @State private var syncDirection: RAGArtifactSyncDirection?
  @State private var syncResultMessage: String?
  @State private var syncError: String?
  @State private var activeTransferId: UUID?
  @State private var onDemandProgress: String?

  private var isCurrentlyIndexing: Bool {
    mcpServer.ragIndexingPath == repo.localPath
  }

  private var analysisState: MCPServerService.RAGRepoAnalysisState? {
    guard let path = repo.localPath else { return nil }
    if let ragRepo = mcpServer.ragRepos.first(where: { $0.rootPath == path }) {
      return mcpServer.analysisState(for: ragRepo.id, repoPath: path)
    }
    return nil
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Prominent search bar (when indexed)
        if repo.ragStatus != nil && repo.ragStatus != .notIndexed, repo.localPath != nil {
          searchCard
        }

        // RAG status hero card
        ragStatusCard

        // Pipeline steps
        if repo.ragStatus != nil && repo.ragStatus != .notIndexed, repo.localPath != nil {
          pipelineCard
        }

        // Swarm sync
        if swarm.isActive {
          swarmSyncSection
        }

        // Lessons
        if !lessons.isEmpty {
          lessonsSection
        }
      }
      .padding(16)
    }
    .task {
      await loadLessons()
      await refreshAnalysisStatus()
    }
  }

  // MARK: - Search Card

  private var searchCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Search bar
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)

        TextField("Search this repo…", text: $searchQuery)
          .textFieldStyle(.plain)
          .onSubmit {
            Task { await runSearch() }
          }

        Picker("", selection: $searchMode) {
          Text("Vector").tag(MCPServerService.RAGSearchMode.vector)
          Text("Text").tag(MCPServerService.RAGSearchMode.text)
          Text("Hybrid").tag(MCPServerService.RAGSearchMode.hybrid)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)

        if isSearching {
          ProgressView()
            .controlSize(.small)
        } else {
          Button {
            Task { await runSearch() }
          } label: {
            Image(systemName: "arrow.right.circle.fill")
              .font(.title3)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.blue)
          .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      .padding(10)
      .background(
        RoundedRectangle(cornerRadius: 8)
          #if os(macOS)
          .fill(Color(nsColor: .controlBackgroundColor))
          #else
          .fill(Color(.systemGroupedBackground))
          #endif
      )

      if let error = searchError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      // Results
      if !searchResults.isEmpty {
        HStack {
          Text("\(searchResults.count) results")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }

        LazyVStack(spacing: 1) {
          ForEach(searchResults.prefix(20), id: \.filePath) { result in
            RepoSearchResultRow(result: result)
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

  // MARK: - RAG Status Card

  private var ragStatusCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          // Status icon
          ZStack {
            Circle()
              .fill(ragStatusColor.opacity(0.15))
              .frame(width: 40, height: 40)

            if isCurrentlyIndexing {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: ragStatusIcon)
                .font(.title3)
                .foregroundStyle(ragStatusColor)
            }
          }

          VStack(alignment: .leading, spacing: 2) {
            Text(ragStatusTitle)
              .font(.headline)

            if let model = repo.ragEmbeddingModel {
              Text(model)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          Spacer()

          // Action buttons
          if isCurrentlyIndexing {
            // No action while indexing
          } else if repo.ragStatus == nil || repo.ragStatus == .notIndexed {
            Button("Index Now") {
              Task { await indexRepo(force: false) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(repo.localPath == nil)
          } else {
            HStack(spacing: 6) {
              Button("Re-Index") {
                Task { await indexRepo(force: false) }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)

              Button {
                Task { await indexRepo(force: true) }
              } label: {
                Image(systemName: "arrow.clockwise")
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .help("Force full re-index")
            }
          }
        }

        // Stats row
        if repo.ragFileCount != nil || repo.ragChunkCount != nil || repo.ragLastIndexedAt != nil {
          Divider()

          HStack(spacing: 16) {
            if let fileCount = repo.ragFileCount {
              VStack(spacing: 2) {
                Text("\(fileCount)")
                  .font(.headline)
                Text("Files")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }

            if let chunkCount = repo.ragChunkCount {
              VStack(spacing: 2) {
                Text("\(chunkCount)")
                  .font(.headline)
                Text("Chunks")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }

            if let lastIndexed = repo.ragLastIndexedAt {
              VStack(spacing: 2) {
                Text(lastIndexed, style: .relative)
                  .font(.callout)
                Text("Last Indexed")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        if let error = indexError {
          Label(error, systemImage: "xmark.circle")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      .padding(4)
    }
  }

  private var ragStatusColor: Color {
    if isCurrentlyIndexing { return .orange }
    switch repo.ragStatus {
    case .indexed, .analyzed: return .green
    case .indexing: return .orange
    case .analyzing: return .purple
    case .stale: return .yellow
    case .notIndexed, .none: return .secondary
    }
  }

  private var ragStatusIcon: String {
    switch repo.ragStatus {
    case .indexed: return "checkmark.circle.fill"
    case .analyzed: return "checkmark.seal.fill"
    case .indexing: return "arrow.triangle.2.circlepath"
    case .analyzing: return "cpu.fill"
    case .stale: return "exclamationmark.triangle"
    case .notIndexed, .none: return "magnifyingglass.circle"
    }
  }

  private var ragStatusTitle: String {
    if isCurrentlyIndexing { return "Indexing…" }
    return repo.ragStatus?.displayName ?? "Not Indexed"
  }

  // MARK: - Pipeline Card

  private var pipelineCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader("AI Pipeline")

      // Visual pipeline steps
      HStack(spacing: 0) {
        PipelineStep(
          title: "Index",
          icon: "tray.full.fill",
          isComplete: repo.ragStatus != nil && repo.ragStatus != .notIndexed,
          isActive: isCurrentlyIndexing
        )

        PipelineArrow()

        PipelineStep(
          title: "Analyze",
          icon: "cpu",
          isComplete: (analysisState?.analyzedCount ?? 0) > 0 && !(analysisState?.isAnalyzing ?? false) && !isAnalyzing,
          isActive: isAnalyzing || (analysisState?.isAnalyzing ?? false)
        )

        PipelineArrow()

        PipelineStep(
          title: "Enrich",
          icon: "sparkles",
          isComplete: enrichedChunks > 0,
          isActive: isEnriching
        )
      }

      // Progress bar (when actively analyzing)
      if let state = analysisState, state.totalChunks > 0, (state.isAnalyzing || isAnalyzing) {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: state.progress)
            .tint(.purple)

          HStack(spacing: 8) {
            Text(verbatim: "\(state.analyzedCount) / \(state.totalChunks) chunks")
              .font(.caption2)
              .foregroundStyle(.secondary)

            if (state.isAnalyzing || isAnalyzing), state.chunksPerSecond > 0 {
              Text("·")
                .foregroundStyle(.tertiary)
              Text("\(String(format: "%.1f", state.chunksPerSecond)) chunks/sec")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(verbatim: "\(Int(state.progress * 100))%")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      // Info about chunks that couldn't be analyzed
      if let state = analysisState, !state.isComplete, !(state.isAnalyzing || isAnalyzing), state.analyzedCount > 0 {
        Text(verbatim: "\(state.analyzedCount) of \(state.totalChunks) chunks analyzed (\(state.unanalyzedCount) could not be processed)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      // Action buttons
      HStack(spacing: 8) {
        #if os(macOS)
        Button {
          Task { await analyzeChunks() }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "cpu")
            Text(isAnalyzing ? "Analyzing…" : "Analyze")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isAnalyzing || repo.localPath == nil)

        Button {
          Task { await enrichEmbeddings() }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "sparkles")
            Text(isEnriching ? "Enriching…" : "Enrich")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isEnriching || repo.localPath == nil)
        #else
        Text("AI Analysis requires macOS")
          .font(.caption)
          .foregroundStyle(.secondary)
        #endif

        Spacer()

        if analyzedChunks > 0 {
          Text("\(analyzedChunks) analyzed")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        if enrichedChunks > 0 {
          Text("\(enrichedChunks) enriched")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }

      // Batch progress bar (when actively analyzing)
      if isAnalyzing, let state = analysisState, let batch = state.batchProgress {
        VStack(alignment: .leading, spacing: 2) {
          ProgressView(value: Double(batch.current), total: Double(batch.total))
            .tint(.purple)
          HStack {
            Text("Chunk \(batch.current) of \(batch.total)")
              .font(.caption2)
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Spacer()
            if state.chunksPerSecond > 0 {
              Text("\(String(format: "%.1f", state.chunksPerSecond)) chunks/sec")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
        }
      }

      // Batch progress bar (when actively enriching)
      if isEnriching, let batch = enrichBatchProgress {
        VStack(alignment: .leading, spacing: 2) {
          ProgressView(value: Double(batch.current), total: Double(batch.total))
            .tint(.orange)
          HStack {
            Text("Enriching \(batch.current) of \(batch.total)")
              .font(.caption2)
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Spacer()
          }
        }
      }

      // Errors
      if let error = analyzeError {
        Label(error, systemImage: "xmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
      }
      if let error = enrichError {
        Label(error, systemImage: "xmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
      }
      if let result = enrichResult {
        Label(result, systemImage: result.contains("No ") ? "info.circle" : "checkmark.circle")
          .font(.caption)
          .foregroundColor(result.contains("No ") ? .secondary : .green)
      }
    }
  }

  // MARK: - Lessons Section

  private var lessonsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionHeader("Learned Lessons")
        Spacer()
        Text("\(lessons.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      LazyVStack(spacing: 1) {
        ForEach(lessons.prefix(10), id: \.id) { lesson in
          HStack(spacing: 10) {
            Circle()
              .fill(lesson.confidence >= 0.7 ? .green : lesson.confidence >= 0.4 ? .orange : .red)
              .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
              Text(lesson.fixDescription)
                .font(.callout)
                .lineLimit(2)

              HStack(spacing: 8) {
                Text("\(Int(lesson.confidence * 100))% confidence")
                if lesson.applyCount > 0 {
                  Text("· Applied \(lesson.applyCount)×")
                }
                if !lesson.source.isEmpty {
                  Text("· \(lesson.source)")
                }
              }
              .font(.caption2)
              .foregroundStyle(.tertiary)
            }

            Spacer()
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

      if lessons.count > 10 {
        Text("+ \(lessons.count - 10) more lessons")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Swarm Sync

  /// Derives the repo identifier used by the swarm sync protocol.
  private var ragRepoIdentifier: String? {
    if let ragRepo = mcpServer.ragRepos.first(where: { $0.rootPath == repo.localPath }) {
      return ragRepo.repoIdentifier
    }
    return repo.normalizedRemoteURL.isEmpty ? nil : repo.normalizedRemoteURL
  }

  private var swarmSyncSection: some View {
    let peers = swarm.connectedWorkers
    let onDemandWorkers = swarm.onDemandWorkers

    return VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Swarm Sync")

      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          // Status / progress area
          if let progress = onDemandProgress {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text(progress)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else if let transferId = activeTransferId,
                    let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text(syncTransferLabel(transfer))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else if let result = syncResultMessage {
            HStack(spacing: 6) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
              Text(result)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else if let error = syncError {
            HStack(spacing: 6) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }

          // Action buttons
          if let repoId = ragRepoIdentifier {
            HStack(spacing: 8) {
              if !peers.isEmpty {
                if peers.count > 1 {
                  syncPeerMenu(peers: peers, repoIdentifier: repoId, direction: .push)
                  syncPeerMenu(peers: peers, repoIdentifier: repoId, direction: .pull)
                } else {
                  Button {
                    Task { await syncWithPeers(repoIdentifier: repoId, direction: .push) }
                  } label: {
                    syncButtonLabel("Push", icon: "arrow.up.circle", active: isSyncing && syncDirection == .push)
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .disabled(isSyncing)

                  Button {
                    Task { await syncWithPeers(repoIdentifier: repoId, direction: .pull) }
                  } label: {
                    syncButtonLabel("Pull", icon: "arrow.down.circle", active: isSyncing && syncDirection == .pull)
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .disabled(isSyncing)
                }
              } else if !onDemandWorkers.isEmpty {
                if onDemandWorkers.count > 1 {
                  onDemandMenu(workers: onDemandWorkers, repoIdentifier: repoId)
                } else {
                  Button {
                    Task { await syncOnDemand(repoIdentifier: repoId, fromWorkerId: onDemandWorkers[0].id) }
                  } label: {
                    syncButtonLabel("Pull (WAN)", icon: "arrow.down.circle", active: isSyncing && syncDirection == .pull)
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .disabled(isSyncing)
                }
              } else {
                HStack(spacing: 6) {
                  Image(systemName: "network.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                  Text("No peers or WAN workers available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }

              Spacer()
            }
          } else {
            HStack(spacing: 6) {
              Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
              Text("Index this repo first to enable swarm sync")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(4)
      }
    }
  }

  @ViewBuilder
  private func syncButtonLabel(_ title: String, icon: String, active: Bool) -> some View {
    if active {
      HStack(spacing: 4) {
        ProgressView()
          .controlSize(.mini)
        Text("\(title)…")
      }
    } else {
      Label(title, systemImage: icon)
    }
  }

  private func syncPeerMenu(peers: [ConnectedPeer], repoIdentifier: String, direction: RAGArtifactSyncDirection) -> some View {
    let isPush = direction == .push
    let label = isPush ? "Push" : "Pull"
    let icon = isPush ? "arrow.up.circle" : "arrow.down.circle"
    let isActive = isSyncing && syncDirection == direction

    return Menu {
      ForEach(peers) { peer in
        Button {
          Task { await syncWithPeers(repoIdentifier: repoIdentifier, direction: direction, workerId: peer.id) }
        } label: {
          Label(peer.displayName, systemImage: "desktopcomputer")
        }
      }
    } label: {
      syncButtonLabel(label, icon: icon, active: isActive)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isSyncing)
  }

  private func onDemandMenu(workers: [FirestoreWorker], repoIdentifier: String) -> some View {
    let isActive = isSyncing && syncDirection == .pull

    return Menu {
      ForEach(workers, id: \.id) { worker in
        Button {
          Task { await syncOnDemand(repoIdentifier: repoIdentifier, fromWorkerId: worker.id) }
        } label: {
          Label(worker.displayName, systemImage: "desktopcomputer")
        }
      }
    } label: {
      syncButtonLabel("Pull (WAN)", icon: "arrow.down.circle", active: isActive)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isSyncing)
  }

  private func syncTransferLabel(_ transfer: RAGArtifactTransferState) -> String {
    switch transfer.status {
    case .queued: return "Queued…"
    case .preparing: return "Preparing…"
    case .transferring:
      if transfer.totalBytes > 0 {
        let pct = Int(Double(transfer.transferredBytes) / Double(transfer.totalBytes) * 100)
        return "Transferring: \(pct)%"
      }
      return "Transferring…"
    case .applying: return "Applying…"
    case .complete: return "Complete"
    case .failed: return transfer.errorMessage ?? "Failed"
    }
  }

  // MARK: - Sync Actions

  private func syncWithPeers(repoIdentifier: String, direction: RAGArtifactSyncDirection, workerId: String? = nil) async {
    isSyncing = true
    syncDirection = direction
    syncResultMessage = nil
    syncError = nil
    activeTransferId = nil
    onDemandProgress = nil

    do {
      let transferId = try await SwarmCoordinator.shared.requestRagArtifactSync(
        direction: direction,
        workerId: workerId,
        repoIdentifier: repoIdentifier
      )
      activeTransferId = transferId

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(0.5))
        if let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) {
          switch transfer.status {
          case .complete:
            if direction == .pull, let summary = transfer.resultSummary {
              let modelNote = transfer.remoteEmbeddingModel.map { " (model: \($0))" } ?? ""
              syncResultMessage = "Pulled from \(transfer.peerName): \(summary)\(modelNote)"
            } else {
              syncResultMessage = direction == .push ? "Pushed to \(transfer.peerName)" : "Pulled from \(transfer.peerName)"
            }
            activeTransferId = nil
            isSyncing = false
            syncDirection = nil
            if direction == .pull {
              await mcpServer.refreshRagSummary()
              await refreshAnalysisStatus()
            }
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(8))
              if syncResultMessage != nil { syncResultMessage = nil }
            }
            return
          case .failed:
            syncError = transfer.errorMessage ?? "Transfer failed"
            activeTransferId = nil
            isSyncing = false
            syncDirection = nil
            return
          default:
            continue
          }
        }
      }
    } catch {
      syncError = "Sync failed: \(error.localizedDescription)"
    }
    isSyncing = false
    syncDirection = nil
  }

  private func syncOnDemand(repoIdentifier: String, fromWorkerId: String) async {
    let workerName = FirebaseService.shared.swarmWorkers
      .first(where: { $0.id == fromWorkerId })?.displayName ?? fromWorkerId

    isSyncing = true
    syncDirection = .pull
    syncResultMessage = nil
    syncError = nil
    activeTransferId = nil
    onDemandProgress = "Requesting pull from \(workerName)…"

    var syncFinished = false

    let syncTask = Task { @MainActor in
      try await SwarmCoordinator.shared.requestRagSyncOnDemand(
        repoIdentifier: repoIdentifier,
        fromWorkerId: fromWorkerId
      )
    }

    let coordinator = RAGSyncCoordinator.shared
    while !syncFinished && !Task.isCancelled {
      if let transfer = coordinator.activeTransfers.values.first(where: {
        $0.repoIdentifier == repoIdentifier && $0.targetWorkerId == fromWorkerId
      }) {
        let method = transfer.connectionMethod?.rawValue ?? "connecting"
        switch transfer.status {
        case .connecting:
          onDemandProgress = "Connecting (\(method))…"
        case .handshaking:
          onDemandProgress = "Handshaking via \(method)…"
        case .transferring:
          let elapsed = Int(transfer.elapsedSeconds)
          if transfer.totalBytes > 0 && transfer.transferredBytes > 0 {
            let pct = Int(transfer.progressFraction * 100)
            onDemandProgress = "Downloading via \(method): \(pct)% [\(elapsed)s]"
          } else if transfer.totalChunks > 0 {
            onDemandProgress = "Uploading via \(method): \(transfer.chunksReceived)/\(transfer.totalChunks) chunks [\(elapsed)s]"
          } else {
            onDemandProgress = "Waiting for remote export via \(method)… [\(elapsed)s]"
          }
        case .importing:
          let byteStr = formatBytes(transfer.transferredBytes)
          onDemandProgress = "Importing \(byteStr)…"
        case .complete:
          syncFinished = true
        case .failed:
          syncFinished = true
        }
      }

      try? await Task.sleep(for: .seconds(0.3))
    }

    // Read final state
    if let transfer = coordinator.activeTransfers.values.first(where: {
      $0.repoIdentifier == repoIdentifier && $0.targetWorkerId == fromWorkerId
    }) {
      switch transfer.status {
      case .complete:
        let byteStr = formatBytes(transfer.transferredBytes)
        syncResultMessage = "Pulled from \(workerName): \(byteStr)"
        await mcpServer.refreshRagSummary()
        await refreshAnalysisStatus()
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(8))
          if syncResultMessage != nil { syncResultMessage = nil }
        }
      case .failed:
        syncError = transfer.error ?? "On-demand sync failed"
      default:
        break
      }
    } else {
      // If we can't find the transfer, check the task result
      do {
        try await syncTask.value
        syncResultMessage = "Pulled from \(workerName)"
        await mcpServer.refreshRagSummary()
        await refreshAnalysisStatus()
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(8))
          if syncResultMessage != nil { syncResultMessage = nil }
        }
      } catch {
        syncError = "On-demand sync failed: \(error.localizedDescription)"
      }
    }

    onDemandProgress = nil
    isSyncing = false
    syncDirection = nil
  }

  private func formatBytes(_ bytes: Int) -> String {
    if bytes >= 1_048_576 {
      return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    } else if bytes >= 1024 {
      return String(format: "%.0f KB", Double(bytes) / 1024)
    }
    return "\(bytes) B"
  }

  // MARK: - Actions

  private func indexRepo(force: Bool) async {
    guard let path = repo.localPath else { return }
    isIndexing = true
    indexError = nil
    do {
      try await mcpServer.indexRagRepo(path: path, forceReindex: force)
      await mcpServer.refreshRagSummary()
    } catch {
      indexError = error.localizedDescription
    }
    isIndexing = false
  }

  private func runSearch() async {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    isSearching = true
    searchError = nil
    do {
      searchResults = try await mcpServer.searchRag(
        query: trimmed,
        mode: searchMode,
        repoPath: repo.localPath,
        limit: 15
      )
    } catch {
      searchError = error.localizedDescription
    }
    isSearching = false
  }

  private func refreshAnalysisStatus() async {
    guard let path = repo.localPath else { return }
    do {
      let unanalyzed = try await mcpServer.getUnanalyzedChunkCount(repoPath: path)
      let analyzed = try await mcpServer.getAnalyzedChunkCount(repoPath: path)
      let enriched = try await mcpServer.getEnrichedChunkCount(repoPath: path)
      if let state = analysisState {
        state.unanalyzedCount = unanalyzed
        state.analyzedCount = analyzed
      }
      enrichedChunks = enriched
    } catch {
      // Non-critical
    }
  }

  private func analyzeChunks() async {
    guard let path = repo.localPath else { return }
    isAnalyzing = true
    analyzeError = nil
    let state = analysisState
    state?.isAnalyzing = true
    state?.analyzeError = nil
    state?.analysisStartTime = Date()
    let batchStart = Date()
    do {
      let count = try await mcpServer.analyzeRagChunks(
        repoPath: path,
        limit: 500
      ) { current, total in
        Task { @MainActor in
          state?.batchProgress = (current, total)
        }
      }
      analyzedChunks = count
      if let state {
        state.analyzedCount += count
        state.unanalyzedCount = max(0, state.unanalyzedCount - count)
        let elapsed = Date().timeIntervalSince(batchStart)
        if elapsed > 0, count > 0 {
          state.chunksPerSecond = Double(count) / elapsed
        }
      }
    } catch {
      analyzeError = error.localizedDescription
      state?.analyzeError = error.localizedDescription
    }
    isAnalyzing = false
    state?.isAnalyzing = false
    state?.batchProgress = nil
    state?.analysisStartTime = nil
    await refreshAnalysisStatus()
  }

  private func enrichEmbeddings() async {
    guard let path = repo.localPath else { return }
    isEnriching = true
    enrichError = nil
    enrichResult = nil
    enrichBatchProgress = nil
    do {
      let count = try await mcpServer.enrichRagEmbeddings(
        repoPath: path,
        limit: 500
      ) { current, total in
        Task { @MainActor in
          enrichBatchProgress = (current: current, total: total)
        }
      }
      enrichedChunks = count
      if count == 0 {
        let analyzedCount = (try? await mcpServer.getAnalyzedChunkCount(repoPath: path)) ?? 0
        if analyzedCount > 0 {
          enrichResult = "All \(analyzedCount) analyzed chunks already enriched"
        } else {
          enrichResult = "No analyzed chunks found — run Analyze first"
        }
      } else {
        enrichResult = "Enriched \(count) chunks"
      }
      await refreshAnalysisStatus()
    } catch {
      enrichError = error.localizedDescription
    }
    isEnriching = false
    enrichBatchProgress = nil
  }

  private func loadLessons() async {
    guard let path = repo.localPath else { return }
    do {
      lessons = try await mcpServer.listLessons(
        repoPath: path,
        includeInactive: false,
        limit: nil
      )
    } catch {
      // Lessons are optional — silently fail
    }
  }
}

// MARK: - Pipeline Step

private struct PipelineStep: View {
  let title: String
  let icon: String
  let isComplete: Bool
  let isActive: Bool

  var body: some View {
    VStack(spacing: 6) {
      ZStack {
        Circle()
          .fill(stepColor.opacity(0.15))
          .frame(width: 36, height: 36)

        if isActive {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: isComplete ? "checkmark" : icon)
            .font(.callout)
            .foregroundStyle(stepColor)
        }
      }

      Text(title)
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundStyle(isComplete || isActive ? .primary : .secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var stepColor: Color {
    if isActive { return .blue }
    if isComplete { return .green }
    return .secondary
  }
}

private struct PipelineArrow: View {
  var body: some View {
    Image(systemName: "chevron.right")
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .frame(width: 20)
  }
}

// MARK: - Repo Search Result Row

private struct RepoSearchResultRow: View {
  let result: LocalRAGSearchResult

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Score
      if let score = result.score {
        Text("\(Int(score * 100))")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.blue)
          .frame(width: 28)
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(displayPath)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)

          Spacer()

          Text("L\(result.startLine)–\(result.endLine)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        Text(result.snippet.components(separatedBy: "\n").first ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }

  private var displayPath: String {
    let path = result.filePath
    // Trim to show just the relative portion
    if let range = path.range(of: "/", options: .backwards) {
      return String(path[range.lowerBound...])
    }
    return path
  }
}

// MARK: - Skills Tab

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
    .task(id: showInactive) {
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
