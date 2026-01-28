//
//  LocalRAGDashboardView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LocalRAGDashboardView: View {
  @Bindable var mcpServer: MCPServerService
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
  @State private var isRepoPickerPresented = false
  @State private var embeddingSettingsChanged = false

  private var providerSelection: Binding<EmbeddingProviderType> {
    Binding(
      get: { LocalRAGEmbeddingProviderFactory.preferredProvider },
      set: { newValue in
        LocalRAGEmbeddingProviderFactory.preferredProvider = newValue
        mcpServer.localRagUseCoreML = (newValue == .coreml)
        embeddingSettingsChanged = true
      }
    )
  }

  private var mlxModelSelection: Binding<String> {
    Binding(
      get: { LocalRAGEmbeddingProviderFactory.preferredMLXModelId ?? "" },
      set: { newValue in
        LocalRAGEmbeddingProviderFactory.preferredMLXModelId = newValue.isEmpty ? nil : newValue
        embeddingSettingsChanged = true
      }
    )
  }

#if os(macOS)
  private var downloadedMLXModelNames: [String] {
    let configs = MLXEmbeddingModelConfig.availableModels
    let downloaded = LocalRAGEmbeddingProviderFactory.downloadedMLXModels
    let names = downloaded.map { id in
      configs.first(where: { $0.huggingFaceId == id || $0.name == id })?.name ?? id
    }
    return Array(Set(names)).sorted()
  }
#endif

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LayoutSpacing.page) {
        // MARK: - Quick Stats Header
        if let status = mcpServer.ragStatus {
          RAGQuickStatsView(
            status: status,
            stats: mcpServer.ragStats,
            repoCount: mcpServer.ragRepos.count
          )
        }
        
        // MARK: - Indexed Repositories
        GroupBox {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            HStack {
              SectionHeader("Indexed Repositories")
              Spacer()
              Button {
                Task { await mcpServer.refreshRagSummary() }
              } label: {
                Image(systemName: "arrow.clockwise")
              }
              .buttonStyle(.borderless)
              .accessibilityIdentifier("agents.localRag.refresh")
            }
            
            // Repo list
            RAGReposListView(
              repos: mcpServer.ragRepos,
              currentlyIndexingPath: mcpServer.ragIndexingPath,
              onDelete: { repo in
                Task {
                  do {
                    _ = try await mcpServer.deleteRagRepo(repoId: repo.id)
                  } catch {
                    errorMessage = error.localizedDescription
                  }
                }
              },
              onReindex: { repo in
                repoPath.wrappedValue = repo.rootPath
                Task { await indexRepository() }
              }
            )
            
            // Indexing progress - only show while in progress, not after complete
            if let progress = mcpServer.ragIndexProgress, !progress.isComplete {
              Divider()
              VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress.progress)
                  .progressViewStyle(.linear)
                Text(progress.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            
            Divider()
            
            // Add new repo
            HStack(spacing: LayoutSpacing.item) {
              TextField("Repository path to index", text: repoPath)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agents.localRag.repoPath")

              Button("Browse") {
                isRepoPickerPresented = true
              }
              .buttonStyle(.bordered)
              
              Button("Index") {
                Task { await indexRepository() }
              }
              .buttonStyle(.borderedProminent)
              .disabled(isIndexing || repoPath.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("agents.localRag.index")
            }
            
            if let errorMessage {
              Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
        }

        // MARK: - Search
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

            if !queryHints.isEmpty {
              Divider()
              VStack(alignment: .leading, spacing: 6) {
                Text("Query hints")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                ForEach(queryHints) { hint in
                  Button {
                    applyQueryHint(hint)
                  } label: {
                    VStack(alignment: .leading, spacing: 2) {
                      Text(hint.query)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                      HStack(spacing: 6) {
                        Text(hint.mode.rawValue)
                        Text("\(hint.resultCount) results")
                        Text("used \(hint.useCount)×")
                      }
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                    }
                  }
                  .buttonStyle(.plain)
                }
              }
            }

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

        // MARK: - Database Info (Collapsible)
        DisclosureGroup("Database & Settings") {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            if let status = mcpServer.ragStatus {
              LabeledContent("Database", value: displayPath(for: status.dbPath))
                .font(.caption)
              LabeledContent("Schema Version", value: "v\(status.schemaVersion)")
                .font(.caption)
              LabeledContent("Embedding Provider", value: status.providerName)
                .font(.caption)
              
              if let stats = mcpServer.ragStats {
                Divider()
                LabeledContent("Total Files", value: "\(stats.fileCount)")
                  .font(.caption)
                LabeledContent("Total Chunks", value: "\(stats.chunkCount)")
                  .font(.caption)
                LabeledContent("Cached Embeddings", value: "\(stats.cacheEmbeddingCount)")
                  .font(.caption)
                LabeledContent("Database Size", value: formatBytes(stats.dbSizeBytes))
                  .font(.caption)
              }
              
              Divider()
              VStack(alignment: .leading, spacing: 8) {
                Picker("Embedding Provider", selection: providerSelection) {
                  Text("Auto").tag(EmbeddingProviderType.auto)
                  Text("MLX").tag(EmbeddingProviderType.mlx)
                  Text("Core ML").tag(EmbeddingProviderType.coreml)
                  Text("System").tag(EmbeddingProviderType.system)
                  Text("Hash (fallback)").tag(EmbeddingProviderType.hash)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("agents.localRag.provider")

#if os(macOS)
                if providerSelection.wrappedValue == .mlx {
                  Picker("MLX Model", selection: mlxModelSelection) {
                    Text("Auto-select").tag("")
                    ForEach(MLXEmbeddingModelConfig.availableModels, id: \.huggingFaceId) { model in
                      let suffix = model.isCodeOptimized ? " (code)" : ""
                      Text("\(model.name) · \(model.tier.description)\(suffix)")
                        .tag(model.huggingFaceId)
                    }
                  }
                  .pickerStyle(.menu)
                  .accessibilityIdentifier("agents.localRag.mlxModel")

                  if !downloadedMLXModelNames.isEmpty {
                    Text("Downloaded: \(downloadedMLXModelNames.joined(separator: ", "))")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  } else {
                    Text("Downloaded: none yet (models download on first use)")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
#endif

                if embeddingSettingsChanged {
                  Label("Apply to reload embedding model", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }

                if providerSelection.wrappedValue == .coreml {
                  Text(coreMLAssetsSummary(status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              
              Button("Initialize Database") {
                Task { await initializeDatabase() }
              }
              .buttonStyle(.bordered)
              .disabled(isInitializing)
              .accessibilityIdentifier("agents.localRag.init")

              Button("Apply Embedding Settings") {
                Task { await applyEmbeddingSettings() }
              }
              .buttonStyle(.bordered)
              .disabled(!embeddingSettingsChanged || isInitializing || isIndexing)
              .accessibilityIdentifier("agents.localRag.applyEmbedding")
            } else {
              Text("Database not initialized")
                .font(.caption)
                .foregroundStyle(.secondary)
              
              Button("Initialize Database") {
                Task { await initializeDatabase() }
              }
              .buttonStyle(.borderedProminent)
              .disabled(isInitializing)
              .accessibilityIdentifier("agents.localRag.init")
            }
            
            if let error = mcpServer.lastRagError {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
          .padding(.vertical, 8)
        }
        .padding(.horizontal, LayoutSpacing.item)

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
      await mcpServer.refreshRagQueryHints()
    }
    .fileImporter(
      isPresented: $isRepoPickerPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let selected = urls.first {
          repoPath.wrappedValue = selected.path
        }
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
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

  private func applyEmbeddingSettings() async {
    errorMessage = nil
    isInitializing = true
    defer { isInitializing = false }
    await mcpServer.applyRagEmbeddingSettings()
    embeddingSettingsChanged = false
  }

  private func indexRepository() async {
    let trimmed = repoPath.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    errorMessage = nil
    isIndexing = true
    defer { isIndexing = false }
    do {
      try await mcpServer.indexRagRepo(path: trimmed)
      lastIndexReport = mcpServer.lastRagIndexReport
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

  private var queryHints: [MCPServerService.RAGQueryHint] {
    mcpServer.ragQueryHints(limit: 8)
  }

  private func applyQueryHint(_ hint: MCPServerService.RAGQueryHint) {
    query.wrappedValue = hint.query
    searchMode.wrappedValue = hint.mode
    if let repoPath = hint.repoPath, !repoPath.isEmpty {
      self.repoPath.wrappedValue = repoPath
    }
  }

  private func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private func coreMLAssetsSummary(_ status: LocalRAGStore.Status) -> String {
    let present = [
      status.coreMLModelPresent ? "model" : nil,
      status.coreMLVocabPresent ? "vocab" : nil
    ].compactMap { $0 }
    let missing = [
      status.coreMLModelPresent ? nil : "model",
      status.coreMLVocabPresent ? nil : "vocab"
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

// MARK: - Quick Stats Header View

/// Displays a compact summary of RAG status including model and stats
struct RAGQuickStatsView: View {
  let status: LocalRAGStore.Status
  let stats: LocalRAGStore.Stats?
  let repoCount: Int
  
  var body: some View {
    HStack(spacing: 16) {
      // Model info
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Image(systemName: "cpu")
            .foregroundStyle(.blue)
          Text(status.embeddingModelName)
            .font(.headline)
        }
        Text("\(status.embeddingDimensions) dimensions · \(status.providerName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      // Stats pills
      HStack(spacing: 12) {
        StatPill(value: repoCount, label: "repos", icon: "folder.fill")
        
        if let stats {
          StatPill(value: stats.fileCount, label: "files", icon: "doc")
          StatPill(value: stats.chunkCount, label: "chunks", icon: "text.alignleft")
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
}

/// A compact stat display pill
private struct StatPill: View {
  let value: Int
  let label: String
  let icon: String
  
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("\(value)")
        .font(.system(.caption, design: .rounded, weight: .medium))
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.fill.tertiary, in: Capsule())
  }
}

