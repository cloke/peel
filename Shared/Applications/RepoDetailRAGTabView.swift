//
//  RepoDetailRAGTabView.swift
//  Peel
//

import OSLog
import SwiftUI

private let repoDetailAutomationLogger = Logger(subsystem: "com.peel.repositories", category: "RepoDetailAutomation")

// MARK: - RAG Tab

struct RAGTabView: View {
  let repo: UnifiedRepository
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(RepositoryAggregator.self) private var aggregator

  @State private var isIndexing = false
  @State private var indexError: String?
  @State private var indexSuccess: String?
  @State private var searchQuery = ""
  @State private var searchMode: MCPServerService.RAGSearchMode = .vector
  @State private var searchResults: [LocalRAGSearchResult] = []
  @State private var isSearching = false
  @State private var searchError: String?
  @State private var isSearchExpanded = false
  @State private var lessons: [LocalRAGLesson] = []
  @State private var isAnalyzing = false
  @State private var analyzeError: String?
  @State private var analyzeSuccess: String?
  @State private var analyzedChunks = 0
  @State private var isEnriching = false
  @State private var enrichError: String?
  @State private var enrichedChunks = 0
  @State private var enrichResult: String?
  @State private var enrichBatchProgress: (current: Int, total: Int)?
  @State private var enrichOverallProgress: (completed: Int, total: Int)?

  // Auto-maintenance
  @State private var isAutoMaintaining = false
  @State private var autoMaintainStep: String?

  // Swarm sync state
  private var swarm: SwarmCoordinator { .shared }
  @State private var isSyncing = false
  @State private var isConnectingWAN = false
  @State private var syncDirection: RAGArtifactSyncDirection?
  @State private var syncResultMessage: String?
  @State private var syncError: String?
  @State private var activeTransferId: UUID?
  @State private var onDemandProgress: String?
  @State private var externalOnDemandProgress: String?
  @AppStorage("repositories.rag.sync.status") private var automationRAGSyncStatus = ""
  @AppStorage("repositories.rag.sync.peers") private var automationRAGSyncPeersData: Data = Data()
  @AppStorage("repositories.rag.sync.wanWorkers") private var automationRAGSyncWANWorkersData: Data = Data()

  private var isCurrentlyIndexing: Bool {
    guard let indexingPath = mcpServer.ragIndexingPath, let localPath = repo.localPath else { return false }
    return indexingPath == localPath
  }

  private var analysisState: MCPServerService.RAGRepoAnalysisState? {
    guard let path = repo.localPath else { return nil }
    if let ragRepo = mcpServer.ragRepos.first(where: { $0.rootPath == path }) {
      return mcpServer.analysisState(for: ragRepo.id, repoPath: path)
    }
    return nil
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        heroCard

        if repo.ragStatus != nil && repo.ragStatus != .notIndexed, repo.localPath != nil {
          searchSection
        }

        if !lessons.isEmpty {
          lessonsSection
        }
      }
      .padding(16)
    }
    .task {
      restoreActiveTransferIfNeeded()
      await loadLessons()
      await refreshAnalysisStatus()
      persistRAGSyncAutomationState()
      handlePendingRAGUIActionIfNeeded()

      // Auto-maintain for tracked repos: trigger reindex/analyze/enrich if needed
      // When last sync was a pull from a peer, skip the unenriched check —
      // the peer already enriched; we only need to keep index/analysis fresh.
      if repo.isTracked, !isAutoMaintaining, !isAnalyzing, !isEnriching, !isCurrentlyIndexing {
        let isStale = repo.ragStatus == .stale
        let hasUnanalyzed = (analysisState?.unanalyzedCount ?? 0) > 0
        let lastSyncWasPull = swarm.localRagArtifactStatus?.lastSyncDirection == .pull
        let hasUnenriched = !lastSyncWasPull && max(0, (analysisState?.analyzedCount ?? 0) - enrichedChunks) > 0
        if isStale || hasUnanalyzed || hasUnenriched {
          await autoMaintain()
        }
      }
    }
    .task {
      await pollExternalTransfers()
    }
    .task(id: activeTransferId) {
      await pollRestoredLANTransfer()
    }
    .onAppear {
      restoreActiveTransferIfNeeded()
      persistRAGSyncAutomationState()
      handlePendingRAGUIActionIfNeeded()
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RepositoryAutomationActionRequested"))) { notification in
      guard let controlId = notification.object as? String,
            controlId.hasPrefix("repositories.rag.sync.") else { return }
      handlePendingRAGUIActionIfNeeded(controlId: controlId)
    }
    .onChange(of: mcpServer.lastUIAction?.id) { _, _ in
      handlePendingRAGUIActionIfNeeded()
    }
    .onChange(of: isSyncing) { _, _ in
      persistRAGSyncAutomationState()
    }
    .onChange(of: syncResultMessage) { _, _ in
      persistRAGSyncAutomationState()
    }
    .onChange(of: syncError) { _, _ in
      persistRAGSyncAutomationState()
    }
    .onChange(of: onDemandProgress) { _, _ in
      persistRAGSyncAutomationState()
    }
    .onChange(of: externalOnDemandProgress) { _, _ in
      persistRAGSyncAutomationState()
    }
  }

  // MARK: - Search Section

  private var searchSection: some View {
    DisclosureGroup(isExpanded: $isSearchExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          TextField("Search this repo…", text: $searchQuery)
            .textFieldStyle(.plain)
            .onSubmit {
              Task { await runSearch() }
            }

          Picker("", selection: $searchMode) {
            Text("Vector").tag(MCPServerService.RAGSearchMode.vector)
            Text("Text").tag(MCPServerService.RAGSearchMode.text)
            Text("Hybrid").tag(MCPServerService.RAGSearchMode.hybrid)
          }
          .pickerStyle(.segmented)
          .frame(width: 180)

          if isSearching {
            ProgressView()
              .controlSize(.small)
          } else {
            Button {
              Task { await runSearch() }
            } label: {
              Image(systemName: "arrow.right.circle.fill")
                .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor))
        )

        if let error = searchError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
        }

        if !searchResults.isEmpty {
          HStack {
            Text("\(searchResults.count) results")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
          }

          LazyVStack(spacing: 1) {
            ForEach(searchResults.prefix(20), id: \.filePath) { result in
              RepoSearchResultRow(result: result)
            }
          }
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
      .padding(.top, 8)
    } label: {
      Label("Search", systemImage: "magnifyingglass")
        .font(.headline)
    }
  }

  // MARK: - Hero Card

  private var heroCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        // Status header
        HStack(spacing: 12) {
          ZStack {
            Circle()
              .fill(ragStatusColor.opacity(0.15))
              .frame(width: 40, height: 40)

            if isCurrentlyIndexing || isAnalyzing || isEnriching || isAutoMaintaining {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: ragStatusIcon)
                .font(.title3)
                .foregroundStyle(ragStatusColor)
            }
          }

          VStack(alignment: .leading, spacing: 2) {
            Text(ragStatusTitle)
              .font(.headline)

            if let model = liveEmbeddingModel ?? repo.ragEmbeddingModel {
              Text(model)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          Spacer()

          if isCurrentlyIndexing || isAnalyzing || isEnriching || isAutoMaintaining {
            // Progress shown below
          } else if repo.ragStatus == nil || repo.ragStatus == .notIndexed {
            Button("Index Now") {
              Task { await indexRepo(force: false) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(repo.localPath == nil)
          } else {
            Menu {
              Button("Re-Index") {
                Task { await indexRepo(force: false) }
              }
              Button("Force Full Re-Index") {
                Task { await indexRepo(force: true) }
              }
              Divider()
              Button(isAnalyzing ? "Analyzing…" : "Analyze Chunks") {
                Task { await analyzeChunks() }
              }
              .disabled(isAnalyzing)
              Button(isEnriching ? "Enriching…" : "Enrich Embeddings") {
                Task { await enrichEmbeddings() }
              }
              .disabled(isEnriching)
            } label: {
              Image(systemName: "ellipsis.circle")
                .font(.title3)
            }
            .buttonStyle(.plain)
          }
        }

        // Compact stats line
        let fileCount = liveFileCount ?? repo.ragFileCount
        let chunkCount = liveChunkCount ?? repo.ragChunkCount
        let lastIndexed = liveLastIndexedAt ?? repo.ragLastIndexedAt
        if fileCount != nil || chunkCount != nil || lastIndexed != nil {
          Divider()

          HStack(spacing: 4) {
            if let fc = fileCount {
              Text("\(fc) files")
            }
            if fileCount != nil, chunkCount != nil {
              Text("\u{00B7}").foregroundStyle(.tertiary)
            }
            if let cc = chunkCount {
              Text("\(cc) chunks")
            }
            if enrichedChunks > 0 {
              Text("\u{00B7}").foregroundStyle(.tertiary)
              Text("\(enrichedChunks) enriched")
            }
            if let li = lastIndexed {
              Text("\u{00B7}").foregroundStyle(.tertiary)
              Text(li, style: .relative)
              Text("ago")
            }
          }
          .font(.callout)
          .foregroundStyle(.secondary)
        }

        // Maintenance action rows — surface what needs attention
        maintenanceSection

        // Active progress bars
        activeProgressSection

        // Swarm sync (inline)
        if swarm.isActive {
          Divider()
          swarmContent
        }

        // Status messages
        statusMessages
      }
      .padding(4)
    }
  }

  // MARK: - Maintenance Section

  @ViewBuilder
  private var maintenanceSection: some View {
    let totalChunks = liveChunkCount ?? repo.ragChunkCount ?? 0
    let unanalyzed = analysisState?.unanalyzedCount ?? 0
    let analyzed = analysisState?.analyzedCount ?? 0
    let unenriched = max(0, analyzed - enrichedChunks)
    let isStale = repo.ragStatus == .stale
    let isIndexed = repo.ragStatus != nil && repo.ragStatus != .notIndexed
    let hasWork = isIndexed && (isStale || unanalyzed > 0 || unenriched > 0)
    let allGood = isIndexed && !isStale && unanalyzed == 0 && unenriched == 0 && totalChunks > 0

    if hasWork || allGood {
      Divider()
    }

    if allGood && !isAnalyzing && !isEnriching && !isCurrentlyIndexing && !isAutoMaintaining {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.caption)
        Text("All \(totalChunks) chunks analyzed & enriched")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if hasWork && !isAutoMaintaining {
      VStack(alignment: .leading, spacing: 6) {
        if isStale {
          maintenanceRow(
            icon: "exclamationmark.triangle.fill",
            color: .yellow,
            text: "Index is stale",
            buttonLabel: "Re-Index",
            isActive: isCurrentlyIndexing
          ) {
            Task { await indexRepo(force: false) }
          }
        }

        if unanalyzed > 0 {
          maintenanceRow(
            icon: "cpu",
            color: .purple,
            text: "\(unanalyzed) chunks need analysis",
            buttonLabel: "Analyze",
            isActive: isAnalyzing
          ) {
            Task { await analyzeChunks() }
          }
        }

        if unenriched > 0 {
          maintenanceRow(
            icon: "sparkles",
            color: .orange,
            text: "\(unenriched) chunks need enrichment",
            buttonLabel: "Enrich",
            isActive: isEnriching
          ) {
            Task { await enrichEmbeddings() }
          }
        }

        // "Fix All" button when multiple things need doing
        let actionCount = (isStale ? 1 : 0) + (unanalyzed > 0 ? 1 : 0) + (unenriched > 0 ? 1 : 0)
        if actionCount > 1, !isCurrentlyIndexing, !isAnalyzing, !isEnriching {
          HStack {
            Spacer()
            Button {
              Task { await autoMaintain() }
            } label: {
              Label("Fix All", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }
        }
      }
    }

    if isAutoMaintaining, let step = autoMaintainStep {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text(step)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func maintenanceRow(icon: String, color: Color, text: String, buttonLabel: String, isActive: Bool, action: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .foregroundStyle(color)
        .font(.caption)
        .frame(width: 16)
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if isActive {
        ProgressView()
          .controlSize(.mini)
      } else {
        Button(buttonLabel, action: action)
          .buttonStyle(.bordered)
          .controlSize(.mini)
      }
    }
  }

  // MARK: - Active Progress

  @ViewBuilder
  private var activeProgressSection: some View {
    if let state = analysisState, state.totalChunks > 0, (state.isAnalyzing || isAnalyzing) {
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: state.progress)
          .tint(.purple)
        HStack {
          Text("\(state.analyzedCount) / \(state.totalChunks) chunks analyzed")
            .font(.caption2)
            .foregroundStyle(.secondary)
          if state.chunksPerSecond > 0 {
            Text("\u{00B7} \(String(format: "%.1f", state.chunksPerSecond))/sec")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          Spacer()
          Text("\(Int(state.progress * 100))%")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }

    if isAnalyzing, let state = analysisState, let batch = state.batchProgress {
      VStack(alignment: .leading, spacing: 2) {
        ProgressView(value: Double(batch.current), total: Double(batch.total))
          .tint(.purple)
        HStack {
          Text("Analyzing chunk \(batch.current) of \(batch.total)")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
          Spacer()
          if state.chunksPerSecond > 0 {
            Text("\(String(format: "%.1f", state.chunksPerSecond)) chunks/sec")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }
    }

    if isEnriching {
      if let overall = enrichOverallProgress, overall.total > 0 {
        VStack(alignment: .leading, spacing: 2) {
          ProgressView(value: Double(overall.completed), total: Double(overall.total))
            .tint(.orange)
          Text("Enriching \(overall.completed) of \(overall.total) chunks")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      } else if let batch = enrichBatchProgress {
        VStack(alignment: .leading, spacing: 2) {
          ProgressView(value: Double(batch.current), total: Double(batch.total))
            .tint(.orange)
          Text("Enriching \(batch.current) of \(batch.total)")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      } else {
        ProgressView()
          .tint(.orange)
      }
    }
  }

  @ViewBuilder
  private var statusMessages: some View {
    if let error = indexError {
      Label(error, systemImage: "xmark.circle")
        .font(.caption)
        .foregroundStyle(.red)
    }
    if let success = indexSuccess {
      Label(success, systemImage: "checkmark.circle")
        .font(.caption)
        .foregroundStyle(.green)
    }
    if let error = analyzeError {
      Label(error, systemImage: "xmark.circle")
        .font(.caption)
        .foregroundStyle(.red)
    }
    if let success = analyzeSuccess {
      Label(success, systemImage: success.contains("No ") ? "info.circle" : "checkmark.circle")
        .font(.caption)
        .foregroundColor(success.contains("No ") ? .secondary : .green)
    }
    if let error = enrichError {
      Label(error, systemImage: "xmark.circle")
        .font(.caption)
        .foregroundStyle(.red)
    }
    if let result = enrichResult {
      Label(result, systemImage: result.contains("No ") ? "info.circle" : "checkmark.circle")
        .font(.caption)
        .foregroundColor(result.contains("No ") ? .secondary : .green)
    }
  }

  private var ragStatusColor: Color {
    if isCurrentlyIndexing { return .orange }
    switch repo.ragStatus {
    case .indexed, .analyzed: return .green
    case .indexing: return .orange
    case .analyzing: return .purple
    case .stale: return .yellow
    case .notIndexed, .none: return .secondary
    }
  }

  private var ragStatusIcon: String {
    switch repo.ragStatus {
    case .indexed: return "checkmark.circle.fill"
    case .analyzed: return "checkmark.seal.fill"
    case .indexing: return "arrow.triangle.2.circlepath"
    case .analyzing: return "cpu.fill"
    case .stale: return "exclamationmark.triangle"
    case .notIndexed, .none: return "magnifyingglass.circle"
    }
  }

  private var ragStatusTitle: String {
    if isCurrentlyIndexing { return "Indexing…" }
    return repo.ragStatus?.displayName ?? "Not Indexed"
  }

  /// Live RAG repo entries matching this repository (refreshed after sync).
  /// Searches all matching repos (parent + sub-packages) by identifier or local path.
  private var liveRagRepos: [MCPServerService.RAGRepoInfo] {
    let identifier = repo.normalizedRemoteURL
    return mcpServer.ragRepos.filter {
      $0.repoIdentifier == identifier || $0.rootPath == repo.localPath
    }
  }

  /// Live embedding model — prefers the entry with actual data (most chunks).
  private var liveEmbeddingModel: String? {
    let withModel = liveRagRepos.filter { $0.embeddingModel != nil }
    if let best = withModel.max(by: { $0.chunkCount < $1.chunkCount }) {
      return best.embeddingModel
    }
    return liveRagRepos.first?.embeddingModel
  }

  /// Live file count from mcpServer.ragRepos (sum of matching entries).
  private var liveFileCount: Int? {
    let repos = liveRagRepos
    guard !repos.isEmpty else { return nil }
    let total = repos.reduce(0) { $0 + $1.fileCount }
    return total > 0 ? total : nil
  }

  /// Live chunk count from mcpServer.ragRepos (sum of matching entries).
  private var liveChunkCount: Int? {
    let repos = liveRagRepos
    guard !repos.isEmpty else { return nil }
    let total = repos.reduce(0) { $0 + $1.chunkCount }
    return total > 0 ? total : nil
  }

  /// Live last-indexed date from mcpServer.ragRepos (most recent).
  private var liveLastIndexedAt: Date? {
    liveRagRepos.compactMap(\.lastIndexedAt).max()
  }

  /// All root paths for repos in this tracked repo group (parent + sub-packages).
  private var allRepoPaths: [String] {
    liveRagRepos.map(\.rootPath)
  }

  // MARK: - Lessons Section

  private var lessonsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionHeader("Learned Lessons")
        Spacer()
        Text("\(lessons.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      LazyVStack(spacing: 1) {
        ForEach(lessons.prefix(10), id: \.id) { lesson in
          HStack(spacing: 10) {
            Circle()
              .fill(lesson.confidence >= 0.7 ? .green : lesson.confidence >= 0.4 ? .orange : .red)
              .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
              Text(lesson.fixDescription)
                .font(.callout)
                .lineLimit(2)

              HStack(spacing: 8) {
                Text("\(Int(lesson.confidence * 100))% confidence")
                if lesson.applyCount > 0 {
                  Text("· Applied \(lesson.applyCount)×")
                }
                if !lesson.source.isEmpty {
                  Text("· \(lesson.source)")
                }
              }
              .font(.caption2)
              .foregroundStyle(.tertiary)
            }

            Spacer()
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
        }
      }
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))

      if lessons.count > 10 {
        Text("+ \(lessons.count - 10) more lessons")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Swarm Sync

  /// Derives the repo identifier used by the swarm sync protocol.
  private var ragRepoIdentifier: String? {
    if let ragRepo = mcpServer.ragRepos.first(where: { $0.rootPath == repo.localPath }) {
      return ragRepo.repoIdentifier
    }
    return repo.normalizedRemoteURL.isEmpty ? nil : repo.normalizedRemoteURL
  }

  private var swarmContent: some View {
    // Access firestoreWorkerVersion so @Observable triggers re-render
    // when the Firestore worker snapshot changes (FirebaseService is
    // not itself @Observable).
    let _ = swarm.firestoreWorkerVersion
    let peers = SwarmPeerPreferences.ordered(peers: swarm.connectedWorkers)
    let onDemandWorkers = SwarmPeerPreferences.ordered(workers: swarm.allOnDemandWorkers)

    return VStack(alignment: .leading, spacing: 8) {
      // Active transfer / sync progress
      swarmProgressView

      // Peer rows — show each peer directly instead of behind menus
      if let repoId = ragRepoIdentifier {
        if peers.isEmpty && onDemandWorkers.isEmpty {
          HStack(spacing: 6) {
            Label("Swarm", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("\u{00B7} No peers available")
              .font(.caption)
              .foregroundStyle(.tertiary)
            Spacer()
          }
        } else {
          HStack(spacing: 6) {
            Label("Swarm", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
          }

          ForEach(peers) { peer in
            peerRow(peer: peer, repoIdentifier: repoId)
          }
          ForEach(onDemandWorkers, id: \.id) { worker in
            wanWorkerRow(worker: worker, repoIdentifier: repoId)
          }
        }
      } else {
        HStack(spacing: 6) {
          Label("Swarm", systemImage: "point.3.connected.trianglepath.dotted")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\u{00B7} Index first to enable sync")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  @ViewBuilder
  private var swarmProgressView: some View {
    if let progress = onDemandProgress {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text(progress)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if let externalOnDemandProgress {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text(externalOnDemandProgress)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if let transferId = activeTransferId,
              let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text(syncTransferLabel(transfer))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if let result = syncResultMessage {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.caption)
        Text(result)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if let error = syncError {
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.caption)
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private func peerRow(peer: ConnectedPeer, repoIdentifier: String) -> some View {
    let repoId = repo.normalizedRemoteURL
    let hasRepo = peer.capabilities.indexedRepos.contains(repoId)
    return HStack(spacing: 8) {
      Image(systemName: "desktopcomputer")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(peer.displayName)
        .font(.caption)
      if !hasRepo {
        Text("not indexed")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Spacer()
      Button {
        Task { await syncWithPeers(repoIdentifier: repoIdentifier, direction: .push, workerId: peer.id) }
      } label: {
        Label("Push", systemImage: "arrow.up.circle")
          .font(.caption)
      }
      .buttonStyle(.bordered)
      .controlSize(.mini)
      .disabled(isSyncing)

      Button {
        Task { await syncWithPeers(repoIdentifier: repoIdentifier, direction: .pull, workerId: peer.id) }
      } label: {
        Label("Pull", systemImage: "arrow.down.circle")
          .font(.caption)
      }
      .buttonStyle(.bordered)
      .controlSize(.mini)
      .disabled(isSyncing || !hasRepo)
    }
  }

  private func wanWorkerRow(worker: FirestoreWorker, repoIdentifier: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "globe")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(worker.displayName)
        .font(.caption)
      if worker.isStale {
        Text("offline")
          .font(.caption2)
          .foregroundStyle(.red)
      }
      Spacer()
      Button {
        Task { await syncOnDemand(repoIdentifier: repoIdentifier, fromWorkerId: worker.id) }
      } label: {
        Label("Pull", systemImage: "arrow.down.circle")
          .font(.caption)
      }
      .buttonStyle(.bordered)
      .controlSize(.mini)
      .disabled(isSyncing)

      Button {
        Task { await connectWANPeer(worker) }
      } label: {
        Label("Connect", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.caption)
      }
      .buttonStyle(.bordered)
      .controlSize(.mini)
      .disabled(isSyncing || isConnectingWAN)
    }
  }

  private func connectWANPeer(_ worker: FirestoreWorker) async {
    isConnectingWAN = true
    defer { isConnectingWAN = false }
    do {
      try await swarm.connectToWANWorker(worker)
      syncResultMessage = "Connected to \(worker.displayName) — push/pull now available"
    } catch {
      syncError = "WAN connect failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Unified Peer Menus (removed — peers shown directly)

  private func syncTransferLabel(_ transfer: RAGArtifactTransferState) -> String {
    switch transfer.status {
    case .queued: return "Queued…"
    case .preparing: return "Preparing…"
    case .transferring:
      if transfer.totalBytes > 0 {
        let pct = Int(Double(transfer.transferredBytes) / Double(transfer.totalBytes) * 100)
        return "Transferring: \(pct)%"
      }
      return "Transferring…"
    case .applying: return "Applying…"
    case .complete: return "Complete"
    case .failed: return transfer.errorMessage ?? "Failed"
    case .stalled: return "Stalled — waiting for reconnect"
    }
  }

  // MARK: - Transfer Restore

  /// On view (re)creation, check if there's an active LAN transfer for this repo and restore tracking state.
  private func restoreActiveTransferIfNeeded() {
    guard activeTransferId == nil else { return }  // already tracking
    guard let repoId = ragRepoIdentifier else { return }
    let activeStatuses: Set<RAGArtifactTransferStatus> = [.queued, .preparing, .transferring, .applying, .stalled]
    if let transfer = SwarmCoordinator.shared.ragTransfers.first(where: {
      $0.repoIdentifier == repoId && activeStatuses.contains($0.status)
    }) {
      activeTransferId = transfer.id
      isSyncing = true
      syncDirection = transfer.direction
      repoDetailAutomationLogger.info("Restored active LAN transfer \(transfer.id) for repo=\(self.repo.displayName, privacy: .public) status=\(transfer.status.rawValue, privacy: .public)")
    }
  }

  /// Polls a restored LAN transfer to completion. Only runs when activeTransferId is set
  /// but syncWithPeers isn't running (i.e. the view was recreated mid-transfer).
  private func pollRestoredLANTransfer() async {
    guard let transferId = activeTransferId else { return }

    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(0.5))
      guard let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) else {
        // Transfer disappeared — clean up
        activeTransferId = nil
        isSyncing = false
        syncDirection = nil
        persistRAGSyncAutomationState()
        return
      }
      switch transfer.status {
      case .complete:
        let direction = transfer.direction
        if direction == .pull, let summary = transfer.resultSummary {
          let modelNote = transfer.remoteEmbeddingModel.map { " (model: \($0))" } ?? ""
          syncResultMessage = "Pulled from \(transfer.peerName): \(summary)\(modelNote)"
        } else {
          syncResultMessage = direction == .push ? "Pushed to \(transfer.peerName)" : "Pulled from \(transfer.peerName)"
        }
        activeTransferId = nil
        isSyncing = false
        syncDirection = nil
        persistRAGSyncAutomationState()
        if direction == .pull {
          await mcpServer.refreshRagSummary()
          aggregator.requestRebuild()
          await refreshAnalysisStatus()
        }
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(8))
          if syncResultMessage != nil { syncResultMessage = nil }
        }
        return
      case .failed:
        syncError = transfer.errorMessage ?? "Transfer failed"
        activeTransferId = nil
        isSyncing = false
        syncDirection = nil
        persistRAGSyncAutomationState()
        return
      default:
        continue
      }
    }
  }

  // MARK: - Sync Actions

  private func syncWithPeers(repoIdentifier: String, direction: RAGArtifactSyncDirection, workerId: String? = nil) async {
    let targetWorker = workerId ?? SwarmPeerPreferences.defaultPeer(from: SwarmCoordinator.shared.connectedWorkers)?.id ?? "auto"
    repoDetailAutomationLogger.info("RAG sync start repo=\(repo.displayName, privacy: .public) direction=\(direction.rawValue, privacy: .public) worker=\(targetWorker, privacy: .public)")
    isSyncing = true
    syncDirection = direction
    syncResultMessage = nil
    syncError = nil
    activeTransferId = nil
    onDemandProgress = nil
    externalOnDemandProgress = nil
    persistRAGSyncAutomationState()

    do {
      let transferId = try await SwarmCoordinator.shared.requestRagArtifactSync(
        direction: direction,
        workerId: workerId,
        repoIdentifier: repoIdentifier
      )
      activeTransferId = transferId

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
            repoDetailAutomationLogger.info("RAG sync completed repo=\(self.repo.displayName, privacy: .public) direction=\(direction.rawValue, privacy: .public) peer=\(transfer.peerName, privacy: .public)")
            activeTransferId = nil
            isSyncing = false
            syncDirection = nil
            persistRAGSyncAutomationState()
            if direction == .pull {
              await mcpServer.refreshRagSummary()
              aggregator.requestRebuild()
              await refreshAnalysisStatus()
            }
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(8))
              if syncResultMessage != nil { syncResultMessage = nil }
            }
            return
          case .failed:
            syncError = transfer.errorMessage ?? "Transfer failed"
            repoDetailAutomationLogger.error("RAG sync failed repo=\(self.repo.displayName, privacy: .public) direction=\(direction.rawValue, privacy: .public) error=\(self.syncError ?? "unknown", privacy: .public)")
            activeTransferId = nil
            isSyncing = false
            syncDirection = nil
            persistRAGSyncAutomationState()
            return
          default:
            continue
          }
        }
      }
    } catch {
      syncError = "Sync failed: \(error.localizedDescription)"
      repoDetailAutomationLogger.error("RAG sync threw repo=\(self.repo.displayName, privacy: .public) direction=\(direction.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
    }
    isSyncing = false
    syncDirection = nil
    persistRAGSyncAutomationState()
  }

  private func syncOnDemand(repoIdentifier: String, fromWorkerId: String) async {
    let workerName = FirebaseService.shared.swarmWorkers
      .first(where: { $0.id == fromWorkerId })?.displayName ?? fromWorkerId

    isSyncing = true
    syncDirection = .pull
    syncResultMessage = nil
    syncError = nil
    activeTransferId = nil
    onDemandProgress = "Requesting pull from \(workerName)…"
    externalOnDemandProgress = nil
    repoDetailAutomationLogger.info("RAG on-demand sync start repo=\(self.repo.displayName, privacy: .public) worker=\(workerName, privacy: .public) id=\(fromWorkerId, privacy: .public)")
    persistRAGSyncAutomationState()

    var syncFinished = false

    let syncTask = Task { @MainActor in
      let transferId = try await SwarmCoordinator.shared.requestRagArtifactSync(
        direction: .pull,
        workerId: fromWorkerId,
        repoIdentifier: repoIdentifier
      )
      return transferId
    }

    // Wait briefly for the transfer to be recorded
    try? await Task.sleep(for: .seconds(0.3))

    let swarm = SwarmCoordinator.shared
    while !syncFinished && !Task.isCancelled {
      if let transfer = swarm.ragTransfers.first(where: {
        $0.repoIdentifier == repoIdentifier && $0.peerId == fromWorkerId
      }) {
        switch transfer.status {
        case .queued:
          onDemandProgress = "Queued…"
        case .preparing:
          onDemandProgress = "Preparing…"
        case .transferring:
          if transfer.totalBytes > 0 && transfer.transferredBytes > 0 {
            let pct = Int(transfer.progress * 100)
            let elapsed = Int(Date().timeIntervalSince(transfer.startedAt))
            onDemandProgress = "Downloading: \(pct)% [\(elapsed)s]"
          } else {
            let elapsed = Int(Date().timeIntervalSince(transfer.startedAt))
            onDemandProgress = "Transferring… [\(elapsed)s]"
          }
        case .applying:
          let byteStr = formatBytes(transfer.transferredBytes)
          onDemandProgress = "Importing \(byteStr)…"
        case .complete:
          syncFinished = true
        case .failed, .stalled:
          syncFinished = true
        }
        persistRAGSyncAutomationState()
      }

      try? await Task.sleep(for: .seconds(0.3))
    }

    // Read final state
    if let transfer = swarm.ragTransfers.first(where: {
      $0.repoIdentifier == repoIdentifier && $0.peerId == fromWorkerId
    }) {
      switch transfer.status {
      case .complete:
        let byteStr = formatBytes(transfer.transferredBytes)
        syncResultMessage = "Pulled from \(workerName): \(byteStr)"
        repoDetailAutomationLogger.info("RAG on-demand sync completed repo=\(self.repo.displayName, privacy: .public) worker=\(workerName, privacy: .public) bytes=\(byteStr, privacy: .public)")
        await mcpServer.refreshRagSummary()
        aggregator.requestRebuild()
        await refreshAnalysisStatus()
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(8))
          if syncResultMessage != nil { syncResultMessage = nil }
        }
      case .failed, .stalled:
        syncError = transfer.errorMessage ?? "On-demand sync failed"
        repoDetailAutomationLogger.error("RAG on-demand sync failed repo=\(self.repo.displayName, privacy: .public) worker=\(workerName, privacy: .public) error=\(self.syncError ?? "unknown", privacy: .public)")
      default:
        break
      }
    } else {
      // If we can't find the transfer, check the task result
      do {
        _ = try await syncTask.value
        syncResultMessage = "Pulled from \(workerName)"
        repoDetailAutomationLogger.info("RAG on-demand sync finished without retained transfer state repo=\(self.repo.displayName, privacy: .public) worker=\(workerName, privacy: .public)")
        await mcpServer.refreshRagSummary()
        aggregator.requestRebuild()
        await refreshAnalysisStatus()
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(8))
          if syncResultMessage != nil { syncResultMessage = nil }
        }
      } catch {
        syncError = "On-demand sync failed: \(error.localizedDescription)"
        repoDetailAutomationLogger.error("RAG on-demand sync threw repo=\(self.repo.displayName, privacy: .public) worker=\(workerName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
      }
    }

    onDemandProgress = nil
    isSyncing = false
    syncDirection = nil
    persistRAGSyncAutomationState()
  }

  private func persistRAGSyncAutomationState() {
    let peers = swarm.connectedWorkers.map(\ .displayName)
    let wanWorkers = swarm.allOnDemandWorkers.map(\ .displayName)
    if let peersData = try? JSONEncoder().encode(peers) {
      automationRAGSyncPeersData = peersData
    }
    if let wanData = try? JSONEncoder().encode(wanWorkers) {
      automationRAGSyncWANWorkersData = wanData
    }

    if let progress = onDemandProgress, !progress.isEmpty {
      automationRAGSyncStatus = progress
    } else if let progress = externalOnDemandProgress, !progress.isEmpty {
      automationRAGSyncStatus = progress
    } else if let result = syncResultMessage, !result.isEmpty {
      automationRAGSyncStatus = result
    } else if let error = syncError, !error.isEmpty {
      automationRAGSyncStatus = error
    } else if isSyncing {
      automationRAGSyncStatus = "syncing"
    } else if !peers.isEmpty {
      automationRAGSyncStatus = "ready-lan"
    } else if !wanWorkers.isEmpty {
      automationRAGSyncStatus = "ready-wan"
    } else if swarm.isActive {
      automationRAGSyncStatus = "no-peers"
    } else {
      automationRAGSyncStatus = "swarm-inactive"
    }
  }

  private func handlePendingRAGUIActionIfNeeded(controlId: String? = nil) {
    let controlId = controlId ?? mcpServer.lastUIAction?.controlId
    guard let controlId else { return }

    let repoId = ragRepoIdentifier
    switch controlId {
    case "repositories.rag.sync.push":
      guard let repoId,
            let peer = SwarmPeerPreferences.defaultPeer(from: swarm.connectedWorkers) else {
        automationRAGSyncStatus = "no-lan-peer"
        if mcpServer.lastUIAction?.controlId == controlId {
          mcpServer.recordUIActionHandled(controlId)
          mcpServer.lastUIAction = nil
        }
        return
      }
      repoDetailAutomationLogger.info("Handling UI push tap for repo=\(self.repo.displayName, privacy: .public) peer=\(peer.displayName, privacy: .public)")
      if mcpServer.lastUIAction?.controlId == controlId {
        mcpServer.recordUIActionHandled(controlId)
        mcpServer.lastUIAction = nil
      }
      Task { await syncWithPeers(repoIdentifier: repoId, direction: .push, workerId: peer.id) }

    case "repositories.rag.sync.pull":
      guard let repoId,
            let peer = SwarmPeerPreferences.defaultPeer(from: swarm.connectedWorkers) else {
        automationRAGSyncStatus = "no-lan-peer"
        if mcpServer.lastUIAction?.controlId == controlId {
          mcpServer.recordUIActionHandled(controlId)
          mcpServer.lastUIAction = nil
        }
        return
      }
      repoDetailAutomationLogger.info("Handling UI pull tap for repo=\(self.repo.displayName, privacy: .public) peer=\(peer.displayName, privacy: .public)")
      if mcpServer.lastUIAction?.controlId == controlId {
        mcpServer.recordUIActionHandled(controlId)
        mcpServer.lastUIAction = nil
      }
      Task { await syncWithPeers(repoIdentifier: repoId, direction: .pull, workerId: peer.id) }

    case "repositories.rag.sync.pullWan":
      guard let repoId,
            let worker = SwarmPeerPreferences.defaultWorker(from: swarm.allOnDemandWorkers) else {
        automationRAGSyncStatus = "no-wan-worker"
        if mcpServer.lastUIAction?.controlId == controlId {
          mcpServer.recordUIActionHandled(controlId)
          mcpServer.lastUIAction = nil
        }
        return
      }
      repoDetailAutomationLogger.info("Handling UI WAN pull tap for repo=\(self.repo.displayName, privacy: .public) worker=\(worker.displayName, privacy: .public)")
      if mcpServer.lastUIAction?.controlId == controlId {
        mcpServer.recordUIActionHandled(controlId)
        mcpServer.lastUIAction = nil
      }
      Task { await syncOnDemand(repoIdentifier: repoId, fromWorkerId: worker.id) }

    case "repositories.rag.analyze":
      if mcpServer.lastUIAction?.controlId == controlId {
        mcpServer.recordUIActionHandled(controlId)
        mcpServer.lastUIAction = nil
      }
      Task { await analyzeChunks() }

    case "repositories.rag.enrich":
      if mcpServer.lastUIAction?.controlId == controlId {
        mcpServer.recordUIActionHandled(controlId)
        mcpServer.lastUIAction = nil
      }
      Task { await enrichEmbeddings() }

    default:
      break
    }
  }

  private func pollExternalTransfers() async {
    let swarm = SwarmCoordinator.shared
    while !Task.isCancelled {
      if !isSyncing,
         let repoId = ragRepoIdentifier,
         let transfer = swarm.ragTransfers.first(where: {
           $0.repoIdentifier == repoId && $0.status != .complete && $0.status != .failed
         }) {
        let worker = transfer.peerName
        switch transfer.status {
        case .queued:
          externalOnDemandProgress = "MCP pull from \(worker): Queued…"
        case .preparing:
          externalOnDemandProgress = "MCP pull from \(worker): Preparing…"
        case .transferring:
          let elapsed = Int(Date().timeIntervalSince(transfer.startedAt))
          if transfer.totalBytes > 0 && transfer.transferredBytes > 0 {
            let pct = Int(transfer.progress * 100)
            externalOnDemandProgress = "MCP pull from \(worker): \(pct)% [\(elapsed)s]"
          } else {
            externalOnDemandProgress = "MCP pull from \(worker): Transferring… [\(elapsed)s]"
          }
        case .applying:
          externalOnDemandProgress = "MCP pull from \(worker): Importing \(formatBytes(transfer.transferredBytes))…"
        case .complete, .failed, .stalled:
          externalOnDemandProgress = nil
        }
      } else if externalOnDemandProgress != nil {
        externalOnDemandProgress = nil
      }
      persistRAGSyncAutomationState()
      try? await Task.sleep(for: .seconds(0.5))
    }
  }

  private func formatBytes(_ bytes: Int) -> String {
    if bytes >= 1_048_576 {
      return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    } else if bytes >= 1024 {
      return String(format: "%.0f KB", Double(bytes) / 1024)
    }
    return "\(bytes) B"
  }

  // MARK: - Actions

  /// Auto-maintenance: chains reindex → analyze → enrich for tracked repos.
  /// Can also be triggered manually via "Fix All" button.
  private func autoMaintain() async {
    guard repo.localPath != nil else { return }
    isAutoMaintaining = true
    defer { isAutoMaintaining = false; autoMaintainStep = nil }

    // Step 1: Re-index if stale
    if repo.ragStatus == .stale {
      autoMaintainStep = "Re-indexing..."
      await indexRepo(force: false)
    }

    // Step 2: Analyze unanalyzed chunks
    await refreshAnalysisStatus()
    if (analysisState?.unanalyzedCount ?? 0) > 0 {
      autoMaintainStep = "Analyzing chunks..."
      await analyzeChunks()
    }

    // Step 3: Enrich unenriched chunks (skip when RAG was pulled from a peer —
    // the peer already enriched; re-enriching locally is redundant and expensive)
    let lastSyncWasPull = swarm.localRagArtifactStatus?.lastSyncDirection == .pull
    if !lastSyncWasPull {
      await refreshAnalysisStatus()
      let unenriched = max(0, (analysisState?.analyzedCount ?? 0) - enrichedChunks)
      if unenriched > 0 {
        autoMaintainStep = "Enriching embeddings..."
        await enrichEmbeddings()
      }
    }

    autoMaintainStep = nil
    await refreshAnalysisStatus()
  }

  private func indexRepo(force: Bool) async {
    guard let path = repo.localPath else { return }
    isIndexing = true
    indexError = nil
    indexSuccess = nil
    do {
      try await mcpServer.indexRagRepo(path: path, forceReindex: force)
      await mcpServer.refreshRagSummary()
      aggregator.requestRebuild()
      if let report = mcpServer.lastRagIndexReport {
        let newChunks = report.chunksIndexed
        let totalFiles = report.filesIndexed + report.filesSkipped
        if newChunks == 0 {
          indexSuccess = "Already up to date (\(totalFiles) files checked)"
        } else {
          indexSuccess = "Indexed \(newChunks) new chunks from \(report.filesIndexed) files"
        }
      } else {
        indexSuccess = "Indexing complete"
      }
    } catch {
      indexError = error.localizedDescription
    }
    isIndexing = false
  }

  private func runSearch() async {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    isSearching = true
    searchError = nil
    do {
      searchResults = try await mcpServer.searchRag(
        query: trimmed,
        mode: searchMode,
        repoPath: repo.localPath,
        limit: 15
      )
    } catch {
      searchError = error.localizedDescription
    }
    isSearching = false
  }

  private func refreshAnalysisStatus() async {
    guard repo.localPath != nil else { return }
    let paths = allRepoPaths
    guard !paths.isEmpty else { return }
    do {
      var totalUnanalyzed = 0
      var totalAnalyzed = 0
      var totalEnriched = 0
      for path in paths {
        totalUnanalyzed += try await mcpServer.getUnanalyzedChunkCount(repoPath: path)
        totalAnalyzed += try await mcpServer.getAnalyzedChunkCount(repoPath: path)
        totalEnriched += try await mcpServer.getEnrichedChunkCount(repoPath: path)
      }
      if let state = analysisState {
        state.unanalyzedCount = totalUnanalyzed
        state.analyzedCount = totalAnalyzed
      }
      enrichedChunks = totalEnriched
    } catch {
      // Non-critical
    }
  }

  private func analyzeChunks() async {
    guard repo.localPath != nil else { return }
    let paths = allRepoPaths
    guard !paths.isEmpty else { return }
    isAnalyzing = true
    analyzeError = nil
    analyzeSuccess = nil
    let state = analysisState
    state?.isAnalyzing = true
    state?.analyzeError = nil
    state?.analysisStartTime = Date()
    let batchStart = Date()
    do {
      var grandTotal = 0
      var keepGoing = true
      while keepGoing {
        var batchCount = 0
        var remaining = 500
        for path in paths where remaining > 0 {
          let offset = grandTotal
          let count = try await mcpServer.analyzeRagChunks(
            repoPath: path,
            limit: remaining
          ) { current, total in
            Task { @MainActor in
              state?.batchProgress = (offset + current, offset + total)
            }
          }
          batchCount += count
          remaining -= count
        }
        grandTotal += batchCount
        if let state {
          state.analyzedCount += batchCount
          state.unanalyzedCount = max(0, state.unanalyzedCount - batchCount)
          let elapsed = Date().timeIntervalSince(batchStart)
          if elapsed > 0, grandTotal > 0 {
            state.chunksPerSecond = Double(grandTotal) / elapsed
          }
        }
        keepGoing = batchCount > 0
      }
      analyzedChunks = grandTotal
      if grandTotal == 0 {
        let totalAnalyzed = state?.analyzedCount ?? 0
        if totalAnalyzed > 0 {
          analyzeSuccess = "All \(totalAnalyzed) chunks already analyzed"
        } else {
          analyzeSuccess = "No chunks to analyze — index first"
        }
      } else {
        analyzeSuccess = "Analyzed \(grandTotal) chunks"
      }
    } catch {
      analyzeError = error.localizedDescription
      state?.analyzeError = error.localizedDescription
    }
    isAnalyzing = false
    state?.isAnalyzing = false
    state?.batchProgress = nil
    state?.analysisStartTime = nil
    await refreshAnalysisStatus()
  }

  private func enrichEmbeddings() async {
    guard repo.localPath != nil else { return }
    let paths = allRepoPaths
    guard !paths.isEmpty else { return }
    isEnriching = true
    enrichError = nil
    enrichResult = nil
    enrichBatchProgress = nil
    enrichOverallProgress = nil
    do {
      // Compute total unenriched across all sub-repos for overall progress
      var totalToEnrich = 0
      for path in paths {
        let analyzed = (try? await mcpServer.getAnalyzedChunkCount(repoPath: path)) ?? 0
        let enriched = (try? await mcpServer.getEnrichedChunkCount(repoPath: path)) ?? 0
        totalToEnrich += max(0, analyzed - enriched)
      }
      if totalToEnrich > 0 {
        enrichOverallProgress = (completed: 0, total: totalToEnrich)
      }
      var grandTotal = 0
      var keepGoing = true
      while keepGoing {
        var batchCount = 0
        var remaining = 500
        for path in paths where remaining > 0 {
          let count = try await mcpServer.enrichRagEmbeddings(
            repoPath: path,
            limit: remaining
          ) { current, total in
            Task { @MainActor in
              enrichBatchProgress = (current: current, total: total)
            }
          }
          batchCount += count
          remaining -= count
        }
        grandTotal += batchCount
        enrichOverallProgress = (completed: grandTotal, total: totalToEnrich)
        keepGoing = batchCount > 0
      }
      enrichedChunks = grandTotal
      if grandTotal == 0 {
        var totalAnalyzed = 0
        for path in paths {
          totalAnalyzed += (try? await mcpServer.getAnalyzedChunkCount(repoPath: path)) ?? 0
        }
        if totalAnalyzed > 0 {
          enrichResult = "All \(totalAnalyzed) analyzed chunks already enriched"
        } else {
          enrichResult = "No analyzed chunks found — run Analyze first"
        }
      } else {
        enrichResult = "Enriched \(grandTotal) chunks"
      }
      await refreshAnalysisStatus()
    } catch {
      enrichError = error.localizedDescription
    }
    isEnriching = false
    enrichBatchProgress = nil
    enrichOverallProgress = nil
  }

  private func loadLessons() async {
    guard let path = repo.localPath else { return }
    do {
      lessons = try await mcpServer.listLessons(
        repoPath: path,
        includeInactive: false,
        limit: nil
      )
    } catch {
      // Lessons are optional — silently fail
    }
  }
}

// MARK: - Repo Search Result Row

private struct RepoSearchResultRow: View {
  let result: LocalRAGSearchResult

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Score
      if let score = result.score {
        Text("\(Int(score * 100))")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.blue)
          .frame(width: 28)
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(displayPath)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)

          Spacer()

          Text("L\(result.startLine)–\(result.endLine)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        Text(result.snippet.components(separatedBy: "\n").first ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }

  private var displayPath: String {
    let path = result.filePath
    // Trim to show just the relative portion
    if let range = path.range(of: "/", options: .backwards) {
      return String(path[range.lowerBound...])
    }
    return path
  }
}

// MARK: - Skills Tab

