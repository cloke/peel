//
//  RAGOverviewDetailView.swift
//  Peel
//
//  Cross-repo RAG overview shown as the detail pane when no repository is
//  selected. Provides global search, per-repo index summaries with analysis,
//  skills, lessons, and quick actions.
//

import SwiftUI
import SwiftData

// MARK: - RAG Overview Detail View

struct RAGOverviewDetailView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(DataService.self) private var dataService
  @Query(sort: \RepoGuidanceSkill.priority, order: .reverse) private var allSkills: [RepoGuidanceSkill]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        headerSection
        RAGGlobalSearchView(mcpServer: mcpServer)
        indexedReposSection
      }
      .padding(20)
    }
    .task {
      await mcpServer.refreshRagSummary()
    }
  }

  // MARK: - Header with Quick Stats

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("RAG Overview", systemImage: "magnifyingglass.circle.fill")
        .font(.title2)
        .fontWeight(.bold)

      HStack(spacing: 20) {
        let totalFiles = mcpServer.ragRepos.reduce(0) { $0 + $1.fileCount }
        let totalChunks = mcpServer.ragRepos.reduce(0) { $0 + $1.chunkCount }
        let totalEmbeddings = mcpServer.ragRepos.reduce(0) { $0 + $1.embeddingCount }
        let activeSkillCount = allSkills.filter(\.isActive).count

        StatPill(label: "Repositories", value: "\(mcpServer.ragRepos.count)", systemImage: "folder")
        StatPill(label: "Files", value: "\(totalFiles)", systemImage: "doc")
        StatPill(label: "Chunks", value: "\(totalChunks)", systemImage: "text.alignleft")
        StatPill(label: "Embeddings", value: "\(totalEmbeddings)", systemImage: "brain")
        StatPill(label: "Skills", value: "\(activeSkillCount)", systemImage: "lightbulb")

        if let model = mcpServer.ragStatus?.embeddingModelName {
          StatPill(label: "Model", value: model, systemImage: "cpu")
        }
      }
      .font(.caption)
    }
  }

  // MARK: - Indexed Repos Grid

  private var indexedReposSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader("Indexed Repositories")

      if mcpServer.ragRepos.isEmpty {
        GroupBox {
          ContentUnavailableView {
            Label("No Repositories Indexed", systemImage: "magnifyingglass")
          } description: {
            Text("Select a repository from the sidebar and use the RAG tab to index it, or add a repo path to get started.")
          }
        }
      } else {
        LazyVStack(spacing: 8) {
          ForEach(mcpServer.ragRepos, id: \.id) { repo in
            RAGOverviewRepoCard(
              repo: repo,
              mcpServer: mcpServer,
              skills: skillsForRepo(repo),
              analysisState: mcpServer.analysisState(for: repo.id, repoPath: repo.rootPath)
            )
          }
        }
      }
    }
  }

  private func skillsForRepo(_ repo: MCPServerService.RAGRepoInfo) -> [RepoGuidanceSkill] {
    let normalizedURL = repo.repoIdentifier.flatMap { RepoRegistry.shared.normalizeRemoteURL($0) }
    return allSkills.filter { skill in
      guard skill.isActive else { return false }
      // Match by path
      if !skill.repoPath.isEmpty, skill.repoPath != "*" {
        if skill.repoPath == repo.rootPath { return true }
      }
      // Match by remote URL
      if !skill.repoRemoteURL.isEmpty, let normalizedURL {
        if RepoRegistry.shared.normalizeRemoteURL(skill.repoRemoteURL) == normalizedURL {
          return true
        }
      }
      // Match by name
      if !skill.repoName.isEmpty, skill.repoName == repo.name {
        return true
      }
      // Wildcard skills apply to all
      if skill.repoPath == "*" { return true }
      return false
    }
  }
}

// MARK: - Stat Pill

private struct StatPill: View {
  let label: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
      Text(value)
        .fontWeight(.semibold)
      Text(label)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.secondary.opacity(0.06))
    )
  }
}

// MARK: - Repo Card for Overview

private struct RAGOverviewRepoCard: View {
  let repo: MCPServerService.RAGRepoInfo
  @Bindable var mcpServer: MCPServerService
  let skills: [RepoGuidanceSkill]
  let analysisState: MCPServerService.RAGRepoAnalysisState

  @State private var isExpanded = false
  @State private var isIndexing = false
  @State private var indexError: String?
  @State private var lessons: [LocalRAGLesson] = []
  @State private var isAnalyzing = false
  @State private var analyzeError: String?
  @State private var isEnriching = false
  @State private var enrichError: String?

  private var isCurrentlyIndexing: Bool {
    mcpServer.ragIndexingPath == repo.rootPath
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 0) {
        // Header — always visible
        cardHeader
          .contentShape(Rectangle())
          .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
              isExpanded.toggle()
            }
          }

        // Expanded content
        if isExpanded {
          Divider()
            .padding(.vertical, 8)
          expandedContent
        }
      }
      .padding(4)
    }
    .task {
      await loadLessons()
    }
  }

  // MARK: - Card Header

  private var cardHeader: some View {
    HStack(spacing: 12) {
      // Status badge
      statusBadge

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(repo.name)
            .fontWeight(.semibold)

          Spacer()

          // Compact indicators
          HStack(spacing: 8) {
            if !skills.isEmpty {
              Label("\(skills.count)", systemImage: "lightbulb.fill")
                .font(.caption2)
                .foregroundStyle(.green)
            }
            if !lessons.isEmpty {
              Label("\(lessons.count)", systemImage: "brain")
                .font(.caption2)
                .foregroundStyle(.purple)
            }
            if analysisState.totalChunks > 0 {
              Label("\(Int(analysisState.progress * 100))%", systemImage: "cpu")
                .font(.caption2)
                .foregroundStyle(analysisState.isComplete ? .green : .orange)
            }
          }

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        // Stats row
        HStack(spacing: 12) {
          Label("\(repo.fileCount) files", systemImage: "doc")
          Label("\(repo.chunkCount) chunks", systemImage: "text.alignleft")

          if repo.embeddingCount > 0 {
            Label("\(repo.embeddingCount) embeddings", systemImage: "brain")
              .foregroundStyle(repo.needsEmbedding ? .orange : .secondary)
          }

          if let model = repo.inferredEmbeddingModel {
            Label(model, systemImage: "cpu")
              .foregroundStyle(.blue)
          }

          if let lastIndexed = repo.lastIndexedAt {
            Text(lastIndexed, style: .relative)
              .foregroundStyle(.tertiary)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      // Action buttons
      if isCurrentlyIndexing {
        ProgressView()
          .controlSize(.small)
      } else {
        Button {
          Task { await reindex(force: false) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Re-index")
        .disabled(isIndexing)
      }
    }
  }

  // MARK: - Expanded Content

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Path
      Text(repo.rootPath)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      // Warnings
      if repo.needsEmbedding {
        Label("Needs local embeddings — re-index to generate", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      if let error = indexError {
        Label(error, systemImage: "xmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      // Analysis progress
      if analysisState.totalChunks > 0 {
        analysisSection
      }

      // Analyze / Enrich actions
      #if os(macOS)
      analyzeEnrichActions
      #endif

      // Skills
      skillsSection

      // Lessons
      lessonsSection
    }
  }

  // MARK: - Analysis Section

  private var analysisSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("AI Analysis", systemImage: "cpu")
          .font(.caption.weight(.semibold))

        Spacer()

        if analysisState.isComplete {
          Text("Complete")
            .font(.caption2)
            .foregroundStyle(.green)
        } else if analysisState.isAnalyzing || isAnalyzing {
          HStack(spacing: 4) {
            ProgressView()
              .controlSize(.mini)
            if analysisState.chunksPerSecond > 0 {
              Text("\(String(format: "%.1f", analysisState.chunksPerSecond)) chunks/sec")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          Text("\(Int(analysisState.progress * 100))%")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }

      ProgressView(value: analysisState.progress)
        .tint(analysisState.isComplete ? .green : .purple)

      Text("\(analysisState.analyzedCount) / \(analysisState.totalChunks) chunks analyzed")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(8)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - Analyze / Enrich Actions

  #if os(macOS)
  private var analyzeEnrichActions: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Index \u{2192} Analyze (AI summaries) \u{2192} Enrich (better embeddings)")
        .font(.caption2)
        .foregroundStyle(.tertiary)

      HStack(spacing: 8) {
        Button {
          Task { await analyzeChunks() }
        } label: {
          HStack(spacing: 4) {
            if isAnalyzing {
              ProgressView().controlSize(.mini)
            } else {
              Image(systemName: "cpu")
            }
            Text(isAnalyzing ? "Analyzing\u{2026}" : "Analyze")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isAnalyzing)

        Button {
          Task { await enrichEmbeddings() }
        } label: {
          HStack(spacing: 4) {
            if isEnriching {
              ProgressView().controlSize(.mini)
            } else {
              Image(systemName: "sparkles")
            }
            Text(isEnriching ? "Enriching\u{2026}" : "Enrich")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isEnriching)
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
    .padding(8)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
  #endif

  // MARK: - Skills Section

  private var skillsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Guidance Skills", systemImage: "lightbulb")
          .font(.caption.weight(.semibold))
        Spacer()
        Text("\(skills.count)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if skills.isEmpty {
        Text("No skills configured")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(skills.prefix(5), id: \.id) { skill in
            HStack(spacing: 6) {
              Circle()
                .fill(.green)
                .frame(width: 5, height: 5)
              Text(skill.title.isEmpty ? "Untitled Skill" : skill.title)
                .font(.caption)
                .lineLimit(1)
              Spacer()
              if !skill.tags.isEmpty {
                Text(skill.tags.components(separatedBy: ",").first ?? "")
                  .font(.caption2)
                  .foregroundStyle(.blue)
              }
              Text("P\(skill.priority)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          if skills.count > 5 {
            Text("+ \(skills.count - 5) more")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(8)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - Lessons Section

  private var lessonsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Learned Lessons", systemImage: "brain")
          .font(.caption.weight(.semibold))
        Spacer()
        Text("\(lessons.count)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if lessons.isEmpty {
        Text("No lessons learned yet")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(lessons.prefix(5), id: \.id) { lesson in
            HStack(spacing: 6) {
              Circle()
                .fill(lesson.confidence >= 0.7 ? .green : lesson.confidence >= 0.4 ? .orange : .red)
                .frame(width: 5, height: 5)
              Text(lesson.fixDescription)
                .font(.caption)
                .lineLimit(1)
              Spacer()
              Text("\(Int(lesson.confidence * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          if lessons.count > 5 {
            Text("+ \(lessons.count - 5) more")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(8)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - Helpers

  private var statusBadge: some View {
    Group {
      if isCurrentlyIndexing {
        Image(systemName: "arrow.triangle.2.circlepath")
          .foregroundStyle(.orange)
          .symbolEffect(.rotate, isActive: true)
      } else if repo.needsEmbedding {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(.orange)
      } else if analysisState.isComplete {
        Image(systemName: "checkmark.seal.fill")
          .foregroundStyle(.green)
      } else {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
    }
    .font(.title2)
  }

  private func reindex(force: Bool) async {
    isIndexing = true
    indexError = nil
    do {
      try await mcpServer.indexRagRepo(path: repo.rootPath, forceReindex: force)
      await mcpServer.refreshRagSummary()
    } catch {
      indexError = error.localizedDescription
    }
    isIndexing = false
  }

  private func loadLessons() async {
    do {
      lessons = try await mcpServer.listLessons(
        repoPath: repo.rootPath,
        includeInactive: false,
        limit: nil
      )
    } catch {
      // Lessons are optional — silently fail
    }
  }

  #if os(macOS)
  private func analyzeChunks() async {
    isAnalyzing = true
    analyzeError = nil
    do {
      _ = try await mcpServer.analyzeRagChunks(
        repoPath: repo.rootPath,
        limit: 500,
        progress: nil
      )
    } catch {
      analyzeError = error.localizedDescription
    }
    isAnalyzing = false
  }

  private func enrichEmbeddings() async {
    isEnriching = true
    enrichError = nil
    do {
      _ = try await mcpServer.enrichRagEmbeddings(
        repoPath: repo.rootPath,
        limit: 500,
        progress: nil
      )
      await mcpServer.refreshRagSummary()
    } catch {
      enrichError = error.localizedDescription
    }
    isEnriching = false
  }
  #endif
}
