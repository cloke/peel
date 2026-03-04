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
  /// This allows a less powerful machine to benefit from a more powerful peer's Qwen 3 embeddings + analysis.
  private func requestOverlaySyncFromSwarm(repoPath: String) async {
    let coordinator = SwarmCoordinator.shared
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
}
