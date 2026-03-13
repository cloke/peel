//
//  RAGToolsHandler.swift
//  Peel
//
//  Thin coordinator for RAG MCP tools. Dispatches to extension files:
//    RAGToolsHandler+Indexing.swift    — status, init, index, repos, branch
//    RAGToolsHandler+Search.swift      — search, queryHints, stats, structural, similar
//    RAGToolsHandler+Skills.swift      — skills.*
//    RAGToolsHandler+Lessons.swift     — lessons.*
//    RAGToolsHandler+Analysis.swift    — config, analyze, enrich, duplicates, patterns
//    RAGToolsHandler+Types.swift       — supporting types
//    RAGToolsHandler+ToolDefinitions.swift — tool definitions
//  Delegate protocol: RAGToolsHandlerDelegate.swift
//

import Foundation
import MCPCore
import SwiftData

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
    "rag.skills.init",          // Bootstrap .peel/directives.md and .peel/skills.json from bundled defaults
    "rag.lessons.list",    // Issue #210: Learning loop - list lessons
    "rag.lessons.add",     // Issue #210: Learning loop - add lesson
    "rag.lessons.query",   // Issue #210: Learning loop - query relevant lessons
    "rag.lessons.update",  // Issue #210: Learning loop - update lesson
    "rag.lessons.delete",  // Issue #210: Learning loop - delete lesson
    "rag.lessons.applied", // Issue #210: Learning loop - record lesson was applied (increases confidence)
    "rag.repos.list",
    "rag.repos.delete",
    "rag.publish",
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
    case "rag.publish":
      return await handlePublish(id: id, arguments: arguments, delegate: ragDelegate)
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
    case "rag.skills.init":
      return handleSkillsInit(id: id, arguments: arguments)
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
      return await handleAnalyze(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.analyze.status":
      return await handleAnalyzeStatus(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.enrich":
      return await handleEnrich(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.enrich.status":
      return await handleEnrichStatus(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.duplicates":
      return await handleDuplicates(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.patterns":
      return await handlePatterns(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.hotspots":
      return await handleHotspots(id: id, arguments: arguments, delegate: ragDelegate)
    case "rag.cache.clear":
      return handleCacheClear(id: id, arguments: arguments)
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
  
  // MARK: - rag.cache.clear

  /// Clear cached HuggingFace model downloads to recover from corrupt/interrupted downloads
  private func handleCacheClear(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let modelId = optionalString("modelId", from: arguments)

    if let modelId {
      // Validate the model exists in our known list
      let knownIds = MLXEmbeddingModelConfig.availableModels.map(\.huggingFaceId)
      guard knownIds.contains(modelId) else {
        let list = knownIds.joined(separator: ", ")
        return (400, makeError(
          id: id,
          code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
          message: "Unknown model '\(modelId)'. Known models: \(list)"
        ))
      }

      // Check for corruption first
      let validationIssue = MLXEmbeddingProvider.validateModelCache(huggingFaceId: modelId)
      let deleted = MLXEmbeddingProvider.clearModelCache(huggingFaceId: modelId)

      return (200, makeResult(id: id, result: [
        "action": "clearOne",
        "modelId": modelId,
        "deleted": deleted,
        "hadCorruption": validationIssue != nil,
        "corruptionDetail": validationIssue ?? "none",
        "note": deleted
          ? "Cache cleared. The model will re-download on next use."
          : "No cache found for this model."
      ]))
    } else {
      // Clear all embedding model caches
      var results: [[String: Any]] = []
      for model in MLXEmbeddingModelConfig.availableModels {
        let issue = MLXEmbeddingProvider.validateModelCache(huggingFaceId: model.huggingFaceId)
        let existed = MLXEmbeddingProvider.clearModelCache(huggingFaceId: model.huggingFaceId)
        if existed || issue != nil {
          results.append([
            "modelId": model.huggingFaceId,
            "deleted": existed,
            "hadCorruption": issue != nil,
            "corruptionDetail": issue ?? "none"
          ])
        }
      }

      return (200, makeResult(id: id, result: [
        "action": "clearAll",
        "cleared": results,
        "count": results.count,
        "note": results.isEmpty
          ? "No cached models found."
          : "Cleared \(results.count) model cache(s). Models will re-download on next use."
      ]))
    }
  }

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
  
  func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }

  // MARK: - Helpers

  
  func encodeSkill(_ skill: RepoGuidanceSkill, formatter: ISO8601DateFormatter) -> [String: Any] {
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
  
  func optionalDouble(_ key: String, from arguments: [String: Any]) -> Double? {
    if let value = arguments[key] as? Double {
      return value
    }
    if let value = arguments[key] as? Int {
      return Double(value)
    }
    return nil
  }
}

