//
//  UnifiedRepositoriesView.swift
//  Peel
//
//  Shared repository sidebar/detail surfaces used by the current repositories UX.
//  The original UnifiedRepositoriesView root has been retired; these components
//  are still reused by the active macOS repositories flow.
//

import SwiftUI
import SwiftData
import Git
#if canImport(Github)
import Github
#endif

// MARK: - Sidebar Row

struct RepoSidebarRow: View {
  let repo: UnifiedRepository

  var body: some View {
    HStack(spacing: 8) {
      // Status indicator dot
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          if repo.isFavorite {
            Image(systemName: "star.fill")
              .font(.caption2)
              .foregroundStyle(.yellow)
          }
          if repo.isSubPackage {
            Image(systemName: "shippingbox")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Text(repo.displayName)
            .fontWeight(.medium)
            .lineLimit(1)
        }

        Text(repo.statusSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .contextMenu {
            if repo.statusSummary.contains("Pull error") {
              Button {
                NotificationCenter.default.post(
                  name: Notification.Name("retryPull"),
                  object: repo.normalizedRemoteURL
                )
              } label: {
                Label("Retry Pull", systemImage: "arrow.clockwise")
              }
            }
          }
      }

      Spacer()

      // Activity badges
      HStack(spacing: 4) {
        if repo.activeChainCount > 0 {
          BadgePill(
            text: "\(repo.activeChainCount)",
            systemImage: "bolt.fill",
            color: .blue
          )
        }
        if repo.worktreeCount > 0 {
          BadgePill(
            text: "\(repo.worktreeCount)",
            systemImage: "arrow.triangle.branch",
            color: .purple
          )
        }
        if !repo.recentPRs.isEmpty {
          BadgePill(
            text: "\(repo.recentPRs.count)",
            systemImage: "arrow.triangle.pull",
            color: .green
          )
          .help("\(repo.recentPRs.count) open pull requests")
        }
        if let rag = repo.ragStatus, rag != .notIndexed {
          Image(systemName: rag.systemImage)
            .font(.caption2)
            .foregroundStyle(ragStatusColor(rag))
            .help(ragStatusHelp(rag))
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var statusColor: Color {
    if repo.activeChainCount > 0 { return .blue }
    if repo.isTracked { return .green }
    if repo.isClonedLocally { return .primary.opacity(0.5) }
    return .secondary.opacity(0.3)
  }

  private func ragStatusColor(_ status: UnifiedRepository.RAGStatus) -> Color {
    switch status {
    case .notIndexed: return .secondary
    case .indexing: return .orange
    case .indexed: return .green
    case .analyzing: return .blue
    case .analyzed: return .green
    case .stale: return .orange
    }
  }

  private func ragStatusHelp(_ status: UnifiedRepository.RAGStatus) -> String {
    switch status {
    case .notIndexed: return "Not indexed"
    case .indexing: return "Indexing in progress…"
    case .indexed: return "RAG index up to date"
    case .analyzing: return "Analyzing repository…"
    case .analyzed: return "Analysis complete"
    case .stale: return "RAG index is outdated — re-index to update"
    }
  }
}

// MARK: - Filter Chip

struct FilterChip: View {
  let title: String
  let count: Int
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title)
        if count > 0 {
          Text("\(count)")
            .fontWeight(.semibold)
        }
      }
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
      )
      .foregroundStyle(isSelected ? Color.accentColor : .secondary)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Badge Pill

struct BadgePill: View {
  let text: String
  let systemImage: String
  let color: Color

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: systemImage)
      Text(text)
    }
    .font(.caption2)
    .fontWeight(.medium)
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(
      Capsule()
        .fill(color.opacity(0.12))
    )
    .foregroundStyle(color)
  }
}

// MARK: - Add Repository Sheet

struct AddRepositorySheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(DataService.self) private var dataService

  enum Mode: Hashable {
    case picker
    case trackRemote
    case workspace
  }

  @State private var mode: Mode = .picker
  @State private var remoteURL = ""
  @State private var repoName = ""
  @State private var errorMessage: String?

  // Workspace detection state
  @State private var workspaceRootPath = ""
  @State private var detectedRepos: [String] = []
  @State private var selectedRepos: Set<String> = []
  @State private var rootIsRepo = false

  var body: some View {
    VStack(spacing: 20) {
      switch mode {
      case .picker:
        pickerView
      case .trackRemote:
        trackRemoteView
      case .workspace:
        workspaceView
      }
    }
    .padding(24)
    .frame(width: 520)
  }

  // MARK: - Picker

  private var pickerView: some View {
    VStack(spacing: 20) {
      Text("Add Repository")
        .font(.headline)

      Text("Choose how to add a repository:")
        .foregroundStyle(.secondary)

      HStack(spacing: 16) {
        #if os(macOS)
        Button {
          openLocalRepository()
        } label: {
          AddOptionCard(
            title: "Open Local",
            subtitle: "Browse to existing clone",
            systemImage: "folder"
          )
        }
        .buttonStyle(.plain)
        #endif

        Button {
          mode = .trackRemote
        } label: {
          AddOptionCard(
            title: "Track Remote",
            subtitle: "Auto-pull a remote repo",
            systemImage: "antenna.radiowaves.left.and.right"
          )
        }
        .buttonStyle(.plain)
      }

      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
  }

  // MARK: - Track Remote

  private var trackRemoteView: some View {
    VStack(spacing: 16) {
      Text("Track Remote Repository")
        .font(.headline)

      Text("Enter a GitHub URL or clone URL to track:")
        .foregroundStyle(.secondary)

      TextField("https://github.com/owner/repo", text: $remoteURL)
        .textFieldStyle(.roundedBorder)
        .onSubmit { deriveRepoName() }

      TextField("Display name", text: $repoName)
        .textFieldStyle(.roundedBorder)

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Button("Back") { mode = .picker }
        Spacer()
        Button("Track") { trackRemote() }
          .keyboardShortcut(.defaultAction)
          .disabled(remoteURL.isEmpty)
      }
    }
  }

  // MARK: - Workspace View

  /// Sub-repos excluding the root (for display count).
  private var subRepoList: [String] {
    detectedRepos.filter { $0 != workspaceRootPath }
  }

  private func relativePath(for repo: String) -> String {
    if repo.hasPrefix(workspaceRootPath + "/") {
      return String(repo.dropFirst(workspaceRootPath.count + 1))
    }
    return URL(fileURLWithPath: repo).lastPathComponent
  }

  private var workspaceView: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "folder.badge.gearshape")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("Workspace Detected")
            .font(.headline)
          Text(URL(fileURLWithPath: workspaceRootPath).lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Text("This folder contains multiple repositories. Select which ones to add:")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      HStack {
        Text("\(subRepoList.count) repositories")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        Button("All") { selectedRepos = Set(detectedRepos) }
          .buttonStyle(.borderless)
          .font(.caption)
        Button("None") { selectedRepos = [] }
          .buttonStyle(.borderless)
          .font(.caption)
      }

      List {
        if rootIsRepo {
          Section {
            repoToggle(path: workspaceRootPath, label: "Workspace root", isRoot: true)
          }
        }
        Section {
          ForEach(subRepoList, id: \.self) { repo in
            repoToggle(path: repo, label: relativePath(for: repo), isRoot: false)
          }
        }
      }
      .listStyle(.bordered(alternatesRowBackgrounds: true))
      .frame(height: min(CGFloat(detectedRepos.count) * 36 + 40, 300))

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Button("Back") { mode = .picker }
        Spacer()
        Text("\(selectedRepos.count) selected")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Add Selected") { addSelectedRepos() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(selectedRepos.isEmpty)
      }
    }
  }

  private func repoToggle(path: String, label: String, isRoot: Bool) -> some View {
    Toggle(isOn: Binding(
      get: { selectedRepos.contains(path) },
      set: { on in
        if on { selectedRepos.insert(path) }
        else { selectedRepos.remove(path) }
      }
    )) {
      Text(label)
        .font(.callout)
        .fontWeight(isRoot ? .medium : .regular)
    }
  }

  // MARK: - Actions

  #if os(macOS)
  private func openLocalRepository() {
    let panel = NSOpenPanel()
    panel.title = "Choose a git repository or workspace"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK, let url = panel.url else { return }

    let path = url.path
    let gitDir = url.appendingPathComponent(".git")
    let isRepo = FileManager.default.fileExists(atPath: gitDir.path)

    // Scan for sub-repos
    let subRepos = scanForSubRepos(rootPath: path)

    if subRepos.count >= 2 || (isRepo && !subRepos.isEmpty) {
      // Workspace with multiple repos — show picker
      workspaceRootPath = path
      rootIsRepo = isRepo
      var allRepos = subRepos
      if isRepo { allRepos.insert(path, at: 0) }
      detectedRepos = allRepos
      selectedRepos = Set(allRepos)
      mode = .workspace
      return
    }

    if isRepo {
      // Single repo — add directly
      trackLocalRepo(path: path)
      return
    }

    if subRepos.count == 1 {
      // Single sub-repo found
      trackLocalRepo(path: subRepos[0])
      return
    }

    errorMessage = "No git repositories found in this folder."
  }
  #endif

  private func deriveRepoName() {
    guard repoName.isEmpty else { return }
    // Extract repo name from URL: github.com/owner/repo → repo
    let cleaned = remoteURL
      .replacingOccurrences(of: ".git", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if let last = cleaned.split(separator: "/").last {
      repoName = String(last)
    }
  }

  private func trackLocalRepo(path: String) {
    let name = URL(fileURLWithPath: path).lastPathComponent
    let remote = discoverRemoteURL(for: path) ?? path
    dataService.trackRemoteRepo(
      remoteURL: remote,
      name: name,
      localPath: path,
      branch: "main"
    )
    aggregator.rebuild()
    dismiss()
  }

  private func addSelectedRepos() {
    for path in selectedRepos {
      let name = URL(fileURLWithPath: path).lastPathComponent
      let remote = discoverRemoteURL(for: path) ?? path
      dataService.trackRemoteRepo(
        remoteURL: remote,
        name: name,
        localPath: path,
        branch: "main"
      )
    }
    aggregator.rebuild()
    dismiss()
  }

  private func scanForSubRepos(rootPath: String) -> [String] {
    let rootURL = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
    let excluded: Set<String> = [".git", ".build", ".swiftpm", "build", "dist",
      "DerivedData", "node_modules", "coverage", "tmp", "Carthage",
      ".turbo", "__snapshots__", "vendor", ".agent-workspaces"]
    let maxDepth = 4
    var repos: [String] = []
    var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]

    while !queue.isEmpty {
      let current = queue.removeFirst()
      if current.depth > maxDepth { continue }
      guard let children = try? FileManager.default.contentsOfDirectory(
        at: current.url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) else { continue }

      for child in children {
        guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        if excluded.contains(child.lastPathComponent) { continue }
        let gitMarker = child.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitMarker.path) {
          // Check if .git is a directory (normal repo) or file (submodule or worktree)
          var isDir: ObjCBool = false
          FileManager.default.fileExists(atPath: gitMarker.path, isDirectory: &isDir)
          if isDir.boolValue {
            // Normal git repo
            repos.append(child.path)
          } else if let contents = try? String(contentsOfFile: gitMarker.path, encoding: .utf8),
                    contents.hasPrefix("gitdir:") {
            let gitdir = contents.trimmingCharacters(in: .whitespacesAndNewlines)
              .replacingOccurrences(of: "gitdir: ", with: "")
            // Submodules point to ../.git/modules/*, worktrees point to ../.git/worktrees/*
            if gitdir.contains("/modules/") {
              repos.append(child.path)
            }
            // Skip worktrees
          }
        } else {
          queue.append((child, current.depth + 1))
        }
      }
    }
    return repos.sorted()
  }

  private func discoverRemoteURL(for path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", path, "remote", "get-url", "origin"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return output?.isEmpty == false ? output : nil
  }

  private func trackRemote() {
    deriveRepoName()
    guard !remoteURL.isEmpty else {
      errorMessage = "URL is required."
      return
    }
    let name = repoName.isEmpty ? "Untitled" : repoName
    dataService.trackRemoteRepo(
      remoteURL: remoteURL,
      name: name,
      localPath: "",
      branch: "main"
    )
    aggregator.rebuild()
    dismiss()
  }
}

struct AddOptionCard: View {
  let title: String
  let subtitle: String
  let systemImage: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.title)
        .foregroundStyle(.blue)
      Text(title)
        .fontWeight(.medium)
        .font(.callout)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.secondary.opacity(0.05))
        .stroke(Color.secondary.opacity(0.15))
    )
  }
}

// MARK: - Command Center (No-Selection View)

/// Cross-repo dashboard shown when no repository is selected.
/// Surfaces actionable items across all repos instead of the retired RAG overview.
struct RepositoriesCommandCenter: View {
  @Environment(RepositoryAggregator.self) private var aggregator
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(ActivityFeed.self) private var activityFeed

  @State private var fetchedOpenPRs: [(ownerRepo: String, pr: UnifiedRepository.PRSummary)] = []
  @State private var isLoadingPRs = false
  @State private var selectedPRDetail: PRDetailIdentifier?
  @State private var selectedRunForReview: ParallelWorktreeRun?
  @State private var expandedExecutions: Set<UUID> = []
  @State private var showAllPRs = false

  /// All non-terminal parallel runs across the workspace.
  private var allActiveRuns: [ParallelWorktreeRun] {
    guard let runner = mcpServer.parallelWorktreeRunner else { return [] }
    return runner.runs.filter { run in
      switch run.status {
      case .completed, .failed, .cancelled: return false
      default: return true
      }
    }
  }

  /// Runs with pending reviews across all repos.
  private var pendingApprovalRuns: [ParallelWorktreeRun] {
    allActiveRuns.filter { $0.pendingReviewCount > 0 || $0.readyToMergeCount > 0 }
  }

  /// All open PRs — uses live GitHub API data when available,
  /// falls back to aggregator cache otherwise.
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

  /// All active chains across repos.
  private var allActiveChains: [(repo: UnifiedRepository, chain: UnifiedRepository.ChainSummary)] {
    aggregator.repositories.flatMap { repo in
      repo.activeChains.map { (repo, $0) }
    }
  }

  /// All active worktrees across repos.
  private var allWorktrees: [(repo: UnifiedRepository, wt: UnifiedRepository.WorktreeSummary)] {
    aggregator.repositories.flatMap { repo in
      repo.activeWorktrees.map { (repo, $0) }
    }
  }

  private var hasActionItems: Bool {
    !pendingApprovalRuns.isEmpty || !allOpenPRs.isEmpty
  }

  private var hasAgentWork: Bool {
    !allActiveChains.isEmpty || !allActiveRuns.isEmpty || !allWorktrees.isEmpty
  }

  var body: some View {
    if let detail = selectedPRDetail {
      PRDetailInlineView(
        ownerRepo: detail.ownerRepo,
        prNumber: detail.prNumber
      ) {
        selectedPRDetail = nil
      }
    } else if let run = selectedRunForReview,
              let runner = mcpServer.parallelWorktreeRunner {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Button {
            selectedRunForReview = nil
          } label: {
            Label("Back to Command Center", systemImage: "chevron.left")
          }
          .buttonStyle(.plain)

          WorktreeRunApprovalCard(
            run: run,
            runner: runner,
            expandedExecutions: $expandedExecutions,
            onDismiss: { selectedRunForReview = nil }
          )
        }
        .padding(20)
      }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Header
          headerSection

          // Needs Attention
          if hasActionItems {
            needsAttentionSection
          }

          // Agent Work
          if hasAgentWork {
            agentWorkSection
          }

          // Repository Cards
          repositoryCardsSection

          // RAG Status (compact, collapsed)
          ragCompactSection
        }
        .padding(20)
      }
      .task { await fetchAllOpenPRs() }
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Command Center")
        .font(.title2)
        .fontWeight(.bold)

      HStack(spacing: 16) {
        quickStat(
          value: "\(aggregator.repositories.count)",
          label: "repos",
          icon: "folder",
          color: .blue
        )
        quickStat(
          value: "\(allOpenPRs.count)",
          label: "open PRs",
          icon: "arrow.triangle.pull",
          color: .green
        )
        quickStat(
          value: "\(allActiveChains.count)",
          label: "chains",
          icon: "bolt.fill",
          color: .orange
        )
        quickStat(
          value: "\(allWorktrees.count)",
          label: "worktrees",
          icon: "arrow.triangle.branch",
          color: .purple
        )
        if pendingApprovalRuns.count > 0 {
          quickStat(
            value: "\(pendingApprovalRuns.count)",
            label: "pending",
            icon: "bell.badge.fill",
            color: .red
          )
        }
      }
      .font(.caption)
    }
  }

  private func quickStat(value: String, label: String, icon: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .foregroundStyle(color)
      Text(value)
        .fontWeight(.semibold)
      Text(label)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(color.opacity(0.06))
    )
  }

  // MARK: - Needs Attention

  private var needsAttentionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Needs Your Attention", systemImage: "bell.badge.fill")
        .font(.headline)
        .foregroundStyle(.orange)

      // Pending approvals
      ForEach(pendingApprovalRuns) { run in
        GroupBox {
          HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
              .font(.title3)
              .foregroundStyle(.purple)
              .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
              Text(run.name)
                .fontWeight(.medium)
                .lineLimit(1)
              HStack(spacing: 6) {
                Text("\(run.pendingReviewCount) pending review")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if run.readyToMergeCount > 0 {
                  Text("· \(run.readyToMergeCount) ready to merge")
                    .font(.caption)
                    .foregroundStyle(.green)
                }
              }
            }
            Spacer()
            Text("Review")
              .font(.caption2)
              .fontWeight(.bold)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Capsule().fill(.purple.opacity(0.15)))
              .foregroundStyle(.purple)
          }
          .padding(2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
          selectedRunForReview = run
        }
      }

      // Open PRs across repos — tap to view full detail
      if isLoadingPRs && fetchedOpenPRs.isEmpty {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading open PRs…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
      }

      if allOpenPRs.isEmpty && !isLoadingPRs {
        ContentUnavailableView("No Open Pull Requests", systemImage: "arrow.triangle.pull")
          .frame(maxWidth: .infinity)
      }

      ForEach(showAllPRs ? allOpenPRs : Array(allOpenPRs.prefix(5)), id: \.pr.id) { item in
        GroupBox {
          HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.pull")
              .font(.title3)
              .foregroundStyle(.green)
              .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: "#\(item.pr.number) \(item.pr.title)")
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
          .padding(2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
          if let ownerRepo = item.repo.ownerSlashRepo {
            selectedPRDetail = PRDetailIdentifier(ownerRepo: ownerRepo, prNumber: item.pr.number)
          }
        }
      }

      if allOpenPRs.count > 5 {
        Button {
          showAllPRs.toggle()
        } label: {
          Text(showAllPRs ? "Show fewer" : "Show all \(allOpenPRs.count) open PRs")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 4)
      }
    }
  }

  // MARK: - Agent Work

  private var agentWorkSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Agent Work")

      ForEach(allActiveChains, id: \.chain.id) { item in
        GroupBox {
          HStack(spacing: 10) {
            if !item.chain.isTerminal {
              ProgressView()
                .controlSize(.small)
                .frame(width: 28)
            } else {
              Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
              Text(item.chain.name)
                .fontWeight(.medium)
              HStack(spacing: 6) {
                Text(item.repo.displayName)
                  .font(.caption)
                  .foregroundStyle(.blue)
                Text("· \(item.chain.stateDisplay)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
          }
          .padding(2)
        }
      }

      // Active runs that aren't in the approval section
      let nonApprovalRuns = allActiveRuns.filter { run in
        !pendingApprovalRuns.contains(where: { $0.id == run.id })
      }
      ForEach(nonApprovalRuns) { run in
        GroupBox {
          HStack(spacing: 10) {
            if run.status == .running {
              ProgressView()
                .controlSize(.small)
                .frame(width: 28)
            } else {
              Image(systemName: "bolt.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
              Text(run.name)
                .fontWeight(.medium)
              Text(run.status.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if run.executions.count > 0 {
              Text("\(run.executions.count) tasks")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            ProgressView(value: run.progress)
              .frame(width: 60)
          }
          .padding(2)
        }
      }

      if !allWorktrees.isEmpty {
        ForEach(allWorktrees.prefix(5), id: \.wt.id) { item in
          GroupBox {
            HStack(spacing: 10) {
              Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

              VStack(alignment: .leading, spacing: 2) {
                Text(item.wt.branch)
                  .fontWeight(.medium)
                  .lineLimit(1)
                HStack(spacing: 6) {
                  Text(item.repo.displayName)
                    .font(.caption)
                    .foregroundStyle(.blue)
                  Text("· \(item.wt.taskStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
            }
            .padding(2)
          }
        }
      }
    }
  }

  // MARK: - Repository Cards

  private var repositoryCardsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Repositories")

      let repos = aggregator.repositories.sorted { $0.sortPriority > $1.sortPriority }

      LazyVStack(spacing: 1) {
        ForEach(repos) { repo in
          HStack(spacing: 10) {
            // Status dot
            Circle()
              .fill(repo.hasActiveWork ? Color.green : Color.secondary.opacity(0.3))
              .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 4) {
                if repo.isFavorite {
                  Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                }
                Text(repo.displayName)
                  .fontWeight(.medium)
              }

              HStack(spacing: 8) {
                if !repo.recentPRs.isEmpty {
                  let openCount = repo.recentPRs.filter { $0.state == "open" }.count
                  if openCount > 0 {
                    Label("\(openCount) PR\(openCount == 1 ? "" : "s")", systemImage: "arrow.triangle.pull")
                      .foregroundStyle(.green)
                  }
                }
                if repo.activeChainCount > 0 {
                  Label("\(repo.activeChainCount) chain\(repo.activeChainCount == 1 ? "" : "s")", systemImage: "bolt.fill")
                    .foregroundStyle(.orange)
                }
                if repo.worktreeCount > 0 {
                  Label("\(repo.worktreeCount) worktree\(repo.worktreeCount == 1 ? "" : "s")", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.purple)
                }
                if let rag = repo.ragStatus, rag != .notIndexed {
                  Label(rag.displayName, systemImage: rag.systemImage)
                    .foregroundStyle(.secondary)
                }
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
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

  // MARK: - RAG Compact

  private var ragCompactSection: some View {
    let repos = mcpServer.ragRepos
    guard !repos.isEmpty else { return AnyView(EmptyView()) }

    let totalFiles = repos.reduce(0) { $0 + $1.fileCount }
    let totalChunks = repos.reduce(0) { $0 + $1.chunkCount }

    return AnyView(
      VStack(alignment: .leading, spacing: 8) {
        SectionHeader("RAG Index", style: .secondary)

        HStack(spacing: 12) {
          Label("\(repos.count) repos", systemImage: "folder")
          Label("\(totalFiles) files", systemImage: "doc")
          Label("\(totalChunks) chunks", systemImage: "text.alignleft")
          if let model = mcpServer.ragStatus?.embeddingModelName {
            Label(model, systemImage: "cpu")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    )
  }

  // MARK: - Data Loading

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

// MARK: - PR Detail Support

struct PRDetailIdentifier: Identifiable {
  let id = UUID()
  let ownerRepo: String
  let prNumber: Int
}

/// Inline PR detail view that loads full PR data and shows PullRequestDetailView
/// with a back button to return to the previous view.
struct PRDetailInlineView: View {
  let ownerRepo: String
  let prNumber: Int
  let onBack: () -> Void

  private enum LoadState {
    case loading
    case loaded(pr: Github.PullRequest, repo: Github.Repository)
    case error(String)
  }

  @State private var state: LoadState = .loading
  #if os(macOS)
  @Environment(MCPServerService.self) private var mcpServer
  @State private var reviewAgentCoordinator = PRReviewAgentCoordinator()
  @State private var reviewAgentTarget: PRReviewAgentTarget?
  @State private var reviewStatusBridge = PRReviewStatusBridge()
  #endif

  var body: some View {
    VStack(spacing: 0) {
      // Back bar
      HStack(spacing: 6) {
        Button {
          onBack()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "chevron.left")
            Text("Back")
          }
          .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)

        Text(verbatim: "PR #\(prNumber)")
          .font(.callout)
          .foregroundStyle(.secondary)

        Spacer()

        if let url = prURL {
          Button {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #endif
          } label: {
            Label("Open in GitHub", systemImage: "arrow.up.right.square")
              .font(.caption)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      Divider()

      // Content
      switch state {
      case .loading:
        VStack(spacing: 12) {
          ProgressView()
          Text(verbatim: "Loading PR #\(prNumber)\u{2026}")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .error(let message):
        ContentUnavailableView(
          "Failed to Load PR",
          systemImage: "exclamationmark.triangle",
          description: Text(message)
        )
      case .loaded(let pr, let repo):
        PullRequestDetailView(organization: nil, repository: repo, pullRequest: pr)
      }
    }
    #if os(macOS)
    .reviewWithAgentProvider(reviewAgentCoordinator)
    .prReviewStatusProvider(reviewStatusBridge)
    .sheet(item: $reviewAgentTarget) { target in
      GithubReviewAgentSheet(target: target)
    }
    .onAppear {
      reviewStatusBridge.queue = mcpServer.prReviewQueue
      reviewAgentCoordinator.onReview = { pr, repo in
        reviewAgentTarget = PRReviewAgentTarget.from(pullRequest: pr, repository: repo)
      }
    }
    #endif
    .task { await loadData() }
  }

  private var prURL: URL? {
    if case .loaded(let pr, _) = state, let urlStr = pr.html_url {
      return URL(string: urlStr)
    }
    return nil
  }

  private func loadData() async {
    let parts = ownerRepo.split(separator: "/")
    guard parts.count == 2 else {
      state = .error("Invalid repository: \(ownerRepo)")
      return
    }
    let owner = String(parts[0])
    let repoName = String(parts[1])

    do {
      async let repoTask = Github.repository(owner: owner, name: repoName)
      async let prTask = Github.pullRequest(owner: owner, repository: repoName, number: prNumber)
      let (repo, pr) = try await (repoTask, prTask)
      state = .loaded(pr: pr, repo: repo)
    } catch is CancellationError {
      return
    } catch {
      state = .error(error.localizedDescription)
    }
  }
}
