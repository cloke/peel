//
//  PRReviewQueueView.swift
//  Peel
//
//  Activity dashboard section showing the persistent PR review queue.
//  Each row shows the PR, its current phase, and contextual actions.
//

import SwiftUI
import Github

// MARK: - Queue Section (for RepositoriesCommandCenter)

struct PRReviewQueueSection: View {
  @Environment(MCPServerService.self) private var mcpServer
  var onSelectPR: ((String, Int) -> Void)?

  private var queue: PRReviewQueue { mcpServer.prReviewQueue }

  var body: some View {
    let active = queue.activeItems
    let completed = queue.completedItems

    if !active.isEmpty || !completed.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        SectionHeader("PR Reviews")

        if !active.isEmpty {
          LazyVStack(spacing: 1) {
            ForEach(active, id: \.id) { item in
              PRReviewQueueRow(item: item, onSelectPR: onSelectPR)
            }
          }
          #if os(macOS)
          .background(Color(nsColor: .controlBackgroundColor))
          #else
          .background(Color(.systemGroupedBackground))
          #endif
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if !completed.isEmpty {
          DisclosureGroup("Completed (\(completed.count))") {
            LazyVStack(spacing: 1) {
              ForEach(completed.prefix(10), id: \.id) { item in
                PRReviewQueueRow(item: item, onSelectPR: onSelectPR)
              }
            }
            #if os(macOS)
            .background(Color(nsColor: .controlBackgroundColor))
            #else
            .background(Color(.systemGroupedBackground))
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }
}

// MARK: - Queue Row

struct PRReviewQueueRow: View {
  let item: PRReviewQueueItem
  var onSelectPR: ((String, Int) -> Void)?
  @Environment(MCPServerService.self) private var mcpServer
  @State private var isExpanded = false

  private var queue: PRReviewQueue { mcpServer.prReviewQueue }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Main row
      HStack(spacing: 10) {
        phaseIcon
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 2) {
          Text(item.prTitle)
            .font(.callout)
            .fontWeight(.medium)
            .lineLimit(1)

          HStack(spacing: 6) {
            Text(verbatim: "\(item.repoOwner)/\(item.repoName) #\(item.prNumber)")
              .font(.caption)
              .foregroundStyle(.secondary)

            phaseBadge
          }
        }

        Spacer()

        // Chain progress indicator
        chainProgressIndicator

        // Expand button
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
          }
        } label: {
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .onTapGesture {
        let ownerRepo = "\(item.repoOwner)/\(item.repoName)"
        onSelectPR?(ownerRepo, item.prNumber)
      }

      // Expanded detail
      if isExpanded {
        Divider()
          .padding(.horizontal, 12)
        expandedContent
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
      }
    }
  }

  // MARK: - Phase Icon

  @ViewBuilder
  private var phaseIcon: some View {
    let imageName = PRReviewPhase.systemImage[item.phase] ?? "questionmark.circle"
    Image(systemName: imageName)
      .font(.callout)
      .foregroundStyle(phaseColor)
  }

  private var phaseColor: Color {
    switch PRReviewPhase.color[item.phase] ?? "secondary" {
    case "purple": return .purple
    case "blue": return .blue
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "red": return .red
    default: return .secondary
    }
  }

  private var phaseBadge: some View {
    Text(PRReviewPhase.displayName[item.phase] ?? item.phase)
      .font(.caption2)
      .fontWeight(.medium)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(phaseColor.opacity(0.1)))
      .foregroundStyle(phaseColor)
  }

  // MARK: - Chain Progress

  @ViewBuilder
  private var chainProgressIndicator: some View {
    let activeChainId = item.phase == PRReviewPhase.fixing ? item.fixChainId : item.reviewChainId
    if !activeChainId.isEmpty, let chain = findChain(activeChainId) {
      switch chain.state {
      case .running:
        ProgressView()
          .controlSize(.small)
      case .complete:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.caption)
      case .failed:
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.red)
          .font(.caption)
      default:
        EmptyView()
      }
    }
  }

  // MARK: - Expanded Content

  @ViewBuilder
  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Timestamps
      HStack(spacing: 16) {
        Label(item.createdAt.formatted(.relative(presentation: .named)), systemImage: "clock")
        if let reviewed = item.reviewCompletedAt {
          Label("Reviewed \(reviewed.formatted(.relative(presentation: .named)))", systemImage: "checkmark")
        }
        if let pushed = item.pushedAt {
          Label("Pushed \(pushed.formatted(.relative(presentation: .named)))", systemImage: "arrow.up")
        }
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)

      // Error display
      if let error = item.lastError {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text(error)
            .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(.red)
      }

      // Review verdict
      if !item.reviewVerdict.isEmpty {
        HStack(spacing: 6) {
          let isApproved = item.reviewVerdict == "approved"
          Image(systemName: isApproved ? "hand.thumbsup.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(isApproved ? .green : .orange)
          Text(item.reviewVerdict.capitalized)
            .fontWeight(.medium)
        }
        .font(.caption)
      }

      // Review output preview
      if !item.reviewOutput.isEmpty {
        DisclosureGroup("Review Output") {
          ScrollView {
            Text(item.reviewOutput)
              .font(.system(.caption2, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          .frame(maxHeight: 150)
        }
        .font(.caption)
      }

      // Actions
      actionButtons
    }
  }

  // MARK: - Action Buttons

  @ViewBuilder
  private var actionButtons: some View {
    HStack(spacing: 8) {
      switch item.phase {
      case PRReviewPhase.reviewed, PRReviewPhase.needsFix:
        Button {
          Task { await dispatchFix() }
        } label: {
          Label("Fix with Agent", systemImage: "hammer")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.small)

      case PRReviewPhase.fixed, PRReviewPhase.readyToPush:
        Button {
          Task { await pushFix() }
        } label: {
          Label("Push to PR", systemImage: "arrow.up.circle")
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .controlSize(.small)

      case PRReviewPhase.failed:
        Button {
          queue.retry(item)
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

      default:
        EmptyView()
      }

      // View full PR details
      Button {
        let ownerRepo = "\(item.repoOwner)/\(item.repoName)"
        onSelectPR?(ownerRepo, item.prNumber)
      } label: {
        Label("View Details", systemImage: "doc.text.magnifyingglass")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)

      // Open in browser
      if !item.htmlURL.isEmpty, let url = URL(string: item.htmlURL) {
        Button {
          #if os(macOS)
          NSWorkspace.shared.open(url)
          #endif
        } label: {
          Label("Open PR", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      // View chain in Agents
      if let chain = activeChain {
        Button {
          mcpServer.agentManager.selectedChain = chain
        } label: {
          Label("View Chain", systemImage: "cpu")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Spacer()

      // Remove
      Button(role: .destructive) {
        queue.remove(item)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
  }

  // MARK: - Helpers

  private var activeChain: AgentChain? {
    let chainId = item.phase == PRReviewPhase.fixing ? item.fixChainId : item.reviewChainId
    return findChain(chainId)
  }

  private func findChain(_ chainId: String) -> AgentChain? {
    guard !chainId.isEmpty, let uuid = UUID(uuidString: chainId) else { return nil }
    return mcpServer.agentManager.chains.first { $0.id == uuid }
  }

  private func dispatchFix() async {
    guard !item.reviewOutput.isEmpty, !item.worktreePath.isEmpty else { return }

    let fullName = "\(item.repoOwner)/\(item.repoName)"
    let fixPrompt = """
    Fix the issues found during the review of PR #\(item.prNumber) in \(fullName).

    Repository: \(fullName)
    PR number: \(item.prNumber)
    Branch: \(item.headRef)

    IMPORTANT: Before making any changes, use `github.pr.files` with \
    the PR details to get the actual list of changed files and their patches. \
    Only modify files that are part of the PR.

    Full review output:
    \(item.reviewOutput)

    Instructions:
    - Fix each issue identified in the review.
    - Create a commit that addresses these issues.
    - Focus on code quality and correctness.
    """

    let template = mcpServer.agentManager.allTemplates.first { $0.name == "Quick Task" }
      ?? mcpServer.agentManager.allTemplates.first
    guard let template else { return }

    let chain = mcpServer.agentManager.createChainFromTemplate(template, workingDirectory: item.worktreePath)
    chain.pullRequestReference = "\(fullName)#\(item.prNumber)"

    queue.markFixing(item, chainId: chain.id.uuidString)

    mcpServer.agentManager.runChainInBackground(
      chain,
      prompt: fixPrompt,
      cliService: mcpServer.cliService,
      sessionTracker: mcpServer.sessionTracker
    )

    // Monitor chain completion
    Task {
      await monitorChain(chain, for: item, isFix: true)
    }
  }

  private func pushFix() async {
    guard !item.headRef.isEmpty, !item.worktreePath.isEmpty else { return }

    queue.markPushing(item)

    let (branchOutput, branchExit) = await runGit(
      ["rev-parse", "--abbrev-ref", "HEAD"],
      in: item.worktreePath
    )
    let currentBranch = branchOutput.trimmingCharacters(in: .whitespacesAndNewlines)

    guard branchExit == 0, !currentBranch.isEmpty, currentBranch != "HEAD" else {
      queue.markFailed(item, error: "Cannot determine current branch in worktree")
      return
    }

    let (output, exitCode) = await runGit(
      ["push", "origin", "\(currentBranch):\(item.headRef)", "--force-with-lease"],
      in: item.worktreePath
    )

    if exitCode == 0 {
      queue.markPushed(item, result: "Pushed to origin/\(item.headRef)")
    } else {
      queue.markFailed(item, error: "Push failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }

  private func monitorChain(_ chain: AgentChain, for item: PRReviewQueueItem, isFix: Bool) async {
    // Poll for chain completion
    while !chain.state.isTerminal {
      try? await Task.sleep(for: .seconds(2))
    }

    if chain.state.isComplete {
      if isFix {
        queue.markFixed(item)
      } else {
        let output = chain.results.last?.output ?? ""
        let verdict = chain.results.last?.reviewVerdict?.rawValue ?? ""
        queue.markReviewed(item, output: output, verdict: verdict)
      }
    } else {
      let errorMsg = {
        if case .failed(let msg) = chain.state { return msg }
        return "Chain did not complete"
      }()
      queue.markFailed(item, error: errorMsg)
    }
  }

  private func runGit(_ arguments: [String], in directoryPath: String) async -> (String, Int32) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: directoryPath)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
          try process.run()
          process.waitUntilExit()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          let output = String(data: data, encoding: .utf8) ?? ""
          continuation.resume(returning: (output, process.terminationStatus))
        } catch {
          continuation.resume(returning: (error.localizedDescription, -1))
        }
      }
    }
  }
}

// MARK: - Detail View (for sidebar navigation)

struct PRReviewQueueDetailView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(RepositoryAggregator.self) private var aggregator

  private var queue: PRReviewQueue { mcpServer.prReviewQueue }

  @State private var fetchedOpenPRs: [(ownerRepo: String, pr: UnifiedRepository.PRSummary)] = []
  @State private var isLoadingPRs = false
  @State private var selectedPRDetail: PRDetailIdentifier?

  private var allOpenPRs: [(repo: UnifiedRepository, pr: UnifiedRepository.PRSummary)] {
    if !fetchedOpenPRs.isEmpty {
      return fetchedOpenPRs.compactMap { item in
        guard let repo = aggregator.repositories.first(where: { $0.ownerSlashRepo == item.ownerRepo })
        else { return nil }
        return (repo, item.pr)
      }
    }
    return aggregator.repositories.flatMap { repo in
      repo.recentPRs.filter { $0.state == "open" }.map { (repo, $0) }
    }
  }

  var body: some View {
    Group {
      if let detail = selectedPRDetail {
        PRDetailInlineView(ownerRepo: detail.ownerRepo, prNumber: detail.prNumber) {
          selectedPRDetail = nil
        }
      } else {
        mainContent
      }
    }
    .navigationTitle("PR Reviews")
  }

  private var mainContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // MCP review queue
        PRReviewQueueSection(onSelectPR: { ownerRepo, prNumber in
          selectedPRDetail = PRDetailIdentifier(ownerRepo: ownerRepo, prNumber: prNumber)
        })

        // Open PRs from tracked repos
        openPRsSection

        if queue.activeItems.isEmpty && queue.completedItems.isEmpty && allOpenPRs.isEmpty && !isLoadingPRs {
          ContentUnavailableView {
            Label("No Pull Requests", systemImage: "arrow.triangle.pull")
          } description: {
            Text("Open PRs from your tracked repositories will appear here.\nEnqueue PRs for automated review via MCP or the template browser.")
          }
        }
      }
      .padding(20)
    }
    .task { await fetchAllOpenPRs() }
  }

  @ViewBuilder
  private var openPRsSection: some View {
    if isLoadingPRs && allOpenPRs.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        SectionHeader("Open Pull Requests")
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading open PRs…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
      }
    } else if !allOpenPRs.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        SectionHeader("Open Pull Requests (\(allOpenPRs.count))")

        LazyVStack(spacing: 1) {
          ForEach(allOpenPRs, id: \.pr.id) { item in
            openPRRow(item)
          }
        }
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #else
        .background(Color(.systemGroupedBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func openPRRow(_ item: (repo: UnifiedRepository, pr: UnifiedRepository.PRSummary)) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "arrow.triangle.pull")
        .font(.callout)
        .foregroundStyle(.green)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: "#\(item.pr.number) \(item.pr.title)")
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(item.repo.displayName)
            .font(.caption)
            .foregroundStyle(.blue)
          if let ref = item.pr.headRef {
            Text("· \(ref)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }

      Spacer()

      Text("Open")
        .font(.caption2)
        .fontWeight(.bold)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.green.opacity(0.15)))
        .foregroundStyle(.green)

      Image(systemName: "chevron.right")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture {
      if let ownerRepo = item.repo.ownerSlashRepo {
        selectedPRDetail = PRDetailIdentifier(ownerRepo: ownerRepo, prNumber: item.pr.number)
      }
    }
  }

  private func fetchAllOpenPRs() async {
    isLoadingPRs = true
    defer { isLoadingPRs = false }

    let repos = aggregator.repositories.compactMap { repo -> (String, String, String)? in
      guard let ownerRepo = repo.ownerSlashRepo else { return nil }
      let parts = ownerRepo.split(separator: "/")
      guard parts.count == 2 else { return nil }
      return (ownerRepo, String(parts[0]), String(parts[1]))
    }

    var results: [(ownerRepo: String, pr: UnifiedRepository.PRSummary)] = []

    await withTaskGroup(of: [(String, UnifiedRepository.PRSummary)].self) { group in
      for (ownerRepo, owner, repoName) in repos {
        group.addTask {
          do {
            let prs = try await Github.pullRequests(owner: owner, repository: repoName, state: "open")
            return prs.map { pr in
              (ownerRepo, UnifiedRepository.PRSummary(
                id: UUID(),
                number: pr.number,
                title: pr.title ?? "Untitled",
                state: pr.state ?? "open",
                htmlURL: pr.html_url,
                headRef: pr.head.ref
              ))
            }
          } catch {
            return []
          }
        }
      }

      for await batch in group {
        results.append(contentsOf: batch)
      }
    }

    fetchedOpenPRs = results
  }
}
