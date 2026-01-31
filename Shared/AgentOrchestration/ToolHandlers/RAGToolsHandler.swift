//
//  RAGToolsHandler.swift
//  Peel
//
//  Created as part of #159: Extract RAG tools from MCPServerService.
//

import Foundation
import MCPCore

// MARK: - RAG Tools Handler Delegate Extension

/// Extended delegate protocol for RAG-specific functionality
@MainActor
protocol RAGToolsHandlerDelegate: MCPToolHandlerDelegate {
  // MARK: - LocalRAGStore Access
  
  /// Search the RAG index
  func searchRagForTool(query: String, mode: MCPServerService.RAGSearchMode, repoPath: String?, limit: Int, matchAll: Bool) async throws -> [RAGToolSearchResult]
  
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
  
  /// List guidance skills
  func listRepoGuidanceSkills(repoPath: String?, includeInactive: Bool, limit: Int?) -> [RepoGuidanceSkill]
  
  /// Add a guidance skill
  func addRepoGuidanceSkill(repoPath: String, title: String, body: String, source: String, tags: String, priority: Int, isActive: Bool) -> RepoGuidanceSkill?
  
  /// Update a guidance skill
  func updateRepoGuidanceSkill(id: UUID, repoPath: String?, title: String?, body: String?, source: String?, tags: String?, priority: Int?, isActive: Bool?) -> RepoGuidanceSkill?
  
  /// Delete a guidance skill
  func deleteRepoGuidanceSkill(id: UUID) -> Bool
  
  // MARK: - Learning Loop (#210)
  
  /// List lessons for a repo
  func listLessons(repoPath: String, includeInactive: Bool, limit: Int?) async throws -> [LocalRAGLesson]
  
  /// Add a lesson
  func addLesson(repoPath: String, filePattern: String?, errorSignature: String?, fixDescription: String, fixCode: String?, source: String) async throws -> LocalRAGLesson
  
  /// Query relevant lessons for a file/error
  func queryLessons(repoPath: String, filePattern: String?, errorSignature: String?, limit: Int) async throws -> [LocalRAGLesson]
  
  /// Update a lesson
  func updateLesson(id: String, fixDescription: String?, fixCode: String?, confidence: Float?, isActive: Bool?) async throws -> LocalRAGLesson?
  
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
    
    do {
      let resolvedMode: MCPServerService.RAGSearchMode = mode.lowercased() == "vector" ? .vector : .text
      // Fetch more results initially if reranking is enabled
      let fetchLimit = shouldRerank ? max(limit * 3, 30) : limit * 2
      var results = try await delegate.searchRagForTool(query: query, mode: resolvedMode, repoPath: repoPath, limit: fetchLimit, matchAll: matchAll)
      
      // Apply filters
      if excludeTests {
        results = results.filter { !$0.isTest }
      }
      if let typeFilter = constructTypeFilter?.lowercased(), !typeFilter.isEmpty {
        results = results.filter { ($0.constructType?.lowercased() ?? "") == typeFilter }
      }
      if let moduleFilter = modulePathFilter, !moduleFilter.isEmpty {
        results = results.filter { ($0.modulePath ?? "").lowercased().contains(moduleFilter.lowercased()) }
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
          
          // Convert back to RAGToolSearchResult
          results = reranked.map { r in
            RAGToolSearchResult(
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
              featureTags: r.featureTags
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
          "snippet": result.snippet,
          "isTest": result.isTest,
          "lineCount": result.lineCount
        ]
        if let constructType = result.constructType {
          item["constructType"] = constructType
        }
        if let constructName = result.constructName {
          item["name"] = constructName
        }
        if let language = result.language {
          item["language"] = language
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
        return item
      }
      
      // Build response with reranker info
      var response: [String: Any] = ["mode": mode, "results": payload]
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
      
      let result: [String: Any] = [
        "repoId": report.repoId,
        "repoPath": report.repoPath,
        "filesIndexed": report.filesIndexed,
        "filesSkipped": report.filesSkipped,
        "chunksIndexed": report.chunksIndexed,
        "bytesScanned": report.bytesScanned,
        "durationMs": report.durationMs,
        "embeddingCount": report.embeddingCount,
        "embeddingDurationMs": report.embeddingDurationMs
      ]
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
    let includeInactive = optionalBool("includeInactive", from: arguments, default: false)
    let limit = optionalInt("limit", from: arguments)
    let formatter = ISO8601DateFormatter()
    
    let skills = delegate.listRepoGuidanceSkills(
      repoPath: repoPath?.isEmpty == false ? repoPath : nil,
      includeInactive: includeInactive,
      limit: limit
    )
    let payload = skills.map { encodeSkill($0, formatter: formatter) }
    return (200, makeResult(id: id, result: ["skills": payload]))
  }
  
  // MARK: - rag.skills.add
  
  private func handleSkillsAdd(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    guard case .success(let title) = requireString("title", from: arguments, id: id) else {
      return missingParamError(id: id, param: "title")
    }
    guard case .success(let body) = requireString("body", from: arguments, id: id) else {
      return missingParamError(id: id, param: "body")
    }
    
    let source = optionalString("source", from: arguments, default: "manual") ?? "manual"
    let tags = optionalString("tags", from: arguments, default: "") ?? ""
    let priority = optionalInt("priority", from: arguments, default: 0) ?? 0
    let isActive = optionalBool("isActive", from: arguments, default: true)
    
    let skill = delegate.addRepoGuidanceSkill(
      repoPath: repoPath,
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
    // JSON numbers come in as Double, so accept both Float and Double
    let confidence: Float? = if let f = arguments["confidence"] as? Float {
      f
    } else if let d = arguments["confidence"] as? Double {
      Float(d)
    } else {
      nil
    }
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
      "occurrences": lesson.occurrences,
      "source": lesson.source,
      "isActive": lesson.isActive,
      "createdAt": formatter.string(from: lesson.createdAt)
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
    if let lastUsedAt = lesson.lastUsedAt {
      result["lastUsedAt"] = formatter.string(from: lastUsedAt)
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
  #endif
  
  // MARK: - Helpers
  
  private func encodeSkill(_ skill: RepoGuidanceSkill, formatter: ISO8601DateFormatter) -> [String: Any] {
    var payload: [String: Any] = [
      "id": skill.id.uuidString,
      "repoPath": skill.repoPath,
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
  
  init(filePath: String, startLine: Int, endLine: Int, snippet: String, isTest: Bool, lineCount: Int, constructType: String? = nil, constructName: String? = nil, language: String? = nil, score: Double? = nil, modulePath: String? = nil, featureTags: [String] = []) {
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
  let chunksIndexed: Int
  let bytesScanned: Int
  let durationMs: Int
  let embeddingCount: Int
  let embeddingDurationMs: Int
  
  init(repoId: String, repoPath: String, filesIndexed: Int, filesSkipped: Int, chunksIndexed: Int, bytesScanned: Int, durationMs: Int, embeddingCount: Int, embeddingDurationMs: Int) {
    self.repoId = repoId
    self.repoPath = repoPath
    self.filesIndexed = filesIndexed
    self.filesSkipped = filesSkipped
    self.chunksIndexed = chunksIndexed
    self.bytesScanned = bytesScanned
    self.durationMs = durationMs
    self.embeddingCount = embeddingCount
    self.embeddingDurationMs = embeddingDurationMs
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
  
  init(id: String, name: String, rootPath: String, fileCount: Int, chunkCount: Int, lastIndexedAt: Date?) {
    self.id = id
    self.name = name
    self.rootPath = rootPath
    self.fileCount = fileCount
    self.chunkCount = chunkCount
    self.lastIndexedAt = lastIndexedAt
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
