//
//  MCPDashboardView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import Charts
import SwiftData
import SwiftUI

struct MCPDashboardView: View {
  @Bindable var mcpServer: MCPServerService
  @Bindable var sessionTracker: SessionTracker
  @Query(sort: \MCPRunRecord.createdAt, order: .reverse) private var mcpRuns: [MCPRunRecord]
  @Query(sort: \MCPRunResultRecord.createdAt, order: .reverse) private var mcpRunResults: [MCPRunResultRecord]
  @State private var selectedRun: MCPRunRecord?
  @State private var showingCleanupConfirmation = false
  @State private var overrideReviewLoopEnabled = false
  @State private var overrideReviewLoopValue = false
  @State private var overridePauseOnReviewEnabled = false
  @State private var overridePauseOnReviewValue = false
  @State private var overrideAllowModelSelection = false
  @State private var overrideAllowScaling = false
  @State private var overrideMaxImplementersEnabled = false
  @State private var overrideMaxImplementers = 2
  @State private var overrideMaxPremiumEnabled = false
  @State private var overrideMaxPremiumCost = "1.0"
  @State private var overridePriority = 0
  @State private var overrideTimeoutEnabled = false
  @State private var overrideTimeoutSeconds = "600"
  @State private var latencySamples: [MCPDailyLatency] = []
  @State private var isLoadingLatency = false
  @State private var lastLatencyRefresh: Date?
  @State private var isLoadingRag = false
  @State private var usageGranularity: UsageGranularity = .day

  private enum UsageGranularity: String, CaseIterable {
    case day
    case week

    var label: String {
      switch self {
      case .day: return "Daily"
      case .week: return "Weekly"
      }
    }
  }

  private struct MCPRunUsageStat: Identifiable {
    let id = UUID()
    let bucketStart: Date
    let runCount: Int
    let averagePremiumCost: Double
  }

  private func buildOverrides() -> MCPServerService.RunOverrides {
    var overrides = MCPServerService.RunOverrides()
    if overrideReviewLoopEnabled {
      overrides.enableReviewLoop = overrideReviewLoopValue
    }
    if overridePauseOnReviewEnabled {
      overrides.pauseOnReview = overridePauseOnReviewValue
    }
    overrides.allowPlannerModelSelection = overrideAllowModelSelection
    overrides.allowPlannerImplementerScaling = overrideAllowScaling
    if overrideMaxImplementersEnabled {
      overrides.maxImplementers = max(1, overrideMaxImplementers)
    }
    if overrideMaxPremiumEnabled, let value = Double(overrideMaxPremiumCost) {
      overrides.maxPremiumCost = value
    }
    overrides.priority = overridePriority
    if overrideTimeoutEnabled, let value = Double(overrideTimeoutSeconds) {
      overrides.timeoutSeconds = value
    }
    return overrides
  }

  private func chainForRun(_ run: MCPServerService.ActiveRunInfo) -> AgentChain? {
    mcpServer.agentManager.chains.first { $0.id == run.chainId }
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
            let duration = Double(raw) else {
        continue
      }
      let day = calendar.startOfDay(for: entry.timestamp)
      durationsByDay[day, default: []].append(duration)
    }

    let samples = durationsByDay.keys.sorted().map { day in
      let values = durationsByDay[day] ?? []
      return MCPDailyLatency(
        day: day,
        medianMs: percentile(values, 0.5),
        p95Ms: percentile(values, 0.95)
      )
    }

    latencySamples = samples
    lastLatencyRefresh = Date()
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
      .mapValues { results in
        results.reduce(0.0) { $0 + $1.premiumCost }
      }

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

  private func percentile(_ values: [Double], _ percentile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let clamped = min(max(percentile, 0), 1)
    let rank = clamped * Double(sorted.count - 1)
    let lower = Int(floor(rank))
    let upper = Int(ceil(rank))
    if lower == upper {
      return sorted[lower]
    }
    let weight = rank - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
  }

  private func refreshRagSummary() async {
    isLoadingRag = true
    defer { isLoadingRag = false }
    await mcpServer.refreshRagSummary()
  }

  private func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox {
          HStack(spacing: 12) {
            Image(systemName: mcpServer.isRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
              .font(.title2)
              .foregroundStyle(mcpServer.isRunning ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text("MCP Server")
                .font(.headline)
              Text(mcpServer.isRunning ? "Running on localhost:\(mcpServer.port)" : "Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if mcpServer.activeRequests > 0 {
              Chip(
                text: "\(mcpServer.activeRequests) active",
                font: .caption,
                foreground: .blue,
                background: Color.blue.opacity(0.15),
                horizontalPadding: 8,
                verticalPadding: 4
              )
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text("Recent MCP Activity")
              .font(.headline)
            if let method = mcpServer.lastRequestMethod,
               let timestamp = mcpServer.lastRequestAt {
              Text("Last request: \(method)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
              Text("No MCP requests yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = mcpServer.lastError {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            }
            Text("Tools enabled: \(mcpServer.enabledToolCount)/\(mcpServer.totalToolCount)")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("Foreground tools: \(mcpServer.foregroundToolCount) · Background tools: \(mcpServer.backgroundToolCount)")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("App active: \(mcpServer.isAppActive ? "Yes" : "No") · Frontmost: \(mcpServer.isAppFrontmost ? "Yes" : "No")")
              .font(.caption)
              .foregroundStyle(.secondary)
            if let blocked = mcpServer.lastBlockedTool,
               let blockedAt = mcpServer.lastBlockedToolAt {
              Text("Last blocked tool: \(blocked)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(blockedAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let handled = mcpServer.lastUIActionHandled,
               let handledAt = mcpServer.lastUIActionHandledAt {
              Text("Last UI action: \(handled)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(handledAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let pending = mcpServer.lastUIAction?.controlId {
              Text("Pending UI action: \(pending)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let requiresForeground = mcpServer.lastToolRequiresForeground,
               let requiresForegroundAt = mcpServer.lastToolRequiresForegroundAt {
              Text("Last tool requires UI: \(requiresForeground ? "Yes" : "No")")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(requiresForegroundAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text("MCP UI Actions")
              .font(.headline)
            if mcpServer.recentUIActions.isEmpty {
              Text("No UI actions yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              ForEach(mcpServer.recentUIActions.prefix(8)) { action in
                HStack {
                  Text(action.controlId)
                    .font(.caption)
                  Spacer()
                  Text(action.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Text(action.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Local RAG")
                .font(.headline)
              Spacer()
              Button("Refresh") {
                Task { await refreshRagSummary() }
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("agents.mcpDashboard.rag.refresh")
            }
            if isLoadingRag {
              ProgressView()
                .scaleEffect(0.8)
            } else if let status = mcpServer.ragStatus {
              Text("DB: \(status.dbPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("Schema: v\(status.schemaVersion) · Embeddings: \(status.providerName)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("Extension loaded: \(status.extensionLoaded ? "Yes" : "No")")
                .font(.caption)
                .foregroundStyle(.secondary)
              if let lastInit = status.lastInitializedAt {
                Text("Last init: \(lastInit, style: .time)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              if let stats = mcpServer.ragStats {
                Text("Repos: \(stats.repoCount) · Files: \(stats.fileCount) · Chunks: \(stats.chunkCount)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text("Embeddings: \(stats.embeddingCount) · Cache: \(stats.cacheEmbeddingCount)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text("DB size: \(formatBytes(stats.dbSizeBytes))")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if let lastIndexedAt = stats.lastIndexedAt {
                  let repoLabel = stats.lastIndexedRepoPath ?? "(unknown repo)"
                  Text("Last index: \(repoLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Text(lastIndexedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              if let error = mcpServer.lastRagError {
                Text(error)
                  .font(.caption)
                  .foregroundStyle(.red)
              }
              if let lastRefresh = mcpServer.lastRagRefreshAt {
                Text("Updated \(lastRefresh, style: .time)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            } else {
              Text("No RAG data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("MCP Latency (Last 14 Days)")
                .font(.headline)
              Spacer()
              Button("Refresh") {
                Task { await loadLatencySamples() }
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("agents.mcpDashboard.latency.refresh")
            }
            if isLoadingLatency {
              ProgressView()
                .scaleEffect(0.8)
            } else if latencySamples.isEmpty {
              Text("No latency samples yet")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            if let lastLatencyRefresh {
              Text("Updated \(lastLatencyRefresh, style: .time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Agent Usage")
                .font(.headline)
              Spacer()
              Picker("Granularity", selection: $usageGranularity) {
                ForEach(UsageGranularity.allCases, id: \.self) { option in
                  Text(option.label).tag(option)
                }
              }
              .pickerStyle(.segmented)
              .frame(width: 180)
              .accessibilityIdentifier("agents.mcpDashboard.usage.granularity")
            }

            let stats = usageStats(granularity: usageGranularity)
            if stats.isEmpty {
              Text("No MCP run data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              Chart(stats) { stat in
                BarMark(
                  x: .value("Period", stat.bucketStart, unit: usageGranularity == .day ? .day : .weekOfYear),
                  y: .value("Runs", stat.runCount)
                )
                .foregroundStyle(Color.accentColor.opacity(0.6))
              }
              .frame(height: 140)

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
              .frame(height: 140)

              if let last = stats.last {
                Text("Latest avg cost: \(last.averagePremiumCost.premiumCostDisplay)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            Text("Run Overrides")
              .font(.headline)
            Toggle("Override review loop", isOn: $overrideReviewLoopEnabled)
              .accessibilityIdentifier("agents.mcpDashboard.overrides.reviewLoopOverride")
            if overrideReviewLoopEnabled {
              Toggle("Enable review loop", isOn: $overrideReviewLoopValue)
                .padding(.leading, 12)
                .accessibilityIdentifier("agents.mcpDashboard.overrides.reviewLoopEnable")
            }
            Toggle("Override review pause", isOn: $overridePauseOnReviewEnabled)
              .accessibilityIdentifier("agents.mcpDashboard.overrides.reviewPauseOverride")
            if overridePauseOnReviewEnabled {
              Toggle("Pause on review request", isOn: $overridePauseOnReviewValue)
                .padding(.leading, 12)
                .accessibilityIdentifier("agents.mcpDashboard.overrides.reviewPauseEnable")
            }
            Toggle("Allow planner model selection", isOn: $overrideAllowModelSelection)
              .accessibilityIdentifier("agents.mcpDashboard.overrides.allowModelSelection")
            Toggle("Allow planner implementer scaling", isOn: $overrideAllowScaling)
              .accessibilityIdentifier("agents.mcpDashboard.overrides.allowScaling")

            HStack {
              Toggle("Limit implementers", isOn: $overrideMaxImplementersEnabled)
                .accessibilityIdentifier("agents.mcpDashboard.overrides.limitImplementers")
              if overrideMaxImplementersEnabled {
                Stepper(value: $overrideMaxImplementers, in: 1...6) {
                  Text("Max: \(overrideMaxImplementers)")
                    .font(.caption)
                }
                .accessibilityIdentifier("agents.mcpDashboard.overrides.maxImplementers")
              }
            }

            HStack {
              Toggle("Cost cap", isOn: $overrideMaxPremiumEnabled)
                .accessibilityIdentifier("agents.mcpDashboard.overrides.costCap")
              if overrideMaxPremiumEnabled {
                TextField("Max premium", text: $overrideMaxPremiumCost)
                  .frame(width: 80)
                  .textFieldStyle(.roundedBorder)
                  .accessibilityIdentifier("agents.mcpDashboard.overrides.maxPremium")
              }
            }

            HStack {
              Text("Priority")
              Stepper(value: $overridePriority, in: -5...5) {
                Text("\(overridePriority)")
                  .font(.caption)
              }
              .accessibilityIdentifier("agents.mcpDashboard.overrides.priority")
            }

            HStack {
              Toggle("Timeout", isOn: $overrideTimeoutEnabled)
                .accessibilityIdentifier("agents.mcpDashboard.overrides.timeoutEnabled")
              if overrideTimeoutEnabled {
                TextField("Seconds", text: $overrideTimeoutSeconds)
                  .frame(width: 90)
                  .textFieldStyle(.roundedBorder)
                  .accessibilityIdentifier("agents.mcpDashboard.overrides.timeoutSeconds")
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text("Active MCP Runs")
              .font(.headline)
            if mcpServer.activeRuns.isEmpty {
              Text("No active MCP runs")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              ForEach(mcpServer.activeRuns) { run in
                let chain = chainForRun(run)
                VStack(alignment: .leading, spacing: 6) {
                  HStack {
                    Text(chain?.name ?? run.templateName)
                      .font(.subheadline)
                      .fontWeight(.medium)
                    Spacer()
                    if let state = chain?.state.displayName {
                      Text(state)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                  }
                  if let lastMessage = chain?.liveStatusMessages.last {
                    Text(lastMessage.message)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(2)
                  }
                  HStack(spacing: 8) {
                    Button("Pause") {
                      Task { await mcpServer.pauseRun(run.id) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("agents.mcpDashboard.activeRun.\(run.id.uuidString).pause")

                    Button("Resume") {
                      Task { await mcpServer.resumeRun(run.id) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("agents.mcpDashboard.activeRun.\(run.id.uuidString).resume")

                    Button("Step") {
                      Task { await mcpServer.stepRun(run.id) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("agents.mcpDashboard.activeRun.\(run.id.uuidString).step")

                    Button("Stop") {
                      Task { await mcpServer.stopRun(run.id) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityIdentifier("agents.mcpDashboard.activeRun.\(run.id.uuidString).stop")
                  }
                }
                .padding(.vertical, 4)
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text("Queue")
              .font(.headline)
            HStack(spacing: 12) {
              Stepper(value: $mcpServer.maxConcurrentChains, in: 1...8) {
                Text("Max concurrent: \(mcpServer.maxConcurrentChains)")
                  .font(.caption)
              }
              .accessibilityIdentifier("agents.mcpDashboard.queue.maxConcurrent")
              Stepper(value: $mcpServer.maxQueuedChains, in: 0...20) {
                Text("Max queued: \(mcpServer.maxQueuedChains)")
                  .font(.caption)
              }
              .accessibilityIdentifier("agents.mcpDashboard.queue.maxQueued")
            }
            if mcpServer.queuedRuns.isEmpty {
              Text("Queue empty")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              ForEach(mcpServer.queuedRuns) { queued in
                HStack {
                  Text("#\(queued.position)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Text(String(queued.id.uuidString.prefix(8)))
                    .font(.caption)
                  Text("Priority \(queued.priority)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Spacer()
                  Button("Cancel") {
                    Task { _ = await mcpServer.cancelQueuedRun(queued.id) }
                  }
                  .buttonStyle(.link)
                  .accessibilityIdentifier("agents.mcpDashboard.queue.\(queued.id.uuidString).cancel")
                }
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text("MCP Run History")
              .font(.headline)
            if mcpRuns.isEmpty {
              Text("No MCP runs yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              ForEach(mcpRuns.prefix(8)) { run in
                VStack(alignment: .leading, spacing: 4) {
                  HStack(spacing: 8) {
                    Image(systemName: run.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                      .foregroundStyle(run.success ? .green : .red)
                    Text(run.templateName)
                      .font(.subheadline)
                    if run.mergeConflictsCount > 0 {
                      Chip(
                        text: "\(run.mergeConflictsCount) conflicts",
                        font: .caption2,
                        foreground: .orange,
                        background: Color.orange.opacity(0.15),
                        horizontalPadding: 6,
                        verticalPadding: 2
                      )
                      .accessibilityIdentifier("agents.mcpDashboard.runHistory.\(run.id.uuidString).conflicts")
                    }
                    Spacer()
                    Text(run.createdAt, style: .time)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                  if let workingDirectory = run.workingDirectory, !workingDirectory.isEmpty {
                    Text(workingDirectory)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                  if let error = run.errorMessage, !error.isEmpty {
                    Text(error)
                      .font(.caption)
                      .foregroundStyle(.red)
                      .lineLimit(2)
                  }
                  HStack {
                    if !run.chainId.isEmpty {
                      Button("View details") {
                        selectedRun = run
                      }
                      .buttonStyle(.link)
                      .accessibilityIdentifier("agents.mcpDashboard.runHistory.\(run.id.uuidString).view")
                      Button("Rerun") {
                        Task { await mcpServer.rerun(run, overrides: buildOverrides()) }
                      }
                      .buttonStyle(.link)
                      .accessibilityIdentifier("agents.mcpDashboard.runHistory.\(run.id.uuidString).rerun")
                    } else {
                      Text("Details unavailable (legacy run)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                  }
                }
                .padding(.vertical, 4)
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text("Cleanup")
              .font(.headline)
            Text("Remove agent worktrees and their branches from MCP runs")
              .font(.caption)
              .foregroundStyle(.secondary)
            Button {
              showingCleanupConfirmation = true
            } label: {
              Label("Clean Agent Worktrees", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(mcpServer.isCleaningAgentWorkspaces)
            .accessibilityIdentifier("agents.mcpDashboard.cleanup.start")
            .confirmationDialog("Remove agent worktrees and branches?", isPresented: $showingCleanupConfirmation, titleVisibility: .visible) {
              Button("Confirm", role: .destructive) {
                Task {
                  await mcpServer.cleanupAgentWorkspaces()
                }
              }
              .accessibilityIdentifier("agents.mcpDashboard.cleanup.confirm")
              Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("agents.mcpDashboard.cleanup.cancel")
            } message: {
              Text("This will delete worktrees and branches created by the MCP run. This cannot be undone.")
            }

            if mcpServer.isCleaningAgentWorkspaces {
              Text("Cleaning worktrees...")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let summary = mcpServer.lastCleanupSummary {
              Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = mcpServer.lastCleanupError {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            }
            if let lastCleanupAt = mcpServer.lastCleanupAt {
              Text("Last cleanup: \(lastCleanupAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text("Session Activity")
              .font(.headline)
            Text("Chain runs this session: \(sessionTracker.chainRunHistory.count)")
              .font(.caption)
              .foregroundStyle(.secondary)
            if let latest = sessionTracker.chainRunHistory.last {
              Text("Last run: \(latest.chainName)")
                .font(.caption)
              Text(latest.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .padding()
    }
    .navigationTitle("MCP Activity")
    .sheet(item: $selectedRun) { run in
      MCPRunDetailView(run: run)
    }
    .task {
      await loadLatencySamples()
      await refreshRagSummary()
    }
  }
}

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

private extension MCPDashboardView {
  var latencySeriesPoints: [MCPLatencyPoint] {
    latencySamples.flatMap { sample in
      [
        MCPLatencyPoint(day: sample.day, value: sample.medianMs, metric: "Median"),
        MCPLatencyPoint(day: sample.day, value: sample.p95Ms, metric: "P95")
      ]
    }
  }
}
