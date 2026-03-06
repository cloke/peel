//
//  RAGIndexVersionService.swift
//  Peel
//
//  Publishes local RAG index versions to Firestore and subscribes to
//  remote peers' versions. When a newer version is detected, emits
//  an availability notification so RAGSyncCoordinator can trigger
//  on-demand P2P transfer.
//
//  Firestore path: swarms/{swarmId}/ragIndexes/{repoIdentifier}
//  Each document is keyed by a hash of the repoIdentifier (normalized
//  git remote URL) and scoped to a worker.
//

import FirebaseFirestore
import Foundation
import os.log
import RAGCore

// MARK: - Types

/// Lightweight metadata about a repo's RAG index on a specific worker.
/// Stored in Firestore for signaling — never contains actual embeddings.
public struct RAGIndexVersion: Codable, Sendable, Identifiable {
  public let id: String  // "{workerId}:{repoIdentifier}"
  public let workerId: String
  public let workerName: String
  public let repoIdentifier: String
  public let repoName: String
  public let version: Int
  public let headSHA: String?
  public let fileCount: Int
  public let chunkCount: Int
  public let embeddingModel: String
  public let embeddingDimensions: Int
  public let sizeEstimateBytes: Int
  public let lastIndexedAt: Date

  /// Firestore document key (safe for use as doc ID)
  var documentKey: String {
    "\(workerId)__\(repoIdentifier.replacingOccurrences(of: "/", with: "_"))"
  }
}

/// Notification that a peer has a newer index version available for P2P sync.
public struct RAGIndexAvailability: Sendable {
  public let swarmId: String
  public let source: RAGIndexVersion
  public let localVersion: Int?  // nil if we don't have this repo at all
  public let localChunkCount: Int?
}

// MARK: - Service

@MainActor
@Observable
public final class RAGIndexVersionService {
  static let shared = RAGIndexVersionService()

  private let logger = Logger(subsystem: "com.peel.rag", category: "IndexVersion")

  // MARK: - Published State

  /// Remote index versions, keyed by repoIdentifier → [workerId: version]
  public private(set) var remoteVersions: [String: [String: RAGIndexVersion]] = [:]

  /// Pending sync opportunities (newer versions available from peers)
  public private(set) var availableUpdates: [RAGIndexAvailability] = []

  /// Whether we're actively listening for remote versions
  public private(set) var isListening = false

  // MARK: - Private State

  private var listeners: [String: ListenerRegistration] = [:]  // keyed by swarmId
  private var publishedVersions: [String: Int] = [:]  // repoIdentifier → last published version
  private var syncInProgress: Set<String> = []  // repoIdentifiers currently syncing

  /// Callback invoked when a new index becomes available for sync
  var onIndexAvailable: ((RAGIndexAvailability) -> Void)?

  private init() {}

  // MARK: - Publishing

  /// Publish the current index version for a repo to all joined swarms.
  /// Call this after rag.index completes successfully.
  func publishIndexVersion(
    repoIdentifier: String,
    repoName: String,
    headSHA: String?,
    fileCount: Int,
    chunkCount: Int,
    embeddingModel: String,
    embeddingDimensions: Int,
    sizeEstimateBytes: Int
  ) async {
    let firebase = FirebaseService.shared
    guard firebase.isSignedIn else {
      logger.debug("Not signed in, skipping index version publish")
      return
    }

    let deviceId = WorkerCapabilities.current().deviceId
    let deviceName = WorkerCapabilities.current().deviceName

    let canonicalRepoIdentifier = normalizeRepoIdentifier(repoIdentifier)

    // Increment version (or start at 1)
    let currentVersion = publishedVersions[canonicalRepoIdentifier] ?? 0
    let newVersion = currentVersion + 1

    let indexVersion = RAGIndexVersion(
      id: "\(deviceId):\(canonicalRepoIdentifier)",
      workerId: deviceId,
      workerName: deviceName,
      repoIdentifier: canonicalRepoIdentifier,
      repoName: repoName,
      version: newVersion,
      headSHA: headSHA,
      fileCount: fileCount,
      chunkCount: chunkCount,
      embeddingModel: embeddingModel,
      embeddingDimensions: embeddingDimensions,
      sizeEstimateBytes: sizeEstimateBytes,
      lastIndexedAt: Date()
    )

    // Write to each swarm we belong to
    for swarm in firebase.memberSwarms where swarm.role.canRegisterWorkers {
      do {
        let docRef = ragIndexesCollection(swarmId: swarm.id)
          .document(indexVersion.documentKey)

        let data: [String: Any] = [
          "workerId": indexVersion.workerId,
          "workerName": indexVersion.workerName,
          "repoIdentifier": indexVersion.repoIdentifier,
          "repoName": indexVersion.repoName,
          "version": indexVersion.version,
          "headSHA": indexVersion.headSHA as Any,
          "fileCount": indexVersion.fileCount,
          "chunkCount": indexVersion.chunkCount,
          "embeddingModel": indexVersion.embeddingModel,
          "embeddingDimensions": indexVersion.embeddingDimensions,
          "sizeEstimateBytes": indexVersion.sizeEstimateBytes,
          "lastIndexedAt": FieldValue.serverTimestamp(),
        ]
        try await docRef.setData(data)
        logger.info("Published index v\(newVersion) for \(repoName) in swarm \(swarm.swarmName)")
      } catch {
        logger.warning("Failed to publish index version for \(repoName) in \(swarm.swarmName): \(error.localizedDescription)")
      }
    }

    publishedVersions[canonicalRepoIdentifier] = newVersion
  }

  // MARK: - Subscribing

  /// Start listening for remote index versions in all joined swarms.
  func startListening() {
    guard !isListening else { return }
    isListening = true

    let firebase = FirebaseService.shared
    for swarm in firebase.memberSwarms {
      addListener(swarmId: swarm.id)
    }
    logger.info("Started listening for remote RAG index versions (\(firebase.memberSwarms.count) swarms)")
  }

  /// Stop all listeners.
  func stopListening() {
    for (_, listener) in listeners {
      listener.remove()
    }
    listeners.removeAll()
    isListening = false
    logger.info("Stopped listening for remote RAG index versions")
  }

  /// Add a listener for a specific swarm's ragIndexes.
  private func addListener(swarmId: String) {
    guard listeners[swarmId] == nil else { return }
    let myDeviceId = WorkerCapabilities.current().deviceId

    let listener = ragIndexesCollection(swarmId: swarmId)
      .addSnapshotListener { [weak self] snapshot, error in
        Task { @MainActor [weak self] in
          guard let self else { return }

          if let error {
            self.logger.warning("ragIndexes listener error for swarm \(swarmId): \(error.localizedDescription)")
            return
          }

          guard let snapshot else { return }

          for change in snapshot.documentChanges {
            let data = change.document.data()
            guard let version = self.parseIndexVersion(from: data) else { continue }

            // Skip our own updates
            guard version.workerId != myDeviceId else { continue }

            switch change.type {
            case .added, .modified:
              self.handleRemoteVersionUpdate(swarmId: swarmId, version: version)
            case .removed:
              self.remoteVersions[version.repoIdentifier]?.removeValue(forKey: version.workerId)
            }
          }
        }
      }

    listeners[swarmId] = listener
  }

  /// Process an incoming remote index version update.
  private func handleRemoteVersionUpdate(swarmId: String, version: RAGIndexVersion) {
    let canonicalRepoIdentifier = normalizeRepoIdentifier(version.repoIdentifier)
    let normalizedVersion = RAGIndexVersion(
      id: "\(version.workerId):\(canonicalRepoIdentifier)",
      workerId: version.workerId,
      workerName: version.workerName,
      repoIdentifier: canonicalRepoIdentifier,
      repoName: version.repoName,
      version: version.version,
      headSHA: version.headSHA,
      fileCount: version.fileCount,
      chunkCount: version.chunkCount,
      embeddingModel: version.embeddingModel,
      embeddingDimensions: version.embeddingDimensions,
      sizeEstimateBytes: version.sizeEstimateBytes,
      lastIndexedAt: version.lastIndexedAt
    )

    // Update our cache
    if remoteVersions[canonicalRepoIdentifier] == nil {
      remoteVersions[canonicalRepoIdentifier] = [:]
    }
    remoteVersions[canonicalRepoIdentifier]?[version.workerId] = normalizedVersion

    // Check if this is newer than what we have locally
    Task {
      await checkForAvailableUpdate(swarmId: swarmId, remote: normalizedVersion)
    }
  }

  /// Compare remote version against our local index and emit availability if newer.
  private func checkForAvailableUpdate(swarmId: String, remote: RAGIndexVersion) async {
    let canonicalRepoIdentifier = normalizeRepoIdentifier(remote.repoIdentifier)

    // Don't re-check if we're already syncing this repo
    guard !syncInProgress.contains(canonicalRepoIdentifier) else { return }

    let store = RAGStore.shared
    do {
      let repos = try await store.listRepos()
      let localRepo = repos.first(where: { repo in
        guard let identifier = repo.repoIdentifier else { return false }
        return normalizeRepoIdentifier(identifier) == canonicalRepoIdentifier
      })

      let localChunkCount = localRepo?.chunkCount
      let localVersion = publishedVersions[canonicalRepoIdentifier]

      // Emit availability if:
      // 1. We don't have this repo at all, OR
      // 2. Remote version is higher, OR
      // 3. Remote has significantly more chunks (>10% more)
      let shouldSync: Bool
      if localRepo == nil {
        shouldSync = true
      } else if let lv = localVersion, remote.version > lv {
        shouldSync = true
      } else if localVersion == nil {
        // Versions are in-memory and reset on app launch; treat unknown local version
        // as sync-eligible so remote sources remain discoverable in UI and auto-sync paths.
        shouldSync = true
      } else if let lc = localChunkCount, remote.chunkCount > lc + max(10, lc / 10) {
        shouldSync = true
      } else {
        shouldSync = false
      }

      if shouldSync {
        let availability = RAGIndexAvailability(
          swarmId: swarmId,
          source: remote,
          localVersion: localVersion,
          localChunkCount: localChunkCount
        )

        // Replace any existing availability for this repo
        availableUpdates.removeAll {
          normalizeRepoIdentifier($0.source.repoIdentifier) == canonicalRepoIdentifier
        }
        availableUpdates.append(availability)

        logger.info("Index available: \(remote.repoName) v\(remote.version) from \(remote.workerName) (\(remote.chunkCount) chunks)")
        onIndexAvailable?(availability)
      }
    } catch {
      logger.warning("Error checking local index for \(remote.repoIdentifier): \(error.localizedDescription)")
    }
  }

  /// Mark a repo as currently syncing (prevents duplicate triggers).
  func markSyncStarted(repoIdentifier: String) {
    syncInProgress.insert(normalizeRepoIdentifier(repoIdentifier))
  }

  /// Mark a repo sync as complete.
  func markSyncCompleted(repoIdentifier: String) {
    let canonicalRepoIdentifier = normalizeRepoIdentifier(repoIdentifier)
    syncInProgress.remove(canonicalRepoIdentifier)
    availableUpdates.removeAll {
      normalizeRepoIdentifier($0.source.repoIdentifier) == canonicalRepoIdentifier
    }
  }

  /// Dismiss an available update without syncing.
  func dismissUpdate(repoIdentifier: String) {
    let canonicalRepoIdentifier = normalizeRepoIdentifier(repoIdentifier)
    availableUpdates.removeAll {
      normalizeRepoIdentifier($0.source.repoIdentifier) == canonicalRepoIdentifier
    }
  }

  // MARK: - Helpers

  private func ragIndexesCollection(swarmId: String) -> CollectionReference {
    Firestore.firestore().collection("swarms/\(swarmId)/ragIndexes")
  }

  private func parseIndexVersion(from data: [String: Any]) -> RAGIndexVersion? {
    guard
      let workerId = data["workerId"] as? String,
      let workerName = data["workerName"] as? String,
      let repoIdentifier = data["repoIdentifier"] as? String,
      let repoName = data["repoName"] as? String,
      let version = data["version"] as? Int,
      let fileCount = data["fileCount"] as? Int,
      let chunkCount = data["chunkCount"] as? Int,
      let embeddingModel = data["embeddingModel"] as? String,
      let embeddingDimensions = data["embeddingDimensions"] as? Int,
      let sizeEstimateBytes = data["sizeEstimateBytes"] as? Int
    else { return nil }

    let headSHA = data["headSHA"] as? String
    let lastIndexedAt: Date
    if let ts = data["lastIndexedAt"] as? Timestamp {
      lastIndexedAt = ts.dateValue()
    } else {
      lastIndexedAt = Date()
    }

    let canonicalRepoIdentifier = normalizeRepoIdentifier(repoIdentifier)

    return RAGIndexVersion(
      id: "\(workerId):\(canonicalRepoIdentifier)",
      workerId: workerId,
      workerName: workerName,
      repoIdentifier: canonicalRepoIdentifier,
      repoName: repoName,
      version: version,
      headSHA: headSHA,
      fileCount: fileCount,
      chunkCount: chunkCount,
      embeddingModel: embeddingModel,
      embeddingDimensions: embeddingDimensions,
      sizeEstimateBytes: sizeEstimateBytes,
      lastIndexedAt: lastIndexedAt
    )
  }

  private func normalizeRepoIdentifier(_ value: String) -> String {
    RepoRegistry.shared.normalizeRemoteURL(value)
  }
}
