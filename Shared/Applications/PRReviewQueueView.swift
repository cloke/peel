//
//  PRReviewQueueView.swift
//  Peel
//
//  Activity dashboard section showing the persistent PR review queue.
//  Each row shows the PR, its current phase, and contextual actions.
//

import SwiftUI

// MARK: - Queue Section (for RepositoriesCommandCenter)

struct PRReviewQueueSection: View {
  @Environment(MCPServerService.self) private var mcpServer
  var onSelectPR: ((String, Int) -> Void)?
  var onSelectRun: ((ParallelWorktreeRun) -> Void)?

  @State private var showCompleted = false

  private var runManager: RunManager? { mcpServer.runManager }

  /// PR review runs from the same data source as Agent Runs / PR Reviews list.
  private var prRuns: [ParallelWorktreeRun] {
    guard let mgr = runManager else { return [] }
    return mgr.runs.filter { $0.kind == .prReview && $0.parentRunId == nil }
  }

  private var activeRuns: [ParallelWorktreeRun] {
    prRuns.filter {
      switch $0.status {
      case .completed, .cancelled, .failed: return false
      default: return true
      }
    }
    .sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
  }

  private var completedRuns: [ParallelWorktreeRun] {
    prRuns.filter {
      switch $0.status {
      case .completed, .cancelled, .failed: return true
      default: return false
      }
    }
    .sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
  }

  /// Historical snapshots for PR reviews (persisted across restarts).
  private var prSnapshots: [ParallelRunSnapshot] {
    guard let mgr = runManager else { return [] }
    let activeIds = Set(prRuns.map(\.id.uuidString))
    return mgr.historicalRuns
      .filter { $0.kind == RunKind.prReview.rawValue && !activeIds.contains($0.runId) }
  }

  var body: some View {
    let totalCompleted = completedRuns.count + prSnapshots.count

    VStack(alignment: .leading, spacing: 12) {
      SectionHeader("PR Reviews")

      if activeRuns.isEmpty && totalCompleted == 0 {
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

      if !activeRuns.isEmpty {
        LazyVStack(spacing: 1) {
          ForEach(activeRuns) { run in
            runRow(run)
          }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }

      if totalCompleted > 0 {
        DisclosureGroup(isExpanded: $showCompleted) {
          LazyVStack(spacing: 1) {
            ForEach(completedRuns.prefix(10)) { run in
              runRow(run)
            }
            ForEach(prSnapshots.prefix(max(0, 10 - completedRuns.count))) { snap in
              snapshotRow(snap)
            }
          }
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        } label: {
          HStack {
            Text("Completed")
            Spacer()
            Text("\(totalCompleted)")
              .font(.caption2)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.12), in: Capsule())
              .foregroundStyle(.secondary)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Row Views

  @ViewBuilder
  private func runRow(_ run: ParallelWorktreeRun) -> some View {
    let childCount = runManager?.childRuns(of: run.id).count ?? 0
    UnifiedRunRow(run: run, childCount: childCount)
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
      .onTapGesture {
        onSelectRun?(run)
      }
  }

  @ViewBuilder
  private func snapshotRow(_ snap: ParallelRunSnapshot) -> some View {
    ParallelRunSnapshotRow(snapshot: snap)
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
  }
}
