//
//  RAGToolsHandler.swift
//  Peel
//
//  Created as part of #159: Extract RAG tools from MCPServerService.
//

import Foundation
import MCPCore
import SwiftData

// MARK: - RAG Tools Handler Delegate Extension

/// Extended delegate protocol for RAG-specific functionality
@MainActor
protocol RAGToolsHandlerDelegate: MCPToolHandlerDelegate {
  // MARK: - LocalRAGStore Access
  
  /// Search the RAG index
  func searchRagForTool(query: String, mode: MCPServerService.RAGSearchMode, repoPath: String?, limit: Int, matchAll: Bool, modulePath: String?) async throws -> [RAGToolSearchResult]
  
  /// Get RAG database status
  func ragStatus() async -> RAGToolStatus
  
  /// Initialize RAG database
  func initializeRag(extensionPath: String?) async throws -> RAGToolStatus
  
  /// Index a repository
  func indexRepository(
    path: String,
    forceReindex: Bool,
    allowWorkspace: Bool,
    excludeSubrepos: Bool,
    progressHandler: (@Sendable (RAGToolIndexProgress) -> Void)?
  ) async throws -> RAGToolIndexReport
  
  /// List indexed repositories
  func listRagRepos() async throws -> [RAGToolRepoInfo]
  
  /// Delete a repository from the index
  func deleteRagRepo(repoId: String?, repoPath: String?) async throws -> Int
  
  /// Get index statistics
  func getIndexStats(repoPath: String) async throws -> RAGToolIndexStats
  
  /// Get large files in a repo
  func getLargeFiles(repoPath: String, limit: Int) async throws -> [RAGToolLargeFile]
  
  /// Get construct type statistics
  func getConstructTypeStats(repoPath: String) async throws -> [RAGToolConstructTypeStat]
  
  /// Get facet counts for filtering/grouping
  func getFacets(repoPath: String?) async throws -> RAGToolFacetCounts
  
  /// Get dependencies for a file (what does it depend on) - Issue #176
  func getDependencies(filePath: String, repoPath: String) async throws -> [RAGToolDependencyResult]
  
  /// Get dependents for a file (what depends on it) - Issue #176
  func getDependents(filePath: String, repoPath: String) async throws -> [RAGToolDependencyResult]
  
  /// Find orphaned files with no dependents - Issue #248
  func findOrphans(repoPath: String, excludeTests: Bool, excludeEntryPoints: Bool, limit: Int) async throws -> [RAGToolOrphanResult]

  /// Index a repository branch/worktree incrementally by copying main branch index then re-indexing changed files - Issue #260
  func indexBranchRepository(
    repoPath: String,
    baseBranch: String,
    baseRepoPath: String?,
    progressHandler: (@Sendable (RAGToolIndexProgress) -> Void)?
  ) async throws -> (report: RAGToolIndexReport, changedFilesCount: Int, deletedFilesCount: Int, wasCopiedFromBase: Bool, baseRepoPath: String?)

  /// Remove stale branch/worktree RAG indexes for repos no longer on disk - Issue #260
  func cleanupBranchIndexes(dryRun: Bool) async throws -> (removedCount: Int, removedPaths: [String])
  
  /// Query files by structural characteristics - Issue #174
  func queryFilesByStructure(
    repoPath: String,
    minLines: Int?,
    maxLines: Int?,
    minMethods: Int?,
    maxMethods: Int?,
    minBytes: Int?,
    maxBytes: Int?,
    language: String?,
    sortBy: String,
    limit: Int
  ) async throws -> [RAGToolStructuralResult]
  
  /// Get structural statistics for a repo - Issue #174
  func getStructuralStats(repoPath: String) async throws -> (
    totalFiles: Int,
    totalLines: Int,
    totalMethods: Int,
    avgLinesPerFile: Double,
    avgMethodsPerFile: Double,
    largestFile: (path: String, lines: Int)?,
    mostMethods: (path: String, count: Int)?
  )
  
  /// Find semantically similar code - Issue #175
  func findSimilarCode(
    query: String,
    repoPath: String?,
    threshold: Double,
    limit: Int,
    excludePath: String?
  ) async throws -> [RAGToolSimilarResult]
  
  /// Clear embedding cache
  func clearRagCache() async throws -> Int
  
  /// Generate embeddings for texts
  func generateEmbeddings(for texts: [String]) async throws -> [[Float]]
  
  // MARK: - DataService Access (Skills)
  
  /// Get model context for direct SwiftData operations
  var modelContext: ModelContext? { get }
  
  /// List guidance skills
    func listRepoGuidanceSkills(repoPath: String?, repoRemoteURL: String?, includeInactive: Bool, limit: Int?) -> [RepoGuidanceSkill]
  
  /// Add a guidance skill
    func addRepoGuidanceSkill(repoPath: String, repoRemoteURL: String?, repoName: String?, title: String, body: String, source: String, tags: String, priority: Int, isActive: Bool) -> RepoGuidanceSkill?
  
  /// Update a guidance skill
    func updateRepoGuidanceSkill(id: UUID, repoPath: String?, repoRemoteURL: String?, repoName: String?, title: String?, body: String?, source: String?, tags: String?, priority: Int?, isActive: Bool?) -> RepoGuidanceSkill?
  
  /// Delete a guidance skill
  func deleteRepoGuidanceSkill(id: UUID) -> Bool

  // MARK: - Skill File I/O (#264)

  /// Export skills for a repo to .peel/skills.json. Returns (count, filePath).
  func exportSkillsToFile(repoPath: String) throws -> (count: Int, path: String)

  /// Import skills from .peel/skills.json into the DB. Returns (imported, skipped).
  func importSkillsFromFile(repoPath: String) throws -> (imported: Int, skipped: Int)

  /// Two-way sync: export DB-only skills, import file-only skills.
  func syncSkillsWithFile(repoPath: String) throws -> (exported: Int, imported: Int, path: String)

  // MARK: - Learning Loop (#210)
  
  /// List lessons for a repo
  func listLessons(repoPath: String, includeInactive: Bool, limit: Int?) async throws -> [LocalRAGLesson]
  
  /// Add a lesson
  func addLesson(repoPath: String, filePattern: String?, errorSignature: String?, fixDescription: String, fixCode: String?, source: String) async throws -> LocalRAGLesson
  
  /// Query relevant lessons for a file/error
  func queryLessons(repoPath: String, filePattern: String?, errorSignature: String?, limit: Int) async throws -> [LocalRAGLesson]
  
  /// Update a lesson
  func updateLesson(id: String, fixDescription: String?, fixCode: String?, confidence: Double?, isActive: Bool?) async throws -> LocalRAGLesson?
  
  /// Delete a lesson
  func deleteLesson(id: String) async throws -> Bool
  
  /// Record that a lesson was applied (Phase 4: confidence feedback)
  func recordLessonApplied(id: String, success: Bool) async throws
  
  // MARK: - Configuration
  
  /// Get/set the preferred embedding provider
  var preferredEmbeddingProvider: EmbeddingProviderType { get set }
  
  /// Refresh RAG summary (repos list)
  func refreshRagSummary() async
  
  /// Get RAG stats
  func ragStats() async throws -> RAGToolStats?

  /// Get recent successful query hints
  func getRagQueryHints(limit: Int?) async -> [MCPServerService.RAGQueryHint]
  
  /// Log a telemetry warning
  func logWarning(_ message: String, metadata: [String: String]) async
  
  // MARK: - AI Analysis (#198)
  
  #if os(macOS)
  /// Analyze un-analyzed chunks using MLX LLM
  func analyzeRagChunks(repoPath: String?, limit: Int, modelTier: MLXAnalyzerModelTier, progress: (@Sendable (Int, Int) -> Void)?) async throws -> Int
  
  /// Get count of un-analyzed chunks
  func getUnanalyzedChunkCount(repoPath: String?) async throws -> Int
  
  /// Get count of analyzed chunks
  func getAnalyzedChunkCount(repoPath: String?) async throws -> Int
  
  /// Re-embed analyzed chunks with enriched text (code + ai_summary)
  func enrichRagEmbeddings(repoPath: String?, limit: Int, progress: (@Sendable (Int, Int) -> Void)?) async throws -> Int
  
  /// Get count of analyzed but not-yet-enriched chunks
  func getUnenrichedChunkCount(repoPath: String?) async throws -> Int
  
  /// Get count of enriched chunks
  func getEnrichedChunkCount(repoPath: String?) async throws -> Int
  
  /// Find duplicate constructs across files
  func findRagDuplicates(repoPath: String?, minFiles: Int, constructTypes: [String]?, sortBy: String, limit: Int) async throws -> [LocalRAGStore.DuplicateGroup]
  
  /// Analyze naming patterns and conventions
  func findRagPatterns(repoPath: String?, constructType: String?, limit: Int) async throws -> [LocalRAGStore.PatternGroup]
  
  /// Find complexity hotspots (god components)
  func findRagHotspots(repoPath: String?, constructType: String?, minTokens: Int, limit: Int) async throws -> [LocalRAGStore.Hotspot]
  #endif
}

// MARK: - RAG Tools Handler

/// Handles RAG (Retrieval-Augmented Generation) tools
@MainActor
final class RAGToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?
  
  /// Typed delegate for RAG-specific operations
  private var ragDelegate: RAGToolsHandlerDelegate? {
    delegate as? RAGToolsHandlerDelegate
  }
  
  let supportedTools: Set<String> = [
    "rag.status",
    "rag.config",
    "rag.init",
    "rag.index",
    "rag.search",
    "rag.queryHints",
    "rag.cache.clear",
    "rag.model.describe",
    "rag.model.list",
    "rag.model.set",
    "rag.embedding.test",
    "rag.ui.status",
    "rag.skills.list",
    "rag.skills.add",
    "rag.skills.update",
    "rag.skills.delete",
    "rag.skills.export",   // Issue #264: Export skills to .peel/skills.json
    "rag.skills.import",   // Issue #264: Import skills from .peel/skills.json
    "rag.skills.sync",     // Issue #264: Two-way sync DB <-> .peel/skills.json
    "rag.skills.ember.detect",  // Issue #263: Detect Ember project and seed skills
    "rag.skills.ember.update",  // Issue #263: Check for and apply Ember skills updates
    "rag.lessons.list",    // Issue #210: Learning loop - list lessons
    "rag.lessons.add",     // Issue #210: Learning loop - add lesson
    "rag.lessons.query",   // Issue #210: Learning loop - query relevant lessons
    "rag.lessons.update",  // Issue #210: Learning loop - update lesson
    "rag.lessons.delete",  // Issue #210: Learning loop - delete lesson
    "rag.lessons.applied", // Issue #210: Learning loop - record lesson was applied (increases confidence)
    "rag.repos.list",
    "rag.repos.delete",
    "rag.stats",
    "rag.largeFiles",
    "rag.constructTypes",
    "rag.facets",
    "rag.dependencies",    // Issue #176: What does a file depend on
    "rag.dependents",      // Issue #176: What depends on a file
    "rag.orphans",         // Issue #248: Find potentially unused/orphaned files
    "rag.structural",      // Issue #174: Query by file structure (lines, methods, size)
    "rag.similar",         // Issue #175: Find semantically similar code
    "rag.reranker.config", // Issue #128: HF reranker configuration
    "rag.analyze",         // Issue #198: Analyze chunks with MLX LLM (macOS only)
    "rag.analyze.status",  // Issue #198: Get AI analysis status (macOS only)
    "rag.enrich",          // Re-embed analyzed chunks with enriched text (code + ai_summary)
    "rag.enrich.status",   // Get enrichment status (analyzed vs enriched counts)
    "rag.duplicates",      // Find duplicate constructs across files for dedup opportunities
    "rag.patterns",        // Analyze naming conventions and pattern consistency
    "rag.hotspots",        // Find god components / complexity hotspots
    "rag.scratch",         // Issue #111: Per-repo scratch directory for artifacts
    "rag.branch.index",    // Issue #260: Branch-aware incremental RAG indexing for worktrees
    "rag.branch.cleanup",  // Issue #260: Clean up stale branch/worktree RAG indexes
  ]
  
  init() {}
  
  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let ragDelegate else {
      return notConfiguredError(id: id)
    }
    
    switch name {
    case "rag.status":
      return await handleStatus(id: id, delegate: ragDelegate)
    case "rag.config":
      return await handleConfig(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.init":
      return await handleInit(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.search":
      return await handleSearch(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.queryHints":
      return await handleQueryHints(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.index":
      return await handleIndex(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.repos.list":
      return await handleReposList(id: id, delegate: ragDelegate)
    case "rag.repos.delete":
      return await handleReposDelete(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.skills.list":
      return handleSkillsList(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.skills.add":
      return handleSkillsAdd(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.skills.update":
      return handleSkillsUpdate(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.skills.delete":
      return handleSkillsDelete(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.skills.export":
      return handleSkillsExport(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.skills.import":
      return handleSkillsImport(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.skills.sync":
      return handleSkillsSync(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.skills.ember.detect":
      return handleSkillsEmberDetect(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.skills.ember.update":
      return await handleSkillsEmberUpdate(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.lessons.list":
      return await handleLessonsList(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.lessons.add":
      return await handleLessonsAdd(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.lessons.query":
      return await handleLessonsQuery(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.lessons.update":
      return await handleLessonsUpdate(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.lessons.delete":
      return await handleLessonsDelete(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.lessons.applied":
      return await handleLessonsApplied(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.stats":
      return await handleStats(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.largeFiles":
      return await handleLargeFiles(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.constructTypes":
      return await handleConstructTypes(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.facets":
      return await handleFacets(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.dependencies":
      return await handleDependencies(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.dependents":
      return await handleDependents(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.orphans":
      return await handleOrphans(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.structural":
      return await handleStructural(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.similar":
      return await handleSimilar(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.reranker.config":
      return handleRerankerConfig(id: id, arguments: arguments)
    case "rag.analyze":
      #if os(macOS)
      return await handleAnalyze(id: id, arguments: arguments, delegate: ragDelegate)
      #else
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "rag.analyze is only available on macOS"))
      #endif
    case "rag.analyze.status":
      #if os(macOS)
      return await handleAnalyzeStatus(id: id, arguments: arguments, delegate: ragDelegate)
      #else
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "rag.analyze.status is only available on macOS"))
      #endif
    case "rag.enrich":
      #if os(macOS)
      return await handleEnrich(id: id, arguments: arguments, delegate: ragDelegate)
      #else
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "rag.enrich is only available on macOS"))
      #endif
    case "rag.enrich.status":
      #if os(macOS)
      return await handleEnrichStatus(id: id, arguments: arguments, delegate: ragDelegate)
      #else
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "rag.enrich.status is only available on macOS"))
      #endif
    case "rag.duplicates":
      #if os(macOS)
      return await handleDuplicates(id: id, arguments: arguments, delegate: ragDelegate)
      #else
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "rag.duplicates is only available on macOS"))
      #endif
    case "rag.patterns":
      #if os(macOS)
      return await handlePatterns(id: id, arguments: arguments, delegate: ragDelegate)
      #else
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "rag.patterns is only available on macOS"))
      #endif
    case "rag.hotspots":
      #if os(macOS)
      return await handleHotspots(id: id, arguments: arguments, delegate: ragDelegate)
      #else
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "rag.hotspots is only available on macOS"))
      #endif
    case "rag.scratch":
      return handleScratch(id: id, arguments: arguments)
    case "rag.branch.index":
      return await handleBranchIndex(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.branch.cleanup":
      return await handleBranchCleanup(id: id, arguments: arguments, delegate: ragDelegate)
    default:
      // For tools not yet extracted, return method not found
      // The MCPServerService will handle these until full extraction is complete
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Tool not yet extracted: \(name)"))
    }
  }
  
  // MARK: - rag.status
  
  private func handleStatus(id: Any?, delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let status = await delegate.ragStatus()
    let formatter = ISO8601DateFormatter()
    var result: [String: Any] = [
      "dbPath": status.dbPath,
      "exists": status.exists,
      "schemaVersion": status.schemaVersion,
      "extensionLoaded": status.extensionLoaded,
      "embeddingProvider": status.providerName,
      "embeddingModel": status.embeddingModelName,
      "embeddingDimensions": status.embeddingDimensions,
      "debugForceSystem": UserDefaults.standard.bool(forKey: "localrag.useSystem")
    ]
    if let lastInitializedAt = status.lastInitializedAt {
      result["lastInitializedAt"] = formatter.string(from: lastInitializedAt)
    }
    return (200, makeResult(id: id, result: result))
  }

  // MARK: - rag.config

  private func handleConfig(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let action = optionalString("action", from: arguments, default: "get") ?? "get"

    if action == "get" {
      // Return current configuration
      let config = buildConfigResult()
      return (200, makeResult(id: id, result: config))
    }

    // action == "set"
    var changes: [String] = []

    // Provider
    if let providerStr = optionalString("provider", from: arguments) {
      if let provider = EmbeddingProviderType(rawValue: providerStr) {
        LocalRAGEmbeddingProviderFactory.preferredProvider = provider
        changes.append("provider=\(providerStr)")
      }
    }

    // MLX cache limit (MB)
    if let clearLimit = arguments["clearMlxCacheLimit"] as? Bool, clearLimit {
      LocalRAGEmbeddingProviderFactory.mlxCacheLimitMB = nil
      changes.append("mlxCacheLimitMB=default")
    } else if let limitMB = optionalInt("mlxCacheLimitMB", from: arguments) {
      LocalRAGEmbeddingProviderFactory.mlxCacheLimitMB = limitMB
      changes.append("mlxCacheLimitMB=\(limitMB)")
    }

    // MLX clear cache after batch
    if let clearAfterBatch = arguments["mlxClearCacheAfterBatch"] as? Bool {
      LocalRAGEmbeddingProviderFactory.mlxClearCacheAfterBatch = clearAfterBatch
      changes.append("mlxClearCacheAfterBatch=\(clearAfterBatch)")
    }

    // MLX memory limit (GB) - new setting for memory pressure management
    if let memoryLimitGB = arguments["mlxMemoryLimitGB"] as? Double {
      LocalRAGEmbeddingProviderFactory.mlxMemoryLimitGB = memoryLimitGB
      changes.append("mlxMemoryLimitGB=\(memoryLimitGB)")
    } else if let memoryLimitGB = arguments["mlxMemoryLimitGB"] as? Int {
      LocalRAGEmbeddingProviderFactory.mlxMemoryLimitGB = Double(memoryLimitGB)
      changes.append("mlxMemoryLimitGB=\(memoryLimitGB)")
    }

    // Reinitialize if requested
    let shouldReinit = optionalBool("reinitialize", from: arguments, default: true)
    if shouldReinit && !changes.isEmpty {
      do {
        _ = try await delegate.initializeRag(extensionPath: nil)
      } catch {
        await delegate.logWarning("RAG reinit after config change failed", metadata: ["error": error.localizedDescription])
      }
    }

    var result = buildConfigResult()
    result["changes"] = changes
    return (200, makeResult(id: id, result: result))
  }

  private func buildConfigResult() -> [String: Any] {
    let provider = LocalRAGEmbeddingProviderFactory.preferredProvider
    let physicalGB = Double(LocalRAGEmbeddingProviderFactory.physicalMemoryBytes()) / 1_073_741_824.0
    let currentGB = Double(LocalRAGEmbeddingProviderFactory.currentProcessMemoryBytes()) / 1_073_741_824.0
    let memoryLimitGB = LocalRAGEmbeddingProviderFactory.mlxMemoryLimitGB

    var config: [String: Any] = [
      "provider": provider.rawValue,
      "mlxClearCacheAfterBatch": LocalRAGEmbeddingProviderFactory.mlxClearCacheAfterBatch,
      "mlxMemoryLimitGB": memoryLimitGB,
      "physicalMemoryGB": String(format: "%.1f", physicalGB),
      "currentProcessMemoryGB": String(format: "%.1f", currentGB),
      "isMemoryPressureHigh": LocalRAGEmbeddingProviderFactory.isMemoryPressureHigh()
    ]
    if let limitMB = LocalRAGEmbeddingProviderFactory.mlxCacheLimitMB {
      config["mlxCacheLimitMB"] = limitMB
    }
    return config
  }

  // MARK: - rag.init

  private func handleInit(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let extensionPath = optionalString("extensionPath", from: arguments)

    do {
      let status = try await delegate.initializeRag(extensionPath: extensionPath)
      await delegate.refreshRagSummary()
      let formatter = ISO8601DateFormatter()
      var result: [String: Any] = [
        "dbPath": status.dbPath,
        "exists": status.exists,
        "schemaVersion": status.schemaVersion,
        "extensionLoaded": status.extensionLoaded,
        "embeddingProvider": status.providerName,
        "embeddingModel": status.embeddingModelName,
        "embeddingDimensions": status.embeddingDimensions
      ]
      if let lastInitializedAt = status.lastInitializedAt {
        result["lastInitializedAt"] = formatter.string(from: lastInitializedAt)
      }
      return (200, makeResult(id: id, result: result))
    } catch {
      await delegate.logWarning("Local RAG init failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.search
  
  private func handleSearch(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let query) = requireString("query", from: arguments, id: id) else {
      return missingParamError(id: id, param: "query")
    }
    
    let repoPath = optionalString("repoPath", from: arguments)
    let limit = optionalInt("limit", from: arguments, default: 10) ?? 10
    let mode = optionalString("mode", from: arguments, default: "text") ?? "text"
    let excludeTests = optionalBool("excludeTests", from: arguments, default: false)
    let constructTypeFilter = optionalString("constructType", from: arguments)
    let modulePathFilter = optionalString("modulePath", from: arguments)
    let featureTagFilter = optionalString("featureTag", from: arguments)
    let matchAll = optionalBool("matchAll", from: arguments, default: true)
    let shouldRerank = optionalBool("rerank", from: arguments, default: false)
    let detail = optionalString("detail", from: arguments, default: "full") ?? "full"
    
    do {
      let resolvedMode: MCPServerService.RAGSearchMode = mode.lowercased() == "vector" ? .vector : .text
      // Fetch more results initially if reranking is enabled
      let fetchLimit = shouldRerank ? max(limit * 3, 30) : limit * 2
      var results = try await delegate.searchRagForTool(query: query, mode: resolvedMode, repoPath: repoPath, limit: fetchLimit, matchAll: matchAll, modulePath: modulePathFilter)
      
      // Apply post-query filters (modulePath is now pushed into SQL)
      if excludeTests {
        results = results.filter { !$0.isTest }
      }
      if let typeFilter = constructTypeFilter?.lowercased(), !typeFilter.isEmpty {
        results = results.filter { ($0.constructType?.lowercased() ?? "") == typeFilter }
      }
      if let tagFilter = featureTagFilter?.lowercased(), !tagFilter.isEmpty {
        results = results.filter { $0.featureTags.contains { $0.lowercased() == tagFilter } }
      }
      
      // Apply HuggingFace reranking if enabled and requested
      var rerankerProvider: String? = nil
      if shouldRerank, let reranker = HFRerankerFactory.makeIfEnabled() {
        do {
          // Convert to RerankerSearchResult
          let rerankerInput = results.map { r in
            RerankerSearchResult(
              filePath: r.filePath,
              startLine: r.startLine,
              endLine: r.endLine,
              snippet: r.snippet,
              isTest: r.isTest,
              lineCount: r.lineCount,
              constructType: r.constructType,
              constructName: r.constructName,
              language: r.language,
              score: r.score.map { Float($0) },
              modulePath: r.modulePath,
              featureTags: r.featureTags
            )
          }
          
          let reranked = try await reranker.rerank(query: query, results: rerankerInput, topK: limit)
          
          // Build a lookup for AI fields that aren't in RerankerSearchResult
          var aiLookup: [String: (aiSummary: String?, aiTags: [String], tokenCount: Int?)] = [:]
          for r in results {
            let key = "\(r.filePath):\(r.startLine)-\(r.endLine)"
            aiLookup[key] = (r.aiSummary, r.aiTags, r.tokenCount)
          }
          
          // Convert back to RAGToolSearchResult
          results = reranked.map { r in
            let key = "\(r.filePath):\(r.startLine)-\(r.endLine)"
            let ai = aiLookup[key]
            return RAGToolSearchResult(
              filePath: r.filePath,
              startLine: r.startLine,
              endLine: r.endLine,
              snippet: r.snippet,
              isTest: r.isTest,
              lineCount: r.lineCount,
              constructType: r.constructType,
              constructName: r.constructName,
              language: r.language,
              score: r.score.map { Double($0) },
              modulePath: r.modulePath,
              featureTags: r.featureTags,
              aiSummary: ai?.aiSummary,
              aiTags: ai?.aiTags ?? [],
              tokenCount: ai?.tokenCount
            )
          }
          
          rerankerProvider = reranker.providerName
        } catch {
          // Log warning but continue with unranked results
          await delegate.logWarning("HF reranking failed, using unranked results", metadata: ["error": error.localizedDescription])
        }
      }
      
      // Trim to requested limit after filtering
      results = Array(results.prefix(limit))
      
      let payload: [[String: Any]] = results.map { result in
        var item: [String: Any] = [
          "filePath": result.filePath,
          "startLine": result.startLine,
          "endLine": result.endLine,
          "isTest": result.isTest,
          "lineCount": result.lineCount
        ]
        // In "summary" mode, return ai_summary instead of code snippet (20-80x smaller)
        // In "minimal" mode, return only path + construct metadata (no code or summary)
        // In "full" mode (default), return everything
        if detail != "minimal" {
          if detail == "summary", let summary = result.aiSummary, !summary.isEmpty {
            item["aiSummary"] = summary
          } else {
            item["snippet"] = result.snippet
            // Include aiSummary alongside snippet in full mode when available
            if let summary = result.aiSummary, !summary.isEmpty {
              item["aiSummary"] = summary
            }
          }
        }
        if let constructType = result.constructType {
          item["constructType"] = constructType
        }
        if let constructName = result.constructName {
          item["name"] = constructName
        }
        if detail != "minimal" {
          if let language = result.language {
            item["language"] = language
          }
        }
        if let score = result.score {
          item["score"] = score
        }
        // Facets (schema v4+)
        if let modulePath = result.modulePath {
          item["modulePath"] = modulePath
        }
        if !result.featureTags.isEmpty {
          item["featureTags"] = result.featureTags
        }
        // AI tags (schema v7+) — included in summary and full modes
        if detail != "minimal", !result.aiTags.isEmpty {
          item["aiTags"] = result.aiTags
        }
        // Token count — helps agents gauge chunk size without seeing code
        if let tokenCount = result.tokenCount {
          item["tokenCount"] = tokenCount
        }
        return item
      }
      
      // Build response with reranker info
      var response: [String: Any] = ["mode": mode, "detail": detail, "results": payload]
      if let provider = rerankerProvider {
        response["rerankerProvider"] = provider
      }
      
      return (200, makeResult(id: id, result: response))
    } catch {
      await delegate.logWarning("Local RAG search failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }

  // MARK: - rag.queryHints

  private func handleQueryHints(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let limit = optionalInt("limit", from: arguments, default: 10) ?? 10
    let hints = await delegate.getRagQueryHints(limit: limit)
    let formatter = ISO8601DateFormatter()
    let payload: [[String: Any]] = hints.map { hint in
      var item: [String: Any] = [
        "query": hint.query,
        "mode": hint.mode.rawValue,
        "resultCount": hint.resultCount,
        "useCount": hint.useCount,
        "lastUsedAt": formatter.string(from: hint.lastUsedAt)
      ]
      if let repoPath = hint.repoPath {
        item["repoPath"] = repoPath
      }
      return item
    }
    return (200, makeResult(id: id, result: ["hints": payload]))
  }
  
  // MARK: - rag.index
  
  private func handleIndex(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let forceReindex = optionalBool("forceReindex", from: arguments, default: false)
    let allowWorkspace = optionalBool("allowWorkspace", from: arguments, default: false)
    let excludeSubrepos = optionalBool("excludeSubrepos", from: arguments, default: true)
    
    do {
      // Delegate handles all state tracking
      let report = try await delegate.indexRepository(
        path: repoPath,
        forceReindex: forceReindex,
        allowWorkspace: allowWorkspace,
        excludeSubrepos: excludeSubrepos,
        progressHandler: nil
      )
      
      await delegate.refreshRagSummary()
      
      var result: [String: Any] = [
        "repoId": report.repoId,
        "repoPath": report.repoPath,
        "filesIndexed": report.filesIndexed,
        "filesSkipped": report.filesSkipped,
        "filesRemoved": report.filesRemoved,
        "chunksIndexed": report.chunksIndexed,
        "bytesScanned": report.bytesScanned,
        "durationMs": report.durationMs,
        "embeddingCount": report.embeddingCount,
        "embeddingDurationMs": report.embeddingDurationMs
      ]
      // Include sub-package reports for workspace indexing (#262)
      if !report.subReports.isEmpty {
        result["subPackagesIndexed"] = report.subReports.count
        result["subReports"] = report.subReports.map { sub -> [String: Any] in
          [
            "repoId": sub.repoId,
            "repoPath": sub.repoPath,
            "filesIndexed": sub.filesIndexed,
            "filesSkipped": sub.filesSkipped,
            "chunksIndexed": sub.chunksIndexed
          ]
        }
      }
      return (200, makeResult(id: id, result: result))
    } catch {
      await delegate.logWarning("Local RAG index failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.repos.list
  
  private func handleReposList(id: Any?, delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    do {
      let repos = try await delegate.listRagRepos()
      let formatter = ISO8601DateFormatter()
      let repoList = repos.map { repo -> [String: Any] in
        var dict: [String: Any] = [
          "id": repo.id,
          "name": repo.name,
          "rootPath": repo.rootPath,
          "fileCount": repo.fileCount,
          "chunkCount": repo.chunkCount
        ]
        if let lastIndexedAt = repo.lastIndexedAt {
          dict["lastIndexedAt"] = formatter.string(from: lastIndexedAt)
        }
        if let repoIdentifier = repo.repoIdentifier {
          dict["repoIdentifier"] = repoIdentifier
        }
        if let parentRepoId = repo.parentRepoId {
          dict["parentRepoId"] = parentRepoId
          // Find the parent repo name for readability
          if let parent = repos.first(where: { $0.id == parentRepoId }) {
            dict["parentName"] = parent.name
          }
        }
        return dict
      }
      return (200, makeResult(id: id, result: ["repos": repoList]))
    } catch {
      await delegate.logWarning("Local RAG list repos failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.repos.delete
  
  private func handleReposDelete(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoId = optionalString("repoId", from: arguments)
    let repoPath = optionalString("repoPath", from: arguments)
    
    guard repoId != nil || repoPath != nil else {
      return missingParamError(id: id, param: "repoId or repoPath")
    }
    
    do {
      let deletedCount = try await delegate.deleteRagRepo(repoId: repoId, repoPath: repoPath)
      await delegate.refreshRagSummary()
      return (200, makeResult(id: id, result: ["filesDeleted": deletedCount]))
    } catch {
      await delegate.logWarning("Local RAG delete repo failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.skills.list
  
  private func handleSkillsList(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    let repoRemoteURL = optionalString("repoRemoteURL", from: arguments)
    let includeInactive = optionalBool("includeInactive", from: arguments, default: false)
    let limit = optionalInt("limit", from: arguments)
    let formatter = ISO8601DateFormatter()
    
    let skills = delegate.listRepoGuidanceSkills(
      repoPath: repoPath?.isEmpty == false ? repoPath : nil,
      repoRemoteURL: repoRemoteURL?.isEmpty == false ? repoRemoteURL : nil,
      includeInactive: includeInactive,
      limit: limit
    )
    let payload = skills.map { encodeSkill($0, formatter: formatter) }
    return (200, makeResult(id: id, result: ["skills": payload]))
  }
  
  // MARK: - rag.skills.add
  
  private func handleSkillsAdd(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments) ?? "*"
    guard case .success(let title) = requireString("title", from: arguments, id: id) else {
      return missingParamError(id: id, param: "title")
    }
    guard case .success(let body) = requireString("body", from: arguments, id: id) else {
      return missingParamError(id: id, param: "body")
    }
    
    let repoRemoteURL = optionalString("repoRemoteURL", from: arguments)
    let repoName = optionalString("repoName", from: arguments)
    let source = optionalString("source", from: arguments, default: "manual") ?? "manual"
    let tags = optionalString("tags", from: arguments, default: "") ?? ""
    let priority = optionalInt("priority", from: arguments, default: 0) ?? 0
    let isActive = optionalBool("isActive", from: arguments, default: true)
    
    let skill = delegate.addRepoGuidanceSkill(
      repoPath: repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "*" : repoPath,
      repoRemoteURL: repoRemoteURL,
      repoName: repoName,
      title: title,
      body: body,
      source: source,
      tags: tags,
      priority: priority,
      isActive: isActive
    )
    guard let skill else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Failed to create skill"))
    }
    let formatter = ISO8601DateFormatter()
    return (200, makeResult(id: id, result: ["skill": encodeSkill(skill, formatter: formatter)]))
  }
  
  // MARK: - rag.skills.update
  
  private func handleSkillsUpdate(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let skillId) = requireUUID("skillId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "skillId")
    }
    
    let skill = delegate.updateRepoGuidanceSkill(
      id: skillId,
      repoPath: optionalString("repoPath", from: arguments),
      repoRemoteURL: optionalString("repoRemoteURL", from: arguments),
      repoName: optionalString("repoName", from: arguments),
      title: optionalString("title", from: arguments),
      body: optionalString("body", from: arguments),
      source: optionalString("source", from: arguments),
      tags: optionalString("tags", from: arguments),
      priority: optionalInt("priority", from: arguments),
      isActive: arguments["isActive"] as? Bool
    )
    
    guard let skill else {
      return notFoundError(id: id, what: "Skill")
    }
    let formatter = ISO8601DateFormatter()
    return (200, makeResult(id: id, result: ["skill": encodeSkill(skill, formatter: formatter)]))
  }
  
  // MARK: - rag.skills.delete
  
  private func handleSkillsDelete(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let skillId) = requireUUID("skillId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "skillId")
    }
    
    let deleted = delegate.deleteRepoGuidanceSkill(id: skillId)
    if !deleted {
      return notFoundError(id: id, what: "Skill")
    }
    return (200, makeResult(id: id, result: ["deleted": skillId.uuidString]))
  }

  // MARK: - rag.skills.export (#264)

  private func handleSkillsExport(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    do {
      let (count, path) = try delegate.exportSkillsToFile(repoPath: repoPath)
      return (200, makeResult(id: id, result: ["exported": count, "path": path]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Export failed: \(error.localizedDescription)"))
    }
  }

  // MARK: - rag.skills.import (#264)

  private func handleSkillsImport(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    do {
      let (imported, skipped) = try delegate.importSkillsFromFile(repoPath: repoPath)
      return (200, makeResult(id: id, result: ["imported": imported, "skipped": skipped]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Import failed: \(error.localizedDescription)"))
    }
  }

  // MARK: - rag.skills.sync (#264)

  private func handleSkillsSync(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    do {
      let (exported, imported, path) = try delegate.syncSkillsWithFile(repoPath: repoPath)
      return (200, makeResult(id: id, result: ["exported": exported, "imported": imported, "path": path]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Sync failed: \(error.localizedDescription)"))
    }
  }

  // MARK: - rag.skills.ember.detect (#263)
  
  private func handleSkillsEmberDetect(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let isEmber = DefaultSkillsService.detectEmberProject(repoPath: repoPath)
    let alreadySeeded = DefaultSkillsService.hasLoadedEmberSkills(repoPath: repoPath)
    let skillCount = delegate.listRepoGuidanceSkills(repoPath: repoPath, repoRemoteURL: nil, includeInactive: false, limit: nil)
      .filter { $0.source == "NullVoxPopuli/agent-skills" }
      .count
    
    var result: [String: Any] = [
      "isEmberProject": isEmber,
      "alreadySeeded": alreadySeeded,
      "emberSkillCount": skillCount
    ]
    
    // If Ember and not seeded, offer to seed
    if isEmber && !alreadySeeded {
      result["action"] = "Use rag.skills.ember.update with action='seed' to add Ember best practices"
    }
    
    // Check for bundle info
    if let bundle = DefaultSkillsService.loadEmberSkillsBundle() {
      result["bundledVersion"] = bundle.meta.version
      result["bundledSkillCount"] = bundle.skills.count
      result["source"] = bundle.meta.source
    }
    
    return (200, makeResult(id: id, result: result))
  }
  
  // MARK: - rag.skills.ember.update (#263)
  
  private func handleSkillsEmberUpdate(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let action = optionalString("action", from: arguments) ?? "check"
    
    switch action {
    case "check":
      // Check for updates from GitHub
      let result = await SkillUpdateService.shared.checkForEmberSkillsUpdate(force: true)
      var response: [String: Any] = [
        "hasUpdate": result.hasUpdate,
        "currentVersion": result.currentVersion ?? "unknown"
      ]
      if let sha = result.latestCommitSHA {
        response["latestCommitSHA"] = String(sha.prefix(8))
      }
      if let lastUpdated = result.lastUpdated {
        response["lastChecked"] = ISO8601DateFormatter().string(from: lastUpdated)
      }
      if let error = result.error {
        response["error"] = error.localizedDescription
      }
      return (200, makeResult(id: id, result: response))
      
    case "seed":
      // Seed Ember skills for this repo
      guard let context = delegate.modelContext else {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Model context not available"))
      }
      
      let isEmber = DefaultSkillsService.detectEmberProject(repoPath: repoPath)
      if !isEmber {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Not an Ember project: \(repoPath)"))
      }
      
      let count = DefaultSkillsService.seedEmberSkills(context: context, repoPath: repoPath, force: true)
      return (200, makeResult(id: id, result: [
        "seeded": count,
        "repoPath": repoPath,
        "source": "NullVoxPopuli/agent-skills"
      ]))
      
    case "update":
      // Remove old and seed new
      guard let context = delegate.modelContext else {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Model context not available"))
      }
      
      let count = DefaultSkillsService.updateEmberSkills(context: context, repoPath: repoPath)
      return (200, makeResult(id: id, result: [
        "updated": count,
        "repoPath": repoPath,
        "source": "NullVoxPopuli/agent-skills"
      ]))
      
    case "remove":
      // Remove Ember skills for this repo
      guard let context = delegate.modelContext else {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Model context not available"))
      }
      
      DefaultSkillsService.removeEmberSkills(context: context, repoPath: repoPath)
      return (200, makeResult(id: id, result: [
        "removed": true,
        "repoPath": repoPath
      ]))
      
    default:
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Invalid action: \(action). Use 'check', 'seed', 'update', or 'remove'"))
    }
  }
  
  // MARK: - rag.lessons.list (#210)
  
  private func handleLessonsList(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let includeInactive = optionalBool("includeInactive", from: arguments, default: false)
    let limit = optionalInt("limit", from: arguments)
    
    do {
      let lessons = try await delegate.listLessons(repoPath: repoPath, includeInactive: includeInactive, limit: limit)
      let formatter = ISO8601DateFormatter()
      let payload = lessons.map { encodeLesson($0, formatter: formatter) }
      return (200, makeResult(id: id, result: ["lessons": payload]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.add (#210)
  
  private func handleLessonsAdd(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    guard case .success(let fixDescription) = requireString("fixDescription", from: arguments, id: id) else {
      return missingParamError(id: id, param: "fixDescription")
    }
    
    let filePattern = optionalString("filePattern", from: arguments)
    let errorSignature = optionalString("errorSignature", from: arguments)
    let fixCode = optionalString("fixCode", from: arguments)
    let source = optionalString("source", from: arguments, default: "manual") ?? "manual"
    
    do {
      let lesson = try await delegate.addLesson(
        repoPath: repoPath,
        filePattern: filePattern,
        errorSignature: errorSignature,
        fixDescription: fixDescription,
        fixCode: fixCode,
        source: source
      )
      let formatter = ISO8601DateFormatter()
      return (200, makeResult(id: id, result: ["lesson": encodeLesson(lesson, formatter: formatter)]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.query (#210)
  
  private func handleLessonsQuery(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let filePattern = optionalString("filePattern", from: arguments)
    let errorSignature = optionalString("errorSignature", from: arguments)
    let limit = optionalInt("limit", from: arguments, default: 20) ?? 20
    
    do {
      let lessons = try await delegate.queryLessons(
        repoPath: repoPath,
        filePattern: filePattern,
        errorSignature: errorSignature,
        limit: limit
      )
      let formatter = ISO8601DateFormatter()
      let payload = lessons.map { encodeLesson($0, formatter: formatter) }
      return (200, makeResult(id: id, result: ["lessons": payload, "query": ["filePattern": filePattern as Any, "errorSignature": errorSignature as Any]]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.update (#210)
  
  private func handleLessonsUpdate(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let lessonId) = requireString("lessonId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "lessonId")
    }
    
    let fixDescription = optionalString("fixDescription", from: arguments)
    let fixCode = optionalString("fixCode", from: arguments)
    // JSON numbers come in as Double
    let confidence: Double? = arguments["confidence"] as? Double
    let isActive = arguments["isActive"] as? Bool
    
    do {
      guard let lesson = try await delegate.updateLesson(
        id: lessonId,
        fixDescription: fixDescription,
        fixCode: fixCode,
        confidence: confidence,
        isActive: isActive
      ) else {
        return notFoundError(id: id, what: "Lesson")
      }
      let formatter = ISO8601DateFormatter()
      return (200, makeResult(id: id, result: ["lesson": encodeLesson(lesson, formatter: formatter)]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.delete (#210)
  
  private func handleLessonsDelete(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let lessonId) = requireString("lessonId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "lessonId")
    }
    
    do {
      let deleted = try await delegate.deleteLesson(id: lessonId)
      if !deleted {
        return notFoundError(id: id, what: "Lesson")
      }
      return (200, makeResult(id: id, result: ["deleted": lessonId]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.applied (#210 Phase 4)
  
  private func handleLessonsApplied(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let lessonId) = requireString("lessonId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "lessonId")
    }
    
    // Optional: whether the lesson actually helped (for future negative feedback)
    let success = optionalBool("success", from: arguments, default: true)
    
    do {
      try await delegate.recordLessonApplied(id: lessonId, success: success)
      return (200, makeResult(id: id, result: ["applied": lessonId, "success": success]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  /// Encode a lesson to a dictionary for JSON response
  private func encodeLesson(_ lesson: LocalRAGLesson, formatter: ISO8601DateFormatter) -> [String: Any] {
    var result: [String: Any] = [
      "id": lesson.id,
      "repoId": lesson.repoId,
      "fixDescription": lesson.fixDescription,
      "confidence": lesson.confidence,
      "applyCount": lesson.applyCount,
      "successCount": lesson.successCount,
      "source": lesson.source,
      "isActive": lesson.isActive,
      "createdAt": lesson.createdAt
    ]
    if let filePattern = lesson.filePattern {
      result["filePattern"] = filePattern
    }
    if let errorSignature = lesson.errorSignature {
      result["errorSignature"] = errorSignature
    }
    if let fixCode = lesson.fixCode {
      result["fixCode"] = fixCode
    }
    if let updatedAt = lesson.updatedAt {
      result["updatedAt"] = updatedAt
    }
    return result
  }
  
  // MARK: - rag.stats
  
  private func handleStats(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    do {
      let stats = try await delegate.getIndexStats(repoPath: repoPath)
      var result: [String: Any] = [
        "fileCount": stats.fileCount,
        "chunkCount": stats.chunkCount,
        "embeddingCount": stats.embeddingCount,
        "totalLines": stats.totalLines,
        "dependencyCount": stats.dependencyCount
      ]
      if !stats.dependenciesByType.isEmpty {
        result["dependenciesByType"] = stats.dependenciesByType
      }
      return (200, makeResult(id: id, result: result))
    } catch {
      await delegate.logWarning("RAG stats failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.largeFiles
  
  private func handleLargeFiles(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    let limit = optionalInt("limit", from: arguments, default: 20) ?? 20
    let minLines = optionalInt("minLines", from: arguments, default: 100) ?? 100
    
    do {
      let files = try await delegate.getLargeFiles(repoPath: repoPath, limit: limit)
      let filtered = files.filter { $0.totalLines >= minLines }
      let payload: [[String: Any]] = filtered.map { file in
        var item: [String: Any] = [
          "filePath": file.path,
          "totalLines": file.totalLines,
          "chunkCount": file.chunkCount
        ]
        if let lang = file.language {
          item["language"] = lang
        }
        return item
      }
      return (200, makeResult(id: id, result: ["files": payload, "count": payload.count]))
    } catch {
      await delegate.logWarning("RAG large files query failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.constructTypes
  
  private func handleConstructTypes(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    do {
      let stats = try await delegate.getConstructTypeStats(repoPath: repoPath)
      let payload: [[String: Any]] = stats.map { stat in
        [
          "type": stat.type,
          "count": stat.count
        ]
      }
      return (200, makeResult(id: id, result: ["types": payload]))
    } catch {
      await delegate.logWarning("RAG construct types query failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.facets
  
  private func handleFacets(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    
    do {
      let facets = try await delegate.getFacets(repoPath: repoPath)
      
      let modulePaths: [[String: Any]] = facets.modulePaths.map { ["path": $0.path, "count": $0.count] }
      let featureTags: [[String: Any]] = facets.featureTags.map { ["tag": $0.tag, "count": $0.count] }
      let languages: [[String: Any]] = facets.languages.map { ["language": $0.language, "count": $0.count] }
      let constructTypes: [[String: Any]] = facets.constructTypes.map { ["type": $0.type, "count": $0.count] }
      
      let result: [String: Any] = [
        "modulePaths": modulePaths,
        "featureTags": featureTags,
        "languages": languages,
        "constructTypes": constructTypes
      ]
      return (200, makeResult(id: id, result: result))
    } catch {
      await delegate.logWarning("RAG facets query failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.dependencies (Issue #176)
  
  private func handleDependencies(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard let filePath = optionalString("filePath", from: arguments) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "filePath is required"))
    }
    guard let repoPath = optionalString("repoPath", from: arguments) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "repoPath is required"))
    }
    
    do {
      let deps = try await delegate.getDependencies(filePath: filePath, repoPath: repoPath)
      
      let result: [String: Any] = [
        "filePath": filePath,
        "repoPath": repoPath,
        "dependencies": deps.map { $0.toDict() },
        "count": deps.count
      ]
      return (200, makeResult(id: id, result: result))
    } catch {
      await delegate.logWarning("RAG dependencies query failed", metadata: ["error": error.localizedDescription, "filePath": filePath])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.dependents (Issue #176)
  
  private func handleDependents(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard let filePath = optionalString("filePath", from: arguments) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "filePath is required"))
    }
    guard let repoPath = optionalString("repoPath", from: arguments) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "repoPath is required"))
    }
    
    do {
      let deps = try await delegate.getDependents(filePath: filePath, repoPath: repoPath)
      
      let result: [String: Any] = [
        "filePath": filePath,
        "repoPath": repoPath,
        "dependents": deps.map { $0.toDict() },
        "count": deps.count
      ]
      return (200, makeResult(id: id, result: result))
    } catch {
      await delegate.logWarning("RAG dependents query failed", metadata: ["error": error.localizedDescription, "filePath": filePath])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.orphans (Issue #248)
  
  private func handleOrphans(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard let repoPath = optionalString("repoPath", from: arguments) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "repoPath is required"))
    }
    
    let excludeTests = optionalBool("excludeTests", from: arguments, default: true)
    let excludeEntryPoints = optionalBool("excludeEntryPoints", from: arguments, default: true)
    let limit = optionalInt("limit", from: arguments) ?? 50
    
    do {
      let orphans = try await delegate.findOrphans(
        repoPath: repoPath,
        excludeTests: excludeTests,
        excludeEntryPoints: excludeEntryPoints,
        limit: limit
      )
      
      let result: [String: Any] = [
        "repoPath": repoPath,
        "orphans": orphans.map { $0.toDict() },
        "count": orphans.count,
        "excludeTests": excludeTests,
        "excludeEntryPoints": excludeEntryPoints,
        "note": "Files with no imports/requires pointing to them AND no type references from other files. May still be used via dynamic loading, reflection, or as entry points."
      ]
      return (200, makeResult(id: id, result: result))
    } catch {
      await delegate.logWarning("RAG orphans query failed", metadata: ["error": error.localizedDescription, "repoPath": repoPath])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.structural (Issue #174)
  
  private func handleStructural(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard let repoPath = optionalString("repoPath", from: arguments) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "repoPath is required"))
    }
    
    // Parse optional filter criteria
    let minLines = optionalInt("minLines", from: arguments)
    let maxLines = optionalInt("maxLines", from: arguments)
    let minMethods = optionalInt("minMethods", from: arguments)
    let maxMethods = optionalInt("maxMethods", from: arguments)
    let minBytes = optionalInt("minBytes", from: arguments)
    let maxBytes = optionalInt("maxBytes", from: arguments)
    let language = optionalString("language", from: arguments)
    let sortBy = optionalString("sortBy", from: arguments) ?? "lines"
    let limit = optionalInt("limit", from: arguments) ?? 50
    
    // Check if we want stats only
    let statsOnly = optionalBool("statsOnly", from: arguments, default: false)
    
    do {
      if statsOnly {
        let stats = try await delegate.getStructuralStats(repoPath: repoPath)
        
        var result: [String: Any] = [
          "repoPath": repoPath,
          "totalFiles": stats.totalFiles,
          "totalLines": stats.totalLines,
          "totalMethods": stats.totalMethods,
          "avgLinesPerFile": stats.avgLinesPerFile,
          "avgMethodsPerFile": stats.avgMethodsPerFile
        ]
        
        if let largest = stats.largestFile {
          result["largestFile"] = ["path": largest.path, "lines": largest.lines]
        }
        if let mostMethods = stats.mostMethods {
          result["mostMethods"] = ["path": mostMethods.path, "count": mostMethods.count]
        }
        
        return (200, makeResult(id: id, result: result))
      } else {
        let files = try await delegate.queryFilesByStructure(
          repoPath: repoPath,
          minLines: minLines,
          maxLines: maxLines,
          minMethods: minMethods,
          maxMethods: maxMethods,
          minBytes: minBytes,
          maxBytes: maxBytes,
          language: language,
          sortBy: sortBy,
          limit: limit
        )
        
        let result: [String: Any] = [
          "repoPath": repoPath,
          "files": files.map { file in
            var dict: [String: Any] = [
              "path": file.path,
              "language": file.language,
              "lineCount": file.lineCount,
              "methodCount": file.methodCount,
              "byteSize": file.byteSize
            ]
            if let modulePath = file.modulePath {
              dict["modulePath"] = modulePath
            }
            return dict
          },
          "count": files.count,
          "filters": [
            "minLines": minLines as Any,
            "maxLines": maxLines as Any,
            "minMethods": minMethods as Any,
            "maxMethods": maxMethods as Any,
            "minBytes": minBytes as Any,
            "maxBytes": maxBytes as Any,
            "language": language as Any,
            "sortBy": sortBy,
            "limit": limit
          ]
        ]
        return (200, makeResult(id: id, result: result))
      }
    } catch {
      await delegate.logWarning("RAG structural query failed", metadata: ["error": error.localizedDescription, "repoPath": repoPath])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.similar (Issue #175)
  
  private func handleSimilar(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard let query = optionalString("query", from: arguments), !query.isEmpty else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "query is required (code snippet or text to find similar code for)"))
    }
    
    let repoPath = optionalString("repoPath", from: arguments)
    let threshold = optionalDouble("threshold", from: arguments) ?? 0.6
    let limit = optionalInt("limit", from: arguments) ?? 10
    let excludePath = optionalString("excludePath", from: arguments)
    
    do {
      let results = try await delegate.findSimilarCode(
        query: query,
        repoPath: repoPath,
        threshold: threshold,
        limit: limit,
        excludePath: excludePath
      )
      
      let response: [String: Any] = [
        "query": String(query.prefix(100)) + (query.count > 100 ? "..." : ""),
        "threshold": threshold,
        "results": results.map { r in
          var dict: [String: Any] = [
            "path": r.path,
            "startLine": r.startLine,
            "endLine": r.endLine,
            "similarity": r.similarity,
            "snippet": r.snippet
          ]
          if let ct = r.constructType {
            dict["constructType"] = ct
          }
          if let cn = r.constructName {
            dict["constructName"] = cn
          }
          return dict
        },
        "count": results.count
      ]
      
      return (200, makeResult(id: id, result: response))
    } catch {
      await delegate.logWarning("RAG similar search failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.reranker.config (Issue #128)
  
  private func handleRerankerConfig(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let action = optionalString("action", from: arguments, default: "get") ?? "get"
    
    switch action {
    case "get":
      // Return current configuration
      let result: [String: Any] = [
        "enabled": HFRerankerFactory.isEnabled,
        "modelId": HFRerankerFactory.modelId,
        "hasApiToken": HFRerankerFactory.apiToken != nil,
        "availableModels": HFRerankerFactory.availableModels.map { model in
          [
            "id": model.id,
            "name": model.name,
            "description": model.description
          ]
        }
      ]
      return (200, makeResult(id: id, result: result))
      
    case "set":
      // Update configuration
      if let enabled = arguments["enabled"] as? Bool {
        HFRerankerFactory.isEnabled = enabled
      }
      if let modelId = optionalString("modelId", from: arguments), !modelId.isEmpty {
        HFRerankerFactory.modelId = modelId
      }
      if let apiToken = optionalString("apiToken", from: arguments) {
        HFRerankerFactory.apiToken = apiToken.isEmpty ? nil : apiToken
      }
      
      let result: [String: Any] = [
        "message": "Reranker configuration updated",
        "enabled": HFRerankerFactory.isEnabled,
        "modelId": HFRerankerFactory.modelId,
        "hasApiToken": HFRerankerFactory.apiToken != nil
      ]
      return (200, makeResult(id: id, result: result))
      
    case "test":
      // Test the reranker with a sample query
      return (200, makeResult(id: id, result: [
        "message": "Use rag.search with rerank=true to test reranking",
        "enabled": HFRerankerFactory.isEnabled,
        "modelId": HFRerankerFactory.modelId
      ]))
      
    default:
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Unknown action: \(action). Use 'get', 'set', or 'test'"))
    }
  }
  
  // MARK: - AI Analysis (#198)
  
  #if os(macOS)
  private func handleAnalyze(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    let limit = arguments["limit"] as? Int ?? 100
    let tierString = optionalString("modelTier", from: arguments)
    
    // Parse model tier from argument or default to auto
    let modelTier: MLXAnalyzerModelTier
    if let tierString = tierString {
      switch tierString.lowercased() {
      case "tiny": modelTier = .tiny
      case "small": modelTier = .small
      case "medium": modelTier = .medium
      case "large": modelTier = .large
      default: modelTier = .auto
      }
    } else {
      modelTier = .auto
    }
    
    do {
      // Check if there are chunks to analyze
      let unanalyzedCount = try await delegate.getUnanalyzedChunkCount(repoPath: repoPath)
      if unanalyzedCount == 0 {
        return (200, makeResult(id: id, result: [
          "message": "No un-analyzed chunks found",
          "chunksAnalyzed": 0,
          "unanalyzedRemaining": 0
        ]))
      }
      
      // Get recommended model info
      let recommendedTier = MLXCodeAnalyzerFactory.recommendedTierDescription()
      
      // Run analysis
      let startTime = Date()
      let analyzedCount = try await delegate.analyzeRagChunks(repoPath: repoPath, limit: limit, modelTier: modelTier) { current, total in
        // Progress callback - could be used for streaming updates
        print("[RAG] Analyzing chunk \(current)/\(total)")
      }
      let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
      
      // Get updated counts
      let newUnanalyzedCount = try await delegate.getUnanalyzedChunkCount(repoPath: repoPath)
      let totalAnalyzed = try await delegate.getAnalyzedChunkCount(repoPath: repoPath)
      
      return (200, makeResult(id: id, result: [
        "message": "AI analysis complete",
        "chunksAnalyzed": analyzedCount,
        "durationMs": durationMs,
        "unanalyzedRemaining": newUnanalyzedCount,
        "totalAnalyzed": totalAnalyzed,
        "modelRecommendation": recommendedTier
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  private func handleAnalyzeStatus(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    
    do {
      let analyzedCount = try await delegate.getAnalyzedChunkCount(repoPath: repoPath)
      let unanalyzedCount = try await delegate.getUnanalyzedChunkCount(repoPath: repoPath)
      let totalChunks = analyzedCount + unanalyzedCount
      let percentAnalyzed = totalChunks > 0 ? Double(analyzedCount) / Double(totalChunks) * 100 : 0
      
      // Get recommended model info
      let recommendedTier = MLXCodeAnalyzerFactory.recommendedTierDescription()
      
      var result: [String: Any] = [
        "analyzedChunks": analyzedCount,
        "unanalyzedChunks": unanalyzedCount,
        "totalChunks": totalChunks,
        "percentAnalyzed": String(format: "%.1f", percentAnalyzed),
        "modelRecommendation": recommendedTier
      ]
      
      if let repoPath {
        result["repoPath"] = repoPath
      }
      
      return (200, makeResult(id: id, result: result))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.enrich
  
  private func handleEnrich(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    let limit = arguments["limit"] as? Int ?? 500
    
    do {
      // Check if there are chunks to enrich
      let unenrichedCount = try await delegate.getUnenrichedChunkCount(repoPath: repoPath)
      if unenrichedCount == 0 {
        let enrichedCount = try await delegate.getEnrichedChunkCount(repoPath: repoPath)
        return (200, makeResult(id: id, result: [
          "message": enrichedCount > 0
            ? "All analyzed chunks are already enriched"
            : "No analyzed chunks found. Run rag.analyze first to generate AI summaries.",
          "chunksEnriched": 0,
          "totalEnriched": enrichedCount,
          "unenrichedRemaining": 0
        ]))
      }
      
      // Run enrichment
      let startTime = Date()
      let enrichedCount = try await delegate.enrichRagEmbeddings(repoPath: repoPath, limit: limit) { current, total in
        print("[RAG] Enriching embedding \(current)/\(total)")
      }
      let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
      
      // Get updated counts
      let newUnenrichedCount = try await delegate.getUnenrichedChunkCount(repoPath: repoPath)
      let totalEnriched = try await delegate.getEnrichedChunkCount(repoPath: repoPath)
      
      return (200, makeResult(id: id, result: [
        "message": "Embedding enrichment complete — vector search now includes AI semantic context",
        "chunksEnriched": enrichedCount,
        "durationMs": durationMs,
        "unenrichedRemaining": newUnenrichedCount,
        "totalEnriched": totalEnriched
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  private func handleEnrichStatus(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    
    do {
      let enrichedCount = try await delegate.getEnrichedChunkCount(repoPath: repoPath)
      let unenrichedCount = try await delegate.getUnenrichedChunkCount(repoPath: repoPath)
      let analyzedCount = try await delegate.getAnalyzedChunkCount(repoPath: repoPath)
      let totalChunks = analyzedCount + (try await delegate.getUnanalyzedChunkCount(repoPath: repoPath))
      let percentEnriched = analyzedCount > 0 ? Double(enrichedCount) / Double(analyzedCount) * 100 : 0
      
      var result: [String: Any] = [
        "enrichedChunks": enrichedCount,
        "unenrichedChunks": unenrichedCount,
        "analyzedChunks": analyzedCount,
        "totalChunks": totalChunks,
        "percentEnriched": String(format: "%.1f", percentEnriched),
        "hint": unenrichedCount > 0
          ? "Run rag.enrich to re-embed \(unenrichedCount) chunks with AI summaries for better vector search"
          : enrichedCount > 0
            ? "All analyzed chunks have enriched embeddings"
            : "Run rag.analyze first, then rag.enrich"
      ]
      
      if let repoPath {
        result["repoPath"] = repoPath
      }
      
      return (200, makeResult(id: id, result: result))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }

  // MARK: - rag.duplicates

  private func handleDuplicates(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    let minFiles = optionalInt("minFiles", from: arguments) ?? 2
    let sortBy = optionalString("sortBy", from: arguments) ?? "wastedTokens"
    let limit = optionalInt("limit", from: arguments) ?? 25

    // Parse constructTypes array or comma-separated string
    var constructTypes: [String]? = nil
    if let typesArray = arguments["constructTypes"] as? [String] {
      constructTypes = typesArray
    } else if let typesStr = optionalString("constructTypes", from: arguments) {
      constructTypes = typesStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    do {
      let groups = try await delegate.findRagDuplicates(
        repoPath: repoPath,
        minFiles: minFiles,
        constructTypes: constructTypes,
        sortBy: sortBy,
        limit: limit
      )

      let totalWasted = groups.reduce(0) { $0 + $1.wastedTokens }

      let items: [[String: Any]] = groups.map { group in
        var item: [String: Any] = [
          "constructName": group.constructName,
          "constructType": group.constructType,
          "fileCount": group.fileCount,
          "totalTokens": group.totalTokens,
          "wastedTokens": group.wastedTokens,
          "files": group.files.map { ["path": $0.path, "tokenCount": $0.tokenCount] }
        ]
        if let summary = group.aiSummary {
          item["aiSummary"] = summary
        }
        return item
      }

      var result: [String: Any] = [
        "duplicateGroups": items,
        "groupCount": groups.count,
        "totalWastedTokens": totalWasted,
        "hint": groups.isEmpty
          ? "No duplicates found. Run rag.analyze first if chunks are not yet analyzed."
          : "Found \(groups.count) duplicate groups with ~\(totalWasted) wasted tokens. Top candidates can be consolidated into shared modules."
      ]

      if let repoPath {
        result["repoPath"] = repoPath
      }

      return (200, makeResult(id: id, result: result))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }

  // MARK: - rag.patterns

  private func handlePatterns(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    let constructType = optionalString("constructType", from: arguments)
    let limit = optionalInt("limit", from: arguments) ?? 30

    do {
      let groups = try await delegate.findRagPatterns(
        repoPath: repoPath,
        constructType: constructType,
        limit: limit
      )

      let totalConstructs = groups.reduce(0) { $0 + $1.count }
      let otherCount = groups.first(where: { $0.suffix == "(other)" })?.count ?? 0
      let conventionRate = totalConstructs > 0
        ? Double(totalConstructs - otherCount) / Double(totalConstructs) * 100
        : 0

      let items: [[String: Any]] = groups.map { group in
        [
          "suffix": group.suffix,
          "count": group.count,
          "totalTokens": group.totalTokens,
          "samples": group.samples.map { [
            "name": $0.constructName,
            "path": $0.path,
            "tokenCount": $0.tokenCount
          ] }
        ]
      }

      var result: [String: Any] = [
        "patterns": items,
        "totalConstructs": totalConstructs,
        "conventionRate": String(format: "%.1f%%", conventionRate),
        "otherCount": otherCount,
        "hint": otherCount > 0
          ? "\(otherCount) constructs lack a standard suffix. Review '(other)' samples to determine if they should follow a naming convention."
          : "All constructs follow a recognized naming pattern."
      ]

      if let repoPath {
        result["repoPath"] = repoPath
      }

      return (200, makeResult(id: id, result: result))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }

  // MARK: - rag.hotspots

  private func handleHotspots(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    let constructType = optionalString("constructType", from: arguments)
    let minTokens = optionalInt("minTokens", from: arguments) ?? 5000
    let limit = optionalInt("limit", from: arguments) ?? 30

    do {
      let hotspots = try await delegate.findRagHotspots(
        repoPath: repoPath,
        constructType: constructType,
        minTokens: minTokens,
        limit: limit
      )

      let totalTokens = hotspots.reduce(0) { $0 + $1.tokenCount }

      let items: [[String: Any]] = hotspots.map { spot in
        var item: [String: Any] = [
          "constructName": spot.constructName,
          "constructType": spot.constructType,
          "filePath": spot.filePath,
          "tokenCount": spot.tokenCount,
          "startLine": spot.startLine,
          "endLine": spot.endLine,
          "lineCount": spot.endLine - spot.startLine + 1
        ]
        if let summary = spot.aiSummary {
          item["aiSummary"] = summary
        }
        if !spot.aiTags.isEmpty {
          item["aiTags"] = spot.aiTags
        }
        return item
      }

      var result: [String: Any] = [
        "hotspots": items,
        "count": hotspots.count,
        "totalTokens": totalTokens,
        "minTokenThreshold": minTokens,
        "hint": hotspots.isEmpty
          ? "No constructs exceed \(minTokens) tokens. Try lowering minTokens."
          : "Found \(hotspots.count) constructs >= \(minTokens) tokens totaling \(totalTokens) tokens. These are refactoring candidates — consider splitting into smaller, focused components."
      ]

      if let repoPath {
        result["repoPath"] = repoPath
      }

      return (200, makeResult(id: id, result: result))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }

  #endif
  
  // MARK: - rag.scratch (Issue #111)
  
  /// Get or manage per-repo scratch directory for artifacts
  private func handleScratch(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let action = optionalString("action", from: arguments, default: "get") ?? "get"
    
    switch action {
    case "get":
      // Get scratch directory for a specific repo
      guard let repoPath = optionalString("repoPath", from: arguments) else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "repoPath is required for action 'get'"))
      }
      
      do {
        let scratchDir = try ScratchAreaService.scratchDirectory(for: repoPath)
        return (200, makeResult(id: id, result: [
          "action": "get",
          "repoPath": repoPath,
          "scratchPath": scratchDir.path,
          "note": "Use this path for storing artifacts (screenshots, diffs, temp outputs)"
        ]))
      } catch {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
      }
      
    case "list":
      // List all scratch directories with sizes
      do {
        let directories = try ScratchAreaService.listScratchDirectories()
        let totalSize = directories.reduce(0) { $0 + $1.sizeBytes }
        
        let items = directories.map { dir -> [String: Any] in
          [
            "repoHash": dir.repoHash,
            "path": dir.path.path,
            "sizeBytes": dir.sizeBytes,
            "sizeHuman": formatBytes(dir.sizeBytes)
          ]
        }
        
        return (200, makeResult(id: id, result: [
          "action": "list",
          "directories": items,
          "totalCount": directories.count,
          "totalSizeBytes": totalSize,
          "totalSizeHuman": formatBytes(totalSize)
        ]))
      } catch {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
      }
      
    case "delete":
      // Delete scratch directory for a specific repo
      guard let repoPath = optionalString("repoPath", from: arguments) else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "repoPath is required for action 'delete'"))
      }
      
      do {
        try ScratchAreaService.deleteScratchDirectory(for: repoPath)
        return (200, makeResult(id: id, result: [
          "action": "delete",
          "repoPath": repoPath,
          "status": "deleted"
        ]))
      } catch {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
      }
      
    case "deleteAll":
      // Delete all scratch directories
      do {
        try ScratchAreaService.deleteAllScratchDirectories()
        return (200, makeResult(id: id, result: [
          "action": "deleteAll",
          "status": "deleted"
        ]))
      } catch {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
      }
      
    default:
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Invalid action: \(action). Valid actions: get, list, delete, deleteAll"))
    }
  }
  
  private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }

  // MARK: - rag.branch.index (Issue #260)

  private func handleBranchIndex(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate?) async -> (Int, Data) {
    guard let delegate else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "RAG delegate unavailable"))
    }
    guard let repoPath = optionalString("repoPath", from: arguments) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "repoPath is required"))
    }
    let baseBranch = optionalString("baseBranch", from: arguments) ?? "main"
    let baseRepoPath = optionalString("baseRepoPath", from: arguments)

    do {
      let result = try await delegate.indexBranchRepository(
        repoPath: repoPath,
        baseBranch: baseBranch,
        baseRepoPath: baseRepoPath,
        progressHandler: nil
      )
      let report = result.report
      var payload: [String: Any] = [
        "repoId": report.repoId,
        "repoPath": report.repoPath,
        "filesIndexed": report.filesIndexed,
        "filesSkipped": report.filesSkipped,
        "chunksIndexed": report.chunksIndexed,
        "bytesScanned": report.bytesScanned,
        "durationMs": report.durationMs,
        "embeddingCount": report.embeddingCount,
        "changedFilesCount": result.changedFilesCount,
        "deletedFilesCount": result.deletedFilesCount,
        "wasCopiedFromBase": result.wasCopiedFromBase,
      ]
      if let base = result.baseRepoPath {
        payload["baseRepoPath"] = base
      }
      return (200, makeResult(id: id, result: payload))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }

  // MARK: - rag.branch.cleanup (Issue #260)

  private func handleBranchCleanup(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate?) async -> (Int, Data) {
    guard let delegate else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "RAG delegate unavailable"))
    }
    let dryRun = optionalBool("dryRun", from: arguments, default: false)

    do {
      let result = try await delegate.cleanupBranchIndexes(dryRun: dryRun)
      return (200, makeResult(id: id, result: [
        "removedCount": result.removedCount,
        "removedPaths": result.removedPaths,
        "dryRun": dryRun,
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }

  // MARK: - Helpers

  
  private func encodeSkill(_ skill: RepoGuidanceSkill, formatter: ISO8601DateFormatter) -> [String: Any] {
    var payload: [String: Any] = [
      "id": skill.id.uuidString,
      "repoPath": skill.repoPath,
      "repoRemoteURL": skill.repoRemoteURL,
      "repoName": skill.repoName,
      "title": skill.title,
      "body": skill.body,
      "source": skill.source,
      "tags": skill.tags,
      "priority": skill.priority,
      "isActive": skill.isActive,
      "appliedCount": skill.appliedCount,
      "createdAt": formatter.string(from: skill.createdAt),
      "updatedAt": formatter.string(from: skill.updatedAt)
    ]
    if let lastAppliedAt = skill.lastAppliedAt {
      payload["lastAppliedAt"] = formatter.string(from: lastAppliedAt)
    }
    return payload
  }
  
  private func optionalDouble(_ key: String, from arguments: [String: Any]) -> Double? {
    if let value = arguments[key] as? Double {
      return value
    }
    if let value = arguments[key] as? Int {
      return Double(value)
    }
    return nil
  }
}

// MARK: - Supporting Types (Prefixed to avoid conflicts with existing types)

/// RAG search result structure used by RAGToolsHandler
struct RAGToolSearchResult {
  let filePath: String
  let startLine: Int
  let endLine: Int
  let snippet: String
  let isTest: Bool
  let lineCount: Int
  let constructType: String?
  let constructName: String?
  let language: String?
  let score: Double?
  // Facets (schema v4+)
  let modulePath: String?
  let featureTags: [String]
  // AI analysis (schema v7+)
  let aiSummary: String?
  let aiTags: [String]
  /// Token count for the original code chunk
  let tokenCount: Int?
  
  init(filePath: String, startLine: Int, endLine: Int, snippet: String, isTest: Bool, lineCount: Int, constructType: String? = nil, constructName: String? = nil, language: String? = nil, score: Double? = nil, modulePath: String? = nil, featureTags: [String] = [], aiSummary: String? = nil, aiTags: [String] = [], tokenCount: Int? = nil) {
    self.filePath = filePath
    self.startLine = startLine
    self.endLine = endLine
    self.snippet = snippet
    self.isTest = isTest
    self.lineCount = lineCount
    self.constructType = constructType
    self.constructName = constructName
    self.language = language
    self.score = score
    self.modulePath = modulePath
    self.featureTags = featureTags
    self.aiSummary = aiSummary
    self.aiTags = aiTags
    self.tokenCount = tokenCount
  }
}

/// RAG database status used by RAGToolsHandler
struct RAGToolStatus {
  let dbPath: String
  let exists: Bool
  let schemaVersion: Int
  let extensionLoaded: Bool
  let providerName: String
  let embeddingModelName: String
  let embeddingDimensions: Int
  let lastInitializedAt: Date?
  
  init(dbPath: String, exists: Bool, schemaVersion: Int, extensionLoaded: Bool, providerName: String, embeddingModelName: String, embeddingDimensions: Int, lastInitializedAt: Date?) {
    self.dbPath = dbPath
    self.exists = exists
    self.schemaVersion = schemaVersion
    self.extensionLoaded = extensionLoaded
    self.providerName = providerName
    self.embeddingModelName = embeddingModelName
    self.embeddingDimensions = embeddingDimensions
    self.lastInitializedAt = lastInitializedAt
  }
}

/// RAG indexing report used by RAGToolsHandler
struct RAGToolIndexReport {
  let repoId: String
  let repoPath: String
  let filesIndexed: Int
  let filesSkipped: Int
  let filesRemoved: Int
  let chunksIndexed: Int
  let bytesScanned: Int
  let durationMs: Int
  let embeddingCount: Int
  let embeddingDurationMs: Int
  let subReports: [RAGToolIndexReport]
  
  init(repoId: String, repoPath: String, filesIndexed: Int, filesSkipped: Int, filesRemoved: Int = 0, chunksIndexed: Int, bytesScanned: Int, durationMs: Int, embeddingCount: Int, embeddingDurationMs: Int, subReports: [RAGToolIndexReport] = []) {
    self.repoId = repoId
    self.repoPath = repoPath
    self.filesIndexed = filesIndexed
    self.filesSkipped = filesSkipped
    self.filesRemoved = filesRemoved
    self.chunksIndexed = chunksIndexed
    self.bytesScanned = bytesScanned
    self.durationMs = durationMs
    self.embeddingCount = embeddingCount
    self.embeddingDurationMs = embeddingDurationMs
    self.subReports = subReports
  }
}

/// RAG index progress used by RAGToolsHandler
enum RAGToolIndexProgress {
  case scanning(filesFound: Int)
  case indexing(current: Int, total: Int)
  case embedding(current: Int, total: Int)
  case complete(report: RAGToolIndexReport)
}

/// RAG repository info used by RAGToolsHandler
struct RAGToolRepoInfo {
  let id: String
  let name: String
  let rootPath: String
  let fileCount: Int
  let chunkCount: Int
  let lastIndexedAt: Date?
  let repoIdentifier: String?
  let parentRepoId: String?
  
  init(id: String, name: String, rootPath: String, fileCount: Int, chunkCount: Int, lastIndexedAt: Date?, repoIdentifier: String? = nil, parentRepoId: String? = nil) {
    self.id = id
    self.name = name
    self.rootPath = rootPath
    self.fileCount = fileCount
    self.chunkCount = chunkCount
    self.lastIndexedAt = lastIndexedAt
    self.repoIdentifier = repoIdentifier
    self.parentRepoId = parentRepoId
  }
}

/// RAG index statistics used by RAGToolsHandler
struct RAGToolIndexStats {
  let fileCount: Int
  let chunkCount: Int
  let embeddingCount: Int
  let totalLines: Int
  let dependencyCount: Int
  let dependenciesByType: [String: Int]
  
  init(fileCount: Int, chunkCount: Int, embeddingCount: Int, totalLines: Int, dependencyCount: Int = 0, dependenciesByType: [String: Int] = [:]) {
    self.fileCount = fileCount
    self.chunkCount = chunkCount
    self.embeddingCount = embeddingCount
    self.totalLines = totalLines
    self.dependencyCount = dependencyCount
    self.dependenciesByType = dependenciesByType
  }
}

/// RAG large file info used by RAGToolsHandler
struct RAGToolLargeFile {
  let path: String
  let totalLines: Int
  let chunkCount: Int
  let language: String?
  
  init(path: String, totalLines: Int, chunkCount: Int, language: String?) {
    self.path = path
    self.totalLines = totalLines
    self.chunkCount = chunkCount
    self.language = language
  }
}

/// RAG construct type statistic used by RAGToolsHandler
struct RAGToolConstructTypeStat {
  let type: String
  let count: Int
  
  init(type: String, count: Int) {
    self.type = type
    self.count = count
  }
}

/// RAG overall stats used by RAGToolsHandler
struct RAGToolStats {
  let repoCount: Int
  let fileCount: Int
  let chunkCount: Int
  let embeddingCount: Int
  let cacheEmbeddingCount: Int
  let dbSizeBytes: Int
  let lastIndexedAt: Date?
  let lastIndexedRepoPath: String?
  
  init(repoCount: Int, fileCount: Int, chunkCount: Int, embeddingCount: Int, cacheEmbeddingCount: Int, dbSizeBytes: Int, lastIndexedAt: Date?, lastIndexedRepoPath: String?) {
    self.repoCount = repoCount
    self.fileCount = fileCount
    self.chunkCount = chunkCount
    self.embeddingCount = embeddingCount
    self.cacheEmbeddingCount = cacheEmbeddingCount
    self.dbSizeBytes = dbSizeBytes
    self.lastIndexedAt = lastIndexedAt
    self.lastIndexedRepoPath = lastIndexedRepoPath
  }
}

/// RAG facet counts for filtering/grouping search results
struct RAGToolFacetCounts {
  let modulePaths: [(path: String, count: Int)]
  let featureTags: [(tag: String, count: Int)]
  let languages: [(language: String, count: Int)]
  let constructTypes: [(type: String, count: Int)]
  
  init(modulePaths: [(path: String, count: Int)], featureTags: [(tag: String, count: Int)], languages: [(language: String, count: Int)], constructTypes: [(type: String, count: Int)]) {
    self.modulePaths = modulePaths
    self.featureTags = featureTags
    self.languages = languages
    self.constructTypes = constructTypes
  }
}

/// RAG dependency result for dependency graph queries (Issue #176)
struct RAGToolDependencyResult {
  let sourceFile: String           // Relative path of source file
  let targetPath: String           // Module/path being depended on
  let targetFile: String?          // Resolved target file (if in repo)
  let dependencyType: String       // "import", "require", "inherit", "conform", "include", "extend"
  let rawImport: String            // Original import statement
  
  init(sourceFile: String, targetPath: String, targetFile: String?, dependencyType: String, rawImport: String) {
    self.sourceFile = sourceFile
    self.targetPath = targetPath
    self.targetFile = targetFile
    self.dependencyType = dependencyType
    self.rawImport = rawImport
  }
  
  /// Convert to dictionary for JSON response
  func toDict() -> [String: Any] {
    var dict: [String: Any] = [
      "sourceFile": sourceFile,
      "targetPath": targetPath,
      "dependencyType": dependencyType,
      "rawImport": rawImport
    ]
    if let targetFile {
      dict["targetFile"] = targetFile
    }
    return dict
  }
}

/// RAG orphan result for finding unused files (Issue #248)
struct RAGToolOrphanResult {
  let filePath: String
  let language: String
  let lineCount: Int
  let symbolsDefinedCount: Int
  let symbolsDefined: [String]
  let reason: String
  
  /// Convert to dictionary for JSON response
  func toDict() -> [String: Any] {
    return [
      "filePath": filePath,
      "language": language,
      "lineCount": lineCount,
      "symbolsDefinedCount": symbolsDefinedCount,
      "symbolsDefined": symbolsDefined,
      "reason": reason
    ]
  }
}

/// RAG structural query result for Issue #174
struct RAGToolStructuralResult {
  let path: String
  let language: String
  let lineCount: Int
  let methodCount: Int
  let byteSize: Int
  let modulePath: String?
  
  init(path: String, language: String, lineCount: Int, methodCount: Int, byteSize: Int, modulePath: String?) {
    self.path = path
    self.language = language
    self.lineCount = lineCount
    self.methodCount = methodCount
    self.byteSize = byteSize
    self.modulePath = modulePath
  }
}

/// RAG similar code result for Issue #175
struct RAGToolSimilarResult {
  let path: String
  let startLine: Int
  let endLine: Int
  let snippet: String
  let similarity: Double
  let constructType: String?
  let constructName: String?
  
  init(path: String, startLine: Int, endLine: Int, snippet: String, similarity: Double, constructType: String?, constructName: String?) {
    self.path = path
    self.startLine = startLine
    self.endLine = endLine
    self.snippet = snippet
    self.similarity = similarity
    self.constructType = constructType
    self.constructName = constructName
  }
}

// MARK: - Tool Definitions

extension RAGToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "rag.status",
        description: "Get Local RAG database status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.config",
        description: "Get or set RAG configuration (embedding provider, memory limits). Use action='get' to see current config, action='set' with provider='mlx' (MLX native, best for Apple Silicon), 'system' (Apple NLEmbedding), 'coreml' (CoreML), or 'hash' (fallback). Set mlxMemoryLimitGB to control max process memory before pausing indexing.",
        inputSchema: [
          "type": "object",
          "properties": [
            "action": ["type": "string", "enum": ["get", "set"], "default": "get"],
            "provider": ["type": "string", "enum": ["mlx", "coreml", "system", "hash", "auto"]],
            "reinitialize": ["type": "boolean", "default": true],
            "mlxCacheLimitMB": ["type": "integer"],
            "mlxClearCacheAfterBatch": ["type": "boolean"],
            "mlxMemoryLimitGB": ["type": "number", "description": "Max process memory (GB) before pausing indexing. Default: 80% of RAM."],
            "clearMlxCacheLimit": ["type": "boolean"]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.init",
        description: "Initialize the Local RAG database schema",
        inputSchema: [
          "type": "object",
          "properties": [
            "extensionPath": ["type": "string"]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.index",
        description: """
        Index a repository path into the Local RAG database. Use forceReindex=true to re-index all files regardless of whether they've changed.
        
        Workspace/monorepo support: If the path contains multiple git sub-repos or sub-packages \
        (directories with Package.swift, package.json, Cargo.toml, etc.), each sub-package is \
        automatically indexed as a separate repo entry with parent/child relationships tracked. \
        Use allowWorkspace=true to instead index everything as a single flat repo.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"],
            "forceReindex": ["type": "boolean", "default": false, "description": "If true, re-index all files even if unchanged. Useful after changing chunking or embedding settings."],
            "allowWorkspace": ["type": "boolean", "default": false, "description": "If true, index workspace as a single flat repo instead of auto-indexing sub-packages separately."],
            "excludeSubrepos": ["type": "boolean", "default": true, "description": "When indexing a workspace with allowWorkspace=true, skip sub-repo folders (index only workspace-level content)." ]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.branch.index",
        description: """
        Index a repository branch or worktree incrementally. Uses copy-on-branch strategy:
        1) If no existing index for this path, copies file/chunk/embedding records from the base
           repo's index (fast — avoids re-embedding unchanged files).
        2) Uses git diff to find changed files since the base branch.
        3) Force-reindexes only the changed/added files.
        4) Deleted files are naturally removed by the incremental scan.

        Use this instead of rag.index when working in a git worktree or on a feature branch
        to get fast, branch-accurate search results.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Path to the worktree or branch checkout to index"],
            "baseBranch": ["type": "string", "default": "main", "description": "The base branch to diff against for finding changed files. Default: main"],
            "baseRepoPath": ["type": "string", "description": "Optional: explicit path to the main repo. If omitted, auto-detected via git worktree list."]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.branch.cleanup",
        description: "Remove stale RAG index entries for repository paths that no longer exist on disk. Use after deleting worktrees or old branch checkouts to reclaim database space.",
        inputSchema: [
          "type": "object",
          "properties": [
            "dryRun": ["type": "boolean", "default": false, "description": "If true, report what would be removed without deleting. Default: false"]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.analyze",
        description: """
        Analyze indexed chunks using local MLX LLM to generate semantic summaries and tags.
        This runs the Qwen2.5-Coder model (hardware-adaptive size selection) on un-analyzed chunks.
        Analysis improves RAG search quality by adding semantic context. macOS only.
        
        The model tier is automatically selected based on available RAM:
        - tiny (8-12GB): Qwen2.5-Coder-0.5B
        - small (12-24GB): Qwen2.5-Coder-1.5B (default for M3 18GB)
        - medium (24-48GB): Qwen2.5-Coder-3B
        - large (48GB+): Qwen2.5-Coder-7B (best for Mac Studio)
        
        After analyzing, run rag.enrich to re-embed chunks with AI summaries for better vector search.
        Results sync via swarm, so Mac Studio can generate high-quality analysis for the team.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "limit": ["type": "integer", "description": "Max chunks to analyze (default 100)", "default": 100]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.analyze.status",
        description: "Get AI analysis status - counts of analyzed vs un-analyzed chunks (macOS only)",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.enrich",
        description: """
        Re-embed analyzed chunks using enriched text (code + AI summary) for better vector search.
        
        After running rag.analyze, chunks have AI-generated summaries but the embeddings still only
        encode the raw code. This tool re-embeds those chunks using "code + AI summary" as input,
        so vector search captures both code structure AND semantic meaning.
        
        Workflow: rag.index → rag.analyze → rag.enrich → dramatically better rag.search vector results
        
        macOS only. Safe to run incrementally — only processes chunks not yet enriched.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "limit": ["type": "integer", "description": "Max chunks to enrich (default 500)", "default": 500]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.enrich.status",
        description: "Get embedding enrichment status — how many analyzed chunks have enriched embeddings (macOS only)",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.duplicates",
        description: """
        Find duplicate/redundant code across a codebase. Returns a ranked report of all constructs
        (functions, classes, types) that appear in multiple files — the #1 tool for code dedup,
        reducing code size, finding copy-paste, and identifying consolidation opportunities.
        
        One call returns a complete ranked list sorted by wasted tokens (code that could be
        eliminated). Each group includes file paths, token counts, and AI-generated summaries
        confirming the duplicates are semantically identical.
        
        USE THIS TOOL when asked to: reduce code size, find duplicates, find redundant code,
        find copy-paste, optimize codebase, consolidate shared code, DRY violations, or
        find refactoring opportunities.
        
        Requires rag.analyze to have been run first. Examples of what it finds:
        - Utility functions copy-pasted across files (eq, gt, formatDate, etc.)
        - Service classes duplicated across apps (ApplicationAdapter, SessionContextService)
        - Component variants that could be unified with a config flag
        
        macOS only. Prefer this over rag.similar for bulk duplicate analysis.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "minFiles": ["type": "integer", "description": "Minimum number of distinct files a construct must appear in (default 2)", "default": 2],
            "constructTypes": [
              "type": "array",
              "items": ["type": "string"],
              "description": "Filter to specific construct types (e.g. ['function', 'classDecl']). Default: all except imports and file-level chunks"
            ],
            "sortBy": ["type": "string", "enum": ["wastedTokens", "fileCount", "totalTokens"], "description": "Sort order (default: wastedTokens)", "default": "wastedTokens"],
            "limit": ["type": "integer", "description": "Max groups to return (default 25)", "default": 25]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.patterns",
        description: """
        Analyze naming conventions and pattern consistency across a codebase. Returns a breakdown
        of how constructs are named — grouped by suffix (Route, Component, Service, Adapter, etc.)
        — plus a list of "other" classes that don't follow any convention.
        
        USE THIS TOOL when asked to: enforce naming conventions, find inconsistent names, audit
        code patterns, check code style, review codebase architecture, identify non-standard
        classes, or improve code consistency.
        
        Returns: convention rate (% following a pattern), count per suffix, total tokens per
        pattern, and 5 sample constructs for each group. The '(other)' group shows classes
        that lack a standard suffix — these are candidates for renaming.
        
        Requires rag.analyze to have been run first. macOS only.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "constructType": ["type": "string", "description": "Filter to a specific construct type (e.g. 'classDecl'). Default: all types."],
            "limit": ["type": "integer", "description": "Max pattern groups to return (default 30)", "default": 30]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.hotspots",
        description: """
        Find complexity hotspots — "god components" and oversized constructs that are prime
        refactoring targets. Returns constructs sorted by token count (largest first), with
        AI summaries and tags to help understand what each one does.
        
        USE THIS TOOL when asked to: find refactoring targets, identify god components, find
        large/complex code, reduce component size, improve maintainability, find code that
        needs splitting, or assess code complexity.
        
        Default threshold is 5000 tokens (~2500 lines). Adjustable via minTokens parameter.
        Results include: construct name, type, file path, token count, line range, AI summary.
        
        Requires rag.analyze to have been run first. macOS only.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "constructType": ["type": "string", "description": "Filter to a specific construct type (e.g. 'classDecl'). Default: all types."],
            "minTokens": ["type": "integer", "description": "Minimum token count threshold (default 5000)", "default": 5000],
            "limit": ["type": "integer", "description": "Max hotspots to return (default 30)", "default": 30]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.search",
        description: """
        Search indexed code content. Returns matching chunks with metadata.
        
        Modes:
        - "text" (default): Keyword search across chunk text, construct names, and AI summaries
        - "vector": Semantic similarity search using embeddings (enriched with AI summaries when available)
        
        Detail levels (IMPORTANT for context window management):
        - "full" (default): Returns code snippet + AI summary + tags + all metadata
        - "summary": Returns AI summary + tags + metadata WITHOUT code snippet (20-80x smaller). Use this for broad exploration — get an overview of what exists, then fetch specific files with full detail.
        - "minimal": Returns only path + construct name/type + token count. Smallest possible response for listing/counting.
        
        Strategy: Start with detail:"summary" for broad queries, then use detail:"full" on specific results you need code for.
        
        Filters:
        - excludeTests: Skip test/spec files
        - constructType: Filter by type (e.g., "component", "function", "classDecl")
        - modulePath: Filter by module path (e.g., "Shared/Services")
        - featureTag: Filter by feature tag (e.g., "rag", "mcp", "agent")
        - matchAll: For text mode - true=AND all words, false=OR any word (default true)
        
        Reranking:
        - rerank: Enable HuggingFace cross-encoder reranking for better relevance. Must configure with rag.reranker.config first.
        
        Results include: filePath, startLine, endLine, constructType, name, tokenCount, isTest, lineCount + (depending on detail level) snippet, aiSummary, aiTags, language, score, modulePath, featureTags
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "query": ["type": "string", "description": "Search query"],
            "repoPath": ["type": "string", "description": "Filter to specific repo"],
            "limit": ["type": "integer", "description": "Max results (default 10)"],
            "mode": ["type": "string", "enum": ["text", "vector"], "description": "Search mode: text (keyword) or vector (semantic)"],
            "detail": ["type": "string", "enum": ["full", "summary", "minimal"], "description": "Response detail level. 'summary' returns AI summaries instead of code (20-80x smaller context). 'minimal' returns only paths and construct names. Default: 'full'"],
            "excludeTests": ["type": "boolean", "description": "Exclude test/spec files"],
            "constructType": ["type": "string", "description": "Filter by construct type"],
            "modulePath": ["type": "string", "description": "Filter by module path (e.g., 'Shared/Services')"],
            "featureTag": ["type": "string", "description": "Filter by feature tag (e.g., 'rag', 'mcp')"],
            "matchAll": ["type": "boolean", "description": "Text mode: true=AND all words, false=OR any word"],
            "rerank": ["type": "boolean", "description": "Apply HF cross-encoder reranking for improved relevance (requires rag.reranker.config setup)"]
          ],
          "required": ["query"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.queryHints",
        description: "Return recent successful RAG queries with result counts.",
        inputSchema: [
          "type": "object",
          "properties": [
            "limit": ["type": "integer", "description": "Max hints to return (default 10)"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.cache.clear",
        description: "Clear cached embeddings (cache_embeddings table)",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.model.describe",
        description: "Describe the current embedding model (MLX, CoreML, System, or Hash)",
        inputSchema: [
          "type": "object",
          "properties": [
            "modelName": ["type": "string"],
            "extension": ["type": "string"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.model.list",
        description: "List available MLX embedding models and current preference",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.model.set",
        description: "Set preferred MLX embedding model by modelId (HuggingFace id or name). Use empty to reset to auto.",
        inputSchema: [
          "type": "object",
          "properties": [
            "modelId": ["type": "string"],
            "reinitialize": ["type": "boolean", "default": true]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.embedding.test",
        description: "Test embedding generation with sample texts. Returns embeddings and timing info.",
        inputSchema: [
          "type": "object",
          "properties": [
            "texts": ["type": "array", "items": ["type": "string"], "description": "Array of texts to embed (max 5)"],
            "showVectors": ["type": "boolean", "default": false, "description": "Include first 10 values of each vector"]
          ],
          "required": ["texts"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.ui.status",
        description: "Get Local RAG dashboard status snapshot",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.skills.list",
        description: "List repo guidance skills",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"],
            "repoRemoteURL": ["type": "string"],
            "includeInactive": ["type": "boolean"],
            "limit": ["type": "integer"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.skills.add",
        description: "Add a repo guidance skill",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"],
            "repoRemoteURL": ["type": "string"],
            "repoName": ["type": "string"],
            "title": ["type": "string"],
            "body": ["type": "string"],
            "source": ["type": "string"],
            "tags": ["type": "string"],
            "priority": ["type": "integer"],
            "isActive": ["type": "boolean"]
          ],
          "required": ["title", "body"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.skills.update",
        description: "Update a repo guidance skill",
        inputSchema: [
          "type": "object",
          "properties": [
            "skillId": ["type": "string"],
            "repoPath": ["type": "string"],
            "repoRemoteURL": ["type": "string"],
            "repoName": ["type": "string"],
            "title": ["type": "string"],
            "body": ["type": "string"],
            "source": ["type": "string"],
            "tags": ["type": "string"],
            "priority": ["type": "integer"],
            "isActive": ["type": "boolean"]
          ],
          "required": ["skillId"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.skills.delete",
        description: "Delete a repo guidance skill",
        inputSchema: [
          "type": "object",
          "properties": [
            "skillId": ["type": "string"]
          ],
          "required": ["skillId"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.skills.ember.detect",
        description: "Detect if a repository is an Ember project and check if Ember best-practice skills are loaded. Returns isEmberProject, alreadySeeded, emberSkillCount, and bundledVersion.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.skills.ember.update",
        description: "Manage bundled Ember best-practice skills. Actions: 'check' (check for updates), 'seed' (add skills), 'update' (force update), 'remove' (delete Ember skills).",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"],
            "action": ["type": "string", "enum": ["check", "seed", "update", "remove"], "description": "Action to perform: check, seed, update, or remove"]
          ],
          "required": ["repoPath", "action"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.lessons.list",
        description: "List lessons learned from agent fixes. Lessons capture recurring error patterns and their fixes to help prevent future mistakes.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"],
            "includeInactive": ["type": "boolean", "description": "Include deactivated lessons (default: false)"],
            "limit": ["type": "integer", "description": "Max lessons to return"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.lessons.add",
        description: "Record a lesson learned from fixing an error. Used to capture patterns of mistakes and their fixes for future reference.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"],
            "filePattern": ["type": "string", "description": "Glob pattern for files this applies to (e.g., '*.gts', 'app/models/*.rb')"],
            "errorSignature": ["type": "string", "description": "Normalized error pattern for matching (e.g., 'undefined method X')"],
            "fixDescription": ["type": "string", "description": "Human-readable description of the fix"],
            "fixCode": ["type": "string", "description": "Actual code snippet that fixed the issue"],
            "source": ["type": "string", "description": "Source: 'manual', 'auto', or 'imported' (default: 'manual')"]
          ],
          "required": ["repoPath", "fixDescription"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.lessons.query",
        description: "Query lessons relevant to a specific file or error. Returns lessons that match the file pattern and/or error signature, sorted by confidence.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"],
            "filePattern": ["type": "string", "description": "File path to match against lesson patterns"],
            "errorSignature": ["type": "string", "description": "Error text to match against lesson signatures"],
            "limit": ["type": "integer", "description": "Max lessons to return (default: 20)"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.lessons.update",
        description: "Update a lesson's description, code, confidence, or active status.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lessonId": ["type": "string", "description": "The lesson ID to update"],
            "fixDescription": ["type": "string", "description": "Updated fix description"],
            "fixCode": ["type": "string", "description": "Updated fix code"],
            "confidence": ["type": "number", "description": "New confidence score (0.0-1.0)"],
            "isActive": ["type": "boolean", "description": "Whether the lesson is active"]
          ],
          "required": ["lessonId"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.lessons.delete",
        description: "Delete a lesson permanently.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lessonId": ["type": "string", "description": "The lesson ID to delete"]
          ],
          "required": ["lessonId"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.lessons.applied",
        description: "Record that a lesson was applied to provide feedback. Updates confidence based on success/failure.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lessonId": ["type": "string", "description": "The lesson ID that was applied"],
            "success": ["type": "boolean", "description": "Whether applying the lesson was successful"]
          ],
          "required": ["lessonId", "success"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.repos.list",
        description: "List all indexed repositories with stats",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.repos.delete",
        description: "Delete an indexed repository and all its data (files, chunks, embeddings)",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoId": ["type": "string", "description": "The repo ID (hash) to delete"],
            "repoPath": ["type": "string", "description": "The repo path to delete (alternative to repoId)"]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.stats",
        description: "Get index statistics: file count, chunk count, embedding count, total lines for a specific repository.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.largeFiles",
        description: "Find the largest files in a repository by line count. Useful for finding refactor candidates.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"],
            "limit": ["type": "integer", "description": "Max files to return (default 20)"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.constructTypes",
        description: "Get distribution of construct types (class, function, component, etc.) in a repository.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.facets",
        description: "Get facet counts for filtering/grouping search results. Returns counts for module paths, feature tags, languages, and construct types.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Optional repo path to filter"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.dependencies",
        description: "Get what a file depends on (imports, requires, inheritance, protocol conformance). Returns the list of modules/files that the specified file imports or depends on.",
        inputSchema: [
          "type": "object",
          "properties": [
            "filePath": ["type": "string", "description": "Relative path of the file within the repo (e.g., 'Shared/Services/LocalRAGStore.swift')"],
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"]
          ],
          "required": ["filePath", "repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.dependents",
        description: "Get what depends on a file (reverse dependencies). Returns the list of files that import or depend on the specified file.",
        inputSchema: [
          "type": "object",
          "properties": [
            "filePath": ["type": "string", "description": "Relative path of the file within the repo (e.g., 'Shared/Services/LocalRAGStore.swift')"],
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"]
          ],
          "required": ["filePath", "repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.orphans",
        description: "Find potentially orphaned/unused files in a repository. An orphan is a file that has no imports/requires pointing to it AND no type references from other files. Useful for finding dead code. Note: May still show entry points, dynamically loaded files, or reflection-based usage.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"],
            "excludeTests": ["type": "boolean", "description": "Exclude test files from results (default: true)"],
            "excludeEntryPoints": ["type": "boolean", "description": "Exclude common entry point files like App.swift, main.swift, index.ts (default: true)"],
            "limit": ["type": "integer", "description": "Maximum results to return (default: 50)"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.structural",
        description: "Query files by structural characteristics: line count, method count, byte size. Use for finding large/complex files or filtering by size. Set statsOnly=true for aggregate statistics.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"],
            "minLines": ["type": "integer", "description": "Minimum line count filter"],
            "maxLines": ["type": "integer", "description": "Maximum line count filter"],
            "minMethods": ["type": "integer", "description": "Minimum method/function count filter"],
            "maxMethods": ["type": "integer", "description": "Maximum method/function count filter"],
            "minBytes": ["type": "integer", "description": "Minimum file size in bytes"],
            "maxBytes": ["type": "integer", "description": "Maximum file size in bytes"],
            "language": ["type": "string", "description": "Filter by language (e.g., 'swift', 'ruby', 'typescript')"],
            "sortBy": ["type": "string", "description": "Sort results by: 'lines', 'methods', 'bytes' (default: 'lines')"],
            "limit": ["type": "integer", "description": "Maximum results to return (default: 50)"],
            "statsOnly": ["type": "boolean", "description": "Return only aggregate statistics (no file list)"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.similar",
        description: "Find code chunks semantically similar to a given snippet or query. Uses embedding-based similarity search to find related code patterns, implementations, or concepts. Note: for finding duplicate/redundant code across a codebase, use rag.duplicates instead — it returns a ranked report of all same-name constructs across files in one call.",
        inputSchema: [
          "type": "object",
          "properties": [
            "query": ["type": "string", "description": "Code snippet or text to find similar code for"],
            "repoPath": ["type": "string", "description": "Absolute path to repository (optional - searches all indexed repos if omitted)"],
            "threshold": ["type": "number", "description": "Minimum similarity score 0.0-1.0 (default: 0.6)"],
            "limit": ["type": "integer", "description": "Maximum results to return (default: 10)"],
            "excludePath": ["type": "string", "description": "File path to exclude from results (useful when finding similar code to an existing file)"]
          ],
          "required": ["query"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.reranker.config",
        description: "Configure HuggingFace reranker for improved search relevance. Cross-encoder reranking can significantly improve search quality by rescoring results with a dedicated relevance model. Requires HF API token for best results.",
        inputSchema: [
          "type": "object",
          "properties": [
            "action": ["type": "string", "description": "Action to perform: 'get' (view config), 'set' (update config), 'test' (info only). Default: 'get'"],
            "enabled": ["type": "boolean", "description": "Enable/disable HF reranking (for 'set' action)"],
            "modelId": ["type": "string", "description": "HuggingFace model ID for reranking (e.g., 'BAAI/bge-reranker-base')"],
            "apiToken": ["type": "string", "description": "HuggingFace API token (optional but recommended for reliability)"]
          ],
          "required": []
        ],
        category: .rag,
        isMutating: false
      ),
    ]
  }
}
