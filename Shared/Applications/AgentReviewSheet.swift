//
//  AgentReviewSheet.swift
//  Peel
//
//  Fresh PR review agent sheet. Shows chain progress, prompt/response,
//  and lets the user approve, comment, or request changes on GitHub.
//

import Github
import MCPCore
import SwiftUI

// MARK: - Target

/// Everything needed to present a review for a PR.
struct AgentReviewTarget: Identifiable {
  let id = UUID()
  let prNumber: Int
  let prTitle: String
  let ownerRepo: String
  let headRef: String?
  let htmlURL: String?
  /// Optional local clone path. Resolved lazily if nil.
  var localPath: String?
}

// MARK: - Sheet

struct AgentReviewSheet: View {
  let target: AgentReviewTarget
  @Environment(MCPServerService.self) private var mcp
  @Environment(\.dismiss) private var dismiss

  // Run lifecycle
  @State private var phase: Phase = .ready
  @State private var runId: String?
  @State private var selectedTemplate: ReviewTemplate = .standard

  // Parsed result
  @State private var result: ParsedReview?
  @State private var rawOutput: String = ""

  // GitHub posting
  @State private var postingAction: String?
  @State private var postResult: String?
  @State private var postError: String?

  // Fix chain
  @State private var fixRunId: String?
  @State private var isPushing = false
  @State private var pushResult: String?
  @State private var pushError: String?

  // Prompt visibility
  @State private var showPrompt = false

  enum Phase: Equatable {
    case ready
    case running
    case completed
    case failed(String)
  }

  enum ReviewTemplate: String, CaseIterable, Identifiable {
    case standard = "PR Review"
    case deep = "Deep PR Review"
    var id: String { rawValue }
    var templateId: String {
      switch self {
      case .standard: return "A0000001-0007-4000-8000-000000000007"
      case .deep: return "A0000001-0011-4000-8000-000000000011"
      }
    }
    var subtitle: String {
      switch self {
      case .standard: return "Quick single-pass review"
      case .deep: return "Multi-step deep analysis"
      }
    }
  }

  // MARK: - Computed chain lookup

  private var activeChain: AgentChain? {
    guard let rid = runId, let uuid = UUID(uuidString: rid),
          let run = mcp.parallelWorktreeRunner?.findRunBySourceChainRunId(uuid),
          let cid = run.executions.first?.chainId
    else { return nil }
    return mcp.agentManager.chains.first { $0.id == cid }
  }

  private var worktreeRun: ParallelWorktreeRun? {
    guard let rid = runId, let uuid = UUID(uuidString: rid) else { return nil }
    return mcp.parallelWorktreeRunner?.findRunBySourceChainRunId(uuid)
  }

  private var fixChain: AgentChain? {
    guard let rid = fixRunId, let uuid = UUID(uuidString: rid),
          let run = mcp.parallelWorktreeRunner?.findRunBySourceChainRunId(uuid),
          let cid = run.executions.first?.chainId
    else { return nil }
    return mcp.agentManager.chains.first { $0.id == cid }
  }

  private var fixWorktreeRun: ParallelWorktreeRun? {
    guard let rid = fixRunId, let uuid = UUID(uuidString: rid) else { return nil }
    return mcp.parallelWorktreeRunner?.findRunBySourceChainRunId(uuid)
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          switch phase {
          case .ready:
            readySection
          case .running:
            runningSection
          case .completed:
            completedSection
          case .failed(let msg):
            failedSection(msg)
          }
        }
        .padding(20)
      }
    }
    .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 640)
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Agent PR Review")
          .font(.headline)
        Text(verbatim: "#\(target.prNumber) — \(target.prTitle)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button { dismiss() } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.title2)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: - Ready (pre-start)

  private var readySection: some View {
    VStack(spacing: 16) {
      // Template picker
      VStack(alignment: .leading, spacing: 8) {
        Text("Review Type")
          .font(.subheadline)
          .fontWeight(.semibold)
        Picker("Template", selection: $selectedTemplate) {
          ForEach(ReviewTemplate.allCases) { t in
            Text(t.rawValue).tag(t)
          }
        }
        .pickerStyle(.segmented)
        Text(selectedTemplate.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(12)
      .background(.quaternary.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: 10))

      // PR info card
      prInfoCard

      // Start button
      Button {
        Task { await startReview() }
      } label: {
        Label("Start Agent Review", systemImage: "sparkles")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
  }

  private var prInfoCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(target.prTitle, systemImage: "arrow.triangle.pull")
        .font(.callout)
        .fontWeight(.medium)
        .lineLimit(2)
      HStack(spacing: 8) {
        Text(target.ownerRepo)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("#\(target.prNumber)")
          .font(.caption)
          .monospacedDigit()
        Circle().fill(.green).frame(width: 7, height: 7)
        Text("Open")
          .font(.caption)
          .foregroundStyle(.green)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Running

  private var runningSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Chain phase indicator
      if let chain = activeChain {
        chainProgressView(chain)
      } else {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Starting review chain…")
            .foregroundStyle(.secondary)
        }
      }

      // Prompt disclosure
      promptDisclosure

      // Live status messages
      if let chain = activeChain, !chain.liveStatusMessages.isEmpty {
        liveStatusList(chain.liveStatusMessages)
      }
    }
  }

  private func chainProgressView(_ chain: AgentChain) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text(chain.state.displayName)
          .font(.headline)
      }

      // Step progress
      if !chain.agents.isEmpty {
        let total = chain.agents.count
        let current = chain.currentAgentIndex
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: Double(min(current + 1, total)), total: Double(total))
            .tint(.blue)
          Text("Step \(min(current + 1, total)) of \(total)")
            .font(.caption)
            .foregroundStyle(.secondary)
          if current < chain.agents.count {
            Text(chain.agents[current].name)
              .font(.caption)
              .fontWeight(.medium)
          }
        }
      }

      // Elapsed time
      if let start = chain.runStartTime {
        Text("Elapsed: \(elapsedString(from: start))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private var promptDisclosure: some View {
    DisclosureGroup("Review Prompt", isExpanded: $showPrompt) {
      Text(buildPrompt())
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .font(.subheadline)
    .fontWeight(.medium)
  }

  private func liveStatusList(_ messages: [LiveStatusMessage]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Activity")
        .font(.subheadline)
        .fontWeight(.semibold)
      ForEach(messages.suffix(8)) { msg in
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: msg.type.icon)
            .font(.caption2)
            .foregroundStyle(msg.type.color)
            .frame(width: 14)
          Text(msg.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Spacer()
          Text(msg.timestamp, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Completed

  private var completedSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let result {
        verdictBanner(result)
        summarySection(result)
        if !result.issues.isEmpty { issuesSection(result.issues) }
        if !result.suggestions.isEmpty { suggestionsSection(result.suggestions) }
        Divider()
        actionButtons(result)

        // Fix chain status (if running)
        if fixRunId != nil { fixChainSection }

        // Post feedback
        if let postResult {
          Label(postResult, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        }
        if let postError {
          Label(postError, systemImage: "xmark.circle")
            .font(.caption)
            .foregroundStyle(.red)
        }
      } else {
        // Completed but no parsed result
        Text("Review completed but could not parse the result.")
          .foregroundStyle(.secondary)
      }

      // Raw output disclosure
      if !rawOutput.isEmpty {
        DisclosureGroup("Raw Response") {
          Text(rawOutput)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .font(.subheadline)
        .fontWeight(.medium)
      }

      // Prompt disclosure
      promptDisclosure
    }
  }

  private func verdictBanner(_ r: ParsedReview) -> some View {
    HStack(spacing: 10) {
      Image(systemName: r.verdict.systemImage)
        .font(.title2)
        .foregroundStyle(r.verdict.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(r.verdict.displayName)
          .font(.headline)
        if let ci = r.ciStatus {
          Text("CI: \(ci)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      riskBadge(r.riskLevel)
    }
    .padding(12)
    .background(r.verdict.color.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private func summarySection(_ r: ParsedReview) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Summary")
        .font(.subheadline)
        .fontWeight(.semibold)
      Text(r.summary)
        .font(.callout)
        .textSelection(.enabled)
    }
  }

  private func issuesSection(_ issues: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Issues (\(issues.count))", systemImage: "exclamationmark.triangle")
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(.orange)
      ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "circle.fill")
            .font(.system(size: 5))
            .foregroundStyle(.orange)
            .padding(.top, 6)
          Text(issue)
            .font(.callout)
            .textSelection(.enabled)
        }
      }
    }
    .padding(12)
    .background(.orange.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private func suggestionsSection(_ suggestions: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Suggestions (\(suggestions.count))", systemImage: "lightbulb")
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(.blue)
      ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "circle.fill")
            .font(.system(size: 5))
            .foregroundStyle(.blue)
            .padding(.top, 6)
          Text(suggestion)
            .font(.callout)
            .textSelection(.enabled)
        }
      }
    }
    .padding(12)
    .background(.blue.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Action Buttons

  private func actionButtons(_ r: ParsedReview) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Actions")
        .font(.subheadline)
        .fontWeight(.semibold)

      HStack(spacing: 10) {
        // Approve
        Button {
          Task { await postReview(event: "APPROVE", body: r.summary) }
        } label: {
          Label("Approve", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .disabled(postingAction != nil)

        // Comment
        Button {
          Task { await postReview(event: "COMMENT", body: r.summary) }
        } label: {
          Label("Comment", systemImage: "text.bubble")
        }
        .buttonStyle(.bordered)
        .disabled(postingAction != nil)

        // Request Changes
        Button {
          Task { await postReview(event: "REQUEST_CHANGES", body: formatChangesBody(r)) }
        } label: {
          Label("Request Changes", systemImage: "exclamationmark.triangle")
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .disabled(postingAction != nil)
      }

      // Fix & push row
      if !r.issues.isEmpty {
        HStack(spacing: 10) {
          Button {
            Task { await dispatchFix(issues: r.issues) }
          } label: {
            Label("Fix Issues", systemImage: "wrench")
          }
          .buttonStyle(.bordered)
          .disabled(fixRunId != nil)

          if let fixRun = fixWorktreeRun,
             fixRun.status == .completed || fixRun.status == .awaitingReview,
             target.headRef != nil {
            Button {
              Task { await pushFix() }
            } label: {
              Label("Push Fix to PR", systemImage: "arrow.up.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(isPushing || pushResult != nil)
          }
        }
        if let pushResult {
          Label(pushResult, systemImage: "checkmark.circle.fill")
            .font(.caption).foregroundStyle(.green)
        }
        if let pushError {
          Label(pushError, systemImage: "xmark.circle")
            .font(.caption).foregroundStyle(.red)
        }
      }

      // Open in browser
      if let urlStr = target.htmlURL, let url = URL(string: urlStr) {
        Button {
          #if os(macOS)
          NSWorkspace.shared.open(url)
          #endif
        } label: {
          Label("Open in Browser", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
      }
    }
  }

  // MARK: - Fix chain section

  private var fixChainSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      if let chain = fixChain {
        HStack(spacing: 8) {
          if chain.state.isTerminal {
            Image(systemName: chain.state.isComplete ? "checkmark.circle.fill" : "xmark.circle.fill")
              .foregroundStyle(chain.state.isComplete ? .green : .red)
          } else {
            ProgressView().controlSize(.small)
          }
          Text("Fix: \(chain.state.displayName)")
            .font(.subheadline)
            .fontWeight(.medium)
        }
        if !chain.liveStatusMessages.isEmpty {
          ForEach(chain.liveStatusMessages.suffix(3)) { msg in
            HStack(spacing: 6) {
              Image(systemName: msg.type.icon)
                .font(.caption2)
                .foregroundStyle(msg.type.color)
              Text(msg.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Starting fix chain…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Failed

  private func failedSection(_ message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.largeTitle)
        .foregroundStyle(.red)
      Text("Review Failed")
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button {
        phase = .ready
        result = nil
        rawOutput = ""
        runId = nil
      } label: {
        Label("Try Again", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  // MARK: - Helpers

  private func riskBadge(_ risk: String) -> some View {
    let color: Color = {
      switch risk.lowercased() {
      case "low": return .green
      case "medium": return .orange
      case "high": return .red
      default: return .secondary
      }
    }()
    return Text("Risk: \(risk.capitalized)")
      .font(.caption2)
      .fontWeight(.medium)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(color.opacity(0.15)))
      .foregroundStyle(color)
  }

  private func elapsedString(from start: Date) -> String {
    let secs = Int(Date().timeIntervalSince(start))
    if secs < 60 { return "\(secs)s" }
    return "\(secs / 60)m \(secs % 60)s"
  }

  private func formatChangesBody(_ r: ParsedReview) -> String {
    var body = r.summary
    if !r.issues.isEmpty {
      body += "\n\n**Issues:**\n"
      body += r.issues.map { "- \($0)" }.joined(separator: "\n")
    }
    if !r.suggestions.isEmpty {
      body += "\n\n**Suggestions:**\n"
      body += r.suggestions.map { "- \($0)" }.joined(separator: "\n")
    }
    return body
  }

  // MARK: - Working directory resolution

  /// Resolve a working directory from multiple sources.
  private func resolveWorkingDirectory() -> String? {
    if let p = target.localPath { return p }
    let ssh = "git@github.com:\(target.ownerRepo).git"
    let https = "https://github.com/\(target.ownerRepo).git"
    if let p = RepoRegistry.shared.getLocalPath(for: ssh) ?? RepoRegistry.shared.getLocalPath(for: https) {
      return p
    }
    return mcp.agentManager.lastUsedWorkingDirectory
  }

  // MARK: - Prompt builder

  private func buildPrompt() -> String {
    let parts = target.ownerRepo.split(separator: "/")
    let owner = parts.count >= 2 ? String(parts[0]) : target.ownerRepo
    let repo = parts.count >= 2 ? String(parts[1]) : target.ownerRepo
    return """
    Review PR #\(target.prNumber) in \(target.ownerRepo).

    Repository owner: \(owner)
    Repository name: \(repo)
    PR number: \(target.prNumber)
    PR title: \(target.prTitle)

    Use the github.pr.get, github.pr.diff, github.pr.files, github.pr.reviews, \
    github.pr.comments, and github.pr.checks tools to gather information.

    Return ONLY valid JSON (no markdown, no code fences) with this schema:
    {
      "summary": "string",
      "riskLevel": "low|medium|high",
      "issues": ["{ file: string, description: string }"],
      "suggestions": ["string"],
      "ciStatus": "string",
      "verdict": "APPROVE|REQUEST_CHANGES|COMMENT"
    }

    Rules:
    - Include all keys, even if arrays are empty.
    - Keep summary concise (<= 4 sentences).
    - Each issue MUST include the file path where it was found.
    - Base verdict on code risk + CI/check status.
    """
  }

  // MARK: - Queue helpers

  private func findQueueItem() -> PRReviewQueueItem? {
    let parts = target.ownerRepo.split(separator: "/")
    let owner = parts.count >= 2 ? String(parts[0]) : target.ownerRepo
    let name = parts.count >= 2 ? String(parts[1]) : target.ownerRepo
    return mcp.prReviewQueue.find(repoOwner: owner, repoName: name, prNumber: target.prNumber)
  }

  // MARK: - Actions

  private func startReview() async {
    guard let workDir = resolveWorkingDirectory() else {
      phase = .failed("No local repository path found. Clone the repo or open another project first.")
      return
    }

    let parts = target.ownerRepo.split(separator: "/")
    guard parts.count == 2 else {
      phase = .failed("Invalid repo format: \(target.ownerRepo)")
      return
    }
    let owner = String(parts[0])
    let repoName = String(parts[1])

    phase = .running

    // Enqueue into persistent queue
    let qi = mcp.prReviewQueue.enqueue(
      repoOwner: owner, repoName: repoName,
      prNumber: target.prNumber, prTitle: target.prTitle,
      headRef: target.headRef ?? "", htmlURL: target.htmlURL ?? ""
    )
    mcp.prReviewQueue.markReviewing(qi, chainId: "", worktreePath: workDir, model: selectedTemplate.rawValue)

    let prompt = buildPrompt()
    var arguments: [String: Any] = [
      "prompt": prompt,
      "workingDirectory": workDir,
      "templateId": selectedTemplate.templateId,
      "returnImmediately": true,
      "requireRagUsage": false,
    ]
    if let headRef = target.headRef {
      arguments["baseBranch"] = headRef
    }

    let (_, data) = await mcp.handleChainRun(id: nil, arguments: arguments)

    // Extract the run ID
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let resultObj = json["result"] as? [String: Any] {
      let chainData: [String: Any]?
      if let content = resultObj["content"] as? [[String: Any]],
         let text = content.first?["text"] as? String,
         let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
        chainData = parsed
      } else {
        chainData = resultObj
      }
      if let chainData,
         let rid = chainData["runId"] as? String
          ?? (chainData["queue"] as? [String: Any])?["runId"] as? String {
        runId = rid
        await pollForResult(rid)
        return
      }
    }

    phase = .failed("Failed to start review chain")
  }

  private func pollForResult(_ chainId: String) async {
    guard let uuid = UUID(uuidString: chainId) else {
      phase = .failed("Invalid review run ID")
      return
    }

    // Wait for the parallel run record to appear
    let deadline = Date().addingTimeInterval(30)
    var run = mcp.parallelWorktreeRunner?.findRunBySourceChainRunId(uuid)
    var sleepMs = 250
    while run == nil && Date() < deadline {
      try? await Task.sleep(for: .milliseconds(sleepMs))
      run = mcp.parallelWorktreeRunner?.findRunBySourceChainRunId(uuid)
      sleepMs = min(2_000, sleepMs + 250)
    }

    guard let runner = mcp.parallelWorktreeRunner, let locatedRun = run else {
      phase = .failed("Review run did not become available in time")
      return
    }

    let status = await runner.waitForRunCompletion(locatedRun, timeoutSeconds: 600)

    switch status {
    case .completed, .failed, .cancelled, .awaitingReview:
      break
    default:
      phase = .failed("Review is still running after 10 minutes. Check the Agent Runs dashboard for results when it finishes.")
      return
    }

    // Extract output
    let output = extractOutput(from: locatedRun)
    rawOutput = output
    if output.isEmpty {
      phase = .failed("Review completed but produced no output.")
      if let qi = findQueueItem() {
        mcp.prReviewQueue.markFailed(qi, error: "No output from review chain")
      }
      return
    }

    let parsed = parseReviewOutput(output)
    result = parsed
    phase = .completed

    if let qi = findQueueItem() {
      mcp.prReviewQueue.markReviewed(qi, output: output, verdict: parsed.verdict.rawValue)
    }
  }

  private func postReview(event: String, body: String) async {
    let parts = target.ownerRepo.split(separator: "/")
    guard parts.count == 2 else { return }

    postingAction = event
    postResult = nil
    postError = nil

    let arguments: [String: Any] = [
      "owner": String(parts[0]),
      "repo": String(parts[1]),
      "pull_number": target.prNumber,
      "event": event,
      "body": body,
    ]

    guard let handler = mcp.githubToolsHandler else {
      postError = "GitHub handler unavailable"
      postingAction = nil
      return
    }

    let (_, data) = await handler.handle(name: "github.pr.review.create", id: nil, arguments: arguments)
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let errorObj = json["error"] as? [String: Any],
       let msg = errorObj["message"] as? String {
      postError = msg
    } else {
      let label = event == "APPROVE" ? "Approved" : event == "REQUEST_CHANGES" ? "Changes requested" : "Comment posted"
      postResult = label
      if event == "APPROVE", let qi = findQueueItem() {
        mcp.prReviewQueue.markReviewed(qi, output: rawOutput, verdict: "APPROVE")
      }
    }
    postingAction = nil
  }

  private func dispatchFix(issues: [String]) async {
    guard let workDir = resolveWorkingDirectory() else { return }

    let parts = target.ownerRepo.split(separator: "/")
    let owner = parts.count >= 2 ? String(parts[0]) : target.ownerRepo
    let repoName = parts.count >= 2 ? String(parts[1]) : target.ownerRepo

    let issuesList = issues.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    let rawContext = result?.rawOutput ?? ""

    let prompt = """
    Fix the issues found in PR #\(target.prNumber) for \(target.ownerRepo).

    Repository owner: \(owner)
    Repository name: \(repoName)
    PR number: \(target.prNumber)

    IMPORTANT: Before making any changes, use `github.pr.files` with \
    owner="\(owner)", repo="\(repoName)", pull_number=\(target.prNumber) to get \
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
        "steps": [["role": "implementer", "model": "claude-sonnet-4.6", "name": "Fix Issues"] as [String: Any]],
      ] as [String: Any],
    ]
    if let headRef = target.headRef {
      arguments["baseBranch"] = headRef
    }

    let (_, data) = await mcp.handleChainRun(id: nil, arguments: arguments)
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let resultObj = json["result"] as? [String: Any] {
      let chainData: [String: Any]?
      if let content = resultObj["content"] as? [[String: Any]],
         let text = content.first?["text"] as? String,
         let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
        chainData = parsed
      } else {
        chainData = resultObj
      }
      if let chainData,
         let rid = chainData["runId"] as? String
          ?? (chainData["queue"] as? [String: Any])?["runId"] as? String {
        fixRunId = rid
        if let qi = findQueueItem() {
          mcp.prReviewQueue.markFixing(qi, chainId: rid, model: "claude-sonnet-4.6")
        }
      }
    }
  }

  private func pushFix() async {
    guard let headRef = target.headRef,
          let runner = mcp.parallelWorktreeRunner,
          let run = fixWorktreeRun,
          let execution = run.executions.first
    else {
      pushError = "Cannot push — missing worktree run or PR head ref"
      return
    }

    isPushing = true
    pushError = nil
    pushResult = nil

    if let qi = findQueueItem() { mcp.prReviewQueue.markPushing(qi) }

    let (output, exitCode) = await runner.pushExecutionBranch(execution, toRemoteRef: headRef, in: run)

    if exitCode == 0 {
      pushResult = "Pushed to origin/\(headRef)"
      if let qi = findQueueItem() { mcp.prReviewQueue.markPushed(qi, result: pushResult!) }
    } else {
      pushError = "Push failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
      if let qi = findQueueItem() { mcp.prReviewQueue.markFailed(qi, error: pushError!) }
    }
    isPushing = false
  }

  // MARK: - Output extraction & parsing

  private func extractOutput(from run: ParallelWorktreeRun) -> String {
    for execution in run.executions.reversed() {
      let trimmed = execution.output.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return ""
  }
}

// MARK: - Parsed Review

struct ParsedReview {
  let summary: String
  let riskLevel: String
  let issues: [String]
  let suggestions: [String]
  let ciStatus: String?
  let verdict: Verdict
  let rawOutput: String

  enum Verdict: String {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"
    case unknown = "UNKNOWN"

    var displayName: String {
      switch self {
      case .approve: return "Approved"
      case .requestChanges: return "Changes Requested"
      case .comment: return "Comment"
      case .unknown: return "Pending Review"
      }
    }

    var systemImage: String {
      switch self {
      case .approve: return "checkmark.circle.fill"
      case .requestChanges: return "exclamationmark.triangle.fill"
      case .comment: return "text.bubble.fill"
      case .unknown: return "questionmark.circle"
      }
    }

    var color: Color {
      switch self {
      case .approve: return .green
      case .requestChanges: return .red
      case .comment: return .orange
      case .unknown: return .secondary
      }
    }
  }
}

// MARK: - JSON parsing

private struct ReviewJSONPayload: Decodable {
  let summary: String?
  let riskLevel: String?
  let issues: [String]?
  let suggestions: [String]?
  let ciStatus: String?
  let verdict: String?
}

private func parseReviewOutput(_ output: String) -> ParsedReview {
  if let structured = parseStructuredJSON(output) { return structured }
  return parseFreeform(output)
}

private func parseStructuredJSON(_ output: String) -> ParsedReview? {
  let candidates = jsonCandidates(from: output)
  let decoder = JSONDecoder()
  for candidate in candidates {
    guard let data = candidate.data(using: .utf8),
          let payload = try? decoder.decode(ReviewJSONPayload.self, from: data)
    else { continue }

    let verdict: ParsedReview.Verdict = {
      switch payload.verdict?.uppercased() {
      case "APPROVE": return .approve
      case "REQUEST_CHANGES": return .requestChanges
      case "COMMENT": return .comment
      default: return .unknown
      }
    }()

    return ParsedReview(
      summary: (payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? String(output.prefix(500)),
      riskLevel: (payload.riskLevel?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
      issues: payload.issues ?? [],
      suggestions: payload.suggestions ?? [],
      ciStatus: payload.ciStatus,
      verdict: verdict,
      rawOutput: output
    )
  }
  return nil
}

private func parseFreeform(_ output: String) -> ParsedReview {
  var summary = ""
  var riskLevel = "unknown"
  var issues: [String] = []
  var suggestions: [String] = []
  var ciStatus: String?
  var verdict: ParsedReview.Verdict = .unknown
  var currentSection = ""

  for line in output.components(separatedBy: "\n") {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let lowered = trimmed.lowercased()

    if lowered.contains("verdict:") || lowered.contains("decision:") {
      if lowered.contains("approve") && !lowered.contains("request") { verdict = .approve }
      else if lowered.contains("request_changes") || lowered.contains("request changes") { verdict = .requestChanges }
      else if lowered.contains("comment") { verdict = .comment }
    }
    if lowered.contains("risk:") || lowered.contains("risk level:") {
      if lowered.contains("high") { riskLevel = "high" }
      else if lowered.contains("medium") { riskLevel = "medium" }
      else if lowered.contains("low") { riskLevel = "low" }
    }
    if lowered.contains("ci status:") || lowered.contains("ci:") || lowered.contains("checks:") {
      ciStatus = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
    }
    if lowered.contains("summary") && (trimmed.hasPrefix("#") || trimmed.hasSuffix(":")) { currentSection = "summary"; continue }
    if lowered.contains("issue") && (trimmed.hasPrefix("#") || trimmed.hasSuffix(":")) { currentSection = "issues"; continue }
    if lowered.contains("suggestion") && (trimmed.hasPrefix("#") || trimmed.hasSuffix(":")) { currentSection = "suggestions"; continue }

    if !trimmed.isEmpty {
      let clean = trimmed.replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
      switch currentSection {
      case "summary": summary = summary.isEmpty ? clean : summary + " " + clean
      case "issues": if clean.count > 3 { issues.append(clean) }
      case "suggestions": if clean.count > 3 { suggestions.append(clean) }
      default: break
      }
    }
  }

  if summary.isEmpty { summary = String(output.prefix(500)) }
  return ParsedReview(summary: summary, riskLevel: riskLevel, issues: issues, suggestions: suggestions, ciStatus: ciStatus, verdict: verdict, rawOutput: output)
}

private func jsonCandidates(from output: String) -> [String] {
  var candidates: [String] = []
  // Fenced code blocks
  if let regex = try? NSRegularExpression(pattern: "```(?:json)?\\s*([\\s\\S]*?)\\s*```") {
    let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
    regex.enumerateMatches(in: output, range: nsRange) { match, _, _ in
      if let match, let range = Range(match.range(at: 1), in: output) {
        candidates.append(String(output[range]))
      }
    }
  }
  // Top-level JSON objects
  if let regex = try? NSRegularExpression(pattern: "\\{[\\s\\S]*?\"summary\"[\\s\\S]*?\\}") {
    let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
    regex.enumerateMatches(in: output, range: nsRange) { match, _, _ in
      if let match, let range = Range(match.range, in: output) {
        candidates.append(String(output[range]))
      }
    }
  }
  return candidates
}

// MARK: - Agent Review Badge

/// Compact status pill showing the current agent review phase for a PR.
struct AgentReviewBadge: View {
  let phase: String

  private var isActive: Bool {
    [PRReviewPhase.reviewing, PRReviewPhase.fixing, PRReviewPhase.pushing].contains(phase)
  }

  private var icon: String {
    PRReviewPhase.systemImage[phase] ?? "questionmark.circle"
  }

  private var label: String {
    PRReviewPhase.displayName[phase] ?? phase
  }

  private var color: Color {
    switch phase {
    case PRReviewPhase.reviewing, PRReviewPhase.fixing, PRReviewPhase.pushing: return .purple
    case PRReviewPhase.reviewed, PRReviewPhase.needsFix: return .orange
    case PRReviewPhase.fixed, PRReviewPhase.readyToPush: return .blue
    case PRReviewPhase.pushed, PRReviewPhase.approved: return .green
    case PRReviewPhase.failed: return .red
    default: return .secondary
    }
  }

  var body: some View {
    HStack(spacing: 3) {
      if isActive {
        ProgressView()
          .controlSize(.mini)
      } else {
        Image(systemName: icon)
      }
      Text(label)
        .fontWeight(.medium)
    }
    .font(.caption2)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(color.opacity(0.15))
    .foregroundStyle(color)
    .clipShape(Capsule())
  }
}

// MARK: - PR Row with Review Action

/// Enhanced PR row that includes an agent review button + sheet trigger.
struct PRRowWithReview: View {
  let pr: UnifiedRepository.PRSummary
  let ownerRepo: String?
  let repoPath: String?
  @Environment(MCPServerService.self) private var mcpServer
  @State private var showingReview = false

  private var queueItem: PRReviewQueueItem? {
    guard let ownerRepo else { return nil }
    let parts = ownerRepo.split(separator: "/")
    guard parts.count == 2 else { return nil }
    return mcpServer.prReviewQueue.find(
      repoOwner: String(parts[0]), repoName: String(parts[1]), prNumber: pr.number
    )
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: prIcon)
        .font(.callout)
        .foregroundStyle(prColor)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(pr.title)
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)

        HStack(spacing: 6) {
          Text(verbatim: "#\(pr.number)")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text(pr.state.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(prColor.opacity(0.1)))
            .foregroundStyle(prColor)
        }
      }

      Spacer()

      if let item = queueItem {
        AgentReviewBadge(phase: item.phase)
      }

      if pr.state == "open" {
        Button {
          showingReview = true
        } label: {
          Label("Review", systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
      }

      if let url = pr.htmlURL, let nsurl = URL(string: url) {
        Button {
          #if os(macOS)
          NSWorkspace.shared.open(nsurl)
          #endif
        } label: {
          Image(systemName: "arrow.up.right.square")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .sheet(isPresented: $showingReview) {
      AgentReviewSheet(target: AgentReviewTarget(
        prNumber: pr.number,
        prTitle: pr.title,
        ownerRepo: ownerRepo ?? "",
        headRef: pr.headRef,
        htmlURL: pr.htmlURL,
        localPath: repoPath
      ))
    }
  }

  private var prIcon: String {
    switch pr.state {
    case "open": return "arrow.triangle.pull"
    case "closed": return "xmark.circle.fill"
    case "merged": return "arrow.triangle.merge"
    default: return "arrow.triangle.pull"
    }
  }

  private var prColor: Color {
    switch pr.state {
    case "open": return .green
    case "closed": return .red
    case "merged": return .purple
    default: return .secondary
    }
  }
}

// MARK: - Coordinator (bridges Github API types → AgentReviewTarget)

@MainActor
final class PRReviewAgentCoordinator: PRReviewAgentProvider {
  var onReview: ((Github.PullRequest, Github.Repository) -> Void)?

  func reviewWithAgent(pr: Github.PullRequest, repo: Github.Repository) {
    onReview?(pr, repo)
  }

  /// Build an `AgentReviewTarget` from the GitHub API types + optional local repo path.
  static func makeTarget(pr: Github.PullRequest, repo: Github.Repository, localRepoPath: String?) -> AgentReviewTarget {
    AgentReviewTarget(
      prNumber: pr.number,
      prTitle: pr.title ?? "PR #\(pr.number)",
      ownerRepo: repo.full_name ?? repo.name,
      headRef: pr.head.ref,
      htmlURL: pr.html_url,
      localPath: localRepoPath
    )
  }
}
