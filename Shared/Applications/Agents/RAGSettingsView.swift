//
//  RAGSettingsView.swift
//  Peel
//
//  Global RAG settings modal - embedding models, database info, sync settings.
//  Part of the RAG UX redesign.
//

import PeelUI
import SwiftUI

struct RAGSettingsView: View {
  @Bindable var mcpServer: MCPServerService
  @Environment(\.dismiss) private var dismiss
  
  @State private var isResetting: Bool = false
  @State private var showResetConfirmation: Bool = false
  @State private var errorMessage: String?
  
  var body: some View {
    NavigationStack {
      Form {
        // MARK: - Embedding Model Section
        Section {
          if let status = mcpServer.ragStatus {
            LabeledContent("Model") {
              Text(status.embeddingModelName)
                .foregroundStyle(.primary)
            }
            
            LabeledContent("Provider") {
              Text(status.providerName)
                .foregroundStyle(.secondary)
            }
            
            LabeledContent("Dimensions") {
              Text("\(status.embeddingDimensions)")
                .foregroundStyle(.secondary)
            }
          } else {
            Text("Loading...")
              .foregroundStyle(.secondary)
          }
        } header: {
          Label("Embedding Model", systemImage: "cpu")
        }
        
        // MARK: - Analysis Model Section
        Section {
          let ramGB = Double(LocalRAGEmbeddingProviderFactory.physicalMemoryBytes()) / 1_073_741_824.0
          let recommendedTier = MLXAnalyzerModelTier.recommended(forMemoryGB: ramGB)
          
          LabeledContent("System RAM") {
            Text("\(String(format: "%.0f", ramGB)) GB")
          }
          
          LabeledContent("Recommended Model") {
            Text(recommendedTier.modelName)
              .foregroundStyle(.green)
          }
          
          VStack(alignment: .leading, spacing: 4) {
            Text("Model Tiers")
              .font(.caption)
              .foregroundStyle(.secondary)
            
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
              GridRow {
                Text("Tiny (0.5B)")
                Text("8GB+")
                  .foregroundStyle(.secondary)
                Text("Fastest")
                  .foregroundStyle(.secondary)
              }
              GridRow {
                Text("Small (1.5B)")
                Text("12GB+")
                  .foregroundStyle(.secondary)
                Text("Balanced")
                  .foregroundStyle(.secondary)
              }
              GridRow {
                Text("Medium (3B)")
                Text("24GB+")
                  .foregroundStyle(.secondary)
                Text("Quality")
                  .foregroundStyle(.secondary)
              }
              GridRow {
                Text("Large (7B)")
                Text("48GB+")
                  .foregroundStyle(.secondary)
                Text("Best")
                  .foregroundStyle(.secondary)
              }
            }
            .font(.caption)
          }
          .padding(.top, 4)
        } header: {
          Label("Analysis Model", systemImage: "brain")
        }
        
        // MARK: - Database Section
        Section {
          if let status = mcpServer.ragStatus {
            LabeledContent("Location") {
              VStack(alignment: .trailing, spacing: 2) {
                Text(URL(fileURLWithPath: status.dbPath).lastPathComponent)
                Text(URL(fileURLWithPath: status.dbPath).deletingLastPathComponent().path)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.head)
              }
            }
            
            LabeledContent("Schema Version") {
              Text("v\(status.schemaVersion)")
            }
            
            if let stats = mcpServer.ragStats {
              LabeledContent("Total Files") {
                Text("\(stats.fileCount)")
              }
              
              LabeledContent("Total Chunks") {
                Text("\(stats.chunkCount)")
              }
            }
            
            HStack {
              Button("Open in Finder") {
                NSWorkspace.shared.selectFile(status.dbPath, inFileViewerRootedAtPath: "")
              }
              .buttonStyle(.bordered)
              
              Spacer()
              
              Button("Reset Database...", role: .destructive) {
                showResetConfirmation = true
              }
              .buttonStyle(.bordered)
            }
            .padding(.top, 4)
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
              LabeledContent("Bundle Version") {
                Text(status.manifestVersion)
                  .foregroundStyle(.secondary)
              }
              
              LabeledContent("Bundle Size") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(status.totalBytes), countStyle: .file))
              }
              
              if let lastSync = status.lastSyncedAt {
                LabeledContent("Last Sync") {
                  Text(lastSync, format: .relative(presentation: .named))
                }
              }
            }
          } else {
            Text("Start Swarm to enable artifact sync with connected peers")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Label("Artifact Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        
        // MARK: - Statistics Section
        Section {
          let usage = mcpServer.ragUsage
          
          LabeledContent("Analysis Runs") {
            Text("\(usage.analysisRuns)")
          }
          
          LabeledContent("Chunks Analyzed (All Time)") {
            Text("\(usage.chunksAnalyzedTotal)")
          }
          
          LabeledContent("Total Analysis Time") {
            Text(formatDuration(usage.totalAnalysisTimeSeconds))
          }
          
          if let lastAnalysis = usage.lastAnalysisAt {
            LabeledContent("Last Analysis") {
              Text(lastAnalysis, format: .relative(presentation: .named))
            }
          }
        } header: {
          Label("Usage Statistics", systemImage: "chart.bar")
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
    }
    .frame(minWidth: 500, minHeight: 600)
  }
  
  private func resetDatabase() async {
    isResetting = true
    defer { isResetting = false }
    
    do {
      // Delete all repos
      for repo in mcpServer.ragRepos {
        _ = try await mcpServer.deleteRagRepo(repoId: repo.id)
      }
      await mcpServer.refreshRagSummary()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 {
      return "\(Int(seconds))s"
    } else if seconds < 3600 {
      let mins = Int(seconds / 60)
      let secs = Int(seconds) % 60
      return "\(mins)m \(secs)s"
    } else {
      let hours = Int(seconds / 3600)
      let mins = Int(seconds / 60) % 60
      return "\(hours)h \(mins)m"
    }
  }
}

// MARK: - Preview

#Preview {
  RAGSettingsView(mcpServer: MCPServerService())
}
