//
//  PRReviewViews.swift
//  Peel
//
//  Agent-powered PR review flow. Triggers a PR Review chain template,
//  displays the structured assessment, and offers approve/fix/comment actions.
//

import MCPCore
import SwiftUI

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
  @Environment(MCPServerService.self) private var mcpServer
  @State private var showingReview = false
  @State private var reviewState = PRReviewState()

  /// Active queue item for this PR, if any.
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

      // Agent review phase badge
      if let item = queueItem {
        AgentReviewBadge(phase: item.phase)
      }

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
  @State private var fixChainId: String?
  @State private var fixModel: CopilotModel = .claudeSonnet46
  @State private var isPushingFix = false
  @State private var pushFixResult: String?
  @State private var pushFixError: String?

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

  /// Look up the active AgentChain for the review run.
  private var activeChain: AgentChain? {
    guard let chainIdStr = reviewState.chainId,
          let runId = UUID(uuidString: chainIdStr),
          let run = mcpServer.parallelWorktreeRunner?.findRunBySourceChainRunId(runId),
          let chainId = run.executions.first?.chainId
    else { return nil }
    return mcpServer.agentManager.chains.first { $0.id == chainId }
  }

  /// Look up the active AgentChain for the fix run.
  private var activeFixChain: AgentChain? {
    guard let chainIdStr = fixChainId,
          let runId = UUID(uuidString: chainIdStr),
          let run = mcpServer.parallelWorktreeRunner?.findRunBySourceChainRunId(runId),
          let chainId = run.executions.first?.chainId
    else { return nil }
    return mcpServer.agentManager.chains.first { $0.id == chainId }
  }

  /// Look up the worktree run for the fix chain.
  private var fixWorktreeRun: ParallelWorktreeRun? {
    guard let chainIdStr = fixChainId,
          let runId = UUID(uuidString: chainIdStr)
    else { return nil }
    return mcpServer.parallelWorktreeRunner?.findRunBySourceChainRunId(runId)
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
        Text(verbatim: "#\(pr.number) — \(pr.title)")
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
    VStack(alignment: .leading, spacing: 16) {
      // Header with elapsed time
      HStack {
        Label("Reviewing PR #\(pr.number)", systemImage: "sparkles")
          .font(.subheadline)
          .fontWeight(.medium)

        Spacer()

        if let chain = activeChain, let startTime = chain.runStartTime {
          ElapsedTimeView(startTime: startTime)
        }
      }

      if let chain = activeChain {
        // Agent progress bar
        if !chain.agents.isEmpty {
          HStack(spacing: 2) {
            ForEach(Array(chain.agents.enumerated()), id: \.element.id) { index, agent in
              let currentIdx = { if case .running(let idx) = chain.state { return idx }; return -1 }()
              VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                  .fill(index < currentIdx ? Color.green : index == currentIdx ? Color.blue : Color.secondary.opacity(0.3))
                  .frame(height: 6)
                Text(agent.role.displayName)
                  .font(.caption2)
                  .foregroundStyle(index == currentIdx ? .primary : .secondary)
              }
            }
          }
        }

        Divider()

        // Streaming status messages
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
              ForEach(chain.liveStatusMessages) { message in
                HStack(alignment: .top, spacing: 6) {
                  Image(systemName: message.type.icon)
                    .font(.caption2)
                    .foregroundStyle(message.type.color)
                    .frame(width: 12)

                  Text(message.message)
                    .font(.caption)
                    .foregroundStyle(message.type == .error ? .red : .primary)

                  Spacer()

                  Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .id(message.id)
              }
            }
          }
          .frame(maxHeight: 200)
          .onChange(of: chain.liveStatusMessages.count) { _, _ in
            if let lastMessage = chain.liveStatusMessages.last {
              withAnimation {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
              }
            }
          }
        }

        // Current agent indicator
        if case .running(let agentIdx) = chain.state, agentIdx < chain.agents.count {
          HStack {
            ProgressView()
              .scaleEffect(0.6)
            Text("Running: \(chain.agents[agentIdx].name)")
              .font(.caption)
              .foregroundStyle(.secondary)

            if let agentStart = chain.currentAgentStartTime {
              Text("·")
                .foregroundStyle(.tertiary)
              ElapsedTimeView(startTime: agentStart)
                .font(.caption)
            }
          }
        }
      } else {
        // Chain not yet discovered — show minimal spinner
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Starting review…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let chainId = reviewState.chainId {
        Text("Chain: \(chainId)")
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 12)
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
            Picker("Model", selection: $fixModel) {
              ForEach(CopilotModel.ModelFamily.allCases) { family in
                Section(family.displayName) {
                  ForEach(CopilotModel.allCases.filter { $0.modelFamily == family }) { model in
                    Text(model.displayNameWithCost).tag(model)
                  }
                }
              }
            }
            .frame(width: 200)

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
          fixChainStatusView
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

  @ViewBuilder
  private var fixChainStatusView: some View {
    if let chain = activeFixChain {
      VStack(alignment: .leading, spacing: 8) {
        if chain.state.isTerminal {
          // Fix chain completed — show result and push action
          fixChainCompletedView(chain: chain)
        } else {
          // Fix chain still running — show progress
          fixChainProgressView(chain: chain)
        }
      }
    } else {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("Starting fix chain…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func fixChainProgressView(chain: AgentChain) -> some View {
    HStack {
      Label("Fix in progress", systemImage: "hammer")
        .font(.caption)
        .fontWeight(.medium)

      Spacer()

      if let startTime = chain.runStartTime {
        ElapsedTimeView(startTime: startTime)
      }
    }

    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(chain.liveStatusMessages) { message in
            HStack(alignment: .top, spacing: 6) {
              Image(systemName: message.type.icon)
                .font(.caption2)
                .foregroundStyle(message.type.color)
                .frame(width: 12)

              Text(message.message)
                .font(.caption)
                .foregroundStyle(message.type == .error ? .red : .primary)

              Spacer()

              Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .id(message.id)
          }
        }
      }
      .frame(maxHeight: 120)
      .onChange(of: chain.liveStatusMessages.count) { _, _ in
        if let lastMessage = chain.liveStatusMessages.last {
          withAnimation {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
          }
        }
      }
    }

    if case .running(let agentIdx) = chain.state, agentIdx < chain.agents.count {
      HStack {
        ProgressView()
          .scaleEffect(0.6)
        Text("Running: \(chain.agents[agentIdx].name)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func fixChainCompletedView(chain: AgentChain) -> some View {
    let succeeded = chain.state.isComplete

    HStack {
      Label(
        succeeded ? "Fix complete" : "Fix failed",
        systemImage: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
      )
      .font(.caption)
      .fontWeight(.medium)
      .foregroundStyle(succeeded ? .green : .red)

      Spacer()

      if let startTime = chain.runStartTime {
        ElapsedTimeView(startTime: startTime)
      }
    }

    // Show last few status messages as context
    if !chain.liveStatusMessages.isEmpty {
      let lastMessages = chain.liveStatusMessages.suffix(3)
      ForEach(Array(lastMessages)) { message in
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: message.type.icon)
            .font(.caption2)
            .foregroundStyle(message.type.color)
            .frame(width: 12)

          Text(message.message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }

    if succeeded {
      Divider()

      // Push actions
      HStack(spacing: 8) {
        if let headRef = pr.headRef {
          Button {
            Task { await pushFixToPR() }
          } label: {
            Label("Push Fix to PR", systemImage: "arrow.up.circle")
          }
          .buttonStyle(.borderedProminent)
          .tint(.blue)
          .disabled(isPushingFix || pushFixResult != nil)

          Text("→ origin/\(headRef)")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Cannot push — PR head ref unknown")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      if isPushingFix {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Pushing to PR branch…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let result = pushFixResult {
        Label(result, systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.green)
      }

      if let error = pushFixError {
        Label(error, systemImage: "xmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
      }
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

    // Enqueue into persistent queue
    let queueItem = mcpServer.prReviewQueue.enqueue(
      repoOwner: owner,
      repoName: repoName,
      prNumber: pr.number,
      prTitle: pr.title,
      headRef: pr.headRef ?? "",
      htmlURL: ""
    )
    mcpServer.prReviewQueue.markReviewing(
      queueItem,
      chainId: "",
      worktreePath: repoPath,
      model: selectedTemplate.rawValue
    )

    let prompt = """
    Review PR #\(pr.number) in \(ownerRepo).
    
    Repository owner: \(owner)
    Repository name: \(repoName)
    PR number: \(pr.number)
    PR title: \(pr.title)
    
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

    var arguments: [String: Any] = [
      "prompt": prompt,
      "workingDirectory": repoPath,
      "templateId": selectedTemplate.templateId,
      "returnImmediately": true,
      "requireRagUsage": false,
    ]
    if let headRef = pr.headRef {
      arguments["baseBranch"] = headRef
    }

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
    guard let runId = UUID(uuidString: chainId) else {
      reviewState.isLoading = false
      reviewState.error = "Invalid review run ID"
      return
    }

    // First, wait briefly for the parallel run record to appear.
    // The run is created synchronously on MainActor before handleChainRun returns,
    // so it should be discoverable immediately. The loop is a safety net.
    let discoveryDeadline = Date().addingTimeInterval(30)
    var locatedRun = mcpServer.parallelWorktreeRunner?.findRunBySourceChainRunId(runId)
    var discoverySleepMs = 250

    while locatedRun == nil && Date() < discoveryDeadline {
      try? await Task.sleep(for: .milliseconds(discoverySleepMs))
      locatedRun = mcpServer.parallelWorktreeRunner?.findRunBySourceChainRunId(runId)
      discoverySleepMs = min(2_000, discoverySleepMs + 250)
    }

    guard let runner = mcpServer.parallelWorktreeRunner, let run = locatedRun else {
      reviewState.isLoading = false
      reviewState.error = "Review run did not become available in time"
      return
    }

    // Wait for the chain to finish. PR reviews on large diffs can take several minutes
    // (multiple MCP tool calls + analysis), so use a generous timeout.
    let status = await runner.waitForRunCompletion(run, timeoutSeconds: 300)

    // If the run is still in progress, the output hasn't been populated yet.
    switch status {
    case .completed, .failed, .cancelled, .awaitingReview:
      break
    default:
      reviewState.isLoading = false
      reviewState.error = "Review is still running. Check the Agent Runs dashboard for results when it finishes."
      return
    }

    let lastOutput = extractReviewOutput(from: run)
    if lastOutput.isEmpty {
      reviewState.isLoading = false
      reviewState.error = "Review completed but produced no output. Check chain logs for details."
      if let qi = findQueueItem() {
        mcpServer.prReviewQueue.markFailed(qi, error: "No output from review chain")
      }
      return
    }

    let parsed = parseReviewOutput(lastOutput)
    reviewState.reviewResult = parsed
    reviewState.isLoading = false

    if let qi = findQueueItem() {
      mcpServer.prReviewQueue.markReviewed(
        qi,
        output: lastOutput,
        verdict: parsed.verdict.rawValue
      )
    }
  }

  private func extractReviewOutput(from run: ParallelWorktreeRun) -> String {
    for execution in run.executions.reversed() {
      let trimmed = execution.output.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return ""
  }

  private struct ReviewJSONPayload: Decodable {
    let summary: String?
    let riskLevel: String?
    let issues: [String]?
    let suggestions: [String]?
    let ciStatus: String?
    let verdict: String?

    enum CodingKeys: String, CodingKey {
      case summary
      case riskLevel
      case issues
      case suggestions
      case ciStatus
      case verdict
    }
  }

  private func parseReviewOutput(_ output: String) -> PRReviewState.PRReviewResult {
    if let structured = parseStructuredReviewOutput(output) {
      return structured
    }

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

  private func parseStructuredReviewOutput(_ output: String) -> PRReviewState.PRReviewResult? {
    let candidates = jsonCandidates(from: output)
    let decoder = JSONDecoder()

    for candidate in candidates {
      guard let data = candidate.data(using: .utf8),
            let payload = try? decoder.decode(ReviewJSONPayload.self, from: data)
      else { continue }

      let verdict: PRReviewState.PRReviewResult.Verdict = {
        switch payload.verdict?.uppercased() {
        case "APPROVE": return .approve
        case "REQUEST_CHANGES": return .requestChanges
        case "COMMENT": return .comment
        default: return .unknown
        }
      }()

      return PRReviewState.PRReviewResult(
        summary: {
          let value = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          return value.isEmpty ? String(output.prefix(500)) : value
        }(),
        riskLevel: {
          let value = payload.riskLevel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          return value.isEmpty ? "unknown" : value
        }(),
        issues: payload.issues ?? [],
        suggestions: payload.suggestions ?? [],
        ciStatus: payload.ciStatus,
        verdict: verdict,
        rawOutput: output
      )
    }

    return nil
  }

  private func jsonCandidates(from output: String) -> [String] {
    var candidates: [String] = []

    let fencedPattern = "```(?:json)?\\s*([\\s\\S]*?)\\s*```"
    if let regex = try? NSRegularExpression(pattern: fencedPattern) {
      let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
      let matches = regex.matches(in: output, options: [], range: nsRange)
      for match in matches {
        guard match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: output)
        else { continue }
        candidates.append(String(output[range]))
      }
    }

    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
      candidates.append(trimmed)
    }

    return candidates
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
    fixChainId = nil

    let parts = ownerRepo.split(separator: "/")
    let owner = parts.count >= 2 ? String(parts[0]) : ownerRepo
    let repoName = parts.count >= 2 ? String(parts[1]) : ownerRepo

    let issuesList = issues.enumerated()
      .map { "\($0.offset + 1). \($0.element)" }
      .joined(separator: "\n")

    // Include raw review output for full context (file paths, line numbers)
    let rawContext = reviewState.reviewResult?.rawOutput ?? ""

    let prompt = """
    Fix the issues found in PR #\(pr.number) for \(ownerRepo).

    Repository owner: \(owner)
    Repository name: \(repoName)
    PR number: \(pr.number)

    IMPORTANT: Before making any changes, use `github.pr.files` with \
    owner="\(owner)", repo="\(repoName)", pull_number=\(pr.number) to get \
    the actual list of changed files and their patches from the PR. Only \
    modify files that are part of the PR — do NOT grep for similar code \
    elsewhere.

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
      "workingDirectory": repoPath,
      "returnImmediately": true,
      "chainSpec": [
        "name": "Fix PR Issues",
        "description": "Fix issues found during PR review",
        "steps": [
          [
            "role": "implementer",
            "model": fixModel.rawValue,
            "name": "Fix Issues",
          ] as [String: Any]
        ],
      ] as [String: Any],
    ]
    if let headRef = pr.headRef {
      arguments["baseBranch"] = headRef
    }

    let (_, data) = await mcpServer.handleChainRun(id: nil, arguments: arguments)

    // Extract the runId so we can show streaming status
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
        fixChainId = runId
        if let qi = findQueueItem() {
          mcpServer.prReviewQueue.markFixing(qi, chainId: runId, model: fixModel.rawValue)
        }
      }
    }

    // Keep isFixing true — the fix chain status view handles the UI.
    // It will appear unfinished until the chain completes, which is appropriate
    // since the user dispatched with returnImmediately.
  }

  private func pushFixToPR() async {
    guard let headRef = pr.headRef,
          let runner = mcpServer.parallelWorktreeRunner,
          let run = fixWorktreeRun,
          let execution = run.executions.first
    else {
      pushFixError = "Cannot push — missing worktree run or PR head ref"
      return
    }

    isPushingFix = true
    pushFixError = nil
    pushFixResult = nil

    if let qi = findQueueItem() {
      mcpServer.prReviewQueue.markPushing(qi)
    }

    let (output, exitCode) = await runner.pushExecutionBranch(
      execution,
      toRemoteRef: headRef,
      in: run
    )

    if exitCode == 0 {
      pushFixResult = "Pushed fix to origin/\(headRef)"
      isFixing = false
      if let qi = findQueueItem() {
        mcpServer.prReviewQueue.markPushed(qi, result: "Pushed to origin/\(headRef)")
      }
    } else {
      let errMsg = "Push failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
      pushFixError = errMsg
      if let qi = findQueueItem() {
        mcpServer.prReviewQueue.markFailed(qi, error: errMsg)
      }
    }

    isPushingFix = false
  }

  /// Find the queue item for the current PR.
  private func findQueueItem() -> PRReviewQueueItem? {
    guard let ownerRepo else { return nil }
    let parts = ownerRepo.split(separator: "/")
    let owner = parts.count >= 2 ? String(parts[0]) : ownerRepo
    let name = parts.count >= 2 ? String(parts[1]) : ownerRepo
    return mcpServer.prReviewQueue.find(repoOwner: owner, repoName: name, prNumber: pr.number)
  }
}
