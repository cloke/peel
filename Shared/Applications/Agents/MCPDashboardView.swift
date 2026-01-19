//
//  MCPDashboardView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftData
import SwiftUI

struct MCPDashboardView: View {
  @Bindable var mcpServer: MCPServerService
  @Bindable var sessionTracker: SessionTracker
  @Query(sort: \MCPRunRecord.createdAt, order: .reverse) private var mcpRuns: [MCPRunRecord]
  @State private var selectedRun: MCPRunRecord?
  @State private var showingCleanupConfirmation = false
  @State private var overrideReviewLoopEnabled = false
  @State private var overrideReviewLoopValue = false
  @State private var overrideAllowModelSelection = false
  @State private var overrideAllowScaling = false
  @State private var overrideMaxImplementersEnabled = false
  @State private var overrideMaxImplementers = 2
  @State private var overrideMaxPremiumEnabled = false
  @State private var overrideMaxPremiumCost = "1.0"
  @State private var overridePriority = 0
  @State private var overrideTimeoutEnabled = false
  @State private var overrideTimeoutSeconds = "600"

  private func buildOverrides() -> MCPServerService.RunOverrides {
    var overrides = MCPServerService.RunOverrides()
    if overrideReviewLoopEnabled {
      overrides.enableReviewLoop = overrideReviewLoopValue
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
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            Text("Run Overrides")
              .font(.headline)
            Toggle("Override review loop", isOn: $overrideReviewLoopEnabled)
            if overrideReviewLoopEnabled {
              Toggle("Enable review loop", isOn: $overrideReviewLoopValue)
                .padding(.leading, 12)
            }
            Toggle("Allow planner model selection", isOn: $overrideAllowModelSelection)
            Toggle("Allow planner implementer scaling", isOn: $overrideAllowScaling)

            HStack {
              Toggle("Limit implementers", isOn: $overrideMaxImplementersEnabled)
              if overrideMaxImplementersEnabled {
                Stepper(value: $overrideMaxImplementers, in: 1...6) {
                  Text("Max: \(overrideMaxImplementers)")
                    .font(.caption)
                }
              }
            }

            HStack {
              Toggle("Cost cap", isOn: $overrideMaxPremiumEnabled)
              if overrideMaxPremiumEnabled {
                TextField("Max premium", text: $overrideMaxPremiumCost)
                  .frame(width: 80)
                  .textFieldStyle(.roundedBorder)
              }
            }

            HStack {
              Text("Priority")
              Stepper(value: $overridePriority, in: -5...5) {
                Text("\(overridePriority)")
                  .font(.caption)
              }
            }

            HStack {
              Toggle("Timeout", isOn: $overrideTimeoutEnabled)
              if overrideTimeoutEnabled {
                TextField("Seconds", text: $overrideTimeoutSeconds)
                  .frame(width: 90)
                  .textFieldStyle(.roundedBorder)
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

                    Button("Resume") {
                      Task { await mcpServer.resumeRun(run.id) }
                    }
                    .buttonStyle(.bordered)

                    Button("Step") {
                      Task { await mcpServer.stepRun(run.id) }
                    }
                    .buttonStyle(.bordered)

                    Button("Stop") {
                      Task { await mcpServer.stopRun(run.id) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
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
              Stepper(value: $mcpServer.maxQueuedChains, in: 0...20) {
                Text("Max queued: \(mcpServer.maxQueuedChains)")
                  .font(.caption)
              }
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
                      Button("Rerun") {
                        Task { await mcpServer.rerun(run, overrides: buildOverrides()) }
                      }
                      .buttonStyle(.link)
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
            .confirmationDialog("Remove agent worktrees and branches?", isPresented: $showingCleanupConfirmation, titleVisibility: .visible) {
              Button("Confirm", role: .destructive) {
                Task {
                  await mcpServer.cleanupAgentWorkspaces()
                }
              }
              Button("Cancel", role: .cancel) {}
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
  }
}
