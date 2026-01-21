//
//  LocalRAGDashboardView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

struct LocalRAGDashboardView: View {
  @Bindable var mcpServer: MCPServerService
  private var useCoreML: Binding<Bool> { $mcpServer.localRagUseCoreML }
  private var repoPath: Binding<String> { $mcpServer.localRagRepoPath }
  private var query: Binding<String> { $mcpServer.localRagQuery }
  private var searchMode: Binding<MCPServerService.RAGSearchMode> { $mcpServer.localRagSearchMode }
  private var limit: Binding<Int> { $mcpServer.localRagSearchLimit }
  @State private var isInitializing = false
  @State private var isIndexing = false
  @State private var isSearching = false
  @State private var lastIndexReport: LocalRAGIndexReport?
  @State private var results: [LocalRAGSearchResult] = []
  @State private var errorMessage: String?

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
      }
      .padding(.horizontal, LayoutSpacing.page)
      .padding(.vertical, LayoutSpacing.section)
    }
    .navigationTitle("Local RAG")
    .task {
      if repoPath.wrappedValue.isEmpty {
        repoPath.wrappedValue = mcpServer.agentManager.lastUsedWorkingDirectory ?? ""
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
      default:
        break
      }
      mcpServer.lastUIAction = nil
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
