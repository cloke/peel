//
//  ExecutionDetailView.swift
//  Peel
//
//  Full-screen detail view for a single parallel worktree execution.
//  Shows agent timeline, code changes (inline diff), artifacts, and approval actions.
//

import Git
import SwiftUI

// MARK: - Execution Detail View

/// Rich detail view for a single worktree execution, presented as a sheet or navigation destination.
/// Modeled after the PR detail view pattern with sections: status, timeline, changed files, artifacts.
struct ExecutionDetailView: View {
  @Bindable var execution: ParallelWorktreeExecution
  let run: ParallelWorktreeRun
  let runner: ParallelWorktreeRunner
  let onDismiss: () -> Void

  @State private var rejectReason = ""
  @State private var showingRejectDialog = false
  @State private var expandedSteps: Set<UUID> = []
  @State private var showingFullOutput = false
  @State private var fullOutputStepId: UUID?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        headerSection
        Divider()
        statusBar
        if !execution.chainStepResults.isEmpty {
          Divider()
          agentTimeline
        }
        if execution.filesChanged > 0 {
          Divider()
          ExecutionChangedFilesView(
            execution: execution,
            run: run,
            runner: runner
          )
        }
        if !execution.artifacts.isEmpty {
          Divider()
          artifactsSection
        }
        if !execution.ragSnippets.isEmpty {
          Divider()
          ragContextSection
        }
        if !execution.operatorGuidance.isEmpty {
          Divider()
          operatorGuidanceSection
        }
        if !execution.reviewRecords.isEmpty {
          Divider()
          reviewHistorySection
        }
        Divider()
        actionButtons
      }
      .padding(20)
    }
    .frame(minWidth: 600, minHeight: 400)
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
    .sheet(isPresented: $showingFullOutput) {
      if let stepId = fullOutputStepId,
         let step = execution.chainStepResults.first(where: { $0.id == stepId }) {
        FullStepOutputSheet(step: step)
      }
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Button(action: onDismiss) {
          Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)

        Spacer()

        #if os(macOS)
        if let path = execution.worktreePath {
          Button {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
          } label: {
            Label("Reveal in Finder", systemImage: "folder")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
        #endif
      }

      Text(execution.task.title)
        .font(.title2)
        .fontWeight(.bold)

      HStack(spacing: 16) {
        if let branch = execution.branchName {
          Label(branch, systemImage: "arrow.triangle.branch")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let duration = execution.duration {
          Label(formatDuration(duration), systemImage: "clock")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        let totalCost = execution.chainStepResults.reduce(0.0) { $0 + $1.premiumCost }
        if totalCost > 0 {
          Label(String(format: "$%.2f", totalCost), systemImage: "creditcard")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if !execution.task.description.isEmpty {
        Text(execution.task.description)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Status Bar

  private var statusBar: some View {
    HStack(spacing: 12) {
      // Status pill
      statusPill

      // File stats
      if execution.filesChanged > 0 {
        HStack(spacing: 6) {
          Label("\(execution.filesChanged) file\(execution.filesChanged == 1 ? "" : "s")", systemImage: "doc")
          Text("+\(execution.insertions)")
            .foregroundStyle(.green)
          Text("-\(execution.deletions)")
            .foregroundStyle(.red)
        }
        .font(.caption.monospaced())
      }

      Spacer()

      // Risk level from reviewer steps
      if let risk = aggregateRiskLevel {
        Text("Risk: \(risk)")
          .font(.caption2)
          .fontWeight(.medium)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Capsule().fill(riskColor(risk).opacity(0.15)))
          .foregroundStyle(riskColor(risk))
      }
    }
  }

  @ViewBuilder
  private var statusPill: some View {
    let (icon, color, label) = statusInfo
    HStack(spacing: 4) {
      Image(systemName: icon)
      Text(label)
    }
    .font(.caption)
    .fontWeight(.medium)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(Capsule().fill(color.opacity(0.15)))
    .foregroundStyle(color)
  }

  private var statusInfo: (String, Color, String) {
    switch execution.status {
    case .pending: ("clock", .secondary, "Pending")
    case .waitingForDependencies: ("arrow.triangle.branch", .secondary, "Waiting")
    case .creatingWorktree, .running: ("bolt.fill", .blue, "Running")
    case .awaitingReview: ("eye.circle.fill", .orange, "Awaiting Review")
    case .reviewed: ("checkmark.circle", .secondary, "Reviewed")
    case .approved: ("checkmark.circle.fill", .green, "Approved")
    case .rejected: ("xmark.circle.fill", .red, "Rejected")
    case .merging: ("arrow.triangle.merge", .blue, "Merging")
    case .merged: ("checkmark.seal.fill", .green, "Merged")
    case .failed: ("xmark.circle.fill", .red, "Failed")
    case .cancelled: ("slash.circle.fill", .secondary, "Cancelled")
    case .conflicted: ("exclamationmark.triangle.fill", .orange, "Conflicted")
    }
  }

  // MARK: - Agent Timeline

  private var agentTimeline: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Agent Timeline")
        .font(.headline)

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(execution.chainStepResults.enumerated()), id: \.element.id) { index, step in
          HStack(alignment: .top, spacing: 12) {
            // Timeline connector
            VStack(spacing: 0) {
              Circle()
                .fill(stepColor(step))
                .frame(width: 10, height: 10)
                .padding(.top, 5)

              if index < execution.chainStepResults.count - 1 {
                Rectangle()
                  .fill(Color.secondary.opacity(0.2))
                  .frame(width: 2)
                  .frame(minHeight: 30)
              }
            }
            .frame(width: 10)

            // Step content
            VStack(alignment: .leading, spacing: 6) {
              stepHeader(step)
              stepDetail(step)
            }
            .padding(.bottom, 8)
          }
        }
      }
    }
  }

  private func stepHeader(_ step: ParallelWorktreeExecution.ChainStepSummary) -> some View {
    HStack(spacing: 8) {
      Image(systemName: stepIcon(step))
        .font(.caption)
        .foregroundStyle(stepColor(step))

      Text(step.stepName)
        .font(.callout)
        .fontWeight(.medium)

      // Role-specific badges
      if let verdict = step.reviewVerdict {
        Text(verdict)
          .font(.caption2)
          .fontWeight(.medium)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(verdictColor(verdict).opacity(0.15)))
          .foregroundStyle(verdictColor(verdict))
      }
      if let gate = step.gateResult {
        Text(gate)
          .font(.caption2)
          .fontWeight(.medium)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(verdictColor(gate).opacity(0.15)))
          .foregroundStyle(verdictColor(gate))
      }

      Spacer()

      // Model + duration + cost
      HStack(spacing: 8) {
        Text(step.model)
          .font(.caption2)
          .foregroundStyle(.quaternary)

        if let duration = step.durationSeconds {
          Text(String(format: "%.1fs", duration))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        if step.premiumCost > 0 {
          Text(String(format: "$%.2f", step.premiumCost))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  @ViewBuilder
  private func stepDetail(_ step: ParallelWorktreeExecution.ChainStepSummary) -> some View {
    let role = step.role.lowercased()

    // Role-specific rendering
    if role == "reviewer" || role == "review", let verdict = step.reviewVerdict {
      reviewerStepDetail(step, verdict: verdict)
    } else if role == "planner" || role == "plan", let decision = step.plannerDecision {
      plannerStepDetail(decision)
    } else if role == "gate", let result = step.gateResult {
      gateStepDetail(result)
    } else if !step.outputPreview.isEmpty {
      genericStepDetail(step)
    }

    // View full output button
    if !step.outputPreview.isEmpty {
      Button {
        fullOutputStepId = step.id
        showingFullOutput = true
      } label: {
        Label("View Full Output", systemImage: "doc.text.magnifyingglass")
          .font(.caption2)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.blue)
    }
  }

  private func reviewerStepDetail(_ step: ParallelWorktreeExecution.ChainStepSummary, verdict: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      // Parse structured content from output
      let lines = step.outputPreview.components(separatedBy: "\n").filter { !$0.isEmpty }
      let issues = lines.filter { $0.lowercased().hasPrefix("issue:") || $0.hasPrefix("- ⚠") || $0.hasPrefix("- ❌") }
      let suggestions = lines.filter { $0.lowercased().hasPrefix("suggestion:") || $0.hasPrefix("- 💡") || $0.hasPrefix("- ✨") }

      if !issues.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          Text("Issues (\(issues.count))")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.orange)
          ForEach(issues.prefix(5), id: \.self) { issue in
            HStack(alignment: .top, spacing: 4) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
              Text(issue)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      if !suggestions.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          Text("Suggestions (\(suggestions.count))")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.blue)
          ForEach(suggestions.prefix(5), id: \.self) { suggestion in
            HStack(alignment: .top, spacing: 4) {
              Image(systemName: "lightbulb.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
              Text(suggestion)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      // Fallback: show preview if no structured content found
      if issues.isEmpty && suggestions.isEmpty && !step.outputPreview.isEmpty {
        Text(String(step.outputPreview.prefix(300)))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(4)
      }
    }
  }

  private func plannerStepDetail(_ decision: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(decision)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(6)
    }
  }

  private func gateStepDetail(_ result: String) -> some View {
    let passed = result.lowercased().contains("pass")
    return HStack(spacing: 6) {
      Image(systemName: passed ? "checkmark.shield.fill" : "xmark.shield.fill")
        .foregroundStyle(passed ? .green : .red)
      Text(result)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func genericStepDetail(_ step: ParallelWorktreeExecution.ChainStepSummary) -> some View {
    Text(String(step.outputPreview.prefix(300)))
      .font(.caption2.monospaced())
      .foregroundStyle(.secondary)
      .lineLimit(4)
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      #if os(macOS)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
      #else
      .background(Color(.secondarySystemBackground))
      #endif
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  // MARK: - Artifacts

  private var artifactsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Artifacts")
        .font(.headline)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
        ForEach(execution.artifacts) { artifact in
          artifactCard(artifact)
        }
      }
    }
  }

  private func artifactCard(_ artifact: ParallelWorktreeExecution.Artifact) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      // Icon by type
      Image(systemName: artifactIcon(artifact.type))
        .font(.title2)
        .foregroundStyle(artifactColor(artifact.type))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)

      if let label = artifact.label {
        Text(label)
          .font(.caption)
          .fontWeight(.medium)
          .lineLimit(2)
      }

      Text(artifact.type)
        .font(.caption2)
        .foregroundStyle(.secondary)

      #if os(macOS)
      Button {
        NSWorkspace.shared.selectFile(artifact.filePath, inFileViewerRootedAtPath: "")
      } label: {
        Label("Open", systemImage: "arrow.up.forward.square")
          .font(.caption2)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.blue)
      #endif
    }
    .padding(10)
    .frame(maxWidth: .infinity)
    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - RAG Context

  private var ragContextSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("RAG Context (\(execution.ragSnippets.count) files)")
        .font(.headline)

      ForEach(execution.ragSnippets) { snippet in
        HStack(spacing: 8) {
          Image(systemName: "doc.text")
            .font(.caption)
            .foregroundStyle(.tertiary)

          VStack(alignment: .leading, spacing: 2) {
            Text(snippet.filePath)
              .font(.caption.monospaced())
              .lineLimit(1)
            Text("Lines \(snippet.startLine)-\(snippet.endLine) • Score: \(String(format: "%.2f", snippet.relevanceScore))")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }

          Spacer()
        }
      }
    }
  }

  // MARK: - Operator Guidance

  private var operatorGuidanceSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Operator Guidance")
        .font(.headline)

      ForEach(Array(execution.operatorGuidance.enumerated()), id: \.offset) { _, guidance in
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "info.circle.fill")
            .font(.caption)
            .foregroundStyle(.blue)
          Text(guidance)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    }
  }

  // MARK: - Review History

  private var reviewHistorySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Review History")
        .font(.headline)

      ForEach(execution.reviewRecords) { record in
        HStack(spacing: 8) {
          Image(systemName: reviewIcon(record.decision))
            .foregroundStyle(reviewColor(record.decision))

          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(record.decision.rawValue.capitalized)
                .font(.caption)
                .fontWeight(.medium)
              if let reviewer = record.reviewerLabel {
                Text("by \(reviewer)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(record.createdAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            if let notes = record.notes {
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

  // MARK: - Action Buttons

  private var actionButtons: some View {
    HStack(spacing: 8) {
      if execution.status == .awaitingReview {
        Button {
          runner.approveExecution(execution, in: run)
        } label: {
          Label("Approve", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.regular)

        Button {
          runner.markReviewed(execution, in: run)
        } label: {
          Label("Reviewed", systemImage: "checkmark.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)

        Button {
          showingRejectDialog = true
        } label: {
          Label("Reject", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
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
        .controlSize(.regular)
      }

      Spacer()
    }
  }

  // MARK: - Helpers

  private var aggregateRiskLevel: String? {
    for step in execution.chainStepResults {
      let output = step.outputPreview.lowercased()
      if output.contains("risk: high") || output.contains("risk:high") { return "high" }
      if output.contains("risk: medium") || output.contains("risk:medium") { return "medium" }
      if output.contains("risk: low") || output.contains("risk:low") { return "low" }
    }
    return nil
  }

  private func riskColor(_ risk: String) -> Color {
    switch risk.lowercased() {
    case "high": .red
    case "medium": .orange
    default: .green
    }
  }

  private func stepIcon(_ step: ParallelWorktreeExecution.ChainStepSummary) -> String {
    if step.gateResult != nil { return "shield.checkered" }
    if step.reviewVerdict != nil { return "eye" }
    if step.plannerDecision != nil { return "lightbulb" }
    return "bolt"
  }

  private func stepColor(_ step: ParallelWorktreeExecution.ChainStepSummary) -> Color {
    if step.gateResult?.lowercased().contains("pass") == true { return .green }
    if step.gateResult?.lowercased().contains("fail") == true { return .red }
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

  private func artifactIcon(_ type: String) -> String {
    switch type.lowercased() {
    case "screenshot": "camera.fill"
    case "report": "doc.text.fill"
    case "test_results", "test": "checkmark.square.fill"
    default: "doc.fill"
    }
  }

  private func artifactColor(_ type: String) -> Color {
    switch type.lowercased() {
    case "screenshot": .purple
    case "report": .blue
    case "test_results", "test": .green
    default: .secondary
    }
  }

  private func reviewIcon(_ decision: ParallelWorktreeExecution.ReviewRecord.Decision) -> String {
    switch decision {
    case .approved: "checkmark.circle.fill"
    case .rejected: "xmark.circle.fill"
    case .reviewed: "checkmark.circle"
    }
  }

  private func reviewColor(_ decision: ParallelWorktreeExecution.ReviewRecord.Decision) -> Color {
    switch decision {
    case .approved: .green
    case .rejected: .red
    case .reviewed: .orange
    }
  }

  private func formatDuration(_ interval: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: interval) ?? ""
  }
}

// MARK: - Full Step Output Sheet

struct FullStepOutputSheet: View {
  let step: ParallelWorktreeExecution.ChainStepSummary
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 8) {
            Text(step.stepName)
              .font(.headline)
            Text(step.role)
              .font(.caption)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(.secondary.opacity(0.15)))
            Text(step.model)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Text(step.outputPreview)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(step.outputPreview, forType: .string)
            #else
            UIPasteboard.general.string = step.outputPreview
            #endif
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
        }
      }
    }
    .frame(minWidth: 500, minHeight: 400)
  }
}
