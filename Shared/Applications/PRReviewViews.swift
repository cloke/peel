//
//  PRReviewViews.swift
//  Peel
//
//  Agent-powered PR review flow. Triggers a PR Review chain template,
//  displays the structured assessment, and offers approve/fix/comment actions.
//

import SwiftUI

// MARK: - PR Review State

/// Tracks the state of an agent-initiated PR review.
@Observable
@MainActor
final class PRReviewState {
  var isLoading = false
  var chainId: String?
  var reviewResult: PRReviewResult?
  var error: String?

  /// Parsed agent review output.
  struct PRReviewResult {
    let summary: String
    let riskLevel: String          // "low" | "medium" | "high"
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
        case .approve: return "Approve"
        case .requestChanges: return "Changes Requested"
        case .comment: return "Comment"
        case .unknown: return "Pending"
        }
      }

      var systemImage: String {
        switch self {
        case .approve: return "checkmark.circle.fill"
        case .requestChanges: return "exclamationmark.triangle.fill"
        case .comment: return "text.bubble"
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

  func reset() {
    isLoading = false
    chainId = nil
    reviewResult = nil
    error = nil
  }
}

// MARK: - PR Row with Review Action

/// Enhanced PR row that includes an agent review button.
struct PRRowWithReview: View {
  let pr: UnifiedRepository.PRSummary
  let ownerRepo: String?
  let repoPath: String?
  @State private var showingReview = false
  @State private var reviewState = PRReviewState()

  var body: some View {
    HStack(spacing: 10) {
      // State icon
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
          Text("#\(pr.number)")
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

      // Agent review button (only for open PRs)
      if pr.state == "open" {
        Button {
          showingReview = true
        } label: {
          Label("Review", systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
      }

      if let url = pr.htmlURL, let _ = URL(string: url) {
        Button {
          if let url = pr.htmlURL, let nsurl = URL(string: url) {
            #if os(macOS)
            NSWorkspace.shared.open(nsurl)
            #endif
          }
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
      PRReviewSheet(
        pr: pr,
        ownerRepo: ownerRepo,
        repoPath: repoPath,
        reviewState: reviewState
      )
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

// MARK: - PR Review Sheet

/// Sheet that triggers an agent PR review and displays the structured results.
struct PRReviewSheet: View {
  let pr: UnifiedRepository.PRSummary
  let ownerRepo: String?
  let repoPath: String?
  @Bindable var reviewState: PRReviewState
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(\.dismiss) private var dismiss
  @State private var selectedTemplate: ReviewTemplate = .standard
  @State private var isPostingReview = false
  @State private var postResult: String?
  @State private var isFixing = false

  enum ReviewTemplate: String, CaseIterable {
    case standard = "PR Review"
    case deep = "Deep PR Review"

    var templateId: String {
      switch self {
      case .standard: return "A0000001-0007-4000-8000-000000000007"
      case .deep: return "A0000001-0011-4000-8000-000000000011"
      }
    }

    var description: String {
      switch self {
      case .standard: return "Quick single-pass review"
      case .deep: return "Multi-step deep analysis"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      sheetHeader

      Divider()

      // Content
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if reviewState.isLoading {
            loadingView
          } else if let result = reviewState.reviewResult {
            reviewResultView(result)
          } else if let error = reviewState.error {
            errorView(error)
          } else {
            startReviewView
          }
        }
        .padding(20)
      }
    }
    .frame(minWidth: 500, idealWidth: 600, minHeight: 400, idealHeight: 600)
  }

  private var sheetHeader: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Agent PR Review")
          .font(.headline)
        Text("#\(pr.number) — \(pr.title)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button("Done") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(16)
  }

  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .controlSize(.large)
      Text("Agent is reviewing PR #\(pr.number)…")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let chainId = reviewState.chainId {
        Text("Chain: \(chainId)")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }

      Text("The agent will analyze the diff, check CI status, and produce a structured review.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  private var startReviewView: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Template picker
      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text("Review Type")
            .font(.subheadline)
            .fontWeight(.medium)

          Picker("Template", selection: $selectedTemplate) {
            ForEach(ReviewTemplate.allCases, id: \.self) { template in
              Text(template.rawValue).tag(template)
            }
          }
          .pickerStyle(.segmented)

          Text(selectedTemplate.description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(4)
      }

      // PR info card
      GroupBox {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Image(systemName: "arrow.triangle.pull")
              .foregroundStyle(.green)
            Text(pr.title)
              .fontWeight(.medium)
          }

          if let ownerRepo {
            Text(ownerRepo)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          HStack(spacing: 12) {
            Label("#\(pr.number)", systemImage: "number")
            Label(pr.state.capitalized, systemImage: "circle.fill")
              .foregroundStyle(pr.state == "open" ? .green : .secondary)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(4)
      }

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

  @ViewBuilder
  private func reviewResultView(_ result: PRReviewState.PRReviewResult) -> some View {
    // Verdict banner
    GroupBox {
      HStack(spacing: 12) {
        Image(systemName: result.verdict.systemImage)
          .font(.title2)
          .foregroundStyle(result.verdict.color)

        VStack(alignment: .leading, spacing: 2) {
          Text(result.verdict.displayName)
            .font(.headline)
            .foregroundStyle(result.verdict.color)

          HStack(spacing: 8) {
            riskBadge(result.riskLevel)
            if let ci = result.ciStatus {
              Text("CI: \(ci)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        Spacer()
      }
      .padding(4)
    }

    // Summary
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        Text("Summary")
          .font(.subheadline)
          .fontWeight(.medium)
        Text(result.summary)
          .font(.callout)
      }
      .padding(4)
    }

    // Issues
    if !result.issues.isEmpty {
      GroupBox {
        VStack(alignment: .leading, spacing: 6) {
          Label("Issues (\(result.issues.count))", systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.red)

          ForEach(result.issues, id: \.self) { issue in
            HStack(alignment: .top, spacing: 6) {
              Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.top, 2)
              Text(issue)
                .font(.callout)
            }
          }
        }
        .padding(4)
      }
    }

    // Suggestions
    if !result.suggestions.isEmpty {
      GroupBox {
        VStack(alignment: .leading, spacing: 6) {
          Label("Suggestions (\(result.suggestions.count))", systemImage: "lightbulb")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.orange)

          ForEach(result.suggestions, id: \.self) { suggestion in
            HStack(alignment: .top, spacing: 6) {
              Image(systemName: "arrow.right.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 2)
              Text(suggestion)
                .font(.callout)
            }
          }
        }
        .padding(4)
      }
    }

    // Actions
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        Text("Actions")
          .font(.subheadline)
          .fontWeight(.medium)

        HStack(spacing: 8) {
          // Approve on GitHub
          if result.verdict == .approve || result.verdict == .comment {
            Button {
              Task { await postGitHubReview(event: "APPROVE", body: result.summary) }
            } label: {
              Label("Approve on GitHub", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(isPostingReview)
          }

          // Post as comment
          Button {
            Task { await postGitHubReview(event: "COMMENT", body: result.rawOutput) }
          } label: {
            Label("Post Review", systemImage: "text.bubble")
          }
          .buttonStyle(.bordered)
          .disabled(isPostingReview)

          // Request changes
          if result.verdict == .requestChanges {
            Button {
              Task { await postGitHubReview(event: "REQUEST_CHANGES", body: result.rawOutput) }
            } label: {
              Label("Request Changes", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isPostingReview)
          }

          // Fix with agent
          if !result.issues.isEmpty {
            Button {
              Task { await dispatchFixChain(issues: result.issues) }
            } label: {
              Label("Fix with Agent", systemImage: "hammer")
            }
            .buttonStyle(.bordered)
            .disabled(isFixing)
          }
        }

        if isPostingReview {
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text("Posting to GitHub…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if let postResult {
          Label(postResult, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.green)
        }

        if isFixing {
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text("Dispatching fix chain…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(4)
    }

    // Raw output (collapsible)
    DisclosureGroup("Raw Agent Output") {
      ScrollView(.horizontal) {
        Text(result.rawOutput)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .frame(maxHeight: 200)
    }
  }

  private func errorView(_ error: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.largeTitle)
        .foregroundStyle(.red)

      Text("Review Failed")
        .font(.headline)

      Text(error)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Button {
        reviewState.reset()
      } label: {
        Label("Try Again", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

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

  // MARK: - Actions

  private func startReview() async {
    guard let ownerRepo, let repoPath else {
      reviewState.error = "Missing repository information"
      return
    }

    let parts = ownerRepo.split(separator: "/")
    guard parts.count == 2 else {
      reviewState.error = "Invalid repo format: \(ownerRepo)"
      return
    }
    let owner = String(parts[0])
    let repoName = String(parts[1])

    reviewState.isLoading = true
    reviewState.error = nil
    reviewState.reviewResult = nil

    let prompt = """
    Review PR #\(pr.number) in \(ownerRepo).
    
    Repository owner: \(owner)
    Repository name: \(repoName)
    PR number: \(pr.number)
    PR title: \(pr.title)
    
    Use the github.pr.get, github.pr.diff, github.pr.files, github.pr.reviews, \
    github.pr.comments, and github.pr.checks tools to gather information.
    
    Produce a structured review with:
    - Summary of changes
    - Risk level (low/medium/high)
    - Issues found (if any)
    - Suggestions for improvement
    - CI/check status
    - Final verdict: APPROVE, REQUEST_CHANGES, or COMMENT
    """

    let arguments: [String: Any] = [
      "prompt": prompt,
      "workingDirectory": repoPath,
      "templateId": selectedTemplate.templateId,
      "returnImmediately": true,
      "requireRagUsage": false,
    ]

    let (_, data) = await mcpServer.handleChainRun(id: nil, arguments: arguments)

    // Parse the response to get the chain ID
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let result = json["result"] as? [String: Any] {
      let chainData: [String: Any]?
      if let content = result["content"] as? [[String: Any]],
         let text = content.first?["text"] as? String,
         let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
        chainData = parsed
      } else {
        chainData = result
      }
      if let chainData,
         let runId = chainData["runId"] as? String
          ?? (chainData["queue"] as? [String: Any])?["runId"] as? String {
        reviewState.chainId = runId
        // Poll for completion
        await pollForResult(chainId: runId)
        return
      }
    }

    reviewState.isLoading = false
    reviewState.error = "Failed to start review chain"
  }

  private func pollForResult(chainId: String) async {
    // Poll the chain status until it completes
    let maxAttempts = 120 // 2 minutes at 1s intervals
    for _ in 0..<maxAttempts {
      try? await Task.sleep(for: .seconds(1))

      guard let runId = UUID(uuidString: chainId) else { break }

      // Check if the run completed via the parallel worktree runner
      if let runner = mcpServer.parallelWorktreeRunner {
        let matchingRun = runner.runs.first { $0.sourceChainRunId == runId }
        if let run = matchingRun {
          // Check if all executions have terminal status
          let isComplete = run.executions.allSatisfy { exec in
            exec.status.isTerminal || exec.status == .awaitingReview || exec.status == .approved || exec.status == .reviewed
          }
          if isComplete && !run.executions.isEmpty {
            let lastOutput = run.executions.last?.output ?? ""
            reviewState.reviewResult = parseReviewOutput(lastOutput)
            reviewState.isLoading = false
            return
          }
        }
      }

      // Also check via the active runs tracking
      if mcpServer.activeRunsById[runId] != nil {
        continue // still running
      } else if reviewState.chainId != nil {
        // Run may have finished — check via parallel runner
        if let runner = mcpServer.parallelWorktreeRunner {
          let matchingRun = runner.runs.first { $0.sourceChainRunId == runId }
          if let run = matchingRun {
            let lastOutput = run.executions.last?.output ?? ""
            reviewState.reviewResult = parseReviewOutput(lastOutput)
            reviewState.isLoading = false
            return
          }
        }
        // No parallel run found and not in active runs — chain likely completed
        // Wait a few more cycles in case it's transitioning
        try? await Task.sleep(for: .seconds(2))
        if mcpServer.activeRunsById[runId] == nil {
          // Still gone — assume completed without output capture
          reviewState.isLoading = false
          reviewState.error = "Chain completed but review output was not captured. Check the Parallel Worktrees dashboard for results."
          return
        }
      }
    }

    reviewState.isLoading = false
    if reviewState.reviewResult == nil {
      reviewState.error = "Review timed out after 2 minutes"
    }
  }

  private func parseReviewOutput(_ output: String) -> PRReviewState.PRReviewResult {
    // Try to parse structured output
    var summary = ""
    var riskLevel = "unknown"
    var issues: [String] = []
    var suggestions: [String] = []
    var ciStatus: String?
    var verdict: PRReviewState.PRReviewResult.Verdict = .unknown

    let lines = output.components(separatedBy: "\n")
    var currentSection = ""

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let lowered = trimmed.lowercased()

      // Detect verdict
      if lowered.contains("verdict:") || lowered.contains("decision:") {
        if lowered.contains("approve") && !lowered.contains("request") {
          verdict = .approve
        } else if lowered.contains("request_changes") || lowered.contains("request changes") {
          verdict = .requestChanges
        } else if lowered.contains("comment") {
          verdict = .comment
        }
      }

      // Detect risk
      if lowered.contains("risk:") || lowered.contains("risk level:") {
        if lowered.contains("high") { riskLevel = "high" }
        else if lowered.contains("medium") { riskLevel = "medium" }
        else if lowered.contains("low") { riskLevel = "low" }
      }

      // Detect CI
      if lowered.contains("ci status:") || lowered.contains("ci:") || lowered.contains("checks:") {
        ciStatus = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
      }

      // Detect sections
      if lowered.contains("summary") && (trimmed.hasPrefix("#") || trimmed.hasSuffix(":")) {
        currentSection = "summary"
        continue
      }
      if lowered.contains("issue") && (trimmed.hasPrefix("#") || trimmed.hasSuffix(":")) {
        currentSection = "issues"
        continue
      }
      if lowered.contains("suggestion") && (trimmed.hasPrefix("#") || trimmed.hasSuffix(":")) {
        currentSection = "suggestions"
        continue
      }

      // Add to current section
      if !trimmed.isEmpty {
        let cleanLine = trimmed
          .replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
          .trimmingCharacters(in: .whitespaces)

        switch currentSection {
        case "summary":
          if summary.isEmpty { summary = cleanLine }
          else { summary += " " + cleanLine }
        case "issues":
          if !cleanLine.isEmpty && cleanLine.count > 3 {
            issues.append(cleanLine)
          }
        case "suggestions":
          if !cleanLine.isEmpty && cleanLine.count > 3 {
            suggestions.append(cleanLine)
          }
        default: break
        }
      }
    }

    // Fallback: if no structured sections found, use the whole output as summary
    if summary.isEmpty {
      summary = String(output.prefix(500))
    }

    return PRReviewState.PRReviewResult(
      summary: summary,
      riskLevel: riskLevel,
      issues: issues,
      suggestions: suggestions,
      ciStatus: ciStatus,
      verdict: verdict,
      rawOutput: output
    )
  }

  private func postGitHubReview(event: String, body: String) async {
    guard let ownerRepo else { return }
    let parts = ownerRepo.split(separator: "/")
    guard parts.count == 2 else { return }

    isPostingReview = true
    postResult = nil

    let arguments: [String: Any] = [
      "owner": String(parts[0]),
      "repo": String(parts[1]),
      "pull_number": pr.number,
      "event": event,
      "body": body,
    ]

    if let handler = mcpServer.githubToolsHandler {
      let (status, _) = await handler.handle(
        name: "github.pr.review.create",
        id: nil,
        arguments: arguments
      )
      if status == 200 {
        postResult = "\(event == "APPROVE" ? "Approved" : event == "REQUEST_CHANGES" ? "Changes requested" : "Review posted") on GitHub"
      } else {
        postResult = "Failed to post review"
      }
    }

    isPostingReview = false
  }

  private func dispatchFixChain(issues: [String]) async {
    guard let ownerRepo, let repoPath else { return }

    isFixing = true

    let issuesList = issues.enumerated()
      .map { "\($0.offset + 1). \($0.element)" }
      .joined(separator: "\n")

    let prompt = """
    Fix the issues found in PR #\(pr.number) for \(ownerRepo):
    
    \(issuesList)
    
    Create a new commit that addresses these issues. Focus on code quality \
    and correctness.
    """

    let arguments: [String: Any] = [
      "prompt": prompt,
      "workingDirectory": repoPath,
      "returnImmediately": true,
    ]

    let _ = await mcpServer.handleChainRun(id: nil, arguments: arguments)
    isFixing = false
  }
}
