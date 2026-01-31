//
//  MCPDashboardView.swift
//  Peel
//
//  Redesigned for operations focus - what matters is running, queued, and history
//

import Charts
import PeelUI
import SwiftData
import SwiftUI

// MARK: - Main Dashboard View

struct MCPDashboardView: View {
  @Bindable var mcpServer: MCPServerService
  @Bindable var sessionTracker: SessionTracker
  @Query(sort: \MCPRunRecord.createdAt, order: .reverse) private var mcpRuns: [MCPRunRecord]
  @Query(sort: \MCPRunResultRecord.createdAt, order: .reverse) private var mcpRunResults: [MCPRunResultRecord]

  @State private var selectedRun: MCPRunRecord?
  @State private var showingSettings = false
  @State private var showingAnalytics = false
  @State private var expandedRunIds: Set<UUID> = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Server Status Bar (compact)
        serverStatusBar

        // Active Runs - The Hero Section
        if !mcpServer.activeRuns.isEmpty {
          activeRunsSection
        }

        // Queue (if any)
        if !mcpServer.queuedRuns.isEmpty {
          queueSection
        }

        // Empty State when nothing active
        if mcpServer.activeRuns.isEmpty && mcpServer.queuedRuns.isEmpty {
          emptyStateCard
        }

        // Run History
        historySection
      }
      .padding()
    }
    .navigationTitle("MCP")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          showingAnalytics = true
        } label: {
          Image(systemName: "chart.xyaxis.line")
        }
        .help("Analytics")

        Button {
          showingSettings = true
        } label: {
          Image(systemName: "gearshape")
        }
        .help("Settings & Overrides")
      }
    }
    .sheet(item: $selectedRun) { run in
      MCPRunDetailView(run: run)
    }
    .sheet(isPresented: $showingSettings) {
      MCPSettingsSheet(mcpServer: mcpServer)
    }
    .sheet(isPresented: $showingAnalytics) {
      MCPAnalyticsSheet(mcpServer: mcpServer, mcpRuns: mcpRuns, mcpRunResults: mcpRunResults)
    }
  }

  // MARK: - Server Status Bar

  private var serverStatusBar: some View {
    HStack(spacing: 12) {
      // Status indicator
      Circle()
        .fill(mcpServer.isRunning ? Color.green : Color.gray)
        .frame(width: 10, height: 10)
        .overlay {
          if mcpServer.activeRequests > 0 {
            Circle()
              .stroke(Color.green, lineWidth: 2)
              .frame(width: 16, height: 16)
              .opacity(0.6)
          }
        }

      VStack(alignment: .leading, spacing: 0) {
        Text(mcpServer.isRunning ? "MCP Server Running" : "MCP Server Stopped")
          .font(.subheadline.weight(.medium))
        if mcpServer.isRunning {
          Text("localhost:\(mcpServer.port)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      if mcpServer.activeRequests > 0 {
        HStack(spacing: 4) {
          ProgressView()
            .scaleEffect(0.6)
          Text("\(mcpServer.activeRequests) active")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      // Quick stats
      HStack(spacing: 16) {
        Label("\(mcpServer.enabledToolCount)", systemImage: "wrench.and.screwdriver")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("\(mcpServer.enabledToolCount) tools enabled")

        if let method = mcpServer.lastRequestMethod {
          Text(method)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Active Runs Section

  private var activeRunsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Active", systemImage: "bolt.fill")
          .font(.headline)
          .foregroundStyle(.primary)

        Spacer()

        Text("\(mcpServer.activeRuns.count) running")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ForEach(mcpServer.activeRuns) { run in
        ActiveRunCard(
          run: run,
          chain: chainForRun(run),
          mcpServer: mcpServer,
          isExpanded: expandedRunIds.contains(run.id),
          onToggleExpand: {
            withAnimation(.easeInOut(duration: 0.2)) {
              if expandedRunIds.contains(run.id) {
                expandedRunIds.remove(run.id)
              } else {
                expandedRunIds.insert(run.id)
              }
            }
          }
        )
      }
    }
  }

  // MARK: - Queue Section

  private var queueSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Queue", systemImage: "list.number")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)

        Spacer()

        Text("\(mcpServer.queuedRuns.count) waiting")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      ForEach(mcpServer.queuedRuns) { queued in
        HStack(spacing: 12) {
          Text("#\(queued.position)")
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .frame(width: 24)

          Text(String(queued.id.uuidString.prefix(8)))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

          if queued.priority != 0 {
            Chip(
              text: "P\(queued.priority)",
              font: .caption2,
              foreground: queued.priority > 0 ? .orange : .secondary,
              background: (queued.priority > 0 ? Color.orange : Color.gray).opacity(0.15),
              horizontalPadding: 6,
              verticalPadding: 2
            )
          }

          Spacer()

          Button("Cancel") {
            Task { _ = await mcpServer.cancelQueuedRun(queued.id) }
          }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(.red.opacity(0.8))
        }
        .padding(.vertical, 4)
      }
    }
    .padding(12)
    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - Empty State

  private var emptyStateCard: some View {
    VStack(spacing: 16) {
      Image(systemName: "bolt.horizontal.circle")
        .font(.system(size: 48))
        .foregroundStyle(.tertiary)

      Text("No Active Runs")
        .font(.headline)
        .foregroundStyle(.secondary)

      Text("Start a chain from the Templates or use the MCP API")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
    .background(Color.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - History Section

  private var historySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("History", systemImage: "clock")
          .font(.headline)
          .foregroundStyle(.primary)

        Spacer()

        if !mcpRuns.isEmpty {
          Text("\(mcpRuns.count) runs")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if mcpRuns.isEmpty {
        Text("No run history yet")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 20)
      } else {
        LazyVStack(spacing: 8) {
          ForEach(mcpRuns.prefix(20)) { run in
            HistoryRunCard(run: run, onSelect: { selectedRun = run }, onRerun: {
              Task { await mcpServer.rerun(run, overrides: MCPServerService.RunOverrides()) }
            })
          }
        }
      }
    }
  }

  // MARK: - Helpers

  private func chainForRun(_ run: MCPServerService.ActiveRunInfo) -> AgentChain? {
    mcpServer.agentManager.chains.first { $0.id == run.chainId }
  }
}

// MARK: - Active Run Card

private struct ActiveRunCard: View {
  let run: MCPServerService.ActiveRunInfo
  let chain: AgentChain?
  let mcpServer: MCPServerService
  let isExpanded: Bool
  let onToggleExpand: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header - always visible
      HStack(spacing: 12) {
        // State indicator
        stateIndicator

        VStack(alignment: .leading, spacing: 2) {
          Text(chain?.name ?? run.templateName)
            .font(.subheadline.weight(.semibold))

          if let lastMessage = chain?.liveStatusMessages.last {
            Text(lastMessage.message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()

        // Expand/collapse
        Button {
          onToggleExpand()
        } label: {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
      .padding(12)
      .contentShape(Rectangle())
      .onTapGesture { onToggleExpand() }

      // Expanded content
      if isExpanded {
        Divider()
          .padding(.horizontal, 12)

        VStack(alignment: .leading, spacing: 12) {
          // Progress info
          if let chain = chain {
            HStack(spacing: 16) {
              // Agent progress
              VStack(alignment: .leading, spacing: 2) {
                Text("Agent")
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                Text("\(chain.currentAgentIndex + 1)/\(chain.agents.count)")
                  .font(.caption.monospaced())
              }

              // Elapsed time
              if let startTime = chain.runStartTime {
                VStack(alignment: .leading, spacing: 2) {
                  Text("Elapsed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                  Text(formatDuration(Date().timeIntervalSince(startTime)))
                    .font(.caption.monospaced())
                }
              }

              // Review iteration
              if chain.enableReviewLoop && chain.currentReviewIteration > 0 {
                VStack(alignment: .leading, spacing: 2) {
                  Text("Review")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                  Text("Iteration \(chain.currentReviewIteration)")
                    .font(.caption.monospaced())
                }
              }
            }
          }

          // Control buttons
          HStack(spacing: 8) {
            Button {
              Task { await mcpServer.pauseRun(run.id) }
            } label: {
              Label("Pause", systemImage: "pause.fill")
            }
            .buttonStyle(.bordered)

            Button {
              Task { await mcpServer.resumeRun(run.id) }
            } label: {
              Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)

            Button {
              Task { await mcpServer.stepRun(run.id) }
            } label: {
              Label("Step", systemImage: "forward.frame.fill")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
              Task { await mcpServer.stopRun(run.id) }
            } label: {
              Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
          }
        }
        .padding(12)
      }
    }
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(borderColor, lineWidth: 1)
    )
  }

  private var stateIndicator: some View {
    Group {
      if let chain = chain {
        switch chain.state {
        case .running:
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 20, height: 20)
        case .idle:
          Image(systemName: "pause.circle.fill")
            .foregroundStyle(.orange)
        case .reviewing:
          Image(systemName: "eye.circle.fill")
            .foregroundStyle(.purple)
        case .complete:
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        case .failed:
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.red)
        }
      } else {
        ProgressView()
          .scaleEffect(0.7)
          .frame(width: 20, height: 20)
      }
    }
  }

  private var cardBackground: Color {
    if let chain = chain {
      switch chain.state {
      case .running: return Color.blue.opacity(0.05)
      case .idle: return Color.orange.opacity(0.05)
      case .reviewing: return Color.purple.opacity(0.05)
      case .complete, .failed: return Color.secondary.opacity(0.03)
      }
    }
    return Color.blue.opacity(0.05)
  }

  private var borderColor: Color {
    if let chain = chain {
      switch chain.state {
      case .running: return Color.blue.opacity(0.2)
      case .idle: return Color.orange.opacity(0.2)
      case .reviewing: return Color.purple.opacity(0.2)
      case .complete, .failed: return Color.secondary.opacity(0.1)
      }
    }
    return Color.blue.opacity(0.2)
  }

  private func formatDuration(_ seconds: TimeInterval) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
  }
}

// MARK: - History Run Card

private struct HistoryRunCard: View {
  let run: MCPRunRecord
  let onSelect: () -> Void
  let onRerun: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      // Status icon
      Image(systemName: run.success ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(run.success ? .green : .red)
        .font(.title3)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(run.templateName)
            .font(.subheadline.weight(.medium))

          if run.mergeConflictsCount > 0 {
            Chip(
              text: "\(run.mergeConflictsCount) conflicts",
              font: .caption2,
              foreground: .orange,
              background: Color.orange.opacity(0.15),
              horizontalPadding: 6,
              verticalPadding: 2
            )
          }
        }

        if let error = run.errorMessage, !error.isEmpty {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(1)
        } else if let dir = run.workingDirectory {
          Text(dir.components(separatedBy: "/").suffix(2).joined(separator: "/"))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        Text(run.createdAt, style: .time)
          .font(.caption)
          .foregroundStyle(.secondary)

        Text(run.createdAt, style: .date)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      // Actions
      Menu {
        Button("View Details", systemImage: "eye") { onSelect() }
        Button("Rerun", systemImage: "arrow.clockwise") { onRerun() }
      } label: {
        Image(systemName: "ellipsis.circle")
          .foregroundStyle(.secondary)
      }
      .menuStyle(.borderlessButton)
    }
    .padding(12)
    .background(Color.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
  }
}

// MARK: - Settings Sheet

private struct MCPSettingsSheet: View {
  @Bindable var mcpServer: MCPServerService
  @Environment(\.dismiss) private var dismiss

  @State private var overrideReviewLoopEnabled = false
  @State private var overrideReviewLoopValue = false
  @State private var overridePauseOnReviewEnabled = false
  @State private var overridePauseOnReviewValue = false
  @State private var overrideAllowModelSelection = true
  @State private var overrideAllowImplementerModelOverride = true
  @State private var overrideAllowScaling = true
  @State private var overrideMaxImplementersEnabled = false
  @State private var overrideMaxImplementers = 2
  @State private var overrideMaxPremiumEnabled = false
  @State private var overrideMaxPremiumCost = "1.0"
  @State private var overridePriority = 0
  @State private var overrideTimeoutEnabled = false
  @State private var overrideTimeoutSeconds = "600"
  @State private var showingCleanupConfirmation = false
  @State private var showingClearHistoryConfirmation = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Queue Limits") {
          Stepper("Max concurrent: \(mcpServer.maxConcurrentChains)", value: $mcpServer.maxConcurrentChains, in: 1...8)
          Stepper("Max queued: \(mcpServer.maxQueuedChains)", value: $mcpServer.maxQueuedChains, in: 0...20)
        }

        Section("Review Controls") {
          Toggle("Override review loop", isOn: $overrideReviewLoopEnabled)
          if overrideReviewLoopEnabled {
            Toggle("Enable review loop", isOn: $overrideReviewLoopValue)
              .padding(.leading)
          }
          Toggle("Override review pause", isOn: $overridePauseOnReviewEnabled)
          if overridePauseOnReviewEnabled {
            Toggle("Pause on review request", isOn: $overridePauseOnReviewValue)
              .padding(.leading)
          }
        }

        Section("Planner Controls") {
          Toggle("Allow planner model selection", isOn: $overrideAllowModelSelection)
          Toggle("Allow implementer model override", isOn: $overrideAllowImplementerModelOverride)
          Toggle("Allow planner implementer scaling", isOn: $overrideAllowScaling)
        }

        Section("Limits") {
          Toggle("Limit implementers", isOn: $overrideMaxImplementersEnabled)
          if overrideMaxImplementersEnabled {
            Stepper("Max: \(overrideMaxImplementers)", value: $overrideMaxImplementers, in: 1...6)
              .padding(.leading)
          }

          Toggle("Cost cap", isOn: $overrideMaxPremiumEnabled)
          if overrideMaxPremiumEnabled {
            HStack {
              Text("Max premium")
              TextField("1.0", text: $overrideMaxPremiumCost)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            }
            .padding(.leading)
          }
        }

        Section("Scheduling") {
          Stepper("Priority: \(overridePriority)", value: $overridePriority, in: -5...5)

          Toggle("Timeout", isOn: $overrideTimeoutEnabled)
          if overrideTimeoutEnabled {
            HStack {
              Text("Seconds")
              TextField("600", text: $overrideTimeoutSeconds)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            }
            .padding(.leading)
          }
        }

        Section("Cleanup") {
          Button("Clean Agent Worktrees", systemImage: "trash") {
            showingCleanupConfirmation = true
          }
          .disabled(mcpServer.isCleaningAgentWorkspaces)

          if mcpServer.isCleaningAgentWorkspaces {
            Text("Cleaning worktrees...")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if let summary = mcpServer.lastCleanupSummary {
            Text(summary)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Button("Clear Run History", systemImage: "trash.slash", role: .destructive) {
            showingClearHistoryConfirmation = true
          }
        }

        Section("Debug Info") {
          LabeledContent("Tools", value: "\(mcpServer.enabledToolCount)/\(mcpServer.totalToolCount)")
          LabeledContent("Foreground tools", value: "\(mcpServer.foregroundToolCount)")
          LabeledContent("Background tools", value: "\(mcpServer.backgroundToolCount)")
          LabeledContent("App active", value: mcpServer.isAppActive ? "Yes" : "No")
          LabeledContent("App frontmost", value: mcpServer.isAppFrontmost ? "Yes" : "No")

          if let error = mcpServer.lastError {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("MCP Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .confirmationDialog("Clean Agent Worktrees?", isPresented: $showingCleanupConfirmation) {
        Button("Clean", role: .destructive) {
          Task { await mcpServer.cleanupAgentWorkspaces() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will delete worktrees and branches created by MCP runs.")
      }
      .confirmationDialog("Clear Run History?", isPresented: $showingClearHistoryConfirmation) {
        Button("Clear", role: .destructive) {
          mcpServer.clearMCPRunHistory()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This deletes all stored MCP run records. This cannot be undone.")
      }
    }
    .frame(minWidth: 500, minHeight: 600)
  }
}

// MARK: - Analytics Sheet

private struct MCPAnalyticsSheet: View {
  let mcpServer: MCPServerService
  let mcpRuns: [MCPRunRecord]
  let mcpRunResults: [MCPRunResultRecord]
  @Environment(\.dismiss) private var dismiss

  @State private var usageGranularity: UsageGranularity = .day
  @State private var latencySamples: [MCPDailyLatency] = []
  @State private var isLoadingLatency = false

  private enum UsageGranularity: String, CaseIterable {
    case day, week
    var label: String { self == .day ? "Daily" : "Weekly" }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          // Usage Chart
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Run Activity")
                .font(.headline)
              Spacer()
              Picker("", selection: $usageGranularity) {
                ForEach(UsageGranularity.allCases, id: \.self) { Text($0.label).tag($0) }
              }
              .pickerStyle(.segmented)
              .frame(width: 140)
            }

            let stats = usageStats(granularity: usageGranularity)
            if stats.isEmpty {
              Text("No run data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else {
              Chart(stats) { stat in
                BarMark(
                  x: .value("Period", stat.bucketStart, unit: usageGranularity == .day ? .day : .weekOfYear),
                  y: .value("Runs", stat.runCount)
                )
                .foregroundStyle(Color.accentColor.gradient)
              }
              .frame(height: 160)

              Chart(stats) { stat in
                LineMark(
                  x: .value("Period", stat.bucketStart, unit: usageGranularity == .day ? .day : .weekOfYear),
                  y: .value("Avg Cost", stat.averagePremiumCost)
                )
                .foregroundStyle(.blue)
                PointMark(
                  x: .value("Period", stat.bucketStart, unit: usageGranularity == .day ? .day : .weekOfYear),
                  y: .value("Avg Cost", stat.averagePremiumCost)
                )
                .foregroundStyle(.blue)
              }
              .frame(height: 120)

              if let last = stats.last {
                Text("Latest avg cost: \(last.averagePremiumCost.premiumCostDisplay)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }

          Divider()

          // Latency Chart
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Latency (Last 14 Days)")
                .font(.headline)
              Spacer()
              Button("Refresh") {
                Task { await loadLatencySamples() }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }

            if isLoadingLatency {
              ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if latencySamples.isEmpty {
              Text("No latency data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else {
              Chart(latencySeriesPoints) { point in
                LineMark(
                  x: .value("Day", point.day, unit: .day),
                  y: .value("Latency (ms)", point.value)
                )
                .foregroundStyle(by: .value("Metric", point.metric))
              }
              .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2))
              }
              .frame(height: 160)
            }
          }

          Divider()

          // Summary Stats
          VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
              .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
              StatCard(title: "Total Runs", value: "\(mcpRuns.count)")
              StatCard(title: "Success Rate", value: successRate)
              StatCard(title: "This Week", value: "\(runsThisWeek)")
            }
          }
        }
        .padding()
      }
      .navigationTitle("Analytics")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task {
        await loadLatencySamples()
      }
    }
    .frame(minWidth: 600, minHeight: 500)
  }

  private var successRate: String {
    guard !mcpRuns.isEmpty else { return "—" }
    let successful = mcpRuns.filter(\.success).count
    let rate = Double(successful) / Double(mcpRuns.count) * 100
    return "\(Int(rate))%"
  }

  private var runsThisWeek: Int {
    let weekAgo = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: Date()) ?? Date()
    return mcpRuns.filter { $0.createdAt >= weekAgo }.count
  }

  private struct MCPRunUsageStat: Identifiable {
    let id = UUID()
    let bucketStart: Date
    let runCount: Int
    let averagePremiumCost: Double
  }

  private func usageStats(granularity: UsageGranularity) -> [MCPRunUsageStat] {
    let calendar = Calendar.current
    let cutoff: Date = {
      switch granularity {
      case .day:
        return calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date.distantPast
      case .week:
        return calendar.date(byAdding: .weekOfYear, value: -12, to: Date()) ?? Date.distantPast
      }
    }()

    let costsByChain = Dictionary(grouping: mcpRunResults, by: { $0.chainId })
      .mapValues { results in results.reduce(0.0) { $0 + $1.premiumCost } }

    var aggregates: [Date: (count: Int, totalCost: Double)] = [:]

    for run in mcpRuns where run.createdAt >= cutoff {
      let bucketStart: Date
      switch granularity {
      case .day:
        bucketStart = calendar.startOfDay(for: run.createdAt)
      case .week:
        bucketStart = calendar.dateInterval(of: .weekOfYear, for: run.createdAt)?.start
          ?? calendar.startOfDay(for: run.createdAt)
      }
      let runCost = costsByChain[run.chainId] ?? 0
      var entry = aggregates[bucketStart] ?? (0, 0)
      entry.count += 1
      entry.totalCost += runCost
      aggregates[bucketStart] = entry
    }

    return aggregates.keys.sorted().map { day in
      let entry = aggregates[day] ?? (0, 0)
      let averageCost = entry.count > 0 ? entry.totalCost / Double(entry.count) : 0
      return MCPRunUsageStat(bucketStart: day, runCount: entry.count, averagePremiumCost: averageCost)
    }
  }

  private func loadLatencySamples() async {
    isLoadingLatency = true
    defer { isLoadingLatency = false }
    let entries = await MCPLogService.shared.readEntries(limit: 2000)
    let calendar = Calendar.current
    let startDate = calendar.date(byAdding: .day, value: -14, to: Date()) ?? Date.distantPast
    var durationsByDay: [Date: [Double]] = [:]

    for entry in entries where entry.message == "RPC complete" {
      guard entry.timestamp >= startDate,
            let raw = entry.metadata["durationMs"],
            let duration = Double(raw) else { continue }
      let day = calendar.startOfDay(for: entry.timestamp)
      durationsByDay[day, default: []].append(duration)
    }

    latencySamples = durationsByDay.keys.sorted().map { day in
      let values = durationsByDay[day] ?? []
      return MCPDailyLatency(day: day, medianMs: percentile(values, 0.5), p95Ms: percentile(values, 0.95))
    }
  }

  private func percentile(_ values: [Double], _ percentile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let clamped = min(max(percentile, 0), 1)
    let rank = clamped * Double(sorted.count - 1)
    let lower = Int(floor(rank))
    let upper = Int(ceil(rank))
    if lower == upper { return sorted[lower] }
    let weight = rank - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
  }

  private var latencySeriesPoints: [MCPLatencyPoint] {
    latencySamples.flatMap { sample in
      [
        MCPLatencyPoint(day: sample.day, value: sample.medianMs, metric: "Median"),
        MCPLatencyPoint(day: sample.day, value: sample.p95Ms, metric: "P95")
      ]
    }
  }
}

// MARK: - Supporting Types

private struct MCPDailyLatency: Identifiable {
  let id = UUID()
  let day: Date
  let medianMs: Double
  let p95Ms: Double
}

private struct MCPLatencyPoint: Identifiable {
  let id = UUID()
  let day: Date
  let value: Double
  let metric: String
}

private struct StatCard: View {
  let title: String
  let value: String

  var body: some View {
    VStack(spacing: 4) {
      Text(value)
        .font(.title2.weight(.semibold))
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
  }
}
