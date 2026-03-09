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
  
  // Reranker state
  @State private var rerankerEnabled: Bool = HFRerankerFactory.isEnabled
  @State private var rerankerModelId: String = HFRerankerFactory.modelId
  @State private var rerankerApiToken: String = HFRerankerFactory.apiToken ?? ""

  // Nightly sync state
  @State private var nightlySync = NightlyRAGSyncService.shared

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
      get: {
        UserDefaults.standard.ragAnalyzerEnabled
      },
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

        // MARK: - Reranker Section
        Section {
          Toggle("Enable HuggingFace reranking", isOn: $rerankerEnabled)
            .onChange(of: rerankerEnabled) { _, newValue in
              HFRerankerFactory.isEnabled = newValue
            }

          if rerankerEnabled {
            Picker("Model", selection: $rerankerModelId) {
              Text("bge-reranker-base (balanced)").tag("BAAI/bge-reranker-base")
              Text("bge-reranker-v2-m3 (fast)").tag("BAAI/bge-reranker-v2-m3")
              Text("bge-reranker-large (best quality)").tag("BAAI/bge-reranker-large")
            }
            .onChange(of: rerankerModelId) { _, newValue in
              HFRerankerFactory.modelId = newValue
            }

            LabeledContent("API Token") {
              HStack {
                SecureField("Optional — increases rate limit", text: $rerankerApiToken)
                  .textFieldStyle(.roundedBorder)
                  .frame(maxWidth: 260)
                  .onChange(of: rerankerApiToken) { _, newValue in
                    HFRerankerFactory.apiToken = newValue.isEmpty ? nil : newValue
                  }
                if !rerankerApiToken.isEmpty {
                  Button {
                    rerankerApiToken = ""
                    HFRerankerFactory.apiToken = nil
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .foregroundStyle(.secondary)
                  }
                  .buttonStyle(.plain)
                }
              }
            }
          }
        } header: {
          Label("Reranking", systemImage: "arrow.up.arrow.down")
        } footer: {
          Text("Reranking fetches more initial results then re-scores them with a cross-encoder for higher precision. Pass \"rerank\": true in rag.search to activate. An API token is optional but raises the free-tier rate limit from 100 to 1,000 requests/day.")
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
          let orderedLANPeers = SwarmPeerPreferences.ordered(peers: swarm.connectedWorkers)
          let orderedWANWorkers = SwarmPeerPreferences.ordered(workers: swarm.onDemandWorkers)
          
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
                peerSyncMenu(peers: orderedLANPeers, direction: .push)
                peerSyncMenu(peers: orderedLANPeers, direction: .pull)
              }
              .padding(.vertical, 4)
            }

            if !orderedLANPeers.isEmpty || !orderedWANWorkers.isEmpty {
              VStack(alignment: .leading, spacing: 10) {
                if !orderedLANPeers.isEmpty {
                  Picker("Preferred LAN Peer", selection: preferredLANPeerSelection) {
                    Text("Auto strongest").tag("")
                    ForEach(orderedLANPeers) { peer in
                      Text(peerMenuDisplayName(peer)).tag(peer.id)
                    }
                  }
                }

                if !orderedWANWorkers.isEmpty {
                  Picker("Preferred WAN Worker", selection: preferredWANWorkerSelection) {
                    Text("First available").tag("")
                    ForEach(orderedWANWorkers, id: \.id) { worker in
                      Text(workerMenuDisplayName(worker)).tag(worker.id)
                    }
                  }
                }

                if !orderedLANPeers.isEmpty {
                  Text("When unset, LAN pull menus prioritize higher-memory workers first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
            
            if isSyncing {
              if let transfer = SwarmCoordinator.shared.ragTransfers.first(where: {
                $0.status == .queued || $0.status == .preparing || $0.status == .transferring || $0.status == .applying
              }), transfer.totalBytes > 0 {
                VStack(alignment: .leading, spacing: 4) {
                  ProgressView(value: transfer.progress)
                  Text("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.transferredBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(transfer.totalBytes), countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              } else {
                HStack(spacing: 8) {
                  ProgressView()
                    .controlSize(.small)
                  Text(syncDirection == .push ? "Pushing…" : "Pulling…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          } else {
            Text("Start Swarm to enable artifact sync")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        } header: {
          Label("Artifact Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        
        // MARK: - Nightly Sync Section
        Section {
          Toggle(
            "Enable nightly index export",
            isOn: Binding(
              get: { nightlySync.isEnabled },
              set: { nightlySync.isEnabled = $0; if $0 { nightlySync.enable(mcpServer: mcpServer) } else { nightlySync.disable() } }
            )
          )

          if nightlySync.isEnabled {
            Picker("Run at", selection: Binding(
              get: { nightlySync.scheduleHour },
              set: { nightlySync.scheduleHour = $0 }
            )) {
              ForEach(0..<24, id: \.self) { hour in
                let formatted = String(format: "%02d:00", hour)
                Text(formatted).tag(hour)
              }
            }

            Stepper(
              "Keep \(nightlySync.maxSnapshots) snapshot\(nightlySync.maxSnapshots == 1 ? "" : "s")",
              value: Binding(
                get: { nightlySync.maxSnapshots },
                set: { nightlySync.maxSnapshots = $0 }
              ),
              in: 1...30
            )

            if let lastRun = nightlySync.lastRunAt {
              LabeledContent("Last Export") {
                Text(lastRun, style: .relative)
                  .foregroundStyle(.secondary)
              }
            }

            if let nextRun = nightlySync.nextRunAt {
              LabeledContent("Next Export") {
                Text(nextRun, style: .date)
                  .foregroundStyle(.secondary)
              }
            }

            HStack(spacing: 8) {
              Button("Export Now") {
                Task { try? await nightlySync.runExport(mcpServer: mcpServer) }
              }
              .disabled(nightlySync.isRunning)

              if nightlySync.isRunning {
                ProgressView()
                  .controlSize(.small)
              }

              Button("Rebuild Local Delta") {
                Task { await triggerFullReindex() }
              }
            }

            if let errorMsg = nightlySync.lastError {
              Text(errorMsg)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
        } header: {
          Label("Nightly Sync", systemImage: "clock.badge.checkmark")
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
  
  private func triggerFullReindex() async {
    for repo in mcpServer.ragRepos {
      _ = try? await mcpServer.localRagStore.indexRepository(path: repo.rootPath)
    }
    await mcpServer.refreshRagSummary()
  }

  // MARK: - Artifact Sync Actions

  private var preferredLANPeerSelection: Binding<String> {
    Binding(
      get: { SwarmPeerPreferences.preferredLANPeerId ?? "" },
      set: { SwarmPeerPreferences.preferredLANPeerId = $0.isEmpty ? nil : $0 }
    )
  }

  private var preferredWANWorkerSelection: Binding<String> {
    Binding(
      get: { SwarmPeerPreferences.preferredWANWorkerId ?? "" },
      set: { SwarmPeerPreferences.preferredWANWorkerId = $0.isEmpty ? nil : $0 }
    )
  }

  private func peerMenuDisplayName(_ peer: ConnectedPeer) -> String {
    let preferredSuffix = SwarmPeerPreferences.isPreferred(peer) ? " (Preferred)" : ""
    return "\(peer.displayName) · \(peer.capabilities.memoryGB)GB\(preferredSuffix)"
  }

  private func workerMenuDisplayName(_ worker: FirestoreWorker) -> String {
    let preferredSuffix = SwarmPeerPreferences.isPreferred(worker) ? " (Preferred)" : ""
    return "\(worker.displayName)\(preferredSuffix)"
  }

  @ViewBuilder
  private func peerSyncMenu(peers: [ConnectedPeer], direction: RAGArtifactSyncDirection) -> some View {
    let isPush = direction == .push
    let defaultPeer = SwarmPeerPreferences.defaultPeer(from: peers)
    let title = isPush ? "Push" : "Pull"
    let icon = isPush ? "arrow.up.to.line" : "arrow.down.to.line"

    if peers.count == 1, let peer = peers.first {
      Button {
        Task { await performPeerSync(direction: direction, workerId: peer.id) }
      } label: {
        Label("\(title) \(peer.displayName)", systemImage: icon)
      }
      .buttonStyle(.bordered)
      .disabled(isSyncing)
    } else {
      Menu {
        ForEach(peers) { peer in
          Button {
            Task { await performPeerSync(direction: direction, workerId: peer.id) }
          } label: {
            Label(peer.displayName, systemImage: "desktopcomputer")
          }
        }
      } label: {
        Label(defaultPeer.map { "\(title) \($0.displayName)" } ?? "\(title) from Peer", systemImage: icon)
      }
      .buttonStyle(.bordered)
      .disabled(isSyncing)
    }
  }
  
  private func performPeerSync(direction: RAGArtifactSyncDirection, workerId: String) async {
    isSyncing = true
    syncDirection = direction
    syncError = nil
    defer { isSyncing = false; syncDirection = nil }
    
    do {
      let coordinator = SwarmCoordinator.shared
      _ = try await coordinator.requestRagArtifactSync(direction: direction, workerId: workerId)
      await mcpServer.refreshRagSummary()
    } catch {
      syncError = error.localizedDescription
    }
  }
  
}
