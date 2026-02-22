import AppKit
import Foundation
import SwiftUI

enum RAGRepositorySearchMode: String {
  case vector
  case text
}

struct RAGRepositorySearchDisplayResult {
  let filePath: String
  let startLine: Int
  let endLine: Int
  let score: Double?
}

struct RAGRepositorySearchSection: View {
  @Binding var searchQuery: String
  @Binding var searchMode: RAGRepositorySearchMode
  let searchResults: [RAGRepositorySearchDisplayResult]
  @Binding var isSearching: Bool

  let runSearch: () async -> Void
  let languageIcon: (String) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Search This Repo", systemImage: "magnifyingglass")
        .font(.subheadline.weight(.semibold))

      HStack(spacing: 8) {
        TextField("Search query...", text: $searchQuery)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            Task { await runSearch() }
          }

        Picker("", selection: $searchMode) {
          Text("Vector").tag(RAGRepositorySearchMode.vector)
          Text("Text").tag(RAGRepositorySearchMode.text)
        }
        .pickerStyle(.segmented)
        .frame(width: 120)

        Button {
          Task { await runSearch() }
        } label: {
          if isSearching {
            ProgressView()
              .scaleEffect(0.7)
          } else {
            Image(systemName: "arrow.right.circle.fill")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
      }

      if !searchResults.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(searchResults.prefix(5), id: \.filePath) { result in
            searchResultRow(result)
          }

          if searchResults.count > 5 {
            Text("+ \(searchResults.count - 5) more results")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.top, 4)
      }
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func searchResultRow(_ result: RAGRepositorySearchDisplayResult) -> some View {
    HStack(spacing: 8) {
      Image(systemName: languageIcon(result.filePath))
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 1) {
        Text(URL(fileURLWithPath: result.filePath).lastPathComponent)
          .font(.caption)
          .lineLimit(1)

        Text("L\(result.startLine)–\(result.endLine)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if let score = result.score {
        Text("\(Int(score * 100))%")
          .font(.caption2)
          .foregroundStyle(score >= 0.8 ? .green : score >= 0.6 ? .orange : .secondary)
      }

      Button {
        NSWorkspace.shared.open(URL(fileURLWithPath: result.filePath))
      } label: {
        Image(systemName: "arrow.up.forward")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
    .padding(.vertical, 2)
  }
}
