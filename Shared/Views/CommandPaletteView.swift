//
//  CommandPaletteView.swift
//  Peel
//
//  Cmd+K global search overlay. Provides quick access to RAG search
//  across all indexed repositories without leaving the current view.
//

import SwiftUI

struct CommandPaletteView: View {
  @Binding var isPresented: Bool
  @Environment(MCPServerService.self) private var mcpServer

  @State private var query = ""
  @State private var searchMode: MCPServerService.RAGSearchMode = .vector
  @State private var results: [LocalRAGSearchResult] = []
  @State private var isSearching = false
  @State private var errorMessage: String?
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Search bar
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .font(.title3)
          .foregroundStyle(.secondary)

        TextField("Search code across all repositories…", text: $query)
          .textFieldStyle(.plain)
          .font(.body)
          .focused($isSearchFocused)
          .onSubmit { Task { await runSearch() } }

        if isSearching {
          ProgressView()
            .controlSize(.small)
        }

        Picker("", selection: $searchMode) {
          Text("Vector").tag(MCPServerService.RAGSearchMode.vector)
          Text("Text").tag(MCPServerService.RAGSearchMode.text)
          Text("Hybrid").tag(MCPServerService.RAGSearchMode.hybrid)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)

        Button {
          isPresented = false
        } label: {
          Text("ESC")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
      }
      .padding(12)

      Divider()

      // Results
      if let error = errorMessage {
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title2)
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
      } else if results.isEmpty && !query.isEmpty && !isSearching {
        VStack(spacing: 8) {
          Image(systemName: "doc.text.magnifyingglass")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("No results found")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
      } else if results.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "sparkle.magnifyingglass")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("Search across all indexed repositories")
            .font(.callout)
            .foregroundStyle(.secondary)
          Text("Vector · text · or hybrid search")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(results.prefix(30).enumerated()), id: \.offset) { _, result in
              CommandPaletteResultRow(result: result)
            }
          }
          .padding(8)
        }
      }
    }
    .frame(maxWidth: 660, maxHeight: 450)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    .onAppear { isSearchFocused = true }
    .onExitCommand { isPresented = false }
  }

  private func runSearch() async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    isSearching = true
    errorMessage = nil

    do {
      results = try await mcpServer.searchRag(
        query: trimmed,
        mode: searchMode,
        limit: 30
      )
    } catch {
      errorMessage = error.localizedDescription
    }

    isSearching = false
  }
}

// MARK: - Result Row

private struct CommandPaletteResultRow: View {
  let result: LocalRAGSearchResult

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: iconForType)
          .font(.caption)
          .foregroundStyle(.blue)
          .frame(width: 16)

        Text(displayPath)
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.middle)

        if let name = result.constructName {
          Text(name)
            .font(.caption)
            .foregroundStyle(.purple)
        }

        Spacer()

        Text("L\(result.startLine)–\(result.endLine)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .monospacedDigit()

        if let score = result.score {
          Text(String(format: "%.0f%%", score * 100))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }

      Text(result.snippet.components(separatedBy: "\n").prefix(2).joined(separator: " "))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
    .contentShape(Rectangle())
  }

  private var displayPath: String {
    let path = result.filePath
    // Show last 2 path components
    let components = path.split(separator: "/")
    if components.count > 2 {
      return components.suffix(2).joined(separator: "/")
    }
    return path
  }

  private var iconForType: String {
    switch result.constructType {
    case "class", "struct": return "c.square"
    case "function", "method": return "f.square"
    case "enum": return "e.square"
    case "protocol": return "p.square"
    case "extension": return "curlybraces"
    default: return "doc.text"
    }
  }
}
