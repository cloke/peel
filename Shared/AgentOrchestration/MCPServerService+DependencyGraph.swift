import Foundation
import MCPCore

// MARK: - Reindex Errors

enum RAGReindexError: LocalizedError {
  /// The repo uses a swarm embedding model but no swarm workers are connected.
  case swarmModelNoWorkers(repoModel: String, localModel: String)
  /// The swarm worker failed to reindex.
  case swarmReindexFailed(worker: String, output: String)

  var errorDescription: String? {
    switch self {
    case .swarmModelNoWorkers(let repoModel, let localModel):
      return "This repo uses \(repoModel) embeddings (from swarm). "
        + "Connect to swarm to reindex, or delete and re-create to use local \(localModel)."
    case .swarmReindexFailed(let worker, let output):
      return "Swarm reindex failed on \(worker): \(output)"
    }
  }
}

// MARK: - Dependency Graph
// Extracted from MCPServerService.swift for maintainability

extension MCPServerService {
  // MARK: - Dependency Graph

  func listRagReposForGraph() async throws -> [(name: String, path: String)] {
    let repos = try await localRagStore.listRepos()
    return repos.map { (name: $0.name, path: $0.rootPath) }
  }

  func buildFullDependencyGraph(repoPath: String) async throws -> FullGraphData {
    let fileSummaries = try await localRagStore.getFileSummaries(for: repoPath)
    let edges = try await localRagStore.getDependencyEdges(for: repoPath)

    var moduleStats: [String: GraphNodeStats] = [:]
    var submoduleStats: [String: GraphNodeStats] = [:]
    var fileIndex: [String: LocalRAGFileSummary] = [:]

    for file in fileSummaries {
      let normalized = normalizedPath(file.path)
      fileIndex[normalized] = file

      let moduleId = moduleKey(for: normalized, modulePath: file.modulePath)
      let submoduleInfo = submoduleKey(for: normalized, modulePath: file.modulePath)

      var moduleBucket = moduleStats[moduleId, default: GraphNodeStats()]
      moduleBucket.fileCount += 1
      addLanguage(file.language, to: &moduleBucket.languages)
      moduleStats[moduleId] = moduleBucket

      var submoduleBucket = submoduleStats[submoduleInfo.key, default: GraphNodeStats()]
      submoduleBucket.fileCount += 1
      addLanguage(file.language, to: &submoduleBucket.languages)
      submoduleBucket.module = submoduleInfo.module
      submoduleStats[submoduleInfo.key] = submoduleBucket
    }

    var resolvedDependencies = 0
    var inferredDependencies = 0
    var moduleLinks: [LinkKey: LinkBucket] = [:]
    var submoduleLinks: [LinkKey: LinkBucket] = [:]

    for edge in edges {
      let sourcePath = normalizedPath(edge.sourceFile)
      let sourceFile = fileIndex[sourcePath]
      let sourceModule = moduleKey(for: sourcePath, modulePath: sourceFile?.modulePath)
      let sourceSubmodule = submoduleKey(for: sourcePath, modulePath: sourceFile?.modulePath).key

      let targetPath = edge.targetFile.map { normalizedPath($0) } ?? normalizedPath(edge.targetPath)
      let targetFile = edge.targetFile.flatMap { fileIndex[normalizedPath($0)] }
      let targetModule = moduleKey(for: targetPath, modulePath: targetFile?.modulePath)
      let targetSubmodule = submoduleKey(for: targetPath, modulePath: targetFile?.modulePath).key

      if edge.targetFile == nil {
        inferredDependencies += 1
      } else {
        resolvedDependencies += 1
      }

      if !sourceModule.isEmpty, !targetModule.isEmpty, sourceModule != targetModule {
        let key = LinkKey(source: sourceModule, target: targetModule)
        moduleLinks[key, default: LinkBucket()].add(type: edge.dependencyType.rawValue)
      }

      if !sourceSubmodule.isEmpty, !targetSubmodule.isEmpty, sourceSubmodule != targetSubmodule {
        let key = LinkKey(source: sourceSubmodule, target: targetSubmodule)
        submoduleLinks[key, default: LinkBucket()].add(type: edge.dependencyType.rawValue)
      }

      if moduleStats[targetModule] == nil {
        moduleStats[targetModule] = GraphNodeStats()
      }
      if submoduleStats[targetSubmodule] == nil {
        var bucket = GraphNodeStats()
        bucket.module = submoduleKey(for: targetPath, modulePath: targetFile?.modulePath).module
        submoduleStats[targetSubmodule] = bucket
      }
    }

    let moduleNodes = moduleStats.map { entry in
      GraphNode(
        id: entry.key,
        label: entry.key,
        fileCount: entry.value.fileCount,
        topLanguage: topLanguage(from: entry.value.languages),
        languages: entry.value.languages.isEmpty ? nil : entry.value.languages,
        module: entry.key
      )
    }
    .sorted { $0.id < $1.id }

    let submoduleNodes = submoduleStats.map { entry in
      GraphNode(
        id: entry.key,
        label: entry.key,
        fileCount: entry.value.fileCount,
        topLanguage: topLanguage(from: entry.value.languages),
        languages: entry.value.languages.isEmpty ? nil : entry.value.languages,
        module: entry.value.module
      )
    }
    .sorted { $0.id < $1.id }

    let moduleLinksOutput = moduleLinks.map { entry in
      GraphLink(source: entry.key.source, target: entry.key.target, weight: entry.value.weight, types: entry.value.types)
    }
    .sorted { $0.source < $1.source }

    let submoduleLinksOutput = submoduleLinks.map { entry in
      GraphLink(source: entry.key.source, target: entry.key.target, weight: entry.value.weight, types: entry.value.types)
    }
    .sorted { $0.source < $1.source }

    let stats = GraphStats(
      totalFiles: fileSummaries.count,
      totalDependencies: edges.count,
      resolvedDependencies: resolvedDependencies,
      inferredDependencies: inferredDependencies,
      totalModules: moduleNodes.count
    )

    return FullGraphData(
      repo: repoPath,
      stats: stats,
      moduleGraph: GraphLevel(nodes: moduleNodes, links: moduleLinksOutput),
      submoduleGraph: GraphLevel(nodes: submoduleNodes, links: submoduleLinksOutput),
      fileGraph: nil
    )
  }

  private struct GraphNodeStats {
    var fileCount: Int = 0
    var languages: [String: Int] = [:]
    var module: String? = nil
  }

  private struct LinkBucket {
    var weight: Int = 0
    var types: [String: Int] = [:]

    mutating func add(type: String) {
      weight += 1
      types[type, default: 0] += 1
    }
  }

  private struct LinkKey: Hashable {
    let source: String
    let target: String
  }

  private func normalizedPath(_ path: String) -> String {
    var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("./") {
      trimmed = String(trimmed.dropFirst(2))
    }
    return trimmed
  }

  private func moduleKey(for path: String, modulePath: String?) -> String {
    let basePath = normalizedPath(modulePath?.isEmpty == false ? modulePath! : path)
    let components = basePath.split(separator: "/")
    return components.first.map(String.init) ?? basePath
  }

  private func submoduleKey(for path: String, modulePath: String?) -> (key: String, module: String) {
    let basePath = normalizedPath(modulePath?.isEmpty == false ? modulePath! : path)
    let components = basePath.split(separator: "/")
    let module = components.first.map(String.init) ?? basePath
    if components.count >= 2 {
      return ("\(components[0])/\(components[1])", module)
    }
    return (module, module)
  }

  private func addLanguage(_ language: String?, to counts: inout [String: Int]) {
    guard let language, !language.isEmpty else { return }
    counts[language, default: 0] += 1
  }

  private func topLanguage(from counts: [String: Int]) -> String? {
    counts.max { $0.value < $1.value }?.key
  }

  func indexPolicyRepository(path: String) async throws -> LocalRAGIndexReport {
    try await localRagStore.indexRepository(path: path)
  }

  func refreshRagArtifactStatus() async {
    guard let status = ragStatus else {
      ragArtifactStatus = nil
      SwarmCoordinator.shared.updateLocalRagArtifactStatus(nil)
      return
    }

    let stats = try? await localRagStore.stats()
    let repos = (try? await localRagStore.listRepos()) ?? []
    let manifest = await LocalRAGArtifacts.buildManifest(status: status, stats: stats, repos: repos)
    let lastSyncedAt = ragArtifactStatus?.lastSyncedAt
    let lastSyncDirection = ragArtifactStatus?.lastSyncDirection
    await updateRagArtifactStatus(from: manifest, lastSyncedAt: lastSyncedAt, direction: lastSyncDirection)
  }

  func updateRagArtifactStatus(
    from manifest: RAGArtifactManifest,
    lastSyncedAt: Date?,
    direction: RAGArtifactSyncDirection?
  ) async {
    let staleInfo = await LocalRAGArtifacts.stalenessInfo(for: manifest)
    let status = RAGArtifactStatus(
      manifestVersion: manifest.version,
      totalBytes: manifest.totalBytes,
      lastSyncedAt: lastSyncedAt,
      lastSyncDirection: direction,
      repoCount: manifest.repos.count,
      lastIndexedAt: manifest.lastIndexedAt,
      staleReason: staleInfo.1
    )
    ragArtifactStatus = status
    SwarmCoordinator.shared.updateLocalRagArtifactStatus(status)
  }

  /// Delete a repository from the RAG index
  public func deleteRagRepo(repoId: String) async throws -> Int {
    print("[RAG] deleteRagRepo called with repoId=\(repoId)")
    let deleted = try await localRagStore.deleteRepo(repoId: repoId)
    print("[RAG] deleteRagRepo: localRagStore.deleteRepo returned \(deleted) files deleted")
    await refreshRagSummary()
    print("[RAG] deleteRagRepo: refreshRagSummary complete, ragRepos count=\(ragRepos.count)")
    return deleted
  }
  
  /// Index a repository (called from UI).
  ///
  /// When the repo already has embeddings from a different model (e.g. Qwen from swarm)
  /// and a swarm worker is connected, the reindex is dispatched to the swarm so the
  /// higher-quality model is preserved. A full artifact sync pull then brings the
  /// results back locally.
  func indexRagRepo(
    path: String,
    forceReindex: Bool = false,
    allowWorkspace: Bool = false,
    excludeSubrepos: Bool = true
  ) async throws {
    ragIndexingPath = path
    ragIndexProgress = nil
    markIndexingStarted(path: path)

    // Check if this repo uses a different embedding model (e.g. Qwen from swarm).
    let localModelName = ragStatus?.embeddingModelName
    let existingRepo = ragRepos.first(where: { $0.rootPath == path })
    let repoModel = existingRepo?.embeddingModel
    let isSwarmModel = repoModel != nil && localModelName != nil && repoModel != localModelName

    if isSwarmModel {
      let coordinator = SwarmCoordinator.shared
      if coordinator.isActive, !coordinator.connectedWorkers.isEmpty {
        do {
          try await dispatchReindexToSwarm(
            path: path, forceReindex: forceReindex,
            allowWorkspace: allowWorkspace, excludeSubrepos: excludeSubrepos,
            coordinator: coordinator
          )
          return
        } catch {
          ragIndexingPath = nil
          markIndexingStopped(path: path)
          ragIndexProgress = nil
          throw error
        }
      } else {
        // No swarm connected — can't regenerate with the swarm model.
        ragIndexingPath = nil
        markIndexingStopped(path: path)
        ragIndexProgress = nil
        throw RAGReindexError.swarmModelNoWorkers(
          repoModel: repoModel ?? "unknown",
          localModel: localModelName ?? "unknown"
        )
      }
    }

    // Models match (or repo is new) — local reindex.
    let task = Task {
      let report = try await localRagStore.indexRepository(
        path: path,
        forceReindex: forceReindex,
        allowWorkspace: allowWorkspace,
        excludeSubrepos: excludeSubrepos
      ) { [weak self] progress in
        Task { @MainActor in
          self?.ragIndexProgress = progress
        }
      }
      return report
    }
    ragIndexingTask = task

    do {
      let report = try await task.value
      ragIndexingTask = nil
      ragIndexingPath = nil
      markIndexingStopped(path: path)
      ragIndexProgress = .complete(report: report)
      lastRagIndexReport = report
      lastRagIndexAt = Date()
      await refreshRagSummary()
    } catch is CancellationError {
      ragIndexingTask = nil
      ragIndexingPath = nil
      markIndexingStopped(path: path)
      ragIndexProgress = nil
      // Indexing was cancelled - not an error
    } catch {
      ragIndexingTask = nil
      ragIndexingPath = nil
      markIndexingStopped(path: path)
      ragIndexProgress = nil
      throw error
    }
  }

  // MARK: - Swarm-Dispatched Reindex

  /// Dispatch reindex to a swarm worker that uses the repo's embedding model,
  /// then pull the results back via full artifact sync.
  private func dispatchReindexToSwarm(
    path: String,
    forceReindex: Bool,
    allowWorkspace: Bool,
    excludeSubrepos: Bool,
    coordinator: SwarmCoordinator
  ) async throws {
    guard let worker = coordinator.connectedWorkers.first else {
      throw RAGReindexError.swarmModelNoWorkers(repoModel: "unknown", localModel: "unknown")
    }

    logger.info("Dispatching reindex to swarm worker \(worker.name) for \(path)")

    // Build JSON-RPC payload to call rag.index on the remote worker's MCP server.
    let payload: [String: Any] = [
      "jsonrpc": "2.0", "id": 1, "method": "tools/call",
      "params": [
        "name": "rag.index",
        "arguments": [
          "repoPath": path,
          "forceReindex": forceReindex,
          "allowWorkspace": allowWorkspace,
          "excludeSubrepos": excludeSubrepos,
        ] as [String: Any],
      ] as [String: Any],
    ]
    let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
    let escapedJSON = payloadJSON.replacingOccurrences(of: "'", with: "'\\''")

    let script = [
      "set -e",
      "echo '[swarm-reindex] Pulling latest'",
      "git -C '\(path.replacingOccurrences(of: "'", with: "'\\''"))' pull --ff-only || git -C '\(path.replacingOccurrences(of: "'", with: "'\\''"))' pull || true",
      "echo '[swarm-reindex] Calling rag.index'",
      "RESPONSE=$(curl -sS -X POST http://127.0.0.1:8765/rpc -H 'Content-Type: application/json' -d '\(escapedJSON)')",
      "echo \"$RESPONSE\"",
      "if echo \"$RESPONSE\" | grep -q '\"error\"'; then",
      "  echo '[swarm-reindex] rag.index returned error' >&2; exit 2",
      "fi",
    ].joined(separator: "\n")

    let result = try await coordinator.sendDirectCommandAndWait(
      "/bin/zsh", args: ["-lc", script],
      workingDirectory: nil, to: worker.id,
      timeout: .seconds(420)
    )

    guard result.exitCode == 0 else {
      throw RAGReindexError.swarmReindexFailed(
        worker: worker.name,
        output: String(result.output.suffix(800))
      )
    }

    logger.info("Swarm reindex succeeded on \(worker.name), pulling artifacts back")

    // Pull the freshly-generated artifacts (embeddings + analysis) back via full sync.
    let repos = (try? await localRagStore.listRepos()) ?? []
    guard let repo = repos.first(where: { $0.rootPath == path }),
          let repoIdentifier = repo.repoIdentifier, !repoIdentifier.isEmpty else {
      logger.warning("Could not resolve repo identifier for \(path) after swarm reindex")
      ragIndexingPath = nil
      markIndexingStopped(path: path)
      await refreshRagSummary()
      return
    }

    let transferId = try await coordinator.requestRagArtifactSync(
      direction: .pull,
      repoIdentifier: repoIdentifier,
      transferMode: .full
    )
    logger.info("Post-swarm-reindex full sync requested for \(repoIdentifier): \(transferId)")

    ragIndexingPath = nil
    markIndexingStopped(path: path)
    lastRagIndexAt = Date()
    await refreshRagSummary()
  }
  
  /// Cancel any in-progress indexing
  func cancelRagIndexing() {
    if let path = ragIndexingPath { markIndexingStopped(path: path) }
    ragIndexingTask?.cancel()
    ragIndexingTask = nil
    ragIndexingPath = nil
    ragIndexProgress = nil
  }

  func listRepoGuidanceSkills(
    repoPath: String? = nil,
    repoRemoteURL: String? = nil,
    includeInactive: Bool = false,
    limit: Int? = nil
  ) -> [RepoGuidanceSkill] {
    dataService?.listRepoGuidanceSkills(
      repoPath: repoPath,
      repoRemoteURL: repoRemoteURL,
      includeInactive: includeInactive,
      limit: limit
    ) ?? []
  }

  @discardableResult
  func addRepoGuidanceSkill(
    repoPath: String,
    repoRemoteURL: String? = nil,
    repoName: String? = nil,
    title: String,
    body: String,
    source: String = "manual",
    tags: String = "",
    priority: Int = 0,
    isActive: Bool = true
  ) -> RepoGuidanceSkill? {
    let created = dataService?.addRepoGuidanceSkill(
      repoPath: repoPath,
      repoRemoteURL: repoRemoteURL,
      repoName: repoName,
      title: title,
      body: body,
      source: source,
      tags: tags,
      priority: priority,
      isActive: isActive
    )
    if created != nil {
      ragUsage.skillsAdded += 1
      ragUsage.lastSkillChangeAt = Date()
      appendRagEvent(
        kind: .skillAdded,
        title: "Skill added",
        detail: title.isEmpty ? repoPath : title
      )
      saveRagUsageStats()
    }
    return created
  }

  @discardableResult
  func updateRepoGuidanceSkill(
    id: UUID,
    repoPath: String? = nil,
    repoRemoteURL: String? = nil,
    repoName: String? = nil,
    title: String? = nil,
    body: String? = nil,
    source: String? = nil,
    tags: String? = nil,
    priority: Int? = nil,
    isActive: Bool? = nil
  ) -> RepoGuidanceSkill? {
    let updated = dataService?.updateRepoGuidanceSkill(
      id: id,
      repoPath: repoPath,
      repoRemoteURL: repoRemoteURL,
      repoName: repoName,
      title: title,
      body: body,
      source: source,
      tags: tags,
      priority: priority,
      isActive: isActive
    )
    if let updated {
      ragUsage.skillsUpdated += 1
      ragUsage.lastSkillChangeAt = Date()
      appendRagEvent(
        kind: .skillUpdated,
        title: "Skill updated",
        detail: updated.title.isEmpty ? updated.repoPath : updated.title
      )
      saveRagUsageStats()
    }
    return updated
  }

  @discardableResult
  public func deleteRepoGuidanceSkill(id: UUID) -> Bool {
    let deleted = dataService?.deleteRepoGuidanceSkill(id: id) ?? false
    if deleted {
      ragUsage.skillsDeleted += 1
      ragUsage.lastSkillChangeAt = Date()
      appendRagEvent(
        kind: .skillDeleted,
        title: "Skill deleted",
        detail: nil
      )
      saveRagUsageStats()
    }
    return deleted
  }
  
}
