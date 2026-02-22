import SwiftUI

struct RAGRepositoryAnalyzerModelOption {
  let name: String
  let tier: MLXAnalyzerModelTier
}

struct RAGRepositoryAnalysisDisplayState {
  let isComplete: Bool
  let totalChunks: Int
  let progress: Double
  let analyzedCount: Int
  let isAnalyzing: Bool
  let isPaused: Bool
  let batchProgress: (current: Int, total: Int)?
  let chunksPerSecond: Double
  let unanalyzedCount: Int
  let analysisStartTime: Date?
  let analyzeError: String?
  let statusColor: Color
}

struct RAGRepositoryAnalysisSection: View {
  let state: RAGRepositoryAnalysisDisplayState
  @Binding var selectedModelTier: MLXAnalyzerModelTier
  let availableModels: [RAGRepositoryAnalyzerModelOption]
  @Binding var showForceReanalyzeConfirm: Bool
  let remainingEstimateText: String?
  let onForceReanalyze: () async -> Void
  let onPause: () -> Void
  let onResume: () -> Void
  let onStop: () -> Void
  let onQuickSample: () async -> Void
  let onAnalyzeAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("AI Analysis", systemImage: "cpu")
          .font(.subheadline.weight(.semibold))

        Spacer()

        if state.isComplete {
          Button {
            showForceReanalyzeConfirm = true
          } label: {
            Label("Reanalyze", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
          .help("Clear AI analysis and re-run with current model tier")

          Text("✓ Complete")
            .font(.caption)
            .foregroundStyle(.green)
        } else if state.totalChunks > 0 {
          Text("\(Int(state.progress * 100))%")
            .font(.caption.weight(.medium))
            .foregroundStyle(state.statusColor)
        }
      }

      if state.totalChunks > 0 {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: state.progress)
            .tint(state.isComplete ? .green : .purple)

          HStack {
            Text("\(state.analyzedCount) / \(state.totalChunks) chunks")
              .font(.caption2)
              .foregroundStyle(.secondary)

            if state.isAnalyzing, let batch = state.batchProgress {
              Text("(\(batch.current)/\(batch.total))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }

            Spacer()

            if state.isAnalyzing, state.chunksPerSecond > 0 {
              Text("\(String(format: "%.1f", state.chunksPerSecond)) chunks/sec")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      HStack(spacing: 8) {
        Picker("", selection: $selectedModelTier) {
          Text("Auto").tag(MLXAnalyzerModelTier.auto)
          ForEach(availableModels, id: \.name) { model in
            Text(model.name).tag(model.tier)
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 180)
        .controlSize(.small)

        Spacer()

        if state.isAnalyzing {
          Button {
            onPause()
          } label: {
            Label("Pause", systemImage: "pause.fill")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.orange)
        } else if state.isPaused {
          Button {
            onResume()
          } label: {
            Label("Resume", systemImage: "play.fill")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)

          Button {
            onStop()
          } label: {
            Image(systemName: "stop.fill")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.red)
        } else {
          Button {
            Task { await onQuickSample() }
          } label: {
            Label("Quick 50", systemImage: "hare")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(state.unanalyzedCount == 0)

          Button {
            onAnalyzeAll()
          } label: {
            Label("Analyze All", systemImage: "play.fill")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(state.unanalyzedCount == 0)
        }
      }

      if state.isAnalyzing || state.isPaused {
        if let startTime = state.analysisStartTime {
          HStack(spacing: 12) {
            Text("Started: \(startTime, format: .dateTime.hour().minute())")

            if let remainingEstimateText {
              Text("Est: \(remainingEstimateText) remaining")
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }

      if let error = state.analyzeError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    .confirmationDialog(
      "Force Reanalyze?",
      isPresented: $showForceReanalyzeConfirm,
      titleVisibility: .visible
    ) {
      Button("Reanalyze All") {
        Task { await onForceReanalyze() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will clear all \(state.analyzedCount) AI summaries and re-analyze with the \(selectedModelTier == .auto ? "auto-selected" : "\(selectedModelTier)") model. Enriched embeddings will also be regenerated.")
    }
  }
}