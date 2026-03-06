//
//  ActivityItemDetailSheet.swift
//  Peel
//
//  Detail sheet for any ActivityItem. Chain items route to ChainDetailView;
//  other types get a purpose-built summary panel.
//

import SwiftUI

// MARK: - Activity Item Detail Sheet

struct ActivityItemDetailSheet: View {
  let item: ActivityItem

  @Environment(MCPServerService.self) private var mcpServer
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          headerSection
          Divider()
          detailContent
        }
        .padding(20)
      }
      .navigationTitle("Activity Detail")
      #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      #endif
    }
    #if os(macOS)
    .frame(minWidth: 500, minHeight: 350)
    #endif
  }

  // MARK: - Header

  private var headerSection: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(tintColor.opacity(0.15))
          .frame(width: 48, height: 48)
        Image(systemName: item.kind.systemImage)
          .font(.title2)
          .foregroundStyle(tintColor)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .font(.title3)
          .fontWeight(.semibold)

        HStack(spacing: 8) {
          if let repoName = item.repoDisplayName {
            Label(repoName, systemImage: "folder")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(item.relativeTime)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }

      Spacer()
    }
  }

  // MARK: - Detail Content (per kind)

  @ViewBuilder
  private var detailContent: some View {
    switch item.kind {
    case .chainStarted(let chainId), .chainCompleted(let chainId, _):
      chainDetail(chainId: chainId)

    case .pullCompleted(let success):
      pullDetail(success: success)

    case .ragIndexed:
      ragDetail(type: "Index")

    case .ragAnalyzed:
      ragDetail(type: "Analysis")

    case .worktreeCreated(let worktreeId):
      worktreeDetail(worktreeId: worktreeId, created: true)

    case .worktreeCleaned(let worktreeId):
      worktreeDetail(worktreeId: worktreeId, created: false)

    case .prActivity(let prNumber):
      prDetail(prNumber: prNumber)

    case .swarmDispatched(let taskId):
      swarmDetail(taskId: taskId)

    case .info:
      infoDetail
    }
  }

  // MARK: - Chain Detail

  @ViewBuilder
  private func chainDetail(chainId: UUID) -> some View {
    if let chain = mcpServer.agentManager.chains.first(where: { $0.id == chainId }) {
      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          DetailRow(label: "Chain", value: chain.name)
          DetailRow(label: "Status", value: chain.state.displayName)

          if let prompt = chain.initialPrompt {
            DetailRow(label: "Prompt", value: prompt)
          }

          DetailRow(label: "Agents", value: "\(chain.agents.count)")

          if let workDir = chain.workingDirectory {
            DetailRow(label: "Working Directory", value: workDir)
          }

          if chain.results.count > 0 {
            DetailRow(label: "Results", value: "\(chain.results.count) result\(chain.results.count == 1 ? "" : "s")")
          }
        }
        .padding(4)
      }

      Text("Open the chain detail for full agent status, logs, and results.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      ContentUnavailableView {
        Label("Chain Not Found", systemImage: "questionmark.circle")
      } description: {
        Text("The chain (\(chainId.uuidString.prefix(8))…) may have been removed.")
      }
    }
  }

  // MARK: - Pull Detail

  private func pullDetail(success: Bool) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "Outcome", value: success ? "Pulled successfully" : "Pull failed")

        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        }

        if let repoName = item.repoDisplayName,
           let repo = aggregator.repositories.first(where: { $0.displayName == repoName }) {
          if let branch = repo.trackedBranch {
            DetailRow(label: "Branch", value: branch)
          }
          if let pullStatus = repo.pullStatus {
            DetailRow(label: "Current Pull Status", value: pullStatus.displayName)
          }
        }
      }
      .padding(4)
    }
  }

  // MARK: - RAG Detail

  private func ragDetail(type: String) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "Operation", value: "RAG \(type) Complete")

        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        }

        if let repoName = item.repoDisplayName {
          DetailRow(label: "Repository", value: repoName)
        }
      }
      .padding(4)
    }
  }

  // MARK: - Worktree Detail

  private func worktreeDetail(worktreeId: UUID, created: Bool) -> some View {
    let workspace = mcpServer.agentManager.workspaceManager.workspaces
      .first(where: { $0.id == worktreeId })

    return GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "Action", value: created ? "Worktree Created" : "Worktree Cleaned Up")

        if let workspace {
          DetailRow(label: "Branch", value: workspace.branch)
          DetailRow(label: "Status", value: workspace.status.displayName)
          DetailRow(label: "Path", value: workspace.path.path)

          if let agentId = workspace.assignedAgentId {
            DetailRow(label: "Assigned Chain", value: agentId.uuidString.prefix(8) + "…")
          }
        } else {
          if let subtitle = item.subtitle {
            DetailRow(label: "Details", value: subtitle)
          }
          Text("Worktree details not available (may have been cleaned up).")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(4)
    }
  }

  // MARK: - PR Detail

  @ViewBuilder
  private func prDetail(prNumber: Int) -> some View {
    let matchingRepo = item.repoDisplayName.flatMap { name in
      aggregator.repositories.first(where: { $0.displayName == name })
    }
    let pr = matchingRepo?.recentPRs.first(where: { $0.number == prNumber })

    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "PR", value: "#\(prNumber)")

        if let pr {
          DetailRow(label: "Title", value: pr.title)
          DetailRow(label: "State", value: pr.state.capitalized)
        }

        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        }
      }
      .padding(4)
    }

    if let pr, let urlString = pr.htmlURL, let url = URL(string: urlString) {
      Button {
        openURL(url)
      } label: {
        Label("Open in Browser", systemImage: "safari")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
  }

  // MARK: - Swarm Detail

  private func swarmDetail(taskId: String) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "Task ID", value: taskId)
        DetailRow(label: "Action", value: "Dispatched to swarm worker")

        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        }

        // Show connected workers count
        let workerCount = SwarmCoordinator.shared.connectedWorkers.count
        DetailRow(label: "Connected Workers", value: "\(workerCount)")
      }
      .padding(4)
    }
  }

  // MARK: - Info Detail

  private var infoDetail: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        } else {
          Text("No additional details available.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(4)
    }
  }

  // MARK: - Tint Color

  private var tintColor: Color {
    switch item.kind.tintColorName {
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

// MARK: - Detail Row

private struct DetailRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 120, alignment: .trailing)

      Text(value)
        .font(.callout)
        .textSelection(.enabled)

      Spacer()
    }
  }
}

// MARK: - Inline Detail View (for sidebar detail pane)

/// Non-sheet version of ActivityItemDetailSheet for use as a NavigationSplitView detail.
struct ActivityItemDetailView: View {
  let item: ActivityItem

  @Environment(MCPServerService.self) private var mcpServer
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(\.openURL) private var openURL

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        headerSection
        Divider()
        detailContent
      }
      .padding(20)
    }
    .navigationTitle("Activity Detail")
  }

  // Reuse the same layout as the sheet

  private var headerSection: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(tintColor.opacity(0.15))
          .frame(width: 48, height: 48)
        Image(systemName: item.kind.systemImage)
          .font(.title2)
          .foregroundStyle(tintColor)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .font(.title3)
          .fontWeight(.semibold)

        HStack(spacing: 8) {
          if let repoName = item.repoDisplayName {
            Label(repoName, systemImage: "folder")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(item.relativeTime)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }

      Spacer()
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    switch item.kind {
    case .chainStarted(let chainId), .chainCompleted(let chainId, _):
      chainDetail(chainId: chainId)
    case .pullCompleted(let success):
      pullDetail(success: success)
    case .ragIndexed:
      ragDetail(type: "Index")
    case .ragAnalyzed:
      ragDetail(type: "Analysis")
    case .worktreeCreated(let worktreeId):
      worktreeDetail(worktreeId: worktreeId, created: true)
    case .worktreeCleaned(let worktreeId):
      worktreeDetail(worktreeId: worktreeId, created: false)
    case .prActivity(let prNumber):
      prDetail(prNumber: prNumber)
    case .swarmDispatched(let taskId):
      swarmDetail(taskId: taskId)
    case .info:
      infoDetail
    }
  }

  @ViewBuilder
  private func chainDetail(chainId: UUID) -> some View {
    if let chain = mcpServer.agentManager.chains.first(where: { $0.id == chainId }) {
      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          DetailRow(label: "Chain", value: chain.name)
          DetailRow(label: "Status", value: chain.state.displayName)
          if let prompt = chain.initialPrompt {
            DetailRow(label: "Prompt", value: prompt)
          }
          DetailRow(label: "Agents", value: "\(chain.agents.count)")
          if let workDir = chain.workingDirectory {
            DetailRow(label: "Working Directory", value: workDir)
          }
        }
        .padding(4)
      }
    } else {
      ContentUnavailableView("Chain Not Found", systemImage: "questionmark.circle")
    }
  }

  private func pullDetail(success: Bool) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "Outcome", value: success ? "Pulled successfully" : "Pull failed")
        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        }
      }
      .padding(4)
    }
  }

  private func ragDetail(type: String) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "Operation", value: "RAG \(type) Complete")
        if let repoName = item.repoDisplayName {
          DetailRow(label: "Repository", value: repoName)
        }
      }
      .padding(4)
    }
  }

  private func worktreeDetail(worktreeId: UUID, created: Bool) -> some View {
    let workspace = mcpServer.agentManager.workspaceManager.workspaces
      .first(where: { $0.id == worktreeId })
    return GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "Action", value: created ? "Worktree Created" : "Worktree Cleaned Up")
        if let workspace {
          DetailRow(label: "Branch", value: workspace.branch)
          DetailRow(label: "Status", value: workspace.status.displayName)
        }
        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        }
      }
      .padding(4)
    }
  }

  @ViewBuilder
  private func prDetail(prNumber: Int) -> some View {
    let matchingRepo = item.repoDisplayName.flatMap { name in
      aggregator.repositories.first(where: { $0.displayName == name })
    }
    let pr = matchingRepo?.recentPRs.first(where: { $0.number == prNumber })
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "PR", value: "#\(prNumber)")
        if let pr {
          DetailRow(label: "Title", value: pr.title)
          DetailRow(label: "State", value: pr.state.capitalized)
        }
        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        }
      }
      .padding(4)
    }
    if let pr, let urlString = pr.htmlURL, let url = URL(string: urlString) {
      Button {
        openURL(url)
      } label: {
        Label("Open in Browser", systemImage: "safari")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
  }

  private func swarmDetail(taskId: String) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        DetailRow(label: "Task ID", value: taskId)
        DetailRow(label: "Action", value: "Dispatched to swarm worker")
        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        }
      }
      .padding(4)
    }
  }

  private var infoDetail: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        if let subtitle = item.subtitle {
          DetailRow(label: "Details", value: subtitle)
        } else {
          Text("No additional details available.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(4)
    }
  }

  private var tintColor: Color {
    switch item.kind.tintColorName {
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
