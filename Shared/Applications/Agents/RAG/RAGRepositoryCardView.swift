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
  @State private var selectedPeerId: String?
  
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
      RAGRepositoryStatusBadge(status: status)
      
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

          // Embedding status indicator
          if repo.needsEmbedding {
            Label("No embeddings", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .help("Synced from peer with different model. Re-index to generate local embeddings.")
          } else if repo.hasPartialEmbeddings {
            Label("\(repo.embeddingCount)/\(repo.chunkCount)", systemImage: "bolt.trianglebadge.exclamationmark")
              .foregroundStyle(.yellow)
              .help("\(repo.chunkCount - repo.embeddingCount) chunks missing embeddings. Re-index to generate them locally.")
          } else if let model = repo.inferredEmbeddingModel {
            let localDims = mcpServer.ragStatus?.embeddingDimensions ?? 768
            let hasMismatch = repo.embeddingDimensions != nil && repo.embeddingDimensions != localDims
            Label(model, systemImage: hasMismatch ? "exclamationmark.triangle" : "arrow.down.circle")
              .foregroundStyle(hasMismatch ? .orange : .blue)
              .help(hasMismatch ? "Dimension mismatch (\(repo.embeddingDimensions ?? 0)d vs local \(localDims)d) — vector search won't work. Re-index to fix." : "Embeddings: \(model)")
          }

          if analysisState.totalChunks > 0 {
            let pct = Int(analysisState.progress * 100)
            Label("\(pct)%", systemImage: "cpu")
              .foregroundStyle(status.color)
          }
          
          if !repoSkills.isEmpty {
            Label("\(repoSkills.count)", systemImage: "lightbulb")
          }
          
          // Incoming transfer indicator (visible even when collapsed)
          if let incomingTransfer = incomingTransferForThisRepo {
            incomingTransferBadge(incomingTransfer)
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
    .contextMenu {
      if let repoIdentifier = repo.repoIdentifier {
        if SwarmCoordinator.shared.isActive {
          Button {
            Task { await syncRepoWithPeers(repoIdentifier: repoIdentifier, direction: .push) }
          } label: {
            Label("Push to Peer", systemImage: "arrow.up.circle")
          }
          .disabled(!hasConnectedPeers || isSyncing)

          Button {
            Task { await syncRepoWithPeers(repoIdentifier: repoIdentifier, direction: .pull) }
          } label: {
            Label("Pull from Peer", systemImage: "arrow.down.circle")
          }
          .disabled(!hasConnectedPeers || isSyncing)
        } else {
          Label("Start Swarm to sync", systemImage: "network.slash")
        }
      }
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
    RAGRepositoryIndexSection(
      state: indexDisplayState,
      showForceReindexConfirm: $showForceReindexConfirm,
      onReindex: { await reindexRepository(force: false) },
      onForceReindexWithAnalysisClear: {
        await reindexRepository(force: true)
        try? await mcpServer.clearRagAnalysis(repoPath: repo.rootPath)
        await refreshAnalysisStatus()
      },
      onForceReindexOnly: { await reindexRepository(force: true) }
    )
  }

  private var indexDisplayState: RAGRepositoryIndexDisplayState {
    RAGRepositoryIndexDisplayState(
      fileCount: repo.fileCount,
      chunkCount: repo.chunkCount,
      embeddingCount: repo.embeddingCount,
      needsEmbedding: repo.needsEmbedding,
      inferredEmbeddingModel: repo.inferredEmbeddingModel,
      embeddingDimensions: repo.embeddingDimensions,
      localEmbeddingDimensions: mcpServer.ragStatus?.embeddingDimensions ?? 768,
      localEmbeddingModelName: mcpServer.ragStatus?.embeddingModelName,
      isIndexingCurrentRepo: mcpServer.ragIndexingPath == repo.rootPath,
      isAnyIndexingActive: mcpServer.ragIndexingPath != nil
    )
  }
  
  // MARK: - Analysis Section
  
  @ViewBuilder
  private var analysisSection: some View {
    RAGRepositoryAnalysisSection(
      state: analysisDisplayState,
      selectedModelTier: $selectedModelTier,
      availableModels: analyzerModelOptions,
      showForceReanalyzeConfirm: $showForceReanalyzeConfirm,
      remainingEstimateText: analysisRemainingEstimateText,
      onForceReanalyze: { await forceReanalyze() },
      onPause: { analysisState.isPaused = true },
      onResume: {
        analysisState.isPaused = false
        analysisState.analyzeTask = Task { await continueAnalyzeAll() }
      },
      onStop: { stopAnalysis() },
      onQuickSample: { await analyzeQuickSample() },
      onAnalyzeAll: { startAnalyzeAll() }
    )
  }

  private var analyzerModelOptions: [RAGRepositoryAnalyzerModelOption] {
    MLXAnalyzerModelConfig.availableModels.map {
      RAGRepositoryAnalyzerModelOption(name: $0.name, tier: $0.tier)
    }
  }

  private var analysisDisplayState: RAGRepositoryAnalysisDisplayState {
    RAGRepositoryAnalysisDisplayState(
      isComplete: analysisState.isComplete,
      totalChunks: analysisState.totalChunks,
      progress: analysisState.progress,
      analyzedCount: analysisState.analyzedCount,
      isAnalyzing: analysisState.isAnalyzing,
      isPaused: analysisState.isPaused,
      batchProgress: analysisState.batchProgress,
      chunksPerSecond: analysisState.chunksPerSecond,
      unanalyzedCount: analysisState.unanalyzedCount,
      analysisStartTime: analysisState.analysisStartTime,
      analyzeError: analysisState.analyzeError,
      statusColor: status.color
    )
  }

  private var analysisRemainingEstimateText: String? {
    guard analysisState.chunksPerSecond > 0, analysisState.unanalyzedCount > 0 else { return nil }
    let remaining = Double(analysisState.unanalyzedCount) / analysisState.chunksPerSecond
    return formatDuration(remaining)
  }
  
  // MARK: - Search Section
  
  @ViewBuilder
  private var searchSection: some View {
    RAGRepositorySearchSection(
      searchQuery: $searchQuery,
      searchMode: searchModeBinding,
      searchResults: searchDisplayResults,
      isSearching: $isSearching,
      runSearch: { await runSearch() },
      languageIcon: { languageIcon(for: $0) }
    )
  }

  private var searchModeBinding: Binding<RAGRepositorySearchMode> {
    Binding(
      get: {
        switch searchMode {
        case .text: return .text
        case .vector, .hybrid: return .vector
        }
      },
      set: { newValue in
        switch newValue {
        case .text:
          searchMode = .text
        case .vector:
          searchMode = .vector
        }
      }
    )
  }

  private var searchDisplayResults: [RAGRepositorySearchDisplayResult] {
    searchResults.map {
      RAGRepositorySearchDisplayResult(
        filePath: $0.filePath,
        startLine: $0.startLine,
        endLine: $0.endLine,
        score: $0.score
      )
    }
  }
  
  // MARK: - Skills Section
  
  @ViewBuilder
  private var skillsSection: some View {
    RAGRepositorySkillsSection(
      skills: repoSkillDisplayItems,
      onManage: { showSkillsSheet = true }
    )
  }

  private var repoSkillDisplayItems: [RAGRepositorySkillDisplayItem] {
    repoSkills.map {
      RAGRepositorySkillDisplayItem(
        id: $0.id.uuidString,
        title: $0.title,
        priority: $0.priority
      )
    }
  }
  
  // MARK: - Lessons Section
  
  @ViewBuilder
  private var lessonsSection: some View {
    RAGRepositoryLessonsSection(
      lessons: repoLessonDisplayItems,
      onManage: { showLessonsSheet = true }
    )
  }

  private var repoLessonDisplayItems: [RAGRepositoryLessonDisplayItem] {
    repoLessons.map {
      RAGRepositoryLessonDisplayItem(
        id: $0.id,
        fixDescription: $0.fixDescription,
        confidence: $0.confidence
      )
    }
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

      // Per-repo sync buttons
      if let repoIdentifier = repo.repoIdentifier {
        let peers = SwarmCoordinator.shared.connectedWorkers
        let hasPeers = !peers.isEmpty && SwarmCoordinator.shared.isActive

        if SwarmCoordinator.shared.isActive && peers.count > 1 {
          // Multiple peers: show menus to pick which peer
          syncPeerMenu(peers: peers, repoIdentifier: repoIdentifier, direction: .push)
          syncPeerMenu(peers: peers, repoIdentifier: repoIdentifier, direction: .pull)
        } else {
          // Single peer (or none): direct buttons
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
          .disabled(isSyncing || !hasPeers)
          .help(
            SwarmCoordinator.shared.isActive
            ? (hasPeers ? "Push to \(peers.first?.displayName ?? "peer")" : "No peers connected")
            : "Start Swarm to sync"
          )

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
          .disabled(isSyncing || !hasPeers)
          .help(
            SwarmCoordinator.shared.isActive
            ? (hasPeers ? "Pull from \(peers.first?.displayName ?? "peer")" : "No peers connected")
            : "Start Swarm to sync"
          )

          if !SwarmCoordinator.shared.isActive {
            Text("Start Swarm to sync")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      Spacer()

      // Transfer progress indicator (outgoing — initiated by this card)
      if let transferId = activeTransferId,
         let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) {
        syncTransferStatus(transfer)
      } else if let incomingTransfer = incomingTransferForThisRepo {
        // Incoming transfer (peer is pulling from us or pushing to us)
        syncTransferStatus(incomingTransfer)
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
  private func syncRepoWithPeers(repoIdentifier: String, direction: RAGArtifactSyncDirection, workerId: String? = nil) async {
    isSyncing = true
    syncDirection = direction
    syncResultMessage = nil
    activeTransferId = nil
    errorMessage = nil

    do {
      let transferId = try await SwarmCoordinator.shared.requestRagArtifactSync(
        direction: direction,
        workerId: workerId,
        repoIdentifier: repoIdentifier
      )
      activeTransferId = transferId

      // Poll transfer status until it completes
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(0.5))
        if let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) {
          switch transfer.status {
          case .complete:
            if direction == .pull, let summary = transfer.resultSummary {
              let modelNote = transfer.remoteEmbeddingModel.map { " (model: \($0))" } ?? ""
              syncResultMessage = "Pulled from \(transfer.peerName): \(summary)\(modelNote)"
            } else {
              syncResultMessage = direction == .push ? "Pushed to \(transfer.peerName)" : "Pulled from \(transfer.peerName)"
            }
            activeTransferId = nil
            isSyncing = false
            syncDirection = nil
            if direction == .pull {
              await mcpServer.refreshRagSummary()
              await refreshAnalysisStatus()
            }
            // Auto-dismiss success message
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(6))
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
    let isIncoming = transfer.id != activeTransferId
    let peer = transfer.peerName
    switch (transfer.direction, transfer.role) {
    case (.push, .sender):
      // We are pushing to peer
      return statusText("Pushing to \(peer)", transfer: transfer)
    case (.pull, .receiver):
      // We are pulling from peer
      return statusText("Pulling from \(peer)", transfer: transfer)
    case (.pull, .sender):
      // Peer is pulling from us
      return statusText("\(peer) pulling", transfer: transfer)
    case (.push, .receiver):
      // Peer is pushing to us
      return statusText("\(peer) pushing", transfer: transfer)
    }
  }

  private func statusText(_ prefix: String, transfer: RAGArtifactTransferState) -> String {
    switch transfer.status {
    case .queued: return "\(prefix): queued…"
    case .preparing: return "\(prefix): preparing…"
    case .transferring:
      if transfer.totalBytes > 0 {
        let pct = Int(transfer.progress * 100)
        return "\(prefix): \(pct)%"
      }
      return "\(prefix)…"
    case .applying: return "\(prefix): applying…"
    case .complete: return "\(prefix): done"
    case .failed: return "\(prefix): failed"
    }
  }

  // MARK: - Incoming Transfer Detection

  /// Find any active incoming transfer for this repo (initiated by a peer, not by us)
  private var incomingTransferForThisRepo: RAGArtifactTransferState? {
    guard let repoId = repo.repoIdentifier else { return nil }
    return SwarmCoordinator.shared.ragTransfers.first { transfer in
      transfer.repoIdentifier == repoId
      && transfer.id != activeTransferId
      && transfer.status != .complete
      && transfer.status != .failed
    }
  }

  /// Compact badge for the card header showing an incoming transfer
  @ViewBuilder
  private func incomingTransferBadge(_ transfer: RAGArtifactTransferState) -> some View {
    HStack(spacing: 3) {
      ProgressView()
        .scaleEffect(0.4)
      let icon = transfer.role == .sender ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
      Image(systemName: icon)
        .font(.caption2)
      Text(transfer.peerName)
        .lineLimit(1)
    }
    .font(.caption2)
    .foregroundStyle(.blue)
    .help(transferStatusLabel(transfer))
  }

  // MARK: - Peer Picker Menu

  @ViewBuilder
  private func syncPeerMenu(peers: [ConnectedPeer], repoIdentifier: String, direction: RAGArtifactSyncDirection) -> some View {
    let isPush = direction == .push
    let label = isPush ? "Push" : "Pull"
    let icon = isPush ? "arrow.up.circle" : "arrow.down.circle"
    let isActive = isSyncing && syncDirection == direction

    Menu {
      ForEach(peers) { peer in
        Button {
          Task { await syncRepoWithPeers(repoIdentifier: repoIdentifier, direction: direction, workerId: peer.id) }
        } label: {
          Label(peer.displayName, systemImage: "desktopcomputer")
        }
      }
    } label: {
      if isActive {
        HStack(spacing: 4) {
          ProgressView()
            .scaleEffect(0.5)
          Text("\(label)…")
        }
      } else {
        Label(label, systemImage: icon)
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isSyncing)
  }

  private var hasConnectedPeers: Bool {
    SwarmCoordinator.shared.isActive && !SwarmCoordinator.shared.connectedWorkers.isEmpty
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

    // Pre-flight: verify the MLX analysis model can load (downloads if needed).
    // This surfaces download/init errors immediately instead of silently failing
    // every chunk and showing a generic "Analysis stalled" message.
    #if os(macOS)
    do {
      try await mcpServer.validateAnalysisModel(tier: selectedModelTier)
    } catch {
      await MainActor.run {
        analysisState.analyzeError = "MLX model failed to load: \(error.localizedDescription). Check your network connection and try again, or select a different model tier."
        analysisState.isAnalyzing = false
        analysisState.isPaused = false
        analysisState.sessionChunksAnalyzed = 0
        analysisState.analysisStartTime = nil
        mcpServer.markAnalysisStopped(repoPath: repo.rootPath)
      }
      return
    }
    #endif

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
                analysisState.analyzeError = "Analysis stalled: \(dbRemaining) chunks could not be processed. The MLX model may have failed to load or run out of memory — try selecting a smaller model tier, or use Force Re-analyze."
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
      chunkCount: 3029,
      embeddingCount: 3029
    ),
    mcpServer: MCPServerService(),
    isExpanded: .constant(true)
  )
  .padding()
  .frame(width: 500)
}
