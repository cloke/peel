//
//  LocalRAGDashboardView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import AppKit

private struct WorkspaceDetectionDebug: Sendable, Identifiable {
  let id = UUID()
  let rootPath: String
  let resolvedRoot: String
  let readableRoot: Bool
  let scanError: String?
  let directoriesScanned: Int
  let excludedCount: Int
  let gitMarkersFound: Int
  let maxDepthReached: Int
}

private struct WorkspaceDetectionResult: Sendable {
  let repos: [String]
  let debug: WorkspaceDetectionDebug
}

private struct WorkspaceIndexSheet: View {
  let rootPath: String
  let repos: [String]
  let debugInfo: WorkspaceDetectionDebug?
  @Binding var selectedRepos: Set<String>
  let onCancel: () -> Void
  let onRescan: () -> Void
  let onIndexWorkspace: (Bool) -> Void
  let onIndexSelected: () -> Void
  @State private var confirmWorkspaceIndex = false
  @State private var excludeSubrepos = true
  @State private var didAutoRescan = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Workspace detected")
            .font(.title3)
            .fontWeight(.semibold)

          Text("This folder contains multiple repositories. Index them individually for better results, or index the whole workspace if you prefer.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)

          VStack(alignment: .leading, spacing: 8) {
            Text("Workspace root")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(rootPath)
              .font(.caption)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
          }

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Select repositories")
                .font(.headline)
              Text("(\(repos.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button("All") {
                selectedRepos = Set(repos)
              }
              .buttonStyle(.borderless)
              Button("None") {
                selectedRepos = []
              }
              .buttonStyle(.borderless)
            }

            if repos.isEmpty {
              Text("No git repositories were detected under this folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              Button("Rescan") {
                onRescan()
              }
              .buttonStyle(.borderless)
            } else {
              List(repos, id: \.self) { repo in
                Toggle(isOn: Binding(
                  get: { selectedRepos.contains(repo) },
                  set: { isOn in
                    if isOn {
                      selectedRepos.insert(repo)
                    } else {
                      selectedRepos.remove(repo)
                    }
                  }
                )) {
                  Text(repo)
                    .font(.caption)
                    .lineLimit(2)
                }
                .toggleStyle(.checkbox)
              }
              .listStyle(.plain)
              .frame(minHeight: 200, maxHeight: 260)
              .scrollContentBackground(.hidden)
              .clipShape(RoundedRectangle(cornerRadius: 8))
            }
          }

          if let debugInfo {
            DisclosureGroup("Detection details") {
              VStack(alignment: .leading, spacing: 4) {
                Text("Resolved root: \(debugInfo.resolvedRoot)")
                Text("Readable root: \(debugInfo.readableRoot ? "Yes" : "No")")
                if let scanError = debugInfo.scanError {
                  Text("Scan error: \(scanError)")
                }
                Text("Directories scanned: \(debugInfo.directoriesScanned)")
                Text("Excluded folders: \(debugInfo.excludedCount)")
                Text("Git markers found: \(debugInfo.gitMarkersFound)")
                Text("Max depth reached: \(debugInfo.maxDepthReached)")
              }
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }

          if selectedRepos.count > 1 {
            Text("Indexing multiple repositories runs sequentially. It can take a while and may make your Mac feel sluggish while it scans and embeds files.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          Divider()

          VStack(alignment: .leading, spacing: 6) {
            Toggle("Allow indexing the entire workspace", isOn: $confirmWorkspaceIndex)
              .toggleStyle(.switch)
            Text("Whole-workspace indexing can be noisy and slower. Prefer sub-repos unless you really need cross-repo context right now.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Toggle("Exclude sub-repos (index only workspace docs)", isOn: $excludeSubrepos)
              .toggleStyle(.switch)
              .disabled(!confirmWorkspaceIndex)
            Text("Keeps the index focused on workspace-level docs and config. Turn off to index everything under the workspace.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.bottom, 8)
      }

      Divider()

      HStack {
        Button("Cancel", action: onCancel)
        Spacer()
        Button("Index Workspace") { onIndexWorkspace(excludeSubrepos) }
          .buttonStyle(.bordered)
          .disabled(!confirmWorkspaceIndex)
        Button("Index Selected", action: onIndexSelected)
          .buttonStyle(.borderedProminent)
          .disabled(selectedRepos.isEmpty)
      }
    }
    .padding(20)
    .onAppear {
      if !didAutoRescan && repos.isEmpty {
        didAutoRescan = true
        onRescan()
      }
    }
  }
}

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
  @State private var showWorkspaceSheet = false
  @State private var workspaceRootPath: String = ""
  @State private var workspaceRepos: [String] = []
  @State private var selectedWorkspaceRepos: Set<String> = []
  @State private var workspaceDebugInfo: WorkspaceDetectionDebug?
  @State private var swarmCoordinator = SwarmCoordinator.shared
  @State private var selectedWorkerId: String?
  @State private var syncError: String?
  
  // AI Analysis state (#198)
  @State private var isAnalyzing = false
  @State private var analyzeProgress: (current: Int, total: Int)?
  @State private var analyzedChunkCount: Int = 0
  @State private var unanalyzedChunkCount: Int = 0
  @State private var analyzeError: String?
  @State private var selectedAnalyzerTier: MLXAnalyzerModelTier = .auto

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

  private var mlxClearCacheAfterBatch: Binding<Bool> {
    Binding(
      get: { LocalRAGEmbeddingProviderFactory.mlxClearCacheAfterBatch },
      set: { LocalRAGEmbeddingProviderFactory.mlxClearCacheAfterBatch = $0 }
    )
  }

  private var mlxMemoryLimitGB: Binding<Double> {
    Binding(
      get: { LocalRAGEmbeddingProviderFactory.mlxMemoryLimitGB },
      set: { LocalRAGEmbeddingProviderFactory.mlxMemoryLimitGB = $0 }
    )
  }

  private var downloadedMLXModelNames: [String] {
    let configs = MLXEmbeddingModelConfig.availableModels
    let downloaded = LocalRAGEmbeddingProviderFactory.downloadedMLXModels
    let names = downloaded.map { id in
      configs.first(where: { $0.huggingFaceId == id || $0.name == id })?.name ?? id
    }
    return Array(Set(names)).sorted()
  }

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

        // MARK: - Artifact Sync
        GroupBox {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            SectionHeader("Artifact Sync")

            if !swarmCoordinator.isActive {
              Text("Start Swarm in Crown or hybrid mode to sync artifacts with peels.")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if swarmCoordinator.connectedWorkers.isEmpty {
              Text("No peels connected yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              let workers = swarmCoordinator.connectedWorkers
              let selection = Binding<String>(
                get: { selectedWorkerId ?? workers.first?.id ?? "" },
                set: { selectedWorkerId = $0 }
              )

              Picker("Peel", selection: selection) {
                ForEach(workers) { worker in
                  Text(worker.name).tag(worker.id)
                }
              }
              .pickerStyle(.menu)
              .accessibilityIdentifier("agents.localRag.sync.worker")

              HStack(spacing: LayoutSpacing.item) {
                Button("Pull from Peel") {
                  Task { await syncRagArtifacts(direction: .pull) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("agents.localRag.sync.pull")

                Button("Push to Peel") {
                  Task { await syncRagArtifacts(direction: .push) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agents.localRag.sync.push")
              }

              if let transfer = swarmCoordinator.ragTransfers.first(where: { $0.peerId == selection.wrappedValue }) {
                VStack(alignment: .leading, spacing: 4) {
                  ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
                  Text(transferStatusLabel(transfer))
                    .font(.caption2)
                    .foregroundStyle(transfer.status == .failed ? .red : .secondary)
                }
              }

              VStack(alignment: .leading, spacing: 6) {
                ForEach(workers) { worker in
                  RAGWorkerSyncRow(
                    peer: worker,
                    status: swarmCoordinator.workerStatuses[worker.id]
                  )
                }
              }
            }

            if let status = mcpServer.ragArtifactStatus {
              Divider()
              VStack(alignment: .leading, spacing: 4) {
                Text("Local bundle: \(status.manifestVersion)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                Text("Total size: \(formatBytes(status.totalBytes))")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                if let lastSyncedAt = status.lastSyncedAt {
                  Text("Last sync: \(lastSyncedAt, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let staleReason = status.staleReason {
                  Text("Stale: \(staleReason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
              }
            }

            if let syncError {
              Text(syncError)
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

        // MARK: - Dependency Graph
        GroupBox {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            SectionHeader("Dependency Graph")
            
            if let firstRepo = mcpServer.ragRepos.first {
              DependencyGraphView(
                mcpServer: mcpServer,
                repoPath: firstRepo.rootPath
              )
            } else {
              ContentUnavailableView {
                Label("No Indexed Repository", systemImage: "folder.badge.questionmark")
              } description: {
                Text("Index a repository first to explore its dependencies.")
              }
            }
          }
        }

        // MARK: - AI Code Analysis (#198)
        GroupBox {
          VStack(alignment: .leading, spacing: LayoutSpacing.item) {
            SectionHeader("AI Code Analysis")
            
            if mcpServer.ragRepos.isEmpty {
              ContentUnavailableView {
                Label("No Indexed Repository", systemImage: "cpu")
              } description: {
                Text("Index a repository first to analyze code with AI.")
              }
            } else {
              // Model tier picker
              HStack {
                Text("Model:")
                  .font(.callout)
                Picker("", selection: $selectedAnalyzerTier) {
                  Text("Auto (based on RAM)").tag(MLXAnalyzerModelTier.auto)
                  Text("Tiny (0.5B) - Fast").tag(MLXAnalyzerModelTier.tiny)
                  Text("Small (1.5B) - Balanced").tag(MLXAnalyzerModelTier.small)
                  Text("Medium (3B) - Quality").tag(MLXAnalyzerModelTier.medium)
                  Text("Large (7B) - Best").tag(MLXAnalyzerModelTier.large)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
              }
              
              // RAM recommendation
              let ramGB = Double(LocalRAGEmbeddingProviderFactory.physicalMemoryBytes()) / 1_073_741_824.0
              let recommendedTier = MLXAnalyzerModelTier.recommended(forMemoryGB: ramGB)
              Text("Recommended for \(String(format: "%.0f", ramGB)) GB RAM: \(recommendedTier.modelName)")
                .font(.caption)
                .foregroundStyle(.secondary)
              
              Divider()
              
              // Status display
              let totalChunks = analyzedChunkCount + unanalyzedChunkCount
              if totalChunks > 0 {
                HStack {
                  VStack(alignment: .leading, spacing: 4) {
                    Text("Analysis Progress")
                      .font(.headline)
                    let pct = totalChunks > 0 ? Double(analyzedChunkCount) / Double(totalChunks) * 100 : 0
                    Text("\(analyzedChunkCount) / \(totalChunks) chunks (\(String(format: "%.1f", pct))%)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  if isAnalyzing, let progress = analyzeProgress {
                    VStack(alignment: .trailing) {
                      ProgressView(value: Double(progress.current), total: Double(progress.total))
                        .frame(width: 100)
                      Text("\(progress.current)/\(progress.total)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                  }
                }
                
                ProgressView(value: Double(analyzedChunkCount), total: Double(totalChunks))
                  .tint(analyzedChunkCount == totalChunks ? .green : .blue)
              } else {
                Text("No chunks indexed yet")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              
              // Action buttons
              HStack {
                Button {
                  Task { await analyzeChunks(limit: 50) }
                } label: {
                  Label(isAnalyzing ? "Analyzing..." : "Analyze 50 Chunks", systemImage: "cpu")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAnalyzing || unanalyzedChunkCount == 0)
                
                Button {
                  Task { await analyzeChunks(limit: 500) }
                } label: {
                  Label("Analyze 500", systemImage: "cpu.fill")
                }
                .buttonStyle(.bordered)
                .disabled(isAnalyzing || unanalyzedChunkCount == 0)
                
                Spacer()
                
                Button {
                  Task { await refreshAnalysisStatus() }
                } label: {
                  Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isAnalyzing)
              }
              
              if let error = analyzeError {
                Label(error, systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            }
          }
        }
        .task {
          await refreshAnalysisStatus()
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
                  
                  // Memory management settings
                  Divider()
                  
                  Toggle("Clear GPU cache after each batch", isOn: mlxClearCacheAfterBatch)
                    .toggleStyle(.switch)
                    .font(.callout)
                    .accessibilityIdentifier("agents.localRag.mlxClearCache")
                  
                  HStack {
                    Text("Memory limit:")
                      .font(.callout)
                    TextField("GB", value: mlxMemoryLimitGB, format: .number.precision(.fractionLength(1)))
                      .textFieldStyle(.roundedBorder)
                      .frame(width: 60)
                      .accessibilityIdentifier("agents.localRag.mlxMemoryLimit")
                    Text("GB")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  
                  let physicalGB = Double(LocalRAGEmbeddingProviderFactory.physicalMemoryBytes()) / 1_073_741_824.0
                  let currentGB = Double(LocalRAGEmbeddingProviderFactory.currentProcessMemoryBytes()) / 1_073_741_824.0
                  let isHigh = LocalRAGEmbeddingProviderFactory.isMemoryPressureHigh()
                  
                  HStack(spacing: 8) {
                    Text("Current: \(String(format: "%.1f", currentGB)) GB / \(String(format: "%.0f", physicalGB)) GB RAM")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                    if isHigh {
                      Label("Memory pressure high", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                  }
                }

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
      case "agents.localRag.sync.pull":
        Task { await syncRagArtifacts(direction: .pull) }
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.localRag.sync.push":
        Task { await syncRagArtifacts(direction: .push) }
        mcpServer.recordUIActionHandled(action.controlId)
      default:
        break
      }
      mcpServer.lastUIAction = nil
    }
    .sheet(isPresented: $showWorkspaceSheet) {
      WorkspaceIndexSheet(
        rootPath: workspaceRootPath,
        repos: workspaceRepos,
        debugInfo: workspaceDebugInfo,
        selectedRepos: $selectedWorkspaceRepos,
        onCancel: { showWorkspaceSheet = false },
        onRescan: {
          let detection = detectWorkspaceRepos(rootPath: workspaceRootPath)
          workspaceDebugInfo = detection.debug
          workspaceRepos = detection.repos
          selectedWorkspaceRepos = Set(detection.repos)
        },
        onIndexWorkspace: { excludeSubrepos in
          showWorkspaceSheet = false
          Task { await indexWorkspaceRoot(excludeSubrepos: excludeSubrepos) }
        },
        onIndexSelected: {
          showWorkspaceSheet = false
          Task { await indexWorkspaceRepos() }
        }
      )
      .frame(minWidth: 520, minHeight: 420)
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

  // MARK: - AI Analysis Methods (#198)
  
  private func refreshAnalysisStatus() async {
    guard let firstRepo = mcpServer.ragRepos.first else {
      analyzedChunkCount = 0
      unanalyzedChunkCount = 0
      return
    }
    
    do {
      let unanalyzed = try await mcpServer.getUnanalyzedChunkCount(repoPath: firstRepo.rootPath)
      let analyzed = try await mcpServer.getAnalyzedChunkCount(repoPath: firstRepo.rootPath)
      await MainActor.run {
        unanalyzedChunkCount = unanalyzed
        analyzedChunkCount = analyzed
      }
    } catch {
      await MainActor.run {
        analyzeError = error.localizedDescription
      }
    }
  }
  
  private func analyzeChunks(limit: Int) async {
    guard let firstRepo = mcpServer.ragRepos.first else { return }
    
    isAnalyzing = true
    analyzeError = nil
    analyzeProgress = (0, limit)
    
    defer {
      Task { @MainActor in
        isAnalyzing = false
        analyzeProgress = nil
      }
    }
    
    do {
      let count = try await mcpServer.analyzeRagChunks(
        repoPath: firstRepo.rootPath,
        limit: limit,
        modelTier: selectedAnalyzerTier
      ) { current, total in
        Task { @MainActor in
          analyzeProgress = (current, total)
        }
      }
      
      await MainActor.run {
        analyzedChunkCount += count
        unanalyzedChunkCount = max(0, unanalyzedChunkCount - count)
      }
    } catch {
      await MainActor.run {
        analyzeError = error.localizedDescription
      }
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
    let detection = detectWorkspaceRepos(rootPath: trimmed)
    workspaceDebugInfo = detection.debug
    let workspaceCandidates = detection.repos
    if workspaceCandidates.count >= 2 {
      workspaceRootPath = trimmed
      workspaceRepos = workspaceCandidates
      selectedWorkspaceRepos = Set(workspaceCandidates)
      showWorkspaceSheet = true
      return
    }
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

  private func indexWorkspaceRoot(excludeSubrepos: Bool) async {
    errorMessage = nil
    isIndexing = true
    defer { isIndexing = false }
    do {
      try await mcpServer.indexRagRepo(
        path: workspaceRootPath,
        allowWorkspace: true,
        excludeSubrepos: excludeSubrepos
      )
      lastIndexReport = mcpServer.lastRagIndexReport
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func indexWorkspaceRepos() async {
    let repos = workspaceRepos.filter { selectedWorkspaceRepos.contains($0) }
    guard !repos.isEmpty else { return }
    errorMessage = nil
    isIndexing = true
    defer { isIndexing = false }
    for repo in repos {
      repoPath.wrappedValue = repo
      do {
        try await mcpServer.indexRagRepo(path: repo)
        lastIndexReport = mcpServer.lastRagIndexReport
      } catch {
        errorMessage = error.localizedDescription
        break
      }
    }
  }

  private func detectWorkspaceRepos(rootPath: String) -> WorkspaceDetectionResult {
    let rootURL = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
    let readableRoot = FileManager.default.isReadableFile(atPath: rootURL.path)
    let excluded = Set([".git", ".build", ".swiftpm", "build", "dist", "DerivedData", "node_modules", "coverage", "tmp", "Carthage", ".turbo", "__snapshots__", "vendor"])
    let maxDepth = 4
    var repos: [String] = []
    var directoriesScanned = 0
    var excludedCount = 0
    var gitMarkersFound = 0
    var maxDepthReached = 0
    var scanError: String? = nil

    var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]
    while !queue.isEmpty {
      let current = queue.removeFirst()
      if current.depth > maxDepth { continue }
      maxDepthReached = max(maxDepthReached, current.depth)
      let children: [URL]
      do {
        children = try FileManager.default.contentsOfDirectory(
          at: current.url,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      } catch {
        scanError = error.localizedDescription
        continue
      }

      for child in children {
        guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        if excluded.contains(child.lastPathComponent) {
          excludedCount += 1
          continue
        }
        directoriesScanned += 1
        let gitMarker = child.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitMarker.path) {
          repos.append(child.path)
          gitMarkersFound += 1
          continue
        }
        queue.append((child, current.depth + 1))
      }
    }

    return WorkspaceDetectionResult(
      repos: Array(Set(repos)).sorted(),
      debug: WorkspaceDetectionDebug(
        rootPath: rootPath,
        resolvedRoot: rootURL.path,
        readableRoot: readableRoot,
        scanError: scanError,
        directoriesScanned: directoriesScanned,
        excludedCount: excludedCount,
        gitMarkersFound: gitMarkersFound,
        maxDepthReached: maxDepthReached
      )
    )
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

  private func syncRagArtifacts(direction: RAGArtifactSyncDirection) async {
    syncError = nil
    do {
      _ = try await swarmCoordinator.requestRagArtifactSync(
        direction: direction,
        workerId: selectedWorkerId
      )
    } catch {
      syncError = error.localizedDescription
    }
  }

  private func transferStatusLabel(_ transfer: RAGArtifactTransferState) -> String {
    let bytes = "\(formatBytes(transfer.transferredBytes)) / \(formatBytes(transfer.totalBytes))"
    let direction = transfer.direction == .pull ? "Pull" : "Push"
    let role = transfer.role == .sender ? "Sending" : "Receiving"
    switch transfer.status {
    case .queued:
      return "Queued \(direction)"
    case .preparing:
      return "Preparing \(direction)"
    case .transferring:
      return "\(role) · \(bytes)"
    case .applying:
      return "Applying bundle"
    case .complete:
      return "Complete"
    case .failed:
      return "Failed: \(transfer.errorMessage ?? "Unknown error")"
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
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func openResult(_ result: LocalRAGSearchResult) {
    NSWorkspace.shared.open(URL(fileURLWithPath: result.filePath))
  }
}

private struct RAGWorkerSyncRow: View {
  let peer: ConnectedPeer
  let status: WorkerStatus?

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Text(peer.name)
        .font(.caption)
        .foregroundStyle(.primary)
      Spacer()
      if let rag = status?.ragArtifacts {
        if let staleReason = rag.staleReason {
          Text("Stale")
            .font(.caption2)
            .foregroundStyle(.orange)
          Text(staleReason)
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if let lastSyncedAt = rag.lastSyncedAt {
          Text(lastSyncedAt, format: .relative(presentation: .named))
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
          Text(rag.manifestVersion)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("No RAG status")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
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

              if let score = result.score {
                Text(String(format: "%.0f%%", score * 100))
                  .font(.caption2)
                  .fontWeight(.medium)
                  .foregroundStyle(scoreColor(score))
              }

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

            Button(action: onOpenFile) {
              Label("Open", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

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

  private func scoreColor(_ score: Float) -> Color {
    if score >= 0.8 { return .green }
    if score >= 0.6 { return .orange }
    return .secondary
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

