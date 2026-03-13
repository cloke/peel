//
//  RepositoryAggregator.swift
//  Peel
//
//  Aggregates repository data from multiple sources (SwiftData models, RAG, chains,
//  worktrees, pull scheduler) into a single [UnifiedRepository] array.
//
//  This is the "join" layer that makes the Unified Repositories view possible.
//  It reads from:
//   - DataService (SyncedRepository, GitHubFavorite, LocalRepositoryPath, TrackedRemoteRepo, TrackedWorktree, MCPRunRecord)
//   - MCPServerService (ragRepos)
//   - AgentManager (chains)
//   - RepoPullScheduler (pull status + history)
//   - RepoRegistry (URL normalization)
//
//  The join key is `RepoRegistry.normalizeRemoteURL(...)`.
//

import Foundation
import OSLog
import SwiftData

@MainActor
@Observable
final class RepositoryAggregator {

  // MARK: - Output

  /// The unified list of repositories, sorted: active work first, then alphabetical.
  private(set) var repositories: [UnifiedRepository] = []

  /// Quick lookup: normalizedRemoteURL → UnifiedRepository
  private(set) var repositoryByURL: [String: UnifiedRepository] = [:]

  /// Quick lookup: id → UnifiedRepository
  private(set) var repositoryById: [UUID: UnifiedRepository] = [:]

  /// Whether a rebuild is currently in progress.
  private(set) var isRebuilding = false

  /// Tracks whether another rebuild should run immediately after the current one completes.
  private var pendingRebuildAfterCurrent = false

  /// Debounces bursty rebuild triggers from multiple UI/data sources.
  private var rebuildDebounceTask: Task<Void, Never>?

  /// Timestamp of the last successful rebuild.
  private(set) var lastRebuiltAt: Date?

  /// All currently-running agent chains across all repos (convenience for Activity dashboard).
  var allActiveChains: [AgentChain] {
    agentManager?.chains.filter { !$0.state.isTerminal } ?? []
  }

  // MARK: - Dependencies

  /// Set before calling `rebuild()`.
  weak var dataService: DataService?

  /// MCPServerService — provides ragRepos.
  weak var mcpServerService: MCPServerService?

  /// AgentManager — provides chains.
  weak var agentManager: AgentManager?

  /// RepoPullScheduler — provides pull status.
  weak var pullScheduler: RepoPullScheduler?

  // MARK: - Private

  private let logger = Logger(subsystem: "com.peel.services", category: "RepositoryAggregator")

  // MARK: - Lifecycle

  init() {}

  // MARK: - Rebuild

  /// Request a rebuild while coalescing bursty triggers.
  /// - Parameters:
  ///   - immediate: Bypass debounce and rebuild right away.
  ///   - debounceMilliseconds: Delay for non-immediate requests.
  func requestRebuild(immediate: Bool = false, debounceMilliseconds: UInt64 = 250) {
    if immediate {
      rebuildDebounceTask?.cancel()
      rebuildDebounceTask = nil
      rebuild()
      return
    }

    rebuildDebounceTask?.cancel()
    rebuildDebounceTask = Task { [weak self] in
      let delay = debounceMilliseconds * 1_000_000
      try? await Task.sleep(nanoseconds: delay)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.rebuild()
      }
    }
  }

  /// Re-aggregate all data sources into the unified list.
  /// Call this whenever underlying data changes (SwiftData save, chain status change, etc.)
  /// The method is idempotent and safe to call frequently; it builds a fresh snapshot.
  @MainActor
  func rebuild() {
    guard !isRebuilding else {
      pendingRebuildAfterCurrent = true
      return
    }

    guard let dataService else {
      logger.warning("Cannot rebuild: dataService not set")
      return
    }
    isRebuilding = true
    defer {
      isRebuilding = false
      lastRebuiltAt = Date()
      if pendingRebuildAfterCurrent {
        pendingRebuildAfterCurrent = false
        requestRebuild(immediate: true)
      }
    }

    // ---- 1. Fetch all data sources ----

    let syncedRepos = dataService.getAllRepositories()
    let localPaths = fetchAllLocalPaths(dataService: dataService)
    let favorites = dataService.getGitHubFavorites()
    let trackedRepos = dataService.getTrackedRemoteRepos()
    let worktrees = dataService.getTrackedWorktrees()
    let recentPRs = dataService.getRecentPRs(limit: 100)

    let ragRepos = mcpServerService?.ragRepos ?? []
    let chains = agentManager?.chains ?? []
    let pullHistory = pullScheduler?.pullHistory ?? []
    let isPulling = pullScheduler?.isPulling ?? false

    // ---- 2. Build lookup indexes ----

    // SyncedRepository id → LocalRepositoryPath
    let pathByRepoId: [UUID: LocalRepositoryPath] = Dictionary(
      localPaths.map { ($0.repositoryId, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    // normalized URL → SyncedRepository (+ its local path)
    var syncedByURL: [String: (repo: SyncedRepository, path: LocalRepositoryPath?)] = [:]
    for repo in syncedRepos {
      if let url = repo.remoteURL, !url.isEmpty {
        let norm = RepoRegistry.shared.normalizeRemoteURL(url)
        syncedByURL[norm] = (repo, pathByRepoId[repo.id])
      } else if let lp = pathByRepoId[repo.id] {
        // Local-only repos: use the local path as a pseudo-URL key
        let key = "local://\(lp.localPath)"
        syncedByURL[key] = (repo, lp)
      }
    }

    // normalized URL → GitHubFavorite
    let favoriteByURL: [String: GitHubFavorite] = Dictionary(
      favorites.compactMap { fav -> (String, GitHubFavorite)? in
        let url = "github.com/\(fav.fullName)".lowercased()
        return (url, fav)
      },
      uniquingKeysWith: { first, _ in first }
    )

    // normalized URL → TrackedRemoteRepo
    let trackedByURL: [String: TrackedRemoteRepo] = Dictionary(
      trackedRepos.map { (RepoRegistry.shared.normalizeRemoteURL($0.remoteURL), $0) },
      uniquingKeysWith: { first, _ in first }
    )

    // TrackedRemoteRepo.id → device-local state
    let deviceStateByTrackedId: [UUID: TrackedRepoDeviceState] = Dictionary(
      trackedRepos.compactMap { repo -> (UUID, TrackedRepoDeviceState)? in
        guard let state = dataService.getDeviceState(for: repo) else { return nil }
        return (repo.id, state)
      },
      uniquingKeysWith: { first, _ in first }
    )

    // normalized URL → [MCPServerService.RAGRepoInfo]
    // Sub-packages (parentRepoId != nil) get their own sidebar entries so the user
    // can see every indexed package individually. Top-level repos without a parent
    // use the normalized remote URL so they merge with SyncedRepository entries.
    var ragByURL: [String: MCPServerService.RAGRepoInfo] = [:]
    for info in ragRepos {
      let norm: String
      if info.parentRepoId != nil {
        // Sub-package: unique key so it's not aggregated into the parent
        norm = "rag://\(info.rootPath)"
      } else if let ident = info.repoIdentifier, !ident.isEmpty {
        norm = RepoRegistry.shared.normalizeRemoteURL(ident)
      } else if let cachedURL = RepoRegistry.shared.getCachedRemoteURL(for: info.rootPath) {
        norm = cachedURL
      } else {
        // Fallback: path-based key so RAG-only repos still appear
        norm = "rag://\(info.rootPath)"
      }

      if let existing = ragByURL[norm] {
        // Aggregate: sum counts, pick latest indexed date, prefer shorter rootPath (parent)
        // For embedding model & dims: prefer the entry with actual data (chunks > 0).
        // A repo entry with 0 chunks but a model name is stale (e.g., re-indexed locally then
        // data cleared but repo row remains). We want the model from entries that have real content.
        let bestModel: String? = {
          if let em = existing.embeddingModel, let im = info.embeddingModel {
            // Both have models: prefer the one with more chunks
            return existing.chunkCount >= info.chunkCount ? em : im
          }
          if existing.embeddingModel != nil && info.embeddingModel == nil {
            // Only existing has model: use it if it has data, otherwise defer
            return existing.chunkCount > 0 ? existing.embeddingModel : nil
          }
          if info.embeddingModel != nil && existing.embeddingModel == nil {
            return info.chunkCount > 0 ? info.embeddingModel : nil
          }
          return nil
        }()
        let bestDims: Int? = {
          if existing.embeddingDimensions != nil && info.embeddingDimensions != nil {
            return existing.chunkCount >= info.chunkCount
              ? existing.embeddingDimensions : info.embeddingDimensions
          }
          // Prefer dims from the entry with data
          if existing.chunkCount > 0 && existing.embeddingDimensions != nil {
            return existing.embeddingDimensions
          }
          if info.chunkCount > 0 && info.embeddingDimensions != nil {
            return info.embeddingDimensions
          }
          return existing.embeddingDimensions ?? info.embeddingDimensions
        }()
        ragByURL[norm] = MCPServerService.RAGRepoInfo(
          id: existing.id,
          name: existing.name,
          rootPath: existing.rootPath.count <= info.rootPath.count ? existing.rootPath : info.rootPath,
          lastIndexedAt: [existing.lastIndexedAt, info.lastIndexedAt].compactMap { $0 }.max(),
          fileCount: existing.fileCount + info.fileCount,
          chunkCount: existing.chunkCount + info.chunkCount,
          embeddingCount: existing.embeddingCount + info.embeddingCount,
          repoIdentifier: existing.repoIdentifier,
          parentRepoId: nil,
          embeddingModel: bestModel,
          embeddingDimensions: bestDims
        )
      } else {
        ragByURL[norm] = info
      }
    }


    // normalized URL → [AgentChain] (chains that have a known workingDirectory)
    var chainsByURL: [String: [AgentChain]] = [:]
    for chain in chains {
      guard let workDir = chain.workingDirectory else { continue }
      if let cachedURL = RepoRegistry.shared.getCachedRemoteURL(for: workDir) {
        chainsByURL[cachedURL, default: []].append(chain)
      } else {
        // Try the parent of .agent-workspaces paths
        let parentPath = resolveRepoPath(from: workDir)
        if let cachedURL = RepoRegistry.shared.getCachedRemoteURL(for: parentPath) {
          chainsByURL[cachedURL, default: []].append(chain)
        }
      }
    }

    // normalized URL → [TrackedWorktree]
    var worktreesByURL: [String: [TrackedWorktree]] = [:]
    for wt in worktrees {
      // Find the synced repo to get its URL
      if let syncedRepo = syncedRepos.first(where: { $0.id == wt.repositoryId }),
         let url = syncedRepo.remoteURL, !url.isEmpty {
        let norm = RepoRegistry.shared.normalizeRemoteURL(url)
        worktreesByURL[norm, default: []].append(wt)
      } else if !wt.mainRepoPath.isEmpty,
                let cachedURL = RepoRegistry.shared.getCachedRemoteURL(for: wt.mainRepoPath) {
        worktreesByURL[cachedURL, default: []].append(wt)
      }
    }

    // repo full name → [RecentPullRequest]
    var prsByFullName: [String: [RecentPullRequest]] = [:]
    for pr in recentPRs {
      let key = pr.repoFullName.lowercased()
      prsByFullName[key, default: []].append(pr)
    }

    // normalized URL → most recent pull history entry
    var lastPullByURL: [String: PullHistoryEntry] = [:]
    for entry in pullHistory {
      let norm = RepoRegistry.shared.normalizeRemoteURL(entry.remoteURL)
      if lastPullByURL[norm] == nil {
        lastPullByURL[norm] = entry // pullHistory is already newest-first
      }
    }

    // ---- 3. Collect all unique normalized URLs ----
    //  Include RepoRegistry (Git tab repos, ReviewLocally repos) as a data source
    //  so repos registered via populateRepoRegistry() appear even without SwiftData records.

    let registeredRepos = RepoRegistry.shared.registeredRepos
    var registeredPathByURL: [String: String] = [:]
    for (remoteURL, localPath) in registeredRepos {
      registeredPathByURL[remoteURL] = localPath
    }

    var allURLs = Set<String>()
    allURLs.formUnion(syncedByURL.keys)
    allURLs.formUnion(favoriteByURL.keys)
    allURLs.formUnion(trackedByURL.keys)
    allURLs.formUnion(ragByURL.keys)
    allURLs.formUnion(chainsByURL.keys)
    allURLs.formUnion(worktreesByURL.keys)
    allURLs.formUnion(registeredPathByURL.keys)

    // ---- 4. Build UnifiedRepository for each URL ----

    var result: [UnifiedRepository] = []

    for url in allURLs {
      let synced = syncedByURL[url]
      let favorite = favoriteByURL[url]
      let tracked = trackedByURL[url]
      let rag = ragByURL[url]
      let chainsForRepo = chainsByURL[url] ?? []
      let wtForRepo = worktreesByURL[url] ?? []

      // Derive owner/repo for PR lookup
      let ownerSlashRepo = deriveOwnerSlashRepo(
        from: url, favorite: favorite, tracked: tracked
      )
      let prsForRepo = (ownerSlashRepo.flatMap { prsByFullName[$0.lowercased()] } ?? [])
        .filter { $0.state == "open" && $0.dismissedAt == nil }
      let lastPull = lastPullByURL[url]

      // Choose the most stable id
      let stableId = synced?.repo.id
        ?? tracked?.id
        ?? favorite?.id
        ?? deterministicUUID(from: url)

      // Best display name
      let displayName = synced?.repo.name.nilIfEmpty
        ?? tracked?.name.nilIfEmpty
        ?? favorite?.repoName.nilIfEmpty
        ?? url.split(separator: "/").last.map(String.init)
        ?? url

      // Local path
      let deviceState = tracked.flatMap { deviceStateByTrackedId[$0.id] }
      var localPath = synced?.path?.localPath
        ?? deviceState?.localPath.nilIfEmpty
        ?? registeredPathByURL[url]
      if localPath == nil {
        localPath = rag?.rootPath.nilIfEmpty
      }

      // Remote URL (original format)
      let originalRemoteURL = synced?.repo.remoteURL
        ?? tracked?.remoteURL
        ?? favorite?.htmlURL

      // RAG status mapping
      let ragStatus = mapRAGStatus(rag: rag)

      // Pull status mapping
      let pullStatus = mapPullStatus(
        tracked: tracked,
        deviceState: deviceState,
        isPulling: isPulling,
        lastPull: lastPull
      )

      // Earliest created date
      let addedAt = [
        synced?.repo.createdAt,
        tracked?.createdAt,
        favorite?.addedAt,
      ].compactMap { $0 }.min()

      // Latest activity
      let lastActivity: Date? = {
        var candidates: [Date?] = [
          synced?.repo.modifiedAt,
          deviceState?.lastPullAt,
          wtForRepo.map(\.createdAt).max(),
          prsForRepo.map(\.viewedAt).max(),
        ]
        candidates.append(chainsForRepo.compactMap(\.runStartTime).max())
        return candidates.compactMap { $0 }.max()
      }()

      let activeWTs = wtForRepo.filter {
        $0.taskStatus != TrackedWorktree.Status.cleaned
          && $0.taskStatus != TrackedWorktree.Status.orphaned
      }

      // macOS-only fields (RAG + chains)
      let isSubPackage = rag?.parentRepoId != nil
      let ragFileCount = rag?.fileCount
      let ragChunkCount = rag?.chunkCount
      let ragEmbeddingModel = rag?.embeddingModel
      let ragLastIndexedAt = rag?.lastIndexedAt
      let activeChainCount = chainsForRepo.filter { !$0.state.isTerminal }.count
      let activeChains = chainsForRepo.map { chain in
        UnifiedRepository.ChainSummary(
          id: chain.id,
          name: chain.name,
          stateDisplay: chain.state.displayName,
          isTerminal: chain.state.isTerminal
        )
      }

      let unified = UnifiedRepository(
        id: stableId,
        normalizedRemoteURL: url,
        displayName: displayName,
        remoteURL: originalRemoteURL,
        isClonedLocally: localPath != nil,
        localPath: localPath,
        isFavorite: favorite != nil || (synced?.repo.isFavorite ?? false),
        isTracked: tracked != nil && (tracked?.isEnabled ?? false),
        isSubPackage: isSubPackage,
        ownerSlashRepo: ownerSlashRepo,
        htmlURL: favorite?.htmlURL ?? synced?.repo.remoteURL,
        ragStatus: ragStatus,
        ragFileCount: ragFileCount,
        ragChunkCount: ragChunkCount,
        ragEmbeddingModel: ragEmbeddingModel,
        ragLastIndexedAt: ragLastIndexedAt,
        pullStatus: pullStatus,
        trackedBranch: tracked?.branch,
        pullIntervalSeconds: tracked?.pullIntervalSeconds,
        syncMode: tracked?.syncMode,
        activeChainCount: activeChainCount,
        activeChains: activeChains,
        worktreeCount: activeWTs.count,
        activeWorktrees: activeWTs.map { wt in
          UnifiedRepository.WorktreeSummary(
            id: wt.id,
            branch: wt.branch,
            source: wt.source,
            taskStatus: wt.taskStatus,
            purpose: wt.purpose
          )
        },
        recentPRs: prsForRepo.prefix(5).map { pr in
          UnifiedRepository.PRSummary(
            id: pr.id,
            number: pr.prNumber,
            title: pr.title,
            state: pr.state,
            htmlURL: pr.htmlURL,
            headRef: nil,
            updatedAt: nil
          )
        },
        addedAt: addedAt,
        lastActivityAt: lastActivity,
        syncedRepositoryId: synced?.repo.id,
        trackedRemoteRepoId: tracked?.id,
        githubFavoriteId: favorite?.id,
        colorTag: synced?.repo.colorTag,
        notes: synced?.repo.notes
      )

      result.append(unified)
    }

    // ---- 5. Sort: active work → tracked → alphabetical ----

    result.sort { lhs, rhs in
      if lhs.sortPriority != rhs.sortPriority {
        return lhs.sortPriority > rhs.sortPriority
      }
      if lhs.isFavorite != rhs.isFavorite {
        return lhs.isFavorite
      }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    // ---- 6. Publish ----

    repositories = result
    repositoryByURL = Dictionary(
      result.map { ($0.normalizedRemoteURL, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    repositoryById = Dictionary(
      result.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    logger.info("Rebuilt unified repos: \(result.count) entries from \(syncedRepos.count) synced, \(favorites.count) favorites, \(trackedRepos.count) tracked, \(ragRepos.count) RAG, \(chains.count) chains, \(worktrees.count) worktrees, \(registeredRepos.count) registered")
  }

  // MARK: - Convenience

  /// Find the unified repo for a local path.
  func repository(forLocalPath path: String) -> UnifiedRepository? {
    if let url = RepoRegistry.shared.getCachedRemoteURL(for: path) {
      return repositoryByURL[url]
    }
    return repositories.first { $0.localPath == path }
  }

  /// Find the unified repo for a remote URL (any format).
  func repository(forRemoteURL url: String) -> UnifiedRepository? {
    let norm = RepoRegistry.shared.normalizeRemoteURL(url)
    return repositoryByURL[norm]
  }

  // MARK: - Private Helpers

  /// Fetch all LocalRepositoryPath records.
  private func fetchAllLocalPaths(dataService: DataService) -> [LocalRepositoryPath] {
    let descriptor = FetchDescriptor<LocalRepositoryPath>()
    return (try? dataService.modelContext.fetch(descriptor)) ?? []
  }

  /// If the path contains `.agent-workspaces`, walk up to get the actual repo root.
  private func resolveRepoPath(from workDir: String) -> String {
    if let range = workDir.range(of: "/.agent-workspaces/") {
      return String(workDir[workDir.startIndex..<range.lowerBound])
    }
    return workDir
  }

  /// Derive "owner/repo" from available data.
  private func deriveOwnerSlashRepo(
    from normalizedURL: String,
    favorite: GitHubFavorite?,
    tracked: TrackedRemoteRepo?
  ) -> String? {
    if let fav = favorite { return fav.fullName }

    // Try to parse from URL: "github.com/owner/repo" → "owner/repo"
    let parts = normalizedURL.split(separator: "/")
    if parts.count >= 3, parts[0].contains("github.com") {
      return "\(parts[1])/\(parts[2])"
    }

    return nil
  }

  /// Map RAGRepoInfo → UnifiedRepository.RAGStatus
  private func mapRAGStatus(rag: MCPServerService.RAGRepoInfo?) -> UnifiedRepository.RAGStatus? {
    guard let rag else { return nil }
    // If there are embeddings, it's at least indexed
    if rag.embeddingCount > 0 {
      // Consider stale if last indexed > 7 days ago
      if let lastIndexed = rag.lastIndexedAt,
         Date().timeIntervalSince(lastIndexed) > 7 * 24 * 3600 {
        return .stale
      }
      return .analyzed
    }
    if rag.chunkCount > 0 {
      return .indexed
    }
    return .notIndexed
  }

  /// Map TrackedRemoteRepo + pull state → UnifiedRepository.PullStatus
  private func mapPullStatus(
    tracked: TrackedRemoteRepo?,
    deviceState: TrackedRepoDeviceState?,
    isPulling: Bool,
    lastPull: PullHistoryEntry?
  ) -> UnifiedRepository.PullStatus? {
    guard let tracked else { return nil }
    guard tracked.isEnabled else { return .disabled }

    if isPulling {
      return .pulling
    }

    // Don't show pull errors for repos with no local path on this device
    if let state = deviceState, !state.localPath.isEmpty,
       let lastErr = state.lastPullError, !lastErr.isEmpty {
      return .error(message: lastErr)
    }

    if let result = deviceState?.lastPullResult {
      if result.contains("up-to-date") {
        return .upToDate
      }
      if result.contains("updated") {
        return .updated(sha: result)
      }
    }

    return .idle(lastPull: deviceState?.lastPullAt)
  }

  /// Produce a stable UUID from a string (for repos that have no SwiftData id).
  private func deterministicUUID(from string: String) -> UUID {
    let data = Data(string.utf8)
    var bytes = [UInt8](repeating: 0, count: 16)
    let hashBytes = Array(data).withUnsafeBufferPointer { buffer -> [UInt8] in
      var hash = [UInt8](repeating: 0, count: 16)
      for (i, byte) in buffer.enumerated() {
        hash[i % 16] ^= byte
      }
      return hash
    }
    for i in 0..<16 {
      bytes[i] = hashBytes[i]
    }
    // Set version 5 (name-based) and variant bits
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }
}

// MARK: - String Helper

private extension String {
  /// Returns nil if the string is empty, otherwise self.
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
