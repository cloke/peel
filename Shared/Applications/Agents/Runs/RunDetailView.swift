import SwiftUI

struct RunDetailView: View {
  @Bindable var run: ParallelWorktreeRun
  let runManager: RunManager
  let runner: ParallelWorktreeRunner?
  @Binding var selectedExecution: ParallelWorktreeExecution?
  @State private var expandedExecutions = Set<UUID>()
  @State private var showingCancelConfirmation = false
  @State private var mergeError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        runHeader
        Divider()
        if let ctx = run.prContext {
          prContextSection(ctx)
          Divider()
        }
        if !run.prompt.isEmpty {
          promptSection
          Divider()
        }
        progressOverview
        if run.kind == .managerRun {
          Divider()
          childRunsSection
        }
        Divider()
        actionButtons
        Divider()
        executionsList
      }
      .padding()
    }
    .navigationTitle(run.name)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if run.status == .pending {
          Button("Start") {
            Task { try? await runManager.startRun(run) }
          }
        }
        if run.status == .running || run.status == .awaitingReview {
          Button("Cancel", role: .destructive) {
            showingCancelConfirmation = true
          }
        }
      }
    }
    .confirmationDialog("Cancel Run?", isPresented: $showingCancelConfirmation) {
      Button("Cancel Run", role: .destructive) {
        Task { await runManager.stopRun(run) }
      }
    } message: {
      Text("This will cancel all pending tasks and cleanup worktrees.")
    }
  }

  // MARK: - Header

  @ViewBuilder
  private var runHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        kindBadge
        Text(run.status.displayName)
          .font(.callout.weight(.medium))
          .foregroundStyle(statusColor)
        if run.isPaused {
          Text("PAUSED")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.yellow.opacity(0.2), in: Capsule())
            .foregroundStyle(.yellow)
        }
        Spacer()
        Text(run.createdAt, style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ViewThatFits(in: .horizontal) {
        HStack {
          headerField("Project", value: run.projectPath, mono: true)
          Spacer()
          headerField("Base Branch", value: run.baseBranch, mono: true, trailing: true)
        }
        VStack(alignment: .leading, spacing: 8) {
          headerField("Project", value: run.projectPath, mono: true)
          headerField("Base Branch", value: run.baseBranch, mono: true)
        }
      }

      if let templateName = run.templateName {
        HStack {
          Text("Template")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(templateName)
            .font(.caption.monospaced())
        }
      }
    }
  }

  @ViewBuilder
  private func headerField(
    _ label: String,
    value: String,
    mono: Bool = false,
    trailing: Bool = false
  ) -> some View {
    VStack(alignment: trailing ? .trailing : .leading) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(mono ? .system(.body, design: .monospaced) : .body)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var kindBadge: some View {
    Text(run.kind.shortLabel)
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(run.kind.badgeColor.opacity(0.15), in: Capsule())
      .foregroundStyle(run.kind.badgeColor)
  }

  private var statusColor: Color {
    switch run.status {
    case .completed: .green
    case .awaitingReview: .orange
    case .failed: .red
    case .cancelled: .secondary
    default: .primary
    }
  }

  // MARK: - PR Context

  @ViewBuilder
  private func prContextSection(_ ctx: PRRunContext) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Pull Request", systemImage: "arrow.triangle.pull")
        .font(.headline)

      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 2) {
          Text("#\(ctx.prNumber)")
            .font(.title3.weight(.semibold))
          Text(ctx.prTitle)
            .font(.callout)
            .lineLimit(2)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 2) {
          Text("Phase")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(PRReviewPhase.displayName[ctx.phase] ?? ctx.phase.capitalized)
            .font(.callout.weight(.medium))
            .foregroundStyle(phaseColor(ctx.phase))
        }
      }

      HStack(spacing: 16) {
        if let verdict = ctx.reviewVerdict {
          Label(verdict.capitalized, systemImage: verdictIcon(verdict))
            .font(.caption)
            .foregroundStyle(verdictColor(verdict))
        }
        Text("\(ctx.repoOwner)/\(ctx.repoName)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        Text(ctx.headRef)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
  }

  private func phaseColor(_ phase: String) -> Color {
    switch phase {
    case PRReviewPhase.approved, PRReviewPhase.pushed: .green
    case PRReviewPhase.needsFix, PRReviewPhase.fixing: .orange
    case PRReviewPhase.failed: .red
    default: .primary
    }
  }

  private func verdictIcon(_ verdict: String) -> String {
    switch verdict {
    case "approved": "checkmark.seal.fill"
    case "needsChanges": "pencil.circle.fill"
    case "rejected": "xmark.circle.fill"
    default: "questionmark.circle"
    }
  }

  private func verdictColor(_ verdict: String) -> Color {
    switch verdict {
    case "approved": .green
    case "needsChanges": .orange
    case "rejected": .red
    default: .secondary
    }
  }

  // MARK: - Prompt

  @ViewBuilder
  private var promptSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Prompt")
        .font(.headline)
      Text(run.prompt)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  // MARK: - Progress

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
        if run.hungExecutionCount > 0 {
          statBox(title: "Hung", value: "\(run.hungExecutionCount)", color: .red)
        }
      }

      ProgressView(value: run.progress)
        .progressViewStyle(.linear)

      if run.totalFilesChanged > 0 {
        HStack(spacing: 16) {
          Label("\(run.totalFilesChanged) files changed", systemImage: "doc")
          Label("+\(run.totalInsertions)", systemImage: "plus")
            .foregroundStyle(.green)
          Label("-\(run.totalDeletions)", systemImage: "minus")
            .foregroundStyle(.red)
        }
        .font(.caption)
      }
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

  // MARK: - Actions

  @ViewBuilder
  private var actionButtons: some View {
    HStack(spacing: 12) {
      if run.isPaused {
        Button {
          Task { try? await runManager.resumeRun(run) }
        } label: {
          Label("Resume", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
      } else if run.status == .running {
        Button {
          runManager.pauseRun(run)
        } label: {
          Label("Pause", systemImage: "pause.fill")
        }
        .buttonStyle(.bordered)
      }

      if run.pendingReviewCount > 0, let runner {
        Button {
          runner.approveAllPending(in: run)
        } label: {
          Label("Approve All", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
      }

      if run.readyToMergeCount > 0, let runner {
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

      Toggle("Auto-Merge", isOn: Binding(
        get: { run.autoMergeOnApproval },
        set: { run.autoMergeOnApproval = $0 }
      ))
      .toggleStyle(.switch)
    }
  }

  // MARK: - Child Runs (Manager)

  @ViewBuilder
  private var childRunsSection: some View {
    let children = runManager.childRuns(of: run.id)
    let stats = runManager.childRunStats(of: run.id)

    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Child Runs", systemImage: "rectangle.stack")
          .font(.headline)
        Spacer()
        if stats.total > 0 {
          HStack(spacing: 8) {
            if stats.running > 0 {
              Label("\(stats.running)", systemImage: "circle.dotted")
                .foregroundStyle(.blue)
            }
            if stats.needsReview > 0 {
              Label("\(stats.needsReview)", systemImage: "eye.circle.fill")
                .foregroundStyle(.orange)
            }
            if stats.completed > 0 {
              Label("\(stats.completed)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
            if stats.failed > 0 {
              Label("\(stats.failed)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
            }
          }
          .font(.caption)
        }
      }

      if children.isEmpty {
        Text("No child runs spawned yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(children) { child in
          childRunCard(child)
        }
      }

      // Overall child progress
      if stats.total > 0 {
        let progress = Double(stats.completed) / Double(stats.total)
        HStack(spacing: 8) {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
          Text("\(stats.completed)/\(stats.total) complete")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private func childRunCard(_ child: ParallelWorktreeRun) -> some View {
    HStack(spacing: 8) {
      childStatusIcon(child.status)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(child.kind.shortLabel)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(child.kind.badgeColor.opacity(0.15), in: Capsule())
            .foregroundStyle(child.kind.badgeColor)
          Text(child.name)
            .fontWeight(.medium)
            .lineLimit(1)
        }
        if !child.prompt.isEmpty {
          Text(child.prompt)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack(spacing: 12) {
          Text(child.status.displayName)
            .font(.caption)
            .foregroundStyle(childStatusColor(child.status))
          if child.totalFilesChanged > 0 {
            Text("\(child.totalFilesChanged) files")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if child.executions.count > 0 {
            Text("\(child.executions.count) exec\(child.executions.count == 1 ? "" : "s")")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer()
      ProgressView(value: child.progress)
        .progressViewStyle(.linear)
        .frame(maxWidth: 60)
    }
    .padding(8)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func childStatusIcon(_ status: ParallelWorktreeRun.RunStatus) -> some View {
    switch status {
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

  private func childStatusColor(_ status: ParallelWorktreeRun.RunStatus) -> Color {
    switch status {
    case .completed: .green
    case .awaitingReview: .orange
    case .failed: .red
    case .cancelled: .secondary
    default: .primary
    }
  }

  // MARK: - Executions

  @ViewBuilder
  private var executionsList: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Executions")
        .font(.headline)

      if let runner {
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
      } else {
        ForEach(run.executions) { execution in
          readOnlyExecutionRow(execution)
        }
      }
    }
  }

  @ViewBuilder
  private func readOnlyExecutionRow(_ execution: ParallelWorktreeExecution) -> some View {
    HStack {
      Image(systemName: executionStatusIcon(execution.status))
        .foregroundStyle(executionStatusColor(execution.status))
      VStack(alignment: .leading) {
        Text(execution.task.title)
          .fontWeight(.medium)
        Text(execution.status.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if execution.filesChanged > 0 {
        Text("\(execution.filesChanged) files")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(8)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func executionStatusIcon(_ status: ParallelWorktreeStatus) -> String {
    switch status {
    case .pending, .waitingForDependencies: "clock"
    case .creatingWorktree, .running: "circle.dotted"
    case .awaitingReview: "eye.circle.fill"
    case .reviewed: "checkmark.circle"
    case .approved: "checkmark.circle.fill"
    case .conflicted: "exclamationmark.triangle.fill"
    case .rejected: "xmark.circle.fill"
    case .merging: "arrow.triangle.merge"
    case .merged: "checkmark.seal.fill"
    case .failed: "xmark.circle.fill"
    case .cancelled: "slash.circle.fill"
    }
  }

  private func executionStatusColor(_ status: ParallelWorktreeStatus) -> Color {
    switch status {
    case .pending, .waitingForDependencies, .cancelled: .secondary
    case .creatingWorktree, .running, .merging: .blue
    case .awaitingReview: .orange
    case .reviewed: .purple
    case .approved, .merged: .green
    case .conflicted: .orange
    case .rejected, .failed: .red
    }
  }
}
