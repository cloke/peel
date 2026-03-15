//
//  ReviewDashboardView.swift
//  Peel
//
//  Unified review dashboard showing all pending reviews across agent worktrees
//  and PRs with filtering, confidence scores, and keyboard navigation.
//

import SwiftUI

struct ReviewDashboardView: View {
  var mcpServer: MCPServerService

  @State private var filter: ReviewFilter = .all
  @State private var sortOrder: ReviewSortOrder = .newest
  @State private var selectedItemId: UUID?
  @State private var searchText = ""

  private var runner: ParallelWorktreeRunner? { mcpServer.parallelWorktreeRunner }

  var body: some View {
    HSplitView {
      // Left: filter bar + list
      VStack(spacing: 0) {
        headerBar
        Divider()

        if filteredItems.isEmpty {
          emptyState
        } else {
          reviewList
        }
      }
      .frame(minWidth: 320, idealWidth: 400)

      // Right: detail pane
      if let selected = selectedItemId, let (execution, run) = resolveExecution(selected) {
        ExecutionDetailView(
          execution: execution,
          run: run,
          runner: runner!,
          onDismiss: { selectedItemId = nil }
        )
      } else {
        VStack(spacing: 12) {
          Image(systemName: "sidebar.right")
            .font(.system(size: 36))
            .foregroundStyle(.secondary)
          Text("Select a review to see details")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle("Review Dashboard")
    .frame(minWidth: 600)
    .searchable(text: $searchText, prompt: "Filter reviews…")
  }

  // MARK: - Header

  private var headerBar: some View {
    HStack(spacing: 12) {
      // Filter pills
      ForEach(ReviewFilter.allCases, id: \.self) { filterOption in
        let count = itemCount(for: filterOption)
        Button {
          filter = filterOption
        } label: {
          HStack(spacing: 4) {
            Text(filterOption.label)
            if count > 0 {
              Text("\(count)")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                  filter == filterOption
                    ? Color.white.opacity(0.3)
                    : Color.secondary.opacity(0.15),
                  in: Capsule()
                )
            }
          }
          .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(filter == filterOption ? .accentColor : .secondary)
        .controlSize(.small)
      }

      Spacer()

      // Sort
      Picker("Sort", selection: $sortOrder) {
        ForEach(ReviewSortOrder.allCases, id: \.self) { order in
          Text(order.label).tag(order)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 140)
      .controlSize(.small)

      // Stats
      statsLabel
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  // MARK: - Review List

  private var reviewList: some View {
    List(selection: $selectedItemId) {
      ForEach(filteredItems) { item in
        ReviewDashboardRow(item: item, runner: runner)
          .tag(item.id)
      }
    }
    .listStyle(.inset(alternatesRowBackgrounds: true))
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.seal")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
      Text("No pending reviews")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text("Agent executions awaiting review will appear here.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Stats

  private var statsLabel: some View {
    let pending = itemCount(for: .pending)
    let approved = itemCount(for: .approved)
    let total = allItems.count
    return Text("\(pending) pending · \(approved) approved · \(total) total")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  // MARK: - Data

  private var allItems: [ReviewItem] {
    guard let runner else { return [] }
    var items: [ReviewItem] = []

    for run in runner.runs {
      for execution in run.executions {
        // Prefer PR review output over raw execution output
        let reviewOutput = run.prContext?.reviewOutput ?? ""
        let output = !reviewOutput.isEmpty ? reviewOutput : execution.output
        let item = ReviewItem(
          id: execution.id,
          runId: run.id,
          runName: run.name,
          title: execution.task.title,
          description: execution.task.description,
          status: mapStatus(execution.status),
          branch: execution.branchName ?? "",
          createdAt: execution.startedAt ?? execution.lastStatusChangeAt,
          reviewRecords: execution.reviewRecords,
          chainStepResults: execution.chainStepResults,
          diffSummary: execution.diffSummary,
          output: output
        )
        items.append(item)
      }
    }

    return items
  }

  private var filteredItems: [ReviewItem] {
    var items = allItems

    // Filter
    switch filter {
    case .all: break
    case .pending:
      items = items.filter { $0.status == .awaitingReview }
    case .approved:
      items = items.filter { $0.status == .approved }
    case .rejected:
      items = items.filter { $0.status == .rejected }
    case .readyToMerge:
      items = items.filter { $0.status == .readyToMerge }
    }

    // Search
    if !searchText.isEmpty {
      let query = searchText.lowercased()
      items = items.filter {
        $0.title.lowercased().contains(query) ||
        $0.runName.lowercased().contains(query) ||
        $0.branch.lowercased().contains(query)
      }
    }

    // Sort
    switch sortOrder {
    case .newest:
      items.sort { $0.createdAt > $1.createdAt }
    case .oldest:
      items.sort { $0.createdAt < $1.createdAt }
    case .byRun:
      items.sort { $0.runName < $1.runName }
    }

    return items
  }

  private func itemCount(for filterOption: ReviewFilter) -> Int {
    switch filterOption {
    case .all: return allItems.count
    case .pending: return allItems.filter { $0.status == .awaitingReview }.count
    case .approved: return allItems.filter { $0.status == .approved }.count
    case .rejected: return allItems.filter { $0.status == .rejected }.count
    case .readyToMerge: return allItems.filter { $0.status == .readyToMerge }.count
    }
  }

  /// Resolve a selected item ID back to the live execution and its parent run.
  private func resolveExecution(_ executionId: UUID) -> (ParallelWorktreeExecution, ParallelWorktreeRun)? {
    guard let runner else { return nil }
    for run in runner.runs {
      if let execution = run.executions.first(where: { $0.id == executionId }) {
        return (execution, run)
      }
    }
    return nil
  }

  private func mapStatus(_ status: ParallelWorktreeStatus) -> ReviewItemStatus {
    switch status {
    case .awaitingReview: return .awaitingReview
    case .approved: return .approved
    case .rejected: return .rejected
    case .merged: return .merged
    case .conflicted: return .conflicted
    default: return .other
    }
  }
}

// MARK: - Review Item Model

struct ReviewItem: Identifiable {
  let id: UUID
  let runId: UUID
  let runName: String
  let title: String
  let description: String
  let status: ReviewItemStatus
  let branch: String
  let createdAt: Date
  let reviewRecords: [ParallelWorktreeExecution.ReviewRecord]
  let chainStepResults: [ParallelWorktreeExecution.ChainStepSummary]
  let diffSummary: String?
  let output: String

  var confidence: Double? {
    guard let verdictStr = chainStepResults.compactMap({ $0.reviewVerdict }).last else { return nil }
    let lowered = verdictStr.lowercased()
    if lowered.contains("approve") { return 0.9 }
    if lowered.contains("needs_changes") { return 0.5 }
    if lowered.contains("reject") { return 0.2 }
    return nil
  }

  var isReadyToMerge: Bool {
    status == .approved || status == .readyToMerge
  }

  /// Parsed agent review output, nil if no structured content.
  var parsedReview: ParsedReview? {
    guard !output.isEmpty else { return nil }
    let parsed = parseReviewOutput(output)
    return parsed.hasStructuredContent ? parsed : nil
  }
}

enum ReviewItemStatus: String {
  case awaitingReview
  case approved
  case rejected
  case merged
  case conflicted
  case readyToMerge
  case other

  var label: String {
    switch self {
    case .awaitingReview: "Pending"
    case .approved: "Approved"
    case .rejected: "Rejected"
    case .merged: "Merged"
    case .conflicted: "Conflicted"
    case .readyToMerge: "Ready"
    case .other: "Other"
    }
  }

  var icon: String {
    switch self {
    case .awaitingReview: "eye.circle"
    case .approved: "checkmark.circle.fill"
    case .rejected: "xmark.circle.fill"
    case .merged: "arrow.triangle.merge"
    case .conflicted: "exclamationmark.triangle.fill"
    case .readyToMerge: "arrow.right.circle.fill"
    case .other: "circle"
    }
  }

  var color: Color {
    switch self {
    case .awaitingReview: .orange
    case .approved: .green
    case .rejected: .red
    case .merged: .purple
    case .conflicted: .yellow
    case .readyToMerge: .blue
    case .other: .secondary
    }
  }
}

// MARK: - Filters & Sort

enum ReviewFilter: String, CaseIterable {
  case all, pending, approved, rejected, readyToMerge

  var label: String {
    switch self {
    case .all: "All"
    case .pending: "Pending"
    case .approved: "Approved"
    case .rejected: "Rejected"
    case .readyToMerge: "Ready to Merge"
    }
  }
}

enum ReviewSortOrder: String, CaseIterable {
  case newest, oldest, byRun

  var label: String {
    switch self {
    case .newest: "Newest First"
    case .oldest: "Oldest First"
    case .byRun: "By Run"
    }
  }
}

// MARK: - Row View

struct ReviewDashboardRow: View {
  let item: ReviewItem
  let runner: ParallelWorktreeRunner?

  @State private var showRejectDialog = false
  @State private var rejectReason = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Title row
      HStack(spacing: 8) {
        Image(systemName: item.status.icon)
          .foregroundStyle(item.status.color)
          .font(.caption)

        Text(item.title)
          .font(.body)
          .fontWeight(.medium)
          .lineLimit(1)

        Spacer()

        if let confidence = item.confidence {
          confidenceBadge(confidence)
        }

        Text(item.status.label)
          .font(.caption2)
          .fontWeight(.medium)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(item.status.color.opacity(0.15), in: Capsule())
          .foregroundStyle(item.status.color)
      }

      // Metadata row
      HStack(spacing: 12) {
        Label(item.runName, systemImage: "square.stack.3d.up")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        if !item.branch.isEmpty {
          Label(item.branch, systemImage: "arrow.triangle.branch")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer()

        Text(item.createdAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      // Structured agent review (when available)
      if let parsed = item.parsedReview {
        ReviewOutputView(parsed: parsed, compact: true, showRawOutput: false, showStepLog: false)
      } else if let diff = item.diffSummary, !diff.isEmpty {
        // Diff summary fallback
        Text(diff)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      // Action buttons
      if item.status == .awaitingReview {
        HStack(spacing: 8) {
          Button {
            approveItem()
          } label: {
            Label("Approve", systemImage: "checkmark")
          }
          .buttonStyle(.borderedProminent)
          .tint(.green)
          .controlSize(.mini)

          Button {
            approveAndMergeItem()
          } label: {
            Label("Approve & Merge", systemImage: "checkmark.seal")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.mini)

          Button {
            showRejectDialog = true
          } label: {
            Label("Reject", systemImage: "xmark")
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)

          Spacer()
        }
        .padding(.top, 2)
      }
    }
    .padding(.vertical, 4)
    .alert("Reject Execution", isPresented: $showRejectDialog) {
      TextField("Reason", text: $rejectReason)
      Button("Cancel", role: .cancel) {}
      Button("Reject", role: .destructive) {
        rejectItem()
        rejectReason = ""
      }
    }
  }

  private func confidenceBadge(_ confidence: Double) -> some View {
    let percentage = Int(confidence * 100)
    let color: Color = confidence >= 0.85 ? .green : confidence >= 0.6 ? .orange : .red
    return Text("\(percentage)%")
      .font(.caption2)
      .fontWeight(.bold)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  private func approveItem() {
    guard let runner else { return }
    for run in runner.runs where run.id == item.runId {
      if let execution = run.executions.first(where: { $0.id == item.id }) {
        runner.approveExecution(execution, in: run)
      }
    }
  }

  private func approveAndMergeItem() {
    guard let runner else { return }
    for run in runner.runs where run.id == item.runId {
      if let execution = run.executions.first(where: { $0.id == item.id }) {
        Task { try? await runner.approveAndMergeExecution(execution, in: run) }
      }
    }
  }

  private func rejectItem() {
    guard let runner else { return }
    for run in runner.runs where run.id == item.runId {
      if let execution = run.executions.first(where: { $0.id == item.id }) {
        runner.rejectExecution(execution, in: run, reason: rejectReason)
      }
    }
  }
}
