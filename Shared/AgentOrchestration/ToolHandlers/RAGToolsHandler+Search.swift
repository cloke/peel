//
//  RAGToolsHandler+Search.swift
//  Peel
//
//  Handles: rag.search, rag.queryHints, rag.stats, rag.largeFiles,
//           rag.constructTypes, rag.facets, rag.dependencies, rag.dependents,
//           rag.orphans, rag.structural, rag.similar
//  Split from RAGToolsHandler.swift as part of #301.
//

import Foundation
import MCPCore

extension RAGToolsHandler {
  // MARK: - rag.search
  
  func handleSearch(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
      let resolvedMode: MCPServerService.RAGSearchMode = {
        switch mode.lowercased() {
        case "vector": return .vector
        case "hybrid": return .hybrid
        default: return .text
        }
      }()
      // Fetch more results initially if reranking or hybrid is enabled
      let fetchLimit = (shouldRerank || resolvedMode == .hybrid) ? max(limit * 3, 30) : limit * 2
      var results: [RAGToolSearchResult]
      if resolvedMode == .hybrid {
        // Run text and vector searches then merge with Reciprocal Rank Fusion
        let textRes = try await delegate.searchRagForTool(query: query, mode: .text, repoPath: repoPath, limit: fetchLimit, matchAll: matchAll, modulePath: modulePathFilter)
        let vectorRes = try await delegate.searchRagForTool(query: query, mode: .vector, repoPath: repoPath, limit: fetchLimit, matchAll: matchAll, modulePath: modulePathFilter)
        results = LocalRRFMerger.merge(text: textRes, vector: vectorRes, topK: fetchLimit)
      } else {
        results = try await delegate.searchRagForTool(query: query, mode: resolvedMode, repoPath: repoPath, limit: fetchLimit, matchAll: matchAll, modulePath: modulePathFilter)
      }
      
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

  func handleQueryHints(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  // MARK: - rag.stats
  
  func handleStats(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleLargeFiles(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleConstructTypes(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleFacets(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleDependencies(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleDependents(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleOrphans(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleStructural(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleSimilar(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
}
