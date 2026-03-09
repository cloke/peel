import AppKit
import Foundation
import Git
import MCPCore
import Network

// MARK: - Server Core
// Learning Loop, RAG operations, HTTP server, and run lifecycle

extension MCPServerService {
  // MARK: - Server Core (#210)
  
  func listLessons(repoPath: String, includeInactive: Bool, limit: Int?) async throws -> [LocalRAGLesson] {
    try await localRagStore.listLessons(repoPath: repoPath, includeInactive: includeInactive, limit: limit ?? 50)
  }
  
  func addLesson(
    repoPath: String,
    filePattern: String?,
    errorSignature: String?,
    fixDescription: String,
    fixCode: String?,
    source: String
  ) async throws -> LocalRAGLesson {
    let lesson = try await localRagStore.addLesson(
      repoPath: repoPath,
      filePattern: filePattern,
      errorSignature: errorSignature,
      fixDescription: fixDescription,
      fixCode: fixCode,
      source: source
    )
    appendRagEvent(
      kind: .lessonAdded,
      title: "Lesson added",
      detail: fixDescription
    )
    return lesson
  }
  
  func queryLessons(
    repoPath: String,
    filePattern: String?,
    errorSignature: String?,
    limit: Int
  ) async throws -> [LocalRAGLesson] {
    try await localRagStore.queryLessons(
      repoPath: repoPath,
      filePattern: filePattern,
      errorSignature: errorSignature,
      limit: limit
    )
  }
  
  func updateLesson(
    id: String,
    fixDescription: String?,
    fixCode: String?,
    confidence: Double?,
    isActive: Bool?
  ) async throws -> LocalRAGLesson? {
    try await localRagStore.updateLesson(
      lessonId: id,
      fixDescription: fixDescription,
      fixCode: fixCode,
      confidence: confidence,
      isActive: isActive
    )
    // Re-fetch the updated lesson to return it
    if let updated = try await localRagStore.getLesson(lessonId: id) {
      appendRagEvent(
        kind: .lessonUpdated,
        title: "Lesson updated",
        detail: updated.fixDescription
      )
      return updated
    }
    return nil
  }
  
  func deleteLesson(id: String) async throws -> Bool {
    do {
      try await localRagStore.deleteLesson(lessonId: id)
      appendRagEvent(
        kind: .lessonDeleted,
        title: "Lesson deleted",
        detail: id
      )
      return true
    } catch {
      return false
    }
  }
  
  func recordLessonApplied(id: String, success: Bool) async throws {
    try await localRagStore.recordLessonUsed(lessonId: id, success: success)
    if success {
      appendRagEvent(
        kind: .lessonApplied,
        title: "Lesson applied",
        detail: "Confidence increased for lesson \(id.prefix(8))..."
      )
    } else {
      appendRagEvent(
        kind: .lessonApplied,
        title: "Lesson not helpful",
        detail: "Confidence decreased for lesson \(id.prefix(8))..."
      )
    }
  }

  func clearMCPRunHistory() {
    dataService?.clearMCPRunHistory()
    sessionTracker.resetSession()
  }

  func buildRepoGuidance(repoPath: String) async -> String? {
    var sections: [String] = []
    if let dataService {
      // Auto-seed Ember skills if this is an Ember project (Issue #263)
      let seededCount = await MainActor.run {
        DefaultSkillsService.autoSeedEmberSkillsIfNeeded(context: dataService.modelContext, repoPath: repoPath)
      }
      if seededCount > 0 {
        await telemetryProvider.info("Auto-seeded Ember skills", metadata: [
          "repoPath": repoPath,
          "skillsAdded": "\(seededCount)"
        ])
      }

      let repoRemoteURL = await RepoRegistry.shared.registerRepo(at: repoPath)
      if let (skillsBlock, skills) = dataService.repoGuidanceSkillsBlock(
        repoPath: repoPath,
        repoRemoteURL: repoRemoteURL
      ) {
        sections.append(skillsBlock)
        dataService.markRepoGuidanceSkillsApplied(skills)
      }
    }

    let queries = [
      ".rubocop.yml",
      "rubocop",
      ".eslintrc",
      "eslint",
      "ruff",
      "flake8",
      "pyproject.toml lint",
      "swiftlint",
      "prettier",
      "style guide",
      "lint"
    ]
    var snippets: [LocalRAGSearchResult] = []
    for query in queries {
      do {
        let results = try await localRagStore.search(query: query, repoPath: repoPath, limit: 2)
        snippets.append(contentsOf: results)
      } catch {
        await telemetryProvider.warning("Repo guidance search failed", metadata: [
          "query": query,
          "error": error.localizedDescription
        ])
      }
    }

    let unique = Dictionary(grouping: snippets, by: { $0.filePath })
      .compactMap { $0.value.first }
      .prefix(4)
    if !unique.isEmpty {
      let guidance = unique.map { result in
        let header = "- Follow repo lint/style rules in \(result.filePath)"
        let snippet = result.snippet
          .split(separator: "\n")
          .prefix(8)
          .joined(separator: "\n")
        return "\(header)\n\n\(snippet)"
      }.joined(separator: "\n\n")
      sections.append("## Repo Guidance\n\n\(guidance)")
    }

    guard !sections.isEmpty else { return nil }
    return sections.joined(separator: "\n\n")
  }

  func initializeRag(extensionPath: String? = nil) async throws {
    let status = try await localRagStore.initialize(extensionPath: extensionPath)
    ragStatus = status
    ragStats = try await localRagStore.stats()
    lastRagError = nil
    lastRagRefreshAt = Date()
  }

  func applyRagEmbeddingSettings() async {
    localRagStore = makeDefaultRAGStore()
    parallelWorktreeRunner?.setRAGStore(localRagStore)
    ragIndexingPath = nil
    ragIndexProgress = nil
    ragStatus = await localRagStore.status()
    ragStats = try? await localRagStore.stats()
    lastRagError = nil
    lastRagRefreshAt = Date()
    await refreshRagSummary()
  }

  func indexRag(repoPath: String) async throws -> LocalRAGIndexReport {
    let report = try await localRagStore.indexRepository(
      path: repoPath,
      allowWorkspace: false,
      excludeSubrepos: true,
      progress: nil
    )
    ragStatus = await localRagStore.status()
    ragStats = try await localRagStore.stats()
    ragUsage.indexRuns += 1
    ragUsage.lastIndexAt = Date()
    lastRagIndexReport = report
    lastRagIndexAt = Date()
    let skipInfo = report.filesSkipped > 0 ? " (\(report.filesSkipped) unchanged)" : ""
    appendRagEvent(
      kind: .index,
      title: "Indexed \(report.filesIndexed) files\(skipInfo) · \(report.chunksIndexed) chunks",
      detail: report.repoPath
    )
    lastRagError = nil
    lastRagRefreshAt = Date()
    saveRagUsageStats()
    return report
  }

  func searchRag(
    query: String,
    mode: RAGSearchMode,
    repoPath: String? = nil,
    limit: Int = 10,
    matchAll: Bool = true
  ) async throws -> [LocalRAGSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let results = try await runRagSearch(
      query: trimmedQuery,
      mode: mode,
      repoPath: repoPath,
      limit: limit,
      matchAll: matchAll,
      recordHints: true
    )
    ragUsage.searches += 1
    ragUsage.totalResults += results.count
    if results.isEmpty {
      ragUsage.emptySearches += 1
    }
    switch mode {
    case .text:
      ragUsage.textSearches += 1
    case .vector:
      ragUsage.vectorSearches += 1
    case .hybrid:
      ragUsage.textSearches += 1
      ragUsage.vectorSearches += 1
    }
    ragUsage.lastSearchAt = Date()
    if !results.isEmpty {
      await refreshRagQueryHints(query: trimmedQuery, repoPath: repoPath, mode: mode, resultCount: results.count)
    }
    appendRagEvent(
      kind: .search,
      title: "Search · \(results.count) results",
      detail: trimmedQuery
    )
    lastRagSearchQuery = trimmedQuery
    lastRagSearchMode = mode
    lastRagSearchRepoPath = repoPath
    lastRagSearchLimit = limit
    lastRagSearchAt = Date()
    lastRagSearchResults = results
    lastRagError = nil
    saveRagUsageStats()
    return results
  }

  func ragQueryHints(limit: Int? = 10) -> [RAGQueryHint] {
    let hints = ragQueryHints.sorted { $0.lastUsedAt > $1.lastUsedAt }
    guard let limit, limit > 0 else { return hints }
    return Array(hints.prefix(limit))
  }

  func refreshRagQueryHints() async {
    await refreshRagQueryHints(query: nil, repoPath: nil, mode: nil, resultCount: nil)
  }

  func runRagSearch(
    query: String,
    mode: RAGSearchMode,
    repoPath: String?,
    limit: Int,
    matchAll: Bool,
    recordHints: Bool,
    modulePath: String? = nil
  ) async throws -> [LocalRAGSearchResult] {
    let results: [LocalRAGSearchResult]
    switch mode {
    case .vector:
      results = try await vectorSearchWithDimensionCheck(
        query: query, repoPath: repoPath, limit: limit, modulePath: modulePath
      )
    case .text:
      results = try await localRagStore.search(query: query, repoPath: repoPath, limit: limit, matchAll: matchAll, modulePath: modulePath)
    case .hybrid:
      // Run text + vector concurrently, merge via Reciprocal Rank Fusion (k=60)
      async let textSearch = localRagStore.search(query: query, repoPath: repoPath, limit: limit, matchAll: matchAll, modulePath: modulePath)
      async let vectorSearch = vectorSearchWithDimensionCheck(
        query: query, repoPath: repoPath, limit: limit, modulePath: modulePath
      )
      let (textRes, vectorRes) = try await (textSearch, vectorSearch)
      var rrfScores: [String: Float] = [:]
      var rrfLookup: [String: LocalRAGSearchResult] = [:]
      for (rank, r) in textRes.enumerated() {
        let key = "\(r.filePath):\(r.startLine)"
        rrfScores[key, default: 0] += 1.0 / (60 + Float(rank + 1))
        if rrfLookup[key] == nil { rrfLookup[key] = r }
      }
      for (rank, r) in vectorRes.enumerated() {
        let key = "\(r.filePath):\(r.startLine)"
        rrfScores[key, default: 0] += 1.0 / (60 + Float(rank + 1))
        if rrfLookup[key] == nil { rrfLookup[key] = r }
      }
      results = rrfScores
        .sorted { $0.value > $1.value }
        .prefix(limit)
        .compactMap { rrfLookup[$0.key] }
    }
    if recordHints, !results.isEmpty {
      do {
        try await localRagStore.recordQueryHint(
          query: query,
          resultCount: results.count,
          searchMode: mode.rawValue
        )
      } catch {
        await telemetryProvider.warning("RAG query hint insert failed", metadata: ["error": error.localizedDescription])
      }
    }
    return results
  }

  /// Vector search with automatic dimension mismatch handling.
  ///
  /// If the stored embeddings for the target repo use different dimensions
  /// than the default provider (e.g. 768d nomic vs 1024d qwen pulled from
  /// Mac Studio), this method creates a temporary provider matching the
  /// stored dimensions and uses `searchVectorWithEmbedding` to supply the
  /// correctly-dimensioned query vector.
  private func vectorSearchWithDimensionCheck(
    query: String,
    repoPath: String?,
    limit: Int,
    modulePath: String?
  ) async throws -> [LocalRAGSearchResult] {
    #if os(macOS)
    let status = await localRagStore.status()
    let providerDims = status.embeddingDimensions
    let providerModel = status.embeddingModelName.lowercased()
    let repos = (try? await localRagStore.listRepos()) ?? []
    let sampledDims = await localRagStore.embeddingDimensionsByRepo()

    func normalizedModel(_ model: String?) -> String? {
      model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func isProviderCompatible(repoModel: String?, repoDims: Int?) -> Bool {
      let dimsMatch = repoDims == nil || repoDims == providerDims
      guard dimsMatch else { return false }
      guard let repoModel = normalizedModel(repoModel), !repoModel.isEmpty else { return true }
      return repoModel == providerModel
    }

    func vectorFor(repoModel: String?, repoDims: Int, cache: inout [String: [Float]]) async throws -> [Float]? {
      let modelKey = normalizedModel(repoModel) ?? ""
      let cacheKey = "\(modelKey)|\(repoDims)"
      if let cached = cache[cacheKey] { return cached }

      let config: MLXEmbeddingModelConfig?
      if let model = normalizedModel(repoModel) {
        config = MLXEmbeddingModelConfig.availableModels.first {
          $0.huggingFaceId.lowercased() == model || $0.name.lowercased() == model
        } ?? MLXEmbeddingModelConfig.availableModels.first { $0.dimensions == repoDims }
      } else {
        config = MLXEmbeddingModelConfig.availableModels.first { $0.dimensions == repoDims }
      }

      guard let config else { return nil }

      await telemetryProvider.info(
        "RAG using per-repo embedding profile for query",
        metadata: [
          "model": config.huggingFaceId,
          "dimensions": "\(config.dimensions)",
        ]
      )
      let provider = MLXEmbeddingProvider(config: config)
      let embeddings = try await provider.embed(texts: [query])
      guard let queryVector = embeddings.first, !queryVector.isEmpty else { return nil }
      cache[cacheKey] = queryVector
      return queryVector
    }

    func searchRepo(_ repo: LocalRAGStore.RepoInfo, vectorCache: inout [String: [Float]]) async throws -> [LocalRAGSearchResult] {
      let repoDims = sampledDims[repo.id]
      if isProviderCompatible(repoModel: nil, repoDims: repoDims) {
        return try await localRagStore.searchVector(query: query, repoPath: repo.rootPath, limit: limit, modulePath: modulePath)
      }

      guard let dims = repoDims,
            let queryVector = try await vectorFor(repoModel: nil, repoDims: dims, cache: &vectorCache) else {
        await telemetryProvider.warning(
          "No compatible local query embedding model for repo profile; falling back to text search",
          metadata: [
            "repoPath": repo.rootPath,
            "repoDims": "\(repoDims ?? -1)",
          ]
        )
        return try await localRagStore.search(query: query, repoPath: repo.rootPath, limit: limit, matchAll: true, modulePath: modulePath)
      }

      return try await localRagStore.searchVectorWithEmbedding(queryVector, repoPath: repo.rootPath, limit: limit, modulePath: modulePath)
    }

    if let repoPath {
      if let targetRepo = repos.first(where: { $0.rootPath == repoPath }) {
        var singleRepoVectorCache: [String: [Float]] = [:]
        return try await searchRepo(targetRepo, vectorCache: &singleRepoVectorCache)
      }
      return try await localRagStore.searchVector(query: query, repoPath: repoPath, limit: limit, modulePath: modulePath)
    }

    var vectorCache: [String: [Float]] = [:]
    var aggregated: [LocalRAGSearchResult] = []

    for repo in repos {
      // Skip repos without embeddings entirely
      let hasEmbeddings = sampledDims[repo.id] != nil
      guard hasEmbeddings else { continue }
      let repoResults = try await searchRepo(repo, vectorCache: &vectorCache)
      aggregated.append(contentsOf: repoResults)
    }

    if aggregated.isEmpty {
      return try await localRagStore.search(query: query, repoPath: nil, limit: limit, matchAll: true, modulePath: modulePath)
    }

    var deduped: [String: LocalRAGSearchResult] = [:]
    for result in aggregated {
      let key = "\(result.filePath):\(result.startLine)-\(result.endLine)"
      if let existing = deduped[key] {
        let existingScore = existing.score ?? -1
        let resultScore = result.score ?? -1
        if resultScore > existingScore {
          deduped[key] = result
        }
      } else {
        deduped[key] = result
      }
    }

    return deduped.values
      .sorted { ($0.score ?? -1) > ($1.score ?? -1) }
      .prefix(limit)
      .map { $0 }
    #else
    // iOS: no MLX, use default provider directly
    return try await localRagStore.searchVector(query: query, repoPath: repoPath, limit: limit, modulePath: modulePath)
    #endif
  }

  private func refreshRagQueryHints(query: String?, repoPath: String?, mode: RAGSearchMode?, resultCount: Int?) async {
    do {
      if let query, let mode, let resultCount {
        try await localRagStore.recordQueryHint(query: query, resultCount: resultCount, searchMode: mode.rawValue)
      }
      let hints = try await localRagStore.fetchQueryHints(limit: 25)
      ragQueryHints = hints.map {
        RAGQueryHint(
          query: $0.query,
          repoPath: nil,
          mode: RAGSearchMode(rawValue: $0.searchMode) ?? .text,
          resultCount: $0.resultCount,
          useCount: 0,
          lastUsedAt: Date()
        )
      }
    } catch {
      await telemetryProvider.warning("RAG query hints refresh failed", metadata: ["error": error.localizedDescription])
    }
  }

  func recordRagUserAction(_ action: RAGUserAction, result: LocalRAGSearchResult? = nil) {
    let now = Date()
    switch action {
    case .copyPath, .copySnippet:
      ragUsage.copyCount += 1
      ragUsage.lastCopyAt = now
      appendRagEvent(
        kind: .copy,
        title: "Snippet copied",
        detail: result?.filePath
      )
    case .openFile:
      ragUsage.openCount += 1
      ragUsage.lastOpenAt = now
      appendRagEvent(
        kind: .open,
        title: "Opened file",
        detail: result?.filePath
      )
    case .markHelpful:
      ragUsage.helpfulCount += 1
      ragUsage.lastHelpfulAt = now
      appendRagEvent(
        kind: .helpful,
        title: "Marked helpful",
        detail: result?.filePath
      )
    case .markIrrelevant:
      ragUsage.irrelevantCount += 1
      ragUsage.lastIrrelevantAt = now
      appendRagEvent(
        kind: .irrelevant,
        title: "Marked not useful",
        detail: result?.filePath
      )
    }
    saveRagUsageStats()
  }
  
  /// Records AI analysis session completion for persistent tracking
  func recordAnalysisSession(chunksAnalyzed: Int, durationSeconds: Double) {
    ragUsage.analysisRuns += 1
    ragUsage.chunksAnalyzedTotal += chunksAnalyzed
    ragUsage.totalAnalysisTimeSeconds += durationSeconds
    ragUsage.lastAnalysisAt = Date()
    appendRagEvent(
      kind: .index,  // Reuse index kind for analysis
      title: "AI analysis completed",
      detail: "\(chunksAnalyzed) chunks in \(formatDuration(durationSeconds))"
    )
    saveRagUsageStats()
  }
  
  private func formatDuration(_ seconds: Double) -> String {
    if seconds < 60 {
      return "\(Int(seconds))s"
    } else if seconds < 3600 {
      let mins = Int(seconds / 60)
      let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
      return "\(mins)m \(secs)s"
    } else {
      let hours = Int(seconds / 3600)
      let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
      return "\(hours)h \(mins)m"
    }
  }

  func appendRagEvent(kind: RAGSessionEvent.Kind, title: String, detail: String?) {
    let event = RAGSessionEvent(timestamp: Date(), title: title, detail: detail, kind: kind)
    ragSessionEvents.insert(event, at: 0)
    if ragSessionEvents.count > 50 {
      ragSessionEvents.removeLast(ragSessionEvents.count - 50)
    }
    saveRagSessionEvents()
  }

  private func buildRagContext(query: String, repoPath: String) async -> String? {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return nil }

    do {
      let results = try await searchRag(
        query: trimmedQuery,
        mode: localRagSearchMode,
        repoPath: repoPath,
        limit: localRagSearchLimit
      )
      guard !results.isEmpty else { return nil }

      let snippets = results.map { result in
        "- \(result.filePath) [\(result.startLine)-\(result.endLine)]:\n\(result.snippet)"
      }
      return ([
        "Local RAG context for: \"\(trimmedQuery)\"",
        snippets.joined(separator: "\n\n")
      ]).joined(separator: "\n")
    } catch {
      await telemetryProvider.warning("Local RAG context build failed", metadata: ["error": error.localizedDescription])
      return nil
    }
  }

  public struct RunOverrides {
    public var enableReviewLoop: Bool? = nil
    public var pauseOnReview: Bool? = nil
    public var enablePrePlanner: Bool? = nil  // Issue #133
    public var allowPlannerModelSelection: Bool = false
    public var allowImplementerModelOverride: Bool = false
    public var allowPlannerImplementerScaling: Bool = false
    public var maxImplementers: Int? = nil
    public var maxPremiumCost: Double? = nil
    public var priority: Int = 0
    public var timeoutSeconds: Double? = nil
    public var requireRagUsage: Bool? = nil

    public init() {}
  }

  public func pauseRun(_ runId: UUID) async {
    if let chain = activeRunChains[runId] {
      await chainRunner.pause(chainId: chain.id)
    }
  }

  public func resumeRun(_ runId: UUID) async {
    if let chain = activeRunChains[runId] {
      await chainRunner.resume(chainId: chain.id)
    }
  }

  public func stepRun(_ runId: UUID) async {
    if let chain = activeRunChains[runId] {
      await chainRunner.step(chainId: chain.id)
    }
  }

  public func stopRun(_ runId: UUID) async {
    if let task = activeChainTasks[runId] {
      task.cancel()
    }
  }

  public func cancelQueuedRun(_ runId: UUID) async -> Bool {
    return cancelQueuedRunInternal(runId: runId)
  }

  func rerun(_ record: MCPRunRecord, overrides: RunOverrides = RunOverrides()) async {
    var arguments: [String: Any] = [
      "templateName": record.templateName,
      "prompt": record.prompt,
    ]
    if let workingDir = record.workingDirectory, !workingDir.isEmpty {
      arguments["workingDirectory"] = workingDir
    }
    if let enableReviewLoop = overrides.enableReviewLoop {
      arguments["enableReviewLoop"] = enableReviewLoop
    }
    if let pauseOnReview = overrides.pauseOnReview {
      arguments["pauseOnReview"] = pauseOnReview
    }
    if let enablePrePlanner = overrides.enablePrePlanner {
      arguments["enablePrePlanner"] = enablePrePlanner
    }
    arguments["allowPlannerModelSelection"] = overrides.allowPlannerModelSelection
    arguments["allowImplementerModelOverride"] = overrides.allowImplementerModelOverride
    arguments["allowPlannerImplementerScaling"] = overrides.allowPlannerImplementerScaling
    if let maxImplementers = overrides.maxImplementers {
      arguments["maxImplementers"] = maxImplementers
    }
    if let maxPremiumCost = overrides.maxPremiumCost {
      arguments["maxPremiumCost"] = maxPremiumCost
    }
    if overrides.priority != 0 {
      arguments["priority"] = overrides.priority
    }
    if let timeoutSeconds = overrides.timeoutSeconds {
      arguments["timeoutSeconds"] = timeoutSeconds
    }
    if let requireRagUsage = overrides.requireRagUsage {
      arguments["requireRagUsage"] = requireRagUsage
    }
    _ = await handleChainRun(id: nil, arguments: arguments)
  }

  public func cleanupWorktrees(paths: [String]) async {
    guard !paths.isEmpty else { return }
    for path in paths {
      guard let workspace = agentManager.workspaceManager.workspaces.first(where: { $0.path.path == path }) else {
        continue
      }
      let repository = Model.Repository(
        name: workspace.parentRepositoryPath.lastPathComponent,
        path: workspace.parentRepositoryPath.path
      )
      let branch = workspace.branch
      try? await agentManager.workspaceManager.cleanupWorkspace(workspace, force: true)
      if !branch.isEmpty {
        _ = try? await Commands.simple(arguments: ["branch", "-D", branch], in: repository)
      }
    }
  }

  public func start() {
    guard !isRunning else { return }
    lastError = nil

    guard port >= 1024 && port <= 65535 else {
      lastError = "Port must be between 1024 and 65535"
      return
    }

    do {
      let portValue = NWEndpoint.Port(rawValue: UInt16(port))
      guard let portValue else {
        lastError = "Invalid port"
        return
      }

      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      let listener = try NWListener(using: parameters, on: portValue)

      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        Task { @MainActor in
          switch state {
          case .ready:
            self.isRunning = true
            self.lastError = nil
          case .failed(let error):
            self.lastError = error.localizedDescription
            self.isRunning = false
          default:
            break
          }
        }
      }

      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in
          self?.handleConnection(connection)
        }
      }

      listener.start(queue: listenerQueue)
      self.listener = listener
    } catch {
      lastError = error.localizedDescription
      isRunning = false
    }
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    for connection in connections.values {
      connection.cancel()
    }
    connections = [:]
    connectionStates = [:]
    isRunning = false
  }

  private func handleConnection(_ connection: NWConnection) {
    // In LAN mode, accept all connections; otherwise only localhost
    guard lanModeEnabled || isLocalConnection(connection) else {
      connection.cancel()
      return
    }

    let id = UUID()
    connections[id] = connection
    connectionStates[id] = ConnectionState()

    connection.stateUpdateHandler = { [weak self] state in
      guard case .failed = state else { return }
      Task { @MainActor in
        self?.closeConnection(id)
      }
    }

    connection.start(queue: listenerQueue)
    receive(on: connection, id: id)
  }

  private func receive(on connection: NWConnection, id: UUID) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      Task { @MainActor in
        guard let self else { return }
        if let data, !data.isEmpty {
          self.connectionStates[id]?.buffer.append(data)
          self.processBuffer(for: id, connection: connection)
        }

        if isComplete || error != nil {
          self.closeConnection(id)
        } else {
          self.receive(on: connection, id: id)
        }
      }
    }
  }

  private func processBuffer(for id: UUID, connection: NWConnection) {
    guard var state = connectionStates[id] else { return }
    if let request = parseRequest(from: &state.buffer) {
      connectionStates[id] = state
      handleRequest(request, on: connection)
    } else {
      connectionStates[id] = state
    }
  }

  private func closeConnection(_ id: UUID) {
    connections[id]?.cancel()
    connections[id] = nil
    connectionStates[id] = nil
  }

  private func isLocalConnection(_ connection: NWConnection) -> Bool {
    switch connection.endpoint {
    case .hostPort(let host, _):
      switch host {
      case .ipv4(let address):
        return address == IPv4Address("127.0.0.1")
      case .ipv6(let address):
        return address == IPv6Address("::1")
      case .name(let name, _):
        return name == "localhost"
      default:
        return false
      }
    default:
      return false
    }
  }

  private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }

  private func parseRequest(from buffer: inout Data) -> HTTPRequest? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerRange = buffer.range(of: delimiter) else { return nil }

    let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

    let lines = headerText.split(separator: "\r\n")
    guard let requestLine = lines.first else { return nil }

    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else { return nil }

    let method = String(requestParts[0])
    let path = String(requestParts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      if let separatorIndex = line.firstIndex(of: ":") {
        let key = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
        headers[key.lowercased()] = value
      }
    }

    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = headerRange.upperBound
    let totalLength = bodyStart + contentLength
    guard buffer.count >= totalLength else { return nil }

    let body = buffer.subdata(in: bodyStart..<totalLength)
    buffer.removeSubrange(0..<totalLength)

    return HTTPRequest(method: method, path: path, headers: headers, body: body)
  }

  private func handleRequest(_ request: HTTPRequest, on connection: NWConnection) {
    guard request.method.uppercased() == "POST", request.path == "/rpc" else {
      sendHTTPResponse(status: 404, body: Data("{\"error\":\"Not Found\"}".utf8), on: connection)
      return
    }

    Task {
      let (_, responseBody) = await handleRPC(body: request.body)
      // JSON-RPC spec: Always return HTTP 200 for valid JSON-RPC responses.
      // Error information is in the JSON body, not the HTTP status.
      // Using HTTP 4xx/5xx causes VS Code MCP client to kill the connection.
      sendHTTPResponse(status: 200, body: responseBody, on: connection)
    }
  }

  private func handleRPC(body: Data) async -> (Int, Data) {
    let startTime = Date()
    var methodForLog = "unknown"
    var statusCode = 500
    defer {
      let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
      Task { await telemetryProvider.info("RPC complete", metadata: [
        "method": methodForLog,
        "durationMs": "\(durationMs)",
        "status": "\(statusCode)"
      ]) }
    }
    activeRequests += 1
    defer { activeRequests -= 1 }
    do {
      let json = try JSONSerialization.jsonObject(with: body, options: [])
      guard let dict = json as? [String: Any] else {
        await telemetryProvider.warning("Invalid RPC request: non-object JSON", metadata: [:])
        methodForLog = "invalid"
        statusCode = 400
        return (400, JSONRPCResponseBuilder.makeError(id: nil, code: -32600, message: "Invalid Request"))
      }

      let method = dict["method"] as? String ?? ""
      let id = dict["id"]
      let params = dict["params"] as? [String: Any]
      lastRequestAt = Date()
      if method == "tools/call",
         let params,
         let toolName = params["name"] as? String {
        lastRequestMethod = "tools/call: \(toolName)"
        methodForLog = "tools/call: \(toolName)"
      } else {
        lastRequestMethod = method
        methodForLog = method
      }

      switch method {
      case "initialize", "mcp/initialize":
        let result: [String: Any] = [
          "protocolVersion": "2024-11-05",
          "serverInfo": ["name": "Peel MCP Server", "version": "0.1"],
          "capabilities": ["tools": ["listChanged": true]]
        ]
        statusCode = 200
        return (200, JSONRPCResponseBuilder.makeResult(id: id, result: result))

      case "initialized", "notifications/initialized":
        statusCode = 200
        return (200, Data())

      // Handle common MCP notifications (no response expected)
      case "notifications/cancelled", "cancelled",
           "notifications/progress", "progress",
           "notifications/message", "message",
           "$/cancelRequest", "$/progress":
        // Notifications don't require a response
        statusCode = 200
        return (200, Data())

      case "tools/list":
        statusCode = 200
        let cursor = params?["cursor"] as? String
        return (200, JSONRPCResponseBuilder.makeResult(id: id, result: paginatedToolList(cursor: cursor)))

      case "tools/call":
        let result = await handleToolCall(id: id, params: params)
        statusCode = result.0
        return result

      default:
        await telemetryProvider.warning("RPC method not found", metadata: ["method": method, "hasId": String(describing: id != nil)])
        // For notifications (id=null), just acknowledge - don't error
        if id == nil {
          statusCode = 200
          return (200, Data())
        }
        statusCode = 400
        return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32601, message: "Method not found"))
      }
    } catch {
      await telemetryProvider.error(error, context: "RPC handling failed", metadata: [:])
      statusCode = 500
      return (500, JSONRPCResponseBuilder.makeError(id: nil, code: -32603, message: error.localizedDescription))
    }
  }

  private func handleToolCall(id: Any?, params: [String: Any]?) async -> (Int, Data) {
    guard let params, let name = params["name"] as? String else {
      await telemetryProvider.warning("Invalid tool call params", metadata: [:])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Invalid params"))
    }

    guard let resolvedName = resolveToolName(name),
          let tool = toolDefinition(named: resolvedName) else {
      await telemetryProvider.warning("Unknown tool", metadata: ["name": name])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32601, message: "Unknown tool"))
    }

    if tool.requiresForeground && !allowForegroundTools {
      await telemetryProvider.warning("Foreground tool disabled", metadata: ["name": resolvedName])
      lastBlockedTool = resolvedName
      lastBlockedToolAt = Date()
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32010, message: "Tool disabled in headless mode"))
    }

    lastToolRequiresForeground = tool.requiresForeground
    lastToolRequiresForegroundAt = Date()

    if tool.requiresForeground && !NSApp.isActive {
      await telemetryProvider.warning("Foreground tool called while app inactive", metadata: ["name": tool.name])
      recordUIActionForegroundNeeded(tool.name)
    }

    if !isToolEnabled(resolvedName) {
      await telemetryProvider.warning("Tool disabled", metadata: ["name": resolvedName, "category": tool.category.rawValue])
      lastBlockedTool = resolvedName
      lastBlockedToolAt = Date()
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32010, message: "Tool disabled"))
    }

    let arguments = params["arguments"] as? [String: Any] ?? [:]

    // Delegate to extracted tool handlers first
    if uiToolsHandler.supportedTools.contains(resolvedName) {
      return await uiToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if vmToolsHandler.supportedTools.contains(resolvedName) {
      return await vmToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if parallelToolsHandler.supportedTools.contains(resolvedName) {
      return await parallelToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if ragToolsHandler?.supportedTools.contains(resolvedName) == true {
      return await ragToolsHandler!.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if codeEditToolsHandler?.supportedTools.contains(resolvedName) == true {
      return await codeEditToolsHandler!.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if chainToolsHandler?.supportedTools.contains(resolvedName) == true {
      return await chainToolsHandler!.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if swarmToolsHandler.supportedTools.contains(resolvedName) {
      return await swarmToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if repoToolsHandler.supportedTools.contains(resolvedName) {
      return await repoToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if worktreeToolsHandler.supportedTools.contains(resolvedName) {
      return await worktreeToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if githubToolsHandler?.supportedTools.contains(resolvedName) == true {
      return await githubToolsHandler!.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if terminalToolsHandler.supportedTools.contains(resolvedName) {
      return await terminalToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if chromeToolsHandler.supportedTools.contains(resolvedName) {
      return await chromeToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if repoProfileToolsHandler.supportedTools.contains(resolvedName) {
      return await repoProfileToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if gitToolsHandler.supportedTools.contains(resolvedName) {
      return await gitToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if codeQualityToolsHandler.supportedTools.contains(resolvedName) {
      return await codeQualityToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if prReviewToolsHandler.supportedTools.contains(resolvedName) {
      return await prReviewToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    #if os(macOS)
    if localChatToolsHandler?.supportedTools.contains(resolvedName) == true {
      return await localChatToolsHandler!.handle(name: resolvedName, id: id, arguments: arguments)
    }
    #endif

    // Fall through to inline handlers (to be extracted in future)
    switch resolvedName {
    // UI tools are now handled by UIToolsHandler above

    case "state.get":
      return handleStateGet(id: id)

    case "state.readonly":
      return handleStateGet(id: id)

    case "state.list":
      return handleStateList(id: id)

    case "tools.search":
      return handleToolsSearch(id: id, arguments: arguments)

    case "tools.categories":
      return handleToolsCategories(id: id)

    // RAG tools are now handled by RAGToolsHandler above
    // Chain tools are now handled by ChainToolsHandler above

    case "workspaces.agent.list":
      return handleAgentWorkspacesList(id: id, arguments: arguments)

    case "workspaces.agent.cleanup.status":
      return handleAgentWorkspacesCleanupStatus(id: id)

    case "logs.mcp.path":
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["path": await telemetryProvider.logPath()]))

    case "logs.mcp.tail":
      let lines = arguments["lines"] as? Int ?? 200
      let text = await telemetryProvider.tail(lines: lines)
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["text": text]))

    // VM tools are now handled by VMToolsHandler above

    case "server.restart":
      return await handleServerRestart(id: id)

    case "server.port.set":
      return await handleServerPortSet(id: id, arguments: arguments)

    case "server.status":
      return handleServerStatus(id: id)

    case "server.sleep.prevent":
      return handleServerSleepPreventionSet(id: id, arguments: arguments)

    case "server.sleep.prevent.status":
      return handleServerSleepPreventionStatus(id: id)

    case "server.lan":
      return handleServerLanModeSet(id: id, arguments: arguments)

    case "server.stop":
      stop()
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["status": "stopped"]))

    case "app.quit":
      scheduleAppQuit()
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["status": "quitting"]))

    case "app.activate":
      activateApp()
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["status": "activated"]))

    case "screenshot.capture":
      let label = arguments["label"] as? String
      let requestedOutputDir = arguments["outputDir"] as? String
      let outputDir: String?
    #if DEBUG
      if let requestedOutputDir, !requestedOutputDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        outputDir = requestedOutputDir
      } else {
        outputDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("KitchenSync/Screenshots")
      }
    #else
      outputDir = requestedOutputDir
    #endif
      do {
        let url = try await screenshotService.capture(label: label, outputDir: outputDir)
        return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["path": url.path]))
      } catch {
        await telemetryProvider.warning("Screenshot tool failed", metadata: ["error": error.localizedDescription])
        return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
      }

    case "translations.validate":
      return await handleTranslationsValidate(id: id, arguments: arguments)

    case "docling.convert":
      return await handleDoclingConvert(id: id, arguments: arguments)

    case "docling.setup":
      return await handleDoclingSetup(id: id, arguments: arguments)

    case "pii.scrub":
      return await handlePIIScrub(id: id, arguments: arguments)

    // Parallel tools are now handled by ParallelToolsHandler

    default:
      await telemetryProvider.warning("Unknown tool", metadata: ["name": name])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32601, message: "Unknown tool"))
    }
  }

  // UI tool handlers moved to UIToolsHandler.swift (#158)

  private func handleStateGet(id: Any?) -> (Int, Data) {
    let showArchived = UserDefaults.standard.bool(forKey: "github-show-archived")
    let brewSource = UserDefaults.standard.string(forKey: "brew.source")
    let brewSearch = UserDefaults.standard.string(forKey: "brew.searchText")
    let workspaceName = UserDefaults.standard.string(forKey: "workspaces.selectedWorkspaceName")
    let repoName = UserDefaults.standard.string(forKey: "workspaces.selectedRepoName")
    let worktreePath = UserDefaults.standard.string(forKey: "workspaces.selectedWorktreePath")
    let worktreeName = UserDefaults.standard.string(forKey: "workspaces.selectedWorktreeName")
    let workspaceNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableNames")
    let repoNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableRepoNames")
    let worktreePaths = UserDefaults.standard.stringArray(forKey: "workspaces.availableWorktreePaths")
    let worktreeNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableWorktreeNames")
    let favoriteKeys = UserDefaults.standard.stringArray(forKey: "github.availableFavoriteKeys")
    let recentPRKeys = UserDefaults.standard.stringArray(forKey: "github.availableRecentPRKeys")
    let selectedFavoriteKey = UserDefaults.standard.string(forKey: "github.selectedFavoriteKey")
    let selectedRecentPRKey = UserDefaults.standard.string(forKey: "github.selectedRecentPRKey")
    let gitRepoPaths = UserDefaults.standard.stringArray(forKey: "git.availableRepoPaths")
    let gitRepoNames = UserDefaults.standard.stringArray(forKey: "git.availableRepoNames")
    let gitSelectedRepo = UserDefaults.standard.string(forKey: "git.selectedRepoPath")
    let formatter = Formatter.iso8601
    let uniqueGitRepoPaths = dedupeStrings(gitRepoPaths)
    let uniqueGitRepoNames = dedupeStrings(gitRepoNames)
    let uniqueWorkspaceNames = dedupeStrings(workspaceNames)
    let uniqueRepoNames = dedupeStrings(repoNames)
    let uniqueWorktreePaths = dedupeStrings(worktreePaths)
    let uniqueWorktreeNames = dedupeStrings(worktreeNames)
    let uniqueFavoriteKeys = dedupeStrings(favoriteKeys)
    let uniqueRecentPRKeys = dedupeStrings(recentPRKeys)
    let recentActions = recentUIActions.prefix(10).map { action in
      [
        "controlId": action.controlId,
        "status": action.status,
        "timestamp": formatter.string(from: action.timestamp)
      ]
    }
    let state: [String: Any] = [
      "currentTool": currentToolId() as Any,
      "mcpRunning": isRunning,
      "activeRequests": activeRequests,
      "appActive": isAppActive,
      "appFrontmost": isAppFrontmost,
      "lastRequestAt": lastRequestAt?.formatted() as Any,
      "githubShowArchived": showArchived,
      "brewSource": brewSource as Any,
      "brewSearchText": brewSearch as Any,
      "workspacesSelectedWorkspace": workspaceName as Any,
      "workspacesSelectedRepo": repoName as Any,
      "workspacesSelectedWorktree": worktreePath as Any,
      "workspacesSelectedWorktreeName": worktreeName as Any,
      "workspacesAvailable": uniqueWorkspaceNames as Any,
      "workspacesAvailableRepos": uniqueRepoNames as Any,
      "workspacesAvailableWorktrees": uniqueWorktreePaths as Any,
      "workspacesAvailableWorktreeNames": uniqueWorktreeNames as Any,
      "githubAvailableFavorites": uniqueFavoriteKeys as Any,
      "githubAvailableRecentPRs": uniqueRecentPRKeys as Any,
      "githubSelectedFavorite": selectedFavoriteKey as Any,
      "githubSelectedRecentPR": selectedRecentPRKey as Any,
      "gitAvailableRepos": uniqueGitRepoPaths as Any,
      "gitAvailableRepoNames": uniqueGitRepoNames as Any,
      "gitSelectedRepo": gitSelectedRepo as Any,
      "lastUIActionHandled": lastUIActionHandled as Any,
      "lastUIActionHandledAt": lastUIActionHandledAt.map { formatter.string(from: $0) } as Any,
      "pendingUIAction": lastUIAction?.controlId as Any,
      "lastToolRequiresForeground": lastToolRequiresForeground as Any,
      "recentUIActions": recentActions
    ]
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: state))
  }

  private func handleStateList(id: Any?) -> (Int, Data) {
    let currentViewId = currentToolId()
    let controls = availableToolControlIds() + availableControlIds(for: currentViewId)
    let controlsByView = Dictionary(uniqueKeysWithValues: availableViewIds().map { viewId in
      (viewId, availableControlIds(for: viewId))
    })
    let controlValuesByView = Dictionary(uniqueKeysWithValues: availableViewIds().map { viewId in
      (viewId, controlValues(for: viewId))
    })
    let toolForegroundByName = Dictionary(uniqueKeysWithValues: activeToolDefinitions.map { tool in
      (tool.name, tool.requiresForeground)
    })
    let toolGroupsByName = Dictionary(uniqueKeysWithValues: activeToolDefinitions.map { tool in
      (tool.name, groups(for: tool).map { $0.rawValue })
    })
    let state: [String: Any] = [
      "views": availableViewIds(),
      "tools": activeToolDefinitions.map { $0.name },
      "controls": controls,
      "controlsByView": controlsByView,
      "controlValuesByView": controlValuesByView,
      "toolRequiresForeground": toolForegroundByName,
      "toolGroups": toolGroupsByName,
      "toolGroupList": toolGroups.map { $0.rawValue },
      "currentViewId": currentViewId as Any
    ]
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: state))
  }

  private func handleToolsSearch(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let query = (arguments["query"] as? String)?.lowercased() ?? ""
    let categoryFilter = (arguments["category"] as? String)?.lowercased()

    let matches = allToolDefinitions.filter { tool in
      if let categoryFilter, tool.category.rawValue.lowercased() != categoryFilter {
        return false
      }
      if query.isEmpty { return categoryFilter != nil }
      return tool.name.lowercased().contains(query)
        || tool.description.lowercased().contains(query)
    }

    let results: [[String: Any]] = matches.map { tool in
      [
        "name": sanitizedToolName(tool.name),
        "originalName": tool.name,
        "description": tool.description,
        "category": tool.category.rawValue,
        "enabled": isToolEnabled(tool.name),
        "requiresForeground": tool.requiresForeground
      ]
    }

    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
      "matches": results,
      "count": results.count,
      "totalTools": allToolDefinitions.count
    ]))
  }

  private func handleToolsCategories(id: Any?) -> (Int, Data) {
    var byCategory = [String: [String]]()
    for tool in allToolDefinitions {
      let cat = tool.category.rawValue
      byCategory[cat, default: []].append(sanitizedToolName(tool.name))
    }

    let categories: [[String: Any]] = byCategory.sorted(by: { $0.key < $1.key }).map { cat, tools in
      [
        "category": cat,
        "count": tools.count,
        "tools": Array(tools.prefix(5)),
        "hasMore": tools.count > 5
      ]
    }

    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
      "categories": categories,
      "totalTools": allToolDefinitions.count
    ]))
  }

  private func handleTranslationsValidate(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let root = (arguments["root"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let translationsPath = arguments["translationsPath"] as? String
    let baseLocale = arguments["baseLocale"] as? String
    let only = arguments["only"] as? String
    let summaryOnly = arguments["summary"] as? Bool ?? false
    let useAppleAI = arguments["useAppleAI"] as? Bool ?? false
    let redactSamples = arguments["redactSamples"] as? Bool ?? true
    let toolPath = arguments["toolPath"] as? String

    guard let root, !root.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing root"))
    }

    let options = TranslationValidatorService.Options(
      root: root,
      translationsPath: translationsPath,
      baseLocale: baseLocale,
      only: only,
      summary: summaryOnly,
      toolPath: toolPath,
      useAppleAI: useAppleAI,
      redactSamples: redactSamples
    )

    do {
      let report = try await translationValidatorService.runValidator(options: options)
      let summary = report.summary()
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
        "report": encodeJSON(report),
        "summary": encodeJSON(summary)
      ]))
    } catch {
      await telemetryProvider.warning("Translation validation failed", metadata: ["error": error.localizedDescription])
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  // VM tool handlers moved to VMToolsHandler.swift (#161)

  private func handlePIIScrub(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let inputPath = (arguments["inputPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let outputPath = (arguments["outputPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let reportPath = (arguments["reportPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let reportFormat = (arguments["reportFormat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let configPath = (arguments["configPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let seed = (arguments["seed"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let maxSamples = arguments["maxSamples"] as? Int
    let enableNER = arguments["enableNER"] as? Bool ?? false
    let toolPath = arguments["toolPath"] as? String

    guard let inputPath, !inputPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing inputPath"))
    }
    guard let outputPath, !outputPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing outputPath"))
    }

    let options = PIIScrubberService.Options(
      inputPath: inputPath,
      outputPath: outputPath,
      reportPath: reportPath,
      reportFormat: reportFormat,
      configPath: configPath,
      seed: seed,
      maxSamples: maxSamples,
      enableNER: enableNER,
      toolPath: toolPath
    )

    do {
      let result = try await piiScrubberService.runScrubber(options: options)
      var payload: [String: Any] = [
        "inputPath": result.inputPath,
        "outputPath": result.outputPath,
        "reportPath": result.reportPath as Any
      ]
      if let report = result.report {
        payload["report"] = encodeJSON(report)
      }
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: payload))
    } catch {
      await telemetryProvider.warning("PII scrubber failed", metadata: ["error": error.localizedDescription])
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleDoclingConvert(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let inputPath = (arguments["inputPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let outputPath = (arguments["outputPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let pythonPath = (arguments["pythonPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let scriptPath = (arguments["scriptPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let profile = (arguments["profile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let includeText = arguments["includeText"] as? Bool ?? false
    let maxChars = arguments["maxChars"] as? Int ?? 20000

    guard let inputPath, !inputPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing inputPath"))
    }
    guard let outputPath, !outputPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing outputPath"))
    }

    let options = DoclingService.Options(
      inputPath: inputPath,
      outputPath: outputPath,
      pythonPath: pythonPath,
      scriptPath: scriptPath,
      profile: profile
    )

    do {
      let result = try await doclingService.runConvert(options: options)
      var payload: [String: Any] = [
        "inputPath": result.inputPath,
        "outputPath": result.outputPath,
        "bytesWritten": result.bytesWritten,
        "pythonPath": result.pythonPath,
        "scriptPath": result.scriptPath
      ]
      if let profile, !profile.isEmpty {
        payload["profile"] = profile
      }
      if includeText {
        let maxLength = max(1, maxChars)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: result.outputPath)),
           let text = String(data: data, encoding: .utf8) {
          payload["text"] = String(text.prefix(maxLength))
          payload["textTruncated"] = text.count > maxLength
        }
      }
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: payload))
    } catch {
      await telemetryProvider.warning("Docling conversion failed", metadata: ["error": error.localizedDescription])
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleDoclingSetup(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let pythonPath = (arguments["pythonPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      let result = try await doclingService.ensureDoclingInstalled(pythonPath: pythonPath)
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
        "pythonPath": result.pythonPath,
        "log": result.log
      ]))
    } catch {
      await telemetryProvider.warning("Docling setup failed", metadata: ["error": error.localizedDescription])
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  // Parallel tool handlers moved to ParallelToolsHandler.swift (#162)
  // RAG tool handlers moved to RAGToolsHandler.swift

  private func encodeJSON<T: Encodable>(_ value: T) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object
  }

}
