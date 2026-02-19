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
  @Query private var allSkills: [RepoGuidanceSkill]
  
  // Add repo state
  @State private var isAddRepoPresented: Bool = false
  @State private var newRepoPath: String = ""
  @State private var isIndexing: Bool = false
  @State private var errorMessage: String?
  
  // Settings state
  @State private var showSettings: Bool = false

  // Skills resolver state
  @State private var showSkillResolver: Bool = false
  @State private var ignoredSkillIdentities: Set<String> = []
  
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
    .sheet(isPresented: $showSkillResolver) {
      RAGSkillsResolverSheet(
        mcpServer: mcpServer,
        skills: unresolvedSkills,
        repoCandidates: localRepoCandidates,
        ignoredIdentityKeys: $ignoredSkillIdentities
      )
    }
    .sheet(isPresented: $showWorkspaceSheet) {
      workspaceSheet
    }
    .onAppear {
      loadIgnoredSkillIdentities()
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
    .onChange(of: ignoredSkillIdentities) { _, newValue in
      UserDefaults.standard.set(Array(newValue), forKey: "rag.skills.ignoredIdentityKeys")
    }
  }

  private var unresolvedSkills: [RepoGuidanceSkill] {
    allSkills.filter { skill in
      guard skill.isActive else { return false }
      if skill.repoPath == "*" {
        return false
      }
      let identity = skillIdentityKey(skill)
      if ignoredSkillIdentities.contains(identity) {
        return false
      }
      if skillAutoResolves(skill) {
        return false
      }
      if skill.repoPath.isEmpty {
        return true
      }
      if !FileManager.default.fileExists(atPath: skill.repoPath) {
        return true
      }
      return false
    }
  }

  private var localRepoCandidates: [LocalRepoCandidate] {
    var paths: Set<String> = []
    for repo in mcpServer.ragRepos {
      paths.insert(repo.rootPath)
    }
    for path in localPaths {
      paths.insert(path.localPath)
    }
    return paths.sorted().map { path in
      LocalRepoCandidate(path: path)
    }
  }

  private func skillIdentityKey(_ skill: RepoGuidanceSkill) -> String {
    if !skill.repoRemoteURL.isEmpty {
      return "remote:\(RepoRegistry.shared.normalizeRemoteURL(skill.repoRemoteURL))"
    }
    if !skill.repoName.isEmpty {
      return "name:\(skill.repoName)"
    }
    return "path:\(skill.repoPath)"
  }

  private func loadIgnoredSkillIdentities() {
    let stored = UserDefaults.standard.stringArray(forKey: "rag.skills.ignoredIdentityKeys") ?? []
    ignoredSkillIdentities = Set(stored)
  }

  private func skillAutoResolves(_ skill: RepoGuidanceSkill) -> Bool {
    if !skill.repoPath.isEmpty, skill.repoPath != "*" {
      return false
    }
    let skillTags = RepoTechDetector.parseTags(skill.tags)
    guard !skillTags.isEmpty else { return false }
    for candidate in localRepoCandidates {
      let repoTags = RepoTechDetector.detectTags(repoPath: candidate.path)
      if !repoTags.isEmpty, !skillTags.isDisjoint(with: repoTags) {
        return true
      }
    }
    return false
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
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Text("\(status.embeddingDimensions) dimensions · \(status.providerName)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 0, maxWidth: 220)
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
      
      if unresolvedSkills.count > 0 {
        Button {
          showSkillResolver = true
        } label: {
          Label("Resolve Skills", systemImage: "exclamationmark.triangle")
        }
        .buttonStyle(.bordered)
        .help("Resolve repo guidance skills for this machine")
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
          
          // Show All/None buttons when in batch mode
          if isBatchMode {
            Button("All") {
              selectedRepoIds = Set(mcpServer.ragRepos.map(\.id))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            
            Button("None") {
              selectedRepoIds.removeAll()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
          }
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

// MARK: - Skills Resolver

private struct LocalRepoCandidate: Identifiable, Hashable {
  let id = UUID()
  let path: String
  var name: String {
    URL(fileURLWithPath: path).lastPathComponent
  }
}

private struct RAGSkillsResolverSheet: View {
  @Bindable var mcpServer: MCPServerService
  let skills: [RepoGuidanceSkill]
  let repoCandidates: [LocalRepoCandidate]
  @Binding var ignoredIdentityKeys: Set<String>
  @Environment(\.dismiss) private var dismiss
  @State private var selectedPaths: [UUID: String] = [:]
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if skills.isEmpty {
          ContentUnavailableView(
            "All Skills Resolved",
            systemImage: "checkmark.circle.fill",
            description: Text("All repo guidance skills are mapped to local repositories on this Mac.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List {
            Section {
              HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
                  .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                  Text("These skills are scoped to repositories that Peel can't find on this Mac.")
                    .font(.subheadline)
                    .fontWeight(.medium)
                  Text("Map each skill to its local repo path, or skip it to hide this warning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .padding(.vertical, 4)
            }

            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
              Section {
                VStack(alignment: .leading, spacing: 10) {

                  // Skill identity row
                  VStack(alignment: .leading, spacing: 2) {
                    Text(skill.title.isEmpty ? "Untitled Skill" : skill.title)
                      .font(.headline)
                    if !skill.repoRemoteURL.isEmpty {
                      HStack(spacing: 4) {
                        Image(systemName: "link")
                          .foregroundStyle(.secondary)
                          .font(.caption2)
                        Text(skill.repoRemoteURL)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                          .textSelection(.enabled)
                      }
                    } else if !skill.repoName.isEmpty {
                      HStack(spacing: 4) {
                        Image(systemName: "folder")
                          .foregroundStyle(.secondary)
                          .font(.caption2)
                        Text(skill.repoName)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                    } else {
                      HStack(spacing: 4) {
                        Image(systemName: "folder")
                          .foregroundStyle(.secondary)
                          .font(.caption2)
                        Text(skill.repoPath)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                          .textSelection(.enabled)
                      }
                    }
                  }

                  // Skill body preview
                  if !skill.body.isEmpty {
                    Text(skill.body.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(3)
                      .padding(8)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                  }

                  // Repo picker — shows full path as subtitle
                  VStack(alignment: .leading, spacing: 4) {
                    Text("Map to local repo")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    Picker("", selection: binding(for: skill)) {
                      Text("Select a local repo...").tag("")
                      ForEach(repoCandidates) { candidate in
                        VStack(alignment: .leading) {
                          Text(candidate.name)
                          Text(candidate.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }.tag(candidate.path)
                      }
                    }
                    .labelsHidden()
                    if let sel = selectedPaths[skill.id], !sel.isEmpty {
                      Text(sel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                  }

                  HStack(spacing: 8) {
                    Button("Choose Folder...") {
                      chooseFolder(for: skill)
                    }
                    .buttonStyle(.bordered)
                    .help("Browse for the local folder containing this repository")

                    if !skill.repoRemoteURL.isEmpty {
                      Button("Clone...") {
                        cloneRepo(for: skill)
                      }
                      .buttonStyle(.bordered)
                      .help("Clone the repository from \(skill.repoRemoteURL) to a local folder")
                    }

                    Button("Map") {
                      applyMapping(for: skill)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((selectedPaths[skill.id] ?? "").isEmpty)
                    .help("Save the mapping from this skill to the selected local repository")

                    Spacer()

                    Button("Skip on This Mac") {
                      ignoreSkill(skill)
                    }
                    .buttonStyle(.bordered)
                    .help("Hide this skill from the Resolve Skills list on this Mac. The skill is not deleted.")
                  }
                }
                .padding(.vertical, 6)
              } header: {
                Text("Skill \(index + 1) of \(skills.count)")
              }
            }
          }
        }
      }
      .navigationTitle("Resolve Skills")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .frame(minWidth: 700, minHeight: 500)
      .overlay(alignment: .bottom) {
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .font(.caption)
            .padding(8)
        }
      }
      .onAppear {
        prefillSelections()
      }
    }
  }

  private func binding(for skill: RepoGuidanceSkill) -> Binding<String> {
    Binding(
      get: { selectedPaths[skill.id] ?? "" },
      set: { selectedPaths[skill.id] = $0 }
    )
  }

  private func prefillSelections() {
    for skill in skills {
      if selectedPaths[skill.id] != nil { continue }
      if !skill.repoName.isEmpty,
         let match = repoCandidates.first(where: { $0.name == skill.repoName }) {
        selectedPaths[skill.id] = match.path
      }
    }
  }

  private func chooseFolder(for skill: RepoGuidanceSkill) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    if panel.runModal() == .OK, let url = panel.url {
      selectedPaths[skill.id] = url.path
    }
  }

  private func cloneRepo(for skill: RepoGuidanceSkill) {
    guard !skill.repoRemoteURL.isEmpty else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Clone"
    if panel.runModal() != .OK || panel.url == nil {
      return
    }
    guard let parent = panel.url else { return }
    let repoName = skill.repoName.isEmpty
      ? URL(string: skill.repoRemoteURL)?.lastPathComponent.replacingOccurrences(of: ".git", with: "") ?? "repo"
      : skill.repoName
    let targetPath = parent.appendingPathComponent(repoName).path

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["clone", skill.repoRemoteURL, targetPath]
    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        selectedPaths[skill.id] = targetPath
        applyMapping(for: skill)
      } else {
        errorMessage = "Clone failed for \(repoName)"
      }
    } catch {
      errorMessage = "Clone failed: \(error.localizedDescription)"
    }
  }

  private func applyMapping(for skill: RepoGuidanceSkill) {
    errorMessage = nil
    guard let path = selectedPaths[skill.id], !path.isEmpty else {
      errorMessage = "Select a local repository path"
      return
    }

    Task {
      let repoRemoteURL = await RepoRegistry.shared.registerRepo(at: path)
      let repoName = URL(fileURLWithPath: path).lastPathComponent
      _ = mcpServer.updateRepoGuidanceSkill(
        id: skill.id,
        repoPath: path,
        repoRemoteURL: repoRemoteURL,
        repoName: repoName
      )
    }
  }

  private func ignoreSkill(_ skill: RepoGuidanceSkill) {
    let identity = skillIdentityKey(skill)
    ignoredIdentityKeys.insert(identity)
  }

  private func skillIdentityKey(_ skill: RepoGuidanceSkill) -> String {
    if !skill.repoRemoteURL.isEmpty {
      return "remote:\(RepoRegistry.shared.normalizeRemoteURL(skill.repoRemoteURL))"
    }
    if !skill.repoName.isEmpty {
      return "name:\(skill.repoName)"
    }
    return "path:\(skill.repoPath)"
  }
}



// MARK: - Preview

#Preview {
  LocalRAGDashboardView(mcpServer: MCPServerService())
}
