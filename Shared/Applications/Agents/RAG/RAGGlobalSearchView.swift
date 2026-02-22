//
//  RAGGlobalSearchView.swift
//  Peel
//
//  Global search bar for searching across all indexed repositories.
//  Part of the RAG UX redesign.
//

import PeelUI
import SwiftUI

struct RAGGlobalSearchView: View {
  @Bindable var mcpServer: MCPServerService
  
  @State private var query: String = ""
  @State private var searchMode: MCPServerService.RAGSearchMode = .vector
  @State private var selectedRepoPath: String? = nil
  @State private var results: [LocalRAGSearchResult] = []
  @State private var isSearching: Bool = false
  @State private var limit: Int = 15
  @State private var errorMessage: String?
  @State private var showResults: Bool = false
  @State private var recentQueries: [String] = []
  
  // Keyboard navigation
  @FocusState private var isSearchFocused: Bool
  
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // MARK: - Search Bar
      searchBar
      
      // MARK: - Filters Row
      filtersRow
      
      // MARK: - Recent Queries
      if !recentQueries.isEmpty && query.isEmpty && isSearchFocused {
        recentQueriesView
      }
      
      // MARK: - Results
      if showResults {
        Divider()
          .padding(.top, 8)
        
        resultsView
      }
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    .onAppear {
      loadRecentQueries()
    }
  }
  
  // MARK: - Search Bar
  
  @ViewBuilder
  private var searchBar: some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.title3)
        .foregroundStyle(.secondary)
      
      TextField("Search across all repositories...", text: $query)
        .textFieldStyle(.plain)
        .font(.body)
        .focused($isSearchFocused)
        .onSubmit {
          Task { await runSearch() }
        }
      
      if !query.isEmpty {
        Button {
          query = ""
          results = []
          showResults = false
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
      
      // Mode picker
      Picker("", selection: $searchMode) {
        Label("Vector", systemImage: "brain")
          .tag(MCPServerService.RAGSearchMode.vector)
        Label("Text", systemImage: "textformat")
          .tag(MCPServerService.RAGSearchMode.text)
        Label("Hybrid", systemImage: "arrow.triangle.merge")
          .tag(MCPServerService.RAGSearchMode.hybrid)
      }
      .pickerStyle(.segmented)
      .frame(width: 210)
      
      // Search button
      Button {
        Task { await runSearch() }
      } label: {
        if isSearching {
          ProgressView()
            .scaleEffect(0.8)
            .frame(width: 20, height: 20)
        } else {
          Image(systemName: "arrow.right.circle.fill")
            .font(.title2)
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(.blue)
      .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
    }
  }
  
  // MARK: - Filters Row
  
  @ViewBuilder
  private var filtersRow: some View {
    HStack(spacing: 12) {
      // Repository filter
      Picker("Repo", selection: Binding(
        get: { selectedRepoPath ?? "all" },
        set: { selectedRepoPath = $0 == "all" ? nil : $0 }
      )) {
        Text("All Repos").tag("all")
        ForEach(mcpServer.ragRepos, id: \.id) { repo in
          Text(repo.name).tag(repo.rootPath)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: 200)
      
      // Result limit
      Stepper("Results: \(limit)", value: $limit, in: 5...50, step: 5)
        .frame(width: 150)
      
      Spacer()
      
      // Results count
      if showResults && !results.isEmpty {
        Text("\(results.count) results")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .font(.caption)
    .padding(.top, 8)
  }
  
  // MARK: - Recent Queries
  
  @ViewBuilder
  private var recentQueriesView: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Recent")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
      
      FlowLayout(spacing: 6) {
        ForEach(recentQueries.prefix(8), id: \.self) { recent in
          Button {
            query = recent
            Task { await runSearch() }
          } label: {
            Text(recent)
              .font(.caption)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(.fill.tertiary, in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }
  
  // MARK: - Results View
  
  @ViewBuilder
  private var resultsView: some View {
    if results.isEmpty && !isSearching {
      VStack(spacing: 8) {
        Image(systemName: "doc.questionmark")
          .font(.title)
          .foregroundStyle(.secondary)
        
        Text("No results found")
          .font(.callout)
          .foregroundStyle(.secondary)
        
        Text("Try a different query or switch between Vector and Text modes")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 20)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(results, id: \.filePath) { result in
            globalSearchResultRow(result)
          }
        }
        .padding(.vertical, 8)
      }
      .frame(maxHeight: 400)
    }
  }
  
  @ViewBuilder
  private func globalSearchResultRow(_ result: LocalRAGSearchResult) -> some View {
    HStack(alignment: .top, spacing: 12) {
      // Score indicator
      ZStack {
        Circle()
          .fill(scoreColor(result.score).opacity(0.2))
          .frame(width: 36, height: 36)
        
        if let score = result.score {
          Text("\(Int(score * 100))")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(scoreColor(result.score))
        }
      }
      
      VStack(alignment: .leading, spacing: 4) {
        // File path
        HStack {
          Image(systemName: languageIcon(for: result.filePath))
            .font(.caption)
            .foregroundStyle(.secondary)
          
          Text(displayPath(for: result.filePath))
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
          
          Spacer()
          
          Text("L\(result.startLine)–\(result.endLine)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        // Snippet preview
        Text(result.snippet.split(separator: "\n").first ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        
        // Repo badge
        if let repoName = repoName(for: result.filePath) {
          Text(repoName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.1), in: Capsule())
            .foregroundStyle(.blue)
        }
      }
      
      // Actions
      VStack(spacing: 4) {
        Button {
          copyToPasteboard(result.filePath)
        } label: {
          Image(systemName: "doc.on.clipboard")
        }
        .buttonStyle(.borderless)
        .help("Copy path")
        
        Button {
          NSWorkspace.shared.open(URL(fileURLWithPath: result.filePath))
        } label: {
          Image(systemName: "arrow.up.forward")
        }
        .buttonStyle(.borderless)
        .help("Open file")
      }
      .font(.caption)
    }
    .padding(8)
    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
  }
  
  // MARK: - Helper Methods
  
  private func runSearch() async {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    
    errorMessage = nil
    isSearching = true
    showResults = true
    
    defer { isSearching = false }
    
    // Save to recent queries
    saveRecentQuery(trimmed)
    
    do {
      let results = try await mcpServer.searchRag(
        query: trimmed,
        mode: searchMode,
        repoPath: selectedRepoPath,
        limit: limit
      )
      self.results = results
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func loadRecentQueries() {
    recentQueries = UserDefaults.standard.stringArray(forKey: "RAG.recentQueries") ?? []
  }
  
  private func saveRecentQuery(_ query: String) {
    var queries = recentQueries
    queries.removeAll { $0 == query }
    queries.insert(query, at: 0)
    queries = Array(queries.prefix(20))
    recentQueries = queries
    UserDefaults.standard.set(queries, forKey: "RAG.recentQueries")
  }
  
  private func displayPath(for path: String) -> String {
    // Try to find the repo this belongs to
    for repo in mcpServer.ragRepos {
      if path.hasPrefix(repo.rootPath) {
        let relative = path.dropFirst(repo.rootPath.count)
        let cleaned = relative.hasPrefix("/") ? relative.dropFirst() : relative
        return String(cleaned)
      }
    }
    return URL(fileURLWithPath: path).lastPathComponent
  }
  
  private func repoName(for path: String) -> String? {
    for repo in mcpServer.ragRepos {
      if path.hasPrefix(repo.rootPath) {
        return repo.name
      }
    }
    return nil
  }
  
  private func scoreColor(_ score: Float?) -> Color {
    guard let score else { return .secondary }
    if score >= 0.8 { return .green }
    if score >= 0.6 { return .orange }
    return .secondary
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
  
  private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

// MARK: - Flow Layout for Tags

struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = arrangeSubviews(proposal: proposal, subviews: subviews)
    return result.size
  }
  
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrangeSubviews(proposal: proposal, subviews: subviews)
    
    for (index, subview) in subviews.enumerated() {
      let position = result.positions[index]
      subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
    }
  }
  
  private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
    let maxWidth = proposal.width ?? .infinity
    var positions: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      
      if x + size.width > maxWidth && x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      
      positions.append(CGPoint(x: x, y: y))
      rowHeight = max(rowHeight, size.height)
      x += size.width + spacing
      totalHeight = y + rowHeight
    }
    
    return (CGSize(width: maxWidth, height: totalHeight), positions)
  }
}

// MARK: - Preview

#Preview {
  RAGGlobalSearchView(mcpServer: MCPServerService())
    .frame(width: 600)
    .padding()
}
