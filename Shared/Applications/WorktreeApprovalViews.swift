//
//  WorktreeApprovalViews.swift
//  Peel
//
//  Inline worktree approval chain views for the Branches tab.
//  Shows live approval/reject/merge controls when executions are awaiting review.
//

import SwiftUI

// MARK: - Pending Approvals Section

/// Shows all parallel worktree runs for a repo that have pending reviews.
/// Displayed inline in the Branches tab above the basic worktree list.
struct WorktreeApprovalsSection: View {
  let runs: [ParallelWorktreeRun]
  let runner: ParallelWorktreeRunner
  @State private var expandedExecutions: Set<UUID> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Pending Approvals")

      ForEach(runs) { run in
        WorktreeRunApprovalCard(
          run: run,
          runner: runner,
          expandedExecutions: $expandedExecutions
        )
      }
    }
  }
}

// MARK: - Run Approval Card

/// A card representing a parallel worktree run with inline approval controls.
struct WorktreeRunApprovalCard: View {
  @Bindable var run: ParallelWorktreeRun
  let runner: ParallelWorktreeRunner
  @Binding var expandedExecutions: Set<UUID>
  @State private var mergeError: String?

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        // Run header
        runHeader

        Divider()

        // Progress overview
        progressOverview

        // Bulk action buttons
        if run.pendingReviewCount > 0 || run.readyToMergeCount > 0 {
          bulkActions
        }

        // Execution cards
        ForEach(run.executions) { execution in
          InlineExecutionCard(
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
      .padding(4)
    }
  }

  private var runHeader: some View {
    HStack(spacing: 10) {
      runStatusIcon

      VStack(alignment: .leading, spacing: 2) {
        Text(run.name)
          .fontWeight(.semibold)

        Text(run.status.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if let started = run.startedAt {
        Text(started, style: .relative)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }

  @ViewBuilder
  private var runStatusIcon: some View {
    switch run.status {
    case .awaitingReview:
      Image(systemName: "eye.circle.fill")
        .font(.title3)
        .foregroundStyle(.orange)
    case .running:
      ProgressView()
        .controlSize(.small)
        .frame(width: 28)
    case .merging:
      Image(systemName: "arrow.triangle.merge")
        .font(.title3)
        .foregroundStyle(.blue)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .font(.title3)
        .foregroundStyle(.green)
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .font(.title3)
        .foregroundStyle(.red)
    default:
      Image(systemName: "clock")
        .font(.title3)
        .foregroundStyle(.secondary)
    }
  }

  private var progressOverview: some View {
    HStack(spacing: 16) {
      if run.pendingReviewCount > 0 {
        Label("\(run.pendingReviewCount) awaiting", systemImage: "eye")
          .foregroundStyle(.orange)
      }
      if run.readyToMergeCount > 0 {
        Label("\(run.readyToMergeCount) ready", systemImage: "arrow.triangle.merge")
          .foregroundStyle(.green)
      }
      if run.activeCount > 0 {
        Label("\(run.activeCount) running", systemImage: "bolt")
          .foregroundStyle(.blue)
      }
      if run.mergedCount > 0 {
        Label("\(run.mergedCount) merged", systemImage: "checkmark.seal")
          .foregroundStyle(.green)
      }
      if run.failedCount > 0 {
        Label("\(run.failedCount) failed", systemImage: "xmark.circle")
          .foregroundStyle(.red)
      }
    }
    .font(.caption)
  }

  private var bulkActions: some View {
    HStack(spacing: 8) {
      if run.pendingReviewCount > 0 {
        Button {
          runner.approveAllPending(in: run)
        } label: {
          Label("Approve All (\(run.pendingReviewCount))", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.small)
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
          Label("Merge All (\(run.readyToMergeCount))", systemImage: "arrow.triangle.merge")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      if let mergeError {
        Label(mergeError, systemImage: "exclamationmark.triangle")
          .font(.caption2)
          .foregroundStyle(.red)
          .lineLimit(2)
      }
    }
  }
}

// MARK: - Inline Execution Card

/// Compact execution card with approval controls, embedded in the branches tab.
struct InlineExecutionCard: View {
  @Bindable var execution: ParallelWorktreeExecution
  let run: ParallelWorktreeRun
  let runner: ParallelWorktreeRunner
  let isExpanded: Bool
  let onToggleExpand: () -> Void
  @State private var rejectReason = ""
  @State private var showingRejectDialog = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Compact header row
      Button(action: onToggleExpand) {
        HStack(spacing: 8) {
          executionStatusIcon

          VStack(alignment: .leading, spacing: 1) {
            Text(execution.task.title)
              .font(.callout)
              .fontWeight(.medium)
              .lineLimit(1)
            Text(execution.branchName ?? execution.status.displayName)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer()

          // Diff stats inline
          if execution.filesChanged > 0 {
            HStack(spacing: 4) {
              Text("\(execution.filesChanged)")
                .foregroundStyle(.secondary)
              Text("+\(execution.insertions)")
                .foregroundStyle(.green)
              Text("-\(execution.deletions)")
                .foregroundStyle(.red)
            }
            .font(.caption2.monospaced())
          }

          if let duration = execution.duration {
            Text(formatDuration(duration))
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        Divider()
          .padding(.horizontal, 10)

        VStack(alignment: .leading, spacing: 8) {
          // Description
          if !execution.task.description.isEmpty {
            Text(execution.task.description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(4)
          }

          // Chain step results
          if !execution.chainStepResults.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("Agent Steps")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

              ForEach(execution.chainStepResults) { step in
                HStack(spacing: 6) {
                  Image(systemName: stepIcon(step))
                    .font(.caption2)
                    .foregroundStyle(stepColor(step))
                  Text(step.stepName)
                    .font(.caption)
                  if let verdict = step.reviewVerdict {
                    Text(verdict)
                      .font(.caption2)
                      .fontWeight(.medium)
                      .padding(.horizontal, 4)
                      .padding(.vertical, 1)
                      .background(Capsule().fill(verdictColor(verdict).opacity(0.15)))
                      .foregroundStyle(verdictColor(verdict))
                  }
                  Spacer()
                  if let duration = step.durationSeconds {
                    Text(String(format: "%.1fs", duration))
                      .font(.caption2)
                      .foregroundStyle(.tertiary)
                  }
                }
              }
            }
          }

          // Diff summary preview
          if let diffSummary = execution.diffSummary, !diffSummary.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("Changes")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
              Text(diffSummary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(6)
            }
          }

          // RAG context
          if !execution.ragSnippets.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
              Text("RAG Context (\(execution.ragSnippets.count))")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

              ForEach(execution.ragSnippets.prefix(3)) { snippet in
                HStack(spacing: 4) {
                  Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                  Text(snippet.filePath)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                }
              }
            }
          }

          // Action buttons
          executionActions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
      }
    }
    #if os(macOS)
    .background(Color(nsColor: .controlBackgroundColor))
    #else
    .background(Color(.systemGroupedBackground))
    #endif
    .clipShape(RoundedRectangle(cornerRadius: 6))
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
  private var executionStatusIcon: some View {
    switch execution.status {
    case .pending:
      Image(systemName: "clock")
        .foregroundStyle(.secondary)
        .frame(width: 16)
    case .waitingForDependencies:
      Image(systemName: "arrow.triangle.branch")
        .foregroundStyle(.secondary)
        .frame(width: 16)
    case .creatingWorktree, .running:
      ProgressView()
        .scaleEffect(0.5)
        .frame(width: 16, height: 16)
    case .awaitingReview:
      Image(systemName: "eye.circle.fill")
        .foregroundStyle(.orange)
        .frame(width: 16)
    case .reviewed:
      Image(systemName: "checkmark.circle")
        .foregroundStyle(.secondary)
        .frame(width: 16)
    case .approved:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .frame(width: 16)
    case .rejected:
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
        .frame(width: 16)
    case .merging:
      Image(systemName: "arrow.triangle.merge")
        .foregroundStyle(.blue)
        .frame(width: 16)
    case .merged:
      Image(systemName: "checkmark.seal.fill")
        .foregroundStyle(.green)
        .frame(width: 16)
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
        .frame(width: 16)
    case .cancelled:
      Image(systemName: "slash.circle.fill")
        .foregroundStyle(.secondary)
        .frame(width: 16)
    case .conflicted:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .frame(width: 16)
    }
  }

  @ViewBuilder
  private var executionActions: some View {
    HStack(spacing: 6) {
      if execution.status == .awaitingReview {
        Button {
          runner.approveExecution(execution, in: run)
        } label: {
          Label("Approve", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.mini)

        Button {
          runner.markReviewed(execution, in: run)
        } label: {
          Label("Reviewed", systemImage: "checkmark.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)

        Button {
          showingRejectDialog = true
        } label: {
          Label("Reject", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
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
        .controlSize(.mini)
      }

      if case .conflicted = execution.status {
        Button {
          // Open in Finder for manual conflict resolution
          if let path = execution.worktreePath {
            #if os(macOS)
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            #endif
          }
        } label: {
          Label("Resolve", systemImage: "exclamationmark.triangle")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.mini)
      }

      Spacer()

      #if os(macOS)
      if let path = execution.worktreePath {
        Button {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
      }
      #endif
    }
  }

  private func stepIcon(_ step: ParallelWorktreeExecution.ChainStepSummary) -> String {
    if step.gateResult != nil { return "shield.checkered" }
    if step.reviewVerdict != nil { return "eye" }
    if step.plannerDecision != nil { return "lightbulb" }
    return "bolt"
  }

  private func stepColor(_ step: ParallelWorktreeExecution.ChainStepSummary) -> Color {
    if step.gateResult == "pass" { return .green }
    if step.gateResult == "fail" { return .red }
    if step.reviewVerdict != nil { return .orange }
    if step.plannerDecision != nil { return .blue }
    return .secondary
  }

  private func verdictColor(_ verdict: String) -> Color {
    let lowered = verdict.lowercased()
    if lowered.contains("approve") || lowered.contains("pass") { return .green }
    if lowered.contains("reject") || lowered.contains("fail") || lowered.contains("request_changes") { return .red }
    return .orange
  }

  private func formatDuration(_ interval: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: interval) ?? ""
  }
}
