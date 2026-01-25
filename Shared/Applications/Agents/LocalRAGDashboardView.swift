//
//  LocalRAGDashboardView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LocalRAGDashboardView: View {
  @Bindable var mcpServer: MCPServerService
  private var useCoreML: Binding<Bool> { $mcpServer.localRagUseCoreML }
  private var repoPath: Binding<String> { $mcpServer.localRagRepoPath }
  private var query: Binding<String> { $mcpServer.localRagQuery }
  private var searchMode: Binding<MCPServerService.RAGSearchMode> { $mcpServer.localRagSearchMode }
  private var limit: Binding<Int> { $mcpServer.localRagSearchLimit }
  @Query(sort: [
    SortDescriptor(\RepoGuidanceSkill.priority, order: .reverse),
    SortDescriptor(\RepoGuidanceSkill.updatedAt, order: .reverse)
  ]) private var repoSkills: [RepoGuidanceSkill]
  @State private var isInitializing = false
  @State private var isIndexing = false
  @State private var isSearching = false
  @State private var lastIndexReport: LocalRAGIndexReport?
  @State private var results: [LocalRAGSearchResult] = []
  @State private var errorMessage: String?
  @State private var skillsRepoFilter: String = ""
  @State private var includeInactiveSkills = false
  @State private var selectedSkillId: UUID?
  @State private var skillRepoPath: String = ""
  @State private var skillTitle: String = ""
  @State private var skillBody: String = ""
  @State private var skillSource: String = "manual"
  @State private var skillTags: String = ""
  @State private var skillPriority: Int = 0
  @State private var skillActive: Bool = true
  @State private var skillsError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LayoutSpacing.page) {
        GroupBox {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            HStack {
              SectionHeader("Local RAG")
              Spacer()
              Button("Refresh") {
                Task { await mcpServer.refreshRagSummary() }
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("agents.localRag.refresh")
            }

            if let status = mcpServer.ragStatus {
              Text("DB: \(status.dbPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("Schema: v\(status.schemaVersion) · Embeddings: \(status.providerName)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(coreMLAssetsSummary(status))
                .font(.caption2)
                .foregroundStyle(.secondary)
              Toggle("Use Core ML embeddings (CodeBERT)", isOn: useCoreML)
                .font(.caption)
                .toggleStyle(.switch)
                .accessibilityIdentifier("agents.localRag.useCoreML")
              if useCoreML.wrappedValue {
                ForEach(coreMLWarnings(status), id: \.self) { warning in
                  Text("Warning: \(warning)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
              }
              // Only show restart message if setting doesn't match current provider
              if needsCoreMLRestart(wantsCoreML: useCoreML.wrappedValue, providerName: status.providerName) {
                Text("Restart required to apply Core ML setting")
                  .font(.caption2)
                  .foregroundStyle(.orange)
              }
              Text("Extension loaded: \(status.extensionLoaded ? "Yes" : "No")")
                .font(.caption)
                .foregroundStyle(.secondary)
              if let lastInit = status.lastInitializedAt {
                Text("Last init: \(lastInit, style: .time)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            } else {
              Text("No status yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let stats = mcpServer.ragStats {
              Divider()
              Text("Repos: \(stats.repoCount) · Files: \(stats.fileCount) · Chunks: \(stats.chunkCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("Embeddings: \(stats.embeddingCount) · Cache: \(stats.cacheEmbeddingCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("DB size: \(formatBytes(stats.dbSizeBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
              if let lastIndexedAt = stats.lastIndexedAt {
                let repoLabel = stats.lastIndexedRepoPath ?? "(unknown repo)"
                Text("Last index: \(repoLabel)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(lastIndexedAt, style: .time)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }

            if let error = mcpServer.lastRagError {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            }
            if let errorMessage {
              Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
            }
            if let lastRefresh = mcpServer.lastRagRefreshAt {
              Text("Updated \(lastRefresh, style: .time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            SectionHeader("Indexing")

            TextField("Repository path", text: repoPath)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("agents.localRag.repoPath")

            Text("Used for indexing and as an optional search scope.")
              .font(.caption2)
              .foregroundStyle(.secondary)

            HStack(spacing: LayoutSpacing.item) {
              Button("Init DB") {
                Task { await initializeDatabase() }
              }
              .buttonStyle(.bordered)
              .disabled(isInitializing)
              .accessibilityIdentifier("agents.localRag.init")

              Button("Index Repo") {
                Task { await indexRepository() }
              }
              .buttonStyle(.borderedProminent)
              .disabled(isIndexing || repoPath.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("agents.localRag.index")
            }

            if isIndexing || isInitializing {
              ProgressView()
                .scaleEffect(0.8)
            }

            if let report = lastIndexReport {
              let skipInfo = report.filesSkipped > 0 ? " · \(report.filesSkipped) skipped" : ""
              Text("Indexed \(report.filesIndexed) files\(skipInfo) · \(report.chunksIndexed) chunks · \(formatBytes(report.bytesScanned))")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("Duration: \(report.durationMs) ms")
                .font(.caption2)
                .foregroundStyle(.secondary)
              if report.embeddingCount > 0 {
                let perEmbedding = report.embeddingDurationMs > 0
                  ? Double(report.embeddingDurationMs) / Double(max(report.embeddingCount, 1))
                  : 0
                Text("Embeddings: \(report.embeddingCount) vectors · \(report.embeddingDurationMs) ms (\(perEmbedding, specifier: "%.1f") ms/vector)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            SectionHeader("Search")

            HStack(spacing: LayoutSpacing.item) {
              TextField("Query", text: query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agents.localRag.query")

              Button("Search") {
                Task { await runSearch() }
              }
              .buttonStyle(.bordered)
              .disabled(isSearching || query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("agents.localRag.search")
            }

            HStack {
              Picker("Mode", selection: searchMode) {
                ForEach(MCPServerService.RAGSearchMode.allCases, id: \.self) { mode in
                  Text(mode.rawValue.capitalized).tag(mode)
                }
              }
              .pickerStyle(.segmented)
              .accessibilityIdentifier("agents.localRag.mode")

              Stepper(value: limit, in: 1...25) {
                Text("Limit: \(limit.wrappedValue)")
                  .font(.caption)
              }
              .accessibilityIdentifier("agents.localRag.limit")
              Spacer()
              if !results.isEmpty {
                Text("Results: \(results.count)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }

            if isSearching {
              ProgressView()
                .scaleEffect(0.8)
            }

            RAGSearchResultsView(
              results: results,
              query: query.wrappedValue,
              repoPath: repoPath.wrappedValue,
              mcpServer: mcpServer,
              onCopyPath: { result in copyToPasteboard(result.filePath) },
              onCopySnippet: { result in copyToPasteboard(result.snippet) },
              onOpenFile: { result in openResult(result) }
            )

            if let lastAt = mcpServer.lastRagSearchAt {
              Divider()
              VStack(alignment: .leading, spacing: 4) {
                Text("Last search")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(lastAt, style: .time)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                if let query = mcpServer.lastRagSearchQuery {
                  Text("Query: \(query)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let mode = mcpServer.lastRagSearchMode {
                  Text("Mode: \(mode.rawValue) · Limit: \(mcpServer.lastRagSearchLimit ?? 0)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let repoPath = mcpServer.lastRagSearchRepoPath {
                  Text("Repo: \(repoPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Text("Results: \(mcpServer.lastRagSearchResults.count)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            HStack {
              SectionHeader("Session Insights")
              Spacer()
              if mcpServer.ragUsage.searches > 0 {
                Button("Clear") {
                  mcpServer.clearRagSessionData()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
            }

            let usage = mcpServer.ragUsage
            let searchCount = max(1, usage.searches)
            let avgResults = Double(usage.totalResults) / Double(searchCount)

            // Session start info
            if let sessionStart = usage.sessionStartedAt {
              Text("Session started: \(sessionStart, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            // Search stats
            HStack(spacing: 16) {
              VStack(alignment: .leading, spacing: 2) {
                Text("\(usage.searches)")
                  .font(.title2.bold())
                Text("Searches")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              VStack(alignment: .leading, spacing: 2) {
                Text("\(avgResults, specifier: "%.1f")")
                  .font(.title2.bold())
                Text("Avg Results")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              VStack(alignment: .leading, spacing: 2) {
                Text("\(usage.emptySearches)")
                  .font(.title2.bold())
                  .foregroundStyle(usage.emptySearches > 0 ? .orange : .primary)
                Text("Empty")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }

            Text("Text: \(usage.textSearches) · Vector: \(usage.vectorSearches)")
              .font(.caption2)
              .foregroundStyle(.secondary)

            Divider()

            // Feedback & helpfulness
            if let helpfulRate = usage.helpfulnessRate, let fpRate = usage.falsePositiveRate {
              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 4) {
                    Image(systemName: "hand.thumbsup.fill")
                      .foregroundStyle(.green)
                    Text("\(helpfulRate * 100, specifier: "%.0f")%")
                      .font(.title3.bold())
                  }
                  Text("Helpful")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                      .foregroundStyle(fpRate > 0.3 ? .red : .orange)
                    Text("\(fpRate * 100, specifier: "%.0f")%")
                      .font(.title3.bold())
                  }
                  Text("False Positive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
            }

            Text("Feedback: \(usage.helpfulCount) helpful · \(usage.irrelevantCount) not useful")
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text("Interactions: \(usage.copyCount) copies · \(usage.openCount) opens")
              .font(.caption2)
              .foregroundStyle(.secondary)

            if let report = mcpServer.lastRagIndexReport {
              Divider()
              Text("Last index: \(displayPath(for: report.repoPath))")
                .font(.caption)
                .foregroundStyle(.secondary)
              let skipInfo = report.filesSkipped > 0 ? " (\(report.filesSkipped) skipped)" : ""
              Text("Added \(report.filesIndexed) files\(skipInfo) · \(report.chunksIndexed) chunks")
                .font(.caption2)
                .foregroundStyle(.secondary)
              if let indexedAt = mcpServer.lastRagIndexAt {
                Text(indexedAt, style: .time)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }

            if usage.skillsAdded + usage.skillsUpdated + usage.skillsDeleted > 0 {
              Divider()
              Text("Skills: +\(usage.skillsAdded) · ~\(usage.skillsUpdated) · -\(usage.skillsDeleted)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if mcpServer.ragSessionEvents.isEmpty {
              Text("No session activity yet")
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
              Divider()
              VStack(alignment: .leading, spacing: 4) {
                ForEach(mcpServer.ragSessionEvents.prefix(6)) { event in
                  VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                      .font(.caption)
                    if let detail = event.detail, !detail.isEmpty {
                      Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Text(event.timestamp, style: .time)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }

        GroupBox {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            SectionHeader("Repo Skills")

            TextField("Filter repo path", text: $skillsRepoFilter)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("agents.localRag.skills.filterPath")

            Toggle("Include inactive skills", isOn: $includeInactiveSkills)
              .toggleStyle(.switch)
              .font(.caption)
              .accessibilityIdentifier("agents.localRag.skills.showInactive")

            HStack(spacing: LayoutSpacing.item) {
              Button("New Skill") {
                resetSkillEditor()
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("agents.localRag.skills.new")

              Button("Save Skill") {
                saveSkill()
              }
              .buttonStyle(.borderedProminent)
              .disabled(skillBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("agents.localRag.skills.save")

              Button("Delete Skill") {
                deleteSelectedSkill()
              }
              .buttonStyle(.bordered)
              .disabled(selectedSkillId == nil)
              .accessibilityIdentifier("agents.localRag.skills.delete")
            }

            if let skillsError {
              Text(skillsError)
                .font(.caption)
                .foregroundStyle(.red)
            }

            if filteredSkills.isEmpty {
              Text("No skills yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              VStack(alignment: .leading, spacing: LayoutSpacing.item) {
                ForEach(filteredSkills) { skill in
                  Button {
                    selectSkill(skill)
                  } label: {
                    VStack(alignment: .leading, spacing: 4) {
                      HStack {
                        Text(skill.title.isEmpty ? "Untitled" : skill.title)
                          .font(.caption)
                          .foregroundStyle(.primary)
                        if !skill.isActive {
                          Text("Inactive")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Priority \(skill.priority)")
                          .font(.caption2)
                          .foregroundStyle(.secondary)
                      }
                      Text(skill.repoPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                      if !skill.tags.isEmpty {
                        Text("Tags: \(skill.tags)")
                          .font(.caption2)
                          .foregroundStyle(.secondary)
                      }
                      Text("Applied \(skill.appliedCount)×")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                  }
                  .buttonStyle(.plain)

                  if skill.id != filteredSkills.last?.id {
                    Divider()
                  }
                }
              }
            }

            Divider()

            TextField("Skill repo path", text: $skillRepoPath)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("agents.localRag.skills.repoPath")

            TextField("Title", text: $skillTitle)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("agents.localRag.skills.title")

            HStack(spacing: LayoutSpacing.item) {
              TextField("Source", text: $skillSource)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agents.localRag.skills.source")

              TextField("Tags", text: $skillTags)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agents.localRag.skills.tags")
            }

            Stepper(value: $skillPriority, in: -5...10) {
              Text("Priority: \(skillPriority)")
                .font(.caption)
            }
            .accessibilityIdentifier("agents.localRag.skills.priority")

            Toggle("Active", isOn: $skillActive)
              .toggleStyle(.switch)
              .font(.caption)
              .accessibilityIdentifier("agents.localRag.skills.active")

            TextEditor(text: $skillBody)
              .font(.caption)
              .frame(minHeight: 140)
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(Color.secondary.opacity(0.3))
              )
              .accessibilityIdentifier("agents.localRag.skills.body")
          }
        }
      }
      .padding(.horizontal, LayoutSpacing.page)
      .padding(.vertical, LayoutSpacing.section)
    }
    .navigationTitle("Local RAG")
    .task {
      if repoPath.wrappedValue.isEmpty {
        repoPath.wrappedValue = mcpServer.agentManager.lastUsedWorkingDirectory ?? ""
      }
      if skillsRepoFilter.isEmpty {
        skillsRepoFilter = repoPath.wrappedValue
      }
      if skillRepoPath.isEmpty {
        skillRepoPath = repoPath.wrappedValue
      }
      await mcpServer.refreshRagSummary()
    }
    .onChange(of: mcpServer.lastUIAction?.id) {
      guard let action = mcpServer.lastUIAction else { return }
      switch action.controlId {
      case "agents.localRag.refresh":
        Task { await mcpServer.refreshRagSummary() }
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.localRag.init":
        Task { await initializeDatabase() }
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.localRag.index":
        Task { await indexRepository() }
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.localRag.search":
        Task { await runSearch() }
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.localRag.skills.new":
        resetSkillEditor()
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.localRag.skills.save":
        saveSkill()
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.localRag.skills.delete":
        deleteSelectedSkill()
        mcpServer.recordUIActionHandled(action.controlId)
      default:
        break
      }
      mcpServer.lastUIAction = nil
    }
  }

  private var filteredSkills: [RepoGuidanceSkill] {
    let filter = skillsRepoFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    return repoSkills.filter { skill in
      let matchesRepo = filter.isEmpty ? true : skill.repoPath == filter
      let matchesActive = includeInactiveSkills ? true : skill.isActive
      return matchesRepo && matchesActive
    }
  }

  private func selectSkill(_ skill: RepoGuidanceSkill) {
    selectedSkillId = skill.id
    skillRepoPath = skill.repoPath
    skillTitle = skill.title
    skillBody = skill.body
    skillSource = skill.source
    skillTags = skill.tags
    skillPriority = skill.priority
    skillActive = skill.isActive
    skillsError = nil
  }

  private func resetSkillEditor() {
    selectedSkillId = nil
    skillRepoPath = skillsRepoFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? repoPath.wrappedValue
      : skillsRepoFilter
    skillTitle = ""
    skillBody = ""
    skillSource = "manual"
    skillTags = ""
    skillPriority = 0
    skillActive = true
    skillsError = nil
  }

  private func saveSkill() {
    let trimmedRepo = skillRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = skillBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRepo.isEmpty else {
      skillsError = "Repo path is required"
      return
    }
    guard !trimmedBody.isEmpty else {
      skillsError = "Skill body is required"
      return
    }
    skillsError = nil
    if let currentSkillId = selectedSkillId,
       let updated = mcpServer.updateRepoGuidanceSkill(
      id: currentSkillId,
        repoPath: trimmedRepo,
        title: skillTitle,
        body: trimmedBody,
        source: skillSource,
        tags: skillTags,
        priority: skillPriority,
        isActive: skillActive
       ) {
      selectedSkillId = updated.id
    } else if let created = mcpServer.addRepoGuidanceSkill(
      repoPath: trimmedRepo,
      title: skillTitle,
      body: trimmedBody,
      source: skillSource,
      tags: skillTags,
      priority: skillPriority,
      isActive: skillActive
    ) {
      selectedSkillId = created.id
    } else {
      skillsError = "Failed to save skill"
    }
  }

  private func deleteSelectedSkill() {
    guard let selectedSkillId else { return }
    if mcpServer.deleteRepoGuidanceSkill(id: selectedSkillId) {
      resetSkillEditor()
    } else {
      skillsError = "Failed to delete skill"
    }
  }

  private func initializeDatabase() async {
    errorMessage = nil
    isInitializing = true
    defer { isInitializing = false }
    do {
      try await mcpServer.initializeRag()
      await mcpServer.refreshRagSummary()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func indexRepository() async {
    let trimmed = repoPath.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    errorMessage = nil
    isIndexing = true
    defer { isIndexing = false }
    do {
      let report = try await mcpServer.indexRag(repoPath: trimmed)
      lastIndexReport = report
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func runSearch() async {
    let trimmed = query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    errorMessage = nil
    isSearching = true
    defer { isSearching = false }
    do {
      let results = try await mcpServer.searchRag(
        query: trimmed,
        mode: searchMode.wrappedValue,
        repoPath: repoPath.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? nil
          : repoPath.wrappedValue,
        limit: limit.wrappedValue
      )
      self.results = results
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private func coreMLAssetsSummary(_ status: LocalRAGStore.Status) -> String {
    let present = [
      status.coreMLModelPresent ? "model" : nil,
      status.coreMLVocabPresent ? "vocab" : nil,
      status.coreMLTokenizerHelperPresent ? "tokenizer" : nil
    ].compactMap { $0 }
    let missing = [
      status.coreMLModelPresent ? nil : "model",
      status.coreMLVocabPresent ? nil : "vocab",
      status.coreMLTokenizerHelperPresent ? nil : "tokenizer"
    ].compactMap { $0 }

    if present.isEmpty && missing.isEmpty {
      return "Core ML assets: unknown"
    }
    if missing.isEmpty {
      return "Core ML assets: \(present.joined(separator: ", "))"
    }
    if present.isEmpty {
      return "Core ML assets: missing \(missing.joined(separator: ", "))"
    }
    return "Core ML assets: \(present.joined(separator: ", ")) · missing \(missing.joined(separator: ", "))"
  }

  private func coreMLWarnings(_ status: LocalRAGStore.Status) -> [String] {
    status.assetWarnings()
  }

  /// Returns true if a restart is needed to apply the Core ML setting
  private func needsCoreMLRestart(wantsCoreML: Bool, providerName: String) -> Bool {
    let isCoreMLProvider = providerName.contains("CoreML")
    // Restart needed if setting doesn't match current provider
    return wantsCoreML != isCoreMLProvider
  }

  private func displayPath(for path: String) -> String {
    let trimmedRepo = repoPath.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRepo.isEmpty, path.hasPrefix(trimmedRepo) else {
      return path
    }
    let relative = path.dropFirst(trimmedRepo.count)
    let cleaned = relative.hasPrefix("/") ? relative.dropFirst() : relative
    return String(cleaned)
  }

  private func copyToPasteboard(_ text: String) {
#if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#else
    UIPasteboard.general.string = text
#endif
  }

#if os(macOS)
  private func openResult(_ result: LocalRAGSearchResult) {
    NSWorkspace.shared.open(URL(fileURLWithPath: result.filePath))
  }
#endif
}

// MARK: - RAG Search Results View

/// Displays search results with file path, line range, and snippet preview.
/// Provides quick actions: copy path, copy snippet, open file, and feedback.
struct RAGSearchResultsView: View {
  let results: [LocalRAGSearchResult]
  let query: String
  let repoPath: String
  let mcpServer: MCPServerService
  var onCopyPath: (LocalRAGSearchResult) -> Void = { _ in }
  var onCopySnippet: (LocalRAGSearchResult) -> Void = { _ in }
  var onOpenFile: (LocalRAGSearchResult) -> Void = { _ in }

  @State private var expandedIndices: Set<Int> = []

  var body: some View {
    if results.isEmpty {
      emptyStateView
    } else {
      resultsListView
    }
  }

  @ViewBuilder
  private var emptyStateView: some View {
    VStack(spacing: 8) {
      if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Image(systemName: "magnifyingglass")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("Enter a query to search")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("Use text mode for exact matches, vector mode for semantic search.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      } else {
        Image(systemName: "doc.questionmark")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("No results found")
          .font(.caption)
          .foregroundStyle(.secondary)
        if !repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Try clearing the repo filter or using a different search mode.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        } else {
          Text("Try a different query or search mode.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 16)
  }

  private var resultsListView: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(results.indices, id: \.self) { index in
        RAGSearchResultRow(
          result: results[index],
          repoPath: repoPath,
          isExpanded: expandedIndices.contains(index),
          onToggle: { toggleExpanded(index) },
          onCopyPath: { onCopyPath(results[index]); mcpServer.recordRagUserAction(.copyPath, result: results[index]) },
          onCopySnippet: { onCopySnippet(results[index]); mcpServer.recordRagUserAction(.copySnippet, result: results[index]) },
          onOpenFile: { onOpenFile(results[index]); mcpServer.recordRagUserAction(.openFile, result: results[index]) },
          onMarkHelpful: { mcpServer.recordRagUserAction(.markHelpful, result: results[index]) },
          onMarkIrrelevant: { mcpServer.recordRagUserAction(.markIrrelevant, result: results[index]) }
        )

        if index != results.indices.last {
          Divider()
            .padding(.vertical, 4)
        }
      }
    }
  }

  private func toggleExpanded(_ index: Int) {
    if expandedIndices.contains(index) {
      expandedIndices.remove(index)
    } else {
      expandedIndices.insert(index)
    }
  }
}

// MARK: - RAG Search Result Row

/// Individual search result row with expandable snippet preview.
struct RAGSearchResultRow: View {
  let result: LocalRAGSearchResult
  let repoPath: String
  let isExpanded: Bool
  var onToggle: () -> Void = {}
  var onCopyPath: () -> Void = {}
  var onCopySnippet: () -> Void = {}
  var onOpenFile: () -> Void = {}
  var onMarkHelpful: () -> Void = {}
  var onMarkIrrelevant: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Header row - always visible
      Button(action: onToggle) {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 12)

          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
              Image(systemName: languageIcon(for: result.filePath))
                .font(.caption2)
                .foregroundStyle(.secondary)
              Text(displayPath)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            HStack(spacing: 8) {
              Label("L\(result.startLine)–\(result.endLine)", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.caption2)
                .foregroundStyle(.secondary)

              Text(snippetPreview)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
          }

          Spacer()
        }
      }
      .buttonStyle(.plain)

      // Expanded content
      if isExpanded {
        VStack(alignment: .leading, spacing: 8) {
          // Full snippet with syntax highlighting styling
          ScrollView(.horizontal, showsIndicators: false) {
            Text(result.snippet)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(8)
          .background(Color.primary.opacity(0.03))
          .clipShape(RoundedRectangle(cornerRadius: 6))

          // Action buttons
          HStack(spacing: 8) {
            Button(action: onCopyPath) {
              Label("Copy Path", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: onCopySnippet) {
              Label("Copy Snippet", systemImage: "text.quote")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

#if os(macOS)
            Button(action: onOpenFile) {
              Label("Open", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
#endif

            Spacer()

            Button(action: onMarkHelpful) {
              Image(systemName: "hand.thumbsup")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.green)

            Button(action: onMarkIrrelevant) {
              Image(systemName: "hand.thumbsdown")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
          }
        }
        .padding(.leading, 20)
      }
    }
    .padding(.vertical, 4)
  }

  private var displayPath: String {
    let trimmedRepo = repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRepo.isEmpty, result.filePath.hasPrefix(trimmedRepo) else {
      // Show just filename if no repo context
      return URL(fileURLWithPath: result.filePath).lastPathComponent
    }
    let relative = result.filePath.dropFirst(trimmedRepo.count)
    let cleaned = relative.hasPrefix("/") ? relative.dropFirst() : relative
    return String(cleaned)
  }

  private var snippetPreview: String {
    let firstLine = result.snippet.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""
    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "(empty)" : String(trimmed.prefix(60))
  }

  private func languageIcon(for path: String) -> String {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "py": return "chevron.left.forwardslash.chevron.right"
    case "js", "ts", "jsx", "tsx": return "j.square"
    case "rs": return "r.square"
    case "rb": return "r.square.fill"
    case "md": return "doc.richtext"
    case "json", "yaml", "yml": return "curlybraces"
    default: return "doc.text"
    }
  }
}

