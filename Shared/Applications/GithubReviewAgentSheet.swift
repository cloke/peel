//
//  GithubReviewAgentSheet.swift
//  Peel
//
//  Created on 1/20/26.
//

import SwiftUI
import Github
import Git
import PeelUI

struct PRReviewAgentTarget: Identifiable {
  let id: UUID
  let recentPR: RecentPRInfo?
  let pullRequest: Github.PullRequest?
  let repository: Github.Repository?

  static func from(pullRequest: Github.PullRequest, repository: Github.Repository) -> PRReviewAgentTarget {
    PRReviewAgentTarget(id: UUID(), recentPR: nil, pullRequest: pullRequest, repository: repository)
  }

  static func from(recentPR: RecentPRInfo) -> PRReviewAgentTarget {
    PRReviewAgentTarget(id: UUID(), recentPR: recentPR, pullRequest: nil, repository: nil)
  }
}

struct GithubReviewAgentSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(MCPServerService.self) private var mcpServer

  let target: PRReviewAgentTarget

  @State private var service = ReviewLocallyService.shared
  @State private var isLoadingPR = false
  @State private var errorMessage: String?
  @State private var pullRequest: Github.PullRequest?
  @State private var repository: Github.Repository?
  @State private var selectedRepoPath: String = ""
  @State private var openInVSCode = false
  @State private var selectedTemplateId: UUID?
  @State private var prompt: String = ""
  @State private var isRunning = false
  @State private var isQueuing = false
  @State private var didQueue = false
  @State private var lastSummary: AgentChainRunner.RunSummary?

  var body: some View {
    VStack(spacing: 0) {
      headerView
      Divider()
      contentView
      Divider()
      footerView
    }
    .frame(width: 520, height: 520)
    .task {
      if selectedRepoPath.isEmpty, let lastPath = service.lastSelectedRepoPath {
        selectedRepoPath = lastPath
      }
      // Register RAG-indexed repos with RepoRegistry (they have direct remote URLs)
      await registerRAGRepos()
      await loadPRIfNeeded()
      autoSelectRepository()
    }
  }

  private var headerView: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "sparkles")
          .font(.title)
          .foregroundStyle(.purple)

        VStack(alignment: .leading, spacing: 2) {
          Text("Review with Agent")
            .font(.headline)
          Text(headerSubtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
      }
    }
    .padding()
  }

  private var headerSubtitle: String {
    if let pr = pullRequest {
      return "PR #\(pr.number): \(pr.title ?? "Untitled")"
    }
    if let recent = target.recentPR {
      return "PR #\(recent.prNumber): \(recent.title)"
    }
    return "Loading PR"
  }

  @ViewBuilder
  private var contentView: some View {
    if isLoadingPR {
      ProgressView("Loading PR...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let errorMessage {
      ErrorView(message: errorMessage) {
        Task { await loadPRIfNeeded() }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          SectionCard("Local Repository") {
            TextField("Path to local repository", text: $selectedRepoPath)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("github.reviewAgent.repoPath")

            HStack(spacing: 8) {
              Button("Browse…") {
                if let path = service.browseForRepository() {
                  selectedRepoPath = path
                  service.lastSelectedRepoPath = path
                }
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("github.reviewAgent.repoBrowse")

              Toggle("Open in VS Code", isOn: $openInVSCode)
                .accessibilityIdentifier("github.reviewAgent.openInVSCode")
            }

            if !service.recentRepositories.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("Recent Repositories")
                  .font(.caption)
                  .foregroundStyle(.secondary)

                ForEach(service.recentRepositories.prefix(6)) { repo in
                  Button {
                    selectedRepoPath = repo.path
                  } label: {
                    HStack {
                      Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                      VStack(alignment: .leading, spacing: 2) {
                        Text(repo.name)
                          .font(.callout)
                        Text(repo.path)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                          .lineLimit(1)
                      }
                      Spacer()
                      if let repository, service.repositoryMatches(local: repo, githubRepo: repository) {
                        Image(systemName: "checkmark.circle.fill")
                          .foregroundStyle(.green)
                      }
                    }
                  }
                  .buttonStyle(.plain)
                }
              }
            }
          }

          SectionCard("Agent Template") {
            Picker("Template", selection: selectedTemplateBinding) {
              ForEach(mcpServer.agentManager.allTemplates, id: \.id) { template in
                Text(template.name).tag(template.id)
              }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("github.reviewAgent.template")

            if let pr = pullRequest {
              let totalLines = (pr.additions ?? 0) + (pr.deletions ?? 0)
              Text(totalLines < 200
                ? "\(totalLines) lines changed — auto-selected free review"
                : "\(totalLines) lines changed — auto-selected deep review")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          SectionCard("Prompt") {
            TextEditor(text: $prompt)
              .frame(minHeight: 120)
              .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
              .accessibilityIdentifier("github.reviewAgent.prompt")
          }

          if let summary = lastSummary {
            SectionCard {
              Text("Agents: \(summary.results.count) · Conflicts: \(summary.mergeConflicts.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
              if let error = summary.errorMessage {
                Text(error)
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            } header: {
              HStack {
                Text(summary.errorMessage == nil ? "Review Complete" : "Review Failed")
                Spacer()
                StatusPill(
                  text: summary.errorMessage == nil ? "Success" : "Failed",
                  style: summary.errorMessage == nil ? .success : .error
                )
              }
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
    }
  }

  private var footerView: some View {
    HStack {
      Button("Cancel") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("github.reviewAgent.cancel")

      Spacer()

      if didQueue {
        Label("Queued — check Agents tab", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.callout)
      }

      Button(isQueuing ? "Queuing\u{2026}" : "Queue & Close") {
        Task { await queueReviewInBackground() }
      }
      .buttonStyle(.bordered)
      .disabled(isRunning || isQueuing || didQueue || selectedRepoPath.isEmpty || pullRequest == nil || repository == nil)
      .help("Start the review in a worktree and close this window. Check progress in the Agents tab.")
      .accessibilityIdentifier("github.reviewAgent.queueAndClose")

      Button(isRunning ? "Running\u{2026}" : "Run Review") {
        Task { await runReview() }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isRunning || isQueuing || didQueue || selectedRepoPath.isEmpty || pullRequest == nil || repository == nil)
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("github.reviewAgent.run")
    }
    .padding()
  }

  private var selectedTemplateBinding: Binding<UUID> {
    Binding(
      get: {
        if let selectedTemplateId {
          return selectedTemplateId
        }
        let defaultTemplate = recommendedTemplate(for: pullRequest)
          ?? mcpServer.agentManager.allTemplates.first
        let value = defaultTemplate?.id ?? UUID()
        selectedTemplateId = value
        return value
      },
      set: { selectedTemplateId = $0 }
    )
  }

  /// Auto-select the best review template based on PR size.
  /// Small PRs (<200 lines) → PR Review (free single-agent).
  /// Larger PRs → Refactor template (planner + implementer + reviewer).
  /// Falls back to first available template.
  private func recommendedTemplate(for pr: Github.PullRequest?) -> ChainTemplate? {
    let templates = mcpServer.agentManager.allTemplates
    let totalLines = (pr?.additions ?? 0) + (pr?.deletions ?? 0)

    if totalLines < 200 {
      return templates.first { $0.name == "PR Review" }
        ?? templates.first { $0.name == "Quick Task" }
    } else {
      return templates.first { $0.name == "Refactor" }
        ?? templates.first { $0.name == "Full Implementation" }
        ?? templates.first { $0.name == "PR Review" }
    }
  }

  private func loadPRIfNeeded() async {
    if let pr = target.pullRequest, let repo = target.repository {
      pullRequest = pr
      repository = repo
      prompt = defaultPrompt(pullRequest: pr, repository: repo)
      autoSelectRepository()
      return
    }

    guard let recent = target.recentPR else { return }
    isLoadingPR = true
    defer { isLoadingPR = false }

    let parts = recent.repoFullName.split(separator: "/")
    guard parts.count == 2 else {
      errorMessage = "Invalid repository name"
      return
    }

    let ownerLogin = String(parts[0])
    let repoName = String(parts[1])

    do {
      async let repoTask = Github.repository(owner: ownerLogin, name: repoName)
      async let prTask = Github.pullRequest(owner: ownerLogin, repository: repoName, number: recent.prNumber)
      let (repo, pr) = try await (repoTask, prTask)
      repository = repo
      pullRequest = pr
      prompt = defaultPrompt(pullRequest: pr, repository: repo)
      autoSelectRepository()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func defaultPrompt(pullRequest: Github.PullRequest, repository: Github.Repository) -> String {
    let title = pullRequest.title ?? "Untitled"
    let body = (pullRequest.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return """
Review PR #\(pullRequest.number) in \(repository.full_name ?? repository.name).
Title: \(title)
Branch: \(pullRequest.head.ref)

Description:
\(body.isEmpty ? "(No description)" : body)

Task:
- Review code changes for correctness, bugs, edge cases, and style.
- Summarize risks and provide actionable suggestions.
- If tests are appropriate, run the relevant test suite.
"""
  }

  private func autoSelectRepository() {
    guard selectedRepoPath.isEmpty, let repository else { return }

    // 1. RepoRegistry — single source of truth for "remote URL → local path"
    //    Populated from Git repos, RAG repos, ReviewLocally recents on launch + sheet open.
    if let cloneURL = repository.clone_url,
       let localPath = RepoRegistry.shared.getLocalPath(for: cloneURL) {
      selectedRepoPath = localPath
      service.lastSelectedRepoPath = localPath
      return
    }
    // Also try full_name-based URLs (covers SSH and HTTPS variants)
    if let fullName = repository.full_name {
      let possibleURLs = [
        "git@github.com:\(fullName).git",
        "https://github.com/\(fullName).git",
      ]
      for url in possibleURLs {
        if let localPath = RepoRegistry.shared.getLocalPath(for: url) {
          selectedRepoPath = localPath
          service.lastSelectedRepoPath = localPath
          return
        }
      }
    }

    #if os(macOS)
    // 2. Name-based scan of sibling directories (handles repos not yet registered)
    if let found = findRepoInSiblingDirectories(named: repository.name) {
      selectedRepoPath = found
      service.lastSelectedRepoPath = found
      return
    }
    #endif

    // 3. Fall back to matching from ReviewLocally recents
    if let match = service.recentRepositories.first(where: { service.repositoryMatches(local: $0, githubRepo: repository) }) {
      selectedRepoPath = match.path
    }
  }

  /// Register RAG-indexed repos with RepoRegistry.
  /// RAG repos already know their remote URL (repoIdentifier) + local path (rootPath),
  /// so this is a fast, no-git-process registration.
  private func registerRAGRepos() async {
    let ragMappings = mcpServer.ragRepos.compactMap { repo -> (remoteURL: String, localPath: String)? in
      guard let identifier = repo.repoIdentifier, !identifier.isEmpty else { return nil }
      return (remoteURL: identifier, localPath: repo.rootPath)
    }
    RepoRegistry.shared.registerAllExplicit(ragMappings)
  }

  #if os(macOS)
  /// Look for the repo in sibling directories of known repos.
  /// E.g. if we know ~/code/kitchen-sink, check ~/code/<repoName>.
  private func findRepoInSiblingDirectories(named repoName: String) -> String? {
    let fm = FileManager.default
    // Gather unique parent directories from all known repo sources
    var parentDirs = Set<String>()
    for repo in Git.ViewModel.shared.repositories where !repo.path.isEmpty {
      let parent = (repo.path as NSString).deletingLastPathComponent
      parentDirs.insert(parent)
    }
    for repo in service.recentRepositories {
      let parent = (repo.path as NSString).deletingLastPathComponent
      parentDirs.insert(parent)
    }
    // Also check ~/code, ~/Developer, ~/src, ~/projects, ~/repos
    let home = NSHomeDirectory()
    for dir in ["code", "Developer", "src", "projects", "repos"] {
      let path = (home as NSString).appendingPathComponent(dir)
      if fm.fileExists(atPath: path) {
        parentDirs.insert(path)
      }
    }

    for parentDir in parentDirs {
      let candidate = (parentDir as NSString).appendingPathComponent(repoName)
      let gitDir = (candidate as NSString).appendingPathComponent(".git")
      if fm.fileExists(atPath: gitDir) {
        return candidate
      }
    }
    return nil
  }
  #endif

  /// Sets up the worktree and creates the chain, returning the chain and prompt to run.
  /// Shared by both inline and background execution paths.
  private func prepareChainForReview() async -> (AgentChain, String)? {
    guard let pullRequest else { return nil }
    errorMessage = nil

    await service.reviewLocally(
      pullRequest: pullRequest,
      localRepoPath: selectedRepoPath,
      openInVSCode: openInVSCode
    )

    guard case .complete(let worktreePath) = service.state else {
      if case .error(let message) = service.state {
        errorMessage = message
      }
      return nil
    }

    let template = mcpServer.agentManager.allTemplates.first { $0.id == selectedTemplateId }
      ?? mcpServer.agentManager.allTemplates.first
    guard let template else {
      errorMessage = "No chain templates available."
      return nil
    }

    let chain = mcpServer.agentManager.createChainFromTemplate(template, workingDirectory: worktreePath)
    mcpServer.agentManager.selectedChain = chain
    return (chain, prompt)
  }

  /// Queue the review to run in the background, then dismiss the sheet.
  private func queueReviewInBackground() async {
    isQueuing = true
    defer { isQueuing = false }

    guard let (chain, reviewPrompt) = await prepareChainForReview() else { return }

    // Fire off the chain run in a task that lives on AgentManager,
    // so it survives sheet dismissal. The chain is already tracked
    // in agentManager.chains and will appear in the sidebar.
    mcpServer.agentManager.runChainInBackground(
      chain,
      prompt: reviewPrompt,
      cliService: mcpServer.cliService,
      sessionTracker: mcpServer.sessionTracker
    )

    didQueue = true
    // Brief delay so the user sees the "Queued" confirmation
    try? await Task.sleep(for: .milliseconds(600))
    dismiss()
  }

  /// Run the review inline (keeps the sheet open to show results).
  private func runReview() async {
    isRunning = true
    lastSummary = nil
    defer { isRunning = false }

    guard let (chain, reviewPrompt) = await prepareChainForReview() else { return }

    let runner = AgentChainRunner(
      agentManager: mcpServer.agentManager,
      cliService: mcpServer.cliService,
      telemetryProvider: MCPTelemetryAdapter(sessionTracker: mcpServer.sessionTracker)
    )
    let summary = await runner.runChain(chain, prompt: reviewPrompt)
    lastSummary = summary
  }
}
