//
//  RAGToolsHandler+Analysis.swift
//  Peel
//
//  Handles: rag.config, rag.reranker.config, rag.analyze, rag.analyze.status,
//           rag.enrich, rag.enrich.status, rag.duplicates, rag.patterns, rag.hotspots
//  Split from RAGToolsHandler.swift as part of #301.
//

import Foundation
import MCPCore

extension RAGToolsHandler {
  // MARK: - rag.config

  func handleConfig(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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

  // MARK: - rag.reranker.config (Issue #128)
  
  func handleRerankerConfig(id: Any?, arguments: [String: Any]) -> (Int, Data) {
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
  func handleAnalyze(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleAnalyzeStatus(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleEnrich(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
  func handleEnrichStatus(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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

  func handleDuplicates(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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

  func handlePatterns(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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

  func handleHotspots(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
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
  
}
