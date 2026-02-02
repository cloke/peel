//
//  LocalRAGDashboardView.swift
//  KitchenSync
//
//  Redesigned repo-centric RAG dashboard.
//  Everything about a repo in one place - index, analyze, search, skills.
//

import PeelUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct LocalRAGDashboardView: View {
  @Bindable var mcpServer: MCPServerService
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \SyncedRepository.name) private var syncedRepos: [SyncedRepository]
  @Query private var localPaths: [LocalRepositoryPath]
  
  // Add repo state
  @State private var isAddRepoPresented: Bool = false
  @State private var newRepoPath: String = ""
  @State private var isIndexing: Bool = false
  @State private var errorMessage: String?
  
  // Settings state
  @State private var showSettings: Bool = false
  
  // Workspace detection state
  @State private var showWorkspaceSheet: Bool = false
  @State private var workspaceRootPath: String = ""
  @State private var workspaceRepos: [String] = []
  @State private var selectedWorkspaceRepos: Set<String> = []
  @State private var workspaceDebugInfo: WorkspaceDetectionDebug?
  
  // Card expansion state - track which repos are expanded
  @State private var expandedRepoIds: Set<String> = []
  
  // Batch operations
  @State private var selectedRepoIds: Set<String> = []
  @State private var isBatchMode: Bool = false
  
  // Keyboard focus
  @FocusState private var isSearchFocused: Bool
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // MARK: - Header with Quick Stats
        headerView
        
        // MARK: - Global Search
        RAGGlobalSearchView(mcpServer: mcpServer)
          .focused($isSearchFocused)
        
        // MARK: - Repository Cards
        if mcpServer.ragRepos.isEmpty {
          emptyStateView
        } else {
          repoCardsView
        }
        
        // MARK: - Batch Operations Bar (when in batch mode)
        if isBatchMode && !selectedRepoIds.isEmpty {
          batchOperationsBar
        }
      }
      .padding(16)
    }
    .navigationTitle("Local RAG")
    .toolbar {
      ToolbarItem(placement: .automatic) {
        HelpButton(topic: .ragSearch)
      }
      toolbarContent
    }
    .task {
      await mcpServer.refreshRagSummary()
    }
    .sheet(isPresented: $isAddRepoPresented) {
      addRepoSheet
    }
    .sheet(isPresented: $showSettings) {
      RAGSettingsView(mcpServer: mcpServer)
    }
    .sheet(isPresented: $showWorkspaceSheet) {
      workspaceSheet
    }
    .onAppear {
      // Keyboard shortcuts
      NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.modifierFlags.contains(.command) {
          if event.characters == "f" {
            isSearchFocused = true
            return nil
          }
          if event.characters == "n" {
            isAddRepoPresented = true
            return nil
          }
        }
        return event
      }
    }
  }
  
  // MARK: - Header View
  
  @ViewBuilder
  private var headerView: some View {
    HStack(alignment: .center, spacing: 16) {
      // Status summary
      if let status = mcpServer.ragStatus {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Image(systemName: "cpu")
              .foregroundStyle(.blue)
            Text(status.embeddingModelName)
              .font(.headline)
          }
          Text("\(status.embeddingDimensions) dimensions · \(status.providerName)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      
      Spacer()
      
      // Quick stats pills
      HStack(spacing: 12) {
        StatPill(value: mcpServer.ragRepos.count, label: "repos", icon: "folder.fill", color: .blue)
        
        if let stats = mcpServer.ragStats {
          StatPill(value: stats.fileCount, label: "files", icon: "doc", color: .green)
          StatPill(value: stats.chunkCount, label: "chunks", icon: "text.alignleft", color: .purple)
        }
        
        // Overall analysis progress
        if mcpServer.ragUsage.chunksAnalyzedTotal > 0 {
          StatPill(value: mcpServer.ragUsage.chunksAnalyzedTotal, label: "analyzed", icon: "checkmark.circle", color: .orange)
        }
      }
      
      // Settings button - always visible
      Button {
        showSettings = true
      } label: {
        Image(systemName: "gearshape")
          .font(.title2)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("RAG Settings")
    }
    .padding(.horizontal, 4)
  }
  
  // MARK: - Empty State
  
  @ViewBuilder
  private var emptyStateView: some View {
    VStack(spacing: 16) {
      Image(systemName: "folder.badge.plus")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      
      Text("No Repositories Indexed")
        .font(.title2.weight(.medium))
      
      Text("Add a repository to start using local RAG search and AI analysis")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      
      Button {
        isAddRepoPresented = true
      } label: {
        Label("Add Repository", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
  }
  
  // MARK: - Repository Cards
  
  @ViewBuilder
  private var repoCardsView: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header with batch mode toggle
      HStack {
        Text("Repositories")
          .font(.headline)
        
        Spacer()
        
        if mcpServer.ragRepos.count > 1 {
          Toggle("Select", isOn: $isBatchMode)
            .toggleStyle(.button)
            .controlSize(.small)
        }
        
        Button {
          // Expand/collapse all
          if expandedRepoIds.count == mcpServer.ragRepos.count {
            expandedRepoIds.removeAll()
          } else {
            expandedRepoIds = Set(mcpServer.ragRepos.map(\.id))
          }
        } label: {
          Image(systemName: expandedRepoIds.count == mcpServer.ragRepos.count ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        }
        .buttonStyle(.borderless)
        .help(expandedRepoIds.count == mcpServer.ragRepos.count ? "Collapse all" : "Expand all")
      }
      
      // Cards
      ForEach(mcpServer.ragRepos, id: \.id) { repo in
        HStack(alignment: .top, spacing: 8) {
          // Selection checkbox in batch mode
          if isBatchMode {
            Toggle("", isOn: Binding(
              get: { selectedRepoIds.contains(repo.id) },
              set: { selected in
                if selected {
                  selectedRepoIds.insert(repo.id)
                } else {
                  selectedRepoIds.remove(repo.id)
                }
              }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .padding(.top, 16)
          }
          
          RAGRepositoryCardView(
            repo: repo,
            mcpServer: mcpServer,
            isExpanded: Binding(
              get: { expandedRepoIds.contains(repo.id) },
              set: { expanded in
                if expanded {
                  expandedRepoIds.insert(repo.id)
                } else {
                  expandedRepoIds.remove(repo.id)
                }
              }
            )
          )
        }
      }
    }
  }
  
  // MARK: - Batch Operations Bar
  
  @ViewBuilder
  private var batchOperationsBar: some View {
    HStack(spacing: 12) {
      Text("\(selectedRepoIds.count) selected")
        .font(.callout.weight(.medium))
      
      Spacer()
      
      Button {
        Task { await batchReindex() }
      } label: {
        Label("Re-index All", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      
      Button {
        Task { await batchAnalyze() }
      } label: {
        Label("Analyze All", systemImage: "play.fill")
      }
      .buttonStyle(.borderedProminent)
      
      Button(role: .destructive) {
        Task { await batchDelete() }
      } label: {
        Label("Remove", systemImage: "trash")
      }
      .buttonStyle(.bordered)
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
  }
  
  // MARK: - Toolbar
  
  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button {
        isAddRepoPresented = true
      } label: {
        Label("Add Repository", systemImage: "plus")
      }
      .keyboardShortcut("n", modifiers: .command)
    }
    
    ToolbarItem(placement: .primaryAction) {
      Button {
        Task { await mcpServer.refreshRagSummary() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
    }
  }
  
  // MARK: - Add Repo Sheet
  
  @ViewBuilder
  private var addRepoSheet: some View {
    NavigationStack {
      VStack(spacing: 20) {
        // Drop zone
        ZStack {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(.secondary)
            .frame(height: 120)
          
          VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
              .font(.largeTitle)
              .foregroundStyle(.secondary)
            
            Text("Drop folder here")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
          handleDrop(providers)
          return true
        }
        
        Divider()
        
        // Manual entry
        HStack {
          TextField("Repository path", text: $newRepoPath)
            .textFieldStyle(.roundedBorder)
          
          Button("Browse...") {
            browseForFolder()
          }
          .buttonStyle(.bordered)
        }
        
        // Repos from Git view not yet indexed
        if !detectedRepos.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Repositories in App (not yet indexed)")
              .font(.caption)
              .foregroundStyle(.secondary)
            
            ScrollView {
              VStack(spacing: 4) {
                ForEach(detectedRepos, id: \.self) { path in
                  Button {
                    newRepoPath = path
                  } label: {
                    HStack {
                      Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                      Text(path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                      Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(newRepoPath == path ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                  }
                  .buttonStyle(.plain)
                }
              }
            }
            .frame(maxHeight: 150)
          }
        }
        
        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
        }
        
        // Indexing progress
        if isIndexing {
          VStack(spacing: 8) {
            if let progress = mcpServer.ragIndexProgress {
              VStack(spacing: 4) {
                ProgressView(value: progress.progress)
                Text(progress.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } else {
              ProgressView("Starting indexing...")
            }
            
            // Hint that user can close
            Label("Indexing continues in background. You can close this dialog.", systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding()
          .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        
        Spacer()
      }
      .padding()
      .navigationTitle("Add Repository")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(isIndexing ? "Close" : "Cancel") {
            isAddRepoPresented = false
            if !isIndexing {
              newRepoPath = ""
            }
          }
        }
        
        ToolbarItem(placement: .confirmationAction) {
          if isIndexing {
            // Show "Done" when indexing - lets user acknowledge and close
            Button("Done") {
              isAddRepoPresented = false
              newRepoPath = ""
            }
            .buttonStyle(.borderedProminent)
          } else {
            Button("Add & Index") {
              Task { await indexNewRepository() }
            }
            .disabled(newRepoPath.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
      }
    }
    .frame(width: 500, height: 450)
  }
  
  // MARK: - Workspace Sheet
  
  @ViewBuilder
  private var workspaceSheet: some View {
    WorkspaceIndexSheet(
      rootPath: workspaceRootPath,
      repos: workspaceRepos,
      debugInfo: workspaceDebugInfo,
      selectedRepos: $selectedWorkspaceRepos,
      onCancel: { showWorkspaceSheet = false },
      onRescan: {
        let detection = detectWorkspaceRepos(rootPath: workspaceRootPath)
        workspaceDebugInfo = detection.debug
        workspaceRepos = detection.repos
        selectedWorkspaceRepos = Set(detection.repos)
      },
      onIndexWorkspace: { excludeSubrepos in
        showWorkspaceSheet = false
        Task { await indexWorkspaceRoot(excludeSubrepos: excludeSubrepos) }
      },
      onIndexSelected: {
        showWorkspaceSheet = false
        Task { await indexWorkspaceRepos() }
      }
    )
    .frame(minWidth: 520, minHeight: 420)
  }
  
  // MARK: - Helper Properties
  
  private var detectedRepos: [String] {
    // Get repos from the app's Git view (SyncedRepository + LocalRepositoryPath)
    // Only show repos that haven't been indexed yet
    var found: [String] = []
    
    for repo in syncedRepos {
      if let localPath = localPaths.first(where: { $0.repositoryId == repo.id }) {
        let path = localPath.localPath
        // Check if already indexed in RAG
        if !mcpServer.ragRepos.contains(where: { $0.rootPath == path }) {
          // Verify the path still exists
          if FileManager.default.fileExists(atPath: path) {
            found.append(path)
          }
        }
      }
    }
    
    return found
  }
  
  // MARK: - Helper Methods
  
  private func handleDrop(_ providers: [NSItemProvider]) {
    for provider in providers {
      provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
          DispatchQueue.main.async {
            newRepoPath = url.path
          }
        }
      }
    }
  }
  
  private func browseForFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a repository folder to index"
    
    if panel.runModal() == .OK, let url = panel.url {
      newRepoPath = url.path
    }
  }
  
  private func indexNewRepository() async {
    let trimmed = newRepoPath.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    
    // Check for workspace (multiple repos)
    let detection = detectWorkspaceRepos(rootPath: trimmed)
    workspaceDebugInfo = detection.debug
    let workspaceCandidates = detection.repos
    
    if workspaceCandidates.count >= 2 {
      workspaceRootPath = trimmed
      workspaceRepos = workspaceCandidates
      selectedWorkspaceRepos = Set(workspaceCandidates)
      isAddRepoPresented = false
      showWorkspaceSheet = true
      return
    }
    
    errorMessage = nil
    isIndexing = true
    defer { isIndexing = false }
    
    do {
      try await mcpServer.indexRagRepo(path: trimmed)
      isAddRepoPresented = false
      newRepoPath = ""
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func indexWorkspaceRoot(excludeSubrepos: Bool) async {
    errorMessage = nil
    isIndexing = true
    defer { isIndexing = false }
    
    do {
      try await mcpServer.indexRagRepo(
        path: workspaceRootPath,
        allowWorkspace: true,
        excludeSubrepos: excludeSubrepos
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func indexWorkspaceRepos() async {
    let repos = workspaceRepos.filter { selectedWorkspaceRepos.contains($0) }
    guard !repos.isEmpty else { return }
    
    errorMessage = nil
    isIndexing = true
    defer { isIndexing = false }
    
    for repo in repos {
      do {
        try await mcpServer.indexRagRepo(path: repo)
      } catch {
        errorMessage = error.localizedDescription
        break
      }
    }
  }
  
  private func detectWorkspaceRepos(rootPath: String) -> WorkspaceDetectionResult {
    let rootURL = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
    let readableRoot = FileManager.default.isReadableFile(atPath: rootURL.path)
    let excluded = Set([".git", ".build", ".swiftpm", "build", "dist", "DerivedData", "node_modules", "coverage", "tmp", "Carthage", ".turbo", "__snapshots__", "vendor"])
    let maxDepth = 4
    var repos: [String] = []
    var directoriesScanned = 0
    var excludedCount = 0
    var gitMarkersFound = 0
    var maxDepthReached = 0
    var scanError: String? = nil

    var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]
    while !queue.isEmpty {
      let current = queue.removeFirst()
      if current.depth > maxDepth { continue }
      maxDepthReached = max(maxDepthReached, current.depth)
      let children: [URL]
      do {
        children = try FileManager.default.contentsOfDirectory(
          at: current.url,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      } catch {
        scanError = error.localizedDescription
        continue
      }

      for child in children {
        guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        if excluded.contains(child.lastPathComponent) {
          excludedCount += 1
          continue
        }
        directoriesScanned += 1
        let gitMarker = child.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitMarker.path) {
          repos.append(child.path)
          gitMarkersFound += 1
          continue
        }
        queue.append((child, current.depth + 1))
      }
    }

    return WorkspaceDetectionResult(
      repos: Array(Set(repos)).sorted(),
      debug: WorkspaceDetectionDebug(
        rootPath: rootPath,
        resolvedRoot: rootURL.path,
        readableRoot: readableRoot,
        scanError: scanError,
        directoriesScanned: directoriesScanned,
        excludedCount: excludedCount,
        gitMarkersFound: gitMarkersFound,
        maxDepthReached: maxDepthReached
      )
    )
  }
  
  // MARK: - Batch Operations
  
  private func batchReindex() async {
    for repoId in selectedRepoIds {
      if let repo = mcpServer.ragRepos.first(where: { $0.id == repoId }) {
        do {
          try await mcpServer.indexRagRepo(path: repo.rootPath)
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
    selectedRepoIds.removeAll()
    isBatchMode = false
  }
  
  private func batchAnalyze() async {
    // Note: This would need a queue mechanism for multiple repos
    // For now, just expand all selected cards
    for repoId in selectedRepoIds {
      expandedRepoIds.insert(repoId)
    }
    selectedRepoIds.removeAll()
    isBatchMode = false
  }
  
  private func batchDelete() async {
    for repoId in selectedRepoIds {
      do {
        _ = try await mcpServer.deleteRagRepo(repoId: repoId)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
    selectedRepoIds.removeAll()
    isBatchMode = false
  }
}

// MARK: - Stat Pill Component

private struct StatPill: View {
  let value: Int
  let label: String
  let icon: String
  var color: Color = .secondary
  
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.caption)
        .foregroundStyle(color)
      Text("\(value)")
        .font(.system(.caption, design: .rounded, weight: .medium))
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.fill.tertiary, in: Capsule())
  }
}

// MARK: - Preview

#Preview {
  LocalRAGDashboardView(mcpServer: MCPServerService())
}
