//
//  RAGSyncCoordinator.swift
//  Peel
//
//  Orchestrates on-demand P2P RAG index sharing:
//  1. Subscribes to Firestore for remote index version updates
//  2. When a newer version is available, requests a pull via
//     SwarmCoordinator's persistent WebRTC/TCP sessions
//  3. Imports the received bundle via RAGArtifactSyncDelegate
//  4. Publishes local index versions after indexing
//

import Foundation
import os.log

// MARK: - Sync Mode

public enum RAGSyncMode: String, Sendable, CaseIterable {
  /// Manually triggered only (via MCP or UI)
  case manual
  /// Automatically sync when a newer version is detected
  case automatic
}

// MARK: - Coordinator

@MainActor
@Observable
public final class RAGSyncCoordinator {
  static let shared = RAGSyncCoordinator()

  private let logger = Logger(subsystem: "com.peel.rag", category: "SyncCoordinator")

  // MARK: - Dependencies

  private let versionService = RAGIndexVersionService.shared

  /// The delegate that provides import/export of RAG bundles.
  /// Set by MCPServerService when it initializes (it conforms to RAGArtifactSyncDelegate).
  weak var ragSyncDelegate: RAGArtifactSyncDelegate?

  // MARK: - State

  /// Current sync mode
  public var syncMode: RAGSyncMode = .manual {
    didSet {
      logger.info("Sync mode changed to \(self.syncMode.rawValue)")
      if syncMode == .automatic {
        processAvailableUpdates()
      }
    }
  }

  /// Whether the coordinator is active (listening for versions)
  public private(set) var isActive = false

  /// History of completed syncs
  public private(set) var syncHistory: [SyncHistoryEntry] = []

  /// Active transfer states (from SwarmCoordinator)
  public var activeTransfers: [RAGArtifactTransferState] {
    SwarmCoordinator.shared.ragTransfers.filter {
      $0.status != .complete && $0.status != .failed
    }
  }

  /// Available updates from remote peers
  public var availableUpdates: [RAGIndexAvailability] {
    versionService.availableUpdates
  }

  /// Remote versions being tracked
  public var remoteVersions: [String: [String: RAGIndexVersion]] {
    versionService.remoteVersions
  }

  // MARK: - Init

  private init() {
    // Wire up the version service callback
    versionService.onIndexAvailable = { [weak self] availability in
      Task { @MainActor [weak self] in
        self?.handleIndexAvailable(availability)
      }
    }
  }

  // MARK: - Lifecycle

  /// Start listening for remote index versions.
  /// Call from SwarmCoordinator.start() or app launch.
  func start() {
    guard !isActive else { return }
    isActive = true
    versionService.startListening()
    logger.info("RAG sync coordinator started (mode: \(self.syncMode.rawValue))")
  }

  /// Stop listening and cancel any active transfers.
  func stop() {
    isActive = false
    versionService.stopListening()
    logger.info("RAG sync coordinator stopped")
  }

  // MARK: - Publishing

  /// Publish a local index version after rag.index completes.
  /// Called from RAGToolsHandler+Indexing after a successful index.
  func publishVersion(
    repoIdentifier: String,
    repoName: String,
    headSHA: String?,
    fileCount: Int,
    chunkCount: Int,
    embeddingModel: String,
    embeddingDimensions: Int,
    sizeEstimateBytes: Int
  ) async {
    await versionService.publishIndexVersion(
      repoIdentifier: repoIdentifier,
      repoName: repoName,
      headSHA: headSHA,
      fileCount: fileCount,
      chunkCount: chunkCount,
      embeddingModel: embeddingModel,
      embeddingDimensions: embeddingDimensions,
      sizeEstimateBytes: sizeEstimateBytes
    )
  }

  // MARK: - Syncing

  /// Manually trigger a sync for a specific repo from a specific worker.
  func syncIndex(
    repoIdentifier: String,
    fromWorkerId: String,
    swarmId: String
  ) async throws {
    guard !swarmId.isEmpty else {
      throw RAGSyncError.invalidSwarmId
    }

    // Normalize early so the identifier matches across machines
    let normalizedIdentifier = RepoRegistry.shared.normalizeRemoteURL(repoIdentifier)

    versionService.markSyncStarted(repoIdentifier: normalizedIdentifier)
    let workerName = FirebaseService.shared.swarmWorkers
      .first(where: { $0.id == fromWorkerId })?.displayName ?? fromWorkerId
    logger.info("Starting sync of \(normalizedIdentifier) from \(workerName)")

    let startTime = Date()
    do {
      let transferId = try await SwarmCoordinator.shared.requestRagArtifactSync(
        direction: .pull,
        workerId: fromWorkerId,
        repoIdentifier: normalizedIdentifier
      )

      let state = try await SwarmCoordinator.shared.waitForTransferCompletion(transferId)

      syncHistory.append(SyncHistoryEntry(
        repoIdentifier: normalizedIdentifier,
        fromWorkerName: workerName,
        connectionMethod: "persistent-session",
        bytesTransferred: state.transferredBytes,
        duration: Date().timeIntervalSince(startTime),
        success: true
      ))

      logger.info("Sync complete: \(normalizedIdentifier) from \(workerName)")
    } catch {
      syncHistory.append(SyncHistoryEntry(
        repoIdentifier: normalizedIdentifier,
        fromWorkerName: workerName,
        connectionMethod: "failed",
        bytesTransferred: 0,
        duration: Date().timeIntervalSince(startTime),
        success: false,
        errorMessage: error.localizedDescription
      ))
      throw error
    }

    versionService.markSyncCompleted(repoIdentifier: normalizedIdentifier)
  }

  /// Sync from the best available source for a repo.
  func syncIndex(repoIdentifier: String) async throws {
    let canonicalRepoIdentifier = RepoRegistry.shared.normalizeRemoteURL(repoIdentifier)
    // Find the best source: prefer the one with the highest version
    guard let availability = versionService.availableUpdates.first(
      where: { RepoRegistry.shared.normalizeRemoteURL($0.source.repoIdentifier) == canonicalRepoIdentifier })
    else {
      throw RAGSyncError.noSourceAvailable(repoIdentifier: repoIdentifier)
    }

    try await syncIndex(
      repoIdentifier: canonicalRepoIdentifier,
      fromWorkerId: availability.source.workerId,
      swarmId: availability.swarmId
    )
  }

  /// Dismiss an available update without syncing.
  func dismissUpdate(repoIdentifier: String) {
    versionService.dismissUpdate(repoIdentifier: repoIdentifier)
  }

  // MARK: - Auto-Sync

  private func handleIndexAvailable(_ availability: RAGIndexAvailability) {
    logger.info("Index available: \(availability.source.repoName) v\(availability.source.version) from \(availability.source.workerName)")

    if syncMode == .automatic {
      Task {
        do {
          try await syncIndex(
            repoIdentifier: availability.source.repoIdentifier,
            fromWorkerId: availability.source.workerId,
            swarmId: availability.swarmId
          )
        } catch {
          logger.error("Auto-sync failed for \(availability.source.repoName): \(error.localizedDescription)")
        }
      }
    }
  }

  /// Process any pending available updates (called when switching to auto mode).
  private func processAvailableUpdates() {
    for availability in versionService.availableUpdates {
      handleIndexAvailable(availability)
    }
  }

  // MARK: - Queries

  /// List all repos that have remote versions available.
  func listRemoteRepos() -> [RemoteRepoInfo] {
    var repos: [RemoteRepoInfo] = []
    for (repoId, workers) in versionService.remoteVersions {
      guard let bestVersion = workers.values.max(by: { $0.version < $1.version }) else { continue }
      let isUpdateAvailable = versionService.availableUpdates.contains {
        $0.source.repoIdentifier == repoId
      }
      repos.append(RemoteRepoInfo(
        repoIdentifier: repoId,
        repoName: bestVersion.repoName,
        bestVersion: bestVersion,
        sourceCount: workers.count,
        isUpdateAvailable: isUpdateAvailable
      ))
    }
    return repos.sorted { $0.repoName < $1.repoName }
  }
}

// MARK: - Supporting Types

public struct SyncHistoryEntry: Identifiable, Sendable {
  public let id = UUID()
  public let timestamp = Date()
  public let repoIdentifier: String
  public let fromWorkerName: String
  public let connectionMethod: String
  public let bytesTransferred: Int
  public let duration: TimeInterval
  public let success: Bool
  public var errorMessage: String?
}

public struct RemoteRepoInfo: Identifiable, Sendable {
  public var id: String { repoIdentifier }
  public let repoIdentifier: String
  public let repoName: String
  public let bestVersion: RAGIndexVersion
  public let sourceCount: Int
  public let isUpdateAvailable: Bool
}

public enum RAGSyncError: LocalizedError {
  case noDelegateConfigured
  case invalidSwarmId
  case workerNotFound(workerId: String)
  case noSourceAvailable(repoIdentifier: String)

  public var errorDescription: String? {
    switch self {
    case .noDelegateConfigured:
      return "RAG sync delegate not configured — MCPServerService may not be initialized"
    case .invalidSwarmId:
      return "Empty swarmId — provide a swarmId or start a swarm first"
    case .workerNotFound(let id):
      return "Worker \(id) not found in any swarm"
    case .noSourceAvailable(let repo):
      return "No sync source available for \(repo)"
    }
  }
}
