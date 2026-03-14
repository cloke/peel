//
//  ParallelWorktreeDashboardView.swift
//  Peel
//
//  Created on 1/21/26.
//

import SwiftUI

struct ParallelWorktreeDashboardView: View {
  var mcpServer: MCPServerService
  @AppStorage("current-tool") private var currentTool: CurrentTool = .agents
  
  private var runner: ParallelWorktreeRunner? {
    mcpServer.parallelWorktreeRunner
  }
  
  @State private var selectedRunId: UUID?
  @State private var selectedExecution: ParallelWorktreeExecution?
  @State private var showingNewRunSheet = false
  @State private var expandedExecutions: Set<UUID> = []
  @State private var showOtherMachines = false
  
  var body: some View {
    if let runner {
      mainContent(runner: runner)
    } else {
      ContentUnavailableView(
        "Runner Not Available",
        systemImage: "exclamationmark.triangle",
        description: Text("Parallel worktree runner is not initialized")
      )
    }
  }
  
  @ViewBuilder
  private func mainContent(runner: ParallelWorktreeRunner) -> some View {
    HSplitView {
      // Left: Run list
      VStack(spacing: 0) {
        runListHeader
        Divider()
        runList(runner: runner)
      }
      .frame(minWidth: 180, idealWidth: 260, maxWidth: 320)
      
      // Right: Detail
      detailContent(runner: runner)
        .frame(minWidth: 300, maxWidth: .infinity)
    }
    .frame(minWidth: 500, idealWidth: 900)
    .navigationTitle("Agent Runs")
    .sheet(isPresented: $showingNewRunSheet) {
      NewParallelRunSheet(runner: runner) { run in
        selectedRunId = run.id
      }
    }
  }
  
  private var runListHeader: some View {
    HStack {
      Text("Runs")
        .font(.headline)
      Spacer()
      Button("Workspaces") {
        currentTool = .workspaces
      }
      .buttonStyle(.bordered)
      Button {
        showingNewRunSheet = true
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier("parallelRuns.newRun")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
  
  @ViewBuilder
  private func runList(runner: ParallelWorktreeRunner) -> some View {
    let history = deduplicatedHistory(runner: runner)
    let hasActive = !runner.runs.isEmpty
    let hasHistory = !history.isEmpty

    if !hasActive && !hasHistory {
      VStack(alignment: .leading, spacing: 12) {
        ContentUnavailableView {
          Label("No Parallel Runs", systemImage: "arrow.triangle.branch")
        } description: {
          Text("Create a parallel run to execute tasks in isolated worktrees (repo checkouts).")
        }

        Button("New Parallel Run") {
          showingNewRunSheet = true
        }
        .buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(16)
    } else {
      List(selection: $selectedRunId) {
        if hasActive {
          if hasHistory {
            Section("Active") {
              ForEach(runner.runs) { run in
                ParallelRunRow(run: run)
                  .tag(run.id)
              }
            }
          } else {
            ForEach(runner.runs) { run in
              ParallelRunRow(run: run)
                .tag(run.id)
            }
          }
        }
        if hasHistory {
          let localHistory = history.filter { FileManager.default.fileExists(atPath: $0.projectPath) }
          let otherHistory = history.filter { !FileManager.default.fileExists(atPath: $0.projectPath) }

          if !localHistory.isEmpty {
            Section("History") {
              ForEach(localHistory) { snapshot in
                ParallelRunSnapshotRow(snapshot: snapshot)
                  .tag(snapshot.id)
              }
            }
          }
          if !otherHistory.isEmpty {
            Section {
              DisclosureGroup(isExpanded: $showOtherMachines) {
                ForEach(otherHistory) { snapshot in
                  ParallelRunSnapshotRow(snapshot: snapshot, isLocal: false)
                    .tag(snapshot.id)
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
          }
        }
      }
      .listStyle(.plain)
      .onAppear {
        if selectedRunId == nil {
          selectedRunId = runner.runs.first?.id
        }
      }
      .onChange(of: runner.runs.map(\.id)) { _, newIds in
        if let selectedRunId, newIds.contains(selectedRunId) { return }
        // Don't clobber a historical snapshot selection
        if let selectedRunId, history.contains(where: { $0.id == selectedRunId }) { return }
        selectedRunId = newIds.first
      }
    }
  }

  /// Returns one snapshot per runId (most recent), excluding currently active runs.
  private func deduplicatedHistory(runner: ParallelWorktreeRunner) -> [ParallelRunSnapshot] {
    let activeIds = Set(runner.runs.map(\.id.uuidString))
    var seen = Set<String>()
    return runner.historicalRuns.filter { snap in
      guard !activeIds.contains(snap.runId) else { return false }
      return seen.insert(snap.runId).inserted
    }
  }
  
  @ViewBuilder
  private func detailContent(runner: ParallelWorktreeRunner) -> some View {
    if let selectedRunId {
      if let run = runner.runs.first(where: { $0.id == selectedRunId }) {
        ParallelRunDetailView(
          run: run,
          runner: runner,
          selectedExecution: $selectedExecution,
          expandedExecutions: $expandedExecutions
        )
      } else if let snapshot = runner.historicalRuns.first(where: { $0.id == selectedRunId }) {
        ParallelRunSnapshotDetailView(snapshot: snapshot, runner: runner, selectedRunId: $selectedRunId)
      } else {
        emptyDetailView
      }
    } else {
      emptyDetailView
    }
  }

  private var emptyDetailView: some View {
    ContentUnavailableView {
      Label("Select a Run", systemImage: "square.stack.3d.up")
    } description: {
      Text("Select a parallel run from the sidebar to view details.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(24)
  }
}

// MARK: - Run Row

struct ParallelRunRow: View {
  @Bindable var run: ParallelWorktreeRun
  
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        statusIcon
        Text(run.name)
          .fontWeight(.medium)
        Spacer()
        Text("\(run.executions.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      HStack(spacing: 8) {
        ProgressView(value: progressValue)
          .progressViewStyle(.linear)
          .tint(progressColor)
          .frame(maxWidth: 100)
        
        Text(run.status.displayName(kind: run.kind, prContext: run.prContext))
          .font(.caption)
          .foregroundStyle(statusTextColor)
      }
      
      if run.pendingReviewCount > 0 {
        Text("\(run.pendingReviewCount) awaiting review")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
      if run.rejectedCount > 0 {
        Text("\(run.rejectedCount) rejected")
          .font(.caption2)
          .foregroundStyle(.red)
      }
      if run.hungExecutionCount > 0 {
        Text("\(run.hungExecutionCount) possibly hung")
          .font(.caption2)
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, 4)
  }
  
  private var progressValue: Double {
    switch run.status {
    case .cancelled, .failed:
      // Show how far we got before cancellation/failure
      return run.progress
    default:
      return run.progress
    }
  }
  
  private var progressColor: Color {
    switch run.status {
    case .completed: return .green
    case .cancelled: return .secondary
    case .failed: return .red
    case .awaitingReview: return .orange
    default: return .blue
    }
  }
  
  private var statusTextColor: Color {
    switch run.status {
    case .completed: return .green
    case .cancelled: return .secondary
    case .failed: return .red
    case .awaitingReview: return .orange
    default: return .secondary
    }
  }
  
  @ViewBuilder
  private var statusIcon: some View {
    switch run.status {
    case .pending:
      Image(systemName: "clock")
        .foregroundStyle(.secondary)
    case .running:
      ProgressView()
        .scaleEffect(0.6)
        .frame(width: 16, height: 16)
    case .awaitingReview:
      Image(systemName: "eye.circle.fill")
        .foregroundStyle(.orange)
    case .merging:
      Image(systemName: "arrow.triangle.merge")
        .foregroundStyle(.blue)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
    case .cancelled:
      Image(systemName: "slash.circle.fill")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Run Detail View

struct ParallelRunDetailView: View {
  @Bindable var run: ParallelWorktreeRun
  let runner: ParallelWorktreeRunner
  @Binding var selectedExecution: ParallelWorktreeExecution?
  @Binding var expandedExecutions: Set<UUID>
  @State private var showingCancelConfirmation = false
  @State private var mergeError: String?
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Header
        runHeader
        
        Divider()
        
        // Progress Overview
        progressOverview
        
        Divider()
        
        // Actions
        actionButtons
        
        Divider()
        
        // Executions List
        executionsList
      }
      .padding()
    }
    .navigationTitle(run.name)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if run.status == .pending {
          Button("Start") {
            Task {
              try? await runner.startRun(run)
            }
          }
          .accessibilityIdentifier("parallelRun.start")
        }
        
        if run.status == .running || run.status == .awaitingReview {
          Button("Cancel", role: .destructive) {
            showingCancelConfirmation = true
          }
          .accessibilityIdentifier("parallelRun.cancel")
        }
      }
    }
    .confirmationDialog("Cancel Run?", isPresented: $showingCancelConfirmation) {
      Button("Cancel Run", role: .destructive) {
        Task {
          await runner.cancelRun(run)
        }
      }
    } message: {
      Text("This will cancel all pending tasks and cleanup worktrees.")
    }
  }
  
  @ViewBuilder
  private var runHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack {
          VStack(alignment: .leading) {
            Text("Project")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(run.projectPath)
              .font(.system(.body, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
          }
          
          Spacer()
          
          VStack(alignment: .trailing) {
            Text("Base Branch")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(run.baseBranch)
              .font(.system(.body, design: .monospaced))
          }
        }
        
        VStack(alignment: .leading, spacing: 8) {
          VStack(alignment: .leading) {
            Text("Project")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(run.projectPath)
              .font(.system(.body, design: .monospaced))
              .lineLimit(2)
              .truncationMode(.middle)
          }
          VStack(alignment: .leading) {
            Text("Base Branch")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(run.baseBranch)
              .font(.system(.body, design: .monospaced))
          }
        }
      }
      
      ViewThatFits(in: .horizontal) {
        HStack {
          VStack(alignment: .leading) {
            Text("Created")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(run.createdAt, style: .relative)
          }
          
          Spacer()
          
          VStack(alignment: .trailing) {
            Text("Status")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(run.status.displayName(kind: run.kind, prContext: run.prContext))
              .fontWeight(.medium)
          }
        }
        
        VStack(alignment: .leading, spacing: 8) {
          VStack(alignment: .leading) {
            Text("Created")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(run.createdAt, style: .relative)
          }
          VStack(alignment: .leading) {
            Text("Status")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(run.status.displayName(kind: run.kind, prContext: run.prContext))
              .fontWeight(.medium)
          }
        }
      }
    }
  }
  
  @ViewBuilder
  private var progressOverview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Progress")
        .font(.headline)
      
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 12) {
        statBox(title: "Total", value: "\(run.executions.count)", color: .primary)
        statBox(title: "Running", value: "\(run.activeCount)", color: .primary)
        statBox(title: "Pending Review", value: "\(run.pendingReviewCount)", color: .orange)
        statBox(title: "Reviewed", value: "\(run.reviewedCount)", color: .purple)
        statBox(title: "Ready to Merge", value: "\(run.readyToMergeCount)", color: .green)
        statBox(title: "Merged", value: "\(run.mergedCount)", color: .blue)
        statBox(title: "Rejected", value: "\(run.rejectedCount)", color: .red)
        statBox(title: "Failed", value: "\(run.failedCount)", color: .red)
        statBox(title: "Hung", value: "\(run.hungExecutionCount)", color: .red)
      }
      
      ProgressView(value: run.progress)
        .progressViewStyle(.linear)
    }
  }
  
  @ViewBuilder
  private func statBox(title: String, value: String, color: Color) -> some View {
    VStack(spacing: 4) {
      Text(value)
        .font(.title2.bold())
        .foregroundStyle(color)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(minWidth: 80)
  }
  
  @ViewBuilder
  private var actionButtons: some View {
    HStack(spacing: 12) {
      if run.pendingReviewCount > 0 {
        Button {
          runner.approveAllPending(in: run)
        } label: {
          Label("Approve All", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("parallelRun.approveAll")
      }
      
      if run.readyToMergeCount > 0 {
        Button {
          mergeError = nil
          Task {
            do {
              try await runner.mergeAllApproved(in: run)
            } catch {
              mergeError = error.localizedDescription
            }
          }
        } label: {
          Label("Merge All Ready", systemImage: "arrow.triangle.merge")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("parallelRun.mergeAll")
      }
      
      if let mergeError {
        Label(mergeError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(3)
      }
      
      Spacer()
      
      Toggle("Review Gate", isOn: Binding(
        get: { run.requireReviewGate },
        set: { run.requireReviewGate = $0 }
      ))
      .toggleStyle(.switch)
      .accessibilityIdentifier("parallelRun.reviewGate")
      
      Toggle("Auto-Merge", isOn: Binding(
        get: { run.autoMergeOnApproval },
        set: { run.autoMergeOnApproval = $0 }
      ))
      .toggleStyle(.switch)
      .accessibilityIdentifier("parallelRun.autoMerge")
    }
  }
  
  @ViewBuilder
  private var executionsList: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Executions")
        .font(.headline)
      
      ForEach(run.executions) { execution in
        ExecutionCard(
          execution: execution,
          run: run,
          runner: runner,
          isExpanded: expandedExecutions.contains(execution.id),
          onToggleExpand: {
            if expandedExecutions.contains(execution.id) {
              expandedExecutions.remove(execution.id)
            } else {
              expandedExecutions.insert(execution.id)
            }
          }
        )
      }
    }
  }
}

// MARK: - Execution Card

struct ExecutionCard: View {
  @Bindable var execution: ParallelWorktreeExecution
  let run: ParallelWorktreeRun
  let runner: ParallelWorktreeRunner
  let isExpanded: Bool
  let onToggleExpand: () -> Void
  @State private var rejectReason = ""
  @State private var showingRejectDialog = false
  @State private var assignedRejectReason = ""
  @State private var showingAssignedRejectDialog = false
  @State private var showingConflictResolution = false
  
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      Button(action: onToggleExpand) {
        HStack {
          statusIcon
          
          VStack(alignment: .leading) {
            Text(execution.task.title)
              .fontWeight(.medium)
            Text(execution.status.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          
          Spacer()
          
          if let duration = execution.duration {
            Text(formatDuration(duration))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .foregroundStyle(.secondary)
        }
        .padding()
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      
      if isExpanded {
        Divider()
        
        VStack(alignment: .leading, spacing: 12) {
          // Task Description
          if !execution.task.description.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("Description")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(execution.task.description)
                .font(.callout)
            }
          }

          // Agent Output
          if !execution.output.isEmpty {
            ReviewOutputView(parsed: parseReviewOutput(execution.output), compact: true)
          }
          
          // RAG Snippets
          if !execution.ragSnippets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("RAG Context (\(execution.ragSnippets.count) snippets)")
                .font(.caption)
                .foregroundStyle(.secondary)
              
              ForEach(execution.ragSnippets.prefix(3)) { snippet in
                HStack {
                  Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                  Text(snippet.filePath)
                    .font(.caption.monospaced())
                  Text("L\(snippet.startLine)-\(snippet.endLine)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
          
          // Worktree Info
          if let path = execution.worktreePath {
            VStack(alignment: .leading, spacing: 4) {
              Text("Worktree")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
          
          // Diff Stats
          if execution.filesChanged > 0 {
            HStack(spacing: 16) {
              Label("\(execution.filesChanged) files", systemImage: "doc")
              Label("+\(execution.insertions)", systemImage: "plus")
                .foregroundStyle(.green)
              Label("-\(execution.deletions)", systemImage: "minus")
                .foregroundStyle(.red)
            }
            .font(.caption)
          }
          
          // Merge Conflicts
          if !execution.conflictFiles.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Label("Merge Conflicts", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption.bold())
              
              ForEach(execution.conflictFiles) { conflict in
                Text(conflict.filePath)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
            }
          }

          reviewRoutingSection

          reviewHistorySection
          
          // Action Buttons
          executionActions
        }
        .padding()
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .alert("Reject Execution", isPresented: $showingRejectDialog) {
      TextField("Reason", text: $rejectReason)
      Button("Cancel", role: .cancel) {}
      Button("Reject", role: .destructive) {
        runner.rejectExecution(execution, in: run, reason: rejectReason)
        rejectReason = ""
      }
    } message: {
      Text("Provide a reason for rejecting this execution.")
    }
    .alert("Reject Assigned Review Target", isPresented: $showingAssignedRejectDialog) {
      TextField("Reason", text: $assignedRejectReason)
      Button("Cancel", role: .cancel) {}
      Button("Reject", role: .destructive) {
        if let target = runner.assignedReviewTarget(for: execution, in: run) {
          runner.rejectExecution(
            target,
            in: run,
            reason: assignedRejectReason,
            reviewerExecutionId: execution.id
          )
        }
        assignedRejectReason = ""
      }
    } message: {
      Text("Provide a reason for rejecting the assigned review target.")
    }
    .sheet(isPresented: $showingConflictResolution) {
      ConflictResolutionView(execution: execution, run: run, runner: runner)
    }
  }
  
  @ViewBuilder
  private var statusIcon: some View {
    switch execution.status {
    case .pending:
      Image(systemName: "clock")
        .foregroundStyle(.secondary)
    case .waitingForDependencies:
      Image(systemName: "arrow.triangle.branch")
        .foregroundStyle(.secondary)
    case .creatingWorktree:
      ProgressView()
        .scaleEffect(0.6)
        .frame(width: 20, height: 20)
    case .running:
      ProgressView()
        .scaleEffect(0.6)
        .frame(width: 20, height: 20)
    case .awaitingReview:
      Image(systemName: "eye.circle.fill")
        .foregroundStyle(.orange)
    case .awaitingConfirmation:
      Image(systemName: "pause.circle.fill")
        .foregroundStyle(.yellow)
    case .reviewed:
      Image(systemName: "checkmark.circle")
        .foregroundStyle(.secondary)
    case .approved:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .conflicted:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    case .rejected:
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
    case .merging:
      Image(systemName: "arrow.triangle.merge")
        .foregroundStyle(.blue)
    case .merged:
      Image(systemName: "checkmark.seal.fill")
        .foregroundStyle(.green)
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
    case .cancelled:
      Image(systemName: "slash.circle.fill")
        .foregroundStyle(.secondary)
    }
  }
  
  @ViewBuilder
  private var executionActions: some View {
    HStack(spacing: 8) {
      if execution.status == .awaitingReview {
        Button {
          runner.approveExecution(execution, in: run)
        } label: {
          Label("Approve", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .accessibilityIdentifier("execution.approve.\(execution.id)")

        Button {
          runner.markReviewed(execution, in: run)
        } label: {
          Label("Reviewed", systemImage: "checkmark.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("execution.reviewed.\(execution.id)")
        
        Button {
          showingRejectDialog = true
        } label: {
          Label("Reject", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("execution.reject.\(execution.id)")
      }
      
      if execution.isReadyToMerge {
        Button {
          Task {
            try? await runner.mergeExecution(execution, in: run)
          }
        } label: {
          Label("Merge", systemImage: "arrow.triangle.merge")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("execution.merge.\(execution.id)")
      }

      if case .conflicted = execution.status {
        Button {
          showingConflictResolution = true
        } label: {
          Label("Resolve Conflicts", systemImage: "exclamationmark.triangle.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .accessibilityIdentifier("execution.resolveConflicts.\(execution.id)")
      }
      
      Spacer()
      
      if let path = execution.worktreePath {
        Button {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } label: {
          Label("Reveal", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        
        Button {
          Task {
            try? await VSCodeService.shared.open(path: path)
          }
        } label: {
          Label("Open in VS Code", systemImage: "terminal")
        }
        .buttonStyle(.bordered)
      }
    }
  }

  @ViewBuilder
  private var reviewRoutingSection: some View {
    let eligibleReviewers = runner.eligibleReviewers(for: execution, in: run)
    let assignedTarget = runner.assignedReviewTarget(for: execution, in: run)

    if execution.status == .awaitingReview || execution.status == .reviewed || assignedTarget != nil {
      VStack(alignment: .leading, spacing: 8) {
        Text("Review Routing")
          .font(.caption)
          .foregroundStyle(.secondary)

        if execution.status == .awaitingReview || execution.status == .reviewed {
          HStack(spacing: 8) {
            Label(execution.assignedReviewerLabel ?? "Unassigned reviewer", systemImage: "person.crop.circle.badge.checkmark")
              .font(.caption2)
              .foregroundStyle(execution.assignedReviewerExecutionId == nil ? .tertiary : .secondary)

            if !eligibleReviewers.isEmpty {
              Menu("Assign Reviewer") {
                ForEach(eligibleReviewers) { reviewer in
                  Button(runner.eligibleReviewerLabel(for: reviewer)) {
                    runner.assignReviewer(reviewer, to: execution, in: run)
                  }
                }
                if execution.assignedReviewerExecutionId != nil {
                  Divider()
                  Button("Clear Assignment", role: .destructive) {
                    runner.assignReviewer(nil, to: execution, in: run)
                  }
                }
              }
              .font(.caption2)
            }
          }
        }

        if let assignedTarget {
          VStack(alignment: .leading, spacing: 6) {
            Label("Assigned Review Target", systemImage: "arrowshape.turn.up.right.circle")
              .font(.caption2)
              .foregroundStyle(.secondary)

            Text(assignedTarget.task.title)
              .font(.caption)
              .fontWeight(.medium)

            Text(assignedTarget.status.displayName)
              .font(.caption2)
              .foregroundStyle(.secondary)

            if assignedTarget.status == .awaitingReview || assignedTarget.status == .reviewed {
              HStack(spacing: 8) {
                Button("Approve Target") {
                  runner.approveExecution(assignedTarget, in: run, reviewerExecutionId: execution.id)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Reviewed Target") {
                  runner.markReviewed(assignedTarget, in: run, reviewerExecutionId: execution.id)
                }
                .buttonStyle(.bordered)

                Button("Reject Target") {
                  showingAssignedRejectDialog = true
                }
                .buttonStyle(.bordered)
              }
              .font(.caption2)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var reviewHistorySection: some View {
    if !execution.reviewRecords.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Review History")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(Array(execution.reviewRecords.suffix(3).reversed())) { review in
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Image(systemName: reviewIcon(review.decision.rawValue))
                .foregroundStyle(reviewColor(review.decision.rawValue))
              Text(review.decision.rawValue.capitalized)
                .font(.caption2)
                .fontWeight(.medium)
              if let reviewerLabel = review.reviewerLabel {
                Text("by \(reviewerLabel)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Text(review.createdAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            if let notes = review.notes {
              Text(notes)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
        }
      }
    }
  }

  private func reviewIcon(_ decision: String) -> String {
    switch decision {
    case "approved": return "checkmark.circle.fill"
    case "rejected": return "xmark.circle.fill"
    default: return "checkmark.circle"
    }
  }

  private func reviewColor(_ decision: String) -> Color {
    switch decision {
    case "approved": return .green
    case "rejected": return .red
    default: return .orange
    }
  }
  
  private func formatDuration(_ interval: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: interval) ?? ""
  }
}

// MARK: - New Run Sheet

struct NewParallelRunSheet: View {
  let runner: ParallelWorktreeRunner
  let onCreate: (ParallelWorktreeRun) -> Void
  @Environment(\.dismiss) private var dismiss
  
  @State private var name = ""
  @State private var projectPath = ""
  @State private var baseBranch = "HEAD"
  @State private var requireReviewGate = true
  @State private var autoMergeOnApproval = false
  @State private var tasksText = ""
  @State private var showingProjectPicker = false
  
  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("New Parallel Run")
          .font(.headline)
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding()
      
      Divider()
      
      // Form
      Form {
        Section("Run Configuration") {
          TextField("Name", text: $name)
            .accessibilityIdentifier("newRun.name")
          
          HStack {
            TextField("Project Path", text: $projectPath)
              .accessibilityIdentifier("newRun.projectPath")
            Button("Browse...") {
              showingProjectPicker = true
            }
          }
          
          TextField("Base Branch", text: $baseBranch)
            .accessibilityIdentifier("newRun.baseBranch")
          
          Toggle("Require Review Gate", isOn: $requireReviewGate)
            .accessibilityIdentifier("newRun.reviewGate")
          
          Toggle("Auto-Merge on Approval", isOn: $autoMergeOnApproval)
            .accessibilityIdentifier("newRun.autoMerge")
        }
        
        Section("Tasks (one per line: title | description | prompt)") {
          TextEditor(text: $tasksText)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 150)
            .accessibilityIdentifier("newRun.tasks")
        }
      }
      .formStyle(.grouped)
      
      Divider()
      
      // Footer
      HStack {
        Text("Format: Task Title | Description | Prompt")
          .font(.caption)
          .foregroundStyle(.secondary)
        
        Spacer()
        
        Button("Create & Start") {
          createAndStart()
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.isEmpty || projectPath.isEmpty || tasksText.isEmpty)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("newRun.create")
      }
      .padding()
    }
    .frame(width: 600, height: 500)
    .fileImporter(
      isPresented: $showingProjectPicker,
      allowedContentTypes: [.folder]
    ) { result in
      if case .success(let url) = result {
        projectPath = url.path
      }
    }
  }
  
  private func createAndStart() {
    let tasks = parseTasks()
    guard !tasks.isEmpty else { return }
    
    let run = runner.createRun(
      name: name,
      projectPath: projectPath,
      tasks: tasks,
      baseBranch: baseBranch,
      requireReviewGate: requireReviewGate,
      autoMergeOnApproval: autoMergeOnApproval
    )
    
    onCreate(run)
    dismiss()
    
    Task {
      try? await runner.startRun(run)
    }
  }
  
  private func parseTasks() -> [WorktreeTask] {
    tasksText
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { line -> WorktreeTask? in
        let parts = line.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 1 else { return nil }
        
        let title = parts[0]
        let description = parts.count > 1 ? parts[1] : ""
        let prompt = parts.count > 2 ? parts[2] : title
        
        return WorktreeTask(
          title: title,
          description: description,
          prompt: prompt
        )
      }
  }
}

// MARK: - Snapshot Row

struct ParallelRunSnapshotRow: View {
  let snapshot: ParallelRunSnapshot
  var isLocal: Bool = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        statusIcon
        Text(snapshot.name)
          .fontWeight(.medium)
        Spacer()
        Text("\(snapshot.executionCount)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        ProgressView(value: snapshot.progress)
          .progressViewStyle(.linear)
          .tint(progressTint)
          .frame(maxWidth: 100)

        Text(snapshot.status)
          .font(.caption)
          .foregroundStyle(statusColor)
      }

      Text(snapshot.updatedAt, style: .relative)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
    .opacity(isLocal ? 1 : 0.55)
  }

  private var progressTint: Color {
    switch snapshot.status.lowercased() {
    case "completed": return .green
    case "cancelled": return .secondary
    case "failed": return .red
    default: return .blue
    }
  }

  private var statusColor: Color {
    switch snapshot.status.lowercased() {
    case "completed": return .green
    case "cancelled": return .secondary
    case "failed": return .red
    default: return .secondary
    }
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch snapshot.status.lowercased() {
    case "completed":
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case "failed":
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case "cancelled":
      Image(systemName: "slash.circle.fill").foregroundStyle(.secondary)
    default:
      Image(systemName: "clock.fill").foregroundStyle(.secondary)
    }
  }
}

// MARK: - Snapshot Detail View

struct ParallelRunSnapshotDetailView: View {
  let snapshot: ParallelRunSnapshot
  let runner: ParallelWorktreeRunner
  @Binding var selectedRunId: UUID?

  private var executions: [SnapshotExecution] { snapshot.decodedExecutions }
  private var isProjectLocal: Bool { FileManager.default.fileExists(atPath: snapshot.projectPath) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        snapshotHeader
        Divider()
        statsGrid
        if !executions.isEmpty {
          Divider()
          executionList
        }
      }
      .padding()
    }
    .navigationTitle(snapshot.name)
  }

  // MARK: Header

  private var snapshotHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(snapshot.name)
            .font(.title2)
            .fontWeight(.semibold)

          HStack(spacing: 6) {
            Text(snapshot.status)
              .font(.subheadline)
              .foregroundStyle(statusColor)
              .fontWeight(.medium)

            Text("·")
              .foregroundStyle(.tertiary)

            Text(snapshot.baseBranch)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fontDesign(.monospaced)

            if let target = snapshot.targetBranch {
              Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(target)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fontDesign(.monospaced)
            }
          }
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 6) {
          Label("History", systemImage: "clock.arrow.circlepath")
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.iconOnly)
            .imageScale(.large)
          if !isProjectLocal {
            Label("Project not on this machine", systemImage: "externaldrive.badge.xmark")
              .font(.caption)
              .foregroundStyle(.secondary)
              .help(snapshot.projectPath)
          } else if executions.contains(where: {
            let s = $0.status.lowercased()
            return s == "awaiting review" || s == "reviewed" ||
                   (s == "running" && $0.branchName != nil)
          }) {
            Button {
              let run = runner.restoreFromSnapshot(snapshot)
              selectedRunId = run.id
            } label: {
              Label("Restore to Active", systemImage: "arrow.uturn.backward.circle")
                .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Re-load this run into the active list with full approve/reject/merge controls")
          }
        }
      }

      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Created")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(snapshot.createdAt, style: .date)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Last Updated")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(snapshot.updatedAt, style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            Text("Project")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            if !isProjectLocal {
              Image(systemName: "externaldrive.badge.xmark")
                .font(.caption2)
                .foregroundStyle(Color.red.opacity(0.8))
            }
          }
          Group {
            if isProjectLocal {
              Text(URL(fileURLWithPath: snapshot.projectPath).lastPathComponent)
                .foregroundStyle(.secondary)
            } else {
              Text(URL(fileURLWithPath: snapshot.projectPath).lastPathComponent)
                .foregroundStyle(Color.red.opacity(0.7))
            }
          }
          .font(.caption)
          .help(snapshot.projectPath)
        }
        if let templateName = snapshot.templateName {
          VStack(alignment: .leading, spacing: 2) {
            Text("Template")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Text(templateName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var statusColor: Color {
    switch snapshot.status.lowercased() {
    case "completed": return .green
    case "failed": return .red
    case "cancelled": return .secondary
    default: return .primary
    }
  }

  // MARK: Stats Grid

  private var statsGrid: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Results")
        .font(.headline)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 12) {
        snapshotStatBox(value: snapshot.executionCount, label: "Total", color: .primary)
        snapshotStatBox(value: snapshot.mergedCount, label: "Merged", color: .green)
        if snapshot.pendingReviewCount > 0 {
          snapshotStatBox(value: snapshot.pendingReviewCount, label: "Pending Review", color: .orange)
        }
        if snapshot.readyToMergeCount > 0 {
          snapshotStatBox(value: snapshot.readyToMergeCount, label: "Ready to Merge", color: .blue)
        }
        if snapshot.rejectedCount > 0 {
          snapshotStatBox(value: snapshot.rejectedCount, label: "Rejected", color: .red)
        }
        if snapshot.failedCount > 0 {
          snapshotStatBox(value: snapshot.failedCount, label: "Failed", color: .red)
        }
        if snapshot.hungCount > 0 {
          snapshotStatBox(value: snapshot.hungCount, label: "Hung", color: .yellow)
        }
      }
    }
  }

  private func snapshotStatBox(value: Int, label: String, color: Color) -> some View {
    VStack(spacing: 4) {
      Text("\(value)")
        .font(.title2)
        .fontWeight(.bold)
        .foregroundStyle(color)
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: Execution List

  private var executionList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Tasks (\(executions.count))")
        .font(.headline)

      ForEach(executions) { exec in
        HStack(alignment: .top, spacing: 10) {
          executionStatusIcon(exec.status)
            .frame(width: 18)

          VStack(alignment: .leading, spacing: 2) {
            Text(exec.taskTitle)
              .font(.subheadline)
              .fontWeight(.medium)

            HStack(spacing: 8) {
              Text(exec.status)
                .font(.caption)
                .foregroundStyle(.secondary)

              if exec.filesChanged > 0 {
                Text("·")
                  .foregroundStyle(.tertiary)
                  .font(.caption)
                Text("\(exec.filesChanged)F +\(exec.insertions) -\(exec.deletions)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fontDesign(.monospaced)
              }
            }

            if let branch = exec.branchName {
              Text(branch)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fontDesign(.monospaced)
            }

            if !exec.artifacts.isEmpty {
              HStack(spacing: 8) {
                Label("\(exec.artifacts.count) artifacts", systemImage: "folder.badge.plus")
                  .font(.caption2)
                  .foregroundStyle(.secondary)

                if let firstArtifact = exec.artifacts.first {
                  Button("Reveal handoff") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: firstArtifact.filePath)])
                  }
                  .buttonStyle(.link)
                  .font(.caption2)
                }
              }
            }

            if !exec.reviewRecords.isEmpty {
              let latestReview = exec.reviewRecords.last
              Label(
                latestReview?.reviewerLabel.flatMap { "\(exec.reviewRecords.count) reviews · \($0)" }
                  ?? "\(exec.reviewRecords.count) reviews",
                systemImage: "checklist"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 4)

        if exec.id != executions.last?.id {
          Divider()
        }
      }
    }
  }

  @ViewBuilder
  private func executionStatusIcon(_ status: String) -> some View {
    switch status.lowercased() {
    case "merged":
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case "rejected":
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case "failed":
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
    case "awaiting review":
      Image(systemName: "eye.circle.fill").foregroundStyle(.orange)
    case "ready to merge":
      Image(systemName: "arrow.triangle.merge").foregroundStyle(.blue)
    default:
      Image(systemName: "circle").foregroundStyle(.secondary)
    }
  }
}

// MARK: - Snapshot Execution (for decoding executionsJSON)

struct SnapshotExecution: Identifiable {
  struct Artifact: Identifiable {
    let id = UUID()
    let type: String
    let filePath: String
    let label: String?
  }

  struct ReviewRecord: Identifiable {
    let id = UUID()
    let decision: String
    let reviewerLabel: String?
  }

  let id: UUID
  let taskTitle: String
  let status: String
  let filesChanged: Int
  let insertions: Int
  let deletions: Int
  let branchName: String?
  let artifacts: [Artifact]
  let reviewRecords: [ReviewRecord]
}

extension ParallelRunSnapshot {
  var decodedExecutions: [SnapshotExecution] {
    guard !executionsJSON.isEmpty,
          let data = executionsJSON.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return array.compactMap { dict in
      guard let idStr = dict["id"] as? String,
            let id = UUID(uuidString: idStr),
            let title = dict["taskTitle"] as? String,
            let status = dict["status"] as? String else { return nil }
      return SnapshotExecution(
        id: id,
        taskTitle: title,
        status: status,
        filesChanged: dict["filesChanged"] as? Int ?? 0,
        insertions: dict["insertions"] as? Int ?? 0,
        deletions: dict["deletions"] as? Int ?? 0,
        branchName: dict["branchName"] as? String,
        artifacts: (dict["artifacts"] as? [[String: Any]] ?? []).compactMap { artifactDict in
          guard let type = artifactDict["type"] as? String,
                let filePath = artifactDict["filePath"] as? String else {
            return nil
          }
          return SnapshotExecution.Artifact(
            type: type,
            filePath: filePath,
            label: artifactDict["label"] as? String
          )
        },
        reviewRecords: (dict["reviewRecords"] as? [[String: Any]] ?? []).compactMap { reviewDict in
          guard let decision = reviewDict["decision"] as? String else {
            return nil
          }
          return SnapshotExecution.ReviewRecord(
            decision: decision,
            reviewerLabel: reviewDict["reviewerLabel"] as? String
          )
        }
      )
    }
  }
}

