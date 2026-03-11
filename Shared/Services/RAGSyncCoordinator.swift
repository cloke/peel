//
//  RAGSyncCoordinator.swift
//  Peel
//
//  Orchestrates on-demand P2P RAG index sharing:
//  1. Subscribes to Firestore for remote index version updates
//  2. When a newer version is available, connects to the peer via
//     OnDemandPeerTransfer (LAN → WAN → WebRTC fallback)
//  3. Imports the received bundle via RAGArtifactSyncDelegate
//  4. Publishes local index versions after indexing
//
//  WebRTC data channels are used when LAN/WAN direct TCP fails.
//  ICE handles NAT traversal automatically.
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
  private let peerTransfer = OnDemandPeerTransfer()

  /// The delegate that provides import/export of RAG bundles.
  /// Set by MCPServerService when it initializes (it conforms to RAGArtifactSyncDelegate).
  weak var ragSyncDelegate: RAGArtifactSyncDelegate?

  /// Set the WebRTC signaling responder so the initiator can check whether
  /// an active serve task is in progress before starting a new transfer.
  var webrtcResponder: WebRTCSignalingResponder? {
    get { peerTransfer.webrtcResponder }
    set { peerTransfer.webrtcResponder = newValue }
  }

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

  /// Active transfer states (from OnDemandPeerTransfer)
  public var activeTransfers: [UUID: OnDemandTransferState] {
    peerTransfer.tracker.activeTransfers
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

    guard let ragSyncDelegate else {
      throw RAGSyncError.noDelegateConfigured
    }

    // Find the worker — try cached list first, then fetch directly from Firestore
    let firebase = FirebaseService.shared
    var worker = firebase.swarmWorkers.first(where: { $0.id == fromWorkerId })
    if worker == nil {
      logger.info("Worker \(fromWorkerId) not in cached list (\(firebase.swarmWorkers.count) workers cached), fetching from Firestore...")
      worker = try await firebase.fetchWorker(swarmId: swarmId, workerId: fromWorkerId)
    }
    guard let worker else {
      throw RAGSyncError.workerNotFound(workerId: fromWorkerId)
    }

    versionService.markSyncStarted(repoIdentifier: repoIdentifier)
    logger.info("Starting sync of \(repoIdentifier) from \(worker.displayName)")

    do {
      let state = try await peerTransfer.requestIndex(
        from: worker,
        repoIdentifier: repoIdentifier,
        swarmId: swarmId,
        ragSyncDelegate: ragSyncDelegate
      )

      syncHistory.append(SyncHistoryEntry(
        repoIdentifier: repoIdentifier,
        fromWorkerName: worker.displayName,
        connectionMethod: state.connectionMethod?.rawValue ?? "unknown",
        bytesTransferred: state.transferredBytes,
        duration: state.elapsedSeconds,
        success: true
      ))

      logger.info("Sync complete: \(repoIdentifier) from \(worker.displayName)")
    } catch {
      syncHistory.append(SyncHistoryEntry(
        repoIdentifier: repoIdentifier,
        fromWorkerName: worker.displayName,
        connectionMethod: "failed",
        bytesTransferred: 0,
        duration: 0,
        success: false,
        errorMessage: error.localizedDescription
      ))
      throw error
    }

    versionService.markSyncCompleted(repoIdentifier: repoIdentifier)
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
