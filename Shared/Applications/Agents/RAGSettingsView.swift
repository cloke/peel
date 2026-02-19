//
//  RAGSettingsView.swift
//  Peel
//
//  Global RAG settings - embedding provider config, database info, sync settings.
//  Accessible from RAG Dashboard toolbar (⚙️ button).
//

import PeelUI
import SwiftUI

struct RAGSettingsView: View {
  @Bindable var mcpServer: MCPServerService
  @Environment(\.dismiss) private var dismiss
  
  // Embedding settings state
  @State private var embeddingSettingsChanged = false
  @State private var analysisSettingsChanged = false
  @State private var isApplyingSettings = false
  
  // Database state
  @State private var isResetting: Bool = false
  @State private var showResetConfirmation: Bool = false
  @State private var isInitializing = false
  @State private var errorMessage: String?
  
  // Sync state
  @State private var isSyncing = false
  @State private var syncDirection: RAGArtifactSyncDirection?
  @State private var syncError: String?
  @State private var firestoreArtifacts: [FirestoreRAGArtifact] = []
  @State private var isLoadingArtifacts = false
  @State private var showFirestorePull = false
  
  // Bindings for embedding settings
  private var providerSelection: Binding<EmbeddingProviderType> {
    Binding(
      get: { LocalRAGEmbeddingProviderFactory.preferredProvider },
      set: { newValue in
        LocalRAGEmbeddingProviderFactory.preferredProvider = newValue
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
    return downloaded.compactMap { id in
      configs.first(where: { $0.huggingFaceId == id || $0.name == id })?.name ?? id
    }.sorted()
  }
  
  // Bindings for analysis settings
  private var analysisEnabled: Binding<Bool> {
    Binding(
      get: { UserDefaults.standard.bool(forKey: "rag.analyzer.enabled") },
      set: { newValue in
        UserDefaults.standard.set(newValue, forKey: "rag.analyzer.enabled")
        analysisSettingsChanged = true
      }
    )
  }
  
  private var analyzerTierSelection: Binding<String> {
    Binding(
      get: { UserDefaults.standard.string(forKey: "rag.analyzer.tier") ?? "" },
      set: { newValue in
        if newValue.isEmpty {
          UserDefaults.standard.removeObject(forKey: "rag.analyzer.tier")
        } else {
          UserDefaults.standard.set(newValue, forKey: "rag.analyzer.tier")
        }
        analysisSettingsChanged = true
      }
    )
  }
  
  var body: some View {
    NavigationStack {
      Form {
        // MARK: - Embedding Provider Section
        Section {
          // Provider picker
          Picker("Provider", selection: providerSelection) {
            Text("Auto (recommended)").tag(EmbeddingProviderType.auto)
            Text("MLX (GPU accelerated)").tag(EmbeddingProviderType.mlx)
            Text("System (Apple NL)").tag(EmbeddingProviderType.system)
            Text("Hash (fallback)").tag(EmbeddingProviderType.hash)
          }
          
          // Current status
          if let status = mcpServer.ragStatus {
            LabeledContent("Active Model") {
              Text(status.embeddingModelName)
                .foregroundStyle(.secondary)
            }
            
            LabeledContent("Dimensions") {
              Text("\(status.embeddingDimensions)")
                .foregroundStyle(.secondary)
            }
          }
          
          // MLX-specific settings
          if providerSelection.wrappedValue == .mlx {
            Divider()
            mlxSettingsSection
          }
          
          // Apply changes banner
          if embeddingSettingsChanged {
            HStack(spacing: 12) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
              Text("Settings changed")
                .font(.callout)
              Spacer()
              Button("Apply") {
                Task { await applyEmbeddingSettings() }
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              .disabled(isApplyingSettings)
            }
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
          }
        } header: {
          HStack(spacing: 4) {
            Label("Embedding Provider", systemImage: "cpu")
            HelpButton(topic: .ragIndexing)
          }
        } footer: {
          Text("MLX uses GPU acceleration for fast local embeddings. System uses Apple's NaturalLanguage framework.")
        }
        
        // MARK: - Analysis Model Section
        Section {
          let ramGB = Double(LocalRAGEmbeddingProviderFactory.physicalMemoryBytes()) / 1_073_741_824.0
          let recommendedTier = MLXAnalyzerModelTier.recommended(forMemoryGB: ramGB)
          let selectedTierRaw = analyzerTierSelection.wrappedValue
          let selectedTier = MLXAnalyzerModelTier(rawValue: selectedTierRaw)
          let effectiveTier = selectedTier ?? recommendedTier
          
          Toggle("Enable AI analysis during indexing", isOn: analysisEnabled)
          
          if analysisEnabled.wrappedValue {
            Picker("Model Tier", selection: analyzerTierSelection) {
              Text("Auto (\(recommendedTier.modelName))").tag("")
              ForEach(MLXAnalyzerModelTier.allCases.filter { $0 != .auto }, id: \.rawValue) { tier in
                Text(tier.description).tag(tier.rawValue)
              }
            }
            
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text("Active: \(effectiveTier.modelName)")
                  .font(.callout.weight(.medium))
                Text("Based on \(String(format: "%.0f", ramGB)) GB RAM")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
            
            DisclosureGroup("Model Tiers") {
              VStack(alignment: .leading, spacing: 8) {
                modelTierRow("Tiny (0.5B)", ram: "8GB+", speed: "Fastest", selected: effectiveTier == .tiny)
                modelTierRow("Small (1.5B)", ram: "12GB+", speed: "Balanced", selected: effectiveTier == .small)
                modelTierRow("Medium (3B)", ram: "24GB+", speed: "Quality", selected: effectiveTier == .medium)
                modelTierRow("Large (7B)", ram: "48GB+", speed: "Best", selected: effectiveTier == .large)
              }
              .padding(.vertical, 4)
            }
          }
          
          // Apply changes banner
          if analysisSettingsChanged {
            HStack(spacing: 12) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
              Text("Settings changed")
                .font(.callout)
              Spacer()
              Button("Apply") {
                Task { await applyAnalysisSettings() }
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              .disabled(isApplyingSettings)
            }
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
          }
        } header: {
          Label("Analysis Model", systemImage: "brain")
        } footer: {
          Text("Analysis adds semantic understanding to chunks for better search quality. Disable to speed up indexing.")
        }
        
        // MARK: - Database Section
        Section {
          if let status = mcpServer.ragStatus {
            LabeledContent("Location") {
              Button {
                NSWorkspace.shared.selectFile(status.dbPath, inFileViewerRootedAtPath: "")
              } label: {
                HStack(spacing: 4) {
                  Text(URL(fileURLWithPath: status.dbPath).lastPathComponent)
                  Image(systemName: "arrow.up.forward.square")
                    .font(.caption)
                }
              }
              .buttonStyle(.plain)
              .foregroundStyle(.blue)
            }
            
            LabeledContent("Schema") {
              Text("v\(status.schemaVersion)")
                .foregroundStyle(.secondary)
            }
            
            if let stats = mcpServer.ragStats {
              LabeledContent("Indexed") {
                Text("\(stats.fileCount) files · \(stats.chunkCount) chunks")
                  .foregroundStyle(.secondary)
              }
              
              LabeledContent("Database Size") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(stats.dbSizeBytes), countStyle: .file))
                  .foregroundStyle(.secondary)
              }
            }
          } else {
            HStack {
              Text("Database not initialized")
                .foregroundStyle(.secondary)
              Spacer()
              Button("Initialize") {
                Task { await initializeDatabase() }
              }
              .buttonStyle(.bordered)
              .disabled(isInitializing)
            }
          }
          
          if mcpServer.ragStatus != nil {
            Button("Reset Database...", role: .destructive) {
              showResetConfirmation = true
            }
          }
        } header: {
          Label("Database", systemImage: "cylinder.split.1x2")
        }
        
        // MARK: - Artifact Sync Section
        Section {
          let swarm = SwarmCoordinator.shared
          let firebase = FirebaseService.shared
          
          if swarm.isActive || firebase.activeSwarm != nil {
            if swarm.isActive {
              LabeledContent("Connected Peers") {
                Text("\(swarm.connectedWorkers.count)")
              }
            }
            
            if let status = mcpServer.ragArtifactStatus {
              LabeledContent("Bundle Size") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(status.totalBytes), countStyle: .file))
                  .foregroundStyle(.secondary)
              }
              
              if let lastSync = status.lastSyncedAt {
                LabeledContent("Last Sync") {
                  RelativeTimeText(lastSync)
                    .foregroundStyle(.secondary)
                }
              }
            }
            
            if let syncError {
              Text(syncError)
                .font(.caption)
                .foregroundStyle(.red)
            }
            
            // Peer-to-peer sync buttons (requires active swarm with connected peers)
            if swarm.isActive && !swarm.connectedWorkers.isEmpty &&
               (swarm.role == .brain || swarm.role == .hybrid) {
              HStack(spacing: 12) {
                Button {
                  Task { await performPeerSync(direction: .push) }
                } label: {
                  Label("Push to Peer", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.bordered)
                .disabled(isSyncing)
                
                Button {
                  Task { await performPeerSync(direction: .pull) }
                } label: {
                  Label("Pull from Peer", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.bordered)
                .disabled(isSyncing)
              }
              .padding(.vertical, 4)
            }
            
            // Firestore sync buttons (requires Firebase swarm)
            if let activeSwarm = firebase.activeSwarm {
              Divider()
              
              HStack(spacing: 12) {
                Button {
                  Task { await performFirestorePush(swarmId: activeSwarm.id) }
                } label: {
                  Label("Push to Cloud", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(isSyncing)
                
                Button {
                  showFirestorePull = true
                  Task { await loadFirestoreArtifacts(swarmId: activeSwarm.id) }
                } label: {
                  Label("Pull from Cloud", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(isSyncing)
              }
              .padding(.vertical, 4)
            }
            
            if isSyncing {
              HStack(spacing: 8) {
                ProgressView()
                  .controlSize(.small)
                Text(syncDirection == .push ? "Pushing…" : "Pulling…")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          } else {
            Text("Start Swarm or join a Firestore swarm to enable artifact sync")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        } header: {
          Label("Artifact Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        .sheet(isPresented: $showFirestorePull) {
          firestorePullSheet
        }
        
        // MARK: - Usage Statistics
        Section {
          let usage = mcpServer.ragUsage
          
          HStack(spacing: 24) {
            VStack {
              Text("\(usage.searches)")
                .font(.title2.weight(.semibold))
              Text("Searches")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            VStack {
              Text("\(usage.indexRuns)")
                .font(.title2.weight(.semibold))
              Text("Index Runs")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            VStack {
              Text("\(usage.analysisRuns)")
                .font(.title2.weight(.semibold))
              Text("Analyses")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
        } header: {
          Label("Session Statistics", systemImage: "chart.bar")
        }
      }
      .formStyle(.grouped)
      .navigationTitle("RAG Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .alert("Reset RAG Database?", isPresented: $showResetConfirmation) {
        Button("Cancel", role: .cancel) { }
        Button("Reset", role: .destructive) {
          Task { await resetDatabase() }
        }
      } message: {
        Text("This will delete all indexed repositories and embeddings. You will need to re-index your repositories.")
      }
      .task {
        await mcpServer.refreshRagSummary()
      }
    }
    .frame(minWidth: 500, minHeight: 600)
  }
  
  // MARK: - MLX Settings Section
  
  @ViewBuilder
  private var mlxSettingsSection: some View {
    // Model picker
    Picker("Model", selection: mlxModelSelection) {
      Text("Auto-select").tag("")
      ForEach(MLXEmbeddingModelConfig.availableModels, id: \.huggingFaceId) { model in
        let suffix = model.isCodeOptimized ? " (code)" : ""
        Text("\(model.name) · \(model.tier.description)\(suffix)")
          .tag(model.huggingFaceId)
      }
    }
    
    // Downloaded models info
    if !downloadedMLXModelNames.isEmpty {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.caption)
        Text("Downloaded: \(downloadedMLXModelNames.joined(separator: ", "))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    
    Divider()
    
    // Memory settings
    Toggle("Clear GPU cache after each batch", isOn: mlxClearCacheAfterBatch)
    
    HStack {
      Text("Memory limit")
      Spacer()
      TextField("", value: mlxMemoryLimitGB, format: .number.precision(.fractionLength(1)))
        .textFieldStyle(.roundedBorder)
        .frame(width: 60)
        .multilineTextAlignment(.trailing)
      Text("GB")
        .foregroundStyle(.secondary)
    }
    
    // Memory status bar
    let physicalGB = Double(LocalRAGEmbeddingProviderFactory.physicalMemoryBytes()) / 1_073_741_824.0
    let currentGB = Double(LocalRAGEmbeddingProviderFactory.currentProcessMemoryBytes()) / 1_073_741_824.0
    let isHigh = LocalRAGEmbeddingProviderFactory.isMemoryPressureHigh()
    
    HStack(spacing: 8) {
      MemoryBar(current: currentGB, total: physicalGB)
      Text("\(String(format: "%.1f", currentGB)) / \(String(format: "%.0f", physicalGB)) GB")
        .font(.caption)
        .foregroundStyle(.secondary)
      if isHigh {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.caption)
      }
    }
  }
  
  // MARK: - Helper Views
  
  private func modelTierRow(_ name: String, ram: String, speed: String, selected: Bool) -> some View {
    HStack {
      if selected {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.caption)
      } else {
        Image(systemName: "circle")
          .foregroundStyle(.secondary)
          .font(.caption)
      }
      Text(name)
        .font(.callout)
      Spacer()
      Text(ram)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("·")
        .foregroundStyle(.tertiary)
      Text(speed)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
  
  // MARK: - Actions
  
  private func applyEmbeddingSettings() async {
    isApplyingSettings = true
    defer { isApplyingSettings = false }
    embeddingSettingsChanged = false
    await mcpServer.applyRagEmbeddingSettings()
    await mcpServer.refreshRagSummary()
  }
  
  private func applyAnalysisSettings() async {
    isApplyingSettings = true
    defer { isApplyingSettings = false }
    analysisSettingsChanged = false
    await mcpServer.applyRagEmbeddingSettings()
    await mcpServer.refreshRagSummary()
  }
  
  private func initializeDatabase() async {
    isInitializing = true
    defer { isInitializing = false }
    _ = try? await mcpServer.initializeRag()
    await mcpServer.refreshRagSummary()
  }
  
  private func resetDatabase() async {
    isResetting = true
    defer { isResetting = false }
    
    do {
      for repo in mcpServer.ragRepos {
        _ = try await mcpServer.deleteRagRepo(repoId: repo.id)
      }
      await mcpServer.refreshRagSummary()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  // MARK: - Artifact Sync Actions
  
  private func performPeerSync(direction: RAGArtifactSyncDirection) async {
    isSyncing = true
    syncDirection = direction
    syncError = nil
    defer { isSyncing = false; syncDirection = nil }
    
    do {
      let coordinator = SwarmCoordinator.shared
      _ = try await coordinator.requestRagArtifactSync(direction: direction)
      await mcpServer.refreshRagSummary()
    } catch {
      syncError = error.localizedDescription
    }
  }
  
  private func performFirestorePush(swarmId: String) async {
    isSyncing = true
    syncDirection = .push
    syncError = nil
    defer { isSyncing = false; syncDirection = nil }
    
    do {
      let ragStore = mcpServer.localRagStore
      let status = await ragStore.status()
      let stats = try? await ragStore.stats()
      let repos = (try? await ragStore.listRepos()) ?? []
      let bundle = try await LocalRAGArtifacts.createBundle(status: status, stats: stats, repos: repos)
      _ = try await FirebaseService.shared.pushRAGArtifacts(swarmId: swarmId, bundle: bundle)
      await mcpServer.refreshRagSummary()
    } catch {
      syncError = error.localizedDescription
    }
  }
  
  private func performFirestorePull(swarmId: String, artifactId: String, repoPath: String) async {
    isSyncing = true
    syncDirection = .pull
    syncError = nil
    showFirestorePull = false
    defer { isSyncing = false; syncDirection = nil }
    
    do {
      let tempDir = FileManager.default.temporaryDirectory
      let bundleURL = tempDir.appendingPathComponent("rag-artifact-\(artifactId).zip")
      
      let manifest = try await FirebaseService.shared.pullRAGArtifacts(
        swarmId: swarmId,
        artifactId: artifactId,
        destination: bundleURL
      )
      
      let bundleSize = (try? FileManager.default.attributesOfItem(atPath: bundleURL.path)[.size] as? Int) ?? 0
      let bundle = LocalRAGArtifactBundle(manifest: manifest, bundleURL: bundleURL, bundleSizeBytes: bundleSize)
      try await mcpServer.localRagStore.importArtifactBundle(bundle, for: repoPath)
      
      try? FileManager.default.removeItem(at: bundleURL)
      await mcpServer.refreshRagSummary()
    } catch {
      syncError = error.localizedDescription
    }
  }
  
  private func loadFirestoreArtifacts(swarmId: String) async {
    isLoadingArtifacts = true
    defer { isLoadingArtifacts = false }
    do {
      firestoreArtifacts = try await FirebaseService.shared.listRAGArtifacts(swarmId: swarmId)
    } catch {
      syncError = error.localizedDescription
    }
  }
  
  // MARK: - Firestore Pull Sheet
  
  @ViewBuilder
  private var firestorePullSheet: some View {
    NavigationStack {
      List {
        if isLoadingArtifacts {
          HStack {
            ProgressView()
              .controlSize(.small)
            Text("Loading artifacts…")
              .foregroundStyle(.secondary)
          }
        } else if firestoreArtifacts.isEmpty {
          Text("No artifacts available")
            .foregroundStyle(.secondary)
        } else {
          ForEach(firestoreArtifacts) { artifact in
            Button {
              // Use the first indexed repo path as default, or home dir
              let repoPath = mcpServer.ragRepos.first?.rootPath
                ?? FileManager.default.homeDirectoryForCurrentUser.path
              let swarmId = FirebaseService.shared.activeSwarm?.id ?? ""
              Task {
                await performFirestorePull(
                  swarmId: swarmId,
                  artifactId: artifact.id,
                  repoPath: repoPath
                )
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(artifact.version)
                    .font(.headline)
                  Spacer()
                  Text(artifact.formattedSize)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                  Label("\(artifact.repoCount) repos", systemImage: "folder")
                  Label("\(artifact.embeddingCacheCount) embeddings", systemImage: "brain")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(artifact.uploadedAt, style: .relative)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }
              .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .navigationTitle("Pull RAG Artifact")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showFirestorePull = false }
        }
      }
    }
    .frame(minWidth: 400, minHeight: 300)
  }
}
