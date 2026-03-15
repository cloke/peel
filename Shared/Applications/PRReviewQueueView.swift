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
  var onSelectRun: ((ParallelWorktreeRun) -> Void)?

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
            PRReviewQueueRow(item: item, onSelectPR: onSelectPR, onSelectRun: onSelectRun)
          }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }

      if !completed.isEmpty {
        DisclosureGroup("Completed (\(completed.count))") {
          LazyVStack(spacing: 1) {
            ForEach(completed.prefix(10), id: \.id) { item in
              PRReviewQueueRow(item: item, onSelectPR: onSelectPR, onSelectRun: onSelectRun)
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
  var onSelectRun: ((ParallelWorktreeRun) -> Void)?
  @Environment(MCPServerService.self) private var mcpServer

  /// The associated run for this PR, if one exists.
  private var associatedRun: ParallelWorktreeRun? {
    mcpServer.parallelWorktreeRunner?.runs.first { run in
      run.kind == .prReview
        && run.prContext?.prNumber == item.prNumber
        && run.prContext?.repoName == item.repoName
    }
  }

  /// Parsed review data from stored reviewOutput.
  private var parsedReview: ParsedReview? {
    guard !item.reviewOutput.isEmpty else { return nil }
    let parsed = parseReviewOutput(item.reviewOutput)
    return parsed.hasStructuredContent ? parsed : nil
  }

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

        // Verdict + issue count (when review data exists)
        if let parsed = parsedReview {
          inlineReviewSummary(parsed)
        }

        // Chain progress indicator
        chainProgressIndicator

        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      // Inline verdict banner for reviewed items
      if let parsed = parsedReview {
        VStack(alignment: .leading, spacing: 6) {
          // Compact verdict banner
          HStack(spacing: 6) {
            Image(systemName: parsed.verdict.systemImage)
              .font(.caption)
              .foregroundStyle(parsed.verdict.color)
            Text(parsed.verdict.displayName)
              .font(.caption.weight(.semibold))
            if let reasoning = parsed.verdictReasoning, !reasoning.isEmpty {
              Text("— \(reasoning)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(parsed.riskLevel.capitalized)
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(riskColor(parsed.riskLevel).opacity(0.15), in: Capsule())
              .foregroundStyle(riskColor(parsed.riskLevel))
          }
          .padding(8)
          .background(parsed.verdict.color.opacity(0.06))
          .clipShape(RoundedRectangle(cornerRadius: 6))

          // Summary snippet
          if !parsed.summary.isEmpty {
            Text(parsed.summary)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      // Navigate to agent review detail if available, otherwise to PR detail
      if let run = associatedRun, !item.reviewOutput.isEmpty {
        onSelectRun?(run)
      } else {
        let ownerRepo = "\(item.repoOwner)/\(item.repoName)"
        onSelectPR?(ownerRepo, item.prNumber)
      }
    }
  }

  @ViewBuilder
  private func inlineReviewSummary(_ parsed: ParsedReview) -> some View {
    HStack(spacing: 4) {
      if !parsed.issues.isEmpty {
        Label("\(parsed.issues.count)", systemImage: "exclamationmark.triangle")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.orange)
      }
      if !parsed.suggestions.isEmpty {
        Label("\(parsed.suggestions.count)", systemImage: "lightbulb")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.blue)
      }
    }
  }

  private func riskColor(_ level: String) -> Color {
    switch level.lowercased() {
    case "high", "critical": return .red
    case "medium": return .orange
    case "low": return .green
    default: return .secondary
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
