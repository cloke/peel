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
  func searchRag(query: String, mode: MCPServerService.RAGSearchMode, repoPath: String?, limit: Int, matchAll: Bool) async throws -> [RAGToolSearchResult]
  
  /// Get RAG database status
  func ragStatus() async -> RAGToolStatus
  
  /// Initialize RAG database
  func initializeRag(extensionPath: String?) async throws -> RAGToolStatus
  
  /// Index a repository
  func indexRepository(path: String, progressHandler: ((RAGToolIndexProgress) -> Void)?) async throws -> RAGToolIndexReport
  
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
  
  /// Clear embedding cache
  func clearRagCache() async throws -> Int
  
  /// Generate embeddings for texts
  func generateEmbeddings(for texts: [String]) async throws -> [[Float]]
  
  // MARK: - DataService Access (Skills)
  
  /// List guidance skills
  func listRepoGuidanceSkills(repoPath: String?, includeInactive: Bool, limit: Int?) -> [RepoGuidanceSkill]
  
  /// Add a guidance skill
  func addRepoGuidanceSkill(repoPath: String, title: String, body: String, source: String, tags: String, priority: Int, isActive: Bool) -> RepoGuidanceSkill
  
  /// Update a guidance skill
  func updateRepoGuidanceSkill(id: UUID, repoPath: String?, title: String?, body: String?, source: String?, tags: String?, priority: Int?, isActive: Bool?) -> RepoGuidanceSkill?
  
  /// Delete a guidance skill
  func deleteRepoGuidanceSkill(id: UUID) -> Bool
  
  // MARK: - State Tracking
  
  /// Track last search parameters for UI
  var lastRagSearchQuery: String? { get set }
  var lastRagSearchMode: MCPServerService.RAGSearchMode? { get set }
  var lastRagSearchRepoPath: String? { get set }
  var lastRagSearchLimit: Int? { get set }
  var lastRagSearchAt: Date? { get set }
  var lastRagSearchResults: [RAGToolSearchResult] { get set }
  var lastRagIndexReport: RAGToolIndexReport? { get set }
  var lastRagIndexAt: Date? { get set }
  var lastRagRefreshAt: Date? { get set }
  var lastRagError: String? { get set }
  
  /// Indexing progress tracking
  var ragIndexingPath: String? { get set }
  var ragIndexProgress: RAGToolIndexProgress? { get set }
  
  // MARK: - Configuration
  
  /// Get/set the preferred embedding provider
  var preferredEmbeddingProvider: EmbeddingProviderType { get set }
  
  /// Refresh RAG summary (repos list)
  func refreshRagSummary() async
  
  /// Get RAG stats
  func ragStats() async throws -> RAGToolStats?
  
  /// Log a telemetry warning
  func logWarning(_ message: String, metadata: [String: String]) async
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
    "rag.repos.list",
    "rag.repos.delete",
    "rag.stats",
    "rag.largeFiles",
    "rag.constructTypes"
  ]
  
  init() {}
  
  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let ragDelegate else {
      return notConfiguredError(id: id)
    }
    
    switch name {
    case "rag.status":
      return await handleStatus(id: id, delegate: ragDelegate)
    case "rag.search":
      return await handleSearch(id: id, arguments: arguments, delegate: ragDelegate)
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
    case "rag.stats":
      return await handleStats(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.largeFiles":
      return await handleLargeFiles(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.constructTypes":
      return await handleConstructTypes(id: id, arguments: arguments, delegate: ragDelegate)
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
      "coreMLModelPresent": status.coreMLModelPresent,
      "coreMLVocabPresent": status.coreMLVocabPresent,
      "coreMLTokenizerHelperPresent": status.coreMLTokenizerHelperPresent,
      "debugForceSystem": UserDefaults.standard.bool(forKey: "localrag.useSystem")
    ]
    if let lastInitializedAt = status.lastInitializedAt {
      result["lastInitializedAt"] = formatter.string(from: lastInitializedAt)
    }
    return (200, makeResult(id: id, result: result))
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
    let matchAll = optionalBool("matchAll", from: arguments, default: true)
    
    do {
      let resolvedMode: MCPServerService.RAGSearchMode = mode.lowercased() == "vector" ? .vector : .text
      var results = try await delegate.searchRag(query: query, mode: resolvedMode, repoPath: repoPath, limit: limit * 2, matchAll: matchAll)
      
      // Apply filters
      if excludeTests {
        results = results.filter { !$0.isTest }
      }
      if let typeFilter = constructTypeFilter?.lowercased(), !typeFilter.isEmpty {
        results = results.filter { ($0.constructType?.lowercased() ?? "") == typeFilter }
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
        return item
      }
      return (200, makeResult(id: id, result: ["mode": mode, "results": payload]))
    } catch {
      await delegate.logWarning("Local RAG search failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.index
  
  private func handleIndex(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    delegate.ragIndexingPath = repoPath
    delegate.ragIndexProgress = nil
    
    do {
      let report = try await delegate.indexRepository(path: repoPath) { progress in
        Task { @MainActor in
          delegate.ragIndexProgress = progress
        }
      }
      
      delegate.ragIndexingPath = nil
      delegate.ragIndexProgress = .complete(report: report)
      delegate.lastRagIndexReport = report
      delegate.lastRagIndexAt = Date()
      
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
      delegate.ragIndexingPath = nil
      delegate.ragIndexProgress = nil
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
  
  // MARK: - rag.stats
  
  private func handleStats(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    do {
      let stats = try await delegate.getIndexStats(repoPath: repoPath)
      let result: [String: Any] = [
        "fileCount": stats.fileCount,
        "chunkCount": stats.chunkCount,
        "embeddingCount": stats.embeddingCount,
        "totalLines": stats.totalLines
      ]
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
  
  init(filePath: String, startLine: Int, endLine: Int, snippet: String, isTest: Bool, lineCount: Int, constructType: String? = nil, constructName: String? = nil, language: String? = nil, score: Double? = nil) {
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
  let coreMLModelPresent: Bool
  let coreMLVocabPresent: Bool
  let coreMLTokenizerHelperPresent: Bool
  let lastInitializedAt: Date?
  
  init(dbPath: String, exists: Bool, schemaVersion: Int, extensionLoaded: Bool, providerName: String, embeddingModelName: String, embeddingDimensions: Int, coreMLModelPresent: Bool, coreMLVocabPresent: Bool, coreMLTokenizerHelperPresent: Bool, lastInitializedAt: Date?) {
    self.dbPath = dbPath
    self.exists = exists
    self.schemaVersion = schemaVersion
    self.extensionLoaded = extensionLoaded
    self.providerName = providerName
    self.embeddingModelName = embeddingModelName
    self.embeddingDimensions = embeddingDimensions
    self.coreMLModelPresent = coreMLModelPresent
    self.coreMLVocabPresent = coreMLVocabPresent
    self.coreMLTokenizerHelperPresent = coreMLTokenizerHelperPresent
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
  
  init(fileCount: Int, chunkCount: Int, embeddingCount: Int, totalLines: Int) {
    self.fileCount = fileCount
    self.chunkCount = chunkCount
    self.embeddingCount = embeddingCount
    self.totalLines = totalLines
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
