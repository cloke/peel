import SwiftUI

struct RAGRepositoryIndexDisplayState {
  let fileCount: Int
  let chunkCount: Int
  let embeddingCount: Int
  let needsEmbedding: Bool
  let inferredEmbeddingModel: String?
  let embeddingDimensions: Int?
  let localEmbeddingDimensions: Int
  let localEmbeddingModelName: String?
  let isIndexingCurrentRepo: Bool
  let isAnyIndexingActive: Bool
  let lastIndexReport: LocalRAGIndexReport?

  init(
    fileCount: Int, chunkCount: Int, embeddingCount: Int,
    needsEmbedding: Bool, inferredEmbeddingModel: String?,
    embeddingDimensions: Int?, localEmbeddingDimensions: Int,
    localEmbeddingModelName: String?, isIndexingCurrentRepo: Bool,
    isAnyIndexingActive: Bool, lastIndexReport: LocalRAGIndexReport? = nil
  ) {
    self.fileCount = fileCount
    self.chunkCount = chunkCount
    self.embeddingCount = embeddingCount
    self.needsEmbedding = needsEmbedding
    self.inferredEmbeddingModel = inferredEmbeddingModel
    self.embeddingDimensions = embeddingDimensions
    self.localEmbeddingDimensions = localEmbeddingDimensions
    self.localEmbeddingModelName = localEmbeddingModelName
    self.isIndexingCurrentRepo = isIndexingCurrentRepo
    self.isAnyIndexingActive = isAnyIndexingActive
    self.lastIndexReport = lastIndexReport
  }
}

struct RAGRepositoryIndexSection: View {
  let state: RAGRepositoryIndexDisplayState
  @Binding var showForceReindexConfirm: Bool
  let onReindex: () async -> Void
  let onForceReindexWithAnalysisClear: () async -> Void
  let onForceReindexOnly: () async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Index", systemImage: "folder.fill")
          .font(.subheadline.weight(.semibold))

        Spacer()

        if state.isIndexingCurrentRepo {
          Text("Indexing...")
            .font(.caption)
            .foregroundStyle(.blue)
        } else {
          Text("✓ Indexed")
            .font(.caption)
            .foregroundStyle(.green)
        }
      }

      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(state.fileCount)")
            .font(.title3.weight(.medium))
          Text("files")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text("\(state.chunkCount)")
            .font(.title3.weight(.medium))
          Text("chunks")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text("\(state.embeddingCount)")
            .font(.title3.weight(.medium))
            .foregroundStyle(state.needsEmbedding ? .orange : .primary)
          Text("embeddings")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          Task { await onReindex() }
        } label: {
          Label("Re-index", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(state.isAnyIndexingActive)
        .help("Re-index changed files")

        Button {
          showForceReindexConfirm = true
        } label: {
          Label("Force Re-index", systemImage: "arrow.clockwise.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(state.isAnyIndexingActive)
        .help("Force full re-index of all files")
        .confirmationDialog(
          "Force Full Reindex?",
          isPresented: $showForceReindexConfirm,
          titleVisibility: .visible
        ) {
          Button("Reindex + Clear Analysis") {
            Task { await onForceReindexWithAnalysisClear() }
          }
          Button("Reindex Only") {
            Task { await onForceReindexOnly() }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("This will re-index all \(state.fileCount) files. Choose whether to also clear AI analysis.")
        }
      }

      // Post-reindex summary
      if !state.isIndexingCurrentRepo, let report = state.lastIndexReport {
        indexReportSummary(report)
      }

      if state.needsEmbedding {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text("No local embeddings — synced from peer with different model")
              .font(.caption)
              .foregroundStyle(.orange)
            Text("Vector search unavailable. Re-index to generate embeddings with \(state.localEmbeddingModelName ?? "local model").")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
      } else if let model = state.inferredEmbeddingModel {
        let repoDims = state.embeddingDimensions
        let hasDimMismatch = repoDims != nil && repoDims != state.localEmbeddingDimensions
        HStack(spacing: 6) {
          Image(systemName: hasDimMismatch ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundStyle(hasDimMismatch ? .orange : .green)
          VStack(alignment: .leading, spacing: 2) {
            Text("Embeddings: \(model)")
              .font(.caption)
              .foregroundStyle(hasDimMismatch ? .orange : .green)
            if hasDimMismatch {
              Text("Dimension mismatch: repo has \(repoDims ?? 0)d, local default model (\(state.localEmbeddingModelName ?? "unknown")) uses \(state.localEmbeddingDimensions)d. Queries use a per-repo embedding profile when available.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(8)
        .background((hasDimMismatch ? Color.orange : Color.green).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func indexReportSummary(_ report: LocalRAGIndexReport) -> some View {
    let durationSec = Double(report.durationMs) / 1000.0
    let parts: [String] = {
      var items = [String]()
      if report.filesIndexed > 0 {
        items.append("\(report.filesIndexed) files indexed")
      }
      if report.filesRemoved > 0 {
        items.append("\(report.filesRemoved) removed")
      }
      if report.filesSkipped > 0 {
        items.append("\(report.filesSkipped) skipped")
      }
      if report.chunksIndexed > 0 {
        items.append("\(report.chunksIndexed) chunks")
      }
      if report.embeddingCount > 0 {
        items.append("\(report.embeddingCount) embeddings")
      }
      return items
    }()

    if !parts.isEmpty {
      HStack(spacing: 6) {
        Image(systemName: "doc.text.magnifyingglass")
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("Last reindex: \(parts.joined(separator: " · "))")
            .font(.caption)
            .foregroundStyle(.primary)
          Text(String(format: "Completed in %.1fs", durationSec))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .padding(8)
      .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
  }
}