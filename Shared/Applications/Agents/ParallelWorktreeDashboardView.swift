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
      .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
      
      // Right: Detail
      detailContent(runner: runner)
        .frame(minWidth: 400, maxWidth: .infinity)
    }
    .frame(minWidth: 700, idealWidth: 900)
    .navigationTitle("Parallel Worktrees")
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
  
  @State private var selectedSnapshotId: UUID?
  
  @ViewBuilder
  private func runList(runner: ParallelWorktreeRunner) -> some View {
    let hasAnyRuns = !runner.runs.isEmpty || !runner.historicalRuns.isEmpty
    
    if !hasAnyRuns {
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
        // Active runs
        if !runner.runs.isEmpty {
          Section("Active") {
            ForEach(runner.runs) { run in
              ParallelRunRow(run: run)
                .tag(run.id)
            }
          }
        }
        
        // Historical runs (from snapshots)
        if !runner.historicalRuns.isEmpty {
          Section("History") {
            ForEach(runner.historicalRuns, id: \.id) { snapshot in
              HistoricalRunRow(snapshot: snapshot)
                .tag(snapshot.id)
            }
          }
        }
      }
      .listStyle(.plain)
      .onAppear {
        if selectedRunId == nil {
          selectedRunId = runner.runs.first?.id ?? runner.historicalRuns.first?.id
        }
      }
      .onChange(of: runner.runs.map(\.id)) { _, newIds in
        if let selectedRunId, newIds.contains(selectedRunId) {
          return
        }
        // Try active runs first, then historical
        selectedRunId = newIds.first ?? runner.historicalRuns.first?.id
      }
    }
  }
  
  @ViewBuilder
  private func detailContent(runner: ParallelWorktreeRunner) -> some View {
    if let selectedRunId, let run = runner.runs.first(where: { $0.id == selectedRunId }) {
      ParallelRunDetailView(
        run: run,
        runner: runner,
        selectedExecution: $selectedExecution,
        expandedExecutions: $expandedExecutions
      )
    } else if let selectedRunId, let snapshot = runner.historicalRuns.first(where: { $0.id == selectedRunId }) {
      HistoricalRunDetailView(snapshot: snapshot)
    } else {
      ContentUnavailableView {
        Label("Select a Run", systemImage: "square.stack.3d.up")
      } description: {
        Text("Select a parallel run from the sidebar to view details.")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(24)
    }
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
        
        Text(run.status.displayName)
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

// MARK: - Historical Run Row

struct HistoricalRunRow: View {
  let snapshot: ParallelRunSnapshot
  
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
          .tint(progressColor)
          .frame(maxWidth: 100)
        
        Text(snapshot.status)
          .font(.caption)
          .foregroundStyle(statusTextColor)
      }
      
      if snapshot.mergedCount > 0 {
        Text("\(snapshot.mergedCount) merged")
          .font(.caption2)
          .foregroundStyle(.green)
      }
      
      Text(snapshot.updatedAt.formatted(.relative(presentation: .named)))
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
  }
  
  private var progressColor: Color {
    switch snapshot.status {
    case "Completed": return .green
    case "Cancelled": return .secondary
    case "Failed": return .red
    default: return .blue
    }
  }
  
  private var statusTextColor: Color {
    switch snapshot.status {
    case "Completed": return .green
    case "Cancelled": return .secondary
    case "Failed": return .red
    default: return .secondary
    }
  }
  
  @ViewBuilder
  private var statusIcon: some View {
    switch snapshot.status {
    case "Completed":
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case "Failed":
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
    case "Cancelled":
      Image(systemName: "slash.circle.fill")
        .foregroundStyle(.secondary)
    default:
      Image(systemName: "clock.fill")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Historical Run Detail View

struct HistoricalRunDetailView: View {
  let snapshot: ParallelRunSnapshot
  @Environment(DataService.self) private var dataService
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Header
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(snapshot.name)
              .font(.title2)
              .fontWeight(.semibold)
            Spacer()
            Label("History", systemImage: "clock.arrow.circlepath")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          
          Text(snapshot.projectPath)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          
          HStack(spacing: 16) {
            Label(snapshot.baseBranch, systemImage: "arrow.triangle.branch")
            if let targetBranch = snapshot.targetBranch {
              Image(systemName: "arrow.right")
              Text(targetBranch)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        
        Divider()
        
        // Status summary
        VStack(alignment: .leading, spacing: 8) {
          Text("Summary")
            .font(.headline)
          
          LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16)
          ], spacing: 12) {
            StatItem(label: "Total", value: "\(snapshot.executionCount)", color: .primary)
            StatItem(label: "Merged", value: "\(snapshot.mergedCount)", color: .green)
            StatItem(label: "Failed", value: "\(snapshot.failedCount)", color: .red)
            StatItem(label: "Rejected", value: "\(snapshot.rejectedCount)", color: .orange)
            StatItem(label: "Progress", value: "\(Int(snapshot.progress * 100))%", color: .blue)
            StatItem(label: "Guidance", value: "\(snapshot.operatorGuidanceCount)", color: .purple)
          }
        }
        
        Divider()
        
        // Dates
        VStack(alignment: .leading, spacing: 8) {
          Text("Timeline")
            .font(.headline)
          
          HStack(spacing: 24) {
            VStack(alignment: .leading) {
              Text("Created")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            VStack(alignment: .leading) {
              Text("Last Updated")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
          }
        }
        
        Divider()
        
        // Executions
        VStack(alignment: .leading, spacing: 8) {
          Text("Executions")
            .font(.headline)
          
          let executions = dataService.decodeParallelExecutions(json: snapshot.executionsJSON)
          
          if executions.isEmpty {
            Text("No execution details available")
              .foregroundStyle(.secondary)
          } else {
            ForEach(executions) { execution in
              HistoricalExecutionRow(execution: execution)
            }
          }
        }
      }
      .padding(24)
    }
  }
}

private struct StatItem: View {
  let label: String
  let value: String
  let color: Color
  
  var body: some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.title3)
        .fontWeight(.semibold)
        .foregroundStyle(color)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(8)
    .background(color.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

private struct HistoricalExecutionRow: View {
  let execution: DataService.HistoricalExecution
  
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        statusIcon
        Text(execution.taskTitle)
          .fontWeight(.medium)
        Spacer()
        if let branchName = execution.branchName {
          Text(branchName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      
      if !execution.taskDescription.isEmpty {
        Text(execution.taskDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      
      HStack(spacing: 12) {
        if execution.filesChanged > 0 {
          Label("\(execution.filesChanged) files", systemImage: "doc.text")
        }
        if execution.insertions > 0 {
          Text("+\(execution.insertions)")
            .foregroundStyle(.green)
        }
        if execution.deletions > 0 {
          Text("-\(execution.deletions)")
            .foregroundStyle(.red)
        }
        if execution.mergeConflictCount > 0 {
          Label("\(execution.mergeConflictCount) conflicts", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(Color.primary.opacity(0.03))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
  
  @ViewBuilder
  private var statusIcon: some View {
    switch execution.status {
    case "Merged":
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case "Approved":
      Image(systemName: "hand.thumbsup.fill")
        .foregroundStyle(.green)
    case "Rejected":
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.orange)
    case "Failed":
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
    case "Cancelled":
      Image(systemName: "slash.circle.fill")
        .foregroundStyle(.secondary)
    case "Awaiting Review":
      Image(systemName: "eye.circle.fill")
        .foregroundStyle(.orange)
    default:
      Image(systemName: "circle")
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
            Text(run.status.displayName)
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
            Text(run.status.displayName)
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
        statBox(title: "Pending Review", value: "\(run.pendingReviewCount)", color: .orange)
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
          Task {
            try? await runner.mergeAllApproved(in: run)
          }
        } label: {
          Label("Merge All Ready", systemImage: "arrow.triangle.merge")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("parallelRun.mergeAll")
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
          if !execution.mergeConflicts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Label("Merge Conflicts", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption.bold())
              
              ForEach(execution.mergeConflicts, id: \.self) { conflict in
                Text(conflict)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
            }
          }
          
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
  }
  
  @ViewBuilder
  private var statusIcon: some View {
    switch execution.status {
    case .pending:
      Image(systemName: "clock")
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
    case .reviewed:
      Image(systemName: "checkmark.circle")
        .foregroundStyle(.secondary)
    case .approved:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
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

