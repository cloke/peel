//
//  PRReviewQueueView.swift
//  Peel
//
//  Activity dashboard section showing the persistent PR review queue.
//  Each row shows the PR, its current phase, and contextual actions.
//

import SwiftUI
import Github

// MARK: - Queue Section (for RepositoriesCommandCenter)

struct PRReviewQueueSection: View {
  @Environment(MCPServerService.self) private var mcpServer
  var onSelectPR: ((String, Int) -> Void)?

  private var queue: PRReviewQueue { mcpServer.prReviewQueue }

  var body: some View {
    let active = queue.activeItems
    let completed = queue.completedItems

    VStack(alignment: .leading, spacing: 12) {
      SectionHeader("PR Reviews")

      if active.isEmpty && completed.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "arrow.triangle.pull")
            .font(.largeTitle)
            .foregroundStyle(.tertiary)
          Text("No PR Reviews")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
          Text("Start a review from Agent Runs or via MCP.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
      }

      if !active.isEmpty {
        LazyVStack(spacing: 1) {
          ForEach(active, id: \.id) { item in
            PRReviewQueueRow(item: item, onSelectPR: onSelectPR)
          }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }

      if !completed.isEmpty {
        DisclosureGroup("Completed (\(completed.count))") {
          LazyVStack(spacing: 1) {
            ForEach(completed.prefix(10), id: \.id) { item in
              PRReviewQueueRow(item: item, onSelectPR: onSelectPR)
            }
          }
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Queue Row

struct PRReviewQueueRow: View {
  let item: PRReviewQueueItem
  var onSelectPR: ((String, Int) -> Void)?
  @Environment(MCPServerService.self) private var mcpServer

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Main row
      HStack(spacing: 10) {
        phaseIcon
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 2) {
          Text(item.prTitle)
            .font(.callout)
            .fontWeight(.medium)
            .lineLimit(1)

          HStack(spacing: 6) {
            Text(verbatim: "\(item.repoOwner)/\(item.repoName) #\(item.prNumber)")
              .font(.caption)
              .foregroundStyle(.secondary)

            phaseBadge
          }
        }

        Spacer()

        // Chain progress indicator
        chainProgressIndicator

        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .onTapGesture {
        let ownerRepo = "\(item.repoOwner)/\(item.repoName)"
        onSelectPR?(ownerRepo, item.prNumber)
      }
    }
  }

  // MARK: - Phase Icon

  @ViewBuilder
  private var phaseIcon: some View {
    let imageName = PRReviewPhase.systemImage[item.phase] ?? "questionmark.circle"
    Image(systemName: imageName)
      .font(.callout)
      .foregroundStyle(phaseColor)
  }

  private var phaseColor: Color {
    switch PRReviewPhase.color[item.phase] ?? "secondary" {
    case "purple": return .purple
    case "blue": return .blue
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "red": return .red
    default: return .secondary
    }
  }

  private var phaseBadge: some View {
    Text(PRReviewPhase.displayName[item.phase] ?? item.phase)
      .font(.caption2)
      .fontWeight(.medium)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(phaseColor.opacity(0.1)))
      .foregroundStyle(phaseColor)
  }

  // MARK: - Chain Progress

  @ViewBuilder
  private var chainProgressIndicator: some View {
    let activeChainId = item.phase == PRReviewPhase.fixing ? item.fixChainId : item.reviewChainId
    if !activeChainId.isEmpty, let chain = findChain(activeChainId) {
      switch chain.state {
      case .running:
        ProgressView()
          .controlSize(.small)
      case .complete:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.caption)
      case .failed:
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.red)
          .font(.caption)
      default:
        EmptyView()
      }
    }
  }

  // MARK: - Helpers

  private func findChain(_ chainId: String) -> AgentChain? {
    guard !chainId.isEmpty, let uuid = UUID(uuidString: chainId) else { return nil }
    return mcpServer.agentManager.chains.first { $0.id == uuid }
  }

}
