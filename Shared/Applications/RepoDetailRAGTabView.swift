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

  @State private var isIndexing = false
  @State private var indexError: String?
  @State private var indexSuccess: String?
  @State private var searchQuery = ""
  @State private var searchMode: MCPServerService.RAGSearchMode = .vector
  @State private var searchResults: [LocalRAGSearchResult] = []
  @State private var isSearching = false
  @State private var searchError: String?
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
  @State private var swarm = SwarmCoordinator.shared
  @State private var isSyncing = false
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
    mcpServer.ragIndexingPath == repo.localPath
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
        // Prominent search bar (when indexed)
        if repo.ragStatus != nil && repo.ragStatus != .notIndexed, repo.localPath != nil {
          searchCard
        }

        // RAG status hero card
        ragStatusCard

        // Pipeline steps
        if repo.ragStatus != nil && repo.ragStatus != .notIndexed, repo.localPath != nil {
          pipelineCard
        }

        // Swarm sync
        if swarm.isActive {
          swarmSyncSection
        }

        // Lessons
        if !lessons.isEmpty {
          lessonsSection
        }
      }
      .padding(16)
    }
    .task {
      await loadLessons()
      await refreshAnalysisStatus()
      persistRAGSyncAutomationState()
      handlePendingRAGUIActionIfNeeded()
    }
    .task {
      await pollExternalTransfers()
    }
    .onAppear {
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

  // MARK: - Search Card

  private var searchCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Search bar
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)

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
          #if os(macOS)
          .fill(Color(nsColor: .controlBackgroundColor))
          #else
          .fill(Color(.systemGroupedBackground))
          #endif
      )

      if let error = searchError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      // Results
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
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #else
        .background(Color(.systemGroupedBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  // MARK: - RAG Status Card

  private var ragStatusCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          // Status icon
          ZStack {
            Circle()
              .fill(ragStatusColor.opacity(0.15))
              .frame(width: 40, height: 40)

            if isCurrentlyIndexing {
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

          // Action buttons
          if isCurrentlyIndexing {
            // No action while indexing
          } else if repo.ragStatus == nil || repo.ragStatus == .notIndexed {
            Button("Index Now") {
              Task { await indexRepo(force: false) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(repo.localPath == nil)
          } else {
            HStack(spacing: 6) {
              Button("Re-Index") {
                Task { await indexRepo(force: false) }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)

              Button {
                Task { await indexRepo(force: true) }
              } label: {
                Image(systemName: "arrow.clockwise")
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .help("Force full re-index")
            }
          }
        }

        // Stats row
        if repo.ragFileCount != nil || repo.ragChunkCount != nil || repo.ragLastIndexedAt != nil {
          Divider()

          HStack(spacing: 16) {
            if let fileCount = repo.ragFileCount {
              VStack(spacing: 2) {
                Text("\(fileCount)")
                  .font(.headline)
                Text("Files")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }

            if let chunkCount = repo.ragChunkCount {
              VStack(spacing: 2) {
                Text("\(chunkCount)")
                  .font(.headline)
                Text("Chunks")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }

            if let lastIndexed = repo.ragLastIndexedAt {
              VStack(spacing: 2) {
                Text(lastIndexed, style: .relative)
                  .font(.callout)
                Text("Last Indexed")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

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
      }
      .padding(4)
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

  /// Live embedding model from mcpServer.ragRepos (refreshed after sync).
  /// Searches all matching repos (parent + sub-packages) and prefers the one
  /// with actual data (most chunks) since the parent entry may be stale.
  private var liveEmbeddingModel: String? {
    let identifier = repo.normalizedRemoteURL
    let matching = mcpServer.ragRepos.filter {
      $0.repoIdentifier == identifier || $0.rootPath == repo.localPath
    }
    // Prefer the repo with a non-nil model AND the most chunks
    let withModel = matching.filter { $0.embeddingModel != nil }
    if let best = withModel.max(by: { $0.chunkCount < $1.chunkCount }) {
      return best.embeddingModel
    }
    return matching.first?.embeddingModel
  }

  // MARK: - Pipeline Card

  private var pipelineCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader("AI Pipeline")

      // Visual pipeline steps
      HStack(spacing: 0) {
        PipelineStep(
          title: "Index",
          icon: "tray.full.fill",
          isComplete: repo.ragStatus != nil && repo.ragStatus != .notIndexed,
          isActive: isCurrentlyIndexing
        )

        PipelineArrow()

        PipelineStep(
          title: "Analyze",
          icon: "cpu",
          isComplete: (analysisState?.analyzedCount ?? 0) > 0 && !(analysisState?.isAnalyzing ?? false) && !isAnalyzing,
          isActive: isAnalyzing || (analysisState?.isAnalyzing ?? false)
        )

        PipelineArrow()

        PipelineStep(
          title: "Enrich",
          icon: "sparkles",
          isComplete: enrichedChunks > 0,
          isActive: isEnriching
        )
      }

      // Progress bar (when actively analyzing)
      if let state = analysisState, state.totalChunks > 0, (state.isAnalyzing || isAnalyzing) {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: state.progress)
            .tint(.purple)

          HStack(spacing: 8) {
            Text(verbatim: "\(state.analyzedCount) / \(state.totalChunks) chunks")
              .font(.caption2)
              .foregroundStyle(.secondary)

            if (state.isAnalyzing || isAnalyzing), state.chunksPerSecond > 0 {
              Text("·")
                .foregroundStyle(.tertiary)
              Text("\(String(format: "%.1f", state.chunksPerSecond)) chunks/sec")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(verbatim: "\(Int(state.progress * 100))%")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      // Info about chunks that couldn't be analyzed
      if let state = analysisState, !state.isComplete, !(state.isAnalyzing || isAnalyzing), state.analyzedCount > 0 {
        Text(verbatim: "\(state.analyzedCount) of \(state.totalChunks) chunks analyzed (\(state.unanalyzedCount) could not be processed)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      // Action buttons
      HStack(spacing: 8) {
        #if os(macOS)
        Button {
          Task { await analyzeChunks() }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "cpu")
            Text(isAnalyzing ? "Analyzing…" : "Analyze")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isAnalyzing || repo.localPath == nil)

        Button {
          Task { await enrichEmbeddings() }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "sparkles")
            Text(isEnriching ? "Enriching…" : "Enrich")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isEnriching || repo.localPath == nil)
        #else
        Text("AI Analysis requires macOS")
          .font(.caption)
          .foregroundStyle(.secondary)
        #endif

        Spacer()

        if analyzedChunks > 0 {
          Text("\(analyzedChunks) analyzed")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        if enrichedChunks > 0 {
          Text("\(enrichedChunks) enriched")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }

      // Batch progress bar (when actively analyzing)
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

      // Batch progress bar (when actively enriching)
      if isEnriching, let batch = enrichBatchProgress {
        VStack(alignment: .leading, spacing: 2) {
          ProgressView(value: Double(batch.current), total: Double(batch.total))
            .tint(.orange)
          HStack {
            Text("Enriching \(batch.current) of \(batch.total)")
              .font(.caption2)
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Spacer()
          }
        }
      }

      // Errors & success
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
      #if os(macOS)
      .background(Color(nsColor: .controlBackgroundColor))
      #else
      .background(Color(.systemGroupedBackground))
      #endif
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

  private var swarmSyncSection: some View {
    let peers = SwarmPeerPreferences.ordered(peers: swarm.connectedWorkers)
    let onDemandWorkers = SwarmPeerPreferences.ordered(workers: swarm.onDemandWorkers)

    return VStack(alignment: .leading, spacing: 8) {
      SectionHeader("Swarm Sync")

      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          // Status / progress area
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

          // Action buttons
          if let repoId = ragRepoIdentifier {
            HStack(spacing: 8) {
              if !peers.isEmpty {
                if peers.count > 1 {
                  syncPeerMenu(peers: peers, repoIdentifier: repoId, direction: .push)
                  syncPeerMenu(peers: peers, repoIdentifier: repoId, direction: .pull)
                } else if let peer = peers.first {
                  Button {
                    Task { await syncWithPeers(repoIdentifier: repoId, direction: .push, workerId: peer.id) }
                  } label: {
                    syncButtonLabel("Push to \(peer.displayName)", icon: "arrow.up.circle", active: isSyncing && syncDirection == .push)
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .disabled(isSyncing)

                  Button {
                    Task { await syncWithPeers(repoIdentifier: repoId, direction: .pull, workerId: peer.id) }
                  } label: {
                    syncButtonLabel("Pull from \(peer.displayName)", icon: "arrow.down.circle", active: isSyncing && syncDirection == .pull)
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .disabled(isSyncing)
                }
              } else if !onDemandWorkers.isEmpty {
                if onDemandWorkers.count > 1 {
                  onDemandMenu(workers: onDemandWorkers, repoIdentifier: repoId)
                } else if let worker = onDemandWorkers.first {
                  Button {
                    Task { await syncOnDemand(repoIdentifier: repoId, fromWorkerId: worker.id) }
                  } label: {
                    syncButtonLabel("Pull from \(worker.displayName) (WAN)", icon: "arrow.down.circle", active: isSyncing && syncDirection == .pull)
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .disabled(isSyncing)
                }
              } else {
                HStack(spacing: 6) {
                  Image(systemName: "network.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                  Text("No peers or WAN workers available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }

              Spacer()
            }
          } else {
            HStack(spacing: 6) {
              Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
              Text("Index this repo first to enable swarm sync")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(4)
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

  private func syncPeerMenu(peers: [ConnectedPeer], repoIdentifier: String, direction: RAGArtifactSyncDirection) -> some View {
    let isPush = direction == .push
    let label = defaultPeerLabel(for: peers, direction: direction)
    let icon = isPush ? "arrow.up.circle" : "arrow.down.circle"
    let isActive = isSyncing && syncDirection == direction

    return Menu {
      ForEach(peers) { peer in
        Button {
          Task { await syncWithPeers(repoIdentifier: repoIdentifier, direction: direction, workerId: peer.id) }
        } label: {
          Label(peerMenuDisplayName(peer), systemImage: "desktopcomputer")
        }
      }
    } label: {
      syncButtonLabel(label, icon: icon, active: isActive)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isSyncing)
  }

  private func onDemandMenu(workers: [FirestoreWorker], repoIdentifier: String) -> some View {
    let isActive = isSyncing && syncDirection == .pull

    return Menu {
      ForEach(workers, id: \.id) { worker in
        Button {
          Task { await syncOnDemand(repoIdentifier: repoIdentifier, fromWorkerId: worker.id) }
        } label: {
          Label(workerMenuDisplayName(worker), systemImage: "desktopcomputer")
        }
      }
    } label: {
      syncButtonLabel(defaultWorkerLabel(for: workers), icon: "arrow.down.circle", active: isActive)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isSyncing)
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
    return "\(worker.displayName)\(preferredSuffix)"
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
      try await SwarmCoordinator.shared.requestRagSyncOnDemand(
        repoIdentifier: repoIdentifier,
        fromWorkerId: fromWorkerId
      )
    }

    let coordinator = RAGSyncCoordinator.shared
    while !syncFinished && !Task.isCancelled {
      if let transfer = coordinator.activeTransfers.values.first(where: {
        $0.repoIdentifier == repoIdentifier && $0.targetWorkerId == fromWorkerId
      }) {
        let method = transfer.connectionMethod?.rawValue ?? "connecting"
        switch transfer.status {
        case .connecting:
          onDemandProgress = "Connecting (\(method))…"
        case .handshaking:
          onDemandProgress = "Handshaking via \(method)…"
        case .transferring:
          let elapsed = Int(transfer.elapsedSeconds)
          if transfer.totalBytes > 0 && transfer.transferredBytes > 0 {
            let pct = Int(transfer.progressFraction * 100)
            onDemandProgress = "Downloading via \(method): \(pct)% [\(elapsed)s]"
          } else if transfer.totalChunks > 0 {
            onDemandProgress = "Uploading via \(method): \(transfer.chunksReceived)/\(transfer.totalChunks) chunks [\(elapsed)s]"
          } else {
            onDemandProgress = "Waiting for remote export via \(method)… [\(elapsed)s]"
          }
        case .importing:
          let byteStr = formatBytes(transfer.transferredBytes)
          onDemandProgress = "Importing \(byteStr)…"
        case .complete:
          syncFinished = true
        case .failed:
          syncFinished = true
        }
        persistRAGSyncAutomationState()
      }

      try? await Task.sleep(for: .seconds(0.3))
    }

    // Read final state
    if let transfer = coordinator.activeTransfers.values.first(where: {
      $0.repoIdentifier == repoIdentifier && $0.targetWorkerId == fromWorkerId
    }) {
      switch transfer.status {
      case .complete:
        let byteStr = formatBytes(transfer.transferredBytes)
        syncResultMessage = "Pulled from \(workerName): \(byteStr)"
        repoDetailAutomationLogger.info("RAG on-demand sync completed repo=\(self.repo.displayName, privacy: .public) worker=\(workerName, privacy: .public) bytes=\(byteStr, privacy: .public)")
        await mcpServer.refreshRagSummary()
        await refreshAnalysisStatus()
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(8))
          if syncResultMessage != nil { syncResultMessage = nil }
        }
      case .failed:
        syncError = transfer.error ?? "On-demand sync failed"
        repoDetailAutomationLogger.error("RAG on-demand sync failed repo=\(self.repo.displayName, privacy: .public) worker=\(workerName, privacy: .public) error=\(self.syncError ?? "unknown", privacy: .public)")
      default:
        break
      }
    } else {
      // If we can't find the transfer, check the task result
      do {
        try await syncTask.value
        syncResultMessage = "Pulled from \(workerName)"
        repoDetailAutomationLogger.info("RAG on-demand sync finished without retained transfer state repo=\(self.repo.displayName, privacy: .public) worker=\(workerName, privacy: .public)")
        await mcpServer.refreshRagSummary()
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
    let wanWorkers = swarm.onDemandWorkers.map(\ .displayName)
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
            let worker = SwarmPeerPreferences.defaultWorker(from: swarm.onDemandWorkers) else {
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

    default:
      break
    }
  }

  private func pollExternalTransfers() async {
    let coordinator = RAGSyncCoordinator.shared
    while !Task.isCancelled {
      if !isSyncing,
         let repoId = ragRepoIdentifier,
         let transfer = coordinator.activeTransfers.values.first(where: {
           $0.repoIdentifier == repoId && $0.status != .complete && $0.status != .failed
         }) {
        let method = transfer.connectionMethod?.rawValue ?? "connecting"
        let worker = transfer.targetWorkerName
        switch transfer.status {
        case .connecting:
          externalOnDemandProgress = "MCP pull from \(worker): Connecting (\(method))…"
        case .handshaking:
          externalOnDemandProgress = "MCP pull from \(worker): Handshaking via \(method)…"
        case .transferring:
          let elapsed = Int(transfer.elapsedSeconds)
          if transfer.totalBytes > 0 && transfer.transferredBytes > 0 {
            let pct = Int(transfer.progressFraction * 100)
            externalOnDemandProgress = "MCP pull from \(worker): \(pct)% via \(method) [\(elapsed)s]"
          } else if transfer.totalChunks > 0 {
            externalOnDemandProgress = "MCP pull from \(worker): \(transfer.chunksReceived)/\(transfer.totalChunks) chunks via \(method) [\(elapsed)s]"
          } else {
            externalOnDemandProgress = "MCP pull from \(worker): Waiting for export via \(method)… [\(elapsed)s]"
          }
        case .importing:
          externalOnDemandProgress = "MCP pull from \(worker): Importing \(formatBytes(transfer.transferredBytes))…"
        case .complete, .failed:
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
    guard let path = repo.localPath else { return }
    do {
      let unanalyzed = try await mcpServer.getUnanalyzedChunkCount(repoPath: path)
      let analyzed = try await mcpServer.getAnalyzedChunkCount(repoPath: path)
      let enriched = try await mcpServer.getEnrichedChunkCount(repoPath: path)
      if let state = analysisState {
        state.unanalyzedCount = unanalyzed
        state.analyzedCount = analyzed
      }
      enrichedChunks = enriched
    } catch {
      // Non-critical
    }
  }

  private func analyzeChunks() async {
    guard let path = repo.localPath else { return }
    isAnalyzing = true
    analyzeError = nil
    analyzeSuccess = nil
    let state = analysisState
    state?.isAnalyzing = true
    state?.analyzeError = nil
    state?.analysisStartTime = Date()
    let batchStart = Date()
    do {
      let count = try await mcpServer.analyzeRagChunks(
        repoPath: path,
        limit: 500
      ) { current, total in
        Task { @MainActor in
          state?.batchProgress = (current, total)
        }
      }
      analyzedChunks = count
      if count == 0 {
        let totalAnalyzed = state?.analyzedCount ?? 0
        if totalAnalyzed > 0 {
          analyzeSuccess = "All \(totalAnalyzed) chunks already analyzed"
        } else {
          analyzeSuccess = "No chunks to analyze — index first"
        }
      } else {
        analyzeSuccess = "Analyzed \(count) chunks"
      }
      if let state {
        state.analyzedCount += count
        state.unanalyzedCount = max(0, state.unanalyzedCount - count)
        let elapsed = Date().timeIntervalSince(batchStart)
        if elapsed > 0, count > 0 {
          state.chunksPerSecond = Double(count) / elapsed
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
    guard let path = repo.localPath else { return }
    isEnriching = true
    enrichError = nil
    enrichResult = nil
    enrichBatchProgress = nil
    do {
      let count = try await mcpServer.enrichRagEmbeddings(
        repoPath: path,
        limit: 500
      ) { current, total in
        Task { @MainActor in
          enrichBatchProgress = (current: current, total: total)
        }
      }
      enrichedChunks = count
      if count == 0 {
        let analyzedCount = (try? await mcpServer.getAnalyzedChunkCount(repoPath: path)) ?? 0
        if analyzedCount > 0 {
          enrichResult = "All \(analyzedCount) analyzed chunks already enriched"
        } else {
          enrichResult = "No analyzed chunks found — run Analyze first"
        }
      } else {
        enrichResult = "Enriched \(count) chunks"
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

// MARK: - Pipeline Step

private struct PipelineStep: View {
  let title: String
  let icon: String
  let isComplete: Bool
  let isActive: Bool

  var body: some View {
    VStack(spacing: 6) {
      ZStack {
        Circle()
          .fill(stepColor.opacity(0.15))
          .frame(width: 36, height: 36)

        if isActive {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: isComplete ? "checkmark" : icon)
            .font(.callout)
            .foregroundStyle(stepColor)
        }
      }

      Text(title)
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundStyle(isComplete || isActive ? .primary : .secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var stepColor: Color {
    if isActive { return .blue }
    if isComplete { return .green }
    return .secondary
  }
}

private struct PipelineArrow: View {
  var body: some View {
    Image(systemName: "chevron.right")
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .frame(width: 20)
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

