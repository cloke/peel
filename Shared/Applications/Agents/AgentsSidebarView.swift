//
//  AgentsSidebarView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

struct AgentsSidebarView: View {
  @Bindable var agentManager: AgentManager
  @Bindable var cliService: CLIService
  @Environment(MCPServerService.self) private var mcpServer
  @Binding var showingSetupSheet: Bool
  @Binding var showingNewChainSheet: Bool
  @Binding var showingNewAgentSheet: Bool
  @Binding var selectedInfrastructure: InfrastructureView?
  @AppStorage("vm.isolation.section") private var vmIsolationSection = "overview"
  @AppStorage("vm.isolation.sidebar.expanded") private var vmIsolationSidebarExpanded = true
  @State private var parallelWorktreeStatus: ParallelWorktreeSummary = .empty
  @State private var worktreeCount: Int = 0

  // Track selection as a string: "chain:id" or "agent:id" or "infra:key"
  @State private var selection: String?

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $selection) {
        // Running chains - show prominently at top
        let runningChains = agentManager.chains.filter {
          if case .running = $0.state { return true }
          if case .reviewing = $0.state { return true }
          return false
        }
        // Saved chain templates / recent chains
        let idleChains = agentManager.chains.filter {
          if case .idle = $0.state { return true }
          if case .complete = $0.state { return true }
          if case .failed = $0.state { return true }
          return false
        }
        if !runningChains.isEmpty {
          Section {
            ForEach(runningChains) { chain in
              RunningChainRowView(chain: chain)
                .tag("chain:\(chain.id.uuidString)")
            }
          } header: {
            Label("Running Now", systemImage: "bolt.fill")
              .foregroundStyle(.blue)
          }
        }

        if !idleChains.isEmpty {
          Section("Recent Chains") {
            ForEach(idleChains) { chain in
              ChainRowView(chain: chain)
                .tag("chain:\(chain.id.uuidString)")
            }
          }
        }

        if !agentManager.activeAgents.isEmpty {
          Section("Active") {
            ForEach(agentManager.activeAgents) { agent in
              AgentRowView(agent: agent)
                .tag("agent:\(agent.id.uuidString)")
            }
          }
        }

        if !agentManager.activeAgents.isEmpty || !agentManager.idleAgents.isEmpty {
          Section("Agents") {
            ForEach(agentManager.idleAgents) { agent in
              AgentRowView(agent: agent)
                .tag("agent:\(agent.id.uuidString)")
            }
          }
        }

        Section("Connections") {
          Button {
            showingSetupSheet = true
          } label: {
            HStack {
              Image(systemName: copilotStatusIcon)
                .foregroundStyle(copilotStatusColor)
              Text("Copilot")
              Spacer()
              Text(copilotStatusLabel)
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("agents.cliSetup")

          Button {
            showingSetupSheet = true
          } label: {
            HStack {
              Image(systemName: cliService.claudeStatus.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(cliService.claudeStatus.isAvailable ? .green : .secondary)
              Text("Claude")
              Spacer()
              Text(cliService.claudeStatus.isAvailable ? "Ready" : "Not installed")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("agents.cliSetup")
        }

        Section("Tools") {
          HStack {
            Image(systemName: mcpServer.isRunning ? "waveform.path.ecg" : "waveform.path")
              .foregroundStyle(mcpServer.isRunning ? .green : .secondary)
            Text("MCP Activity")
            Spacer()
            if mcpServer.activeRequests > 0 {
              Chip(
                text: "\(mcpServer.activeRequests)",
                foreground: .blue,
                background: .blue.opacity(0.2)
              )
            }
          }
          .accessibilityIdentifier("agents.mcpDashboard")
          .tag("infra:mcp-dashboard")

          HStack {
            Image(systemName: "square.grid.2x2")
              .foregroundStyle(.blue)
            Text("Template Gallery")
            Spacer()
          }
          .accessibilityIdentifier("agents.templateGallery")
          .tag("infra:template-gallery")

          HStack {
            Image(systemName: "magnifyingglass.circle")
              .foregroundStyle(.teal)
            Text("Local RAG")
            Spacer()
          }
          .accessibilityIdentifier("agents.localRag")
          .tag("infra:local-rag")

          HStack {
            Image(systemName: "shield.lefthalf.filled")
              .foregroundStyle(.orange)
            Text("PII Scrubber")
            Spacer()
          }
          .accessibilityIdentifier("agents.piiScrubber")
          .tag("infra:pii-scrubber")

          HStack {
            Image(systemName: "character.book.closed")
              .foregroundStyle(.indigo)
            Text("Translation Validation")
            Spacer()
          }
          .accessibilityIdentifier("agents.translationValidation")
          .tag("infra:translation-validation")

          HStack {
            Image(systemName: "arrow.triangle.branch")
              .foregroundStyle(.mint)
            Text("Parallel Worktrees")
            Spacer()
            if parallelWorktreeStatus.totalRuns > 0 {
              Chip(
                text: "Runs \(parallelWorktreeStatus.totalRuns)",
                foreground: .mint,
                background: .mint.opacity(0.2)
              )
            }
          }
          .accessibilityIdentifier("agents.parallelWorktrees")
          .tag("infra:parallel-worktrees")

          HStack {
            Image(systemName: "folder.badge.gearshape")
              .foregroundStyle(.cyan)
            Text("Worktrees")
            Spacer()
            if worktreeCount > 0 {
              Chip(
                text: "\(worktreeCount)",
                foreground: .cyan,
                background: .cyan.opacity(0.2)
              )
            }
          }
          .accessibilityIdentifier("agents.worktrees")
          .tag("infra:worktrees")

          if parallelWorktreeStatus.totalRuns > 0 {
            HStack(spacing: 8) {
              sidebarToken(icon: "tray.full", color: .secondary, value: parallelWorktreeStatus.totalRuns)
              sidebarToken(icon: "clock", color: .secondary, value: parallelWorktreeStatus.pendingRuns)
              sidebarToken(icon: "square.stack.3d.up", color: .blue, value: parallelWorktreeStatus.totalExecutions)
              sidebarToken(icon: "bolt.fill", color: .mint, value: parallelWorktreeStatus.runningExecutions)
              sidebarToken(icon: "hourglass", color: .orange, value: parallelWorktreeStatus.awaitingReviewExecutions)
              sidebarToken(icon: "hand.thumbsdown.fill", color: .red, value: parallelWorktreeStatus.rejectedExecutions)
              sidebarToken(icon: "checkmark.circle", color: .green, value: parallelWorktreeStatus.readyToMergeExecutions)
              sidebarToken(icon: "xmark.octagon", color: .red, value: parallelWorktreeStatus.failedExecutions)
              sidebarToken(icon: "exclamationmark.triangle", color: .yellow, value: parallelWorktreeStatus.hungExecutions)
              Spacer()
            }
            .font(.caption2)
            .padding(.leading, 24)
          }
        }

        Section {
          DisclosureGroup("VM Isolation", isExpanded: $vmIsolationSidebarExpanded) {
            vmIsolationRow(title: "Overview", icon: "shield.checkered", section: "overview")
            vmIsolationRow(title: "Linux", icon: "server.rack", section: "linux")
            vmIsolationRow(title: "macOS", icon: "desktopcomputer", section: "macos")
            vmIsolationRow(title: "Pools", icon: "square.grid.2x2", section: "pools")
          }
        }
      }
      .listStyle(.sidebar)

      // Quick action buttons at bottom of sidebar
      Divider()
      HStack(spacing: 12) {
        Button {
          showingNewAgentSheet = true
        } label: {
          Label("Agent", systemImage: "cpu")
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("agents.newAgent")

        Button {
          showingNewChainSheet = true
        } label: {
          Label("Chain", systemImage: "link")
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("agents.newChain")

        Spacer()

        Button {
          showingSetupSheet = true
        } label: {
          Image(systemName: cliService.copilotStatus.isAvailable ? "checkmark.circle" : "gear")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("agents.cliSetup")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .navigationTitle("Agents")
    .onChange(of: selection) { _, newValue in
      handleSelection(newValue)
    }
    .onAppear {
      // Sync selection from manager on appear
      if let chain = agentManager.selectedChain {
        selection = "chain:\(chain.id.uuidString)"
      } else if let agent = agentManager.selectedAgent {
        selection = "agent:\(agent.id.uuidString)"
      } else if selectedInfrastructure == .vmIsolation {
        selection = "infra:vm-isolation:\(vmIsolationSection)"
      }
      refreshParallelWorktreeStatus()
      Task { await refreshWorktreeCount() }
    }
    .onChange(of: mcpServer.parallelWorktreeRunner?.runs.count ?? 0) { _, _ in
      refreshParallelWorktreeStatus()
    }
  }

  private func refreshParallelWorktreeStatus() {
    parallelWorktreeStatus = ParallelWorktreeSummary(runs: mcpServer.parallelWorktreeRunner?.runs ?? [])
  }

  private func refreshWorktreeCount() async {
    do {
      let allWorktrees = try await mcpServer.listAllWorktrees()
      worktreeCount = allWorktrees.count
    } catch {
      worktreeCount = 0
    }
  }

  private func handleSelection(_ value: String?) {
    guard let value else {
      agentManager.selectedAgent = nil
      agentManager.selectedChain = nil
      selectedInfrastructure = nil
      return
    }

    if value.hasPrefix("chain:") {
      selectedInfrastructure = nil
      let idStr = String(value.dropFirst(6))
      if let uuid = UUID(uuidString: idStr),
         let chain = agentManager.chains.first(where: { $0.id == uuid }) {
        agentManager.selectedAgent = nil
        agentManager.selectedChain = chain
      }
    } else if value.hasPrefix("agent:") {
      selectedInfrastructure = nil
      let idStr = String(value.dropFirst(6))
      if let uuid = UUID(uuidString: idStr),
         let agent = agentManager.agents.first(where: { $0.id == uuid }) {
        agentManager.selectedChain = nil
        agentManager.selectedAgent = agent
      }
    } else if value.hasPrefix("infra:") {
      agentManager.selectedAgent = nil
      agentManager.selectedChain = nil
      let key = String(value.dropFirst(6))
      if key.hasPrefix("vm-isolation") {
        selectedInfrastructure = .vmIsolation
        if let section = key.split(separator: ":").dropFirst().first {
          vmIsolationSection = String(section)
        }
      } else {
        selectedInfrastructure = InfrastructureView(rawValue: key)
      }
      if let controlId = infrastructureControlId(for: key) {
        mcpServer.recordUIActionHandled(controlId)
      }
    }
  }

  private func infrastructureControlId(for key: String) -> String? {
    switch key {
    case "mcp-dashboard": return "agents.mcpDashboard"
    case "template-gallery": return "agents.templateGallery"
    case "local-rag": return "agents.localRag"
    case "translation-validation": return "agents.translationValidation"
    case "vm-isolation", "vm-isolation:overview", "vm-isolation:linux", "vm-isolation:macos", "vm-isolation:pools":
      return "agents.vmIsolation"
    case "pii-scrubber": return "agents.piiScrubber"
    default: return nil
    }
  }

  @ViewBuilder
  private func sidebarToken(icon: String, color: Color, value: Int) -> some View {
    if value > 0 {
      HStack(spacing: 4) {
        Image(systemName: icon)
          .foregroundStyle(color)
        Text("\(value)")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func vmIsolationRow(title: String, icon: String, section: String) -> some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(.purple)
      Text(title)
      Spacer()
    }
    .accessibilityIdentifier("agents.vmIsolation")
    .tag("infra:vm-isolation:\(section)")
  }

  private var copilotStatusIcon: String {
    switch cliService.copilotStatus {
    case .available: return "checkmark.circle.fill"
    case .needsExtension: return "exclamationmark.circle.fill"
    case .notAuthenticated: return "exclamationmark.triangle.fill"
    case .checking: return "circle.dotted"
    default: return "xmark.circle"
    }
  }

  private var copilotStatusColor: Color {
    switch cliService.copilotStatus {
    case .available: return .green
    case .needsExtension: return .blue
    case .notAuthenticated: return .orange
    default: return .secondary
    }
  }

  private var copilotStatusLabel: String {
    switch cliService.copilotStatus {
    case .available: return "Ready"
    case .needsExtension: return "Needs extension"
    case .notAuthenticated: return "Needs auth"
    case .notInstalled: return "Not installed"
    case .checking: return "Checking..."
    case .error: return "Error"
    }
  }
}

private struct ParallelWorktreeSummary {
  let totalRuns: Int
  let pendingRuns: Int
  let activeRuns: Int
  let totalExecutions: Int
  let runningExecutions: Int
  let awaitingReviewExecutions: Int
  let rejectedExecutions: Int
  let readyToMergeExecutions: Int
  let failedExecutions: Int
  let hungExecutions: Int

  static let empty = ParallelWorktreeSummary(runs: [])

  init(runs: [ParallelWorktreeRun]) {
    totalRuns = runs.count
    pendingRuns = runs.filter { $0.status == .pending }.count
    activeRuns = runs.filter { run in
      switch run.status {
      case .running, .awaitingReview, .merging:
        return true
      default:
        return false
      }
    }.count
    totalExecutions = runs.reduce(0) { $0 + $1.executions.count }
    runningExecutions = runs.reduce(0) { total, run in
      total + run.executions.filter { execution in
        switch execution.status {
        case .running, .creatingWorktree:
          return true
        default:
          return false
        }
      }.count
    }
    awaitingReviewExecutions = runs.reduce(0) { $0 + $1.pendingReviewCount }
    rejectedExecutions = runs.reduce(0) { $0 + $1.rejectedCount }
    readyToMergeExecutions = runs.reduce(0) { $0 + $1.readyToMergeCount }
    failedExecutions = runs.reduce(0) { $0 + $1.failedCount }
    hungExecutions = runs.reduce(0) { $0 + $1.hungExecutionCount }
  }
}
