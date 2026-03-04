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
  @Environment(\.localRepoResolver) private var localRepoResolver
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
  @State private var launchedChain: AgentChain?
  @State private var repoAutoResolved = false
  @State private var showRepoPicker = false
  @State private var isSearchingRepo = false
  @AppStorage("current-tool") private var currentTool: CurrentTool = .agents

  var body: some View {
    VStack(spacing: 0) {
      headerView
      Divider()
      contentView
      Divider()
      footerView
    }
    .frame(width: 560, height: chainIsFinished ? 640 : 520)
    .task {
      // Register RAG-indexed repos with RepoRegistry (they have direct remote URLs)
      await registerRAGRepos()
      await loadPRIfNeeded()
      // Try repo-specific auto-select: sync strategies first, then async filesystem scan
      autoSelectRepository()
      #if os(macOS)
      if selectedRepoPath.isEmpty {
        // Async fallback: deeper filesystem scan
        await asyncFindRepository()
      }
      #endif
      if selectedRepoPath.isEmpty, let lastPath = service.lastSelectedRepoPath {
        selectedRepoPath = lastPath
      }
      if !selectedRepoPath.isEmpty {
        repoAutoResolved = true
      }
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
          localRepoSection

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

          if let chain = launchedChain {
            chainStatusCard(chain)
          } else if let summary = lastSummary {
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

  // MARK: - Local Repository Section

  @ViewBuilder
  private var localRepoSection: some View {
    if isSearchingRepo {
      SectionCard("Local Repository") {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Searching for local clone\u{2026}")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    } else if !selectedRepoPath.isEmpty && repoAutoResolved && !showRepoPicker {
      // Compact resolved view — repo was auto-detected
      SectionCard("Local Repository") {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          VStack(alignment: .leading, spacing: 2) {
            Text((selectedRepoPath as NSString).lastPathComponent)
              .font(.callout.weight(.medium))
            Text(selectedRepoPath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer()
          Button("Change") {
            showRepoPicker = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        Toggle("Open in VS Code", isOn: $openInVSCode)
          .accessibilityIdentifier("github.reviewAgent.openInVSCode")
      }
    } else {
      // Full picker — no auto-match or user chose to change
      SectionCard("Local Repository") {
        TextField("Path to local repository", text: $selectedRepoPath)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("github.reviewAgent.repoPath")

        HStack(spacing: 8) {
          Button("Browse\u{2026}") {
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
    }
  }

  private var chainIsFinished: Bool {
    guard let chain = launchedChain else { return false }
    switch chain.state {
    case .complete, .failed: return true
    default: return false
    }
  }

  private var footerView: some View {
    HStack {
      Button(launchedChain != nil ? "Close" : "Cancel") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("github.reviewAgent.cancel")

      Spacer()

      if let chain = launchedChain {
        switch chain.state {
        case .complete, .failed:
          Button {
            mcpServer.agentManager.selectedChain = chain
            currentTool = .agents
            dismiss()
          } label: {
            Label("View in Agents", systemImage: "cpu")
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("github.reviewAgent.viewInAgents")
        default:
          Label("Running \u{2014} you can close and check Agents tab", systemImage: "arrow.triangle.2.circlepath")
            .foregroundStyle(.secondary)
            .font(.caption)
        }
      } else {
        Button("Run Review") {
          Task { await runReview() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isQueuing || didQueue || selectedRepoPath.isEmpty || pullRequest == nil || repository == nil)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("github.reviewAgent.run")
      }
    }
    .padding()
  }

  @ViewBuilder
  private func chainStatusCard(_ chain: AgentChain) -> some View {
    SectionCard {
      HStack(spacing: 10) {
        switch chain.state {
        case .idle:
          ProgressView().controlSize(.small)
          Text("Preparing\u{2026}")
            .font(.callout)
            .foregroundStyle(.secondary)
        case .running(let idx):
          ProgressView().controlSize(.small)
          VStack(alignment: .leading, spacing: 2) {
            Text("Running agent \(idx + 1) of \(chain.agents.count)")
              .font(.callout)
            if idx < chain.agents.count {
              Text(chain.agents[idx].name)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        case .reviewing(let iter):
          ProgressView().controlSize(.small)
          Text("Review loop \(iter + 1)")
            .font(.callout)
        case .complete:
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("Review Complete")
            .font(.callout.weight(.medium))
        case .failed(let msg):
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.red)
          VStack(alignment: .leading, spacing: 2) {
            Text("Review Failed")
              .font(.callout.weight(.medium))
            Text(msg)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        Spacer()
      }

      if !chain.results.isEmpty {
        let cost = chain.results.reduce(0) { $0 + $1.premiumCost }
        Text("\(chain.results.count) step\(chain.results.count == 1 ? "" : "s") completed \u{00b7} \(cost.premiumMultiplierString()) used")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      HStack {
        Text("Review Progress")
        Spacer()
        if case .complete = chain.state {
          StatusPill(text: "Success", style: .success)
        } else if case .failed = chain.state {
          StatusPill(text: "Failed", style: .error)
        }
      }
    }

    // Show review output when chain finishes
    if case .complete = chain.state, let lastOutput = chain.results.last {
      SectionCard {
        ScrollView {
          Text(lastOutput.output)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 180)

        if let verdict = lastOutput.reviewVerdict {
          HStack(spacing: 6) {
            Image(systemName: verdict.iconName)
              .foregroundStyle(verdict.swiftUIColor)
            Text(verdict.displayName)
              .font(.caption.weight(.medium))
              .foregroundStyle(verdict.swiftUIColor)
          }
        }
      } header: {
        HStack {
          Text("Review Output")
          Spacer()
          Text(lastOutput.agentName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } else if case .failed = chain.state, let lastOutput = chain.results.last {
      SectionCard {
        ScrollView {
          Text(lastOutput.output)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 120)
      } header: {
        Text("Last Output")
      }
    }
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
  /// Medium PRs (200-800 lines) → Deep PR Review (multi-step with codebase context).
  /// Large PRs (>800 lines) → Deep PR Review.
  /// Falls back to first available template.
  private func recommendedTemplate(for pr: Github.PullRequest?) -> ChainTemplate? {
    let templates = mcpServer.agentManager.allTemplates
    let totalLines = (pr?.additions ?? 0) + (pr?.deletions ?? 0)

    if totalLines < 200 {
      return templates.first { $0.name == "PR Review" }
        ?? templates.first { $0.name == "Quick Task" }
    } else {
      return templates.first { $0.name == "Deep PR Review" }
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

    // 2. LocalRepoResolver — SwiftData-backed lookup (SyncedRepository + LocalRepositoryPath)
    if let localPath = localRepoResolver?.localPath(for: repository) {
      selectedRepoPath = localPath
      service.lastSelectedRepoPath = localPath
      return
    }

    #if os(macOS)
    // 3. Name-based scan of sibling directories (handles repos not yet registered)
    if let found = findRepoInSiblingDirectories(named: repository.name) {
      selectedRepoPath = found
      service.lastSelectedRepoPath = found
      return
    }
    #endif

    // 4. Fall back to matching from ReviewLocally recents
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
  /// Gather directories to scan for local clones.
  private func gatherSearchDirs() -> Set<String> {
    let fm = FileManager.default
    var parentDirs = Set<String>()
    for repo in Git.ViewModel.shared.repositories where !repo.path.isEmpty {
      let parent = (repo.path as NSString).deletingLastPathComponent
      parentDirs.insert(parent)
    }
    for repo in service.recentRepositories {
      let parent = (repo.path as NSString).deletingLastPathComponent
      parentDirs.insert(parent)
    }
    // Also add RAG repo parent dirs
    for repo in mcpServer.ragRepos {
      let parent = (repo.rootPath as NSString).deletingLastPathComponent
      parentDirs.insert(parent)
    }
    let home = NSHomeDirectory()
    for dir in ["code", "Developer", "src", "projects", "repos"] {
      let path = (home as NSString).appendingPathComponent(dir)
      if fm.fileExists(atPath: path) {
        parentDirs.insert(path)
      }
    }
    return parentDirs
  }

  /// Look for the repo in sibling directories of known repos.
  /// Checks both direct children and one level of subdirectories.
  /// E.g. if we know ~/code, checks ~/code/<repoName> AND ~/code/*/<repoName>.
  private func findRepoInSiblingDirectories(named repoName: String) -> String? {
    let fm = FileManager.default
    let parentDirs = gatherSearchDirs()

    for parentDir in parentDirs {
      // Direct child: parentDir/repoName
      let candidate = (parentDir as NSString).appendingPathComponent(repoName)
      let gitDir = (candidate as NSString).appendingPathComponent(".git")
      if fm.fileExists(atPath: gitDir) {
        return candidate
      }

      // One level deeper: parentDir/*/repoName (e.g. ~/code/workspace/repoName)
      if let subdirs = try? fm.contentsOfDirectory(atPath: parentDir) {
        for subdir in subdirs where !subdir.hasPrefix(".") {
          let subdirPath = (parentDir as NSString).appendingPathComponent(subdir)
          var isDir: ObjCBool = false
          guard fm.fileExists(atPath: subdirPath, isDirectory: &isDir), isDir.boolValue else { continue }
          let deepCandidate = (subdirPath as NSString).appendingPathComponent(repoName)
          let deepGitDir = (deepCandidate as NSString).appendingPathComponent(".git")
          if fm.fileExists(atPath: deepGitDir) {
            return deepCandidate
          }
        }
      }
    }
    return nil
  }

  /// Async filesystem scan using `find` for broader repo discovery.
  /// Called when synchronous strategies fail.
  private func asyncFindRepository() async {
    guard let repository else { return }
    isSearchingRepo = true
    defer { isSearchingRepo = false }

    let repoName = repository.name
    let home = NSHomeDirectory()
    let searchRoots = gatherSearchDirs().union([
      (home as NSString).appendingPathComponent("code"),
      (home as NSString).appendingPathComponent("Developer"),
    ]).filter { FileManager.default.fileExists(atPath: $0) }

    // Use find to search up to 3 levels deep for a .git dir inside a matching folder
    for root in searchRoots {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
      process.arguments = [root, "-maxdepth", "4", "-type", "d", "-name", ".git", "-path", "*/\(repoName)/.git"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice

      do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { continue }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { continue }
        // Take the first match, strip /.git suffix
        if let firstLine = output.components(separatedBy: "\n").first {
          let repoPath = (firstLine as NSString).deletingLastPathComponent
          selectedRepoPath = repoPath
          service.lastSelectedRepoPath = repoPath
          // Register for future lookups
          await RepoRegistry.shared.registerRepo(at: repoPath)
          return
        }
      } catch {
        continue
      }
    }
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
    // Associate chain with this PR so the GitHub sidebar can show review status.
    if let repository {
      chain.pullRequestReference = "\(repository.full_name ?? repository.name)#\(pullRequest.number)"
    }
    mcpServer.agentManager.selectedChain = chain
    return (chain, prompt)
  }

  /// Run the review in the background on AgentManager so it survives sheet dismissal.
  /// The sheet stays open to show live progress, but the user can close it any time.
  private func runReview() async {
    isRunning = true
    lastSummary = nil
    defer { isRunning = false }

    guard let (chain, reviewPrompt) = await prepareChainForReview() else { return }

    launchedChain = chain

    // Fire off the chain run on AgentManager so it survives sheet dismissal.
    mcpServer.agentManager.runChainInBackground(
      chain,
      prompt: reviewPrompt,
      cliService: mcpServer.cliService,
      sessionTracker: mcpServer.sessionTracker
    )
  }
}
