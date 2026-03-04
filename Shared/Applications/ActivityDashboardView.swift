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

  private var swarm: SwarmCoordinator { SwarmCoordinator.shared }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Running Now
        runningNowSection

        // Workers panel — always visible
        workersSection

        // RAG Indexing status
        ragIndexingSection

        // Recent Activity
        recentActivitySection
      }
      .padding(20)
    }
    .navigationTitle("Activity")
    #if os(macOS)
    .toolbar {
      ToolSelectionToolbar()
      ChainActivityToolbar()
      ToolbarItem(placement: .primaryAction) {
        Button {
          // TODO: Open NewChainSheet
        } label: {
          Label("Run Task", systemImage: "play.fill")
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
    #endif
  }

  // MARK: - Running Now

  @ViewBuilder
  private var runningNowSection: some View {
    let runningChains = aggregator.allActiveChains
    let pullsInProgress = aggregator.repositories.filter {
      $0.pullStatus == .pulling
    }

    if !runningChains.isEmpty || !pullsInProgress.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        SectionHeader("Running Now")

        ForEach(runningChains) { chain in
          RunningChainCard(chain: chain)
            .contentShape(Rectangle())
            .onTapGesture { selectedChain = chain }
        }

        ForEach(pullsInProgress) { repo in
          RunningPullCard(repo: repo)
        }
      }
    }
  }

  // MARK: - Workers

  private var workersSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader("Swarm")

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

      let items = filteredItems
      if items.isEmpty {
        ContentUnavailableView {
          Label("No Activity", systemImage: "clock")
        } description: {
          Text("Agent runs, pulls, and other activity will appear here.")
        }
      } else {
        LazyVStack(spacing: 1) {
          ForEach(items.prefix(100)) { item in
            DashboardActivityRow(item: item) {
              navigateToChain(for: item)
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

  // MARK: - Chain Navigation

  private func navigateToChain(for item: ActivityItem) {
    var chainId: UUID?
    switch item.kind {
    case .chainStarted(let id): chainId = id
    case .chainCompleted(let id, _): chainId = id
    default: break
    }
    guard let chainId else { return }
    if let chain = mcpServer.agentManager.chains.first(where: { $0.id == chainId }) {
      selectedChain = chain
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
  var onTap: (() -> Void)? = nil

  private var isChainItem: Bool {
    switch item.kind {
    case .chainStarted, .chainCompleted: return true
    default: return false
    }
  }

  var body: some View {
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
            .lineLimit(2)
        }
      }

      Spacer()

      if isChainItem {
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      Text(item.relativeTime)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture {
      if isChainItem { onTap?() }
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
