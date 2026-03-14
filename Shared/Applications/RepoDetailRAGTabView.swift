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

            if isCurrentlyIndexing || isAnalyzing || isEnriching {
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

          if isCurrentlyIndexing || isAnalyzing || isEnriching {
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

        // Compact stats line (live from mcpServer.ragRepos)
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

        // Active progress
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
              Text("Chunk \(batch.current) of \(batch.total)")
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

        if isEnriching, let batch = enrichBatchProgress {
          VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: Double(batch.current), total: Double(batch.total))
              .tint(.orange)
            Text("Enriching \(batch.current) of \(batch.total)")
              .font(.caption2)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }

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
      // Sync progress / status
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

      // Peer action buttons
      if let repoId = ragRepoIdentifier {
        let allPeers = peers
        let allWAN = onDemandWorkers
        let totalCount = allPeers.count + allWAN.count

        if totalCount == 0 {
          HStack(spacing: 6) {
            Label("Swarm", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("\u{00B7} No peers available")
              .font(.caption)
              .foregroundStyle(.tertiary)
            Spacer()
          }
        } else if totalCount == 1, let peer = allPeers.first {
          HStack(spacing: 8) {
            Label("Swarm", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              Task { await syncWithPeers(repoIdentifier: repoId, direction: .push, workerId: peer.id) }
            } label: {
              syncButtonLabel("Push", icon: "arrow.up.circle", active: isSyncing && syncDirection == .push)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(isSyncing)

            Button {
              Task { await syncWithPeers(repoIdentifier: repoId, direction: .pull, workerId: peer.id) }
            } label: {
              syncButtonLabel("Pull", icon: "arrow.down.circle", active: isSyncing && syncDirection == .pull)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(isSyncing)
          }
        } else if totalCount == 1, let worker = allWAN.first {
          let staleLabel = worker.isStale ? " (offline)" : ""
          HStack(spacing: 8) {
            Label("Swarm", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              Task { await syncOnDemand(repoIdentifier: repoId, fromWorkerId: worker.id) }
            } label: {
              syncButtonLabel("Pull\(staleLabel)", icon: "arrow.down.circle", active: isSyncing && syncDirection == .pull)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(isSyncing)

            Button {
              Task { await connectWANPeer(worker) }
            } label: {
              syncButtonLabel("Connect", icon: "point.3.connected.trianglepath.dotted", active: isConnectingWAN)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(isSyncing || isConnectingWAN)
          }
        } else {
          HStack(spacing: 8) {
            Label("Swarm", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            unifiedPushMenu(peers: allPeers, workers: allWAN, repoIdentifier: repoId)
            unifiedPullMenu(peers: allPeers, workers: allWAN, repoIdentifier: repoId)
            if !allWAN.isEmpty {
              unifiedConnectMenu(workers: allWAN)
            }
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
  private func syncButtonLabel(_ title: String, icon: String, active: Bool) -> some View {
    if active {
      HStack(spacing: 4) {
        ProgressView()
          .controlSize(.mini)
        Text("\(title)…")
      }
    } else {
      Label(title, systemImage: icon)
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

  // MARK: - Unified Peer Menus

  private func unifiedPushMenu(peers: [ConnectedPeer], workers: [FirestoreWorker], repoIdentifier: String) -> some View {
    let isActive = isSyncing && syncDirection == .push
    return Menu {
      if !peers.isEmpty {
        Section("LAN") {
          ForEach(peers) { peer in
            Button {
              Task { await syncWithPeers(repoIdentifier: repoIdentifier, direction: .push, workerId: peer.id) }
            } label: {
              Label(peerMenuDisplayName(peer), systemImage: "desktopcomputer")
            }
          }
        }
      }
      if !workers.isEmpty {
        Section("WAN (connect first)") {
          ForEach(workers, id: \.id) { worker in
            Button {
              Task { await connectWANPeer(worker) }
            } label: {
              Label("\(workerMenuDisplayName(worker)) — Connect", systemImage: "point.3.connected.trianglepath.dotted")
            }
          }
        }
      }
    } label: {
      syncButtonLabel("Push to…", icon: "arrow.up.circle", active: isActive)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isSyncing || peers.isEmpty)
  }

  private func unifiedPullMenu(peers: [ConnectedPeer], workers: [FirestoreWorker], repoIdentifier: String) -> some View {
    let isActive = isSyncing && syncDirection == .pull
    return Menu {
      if !peers.isEmpty {
        Section("LAN") {
          ForEach(peers) { peer in
            Button {
              Task { await syncWithPeers(repoIdentifier: repoIdentifier, direction: .pull, workerId: peer.id) }
            } label: {
              Label(peerMenuDisplayName(peer), systemImage: "desktopcomputer")
            }
          }
        }
      }
      if !workers.isEmpty {
        Section("WAN") {
          ForEach(workers, id: \.id) { worker in
            Button {
              Task { await syncOnDemand(repoIdentifier: repoIdentifier, fromWorkerId: worker.id) }
            } label: {
              Label(workerMenuDisplayName(worker), systemImage: "globe")
            }
          }
        }
      }
    } label: {
      syncButtonLabel("Pull from…", icon: "arrow.down.circle", active: isActive)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isSyncing)
  }

  private func unifiedConnectMenu(workers: [FirestoreWorker]) -> some View {
    return Menu {
      ForEach(workers, id: \.id) { worker in
        Button {
          Task { await connectWANPeer(worker) }
        } label: {
          Label(workerMenuDisplayName(worker), systemImage: "desktopcomputer")
        }
      }
    } label: {
      syncButtonLabel("Connect…", icon: "point.3.connected.trianglepath.dotted", active: isConnectingWAN)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isSyncing || isConnectingWAN)
  }

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

  private func defaultPeerLabel(for peers: [ConnectedPeer], direction: RAGArtifactSyncDirection) -> String {
    guard let peer = SwarmPeerPreferences.defaultPeer(from: peers) else {
      return direction == .push ? "Push" : "Pull"
    }
    return direction == .push ? "Push to \(peer.displayName)" : "Pull from \(peer.displayName)"
  }

  private func defaultWorkerLabel(for workers: [FirestoreWorker]) -> String {
    guard let worker = SwarmPeerPreferences.defaultWorker(from: workers) else {
      return "Pull (WAN)"
    }
    return "Pull from \(worker.displayName) (WAN)"
  }

  private func peerMenuDisplayName(_ peer: ConnectedPeer) -> String {
    let preferredSuffix = SwarmPeerPreferences.isPreferred(peer) ? " (Preferred)" : ""
    return "\(peer.displayName) · \(peer.capabilities.memoryGB)GB\(preferredSuffix)"
  }

  private func workerMenuDisplayName(_ worker: FirestoreWorker) -> String {
    let preferredSuffix = SwarmPeerPreferences.isPreferred(worker) ? " (Preferred)" : ""
    let staleSuffix = worker.isStale ? " · offline" : ""
    return "\(worker.displayName)\(preferredSuffix)\(staleSuffix)"
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
      var totalCount = 0
      var remaining = 500
      for path in paths where remaining > 0 {
        let count = try await mcpServer.analyzeRagChunks(
          repoPath: path,
          limit: remaining
        ) { current, total in
          Task { @MainActor in
            state?.batchProgress = (current, total)
          }
        }
        totalCount += count
        remaining -= count
      }
      analyzedChunks = totalCount
      if totalCount == 0 {
        let totalAnalyzed = state?.analyzedCount ?? 0
        if totalAnalyzed > 0 {
          analyzeSuccess = "All \(totalAnalyzed) chunks already analyzed"
        } else {
          analyzeSuccess = "No chunks to analyze — index first"
        }
      } else {
        analyzeSuccess = "Analyzed \(totalCount) chunks"
      }
      if let state {
        state.analyzedCount += totalCount
        state.unanalyzedCount = max(0, state.unanalyzedCount - totalCount)
        let elapsed = Date().timeIntervalSince(batchStart)
        if elapsed > 0, totalCount > 0 {
          state.chunksPerSecond = Double(totalCount) / elapsed
        }
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
    do {
      var totalCount = 0
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
        totalCount += count
        remaining -= count
      }
      enrichedChunks = totalCount
      if totalCount == 0 {
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
        enrichResult = "Enriched \(totalCount) chunks"
      }
      await refreshAnalysisStatus()
    } catch {
      enrichError = error.localizedDescription
    }
    isEnriching = false
    enrichBatchProgress = nil
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

