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
  @State private var isApplyingSettings = false
  
  // Database state
  @State private var isResetting: Bool = false
  @State private var showResetConfirmation: Bool = false
  @State private var isInitializing = false
  @State private var errorMessage: String?
  
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
          Label("Embedding Provider", systemImage: "cpu")
        } footer: {
          Text("MLX uses GPU acceleration for fast local embeddings. System uses Apple's NaturalLanguage framework.")
        }
        
        // MARK: - Analysis Model Section
        Section {
          let ramGB = Double(LocalRAGEmbeddingProviderFactory.physicalMemoryBytes()) / 1_073_741_824.0
          let recommendedTier = MLXAnalyzerModelTier.recommended(forMemoryGB: ramGB)
          
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Recommended: \(recommendedTier.modelName)")
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
              modelTierRow("Tiny (0.5B)", ram: "8GB+", speed: "Fastest", selected: recommendedTier == .tiny)
              modelTierRow("Small (1.5B)", ram: "12GB+", speed: "Balanced", selected: recommendedTier == .small)
              modelTierRow("Medium (3B)", ram: "24GB+", speed: "Quality", selected: recommendedTier == .medium)
              modelTierRow("Large (7B)", ram: "48GB+", speed: "Best", selected: recommendedTier == .large)
            }
            .padding(.vertical, 4)
          }
        } header: {
          Label("Analysis Model", systemImage: "brain")
        } footer: {
          Text("Analysis adds semantic understanding to chunks for better search quality.")
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
          
          if swarm.isActive {
            LabeledContent("Connected Peers") {
              Text("\(swarm.connectedWorkers.count)")
            }
            
            if let status = mcpServer.ragArtifactStatus {
              LabeledContent("Bundle Size") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(status.totalBytes), countStyle: .file))
                  .foregroundStyle(.secondary)
              }
              
              if let lastSync = status.lastSyncedAt {
                LabeledContent("Last Sync") {
                  Text(lastSync, format: .relative(presentation: .named))
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
}
