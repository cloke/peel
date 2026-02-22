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
}