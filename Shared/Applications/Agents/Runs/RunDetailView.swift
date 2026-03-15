import SwiftUI

struct RunDetailView: View {
  @Bindable var run: ParallelWorktreeRun
  let runManager: RunManager
  let runner: ParallelWorktreeRunner?
  var mcpServer: MCPServerService?
  @Binding var selectedExecution: ParallelWorktreeExecution?
  @AppStorage("activity.automationExpandExecution") private var automationExpandExecution = ""
  @State private var expandedExecutions = Set<UUID>()
  @State private var showingCancelConfirmation = false
  @State private var mergeError: String?
  @State private var showRawOutput = false
  @State private var prActionInProgress: String?
  @State private var prActionResult: String?
  @State private var prActionError: String?
  @State private var fixRunId: String?
  @State private var isPushing = false
  @State private var pushResult: String?
  @State private var pushError: String?
  @State private var followUpPrompt = ""
  @State private var followUpRunId: String?
  @State private var isDispatchingFollowUp = false
  @State private var followUpError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        runHeader
        if let ctx = run.prContext {
          Divider()
          prContextSection(ctx)
          // PR actions immediately after context (approve/request changes/comment)
          if isPRReview {
            Divider()
            actionButtons
          }
        }
        // Show parsed review whenever output has structured content (JSON with summary/issues)
        if let output = bestOutput, !output.isEmpty, outputHasStructuredContent(output) {
          Divider()
          parsedReviewSection(output)
          if !isPRReview {
            Divider()
            actionButtons
          }
        } else {
          if !isPRReview {
            Divider()
            actionButtons
          }
          if let output = bestOutput, !output.isEmpty {
            Divider()
            rawOutputSection(output)
          }
        }
        Divider()
        progressOverview
        Divider()
        executionsList
        if run.kind == .managerRun {
          Divider()
          childRunsSection
        }
        if !isPRReview, !run.prompt.isEmpty {
          Divider()
          promptSection
        }
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
    .onChange(of: automationExpandExecution) { _, newValue in
      guard !newValue.isEmpty else { return }
      defer { automationExpandExecution = "" }
      if newValue == "all" {
        expandedExecutions = Set(run.executions.map(\.id))
      } else if newValue == "none" {
        expandedExecutions.removeAll()
      } else if let uuid = UUID(uuidString: newValue) {
        if expandedExecutions.contains(uuid) {
          expandedExecutions.remove(uuid)
        } else {
          expandedExecutions.insert(uuid)
        }
      }
    }
  }

  // MARK: - Header

  @ViewBuilder
  private var runHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        kindBadge
        Text(run.status.displayName(kind: run.kind, prContext: run.prContext))
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
    let lowered = verdict.lowercased()
    if lowered.contains("approve") { return "checkmark.seal.fill" }
    if lowered.contains("reject") || lowered.contains("request") || lowered.contains("change") { return "pencil.circle.fill" }
    return "questionmark.circle"
  }

  private func verdictColor(_ verdict: String) -> Color {
    let lowered = verdict.lowercased()
    if lowered.contains("approve") || lowered.contains("pass") { return .green }
    if lowered.contains("reject") || lowered.contains("fail") || lowered.contains("request_changes") { return .red }
    return .orange
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

  // MARK: - Output

  /// Prefer PR review output (the actual review) over raw execution output (tool call log)
  private var bestOutput: String? {
    if let reviewOutput = run.prContext?.reviewOutput, !reviewOutput.isEmpty {
      return reviewOutput
    }
    return run.executions.first?.output
  }

  @ViewBuilder
  private func parsedReviewSection(_ output: String) -> some View {
    let parsed = parseReviewOutput(output)
    VStack(alignment: .leading, spacing: 16) {
      Text("Agent Review")
        .font(.headline)

      ReviewOutputView(parsed: parsed)

      // Follow-up Actions
      followUpActionsSection(parsed: parsed)
    }
  }

  @ViewBuilder
  private func rawOutputSection(_ output: String) -> some View {
    let parsed = parseReviewOutput(output)
    VStack(alignment: .leading, spacing: 12) {
      if parsed.hasStructuredContent {
        Text("Agent Review")
          .font(.headline)
        ReviewOutputView(parsed: parsed)
        followUpActionsSection(parsed: parsed)
      } else {
        // Never dump raw JSON/text inline — show a summary + disclosure
        Text("Agent Output")
          .font(.headline)
        if !parsed.summary.isEmpty, parsed.summary != String(output.prefix(500)) {
          Text(parsed.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        DisclosureGroup("View Full Output") {
          Text(output)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
      }
    }
  }

  // MARK: - Output Helpers

  private func outputHasStructuredContent(_ output: String) -> Bool {
    parseReviewOutput(output).hasStructuredContent
  }

  private func extractContentAfterSteps(from output: String) -> String {
    let lines = output.components(separatedBy: "\n")
    var lastStepIndex = -1
    for (i, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("●") || trimmed.hasPrefix("•") || trimmed.hasPrefix("└") {
        lastStepIndex = i
      }
    }
    if lastStepIndex >= 0, lastStepIndex + 1 < lines.count {
      let remaining = lines[(lastStepIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      return remaining
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
  }

  // MARK: - Progress

  private var isPRReview: Bool { run.kind == .prReview }

  private var fixChain: AgentChain? {
    guard let rid = fixRunId, let uuid = UUID(uuidString: rid),
          let run = runner?.findRunBySourceChainRunId(uuid),
          let cid = run.executions.first?.chainId
    else { return nil }
    return mcpServer?.agentManager.chains.first { $0.id == cid }
  }

  private var fixWorktreeRun: ParallelWorktreeRun? {
    guard let rid = fixRunId, let uuid = UUID(uuidString: rid) else { return nil }
    return runner?.findRunBySourceChainRunId(uuid)
  }

  @ViewBuilder
  private var progressOverview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Progress")
        .font(.headline)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 12) {
        statBox(title: "Total", value: "\(run.executions.count)", color: .primary)
        statBox(title: "Running", value: "\(run.activeCount)", color: .primary)
        statBox(title: isPRReview ? "Pending" : "Pending Review", value: "\(run.pendingReviewCount)", color: .orange)
        statBox(title: "Reviewed", value: "\(run.reviewedCount)", color: .purple)
        statBox(title: isPRReview ? "Ready to Approve" : "Ready to Merge", value: "\(run.readyToMergeCount)", color: .green)
        if !isPRReview {
          statBox(title: "Merged", value: "\(run.mergedCount)", color: .blue)
        }
        statBox(title: "Rejected", value: "\(run.rejectedCount)", color: .red)
        statBox(title: "Failed", value: "\(run.failedCount)", color: .red)
        if run.cancelledCount > 0 {
          statBox(title: "Cancelled", value: "\(run.cancelledCount)", color: .secondary)
        }
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
    VStack(alignment: .leading, spacing: 12) {
      if isPRReview {
        prReviewActions
      } else {
        codeChangeActions
      }
    }
  }

  @ViewBuilder
  private var prReviewActions: some View {
    HStack(spacing: 12) {
      // Confirmation gate: the review agent is done, waiting for user to approve posting
      if let gateExecution = run.executions.first(where: { $0.status == .awaitingConfirmation }) {
        Button {
          Task { await runManager.confirmExecution(gateExecution) }
        } label: {
          Label("Confirm & Post Review", systemImage: "paperplane.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .help("Advance past the confirmation gate and post the review to GitHub")
      }

      if run.isPaused {
        Button {
          Task { try? await runManager.resumeRun(run) }
        } label: {
          Label("Resume", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
      } else if run.status == .running && !run.executions.contains(where: { $0.status == .awaitingConfirmation }) {
        Button {
          runManager.pauseRun(run)
        } label: {
          Label("Pause", systemImage: "pause.fill")
        }
        .buttonStyle(.bordered)
      }

      if let ctx = run.prContext, run.readyToMergeCount > 0 {
        Button {
          Task { await postGitHubReview(ctx: ctx, event: "APPROVE", body: "Approved via Peel agent review.") }
        } label: {
          Label(prActionInProgress == "APPROVE" ? "Approving..." : "Approve PR", systemImage: "checkmark.seal.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .disabled(prActionInProgress != nil)

        Button {
          Task { await postGitHubReview(ctx: ctx, event: "REQUEST_CHANGES", body: reviewBodyForRequestChanges()) }
        } label: {
          Label(prActionInProgress == "REQUEST_CHANGES" ? "Posting..." : "Request Changes", systemImage: "exclamationmark.bubble")
        }
        .buttonStyle(.bordered)
        .disabled(prActionInProgress != nil)

        Button {
          Task { await postGitHubReview(ctx: ctx, event: "COMMENT", body: reviewBodyForComment()) }
        } label: {
          Label(prActionInProgress == "COMMENT" ? "Posting..." : "Comment", systemImage: "text.bubble")
        }
        .buttonStyle(.bordered)
        .disabled(prActionInProgress != nil)
      }

      Spacer()

      if let result = prActionResult {
        Label(result, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }
      if let error = prActionError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(3)
      }
    }
  }

  @ViewBuilder
  private var codeChangeActions: some View {
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

        Button {
          mergeError = nil
          Task {
            do {
              for execution in run.executions where execution.status == .awaitingReview {
                try await runner.approveAndMergeExecution(execution, in: run)
              }
            } catch {
              mergeError = error.localizedDescription
            }
          }
        } label: {
          Label("Approve All & Merge", systemImage: "checkmark.seal")
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
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

  // MARK: - GitHub PR Actions

  private func postGitHubReview(ctx: PRRunContext, event: String, body: String) async {
    guard let handler = mcpServer?.githubToolsHandler else {
      prActionError = "GitHub handler unavailable"
      return
    }

    prActionInProgress = event
    prActionResult = nil
    prActionError = nil

    let arguments: [String: Any] = [
      "owner": ctx.repoOwner,
      "repo": ctx.repoName,
      "pull_number": ctx.prNumber,
      "event": event,
      "body": body,
    ]

    let (_, data) = await handler.handle(name: "github.pr.review.create", id: nil, arguments: arguments)
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let errorObj = json["error"] as? [String: Any],
       let msg = errorObj["message"] as? String {
      prActionError = msg
    } else {
      switch event {
      case "APPROVE": prActionResult = "PR Approved"
      case "REQUEST_CHANGES": prActionResult = "Changes Requested"
      default: prActionResult = "Comment Posted"
      }
    }
    prActionInProgress = nil
  }

  private func reviewBodyForRequestChanges() -> String {
    guard let output = bestOutput else { return "Changes requested via Peel agent review." }
    let parsed = parseReviewOutput(output)
    if !parsed.issues.isEmpty {
      return "Issues found by agent review:\n\n" + parsed.issues.map { "- \($0)" }.joined(separator: "\n")
    }
    return parsed.summary.isEmpty ? "Changes requested via Peel agent review." : parsed.summary
  }

  private func reviewBodyForComment() -> String {
    guard let output = bestOutput else { return "Review comment via Peel." }
    let parsed = parseReviewOutput(output)
    return parsed.summary.isEmpty ? "Review comment via Peel." : parsed.summary
  }

  // MARK: - Fix / Push Workflow

  private func dispatchFix(issues: [String]) async {
    guard let ctx = run.prContext else { return }
    let workDir = run.projectPath

    let issuesList = issues.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    let rawContext = bestOutput ?? ""

    let prompt = """
    Fix the issues found in PR #\(ctx.prNumber) for \(ctx.repoOwner)/\(ctx.repoName).
    Repository owner: \(ctx.repoOwner)
    Repository name: \(ctx.repoName)
    PR number: \(ctx.prNumber)
    IMPORTANT: Before making any changes, use `github.pr.files` with \
    owner="\(ctx.repoOwner)", repo="\(ctx.repoName)", pull_number=\(ctx.prNumber) to get \
    the actual list of changed files and their patches from the PR. Only \
    modify files that are part of the PR — do NOT grep for similar code elsewhere.

    Issues to fix:
    \(issuesList)

    Full review context:
    \(rawContext)

    Instructions:
    - Fix each issue in the file where it was found.
    - Create a new commit that addresses these issues.
    - Focus on code quality and correctness.
    """

    var arguments: [String: Any] = [
      "prompt": prompt,
      "workingDirectory": workDir,
      "returnImmediately": true,
      "chainSpec": [
        "name": "Fix PR Issues",
        "description": "Fix issues found during PR review",
        "steps": [["role": "implementer", "model": "claude-sonnet-4.6", "name": "Fix Issues"]],
      ] as [String: Any],
    ]
    arguments["baseBranch"] = ctx.headRef

    guard let mcpServer else { return }
    let (_, data) = await mcpServer.handleChainRun(id: nil, arguments: arguments)

    if let resultDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      let chainData = resultDict["chainData"] as? [String: Any]
      let queueData = chainData?["queue"] as? [String: Any]
      let runId = (chainData?["runId"] as? String) ?? (queueData?["runId"] as? String)
      if let runId {
        fixRunId = runId
        if let qi = mcpServer.prReviewQueue.find(
          repoOwner: ctx.repoOwner, repoName: ctx.repoName, prNumber: ctx.prNumber
        ) {
          mcpServer.prReviewQueue.markFixing(qi, chainId: runId)
        }
      }
    }
  }

  private func pushFix() async {
    guard let ctx = run.prContext,
          let runner,
          let fwr = fixWorktreeRun,
          let execution = fwr.executions.first
    else {
      pushError = "Cannot push — missing worktree run or PR head ref"
      return
    }

    isPushing = true
    pushError = nil
    pushResult = nil

    if let qi = mcpServer?.prReviewQueue.find(
      repoOwner: ctx.repoOwner, repoName: ctx.repoName, prNumber: ctx.prNumber
    ) {
      mcpServer?.prReviewQueue.markPushing(qi)
    }

    let (output, exitCode) = await runner.pushExecutionBranch(execution, toRemoteRef: ctx.headRef, in: fwr)

    if exitCode == 0 {
      pushResult = "Pushed to origin/\(ctx.headRef)"
      if let qi = mcpServer?.prReviewQueue.find(
        repoOwner: ctx.repoOwner, repoName: ctx.repoName, prNumber: ctx.prNumber
      ) {
        mcpServer?.prReviewQueue.markPushed(qi, result: pushResult!)
      }
    } else {
      pushError = "Push failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
      if let qi = mcpServer?.prReviewQueue.find(
        repoOwner: ctx.repoOwner, repoName: ctx.repoName, prNumber: ctx.prNumber
      ) {
        mcpServer?.prReviewQueue.markFailed(qi, error: pushError!)
      }
    }

    isPushing = false
  }

  // MARK: - Follow-up Actions

  private var followUpChain: AgentChain? {
    guard let rid = followUpRunId, let uuid = UUID(uuidString: rid),
          let run = runner?.findRunBySourceChainRunId(uuid),
          let cid = run.executions.first?.chainId
    else { return nil }
    return mcpServer?.agentManager.chains.first { $0.id == cid }
  }

  private var followUpWorktreeRun: ParallelWorktreeRun? {
    guard let rid = followUpRunId, let uuid = UUID(uuidString: rid) else { return nil }
    return runner?.findRunBySourceChainRunId(uuid)
  }

  @ViewBuilder
  private func followUpActionsSection(parsed: ParsedReview) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      // Active fix/follow-up chain status
      if let chain = fixChain {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Fix chain: \(chain.state.displayName)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let chain = followUpChain {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Follow-up chain: \(chain.state.displayName)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      // Push button for completed fix/follow-up
      let completedRun = fixWorktreeRun ?? followUpWorktreeRun
      if let fwr = completedRun,
         (fwr.status == .completed || fwr.status == .awaitingReview),
         isPRReview, run.prContext?.headRef != nil {
        Button {
          Task { await pushFix() }
        } label: {
          Label(isPushing ? "Pushing…" : "Push Fix", systemImage: "arrow.up.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isPushing)
      }

      if let result = pushResult {
        Label(result, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }
      if let error = pushError {
        Label(error, systemImage: "xmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }

      // Quick action buttons (only when no chain is running)
      if fixRunId == nil, followUpRunId == nil {
        HStack(spacing: 8) {
          if !parsed.issues.isEmpty, isPRReview {
            Button {
              Task { await dispatchFix(issues: parsed.issues) }
            } label: {
              Label("Fix Issues", systemImage: "wrench.fill")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
          }

          if !parsed.suggestions.isEmpty {
            Button {
              let items = parsed.suggestions.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
              followUpPrompt = "Implement these suggestions:\n\(items)"
            } label: {
              Label("Implement Suggestions", systemImage: "lightbulb.fill")
            }
            .buttonStyle(.bordered)
            .tint(.blue)
          }
        }

        // Custom follow-up prompt
        VStack(alignment: .leading, spacing: 6) {
          Text("Follow-up Instructions")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextEditor(text: $followUpPrompt)
            .font(.callout)
            .frame(minHeight: 60, maxHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
            )
          HStack {
            Button {
              guard !followUpPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
              Task { await dispatchFollowUp(prompt: followUpPrompt) }
            } label: {
              Label(isDispatchingFollowUp ? "Dispatching…" : "Run Follow-up", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(followUpPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDispatchingFollowUp)

            Spacer()
          }
        }
      }

      if let error = followUpError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private func dispatchFollowUp(prompt userPrompt: String) async {
    isDispatchingFollowUp = true
    followUpError = nil

    let workDir = run.projectPath
    let rawContext = bestOutput ?? ""

    var prompt: String
    if let ctx = run.prContext {
      prompt = """
      Follow-up work for PR #\(ctx.prNumber) in \(ctx.repoOwner)/\(ctx.repoName).
      Repository owner: \(ctx.repoOwner)
      Repository name: \(ctx.repoName)
      PR number: \(ctx.prNumber)
      IMPORTANT: Before making any changes, use `github.pr.files` with \
      owner="\(ctx.repoOwner)", repo="\(ctx.repoName)", pull_number=\(ctx.prNumber) to get \
      the actual list of changed files and their patches from the PR. Only \
      modify files that are part of the PR — do NOT grep for similar code elsewhere.

      Original review context:
      \(rawContext)

      Follow-up instructions:
      \(userPrompt)
      """
    } else {
      prompt = """
      Follow-up work for agent run in \(workDir).

      Original output:
      \(rawContext)

      Follow-up instructions:
      \(userPrompt)
      """
    }

    var arguments: [String: Any] = [
      "prompt": prompt,
      "workingDirectory": workDir,
      "returnImmediately": true,
      "chainSpec": [
        "name": "Follow-up",
        "description": "Implement follow-up changes from review",
        "steps": [["role": "implementer", "model": "claude-sonnet-4.6", "name": "Implement Changes"]],
      ] as [String: Any],
    ]
    if let ctx = run.prContext {
      arguments["baseBranch"] = ctx.headRef
    }

    guard let mcpServer else {
      followUpError = "MCP server unavailable"
      isDispatchingFollowUp = false
      return
    }

    let (_, data) = await mcpServer.handleChainRun(id: nil, arguments: arguments)

    if let resultDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      let chainData = resultDict["chainData"] as? [String: Any]
      let queueData = chainData?["queue"] as? [String: Any]
      let runId = (chainData?["runId"] as? String) ?? (queueData?["runId"] as? String)
      if let runId {
        followUpRunId = runId
        followUpPrompt = ""
        if isPRReview, let ctx = run.prContext,
           let qi = mcpServer.prReviewQueue.find(
             repoOwner: ctx.repoOwner, repoName: ctx.repoName, prNumber: ctx.prNumber
           ) {
          mcpServer.prReviewQueue.markFixing(qi, chainId: runId)
        }
      } else {
        followUpError = "Failed to start follow-up chain"
      }
    } else {
      followUpError = "Failed to parse chain response"
    }

    isDispatchingFollowUp = false
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
          Text(child.status.displayName(kind: child.kind, prContext: child.prContext))
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
    case .awaitingConfirmation: "pause.circle.fill"
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
    case .awaitingConfirmation: .yellow
    case .reviewed: .purple
    case .approved, .merged: .green
    case .conflicted: .orange
    case .rejected, .failed: .red
    }
  }
}
