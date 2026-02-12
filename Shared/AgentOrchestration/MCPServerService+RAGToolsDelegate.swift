//
//  MCPServerService+RAGToolsDelegate.swift
//  KitchenSync
//
//  Extracted from MCPServerService.swift for maintainability.
//

import Foundation
import SwiftData

// MARK: - RAGToolsHandlerDelegate

extension MCPServerService: RAGToolsHandlerDelegate {
  
  var modelContext: ModelContext? {
    dataService?.modelContext
  }
  
  // MARK: - LocalRAGStore Access
  
  func searchRagForTool(query: String, mode: RAGSearchMode, repoPath: String?, limit: Int, matchAll: Bool, modulePath: String? = nil) async throws -> [RAGToolSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let results = try await runRagSearch(
      query: trimmedQuery,
      mode: mode,
      repoPath: repoPath,
      limit: limit,
      matchAll: matchAll,
      recordHints: true,
      modulePath: modulePath
    )
    return results.map { result in
      RAGToolSearchResult(
        filePath: result.filePath,
        startLine: result.startLine,
        endLine: result.endLine,
        snippet: result.snippet,
        isTest: result.isTest,
        lineCount: result.lineCount,
        constructType: result.constructType,
        constructName: result.constructName,
        language: result.language,
        score: result.score.map { Double($0) },
        modulePath: result.modulePath,
        featureTags: result.featureTags,
        aiSummary: result.aiSummary,
        aiTags: result.aiTags,
        tokenCount: result.tokenCount
      )
    }
  }
  
  func ragStatus() async -> RAGToolStatus {
    let status = await localRagStore.status()
    return RAGToolStatus(
      dbPath: status.dbPath,
      exists: status.exists,
      schemaVersion: status.schemaVersion,
      extensionLoaded: status.extensionLoaded,
      providerName: status.providerName,
      embeddingModelName: status.embeddingModelName,
      embeddingDimensions: status.embeddingDimensions,
      lastInitializedAt: status.lastInitializedAt
    )
  }
  
  func initializeRag(extensionPath: String?) async throws -> RAGToolStatus {
    let status = try await localRagStore.initialize(extensionPath: extensionPath)
    return RAGToolStatus(
      dbPath: status.dbPath,
      exists: status.exists,
      schemaVersion: status.schemaVersion,
      extensionLoaded: status.extensionLoaded,
      providerName: status.providerName,
      embeddingModelName: status.embeddingModelName,
      embeddingDimensions: status.embeddingDimensions,
      lastInitializedAt: status.lastInitializedAt
    )
  }
  
  func indexRepository(
    path: String,
    forceReindex: Bool,
    allowWorkspace: Bool,
    excludeSubrepos: Bool,
    progressHandler: (@Sendable (RAGToolIndexProgress) -> Void)?
  ) async throws -> RAGToolIndexReport {
    // Update UI state so dashboard shows progress
    ragIndexingPath = path
    ragIndexProgress = nil
    
    do {
      let report = try await localRagStore.indexRepository(
        path: path,
        forceReindex: forceReindex,
        allowWorkspace: allowWorkspace,
        excludeSubrepos: excludeSubrepos
      ) { [weak self] progress in
        // Update UI progress state
        Task { @MainActor in
          self?.ragIndexProgress = progress
        }
        
        // Also call the external progress handler if provided
        if let handler = progressHandler {
          switch progress {
          case .scanning(let fileCount):
            handler(.scanning(filesFound: fileCount))
          case .analyzing(let current, let total, _):
            handler(.indexing(current: current, total: total))
          case .embedding(let current, let total):
            handler(.embedding(current: current, total: total))
          case .storing:
            break // RAGToolIndexProgress doesn't have storing case
          case .complete(let localReport):
            handler(.complete(report: Self.convertReport(localReport)))
          }
        }
      }
      
      // Update UI state on completion
      ragIndexingPath = nil
      ragIndexProgress = .complete(report: report)
      lastRagIndexReport = report
      lastRagIndexAt = Date()
      
      return Self.convertReport(report)
    } catch {
      // Clean up UI state on error
      ragIndexingPath = nil
      ragIndexProgress = nil
      throw error
    }
  }

  /// Convert LocalRAGIndexReport to RAGToolIndexReport (including sub-reports for workspace indexing)
  nonisolated private static func convertReport(_ report: LocalRAGIndexReport) -> RAGToolIndexReport {
    RAGToolIndexReport(
      repoId: report.repoId,
      repoPath: report.repoPath,
      filesIndexed: report.filesIndexed,
      filesSkipped: report.filesSkipped,
      filesRemoved: report.filesRemoved,
      chunksIndexed: report.chunksIndexed,
      bytesScanned: report.bytesScanned,
      durationMs: report.durationMs,
      embeddingCount: report.embeddingCount,
      embeddingDurationMs: report.embeddingDurationMs,
      subReports: report.subReports.map { convertReport($0) }
    )
  }
  
  func listRagRepos() async throws -> [RAGToolRepoInfo] {
    let repos = try await localRagStore.listRepos()
    return repos.map { repo in
      RAGToolRepoInfo(
        id: repo.id,
        name: repo.name,
        rootPath: repo.rootPath,
        fileCount: repo.fileCount,
        chunkCount: repo.chunkCount,
        lastIndexedAt: repo.lastIndexedAt,
        repoIdentifier: repo.repoIdentifier,
        parentRepoId: repo.parentRepoId
      )
    }
  }
  
  func deleteRagRepo(repoId: String?, repoPath: String?) async throws -> Int {
    let deleted = try await localRagStore.deleteRepo(repoId: repoId, repoPath: repoPath)
    await refreshRagSummary()
    return deleted
  }
  
  func getIndexStats(repoPath: String) async throws -> RAGToolIndexStats {
    let stats = try await localRagStore.getIndexStats(repoPath: repoPath)
    let depStats = try await localRagStore.getDependencyStats(for: repoPath)
    return RAGToolIndexStats(
      fileCount: stats.fileCount,
      chunkCount: stats.chunkCount,
      embeddingCount: stats.embeddingCount,
      totalLines: stats.totalLines,
      dependencyCount: depStats.totalDeps,
      dependenciesByType: depStats.byType
    )
  }
  
  func getLargeFiles(repoPath: String, limit: Int) async throws -> [RAGToolLargeFile] {
    let files = try await localRagStore.getLargeFiles(repoPath: repoPath, limit: limit)
    return files.map { file in
      RAGToolLargeFile(
        path: file.path,
        totalLines: file.totalLines,
        chunkCount: file.chunkCount,
        language: file.language
      )
    }
  }
  
  func getConstructTypeStats(repoPath: String) async throws -> [RAGToolConstructTypeStat] {
    let stats = try await localRagStore.getConstructTypeStats(repoPath: repoPath)
    return stats.map { stat in
      RAGToolConstructTypeStat(type: stat.type, count: stat.count)
    }
  }
  
  func getFacets(repoPath: String?) async throws -> RAGToolFacetCounts {
    let facets = try await localRagStore.getFacets(repoPath: repoPath)
    return RAGToolFacetCounts(
      modulePaths: facets.modulePaths,
      featureTags: facets.featureTags,
      languages: facets.languages,
      constructTypes: facets.constructTypes
    )
  }
  
  func getDependencies(filePath: String, repoPath: String) async throws -> [RAGToolDependencyResult] {
    let deps = try await localRagStore.getDependencies(for: filePath, inRepo: repoPath)
    return deps.map { dep in
      RAGToolDependencyResult(
        sourceFile: dep.sourceFile,
        targetPath: dep.targetPath,
        targetFile: dep.targetFile,
        dependencyType: dep.dependencyType.rawValue,
        rawImport: dep.rawImport
      )
    }
  }
  
  func getDependents(filePath: String, repoPath: String) async throws -> [RAGToolDependencyResult] {
    let deps = try await localRagStore.getDependents(for: filePath, inRepo: repoPath)
    return deps.map { dep in
      RAGToolDependencyResult(
        sourceFile: dep.sourceFile,
        targetPath: dep.targetPath,
        targetFile: dep.targetFile,
        dependencyType: dep.dependencyType.rawValue,
        rawImport: dep.rawImport
      )
    }
  }
  
  func findOrphans(repoPath: String, excludeTests: Bool, excludeEntryPoints: Bool, limit: Int) async throws -> [RAGToolOrphanResult] {
    let orphans = try await localRagStore.findOrphans(
      repoPath: repoPath,
      excludeTests: excludeTests,
      excludeEntryPoints: excludeEntryPoints,
      limit: limit
    )
    return orphans.map { o in
      RAGToolOrphanResult(
        filePath: o.filePath,
        language: o.language,
        lineCount: o.lineCount,
        symbolsDefinedCount: o.symbolsDefinedCount,
        symbolsDefined: o.symbolsDefined,
        reason: o.reason
      )
    }
  }
  
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
  ) async throws -> [RAGToolStructuralResult] {
    let results = try await localRagStore.queryFilesByStructure(
      inRepo: repoPath,
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
    return results.map { r in
      RAGToolStructuralResult(
        path: r.path,
        language: r.language,
        lineCount: r.lineCount,
        methodCount: r.methodCount,
        byteSize: r.byteSize,
        modulePath: r.modulePath
      )
    }
  }
  
  func getStructuralStats(repoPath: String) async throws -> (
    totalFiles: Int,
    totalLines: Int,
    totalMethods: Int,
    avgLinesPerFile: Double,
    avgMethodsPerFile: Double,
    largestFile: (path: String, lines: Int)?,
    mostMethods: (path: String, count: Int)?
  ) {
    let stats = try await localRagStore.getStructuralStats(for: repoPath)
    return (
      totalFiles: stats.totalFiles,
      totalLines: stats.totalLines,
      totalMethods: stats.totalMethods,
      avgLinesPerFile: stats.avgLinesPerFile,
      avgMethodsPerFile: stats.avgMethodsPerFile,
      largestFile: stats.largestFile,
      mostMethods: stats.mostMethods
    )
  }
  
  func findSimilarCode(
    query: String,
    repoPath: String?,
    threshold: Double,
    limit: Int,
    excludePath: String?
  ) async throws -> [RAGToolSimilarResult] {
    let results = try await localRagStore.findSimilarCode(
      query: query,
      repoPath: repoPath,
      threshold: threshold,
      limit: limit,
      excludePath: excludePath
    )
    return results.map { r in
      RAGToolSimilarResult(
        path: r.path,
        startLine: r.startLine,
        endLine: r.endLine,
        snippet: r.snippet,
        similarity: r.similarity,
        constructType: r.constructType,
        constructName: r.constructName
      )
    }
  }
  
  func clearRagCache() async throws -> Int {
    return try await localRagStore.clearEmbeddingCache()
  }
  
  func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
    return try await localRagStore.generateEmbeddings(for: texts)
  }
  
  // MARK: - Configuration (delegate accessors for existing methods)
  // Note: listRepoGuidanceSkills, addRepoGuidanceSkill, updateRepoGuidanceSkill, 
  // deleteRepoGuidanceSkill, and refreshRagSummary are already defined in MCPServerService
  
  var preferredEmbeddingProvider: EmbeddingProviderType {
    get { LocalRAGEmbeddingProviderFactory.preferredProvider }
    set { LocalRAGEmbeddingProviderFactory.preferredProvider = newValue }
  }
  
  func ragStats() async throws -> RAGToolStats? {
    let stats = try await localRagStore.stats()
    return RAGToolStats(
      repoCount: stats.repoCount,
      fileCount: stats.fileCount,
      chunkCount: stats.chunkCount,
      embeddingCount: stats.embeddingCount,
      cacheEmbeddingCount: stats.cacheEmbeddingCount,
      dbSizeBytes: stats.dbSizeBytes,
      lastIndexedAt: stats.lastIndexedAt,
      lastIndexedRepoPath: stats.lastIndexedRepoPath
    )
  }

  func getRagQueryHints(limit: Int?) async -> [RAGQueryHint] {
    await refreshRagQueryHints()
    return ragQueryHints(limit: limit)
  }
  
  func logWarning(_ message: String, metadata: [String: String]) async {
    await telemetryProvider.warning(message, metadata: metadata)
  }
  
  // MARK: - AI Analysis (#198)
  
  #if os(macOS)
  func analyzeRagChunks(repoPath: String?, limit: Int, modelTier: MLXAnalyzerModelTier = .auto, progress: (@Sendable (Int, Int) -> Void)?) async throws -> Int {
    // Note: modelTier is not used directly — the chunkAnalyzer was configured at store creation
    try await localRagStore.analyzeChunks(repoPath: repoPath, limit: limit, progress: progress)
  }
  
  func getUnanalyzedChunkCount(repoPath: String?) async throws -> Int {
    try await localRagStore.getUnanalyzedChunkCount(repoPath: repoPath)
  }
  
  func getAnalyzedChunkCount(repoPath: String?) async throws -> Int {
    try await localRagStore.getAnalyzedChunkCount(repoPath: repoPath)
  }
  
  func enrichRagEmbeddings(repoPath: String?, limit: Int, progress: (@Sendable (Int, Int) -> Void)?) async throws -> Int {
    try await localRagStore.enrichEmbeddings(repoPath: repoPath, limit: limit, progress: progress)
  }
  
  func getUnenrichedChunkCount(repoPath: String?) async throws -> Int {
    try await localRagStore.getUnenrichedChunkCount(repoPath: repoPath)
  }
  
  func getEnrichedChunkCount(repoPath: String?) async throws -> Int {
    try await localRagStore.getEnrichedChunkCount(repoPath: repoPath)
  }
  
  func findRagDuplicates(repoPath: String?, minFiles: Int, constructTypes: [String]?, sortBy: String, limit: Int) async throws -> [LocalRAGStore.DuplicateGroup] {
    try await localRagStore.findDuplicates(repoPath: repoPath, minTokens: minFiles, limit: limit)
  }
  
  func findRagPatterns(repoPath: String?, constructType: String?, limit: Int) async throws -> [LocalRAGStore.PatternGroup] {
    try await localRagStore.findPatterns(repoPath: repoPath, limit: limit)
  }
  
  func findRagHotspots(repoPath: String?, constructType: String?, minTokens: Int, limit: Int) async throws -> [LocalRAGStore.Hotspot] {
    try await localRagStore.findHotspots(repoPath: repoPath, tokenThreshold: minTokens, limit: limit)
  }
  
  func clearRagAnalysis(repoPath: String?) async throws {
    try await localRagStore.clearAnalysis(repoPath: repoPath)
  }
  #endif
}
