//
//  ActivityDashboardView.swift
//  Peel
//
//  Dashboard tab showing live agent work, worker status, and recent activity
//  across all repositories. Replaces the scattered chain/worktree/swarm views.
//

import SwiftUI

// MARK: - Activity Dashboard

struct ActivityDashboardView: View {
  @Environment(ActivityFeed.self) private var activityFeed
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(MCPServerService.self) private var mcpServer

  @State private var filterMode: ActivityFilterMode = .all
  @State private var filterRepo: String? = nil  // nil = all repos
  @State private var selectedChain: AgentChain?
  @State private var expandedItems: Set<UUID> = []
  @State private var showingTemplateBrowser = false
  @State private var showingSwarmConsole = false
  @State private var recentPage = 0

  private let recentPageSize = 50

  private var swarm: SwarmCoordinator { SwarmCoordinator.shared }

  var body: some View {
    Group {
      if showingSwarmConsole {
        SwarmManagementView()
      } else {
        dashboardContent
      }
    }
    .navigationTitle(showingSwarmConsole ? "Swarm Console" : "Activity")
    .onChange(of: filterMode) { _, _ in
      recentPage = 0
    }
    .onChange(of: filterRepo) { _, _ in
      recentPage = 0
    }
    .onChange(of: filteredItems.count) { _, count in
      if count == 0 {
        recentPage = 0
      } else {
        recentPage = min(recentPage, totalRecentPages - 1)
      }
    }
    #if os(macOS)
    .toolbar {
      ToolSelectionToolbar()
      ChainActivityToolbar()
      if showingSwarmConsole {
        ToolbarItem(placement: .navigation) {
          Button {
            withAnimation(.easeInOut(duration: 0.2)) {
              showingSwarmConsole = false
            }
          } label: {
            Label("Back to Activity", systemImage: "chevron.left")
          }
        }
      } else {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showingTemplateBrowser = true
          } label: {
            Label("Run Task", systemImage: "play.fill")
          }
        }
      }
    }
    #endif
    #if os(macOS)
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
    .sheet(isPresented: $showingTemplateBrowser) {
      TemplateBrowserSheet()
    }
    #endif
  }

  // MARK: - Dashboard Content

  private var dashboardContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        runningNowSection
        PRReviewQueueSection()
        quickTemplatesSection
        workersSection
        ragIndexingSection
        recentActivitySection
      }
      .padding(20)
    }
  }

  // MARK: - Running Now

  @ViewBuilder
  private var runningNowSection: some View {
    let runningChains = aggregator.allActiveChains
    let pullsInProgress = aggregator.repositories.filter {
      $0.pullStatus == .pulling
    }
    let activeWorktrees = mcpServer.agentManager.workspaceManager.workspaces
      .filter { $0.status == .active || $0.status == .ready }

    if !runningChains.isEmpty || !pullsInProgress.isEmpty || !activeWorktrees.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        SectionHeader("Running Now")

        ForEach(runningChains) { chain in
          RunningChainCard(chain: chain)
            .contentShape(Rectangle())
            .onTapGesture { selectedChain = chain }
        }

        ForEach(activeWorktrees) { workspace in
          RunningWorktreeCard(workspace: workspace)
        }

        ForEach(pullsInProgress) { repo in
          RunningPullCard(repo: repo)
        }
      }
    }
  }

  // MARK: - Quick Templates

  private var quickTemplatesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionHeader("Templates")
        Spacer()
        Button {
          showingTemplateBrowser = true
        } label: {
          HStack(spacing: 4) {
            Text("Browse All")
            Image(systemName: "chevron.right")
          }
          .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
      }

      let coreTemplates = mcpServer.agentManager.allTemplates
        .filter { $0.category == .core }
        .prefix(4)

      HStack(spacing: 10) {
        ForEach(Array(coreTemplates)) { template in
          QuickTemplateCard(template: template) {
            showingTemplateBrowser = true
          }
        }
      }
    }
  }

  // MARK: - Workers

  private var workersSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionHeader("Swarm")
        Spacer()
        #if os(macOS)
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            showingSwarmConsole = true
          }
        } label: {
          Label("Open Console", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        #endif
      }

      if swarm.isActive {
        // Active swarm — show workers
        HStack(spacing: 16) {
          // This machine
          WorkerCard(
            name: Host.current().localizedName ?? "This Mac",
            role: swarm.role.rawValue,
            isOnline: true,
            statusText: swarm.currentTask != nil ? swarm.currentTask!.prompt : nil
          )

          // Connected peers
          ForEach(swarm.connectedWorkers) { peer in
            let status = swarm.workerStatuses[peer.id]
            WorkerCard(
              name: peer.displayName,
              role: "worker",
              isOnline: true,
              statusText: status?.state.rawValue ?? "connected"
            )
          }

          // Discovered but not connected
          ForEach(swarm.discoveredPeers.filter { peer in
            !swarm.connectedWorkers.contains(where: { $0.id == peer.id })
          }) { peer in
            WorkerCard(
              name: peer.displayName,
              role: "discovered",
              isOnline: false,
              statusText: "Not connected"
            )
          }
        }

        // Cluster stats
        HStack(spacing: 20) {
          Label("\(swarm.connectedWorkers.count + 1) online", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Label("\(swarm.tasksCompleted) completed", systemImage: "checkmark")
            .foregroundStyle(.secondary)
          if swarm.tasksFailed > 0 {
            Label("\(swarm.tasksFailed) failed", systemImage: "xmark.circle")
              .foregroundStyle(.red)
          }
        }
        .font(.caption)
      } else {
        // Inactive swarm — show prompt to start
        GroupBox {
          HStack(spacing: 12) {
            Image(systemName: "network.slash")
              .font(.title2)
              .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
              Text("Swarm Not Active")
                .fontWeight(.medium)
              Text("Start the swarm to distribute work across machines and see connected workers.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Start Swarm") {
              try? swarm.start(role: .hybrid)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }
          .padding(4)
        }
      }
    }
  }

  // MARK: - RAG Indexing

  @ViewBuilder
  private var ragIndexingSection: some View {
    let mcpServer = aggregator.mcpServerService
    if let indexingPath = mcpServer?.ragIndexingPath {
      VStack(alignment: .leading, spacing: 8) {
        SectionHeader("RAG Indexing")

        GroupBox {
          HStack(spacing: 12) {
            ProgressView()
              .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
              Text("Indexing repository…")
                .fontWeight(.medium)
              Text(indexingPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer()
          }
          .padding(4)
        }
      }
    }
  }

  // MARK: - Recent Activity

  private var recentActivitySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionHeader("Recent")
        Spacer()
        repoFilterMenu
        filterPicker
      }

      let pageItems = pagedRecentItems
      if pageItems.isEmpty {
        ContentUnavailableView {
          Label("No Activity", systemImage: "clock")
        } description: {
          Text("Agent runs, pulls, and other activity will appear here.")
        }
      } else {
        HStack {
          Text("Showing \(recentRange.start)-\(recentRange.end) of \(recentRange.total)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            recentPage = max(0, recentPage - 1)
          } label: {
            Label("Previous", systemImage: "chevron.left")
          }
          .buttonStyle(.borderless)
          .disabled(recentPage == 0)

          Text("Page \(recentPage + 1) of \(totalRecentPages)")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            recentPage = min(totalRecentPages - 1, recentPage + 1)
          } label: {
            Label("Next", systemImage: "chevron.right")
          }
          .buttonStyle(.borderless)
          .disabled(recentPage >= totalRecentPages - 1)
        }

        LazyVStack(spacing: 1) {
          ForEach(pageItems) { item in
            DashboardActivityRow(
              item: item,
              isExpanded: expandedItems.contains(item.id)
            ) {
              navigateToItem(item)
            }
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

  private var totalRecentPages: Int {
    max(1, Int(ceil(Double(filteredItems.count) / Double(recentPageSize))))
  }

  private var pagedRecentItems: [ActivityItem] {
    let items = filteredItems
    guard !items.isEmpty else { return [] }

    let safePage = min(max(recentPage, 0), totalRecentPages - 1)
    let start = safePage * recentPageSize
    let end = min(start + recentPageSize, items.count)
    return Array(items[start..<end])
  }

  private var recentRange: (start: Int, end: Int, total: Int) {
    let total = filteredItems.count
    guard total > 0 else { return (0, 0, 0) }

    let safePage = min(max(recentPage, 0), totalRecentPages - 1)
    let start = (safePage * recentPageSize) + 1
    let end = min((safePage + 1) * recentPageSize, total)
    return (start, end, total)
  }

  // MARK: - Repo Filter

  private var repoFilterMenu: some View {
    let repoNames = Set(activityFeed.items.compactMap(\.repoDisplayName)).sorted()
    return Menu {
      Button("All Repositories") { filterRepo = nil }
      Divider()
      ForEach(repoNames, id: \.self) { name in
        Button(name) { filterRepo = name }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease.circle")
        Text(filterRepo ?? "All Repos")
          .lineLimit(1)
      }
      .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  // MARK: - Filtering

  private var filterPicker: some View {
    Picker("Filter", selection: $filterMode) {
      ForEach(ActivityFilterMode.allCases, id: \.self) { mode in
        Text(mode.rawValue).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 300)
  }

  private var filteredItems: [ActivityItem] {
    var items: [ActivityItem]
    switch filterMode {
    case .all:
      items = activityFeed.items
    case .running:
      items = activityFeed.items.filter { item in
        switch item.kind {
        case .chainStarted: return true
        case .swarmDispatched: return true
        default: return false
        }
      }
    case .completed:
      items = activityFeed.items.filter { item in
        if case .chainCompleted(_, let success) = item.kind, success {
          return true
        }
        return false
      }
    case .failed:
      items = activityFeed.items.filter { $0.isError }
    }

    // Apply repo filter
    if let filterRepo {
      items = items.filter { $0.repoDisplayName == filterRepo }
    }

    return items
  }

  // MARK: - Item Navigation

  private func navigateToItem(_ item: ActivityItem) {
    switch item.kind {
    case .chainStarted(let id), .chainCompleted(let id, _):
      // Chain items open the full ChainDetailView (too complex for inline)
      if let chain = mcpServer.agentManager.chains.first(where: { $0.id == id }) {
        selectedChain = chain
      } else {
        toggleExpanded(item)
      }
    default:
      // All other items expand inline
      toggleExpanded(item)
    }
  }

  private func toggleExpanded(_ item: ActivityItem) {
    withAnimation(.easeInOut(duration: 0.2)) {
      if expandedItems.contains(item.id) {
        expandedItems.remove(item.id)
      } else {
        expandedItems.insert(item.id)
      }
    }
  }
}

// MARK: - Filter Mode

enum ActivityFilterMode: String, CaseIterable {
  case all = "All"
  case running = "Running"
  case completed = "Completed"
  case failed = "Failed"
}

// MARK: - Running Chain Card

struct RunningChainCard: View {
  let chain: AgentChain

  var body: some View {
    GroupBox {
      HStack(spacing: 12) {
        ProgressView()
          .controlSize(.small)

        VStack(alignment: .leading, spacing: 4) {
          Text(chain.name)
            .fontWeight(.semibold)

          HStack(spacing: 8) {
            Text(chain.state.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)

            if let prompt = chain.initialPrompt {
              Text("·")
                .foregroundStyle(.tertiary)
              Text(prompt.prefix(80))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }

          if let lastMsg = chain.liveStatusMessages.last {
            Text(lastMsg.message)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }

        Spacer()

        if let start = chain.runStartTime {
          Text(start, style: .relative)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(4)
    }
  }
}

// MARK: - Running Pull Card

struct RunningPullCard: View {
  let repo: UnifiedRepository

  var body: some View {
    GroupBox {
      HStack(spacing: 12) {
        ProgressView()
          .controlSize(.small)

        VStack(alignment: .leading, spacing: 2) {
          Text("Pulling \(repo.displayName)")
            .fontWeight(.medium)

          if let branch = repo.trackedBranch {
            Text("origin/\(branch) → local")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
      }
      .padding(4)
    }
  }
}

// MARK: - Worker Card

struct WorkerCard: View {
  let name: String
  let role: String
  let isOnline: Bool
  let statusText: String?

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Circle()
            .fill(isOnline ? .green : .red)
            .frame(width: 8, height: 8)

          Text(name)
            .fontWeight(.medium)
        }

        Text(role.capitalized)
          .font(.caption)
          .foregroundStyle(.secondary)

        if let text = statusText {
          Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
        } else {
          Text("Idle")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(4)
      .frame(minWidth: 140, alignment: .leading)
    }
  }
}

// MARK: - Dashboard Activity Row

struct DashboardActivityRow: View {
  let item: ActivityItem
  var isExpanded: Bool = false
  var onTap: (() -> Void)? = nil

  @Environment(MCPServerService.self) private var mcpServer
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Main row
      HStack(spacing: 12) {
        Image(systemName: item.kind.systemImage)
          .font(.callout)
          .foregroundStyle(colorForTint(item.kind.tintColorName))
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(item.title)
              .font(.callout)
              .lineLimit(1)

            if let repoName = item.repoDisplayName {
              Text("on \(repoName)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }

          if let subtitle = item.subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(isExpanded ? nil : 2)
          }
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))

        Text(item.relativeTime)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .onTapGesture { onTap?() }

      // Inline detail (expanded)
      if isExpanded {
        Divider()
          .padding(.horizontal, 12)

        inlineDetail
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  // MARK: - Inline Detail Content

  @ViewBuilder
  private var inlineDetail: some View {
    switch item.kind {
    case .chainStarted(let chainId), .chainCompleted(let chainId, _):
      chainInlineDetail(chainId: chainId)

    case .pullCompleted(let success):
      pullInlineDetail(success: success)

    case .ragIndexed:
      ragInlineDetail(type: "Index")

    case .ragAnalyzed:
      ragInlineDetail(type: "Analysis")

    case .worktreeCreated(let worktreeId):
      worktreeInlineDetail(worktreeId: worktreeId, created: true)

    case .worktreeCleaned(let worktreeId):
      worktreeInlineDetail(worktreeId: worktreeId, created: false)

    case .prActivity(let prNumber):
      prInlineDetail(prNumber: prNumber)

    case .swarmDispatched(let taskId):
      swarmInlineDetail(taskId: taskId)

    case .info:
      if let subtitle = item.subtitle {
        inlineRow("Details", subtitle)
      }
    }
  }

  @ViewBuilder
  private func chainInlineDetail(chainId: UUID) -> some View {
    if let chain = mcpServer.agentManager.chains.first(where: { $0.id == chainId }) {
      VStack(alignment: .leading, spacing: 4) {
        inlineRow("Status", chain.state.displayName)
        if let prompt = chain.initialPrompt {
          inlineRow("Prompt", prompt)
        }
        inlineRow("Agents", "\(chain.agents.count)")
        if let workDir = chain.workingDirectory {
          inlineRow("Dir", workDir)
        }
      }
    } else {
      Text("Chain no longer available")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func pullInlineDetail(success: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      inlineRow("Outcome", success ? "Pulled successfully" : "Pull failed")
      if let repoName = item.repoDisplayName,
         let repo = aggregator.repositories.first(where: { $0.displayName == repoName }) {
        if let branch = repo.trackedBranch {
          inlineRow("Branch", branch)
        }
      }
    }
  }

  private func ragInlineDetail(type: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      inlineRow("Operation", "RAG \(type) Complete")
      if let repoName = item.repoDisplayName {
        inlineRow("Repository", repoName)
      }
    }
  }

  private func worktreeInlineDetail(worktreeId: UUID, created: Bool) -> some View {
    let workspace = mcpServer.agentManager.workspaceManager.workspaces
      .first(where: { $0.id == worktreeId })

    return VStack(alignment: .leading, spacing: 4) {
      inlineRow("Action", created ? "Worktree Created" : "Worktree Cleaned Up")
      if let workspace {
        inlineRow("Branch", workspace.branch)
        inlineRow("Status", workspace.status.displayName)
      }
    }
  }

  @ViewBuilder
  private func prInlineDetail(prNumber: Int) -> some View {
    let matchingRepo = item.repoDisplayName.flatMap { name in
      aggregator.repositories.first(where: { $0.displayName == name })
    }
    let pr = matchingRepo?.recentPRs.first(where: { $0.number == prNumber })

    VStack(alignment: .leading, spacing: 4) {
      inlineRow("PR", "#\(prNumber)")
      if let pr {
        inlineRow("State", pr.state.capitalized)
      }
      if let pr, let urlString = pr.htmlURL, let url = URL(string: urlString) {
        Button {
          openURL(url)
        } label: {
          Label("Open in Browser", systemImage: "safari")
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.top, 2)
      }
    }
  }

  private func swarmInlineDetail(taskId: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      inlineRow("Task", taskId)
      inlineRow("Workers", "\(SwarmCoordinator.shared.connectedWorkers.count) connected")
    }
  }

  // MARK: - Helpers

  private func inlineRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 70, alignment: .trailing)
      Text(value)
        .font(.caption)
        .foregroundStyle(.primary)
        .textSelection(.enabled)
      Spacer()
    }
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

// MARK: - Running Worktree Card

struct RunningWorktreeCard: View {
  let workspace: AgentWorkspace

  var body: some View {
    GroupBox {
      HStack(spacing: 12) {
        Image(systemName: "arrow.triangle.branch")
          .font(.title3)
          .foregroundStyle(.blue)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 4) {
          Text(workspace.name)
            .fontWeight(.semibold)

          HStack(spacing: 8) {
            Label(workspace.branch, systemImage: "arrow.triangle.branch")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)

            Text("·")
              .foregroundStyle(.tertiary)

            Text(workspace.status.displayName)
              .font(.caption)
              .foregroundStyle(workspace.status == .active ? .green : .secondary)
          }

          Text(workspace.path.lastPathComponent)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer()

        if workspace.status == .active || workspace.status == .creating {
          ProgressView()
            .controlSize(.small)
        }

        Text(workspace.createdAt, style: .relative)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(4)
    }
  }
}

// MARK: - Quick Template Card

struct QuickTemplateCard: View {
  let template: ChainTemplate
  let onTap: () -> Void

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        Image(systemName: iconForCategory)
          .font(.title3)
          .foregroundStyle(Color.accentColor)

        Text(template.name)
          .font(.caption)
          .fontWeight(.medium)
          .lineLimit(1)

        Text("\(template.steps.count) step\(template.steps.count == 1 ? "" : "s")")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .onTapGesture { onTap() }
  }

  private var iconForCategory: String {
    switch template.category {
    case .core: return "bolt.fill"
    case .specialized: return "slider.horizontal.3"
    case .yolo: return "shield.checkmark.fill"
    }
  }
}
