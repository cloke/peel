//
//  RAGRepositoryCardView.swift
//  Peel
//
//  Repo-centric card showing all RAG operations for a single repository.
//  Part of the RAG UX redesign - everything about a repo in one place.
//

import OSLog
import PeelUI
import SwiftData
import SwiftUI

private let repoSkillsLogger = Logger(subsystem: "com.peel.rag", category: "skills")

// MARK: - Repository Status

/// Visual status states for a repository
enum RAGRepoStatus: Equatable {
  case notIndexed
  case indexing
  case indexedOnly
  case analyzing(progress: Double)
  case partiallyAnalyzed(progress: Double)
  case fullyAnalyzed
  case stale
  
  var badge: String {
    switch self {
    case .notIndexed: return "○"
    case .indexing: return "◐"
    case .indexedOnly: return "◑"
    case .analyzing: return "◐"
    case .partiallyAnalyzed: return "◕"
    case .fullyAnalyzed: return "●"
    case .stale: return "⚠"
    }
  }
  
  var color: Color {
    switch self {
    case .notIndexed: return .gray
    case .indexing: return .blue
    case .indexedOnly: return .yellow
    case .analyzing: return .purple
    case .partiallyAnalyzed: return .orange
    case .fullyAnalyzed: return .green
    case .stale: return .orange
    }
  }
  
  var label: String {
    switch self {
    case .notIndexed: return "Not indexed"
    case .indexing: return "Indexing..."
    case .indexedOnly: return "Indexed"
    case .analyzing(let progress): return "Analyzing \(Int(progress * 100))%"
    case .partiallyAnalyzed(let progress): return "\(Int(progress * 100))% analyzed"
    case .fullyAnalyzed: return "Complete"
    case .stale: return "Stale"
    }
  }
}

// MARK: - Repository Card View

struct RAGRepositoryCardView: View {
  let repo: MCPServerService.RAGRepoInfo
  @Bindable var mcpServer: MCPServerService
  @Binding var isExpanded: Bool
  
  // Analysis state for this repo - from centralized store
  private var analysisState: MCPServerService.RAGRepoAnalysisState {
    mcpServer.analysisState(for: repo.id, repoPath: repo.rootPath)
  }
  @State private var selectedModelTier: MLXAnalyzerModelTier = .auto
  
  // Search state for this repo
  @State private var searchQuery: String = ""
  @State private var searchMode: MCPServerService.RAGSearchMode = .vector
  @State private var searchResults: [LocalRAGSearchResult] = []
  @State private var isSearching: Bool = false
  @State private var searchLimit: Int = 10
  
  // Skills for this repo
  @Query private var allSkills: [RepoGuidanceSkill]
  @State private var repoRemoteURL: String?
  @State private var repoTechTags: Set<String> = []
  private var repoSkills: [RepoGuidanceSkill] {
    allSkills.filter { skill in
      skill.isActive && repoSkillMatches(skill)
    }
  }
  
  // Lessons for this repo
  @State private var repoLessons: [LocalRAGLesson] = []
  @State private var showLessonsSheet: Bool = false
  
  // UI state
  @State private var isHovering: Bool = false
  @State private var showSkillsSheet: Bool = false
  @State private var errorMessage: String?
  @State private var showForceReindexConfirm: Bool = false
  @State private var showForceReanalyzeConfirm: Bool = false
  @State private var showDeleteConfirm: Bool = false
  @State private var isDeleting: Bool = false
  @State private var isSyncing: Bool = false
  @State private var syncDirection: RAGArtifactSyncDirection?
  @State private var activeTransferId: UUID?
  @State private var syncResultMessage: String?
  
  /// Adaptive batch size based on available RAM.
  /// Smaller batches = more frequent UI progress updates (important on laptops).
  private var adaptiveBatchSize: Int {
    let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    if memGB >= 48 {
      return 50   // Mac Studio / Mac Pro
    } else if memGB >= 32 {
      return 25   // MacBook Pro 32GB
    } else {
      return 10   // Laptops (8-18GB) — fast feedback
    }
  }

  // Computed status
  private var status: RAGRepoStatus {
    if mcpServer.ragIndexingPath == repo.rootPath {
      return .indexing
    }
    if analysisState.isAnalyzing {
      return .analyzing(progress: analysisState.progress)
    }
    if analysisState.totalChunks == 0 {
      return .indexedOnly
    }
    if analysisState.isComplete {
      return .fullyAnalyzed
    }
    return .partiallyAnalyzed(progress: analysisState.progress)
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // MARK: - Card Header (Always Visible)
      cardHeader
      
      // MARK: - Expanded Content
      if isExpanded {
        Divider()
          .padding(.horizontal, 12)
        
        expandedContent
          .padding(12)
      }
    }
    .background(cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(isHovering ? 0.15 : 0.08), radius: isHovering ? 8 : 4, y: 2)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
    .task {
      await refreshAnalysisStatus()
      await loadLessons()
      repoRemoteURL = await RepoRegistry.shared.registerRepo(at: repo.rootPath)
        ?? RepoRegistry.shared.getCachedRemoteURL(for: repo.rootPath)
      repoTechTags = RepoTechDetector.detectTags(repoPath: repo.rootPath)
      // Auto-resume analysis that was interrupted by an app quit
      if mcpServer.interruptedAnalysisPaths.contains(repo.rootPath),
         !analysisState.isAnalyzing,
         analysisState.unanalyzedCount > 0 {
        print("[RAG Resume] Auto-resuming analysis for \(repo.rootPath)")
        startAnalyzeAll()
      }
    }
    .sheet(isPresented: $showSkillsSheet) {
      RAGRepoSkillsSheet(repo: repo, mcpServer: mcpServer)
    }
    .sheet(isPresented: $showLessonsSheet) {
      RAGLessonsView(repo: repo, mcpServer: mcpServer)
    }
  }
  
  // MARK: - Card Header
  
  @ViewBuilder
  private var cardHeader: some View {
    HStack(alignment: .center, spacing: 12) {
      // Status badge
      statusBadge
      
      // Repo info
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(repo.name)
            .font(.headline)
            .lineLimit(1)
          
          Spacer()
          
          // Last indexed time
          if let lastIndexed = repo.lastIndexedAt {
            RelativeTimeText(lastIndexed)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        
        // Quick stats row
        HStack(spacing: 12) {
          Label("\(repo.fileCount)", systemImage: "doc")
          Label("\(repo.chunkCount)", systemImage: "text.alignleft")
          
          if analysisState.totalChunks > 0 {
            let pct = Int(analysisState.progress * 100)
            Label("\(pct)%", systemImage: "cpu")
              .foregroundStyle(status.color)
          }
          
          if !repoSkills.isEmpty {
            Label("\(repoSkills.count)", systemImage: "lightbulb")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      
      // Expand/collapse chevron
      Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
        isExpanded.toggle()
      }
    }
  }
  
  // MARK: - Status Badge
  
  @ViewBuilder
  private var statusBadge: some View {
    ZStack {
      Circle()
        .fill(status.color.opacity(0.2))
        .frame(width: 40, height: 40)
      
      if case .indexing = status {
        ProgressView()
          .scaleEffect(0.6)
      } else if case .analyzing = status {
        ProgressView()
          .scaleEffect(0.6)
          .tint(.purple)
      } else {
        Image(systemName: statusIcon)
          .font(.system(size: 18))
          .foregroundStyle(status.color)
      }
    }
  }
  
  private var statusIcon: String {
    switch status {
    case .notIndexed: return "folder.badge.questionmark"
    case .indexing: return "arrow.clockwise"
    case .indexedOnly: return "folder"
    case .analyzing: return "cpu"
    case .partiallyAnalyzed: return "chart.pie"
    case .fullyAnalyzed: return "checkmark.circle.fill"
    case .stale: return "exclamationmark.triangle"
    }
  }
  
  // MARK: - Expanded Content
  
  @ViewBuilder
  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Path display
      Text(repo.rootPath)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      
      // MARK: Index Section
      indexSection
      
      // MARK: Analysis Section
      analysisSection
      
      // MARK: Search Section
      searchSection
      
      // MARK: Skills Section
      skillsSection
      
      // MARK: Lessons Section
      lessonsSection
      
      // MARK: Actions Footer
      actionsFooter
    }
  }
  
  // MARK: - Index Section
  
  @ViewBuilder
  private var indexSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Index", systemImage: "folder.fill")
          .font(.subheadline.weight(.semibold))
        
        Spacer()
        
        if mcpServer.ragIndexingPath == repo.rootPath {
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
          Text("\(repo.fileCount)")
            .font(.title3.weight(.medium))
          Text("files")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        
        VStack(alignment: .leading, spacing: 2) {
          Text("\(repo.chunkCount)")
            .font(.title3.weight(.medium))
          Text("chunks")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        
        Spacer()
        
        Button {
          Task { await reindexRepository(force: false) }
        } label: {
          Label("Re-index", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(mcpServer.ragIndexingPath != nil)
        .help("Re-index changed files")
        
        Button {
          showForceReindexConfirm = true
        } label: {
          Label("Force Re-index", systemImage: "arrow.clockwise.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(mcpServer.ragIndexingPath != nil)
        .help("Force full re-index of all files")
        .confirmationDialog(
          "Force Full Reindex?",
          isPresented: $showForceReindexConfirm,
          titleVisibility: .visible
        ) {
          Button("Reindex + Clear Analysis") {
            Task {
              await reindexRepository(force: true)
              try? await mcpServer.clearRagAnalysis(repoPath: repo.rootPath)
              await refreshAnalysisStatus()
            }
          }
          Button("Reindex Only") {
            Task { await reindexRepository(force: true) }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("This will re-index all \(repo.fileCount) files. Choose whether to also clear AI analysis.")
        }
      }
      
      // Index progress
      if let progress = mcpServer.ragIndexProgress, 
         mcpServer.ragIndexingPath == repo.rootPath,
         !progress.isComplete {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.progress)
              .progressViewStyle(.linear)
            Text(progress.description)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          
          Button {
            mcpServer.cancelRagIndexing()
          } label: {
            Image(systemName: "stop.fill")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.red)
          .help("Cancel indexing")
        }
      }
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
  
  // MARK: - Analysis Section
  
  @ViewBuilder
  private var analysisSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("AI Analysis", systemImage: "cpu")
          .font(.subheadline.weight(.semibold))
        
        Spacer()
        
        if analysisState.isComplete {
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
        } else if analysisState.totalChunks > 0 {
          Text("\(Int(analysisState.progress * 100))%")
            .font(.caption.weight(.medium))
            .foregroundStyle(status.color)
        }
      }
      
      // Progress bar
      if analysisState.totalChunks > 0 {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: analysisState.progress)
            .tint(analysisState.isComplete ? .green : .purple)
          
          HStack {
            Text("\(analysisState.analyzedCount) / \(analysisState.totalChunks) chunks")
              .font(.caption2)
              .foregroundStyle(.secondary)
            
            if analysisState.isAnalyzing, let batch = analysisState.batchProgress {
              Text("(\(batch.current)/\(batch.total))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
            
            Spacer()
            
            if analysisState.isAnalyzing, analysisState.chunksPerSecond > 0 {
              Text("\(String(format: "%.1f", analysisState.chunksPerSecond)) chunks/sec")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      
      // Model picker and actions
      HStack(spacing: 8) {
        Picker("", selection: $selectedModelTier) {
          Text("Auto").tag(MLXAnalyzerModelTier.auto)
          ForEach(MLXAnalyzerModelConfig.availableModels, id: \.name) { model in
            Text(model.name).tag(model.tier)
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 180)
        .controlSize(.small)
        
        Spacer()
        
        if analysisState.isAnalyzing {
          Button {
            analysisState.isPaused = true
          } label: {
            Label("Pause", systemImage: "pause.fill")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.orange)
        } else if analysisState.isPaused {
          Button {
            analysisState.isPaused = false
            analysisState.analyzeTask = Task { await continueAnalyzeAll() }
          } label: {
            Label("Resume", systemImage: "play.fill")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          
          Button {
            stopAnalysis()
          } label: {
            Image(systemName: "stop.fill")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.red)
        } else {
          Button {
            Task { await analyzeQuickSample() }
          } label: {
            Label("Quick 50", systemImage: "hare")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(analysisState.unanalyzedCount == 0)
          
          Button {
            startAnalyzeAll()
          } label: {
            Label("Analyze All", systemImage: "play.fill")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(analysisState.unanalyzedCount == 0)
        }
      }
      
      // Time estimate
      if analysisState.isAnalyzing || analysisState.isPaused {
        if let startTime = analysisState.analysisStartTime {
          HStack(spacing: 12) {
            Text("Started: \(startTime, format: .dateTime.hour().minute())")
            
            if analysisState.chunksPerSecond > 0 && analysisState.unanalyzedCount > 0 {
              let remaining = Double(analysisState.unanalyzedCount) / analysisState.chunksPerSecond
              Text("Est: \(formatDuration(remaining)) remaining")
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }
      
      // Error display
      if let error = analysisState.analyzeError {
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
        Task { await forceReanalyze() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will clear all \(analysisState.analyzedCount) AI summaries and re-analyze with the \(selectedModelTier == .auto ? "auto-selected" : "\(selectedModelTier)") model. Enriched embeddings will also be regenerated.")
    }
  }
  
  // MARK: - Search Section
  
  @ViewBuilder
  private var searchSection: some View {
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
          Text("Vector").tag(MCPServerService.RAGSearchMode.vector)
          Text("Text").tag(MCPServerService.RAGSearchMode.text)
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
      
      // Search results
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
  private func searchResultRow(_ result: LocalRAGSearchResult) -> some View {
    HStack(spacing: 8) {
      Image(systemName: languageIcon(for: result.filePath))
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
  
  // MARK: - Skills Section
  
  @ViewBuilder
  private var skillsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Guidance Skills", systemImage: "lightbulb")
          .font(.subheadline.weight(.semibold))
        
        Spacer()
        
        Button {
          showSkillsSheet = true
        } label: {
          Label("Manage", systemImage: "gear")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      
      if repoSkills.isEmpty {
        Text("No skills configured for this repository")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(repoSkills.prefix(3)) { skill in
            HStack(spacing: 6) {
              Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
              
              Text(skill.title.isEmpty ? "Untitled" : skill.title)
                .font(.caption)
                .lineLimit(1)
              
              Spacer()
              
              Text("Priority \(skill.priority)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          
          if repoSkills.count > 3 {
            Text("+ \(repoSkills.count - 3) more")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
  
  // MARK: - Lessons Section
  
  @ViewBuilder
  private var lessonsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Learned Lessons", systemImage: "brain")
          .font(.subheadline.weight(.semibold))
        
        Spacer()
        
        Button {
          showLessonsSheet = true
        } label: {
          Label("Manage", systemImage: "gear")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      
      if repoLessons.isEmpty {
        Text("No lessons learned yet")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(repoLessons.prefix(3)) { lesson in
            HStack(spacing: 6) {
              // Confidence indicator
              Circle()
                .fill(lesson.confidence >= 0.7 ? .green : lesson.confidence >= 0.4 ? .orange : .red)
                .frame(width: 6, height: 6)
              
              Text(lesson.fixDescription)
                .font(.caption)
                .lineLimit(1)
              
              Spacer()
              
              Text("\(Int(lesson.confidence * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          
          if repoLessons.count > 3 {
            Text("+ \(repoLessons.count - 3) more")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
  
  // MARK: - Load Lessons
  
  private func loadLessons() async {
    do {
      repoLessons = try await mcpServer.listLessons(
        repoPath: repo.rootPath,
        includeInactive: false,
        limit: nil
      )
    } catch {
      // Silently fail - lessons are optional
    }
  }
  
  // MARK: - Actions Footer
  
  @ViewBuilder
  private var actionsFooter: some View {
    HStack {
      Button(role: .destructive) {
        showDeleteConfirm = true
      } label: {
        if isDeleting {
          ProgressView()
            .scaleEffect(0.6)
        } else {
          Label("Remove from Index", systemImage: "trash")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(isDeleting)
      .confirmationDialog(
        "Remove \"\(repo.name)\" from Index?",
        isPresented: $showDeleteConfirm,
        titleVisibility: .visible
      ) {
        Button("Remove", role: .destructive) {
          Task {
            isDeleting = true
            defer { isDeleting = false }
            do {
              print("[RAG-UI] Delete button tapped for repo: \(repo.name) id=\(repo.id)")
              let deleted = try await mcpServer.deleteRagRepo(repoId: repo.id)
              print("[RAG-UI] Delete completed: \(deleted) files removed")
            } catch {
              print("[RAG-UI] Delete failed: \(error)")
              errorMessage = error.localizedDescription
            }
          }
        }
      } message: {
        Text("This will remove \(repo.fileCount) files and \(repo.chunkCount) chunks from the index. You can re-index later.")
      }

      // Per-repo sync buttons (requires repoIdentifier and active swarm)
      if let repoIdentifier = repo.repoIdentifier,
         SwarmCoordinator.shared.isActive,
         !SwarmCoordinator.shared.connectedWorkers.isEmpty {
        Button {
          Task { await syncRepoWithPeers(repoIdentifier: repoIdentifier, direction: .push) }
        } label: {
          if isSyncing && syncDirection == .push {
            HStack(spacing: 4) {
              ProgressView()
                .scaleEffect(0.5)
              Text("Pushing…")
            }
          } else {
            Label("Push", systemImage: "arrow.up.circle")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isSyncing)
        .help("Push this repo's embeddings to connected swarm peers")

        Button {
          Task { await syncRepoWithPeers(repoIdentifier: repoIdentifier, direction: .pull) }
        } label: {
          if isSyncing && syncDirection == .pull {
            HStack(spacing: 4) {
              ProgressView()
                .scaleEffect(0.5)
              Text("Pulling…")
            }
          } else {
            Label("Pull", systemImage: "arrow.down.circle")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isSyncing)
        .help("Pull this repo's embeddings from connected swarm peers")
      }

      Spacer()

      // Transfer progress indicator
      if let transferId = activeTransferId,
         let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) {
        syncTransferStatus(transfer)
      } else if let syncResultMessage {
        Text(syncResultMessage)
          .font(.caption)
          .foregroundStyle(.green)
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  /// Sync per-repo artifacts with connected swarm peers
  private func syncRepoWithPeers(repoIdentifier: String, direction: RAGArtifactSyncDirection) async {
    isSyncing = true
    syncDirection = direction
    syncResultMessage = nil
    activeTransferId = nil
    errorMessage = nil

    do {
      let transferId = try await SwarmCoordinator.shared.requestRagArtifactSync(
        direction: direction,
        repoIdentifier: repoIdentifier
      )
      activeTransferId = transferId

      // Poll transfer status until it completes
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(0.5))
        if let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) {
          switch transfer.status {
          case .complete:
            syncResultMessage = direction == .push ? "Pushed to \(transfer.peerName)" : "Pulled from \(transfer.peerName)"
            activeTransferId = nil
            isSyncing = false
            syncDirection = nil
            if direction == .pull {
              await mcpServer.refreshRagSummary()
            }
            // Auto-dismiss success message
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(4))
              if syncResultMessage != nil { syncResultMessage = nil }
            }
            return
          case .failed:
            errorMessage = transfer.errorMessage ?? "Transfer failed"
            activeTransferId = nil
            isSyncing = false
            syncDirection = nil
            return
          default:
            continue
          }
        }
      }
    } catch {
      errorMessage = "Sync failed: \(error.localizedDescription)"
    }
    isSyncing = false
    syncDirection = nil
  }

  /// Transfer progress display
  @ViewBuilder
  private func syncTransferStatus(_ transfer: RAGArtifactTransferState) -> some View {
    HStack(spacing: 6) {
      ProgressView()
        .scaleEffect(0.5)

      VStack(alignment: .leading, spacing: 1) {
        Text(transferStatusLabel(transfer))
          .font(.caption2)
          .foregroundStyle(.secondary)

        if transfer.totalBytes > 0 {
          ProgressView(value: transfer.progress)
            .frame(width: 80)
        }
      }
    }
  }

  private func transferStatusLabel(_ transfer: RAGArtifactTransferState) -> String {
    let dir = transfer.direction == .push ? "Pushing" : "Pulling"
    switch transfer.status {
    case .queued: return "\(dir): queued…"
    case .preparing: return "\(dir): preparing…"
    case .transferring:
      if transfer.totalBytes > 0 {
        let pct = Int(transfer.progress * 100)
        return "\(dir): \(pct)%"
      }
      return "\(dir)…"
    case .applying: return "Applying…"
    case .complete: return "Done"
    case .failed: return "Failed"
    }
  }
  
  // MARK: - Card Background
  
  @ViewBuilder
  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 12)
      .fill(.background)
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(status.color.opacity(isExpanded ? 0.3 : 0.15), lineWidth: isExpanded ? 2 : 1)
      )
  }
  
  // MARK: - Helper Methods
  
  private func refreshAnalysisStatus() async {
    do {
      let unanalyzed = try await mcpServer.getUnanalyzedChunkCount(repoPath: repo.rootPath)
      let analyzed = try await mcpServer.getAnalyzedChunkCount(repoPath: repo.rootPath)
      await MainActor.run {
        analysisState.unanalyzedCount = unanalyzed
        analysisState.analyzedCount = analyzed
      }
    } catch {
      await MainActor.run {
        analysisState.analyzeError = error.localizedDescription
      }
    }
  }
  
  private func reindexRepository(force: Bool) async {
    errorMessage = nil
    do {
      try await mcpServer.indexRagRepo(path: repo.rootPath, forceReindex: force)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func analyzeQuickSample() async {
    analysisState.isAnalyzing = true
    analysisState.analyzeError = nil
    analysisState.analysisStartTime = Date()
    
    defer {
      Task { @MainActor in
        analysisState.isAnalyzing = false
        analysisState.batchProgress = nil
      }
    }
    
    do {
      let count = try await mcpServer.analyzeRagChunks(
        repoPath: repo.rootPath,
        limit: adaptiveBatchSize,
        modelTier: selectedModelTier
      ) { current, total in
        Task { @MainActor in
          analysisState.batchProgress = (current, total)
        }
      }
      
      await MainActor.run {
        analysisState.analyzedCount += count
        analysisState.unanalyzedCount = max(0, analysisState.unanalyzedCount - count)
      }
    } catch {
      await MainActor.run {
        analysisState.analyzeError = error.localizedDescription
      }
    }
  }
  
  private func startAnalyzeAll() {
    // Guard: AI Analysis must be enabled in Settings before chunks can be analyzed.
    // makeDefaultRAGStore checks this same key — if false, chunkAnalyzer is nil and
    // RAGCore silently returns 0 for every batch, causing an infinite stall loop.
    guard UserDefaults.standard.ragAnalyzerEnabled else {
      analysisState.analyzeError = "AI Analysis is disabled. Enable it in Settings → AI Analysis to get started."
      return
    }
    // Cancel any existing task before starting a new one to prevent double-running
    analysisState.analyzeTask?.cancel()
    analysisState.analyzeTask = nil
    mcpServer.markAnalysisStarted(repoPath: repo.rootPath)
    analysisState.isAnalyzing = true
    analysisState.isPaused = false
    analysisState.analyzeError = nil
    analysisState.analysisStartTime = Date()
    analysisState.chunksPerSecond = 0
    analysisState.sessionChunksAnalyzed = 0
    analysisState.analyzeTask = Task { await runAnalyzeAllLoop() }
  }
  
  private func continueAnalyzeAll() async {
    await MainActor.run {
      analysisState.isAnalyzing = true
    }
    await runAnalyzeAllLoop()
  }
  
  private func stopAnalysis() {
    analysisState.analyzeTask?.cancel()
    analysisState.analyzeTask = nil
    mcpServer.markAnalysisStopped(repoPath: repo.rootPath)
    
    if let startTime = analysisState.analysisStartTime, analysisState.sessionChunksAnalyzed > 0 {
      let duration = Date().timeIntervalSince(startTime)
      mcpServer.recordAnalysisSession(chunksAnalyzed: analysisState.sessionChunksAnalyzed, durationSeconds: duration)
    }
    
    analysisState.isAnalyzing = false
    analysisState.isPaused = false
    analysisState.batchProgress = nil
    analysisState.sessionChunksAnalyzed = 0
    analysisState.analysisStartTime = nil
  }
  
  private func runAnalyzeAllLoop() async {
    let batchSize = adaptiveBatchSize
    
    while !Task.isCancelled {
      if await MainActor.run(body: { analysisState.isPaused }) {
        await MainActor.run { analysisState.isAnalyzing = false }
        return
      }
      
      let remaining = await MainActor.run { analysisState.unanalyzedCount }
      if remaining == 0 {
        // Clear analyzing state FIRST so UI shows "Complete" without
        // simultaneously showing the running state (Pause button, chunks/sec, etc.)
        await MainActor.run {
          if let startTime = analysisState.analysisStartTime, analysisState.sessionChunksAnalyzed > 0 {
            let duration = Date().timeIntervalSince(startTime)
            mcpServer.recordAnalysisSession(chunksAnalyzed: analysisState.sessionChunksAnalyzed, durationSeconds: duration)
          }
          analysisState.isAnalyzing = false
          analysisState.isPaused = false
          analysisState.batchProgress = nil
          analysisState.sessionChunksAnalyzed = 0
          analysisState.analysisStartTime = nil
          mcpServer.markAnalysisStopped(repoPath: repo.rootPath)
        }
        
        // Auto-enrich embeddings with AI summaries (runs after UI is updated)
        await enrichAfterAnalysis()
        return
      }
      
      let thisBatch = min(batchSize, remaining)
      let batchStart = Date()
      
      do {
        let count = try await mcpServer.analyzeRagChunks(
          repoPath: repo.rootPath,
          limit: thisBatch,
          modelTier: selectedModelTier
        ) { current, total in
          Task { @MainActor in
            analysisState.batchProgress = (current, total)
          }
        }
        
        await MainActor.run {
          analysisState.analyzedCount += count
          analysisState.unanalyzedCount = max(0, analysisState.unanalyzedCount - count)
          analysisState.sessionChunksAnalyzed += count
          
          let elapsed = Date().timeIntervalSince(batchStart)
          if elapsed > 0 && count > 0 {
            let batchRate = Double(count) / elapsed
            if analysisState.chunksPerSecond == 0 {
              analysisState.chunksPerSecond = batchRate
            } else {
              analysisState.chunksPerSecond = analysisState.chunksPerSecond * 0.7 + batchRate * 0.3
            }
          }
        }

        // If the batch returned 0, the chunk analyzer is silently failing for every
        // chunk in the batch (RAGCore catches individual errors without re-throwing).
        // Re-query the DB to distinguish "actually done" from "stalled analyzer".
        if count == 0 {
          let dbRemaining = (try? await mcpServer.getUnanalyzedChunkCount(repoPath: repo.rootPath)) ?? 0
          if dbRemaining == 0 {
            // All chunks were actually already analyzed — let the next loop check see 0 and finish cleanly
            await MainActor.run { analysisState.unanalyzedCount = 0 }
          } else {
            // Analyzer is consistently failing — stop with a message rather than spinning
            await MainActor.run {
              if let startTime = analysisState.analysisStartTime, analysisState.sessionChunksAnalyzed > 0 {
                let duration = Date().timeIntervalSince(startTime)
                mcpServer.recordAnalysisSession(chunksAnalyzed: analysisState.sessionChunksAnalyzed, durationSeconds: duration)
              }
              let analyzerEnabled = UserDefaults.standard.ragAnalyzerEnabled
              if analyzerEnabled {
                analysisState.analyzeError = "Analysis stalled: \(dbRemaining) chunks could not be processed. The MLX model may have failed — try Force Re-analyze or check Console logs."
              } else {
                analysisState.analyzeError = "AI Analysis is disabled. Enable it in Settings → AI Analysis to analyze chunks."
              }
              analysisState.isAnalyzing = false
              analysisState.isPaused = false
              analysisState.sessionChunksAnalyzed = 0
              analysisState.analysisStartTime = nil
              mcpServer.markAnalysisStopped(repoPath: repo.rootPath)
            }
            return
          }
        }
      } catch {
        await MainActor.run {
          if let startTime = analysisState.analysisStartTime, analysisState.sessionChunksAnalyzed > 0 {
            let duration = Date().timeIntervalSince(startTime)
            mcpServer.recordAnalysisSession(chunksAnalyzed: analysisState.sessionChunksAnalyzed, durationSeconds: duration)
          }
          analysisState.analyzeError = error.localizedDescription
          analysisState.isAnalyzing = false
          analysisState.isPaused = false
          analysisState.sessionChunksAnalyzed = 0
          analysisState.analysisStartTime = nil
          mcpServer.markAnalysisStopped(repoPath: repo.rootPath)
        }
        return
      }
    }
    
    await MainActor.run {
      analysisState.isAnalyzing = false
      analysisState.isPaused = false
    }
  }
  
  /// Clear existing analysis and restart with the currently selected model tier.
  private func forceReanalyze() async {
    do {
      // Clear existing analysis (summaries, tags, enriched_at)
      try await mcpServer.clearRagAnalysis(repoPath: repo.rootPath)
      
      // Refresh counts so UI shows 0 analyzed / N unanalyzed
      await refreshAnalysisStatus()
      
      // Start the full analysis loop (which auto-enriches on completion)
      startAnalyzeAll()
    } catch {
      analysisState.analyzeError = error.localizedDescription
    }
  }
  
  /// After analysis completes, re-embed chunks with enriched text (code + AI summary)
  /// so vector search captures semantic meaning from the analysis.
  private func enrichAfterAnalysis() async {
    do {
      let enriched = try await mcpServer.enrichRagEmbeddings(
        repoPath: repo.rootPath,
        limit: 5000,
        progress: nil
      )
      if enriched > 0 {
        print("[RAG] Auto-enriched \(enriched) embeddings after analysis")
      }
    } catch {
      // Non-fatal — analysis results are still useful for text search
      print("[RAG] Auto-enrich failed (non-fatal): \(error.localizedDescription)")
    }
  }
  
  private func runSearch() async {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    
    isSearching = true
    defer { isSearching = false }
    
    do {
      let results = try await mcpServer.searchRag(
        query: trimmed,
        mode: searchMode,
        repoPath: repo.rootPath,
        limit: searchLimit
      )
      self.searchResults = results
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
}

private extension RAGRepositoryCardView {
  func repoSkillMatches(_ skill: RepoGuidanceSkill) -> Bool {
    if skill.repoPath == "*" {
      let skillTags = RepoTechDetector.parseTags(skill.tags)
      if !repoTechTags.isEmpty {
        if !skillTags.isEmpty,
           !skillTags.isDisjoint(with: repoTechTags) {
          repoSkillsLogger.notice("Skill matched by wildcard tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
          return true
        }
        repoSkillsLogger.notice("Skill rejected by wildcard tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
        return false
      }
      repoSkillsLogger.notice("Skill matched by wildcard path. skill=\(skill.title, privacy: .public)")
      return true
    }
    if skill.repoPath == repo.rootPath {
      repoSkillsLogger.notice("Skill matched by repo path. skill=\(skill.title, privacy: .public) repo=\(repo.rootPath, privacy: .public)")
      return true
    }
    if let repoRemoteURL,
       !repoRemoteURL.isEmpty,
       !skill.repoRemoteURL.isEmpty,
       RepoRegistry.shared.normalizeRemoteURL(skill.repoRemoteURL) == RepoRegistry.shared.normalizeRemoteURL(repoRemoteURL) {
      repoSkillsLogger.notice("Skill matched by repo remote. skill=\(skill.title, privacy: .public)")
      return true
    }
    if !skill.repoName.isEmpty {
      let repoName = URL(fileURLWithPath: repo.rootPath).lastPathComponent
      if repoName == skill.repoName {
        repoSkillsLogger.notice("Skill matched by repo name. skill=\(skill.title, privacy: .public) repoName=\(repoName, privacy: .public)")
        return true
      }
    }

    let skillTags = RepoTechDetector.parseTags(skill.tags)
    if skill.repoPath.isEmpty || skill.repoPath == "*" {
      if !repoTechTags.isEmpty {
        if !skillTags.isEmpty,
           !skillTags.isDisjoint(with: repoTechTags) {
          repoSkillsLogger.notice("Skill matched by tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
          return true
        }
        repoSkillsLogger.notice("Skill rejected by tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
        return false
      }
      if !skillTags.isEmpty,
         !skillTags.isDisjoint(with: repoTechTags) {
        repoSkillsLogger.notice("Skill matched by tags (no repo tags). skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public)")
        return true
      }
    }
    return false
  }
}

// MARK: - Skills Sheet

struct RAGRepoSkillsSheet: View {
  let repo: MCPServerService.RAGRepoInfo
  @Bindable var mcpServer: MCPServerService
  @Environment(\.dismiss) private var dismiss
  
  @Query private var allSkills: [RepoGuidanceSkill]
  @State private var repoRemoteURL: String?
  @State private var repoTechTags: Set<String> = []
  private var repoSkills: [RepoGuidanceSkill] {
    allSkills.filter { repoSkillMatches($0) }
  }
  
  @State private var selectedSkillId: UUID?
  @State private var skillTitle: String = ""
  @State private var skillBody: String = ""
  @State private var skillTags: String = ""
  @State private var skillPriority: Int = 0
  @State private var skillActive: Bool = true
  @State private var skillSource: String = "manual"
  @State private var errorMessage: String?

  private func repoSkillMatches(_ skill: RepoGuidanceSkill) -> Bool {
    if skill.repoPath == "*" {
      let skillTags = RepoTechDetector.parseTags(skill.tags)
      if !repoTechTags.isEmpty {
        if !skillTags.isEmpty,
           !skillTags.isDisjoint(with: repoTechTags) {
          repoSkillsLogger.notice("Sheet skill matched by wildcard tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
          return true
        }
        repoSkillsLogger.notice("Sheet skill rejected by wildcard tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
        return false
      }
      repoSkillsLogger.notice("Sheet skill matched by wildcard path. skill=\(skill.title, privacy: .public)")
      return true
    }
    if skill.repoPath == repo.rootPath {
      repoSkillsLogger.notice("Sheet skill matched by repo path. skill=\(skill.title, privacy: .public) repo=\(repo.rootPath, privacy: .public)")
      return true
    }
    if let repoRemoteURL,
       !repoRemoteURL.isEmpty,
       !skill.repoRemoteURL.isEmpty,
       RepoRegistry.shared.normalizeRemoteURL(skill.repoRemoteURL) == RepoRegistry.shared.normalizeRemoteURL(repoRemoteURL) {
      repoSkillsLogger.notice("Sheet skill matched by repo remote. skill=\(skill.title, privacy: .public)")
      return true
    }
    if !skill.repoName.isEmpty {
      let repoName = URL(fileURLWithPath: repo.rootPath).lastPathComponent
      if repoName == skill.repoName {
        repoSkillsLogger.notice("Sheet skill matched by repo name. skill=\(skill.title, privacy: .public) repoName=\(repoName, privacy: .public)")
        return true
      }
    }
    let skillTags = RepoTechDetector.parseTags(skill.tags)
    if skill.repoPath.isEmpty || skill.repoPath == "*" {
      if !repoTechTags.isEmpty {
        if !skillTags.isEmpty,
           !skillTags.isDisjoint(with: repoTechTags) {
          repoSkillsLogger.notice("Sheet skill matched by tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
          return true
        }
        repoSkillsLogger.notice("Sheet skill rejected by tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
        return false
      }
      if !skillTags.isEmpty,
         !skillTags.isDisjoint(with: repoTechTags) {
        repoSkillsLogger.notice("Sheet skill matched by tags (no repo tags). skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public)")
        return true
      }
    }
    return false
  }
  
  var body: some View {
    NavigationStack {
      HSplitView {
        // Skill list
        VStack(alignment: .leading) {
          List(selection: $selectedSkillId) {
            ForEach(repoSkills) { skill in
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(skill.title.isEmpty ? "Untitled" : skill.title)
                    .font(.callout)
                  
                  Spacer()
                  
                  if !skill.isActive {
                    Text("Inactive")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
                
                Text("Priority \(skill.priority) · Used \(skill.appliedCount)×")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .tag(skill.id)
            }
          }
          .listStyle(.sidebar)
          
          HStack {
            Button {
              createNewSkill()
            } label: {
              Label("New Skill", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            
            Spacer()
          }
          .padding(8)
        }
        .frame(minWidth: 200, maxWidth: 300)
        
        // Editor
        VStack(alignment: .leading, spacing: 12) {
          TextField("Title", text: $skillTitle)
            .textFieldStyle(.roundedBorder)
          
          HStack {
            TextField("Tags (comma-separated)", text: $skillTags)
              .textFieldStyle(.roundedBorder)
            
            Stepper("Priority: \(skillPriority)", value: $skillPriority, in: -5...10)
              .frame(width: 150)
          }
          
          Toggle("Active", isOn: $skillActive)
          
          Text("Guidance Content")
            .font(.caption)
            .foregroundStyle(.secondary)
          
          TextEditor(text: $skillBody)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 200)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3))
            )
          
          if let errorMessage {
            Text(errorMessage)
              .font(.caption)
              .foregroundStyle(.red)
          }
          
          HStack {
            if selectedSkillId != nil {
              Button(role: .destructive) {
                deleteSkill()
              } label: {
                Label("Delete", systemImage: "trash")
              }
              .buttonStyle(.bordered)
            }
            
            Spacer()
            
            Button("Save") {
              saveSkill()
            }
            .buttonStyle(.borderedProminent)
            .disabled(skillBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .padding()
        .frame(minWidth: 400)
      }
      .navigationTitle("Skills for \(repo.name)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .frame(minWidth: 700, minHeight: 500)
    .onChange(of: selectedSkillId) { _, newId in
      if let newId, let skill = repoSkills.first(where: { $0.id == newId }) {
        loadSkill(skill)
      }
    }
    .task {
      repoRemoteURL = await RepoRegistry.shared.registerRepo(at: repo.rootPath)
        ?? RepoRegistry.shared.getCachedRemoteURL(for: repo.rootPath)
      repoTechTags = RepoTechDetector.detectTags(repoPath: repo.rootPath)
    }
  }
  
  private func loadSkill(_ skill: RepoGuidanceSkill) {
    skillTitle = skill.title
    skillBody = skill.body
    skillTags = skill.tags
    skillPriority = skill.priority
    skillActive = skill.isActive
    skillSource = skill.source
    errorMessage = nil
  }
  
  private func createNewSkill() {
    selectedSkillId = nil
    skillTitle = ""
    skillBody = ""
    skillTags = ""
    skillPriority = 0
    skillActive = true
    skillSource = "manual"
    errorMessage = nil
  }
  
  private func saveSkill() {
    let trimmedBody = skillBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else {
      errorMessage = "Skill body is required"
      return
    }
    
    errorMessage = nil
    
    if let currentId = selectedSkillId,
       let updated = mcpServer.updateRepoGuidanceSkill(
         id: currentId,
         repoPath: repo.rootPath,
         repoRemoteURL: repoRemoteURL,
         repoName: repo.name,
         title: skillTitle,
         body: trimmedBody,
         source: skillSource,
         tags: skillTags,
         priority: skillPriority,
         isActive: skillActive
       ) {
      selectedSkillId = updated.id
    } else if let created = mcpServer.addRepoGuidanceSkill(
      repoPath: repo.rootPath,
      repoRemoteURL: repoRemoteURL,
      repoName: repo.name,
      title: skillTitle,
      body: trimmedBody,
      source: skillSource,
      tags: skillTags,
      priority: skillPriority,
      isActive: skillActive
    ) {
      selectedSkillId = created.id
    } else {
      errorMessage = "Failed to save skill"
    }
  }
  
  private func deleteSkill() {
    guard let selectedSkillId else { return }
    if mcpServer.deleteRepoGuidanceSkill(id: selectedSkillId) {
      createNewSkill()
    } else {
      errorMessage = "Failed to delete skill"
    }
  }
}

// MARK: - Preview

#Preview {
  RAGRepositoryCardView(
    repo: MCPServerService.RAGRepoInfo(
      id: "1",
      name: "Peel",
      rootPath: "/Users/dev/code/peel",
      lastIndexedAt: Date().addingTimeInterval(-3600),
      fileCount: 340,
      chunkCount: 3029
    ),
    mcpServer: MCPServerService(),
    isExpanded: .constant(true)
  )
  .padding()
  .frame(width: 500)
}
