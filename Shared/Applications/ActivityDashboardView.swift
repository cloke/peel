//
//  ActivityDashboardView.swift
//  Peel
//
//  Activity component views (cards, rows, filters) used by RepositoriesCommandCenter.
//  The ActivityDashboardView struct has been merged into RepositoriesCommandCenter.
//

import SwiftUI
import Github

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
  let statusColor: Color
  let statusText: String?

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Circle()
            .fill(isOnline ? statusColor : .red)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Main row — no @Observable environment access here to avoid
      // swift_getObjectType crashes during rapid SwiftUI layout passes.
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

      // Inline detail — deferred to a child view so @Observable
      // environment objects are only resolved when actually expanded.
      if isExpanded {
        Divider()
          .padding(.horizontal, 12)

        DashboardActivityRowDetail(item: item)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
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

// MARK: - Expanded Detail (own view to isolate @Observable access)

/// Separated into its own view so `MCPServerService` / `RepositoryAggregator`
/// are only pulled from the environment when the row is actually expanded.
/// This avoids @Observable tracking registrations on every body evaluation
/// of the collapsed row, which was causing a swift_getObjectType crash during
/// main-actor isolation checks in rapid SwiftUI layout passes.
private struct DashboardActivityRowDetail: View {
  let item: ActivityItem

  @Environment(MCPServerService.self) private var mcpServer
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(\.openURL) private var openURL

  var body: some View {
    inlineDetail
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

// MARK: - Activity PR Sheet

/// Full PR detail presented as a sheet from the Activity dashboard.
/// Mirrors the experience of selecting a PR in the Repositories section.
struct ActivityPRSheet: View {
  let ownerRepo: String
  let prNumber: Int

  private enum LoadState {
    case loading
    case loaded(pr: Github.PullRequest, repo: Github.Repository)
    case error(String)
  }

  @State private var state: LoadState = .loading
  @Environment(\.dismiss) private var dismiss

  #if os(macOS)
  @Environment(MCPServerService.self) private var mcpServer
  @State private var reviewAgentCoordinator = PRReviewAgentCoordinator()
  @State private var reviewTarget: AgentReviewTarget?
  @State private var reviewStatusBridge = PRReviewStatusBridge()
  #endif

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("PR #\(prNumber)")
        #if os(macOS)
        .navigationSubtitle(ownerRepo)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    #if os(macOS)
    .reviewWithAgentProvider(reviewAgentCoordinator)
    .prReviewStatusProvider(reviewStatusBridge)
    .sheet(item: $reviewTarget) { target in
      AgentReviewSheet(target: target)
    }
    .onAppear {
      reviewStatusBridge.queue = mcpServer.prReviewQueue
      reviewAgentCoordinator.onReview = { pr, repo in
        reviewTarget = PRReviewAgentCoordinator.makeTarget(pr: pr, repo: repo, localRepoPath: nil)
      }
    }
    #endif
    .task { await loadData() }
    .frame(minWidth: 700, minHeight: 500)
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .loading:
      VStack(spacing: 12) {
        ProgressView()
        Text("Loading PR #\(prNumber)\u{2026}")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .error(let message):
      ContentUnavailableView(
        "Failed to Load PR",
        systemImage: "exclamationmark.triangle",
        description: Text(message)
      )
    case .loaded(let pr, let repo):
      PullRequestDetailView(organization: nil, repository: repo, pullRequest: pr)
    }
  }

  private func loadData() async {
    let parts = ownerRepo.split(separator: "/")
    guard parts.count == 2 else {
      state = .error("Invalid repository: \(ownerRepo)")
      return
    }
    let owner = String(parts[0])
    let repoName = String(parts[1])

    do {
      async let repoTask = Github.repository(owner: owner, name: repoName)
      async let prTask = Github.pullRequest(
        owner: owner, repository: repoName, number: prNumber
      )
      let (repo, pr) = try await (repoTask, prTask)
      state = .loaded(pr: pr, repo: repo)
    } catch is CancellationError {
      return
    } catch {
      state = .error(error.localizedDescription)
    }
  }
}
