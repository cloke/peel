//
//  LocalRAGDashboardView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftData
import SwiftUI

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
              let coreMLAssets = [
                status.coreMLModelPresent ? "model" : nil,
                status.coreMLVocabPresent ? "vocab" : nil,
                status.coreMLTokenizerHelperPresent ? "tokenizer" : nil
              ].compactMap { $0 }.joined(separator: ", ")
              if !coreMLAssets.isEmpty {
                Text("Core ML assets: \(coreMLAssets)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              } else {
                Text("Core ML assets missing")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Toggle("Use Core ML embeddings (CodeBERT)", isOn: useCoreML)
                .font(.caption)
                .toggleStyle(.switch)
                .accessibilityIdentifier("agents.localRag.useCoreML")
              if useCoreML.wrappedValue && !status.coreMLTokenizerHelperPresent {
                Text("Warning: tokenizer helper missing — embeddings will be low quality")
                  .font(.caption2)
                  .foregroundStyle(.orange)
              }
              if useCoreML.wrappedValue && (!status.coreMLModelPresent || !status.coreMLVocabPresent) {
                Text("Warning: Core ML assets missing — falling back to system embeddings")
                  .font(.caption2)
                  .foregroundStyle(.orange)
              }
              Text("Restart required to apply Core ML setting")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
              Text("Indexed \(report.filesIndexed) files · \(report.chunksIndexed) chunks · \(formatBytes(report.bytesScanned))")
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

            TextField("Query", text: query)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("agents.localRag.query")

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
            }

            Button("Search") {
              Task { await runSearch() }
            }
            .buttonStyle(.bordered)
            .disabled(isSearching || query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("agents.localRag.search")

            if isSearching {
              ProgressView()
                .scaleEffect(0.8)
            }

            if results.isEmpty {
              Text("No results yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              VStack(alignment: .leading, spacing: LayoutSpacing.item) {
                ForEach(results.indices, id: \.self) { index in
                  let result = results[index]
                  VStack(alignment: .leading, spacing: 4) {
                    Text(result.filePath)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                    Text("Lines \(result.startLine)-\(result.endLine)")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                    Text(result.snippet)
                      .font(.caption)
                      .lineLimit(3)
                      .textSelection(.enabled)
                  }
                  if index != results.indices.last {
                    Divider()
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
    if let selectedSkillId,
       let updated = mcpServer.updateRepoGuidanceSkill(
        id: selectedSkillId,
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
}
