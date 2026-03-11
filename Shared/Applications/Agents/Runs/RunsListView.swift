//
//  RunsListView.swift
//  Peel
//
//  Unified view of ALL runs — code changes, PR reviews, investigations, ideas.
//  Groups runs into status-based sections: Needs Review / Running / Ready to Merge /
//  Ideas & Paused / Pending / Completed (collapsible).
//

import SwiftUI

// MARK: - ViewModel

@MainActor
@Observable
final class RunsListViewModel {
  var selectedRunId: UUID?
  var filterKind: RunKind? = nil
  var sortOrder: SortOrder = .newestFirst
  var showCompletedSection = false
  var showOtherMachines = false

  enum SortOrder: String, CaseIterable {
    case priority        = "Priority"
    case newestFirst     = "Newest"
    case oldestFirst     = "Oldest"
    case recentlyUpdated = "Recently Updated"
  }

  func sorted(_ runs: [ParallelWorktreeRun]) -> [ParallelWorktreeRun] {
    switch sortOrder {
    case .priority:
      return runs.sorted { priorityScore($0) > priorityScore($1) }
    case .newestFirst, .recentlyUpdated:
      return runs.sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
    case .oldestFirst:
      return runs.sorted { ($0.lastUpdatedAt ?? .distantPast) < ($1.lastUpdatedAt ?? .distantPast) }
    }
  }

  func filtered(_ runs: [ParallelWorktreeRun]) -> [ParallelWorktreeRun] {
    guard let kind = filterKind else { return runs }
    return runs.filter { $0.kind == kind }
  }

  private func priorityScore(_ run: ParallelWorktreeRun) -> Int {
    switch run.status {
    case .awaitingReview: return 5
    case .running, .merging: return 4
    default:
      if run.readyToMergeCount > 0 { return 3 }
      if run.status == .pending { return 2 }
      return 0
    }
  }
}

// MARK: - Main View

struct RunsListView: View {
  var mcpServer: MCPServerService

  @State private var viewModel = RunsListViewModel()
  @State private var showingNewRunSheet = false
  @State private var selectedExecution: ParallelWorktreeExecution?

  private var runManager: RunManager? { mcpServer.runManager }
  private var runner: ParallelWorktreeRunner? { mcpServer.parallelWorktreeRunner }

  var body: some View {
    if let mgr = runManager {
      mainContent(mgr: mgr)
    } else {
      // Fallback to legacy dashboard if RunManager not initialized
      ParallelWorktreeDashboardView(mcpServer: mcpServer)
    }
  }

  // MARK: - Main Layout

  @ViewBuilder
  private func mainContent(mgr: RunManager) -> some View {
    HSplitView {
      VStack(spacing: 0) {
        listHeader(mgr: mgr)
        kindFilterBar
        Divider()
        runList(mgr: mgr)
      }
      .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)

      detailContent(mgr: mgr)
        .frame(minWidth: 400, maxWidth: .infinity)
    }
    .frame(minWidth: 700, idealWidth: 900)
    .navigationTitle("Runs")
    .sheet(isPresented: $showingNewRunSheet) {
      if let runner {
        NewParallelRunSheet(runner: runner) { run in
          viewModel.selectedRunId = run.id
        }
      }
    }
  }

  // MARK: - Header

  private func listHeader(mgr: RunManager) -> some View {
    HStack(spacing: 6) {
      Text("Runs")
        .font(.headline)
      Spacer()

      // Sort menu
      Menu {
        ForEach(RunsListViewModel.SortOrder.allCases, id: \.self) { order in
          Button {
            viewModel.sortOrder = order
          } label: {
            if viewModel.sortOrder == order {
              Label(order.rawValue, systemImage: "checkmark")
            } else {
              Text(order.rawValue)
            }
          }
        }
      } label: {
        Image(systemName: "arrow.up.arrow.down")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Sort order")

      // New run button
      Button {
        showingNewRunSheet = true
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier("runs.newRun")
      .help("New run")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - Kind Filter Bar

  private var kindFilterBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        FilterChip(title: "All", count: 0, isSelected: viewModel.filterKind == nil) {
          viewModel.filterKind = nil
        }
        ForEach(RunKind.allCases, id: \.self) { kind in
          FilterChip(title: kind.displayLabel, count: 0, isSelected: viewModel.filterKind == kind) {
            viewModel.filterKind = kind
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
    }
  }

  // MARK: - Run List

  @ViewBuilder
  private func runList(mgr: RunManager) -> some View {
    let all = viewModel.filtered(mgr.runs)

    let needsReview = viewModel.sorted(all.filter { $0.status == .awaitingReview })
    let running     = viewModel.sorted(all.filter { $0.status == .running || $0.status == .merging })
    let ready       = viewModel.sorted(all.filter { $0.readyToMergeCount > 0 && $0.status != .awaitingReview })
    let ideas       = viewModel.sorted(all.filter { $0.kind == .investigation && $0.isPaused })
    let pending     = viewModel.sorted(all.filter {
      $0.status == .pending && !($0.kind == .investigation && $0.isPaused)
    })
    let completed   = viewModel.sorted(all.filter {
      switch $0.status {
      case .completed, .cancelled, .failed: return true
      default: return false
      }
    })

    let history = filteredSnapshots(deduplicatedHistory(mgr: mgr))
    let localHistory = history.filter { FileManager.default.fileExists(atPath: $0.projectPath) }
    let otherHistory = history.filter { !FileManager.default.fileExists(atPath: $0.projectPath) }

    let isEmpty = all.isEmpty && history.isEmpty

    if isEmpty {
      ContentUnavailableView {
        Label("No Runs", systemImage: "arrow.triangle.branch")
      } description: {
        Text(viewModel.filterKind == nil
          ? "Runs from MCP chains and parallel tasks appear here."
          : "No \(viewModel.filterKind!.displayLabel.lowercased()) runs.")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(16)
    } else {
      List(selection: $viewModel.selectedRunId) {

        if !needsReview.isEmpty {
          Section {
            ForEach(needsReview) { run in
              UnifiedRunRow(run: run).tag(run.id)
            }
          } header: {
            HStack {
              Text("Needs Review")
              Spacer()
              Text("\(needsReview.count)")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
            }
          }
        }

        if !running.isEmpty {
          Section("Running") {
            ForEach(running) { run in
              UnifiedRunRow(run: run).tag(run.id)
            }
          }
        }

        if !ready.isEmpty {
          Section("Approved / Ready to Merge") {
            ForEach(ready) { run in
              UnifiedRunRow(run: run).tag(run.id)
            }
          }
        }

        if !ideas.isEmpty {
          Section("Ideas / Paused") {
            ForEach(ideas) { run in
              UnifiedRunRow(run: run).tag(run.id)
            }
          }
        }

        if !pending.isEmpty {
          Section("Pending") {
            ForEach(pending) { run in
              UnifiedRunRow(run: run).tag(run.id)
            }
          }
        }

        let completedTotal = completed.count + history.count
        if completedTotal > 0 {
          Section {
            DisclosureGroup(isExpanded: $viewModel.showCompletedSection) {
              ForEach(completed.prefix(20)) { run in
                UnifiedRunRow(run: run).tag(run.id)
              }
              if !localHistory.isEmpty {
                let remaining = max(0, 20 - completed.count)
                ForEach(localHistory.prefix(remaining)) { snap in
                  ParallelRunSnapshotRow(snapshot: snap).tag(snap.id)
                }
              }
              if !otherHistory.isEmpty {
                DisclosureGroup(isExpanded: $viewModel.showOtherMachines) {
                  ForEach(otherHistory.prefix(10)) { snap in
                    ParallelRunSnapshotRow(snapshot: snap, isLocal: false).tag(snap.id)
                  }
                } label: {
                  Label(
                    "Other Machines (\(otherHistory.count))",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark"
                  )
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
                }
              }
            } label: {
              HStack {
                Text("Completed")
                  .font(.subheadline)
                Spacer()
                Text("\(completedTotal)")
                  .font(.caption2)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.secondary.opacity(0.12), in: Capsule())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .onAppear {
        if viewModel.selectedRunId == nil {
          viewModel.selectedRunId = (needsReview.first ?? running.first ?? ready.first ?? pending.first)?.id
        }
      }
      .onChange(of: mgr.runs.map(\.id)) { _, newIds in
        guard let sel = viewModel.selectedRunId else { return }
        if !newIds.contains(sel) && !history.contains(where: { $0.id == sel }) {
          viewModel.selectedRunId = newIds.first
        }
      }
    }
  }

  // MARK: - Detail Panel

  @ViewBuilder
  private func detailContent(mgr: RunManager) -> some View {
    if let selectedId = viewModel.selectedRunId {
      if let run = mgr.findRun(id: selectedId) {
        RunDetailView(
          run: run,
          runManager: mgr,
          runner: mgr.worktreeRunner,
          selectedExecution: $selectedExecution
        )
      } else if let snap = mgr.historicalRuns.first(where: { $0.id == selectedId }),
                let runner = runner {
        ParallelRunSnapshotDetailView(snapshot: snap, runner: runner, selectedRunId: $viewModel.selectedRunId)
      } else {
        emptyDetail
      }
    } else {
      emptyDetail
    }
  }

  private var emptyDetail: some View {
    ContentUnavailableView {
      Label("Select a Run", systemImage: "square.stack.3d.up")
    } description: {
      Text("Select a run to view details and executions.")
    }
  }

  // MARK: - Helpers

  private func filteredSnapshots(_ snapshots: [ParallelRunSnapshot]) -> [ParallelRunSnapshot] {
    guard let kind = viewModel.filterKind else { return snapshots }
    return snapshots.filter { $0.kind == kind.rawValue }
  }

  private func deduplicatedHistory(mgr: RunManager) -> [ParallelRunSnapshot] {
    let activeIds = Set(mgr.runs.map(\.id.uuidString))
    var seen = Set<String>()
    return mgr.historicalRuns.filter { snap in
      guard !activeIds.contains(snap.runId) else { return false }
      return seen.insert(snap.runId).inserted
    }
  }
}

// MARK: - Unified Run Row

struct UnifiedRunRow: View {
  @Bindable var run: ParallelWorktreeRun

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        statusIcon
        kindBadge
        Text(run.name)
          .fontWeight(.medium)
          .lineLimit(1)
        Spacer()
        executionCountBadge
      }

      progressRow

      if run.pendingReviewCount > 0 {
        Text("\(run.pendingReviewCount) awaiting review")
          .font(.caption2).foregroundStyle(.orange)
      }
      if run.rejectedCount > 0 {
        Text("\(run.rejectedCount) rejected")
          .font(.caption2).foregroundStyle(.red)
      }
      if run.hungExecutionCount > 0 {
        Text("\(run.hungExecutionCount) possibly hung")
          .font(.caption2).foregroundStyle(.red)
      }

      // PR-specific subtitle
      if run.kind == .prReview, let pr = run.prContext {
        HStack(spacing: 4) {
          Text(verbatim: "\(pr.repoOwner)/\(pr.repoName) #\(pr.prNumber)")
            .font(.caption)
            .foregroundStyle(.secondary)
          phaseBadge(pr.phase)
        }
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch run.status {
    case .pending:
      Image(systemName: "clock").foregroundStyle(.secondary)
    case .running:
      ProgressView().controlSize(.small)
    case .awaitingReview:
      Image(systemName: "eye.circle.fill").foregroundStyle(.orange)
    case .merging:
      Image(systemName: "arrow.triangle.merge").foregroundStyle(.blue)
    case .completed:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case .cancelled:
      Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
    }
  }

  private var kindBadge: some View {
    Text(run.kind.shortLabel)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(run.kind.badgeColor.opacity(0.15), in: Capsule())
      .foregroundStyle(run.kind.badgeColor)
  }

  private var executionCountBadge: some View {
    Text("\(run.executions.count)")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private var progressRow: some View {
    HStack(spacing: 8) {
      ProgressView(value: run.progress)
        .progressViewStyle(.linear)
        .tint(progressColor)
        .frame(maxWidth: 100)

      Text(run.status.displayName)
        .font(.caption)
        .foregroundStyle(statusTextColor)
    }
  }

  private func phaseBadge(_ phase: String) -> some View {
    let color = phaseColor(for: phase)
    return Text(PRReviewPhase.displayName[phase] ?? phase)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color.opacity(0.1), in: Capsule())
      .foregroundStyle(color)
  }

  private func phaseColor(for phase: String) -> Color {
    switch PRReviewPhase.color[phase] ?? "secondary" {
    case "purple": return .purple
    case "blue":   return .blue
    case "orange": return .orange
    case "yellow": return .yellow
    case "green":  return .green
    case "red":    return .red
    default:       return .secondary
    }
  }

  private var progressColor: Color {
    switch run.status {
    case .completed:      return .green
    case .awaitingReview: return .orange
    case .cancelled:      return .secondary
    case .failed:         return .red
    default:              return .blue
    }
  }

  private var statusTextColor: Color {
    switch run.status {
    case .completed:      return .green
    case .awaitingReview: return .orange
    case .failed:         return .red
    case .cancelled:      return .secondary
    default:              return .primary
    }
  }
}

// MARK: - RunKind UI Extensions

extension RunKind {
  var displayLabel: String {
    switch self {
    case .codeChange:    return "Code"
    case .prReview:      return "PR Review"
    case .investigation: return "Research"
    case .custom:        return "Custom"
    }
  }

  var shortLabel: String {
    switch self {
    case .codeChange:    return "CODE"
    case .prReview:      return "PR"
    case .investigation: return "RES"
    case .custom:        return "CUST"
    }
  }

  var badgeColor: Color {
    switch self {
    case .codeChange:    return .blue
    case .prReview:      return .purple
    case .investigation: return .teal
    case .custom:        return .orange
    }
  }
}
