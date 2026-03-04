//
//  RepoDetailView.swift
//  Peel
//
//  Detail pane for a single UnifiedRepository. Shows sub-tabs:
//  Branches, Activity, RAG, and Skills.
//

import Git
import SwiftData
import SwiftUI

// MARK: - Detail Tab

enum RepoDetailTab: String, CaseIterable {
  case branches = "Branches"
  case activity = "Activity"
  case rag = "RAG"
  case skills = "Skills"

  var systemImage: String {
    switch self {
    case .branches: return "arrow.triangle.branch"
    case .activity: return "clock"
    case .rag: return "magnifyingglass"
    case .skills: return "hammer"
    }
  }
}

// MARK: - Repo Detail View

struct RepoDetailView: View {
  let repo: UnifiedRepository

  @Environment(ActivityFeed.self) private var activityFeed
  @State private var selectedTab: RepoDetailTab = .branches

  var body: some View {
    VStack(spacing: 0) {
      // Header
      repoHeader

      Divider()

      // Tab picker
      Picker("", selection: $selectedTab) {
        ForEach(RepoDetailTab.allCases, id: \.self) { tab in
          Label(tab.rawValue, systemImage: tab.systemImage)
            .tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      // Tab content
      tabContent
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  // MARK: - Header

  private var repoHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            if repo.isFavorite {
              Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
            }
            Text(repo.displayName)
              .font(.title2)
              .fontWeight(.bold)
          }

          if let ownerRepo = repo.ownerSlashRepo {
            Text(ownerRepo)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        // Status pills
        HStack(spacing: 8) {
          if repo.isClonedLocally {
            RepoStatusPill(text: "Cloned", systemImage: "checkmark.circle.fill", color: .green)
          } else {
            RepoStatusPill(text: "Remote", systemImage: "cloud", color: .secondary)
          }

          if repo.isTracked {
            RepoStatusPill(text: "Auto-Pull", systemImage: "arrow.down.circle", color: .blue)
          }

          if let rag = repo.ragStatus, rag != .notIndexed {
            RepoStatusPill(text: rag.displayName, systemImage: rag.systemImage, color: .purple)
          }
        }
      }

      // Summary stats
      HStack(spacing: 16) {
        if repo.activeChainCount > 0 {
          Label("\(repo.activeChainCount) active chain\(repo.activeChainCount == 1 ? "" : "s")", systemImage: "bolt.fill")
            .foregroundStyle(.blue)
        }
        if repo.worktreeCount > 0 {
          Label("\(repo.worktreeCount) worktree\(repo.worktreeCount == 1 ? "" : "s")", systemImage: "arrow.triangle.branch")
            .foregroundStyle(.purple)
        }
        if !repo.recentPRs.isEmpty {
          Label("\(repo.recentPRs.count) recent PR\(repo.recentPRs.count == 1 ? "" : "s")", systemImage: "arrow.triangle.pull")
            .foregroundStyle(.orange)
        }
        if let pull = repo.pullStatus {
          Label(pull.displayName, systemImage: pull.systemImage)
            .foregroundStyle(pullStatusColor(pull))
        }
      }
      .font(.caption)
    }
    .padding(16)
  }

  // MARK: - Tab Content

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
    case .branches:
      BranchesTabView(repo: repo)
    case .activity:
      ActivityTabView(repo: repo)
    case .rag:
      RAGTabView(repo: repo)
    case .skills:
      SkillsTabView(repo: repo)
    }
  }

  private func pullStatusColor(_ status: UnifiedRepository.PullStatus) -> Color {
    switch status {
    case .disabled: return .secondary
    case .idle: return .secondary
    case .pulling: return .blue
    case .upToDate: return .green
    case .updated: return .green
    case .error: return .red
    }
  }
}

// MARK: - Status Pill

struct RepoStatusPill: View {
  let text: String
  let systemImage: String
  let color: Color

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption)
      .fontWeight(.medium)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        Capsule()
          .fill(color.opacity(0.1))
      )
      .foregroundStyle(color)
  }
}

// MARK: - Branches Tab

struct BranchesTabView: View {
  let repo: UnifiedRepository

  @State private var gitRepository: Git.Model.Repository?

  var body: some View {
    Group {
      #if os(macOS)
      if let localPath = repo.localPath, repo.isClonedLocally {
        if let gitRepo = gitRepository {
          GitRootView(repository: gitRepo)
        } else {
          ProgressView("Loading repository…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        notClonedView
      }
      #else
      notClonedPlaceholder
      #endif
    }
    .task(id: repo.localPath) {
      if let localPath = repo.localPath, repo.isClonedLocally {
        gitRepository = Git.Model.Repository(name: repo.displayName, path: localPath)
      } else {
        gitRepository = nil
      }
    }
  }

  private var notClonedView: some View {
    VStack(spacing: 16) {
      // Show worktrees / PRs / chains as before for remote repos
      if !repo.activeWorktrees.isEmpty || !repo.recentPRs.isEmpty || !repo.activeChains.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if !repo.activeWorktrees.isEmpty {
              Section {
                ForEach(repo.activeWorktrees) { wt in
                  RepoWorktreeRow(worktree: wt)
                }
              } header: {
                SectionHeader("Active Worktrees")
              }
            }

            if !repo.recentPRs.isEmpty {
              Section {
                ForEach(repo.recentPRs) { pr in
                  RepoPRRow(pr: pr)
                }
              } header: {
                SectionHeader("Pull Requests")
              }
            }

            if !repo.activeChains.isEmpty {
              Section {
                ForEach(repo.activeChains) { chain in
                  RepoChainRow(chain: chain)
                }
              } header: {
                SectionHeader("Agent Chains")
              }
            }
          }
          .padding(16)
        }
      } else {
        ContentUnavailableView {
          Label("Not Cloned", systemImage: "arrow.down.to.line")
        } description: {
          Text("Clone this repository locally to view branches, commits, and local changes.")
        }
      }
    }
  }

  private var notClonedPlaceholder: some View {
    ContentUnavailableView {
      Label("Branches", systemImage: "arrow.triangle.branch")
    } description: {
      Text("Branch and commit viewing is available on macOS.")
    }
  }
}

// MARK: - Activity Tab

struct ActivityTabView: View {
  let repo: UnifiedRepository
  @Environment(ActivityFeed.self) private var activityFeed

  var body: some View {
    let repoItems = activityFeed.items(for: repo.normalizedRemoteURL)

    if repoItems.isEmpty {
      ContentUnavailableView {
        Label("No Activity", systemImage: "clock")
      } description: {
        Text("No recent activity for this repository.")
      }
    } else {
      List(repoItems) { item in
        RepoActivityItemRow(item: item)
      }
      .listStyle(.plain)
    }
  }
}

// MARK: - RAG Tab

struct RAGTabView: View {
  let repo: UnifiedRepository
  @Environment(MCPServerService.self) private var mcpServer

  @State private var isIndexing = false
  @State private var indexError: String?
  @State private var searchQuery = ""
  @State private var searchMode: MCPServerService.RAGSearchMode = .vector
  @State private var searchResults: [LocalRAGSearchResult] = []
  @State private var isSearching = false
  @State private var searchError: String?
  @State private var lessons: [LocalRAGLesson] = []
  @State private var isAnalyzing = false
  @State private var analyzeError: String?
  @State private var analyzedChunks = 0
  @State private var isEnriching = false
  @State private var enrichError: String?
  @State private var enrichedChunks = 0

  private var isCurrentlyIndexing: Bool {
    mcpServer.ragIndexingPath == repo.localPath
  }

  private var analysisState: MCPServerService.RAGRepoAnalysisState? {
    guard let path = repo.localPath else { return nil }
    // Find matching RAG repo to get its ID
    if let ragRepo = mcpServer.ragRepos.first(where: { $0.rootPath == path }) {
      return mcpServer.analysisState(for: ragRepo.id, repoPath: path)
    }
    return nil
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // RAG Status Card
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              if isCurrentlyIndexing {
                Label("Indexing…", systemImage: "arrow.triangle.2.circlepath")
                  .font(.headline)
                  .foregroundStyle(.orange)
              } else if let rag = repo.ragStatus {
                Label(rag.displayName, systemImage: rag.systemImage)
                  .font(.headline)
              } else {
                Label("Not Indexed", systemImage: "magnifyingglass.circle")
                  .font(.headline)
                  .foregroundStyle(.secondary)
              }

              Spacer()

              if isCurrentlyIndexing {
                ProgressView()
                  .controlSize(.small)
              } else if repo.ragStatus == nil || repo.ragStatus == .notIndexed {
                Button("Index Now") {
                  Task { await indexRepo(force: false) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(repo.localPath == nil)
              } else {
                Button("Re-Index") {
                  Task { await indexRepo(force: false) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Force Re-Index") {
                  Task { await indexRepo(force: true) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
            }

            if let fileCount = repo.ragFileCount {
              LabeledContent("Files Indexed", value: "\(fileCount)")
            }
            if let chunkCount = repo.ragChunkCount {
              LabeledContent("Chunks", value: "\(chunkCount)")
            }
            if let model = repo.ragEmbeddingModel {
              LabeledContent("Embedding Model", value: model)
            }
            if let lastIndexed = repo.ragLastIndexedAt {
              LabeledContent("Last Indexed") {
                Text(lastIndexed, style: .relative)
              }
            }

            if let error = indexError {
              Label(error, systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
          .padding(4)
        } label: {
          Label("RAG Index", systemImage: "magnifyingglass")
        }

        // Code Search — only show when indexed
        if repo.ragStatus != nil && repo.ragStatus != .notIndexed, repo.localPath != nil {
          GroupBox {
            VStack(alignment: .leading, spacing: 10) {
              // Search bar
              HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                  .foregroundStyle(.secondary)

                TextField("Search this repo…", text: $searchQuery)
                  .textFieldStyle(.plain)
                  .onSubmit {
                    Task { await runSearch() }
                  }

                Picker("", selection: $searchMode) {
                  Text("Vector").tag(MCPServerService.RAGSearchMode.vector)
                  Text("Text").tag(MCPServerService.RAGSearchMode.text)
                  Text("Hybrid").tag(MCPServerService.RAGSearchMode.hybrid)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                if isSearching {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  Button {
                    Task { await runSearch() }
                  } label: {
                    Image(systemName: "arrow.right.circle.fill")
                      .font(.title3)
                  }
                  .buttonStyle(.plain)
                  .foregroundStyle(.blue)
                  .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
              }

              if let error = searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(.red)
              }

              // Results
              if !searchResults.isEmpty {
                Divider()
                Text("\(searchResults.count) results")
                  .font(.caption)
                  .foregroundStyle(.secondary)

                ForEach(searchResults.prefix(20), id: \.filePath) { result in
                  RepoSearchResultRow(result: result)
                }
              }
            }
            .padding(4)
          } label: {
            Label("Code Search", systemImage: "text.magnifyingglass")
          }
        }

        // AI Analysis & Enrich Pipeline
        if repo.ragStatus != nil && repo.ragStatus != .notIndexed, repo.localPath != nil {
          GroupBox {
            VStack(alignment: .leading, spacing: 10) {
              // Status display
              if let state = analysisState, state.totalChunks > 0 {
                HStack {
                  if state.isComplete {
                    Label("Analysis Complete", systemImage: "checkmark.seal.fill")
                      .foregroundStyle(.green)
                  } else if state.isAnalyzing || isAnalyzing {
                    HStack(spacing: 6) {
                      ProgressView()
                        .controlSize(.small)
                      Text("Analyzing…")
                    }
                  } else if state.isPaused {
                    Label("Paused", systemImage: "pause.circle")
                      .foregroundStyle(.orange)
                  } else {
                    Label("\(state.analyzedCount) / \(state.totalChunks) chunks analyzed", systemImage: "cpu")
                      .foregroundStyle(.secondary)
                  }

                  Spacer()

                  Text("\(Int(state.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                ProgressView(value: state.progress)
                  .tint(state.isComplete ? .green : .purple)

                if (state.isAnalyzing || isAnalyzing), state.chunksPerSecond > 0 {
                  Text("\(String(format: "%.1f", state.chunksPerSecond)) chunks/sec")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                if let error = state.analyzeError {
                  Label(error, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                }
              }

              // Pipeline description
              Text("Pipeline: Index → Analyze (AI summaries) → Enrich (better embeddings)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

              // Action buttons
              HStack(spacing: 8) {
                #if os(macOS)
                Button {
                  Task { await analyzeChunks() }
                } label: {
                  HStack(spacing: 4) {
                    if isAnalyzing {
                      ProgressView()
                        .controlSize(.mini)
                    } else {
                      Image(systemName: "cpu")
                    }
                    Text(isAnalyzing ? "Analyzing…" : "Analyze")
                  }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isAnalyzing || repo.localPath == nil)

                Button {
                  Task { await enrichEmbeddings() }
                } label: {
                  HStack(spacing: 4) {
                    if isEnriching {
                      ProgressView()
                        .controlSize(.mini)
                    } else {
                      Image(systemName: "sparkles")
                    }
                    Text(isEnriching ? "Enriching…" : "Enrich")
                  }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isEnriching || repo.localPath == nil)
                #else
                Text("AI Analysis requires macOS")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                #endif

                Spacer()

                if analyzedChunks > 0 {
                  Text("Last run: \(analyzedChunks) chunks analyzed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                if enrichedChunks > 0 {
                  Text("Last run: \(enrichedChunks) chunks enriched")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
              }

              if let error = analyzeError {
                Label(error, systemImage: "xmark.circle")
                  .font(.caption)
                  .foregroundStyle(.red)
              }
              if let error = enrichError {
                Label(error, systemImage: "xmark.circle")
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            }
            .padding(4)
          } label: {
            Label("AI Analysis & Enrichment", systemImage: "cpu")
          }
        }

        // Lessons
        if !lessons.isEmpty {
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(lessons.prefix(10), id: \.id) { lesson in
                HStack(spacing: 8) {
                  Circle()
                    .fill(lesson.confidence >= 0.7 ? .green : lesson.confidence >= 0.4 ? .orange : .red)
                    .frame(width: 8, height: 8)

                  VStack(alignment: .leading, spacing: 2) {
                    Text(lesson.fixDescription)
                      .font(.callout)
                      .lineLimit(2)

                    HStack(spacing: 8) {
                      Text("Confidence: \(Int(lesson.confidence * 100))%")
                      if lesson.applyCount > 0 {
                        Text("Applied: \(lesson.applyCount)×")
                      }
                      if !lesson.source.isEmpty {
                        Text(lesson.source)
                      }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                  }

                  Spacer()
                }
                if lesson.id != lessons.prefix(10).last?.id {
                  Divider()
                }
              }

              if lessons.count > 10 {
                Text("+ \(lessons.count - 10) more lessons")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(4)
          } label: {
            Label("Learned Lessons (\(lessons.count))", systemImage: "brain")
          }
        }
      }
      .padding(16)
    }
    .task {
      await loadLessons()
    }
  }

  private func indexRepo(force: Bool) async {
    guard let path = repo.localPath else { return }
    isIndexing = true
    indexError = nil
    do {
      try await mcpServer.indexRagRepo(path: path, forceReindex: force)
      await mcpServer.refreshRagSummary()
    } catch {
      indexError = error.localizedDescription
    }
    isIndexing = false
  }

  private func runSearch() async {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    isSearching = true
    searchError = nil
    do {
      searchResults = try await mcpServer.searchRag(
        query: trimmed,
        mode: searchMode,
        repoPath: repo.localPath,
        limit: 15
      )
    } catch {
      searchError = error.localizedDescription
    }
    isSearching = false
  }

  private func analyzeChunks() async {
    guard let path = repo.localPath else { return }
    isAnalyzing = true
    analyzeError = nil
    do {
      let count = try await mcpServer.analyzeRagChunks(
        repoPath: path,
        limit: 500,
        progress: nil
      )
      analyzedChunks = count
    } catch {
      analyzeError = error.localizedDescription
    }
    isAnalyzing = false
  }

  private func enrichEmbeddings() async {
    guard let path = repo.localPath else { return }
    isEnriching = true
    enrichError = nil
    do {
      let count = try await mcpServer.enrichRagEmbeddings(
        repoPath: path,
        limit: 500,
        progress: nil
      )
      enrichedChunks = count
    } catch {
      enrichError = error.localizedDescription
    }
    isEnriching = false
  }

  private func loadLessons() async {
    guard let path = repo.localPath else { return }
    do {
      lessons = try await mcpServer.listLessons(
        repoPath: path,
        includeInactive: false,
        limit: nil
      )
    } catch {
      // Lessons are optional — silently fail
    }
  }
}

// MARK: - Repo Search Result Row

private struct RepoSearchResultRow: View {
  let result: LocalRAGSearchResult

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Score
      if let score = result.score {
        Text("\(Int(score * 100))")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.blue)
          .frame(width: 28)
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(displayPath)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)

          Spacer()

          Text("L\(result.startLine)–\(result.endLine)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        Text(result.snippet.components(separatedBy: "\n").first ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }

  private var displayPath: String {
    let path = result.filePath
    // Trim to show just the relative portion
    if let range = path.range(of: "/", options: .backwards) {
      return String(path[range.lowerBound...])
    }
    return path
  }
}

// MARK: - Skills Tab

struct SkillsTabView: View {
  let repo: UnifiedRepository
  @Environment(DataService.self) private var dataService

  @State private var skills: [RepoGuidanceSkill] = []
  @State private var showInactive = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Header
        HStack {
          Label("Guidance Skills", systemImage: "lightbulb")
            .font(.headline)

          Spacer()

          Toggle("Show Inactive", isOn: $showInactive)
            .toggleStyle(.switch)
            .controlSize(.small)

          Text("\(skills.count) skills")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if skills.isEmpty {
          GroupBox {
            ContentUnavailableView {
              Label("No Skills", systemImage: "lightbulb.slash")
            } description: {
              Text("No guidance skills configured for this repository. Skills help agents understand your codebase conventions, patterns, and best practices.")
            }
          }
        } else {
          LazyVStack(spacing: 6) {
            ForEach(skills, id: \.id) { skill in
              SkillRow(skill: skill)
            }
          }
        }
      }
      .padding(16)
    }
    .task(id: showInactive) {
      loadSkills()
    }
  }

  private func loadSkills() {
    skills = dataService.listRepoGuidanceSkills(
      repoPath: repo.localPath,
      repoRemoteURL: repo.normalizedRemoteURL,
      includeInactive: showInactive,
      limit: nil
    )
  }
}

// MARK: - Skill Row

private struct SkillRow: View {
  let skill: RepoGuidanceSkill
  @State private var isExpanded = false

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: skill.isActive ? "lightbulb.fill" : "lightbulb.slash")
            .foregroundStyle(skill.isActive ? .green : .gray)

          Text(skill.title.isEmpty ? "Untitled Skill" : skill.title)
            .fontWeight(.medium)

          Spacer()

          if !skill.tags.isEmpty {
            HStack(spacing: 4) {
              ForEach(skill.tags.components(separatedBy: ",").prefix(3), id: \.self) { tag in
                Text(tag.trimmingCharacters(in: .whitespaces))
                  .font(.caption2)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Capsule().fill(.blue.opacity(0.1)))
                  .foregroundStyle(.blue)
              }
            }
          }

          Text("P\(skill.priority)")
            .font(.caption)
            .foregroundStyle(priorityColor)
            .fontWeight(.semibold)

          if skill.appliedCount > 0 {
            Label("\(skill.appliedCount)×", systemImage: "checkmark.circle")
              .font(.caption2)
              .foregroundStyle(.green)
          }

          Button {
            withAnimation(.spring(response: 0.25)) { isExpanded.toggle() }
          } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
              .font(.caption2)
          }
          .buttonStyle(.borderless)
        }

        HStack(spacing: 12) {
          Text(skill.source.isEmpty ? "manual" : skill.source)
            .font(.caption)
            .foregroundStyle(.secondary)

          Text(skill.updatedAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        if isExpanded, !skill.body.isEmpty {
          Divider()
          Text(skill.body)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .padding(4)
    }
  }

  private var priorityColor: Color {
    if skill.priority >= 80 { return .red }
    if skill.priority >= 50 { return .orange }
    return .secondary
  }
}

// MARK: - Subview: Worktree Row

struct RepoWorktreeRow: View {
  let worktree: UnifiedRepository.WorktreeSummary

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(worktree.branch)
          .fontWeight(.medium)
        HStack(spacing: 6) {
          Text(worktree.source)
            .font(.caption)
            .foregroundStyle(.secondary)
          if let purpose = worktree.purpose {
            Text("·")
              .foregroundStyle(.secondary)
            Text(purpose)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }

      Spacer()

      Text(worktree.taskStatus)
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
          Capsule()
            .fill(worktreeStatusColor.opacity(0.1))
        )
        .foregroundStyle(worktreeStatusColor)
    }
    .padding(.vertical, 4)
  }

  private var worktreeStatusColor: Color {
    switch worktree.taskStatus {
    case TrackedWorktree.Status.active: return .blue
    case TrackedWorktree.Status.committed: return .green
    case TrackedWorktree.Status.failed: return .red
    case TrackedWorktree.Status.orphaned: return .orange
    default: return .secondary
    }
  }
}

// MARK: - Subview: PR Row

struct RepoPRRow: View {
  let pr: UnifiedRepository.PRSummary

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("#\(pr.number) \(pr.title)")
          .lineLimit(1)
        Text(pr.state)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if pr.state == "open" {
        Image(systemName: "circle.fill")
          .font(.caption2)
          .foregroundStyle(.green)
      } else if pr.state == "closed" {
        Image(systemName: "xmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.red)
      } else if pr.state == "merged" {
        Image(systemName: "arrow.triangle.merge")
          .font(.caption2)
          .foregroundStyle(.purple)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Subview: Chain Row

struct RepoChainRow: View {
  let chain: UnifiedRepository.ChainSummary

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(chain.name)
          .fontWeight(.medium)
        Text(chain.stateDisplay)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if !chain.isTerminal {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: chain.isTerminal ? "checkmark.circle" : "play.circle")
          .foregroundStyle(chain.isTerminal ? .green : .blue)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Subview: Activity Item Row

struct RepoActivityItemRow: View {
  let item: ActivityItem

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.kind.systemImage)
        .font(.callout)
        .foregroundStyle(colorForTint(item.kind.tintColorName))
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.callout)
          .lineLimit(1)
        if let subtitle = item.subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Spacer()

      Text(item.relativeTime)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 2)
  }

  private func colorForTint(_ name: String) -> Color {
    switch name {
    case "green": return .green
    case "red": return .red
    case "blue": return .blue
    case "orange": return .orange
    case "purple": return .purple
    case "teal": return .teal
    case "gray": return .gray
    default: return .secondary
    }
  }
}


