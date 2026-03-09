//
//  MCPServerService+SmallDelegates.swift
//  KitchenSync
//
//  Extracted from MCPServerService.swift for maintainability.
//  Contains small delegate conformances that don't warrant their own files.
//

import Foundation

// MARK: - MCPToolHandlerDelegate Conformance

extension MCPServerService: MCPToolHandlerDelegate {
  public func availableViewIds() -> [String] {
    uiAutomationProvider.availableViewIds()
  }

  public func availableToolControlIds() -> [String] {
    uiAutomationProvider.availableToolControlIds()
  }

  public func availableControlIds(for viewId: String?) -> [String] {
    uiAutomationProvider.availableControlIds(for: viewId)
  }

  public func controlValues(for viewId: String?) -> [String: Any] {
    uiAutomationProvider.controlValues(for: viewId)
  }

  public func currentToolId() -> String? {
    uiAutomationProvider.currentToolId()
  }

  public func setCurrentToolId(_ viewId: String) {
    uiAutomationProvider.setCurrentToolId(viewId)
  }

  public func worktreeNameMapFromDefaults() -> [String: String] {
    uiAutomationProvider.worktreeNameMapFromDefaults()
  }

  func handleRepositoryAutomationTap(controlId: String) async -> [String: Any] {
    persistRepositoryAutomationWorkerState()

    switch controlId {
    case "repositories.overview.sync.pullNow":
      return await handleRepositoryOverviewPullNowAutomationTap(controlId: controlId)
    case "repositories.rag.sync.push":
      return await handleRepositoryRAGAutomationTap(controlId: controlId, direction: .push)
    case "repositories.rag.sync.pull":
      return await handleRepositoryRAGAutomationTap(controlId: controlId, direction: .pull)
    case "repositories.rag.sync.pullWan":
      return await handleRepositoryRAGWANTap(controlId: controlId)
    default:
      return ["controlId": controlId, "status": "unsupported"]
    }
  }

  private func persistRepositoryAutomationWorkerState() {
    UserDefaults.standard.set(
      SwarmCoordinator.shared.connectedWorkers.map(\.displayName),
      forKey: "repositories.rag.sync.peers"
    )
    UserDefaults.standard.set(
      SwarmCoordinator.shared.onDemandWorkers.map(\.displayName),
      forKey: "repositories.rag.sync.wanWorkers"
    )
  }

  private func selectedRepositoryAutomationIdentifier() -> String? {
    let selected = UserDefaults.standard.string(forKey: "repositories.selectedRepoKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let selected, !selected.isEmpty else { return nil }
    return RepoRegistry.shared.normalizeRemoteURL(selected)
  }

  private func selectedRepositoryAutomationName() -> String {
    let name = UserDefaults.standard.string(forKey: "repositories.selectedRepoName")?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let name, !name.isEmpty {
      return name
    }
    return selectedRepositoryAutomationIdentifier() ?? "unknown-repo"
  }

  private func handleRepositoryOverviewPullNowAutomationTap(controlId: String) async -> [String: Any] {
    guard let repoIdentifier = selectedRepositoryAutomationIdentifier() else {
      UserDefaults.standard.set("no-repo", forKey: "repositories.overview.sync.status")
      UserDefaults.standard.set("", forKey: "repositories.overview.sync.source")
      return ["controlId": controlId, "status": "no-repo"]
    }

    let normalized = RepoRegistry.shared.normalizeRemoteURL(repoIdentifier)
    guard let availability = RAGSyncCoordinator.shared.availableUpdates.first(where: {
      RepoRegistry.shared.normalizeRemoteURL($0.source.repoIdentifier) == normalized
    }) else {
      UserDefaults.standard.set("no-source", forKey: "repositories.overview.sync.status")
      UserDefaults.standard.set("", forKey: "repositories.overview.sync.source")
      return ["controlId": controlId, "status": "no-source", "repoIdentifier": normalized]
    }

    UserDefaults.standard.set("pulling", forKey: "repositories.overview.sync.status")
    UserDefaults.standard.set(availability.source.workerName, forKey: "repositories.overview.sync.source")

    Task { @MainActor in
      do {
        try await RAGSyncCoordinator.shared.syncIndex(repoIdentifier: normalized)
        UserDefaults.standard.set("pulled", forKey: "repositories.overview.sync.status")
        await refreshRagSummary()
      } catch {
        logger.error("Overview automation pull failed for \(normalized): \(error.localizedDescription)")
        UserDefaults.standard.set("failed", forKey: "repositories.overview.sync.status")
      }
    }

    return [
      "controlId": controlId,
      "status": "pulling",
      "repoIdentifier": normalized,
      "source": availability.source.workerName
    ]
  }

  private func handleRepositoryRAGAutomationTap(
    controlId: String,
    direction: RAGArtifactSyncDirection
  ) async -> [String: Any] {
    guard let repoIdentifier = selectedRepositoryAutomationIdentifier() else {
      UserDefaults.standard.set("no-repo", forKey: "repositories.rag.sync.status")
      return ["controlId": controlId, "status": "no-repo"]
    }

    guard let peer = SwarmCoordinator.shared.connectedWorkers.first else {
      UserDefaults.standard.set("no-lan-peer", forKey: "repositories.rag.sync.status")
      persistRepositoryAutomationWorkerState()
      return ["controlId": controlId, "status": "no-lan-peer", "repoIdentifier": repoIdentifier]
    }

    let displayName = selectedRepositoryAutomationName()
    UserDefaults.standard.set("syncing", forKey: "repositories.rag.sync.status")
    persistRepositoryAutomationWorkerState()

    Task { @MainActor in
      do {
        let transferId = try await SwarmCoordinator.shared.requestRagArtifactSync(
          direction: direction,
          workerId: peer.id,
          repoIdentifier: repoIdentifier
        )

        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(0.5))
          guard let transfer = SwarmCoordinator.shared.ragTransfers.first(where: { $0.id == transferId }) else {
            continue
          }

          switch transfer.status {
          case .queued:
            UserDefaults.standard.set("queued", forKey: "repositories.rag.sync.status")
          case .preparing:
            UserDefaults.standard.set("preparing", forKey: "repositories.rag.sync.status")
          case .transferring:
            if transfer.totalBytes > 0 {
              let pct = Int(Double(transfer.transferredBytes) / Double(transfer.totalBytes) * 100)
              UserDefaults.standard.set("transferring-\(pct)%", forKey: "repositories.rag.sync.status")
            } else {
              UserDefaults.standard.set("transferring", forKey: "repositories.rag.sync.status")
            }
          case .applying:
            UserDefaults.standard.set("applying", forKey: "repositories.rag.sync.status")
          case .complete:
            if direction == .pull, let summary = transfer.resultSummary, !summary.isEmpty {
              UserDefaults.standard.set("pulled: \(summary)", forKey: "repositories.rag.sync.status")
            } else {
              UserDefaults.standard.set(direction == .push ? "pushed" : "pulled", forKey: "repositories.rag.sync.status")
            }
            if direction == .pull {
              await refreshRagSummary()
            }
            return
          case .failed:
            UserDefaults.standard.set(transfer.errorMessage ?? "failed", forKey: "repositories.rag.sync.status")
            return
          }
        }
      } catch {
        logger.error("RAG automation sync failed for \(displayName): \(error.localizedDescription)")
        UserDefaults.standard.set("failed: \(error.localizedDescription)", forKey: "repositories.rag.sync.status")
      }
    }

    return [
      "controlId": controlId,
      "status": "syncing",
      "repoIdentifier": repoIdentifier,
      "peer": peer.displayName,
      "direction": direction.rawValue
    ]
  }

  private func handleRepositoryRAGWANTap(controlId: String) async -> [String: Any] {
    guard let repoIdentifier = selectedRepositoryAutomationIdentifier() else {
      UserDefaults.standard.set("no-repo", forKey: "repositories.rag.sync.status")
      return ["controlId": controlId, "status": "no-repo"]
    }

    guard let worker = SwarmCoordinator.shared.onDemandWorkers.first else {
      UserDefaults.standard.set("no-wan-worker", forKey: "repositories.rag.sync.status")
      persistRepositoryAutomationWorkerState()
      return ["controlId": controlId, "status": "no-wan-worker", "repoIdentifier": repoIdentifier]
    }

    UserDefaults.standard.set("requesting-wan", forKey: "repositories.rag.sync.status")
    persistRepositoryAutomationWorkerState()

    Task { @MainActor in
      do {
        try await SwarmCoordinator.shared.requestRagSyncOnDemand(
          repoIdentifier: repoIdentifier,
          fromWorkerId: worker.id
        )
        UserDefaults.standard.set("pulled-wan", forKey: "repositories.rag.sync.status")
        await refreshRagSummary()
      } catch {
        logger.error("RAG WAN automation sync failed for \(repoIdentifier): \(error.localizedDescription)")
        UserDefaults.standard.set("failed: \(error.localizedDescription)", forKey: "repositories.rag.sync.status")
      }
    }

    return [
      "controlId": controlId,
      "status": "requesting-wan",
      "repoIdentifier": repoIdentifier,
      "worker": worker.displayName
    ]
  }
}

// MARK: - ParallelToolsHandlerDelegate

extension MCPServerService: ParallelToolsHandlerDelegate {
  // Note: parallelWorktreeRunner is already exposed with internal visibility.
  // Private properties need explicit accessors for protocol conformance.
  var parallelDataService: DataService? {
    dataService
  }

  var parallelTelemetryProvider: MCPTelemetryProviding {
    telemetryProvider
  }
}

// MARK: - RepoToolsHandlerDelegate

extension MCPServerService: RepoToolsHandlerDelegate {
  var repoDataService: DataService? {
    dataService
  }
}

// MARK: - CodeEditToolsHandlerDelegate

#if os(macOS)
extension MCPServerService: CodeEditToolsHandlerDelegate {}
#endif

// MARK: - RepoPullSchedulerDelegate

extension MCPServerService: RepoPullSchedulerDelegate {
  public func repoPullScheduler(_ scheduler: RepoPullScheduler, shouldReindex repoPath: String) {
    Task { @MainActor in
      logger.info("Auto-reindexing \(repoPath) after pull")
      do {
        let report = try await indexRepository(
          path: repoPath,
          forceReindex: false,
          allowWorkspace: false,
          excludeSubrepos: true,
          progressHandler: nil
        )
        await refreshRagSummary()
        logger.info("Auto-reindex complete for \(repoPath): \(report.filesIndexed) files, \(report.chunksIndexed) chunks")

        // After local reindex, request overlay sync from swarm if active.
        // This pulls pre-computed embeddings + AI analysis from a more powerful peer.
        await requestOverlaySyncFromSwarm(repoPath: repoPath)
      } catch {
        logger.error("Auto-reindex failed for \(repoPath): \(error.localizedDescription)")
      }
    }
  }

  /// After local reindex, pull overlay data (embeddings + analysis) from a connected swarm peer.
  /// This allows a less powerful machine (worker) to benefit from a more powerful peer's embeddings + analysis.
  /// Brain/hybrid roles skip this — they are the source of truth and should not pull from workers.
  private func requestOverlaySyncFromSwarm(repoPath: String) async {
    let coordinator = SwarmCoordinator.shared
    // Brain/hybrid machines ARE the source — don't pull overlays from workers.
    let role = coordinator.role
    guard role == .worker else { return }
    guard coordinator.isActive, !coordinator.connectedWorkers.isEmpty else { return }

    // Resolve the repo identifier from the local RAG store
    let repos = (try? await localRagStore.listRepos()) ?? []
    guard let repo = repos.first(where: { $0.rootPath == repoPath }),
          let repoIdentifier = repo.repoIdentifier, !repoIdentifier.isEmpty else {
      logger.debug("Skipping overlay sync for \(repoPath): no repo identifier found")
      return
    }

    do {
      let transferId = try await coordinator.requestRagArtifactSync(
        direction: .pull,
        repoIdentifier: repoIdentifier,
        transferMode: .overlay
      )
      logger.info("Post-reindex overlay sync requested for \(repoIdentifier): transfer \(transferId)")
    } catch {
      logger.warning("Post-reindex overlay sync failed for \(repoIdentifier): \(error.localizedDescription)")
    }
  }

  public func repoPullScheduler(_ scheduler: RepoPullScheduler, shouldSyncIndexFor repoPath: String) {
    Task { @MainActor in
      logger.info("Syncing RAG index from crown for \(repoPath) after pull")

      // Resolve repo identifier from local RAG store, then fall back to registry/tracked repo metadata.
      let standardizedRepoPath = (repoPath as NSString).standardizingPath
      let repos = (try? await localRagStore.listRepos()) ?? []
      let repoIdentifierFromStore = repos.first(where: {
        ($0.rootPath as NSString).standardizingPath == standardizedRepoPath
      })?.repoIdentifier

      let repoIdentifierFromRegistry = RepoRegistry.shared.getCachedRemoteURL(for: standardizedRepoPath)

      let repoIdentifierFromTrackedRepo: String? = {
        guard let dataService else { return nil }
        // Find tracked repo by matching device-local path
        for repo in dataService.getTrackedRemoteRepos() {
          if let state = dataService.getDeviceState(for: repo),
             (state.localPath as NSString).standardizingPath == standardizedRepoPath {
            return RepoRegistry.shared.normalizeRemoteURL(repo.remoteURL)
          }
        }
        return nil
      }()

      guard let repoIdentifier = repoIdentifierFromStore
        ?? repoIdentifierFromRegistry
        ?? repoIdentifierFromTrackedRepo,
        !repoIdentifier.isEmpty else {
        logger.warning("Cannot sync index for \(repoPath): no repo identifier found")
        return
      }

      let syncCoordinator = RAGSyncCoordinator.shared
      guard syncCoordinator.isActive else {
        logger.warning("Cannot sync index for \(repoIdentifier): RAG sync coordinator is not active")
        return
      }

      do {
        try await syncCoordinator.syncIndex(repoIdentifier: repoIdentifier)
        logger.info("RAG index sync from crown complete for \(repoIdentifier)")
      } catch {
        logger.error("RAG index sync from crown failed for \(repoIdentifier): \(error.localizedDescription)")
      }
    }
  }
}
