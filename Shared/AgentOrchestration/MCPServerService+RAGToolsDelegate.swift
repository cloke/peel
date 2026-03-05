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
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let results = try await runRagSearch(
      query: trimmedQuery,
      mode: mode,
      repoPath: resolvedPath,
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
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    let deleted = try await localRagStore.deleteRepo(repoId: repoId, repoPath: resolvedPath)
    await refreshRagSummary()
    return deleted
  }
  
  func getIndexStats(repoPath: String) async throws -> RAGToolIndexStats {
    let resolvedPath = await resolveRepoPathForTool(repoPath) ?? repoPath
    let stats = try await localRagStore.getIndexStats(repoPath: resolvedPath)
    let depStats = try await localRagStore.getDependencyStats(for: resolvedPath)
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
    let resolvedPath = await resolveRepoPathForTool(repoPath) ?? repoPath
    let files = try await localRagStore.getLargeFiles(repoPath: resolvedPath, limit: limit)
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
    let resolvedPath = await resolveRepoPathForTool(repoPath) ?? repoPath
    let stats = try await localRagStore.getConstructTypeStats(repoPath: resolvedPath)
    return stats.map { stat in
      RAGToolConstructTypeStat(type: stat.type, count: stat.count)
    }
  }
  
  func getFacets(repoPath: String?) async throws -> RAGToolFacetCounts {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    let facets = try await localRagStore.getFacets(repoPath: resolvedPath)
    return RAGToolFacetCounts(
      modulePaths: facets.modulePaths,
      featureTags: facets.featureTags,
      languages: facets.languages,
      constructTypes: facets.constructTypes
    )
  }
  
  func getDependencies(filePath: String, repoPath: String) async throws -> [RAGToolDependencyResult] {
    let resolvedPath = await resolveRepoPathForTool(repoPath) ?? repoPath
    let deps = try await localRagStore.getDependencies(for: filePath, inRepo: resolvedPath)
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
    let resolvedPath = await resolveRepoPathForTool(repoPath) ?? repoPath
    let deps = try await localRagStore.getDependents(for: filePath, inRepo: resolvedPath)
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
    let resolvedPath = await resolveRepoPathForTool(repoPath) ?? repoPath
    let orphans = try await localRagStore.findOrphans(
      repoPath: resolvedPath,
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
    let resolvedPath = await resolveRepoPathForTool(repoPath) ?? repoPath
    let results = try await localRagStore.queryFilesByStructure(
      inRepo: resolvedPath,
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
    let resolvedPath = await resolveRepoPathForTool(repoPath) ?? repoPath
    let stats = try await localRagStore.getStructuralStats(for: resolvedPath)
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
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    let results = try await localRagStore.findSimilarCode(
      query: query,
      repoPath: resolvedPath,
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

  /// Validate that the MLX analysis model can load before starting a batch.
  /// Creates a temporary analyzer with the requested tier, tries to preload it,
  /// and surfaces any download/init error to the caller.
  /// The downloaded model files are cache-local so the real analyzer benefits too.
  func validateAnalysisModel(tier: MLXAnalyzerModelTier = .auto) async throws {
    let analyzer = MLXCodeAnalyzerFactory.makeAnalyzer(tier: tier)
    try await analyzer.preload()
    // Immediately unload — the real analyzer inside RAGStore will reload from cache.
    await analyzer.unload()
  }

  func analyzeRagChunks(repoPath: String?, limit: Int, modelTier: MLXAnalyzerModelTier = .auto, progress: (@Sendable (Int, Int) -> Void)?) async throws -> Int {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    // Note: modelTier is not used directly — the chunkAnalyzer was configured at store creation
    return try await localRagStore.analyzeChunks(repoPath: resolvedPath, limit: limit, progress: progress)
  }
  
  func getUnanalyzedChunkCount(repoPath: String?) async throws -> Int {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    return try await localRagStore.getUnanalyzedChunkCount(repoPath: resolvedPath)
  }
  
  func getAnalyzedChunkCount(repoPath: String?) async throws -> Int {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    return try await localRagStore.getAnalyzedChunkCount(repoPath: resolvedPath)
  }
  
  func enrichRagEmbeddings(repoPath: String?, limit: Int, progress: (@Sendable (Int, Int) -> Void)?) async throws -> Int {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    return try await localRagStore.enrichEmbeddings(repoPath: resolvedPath, limit: limit, progress: progress)
  }
  
  func getUnenrichedChunkCount(repoPath: String?) async throws -> Int {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    return try await localRagStore.getUnenrichedChunkCount(repoPath: resolvedPath)
  }
  
  func getEnrichedChunkCount(repoPath: String?) async throws -> Int {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    return try await localRagStore.getEnrichedChunkCount(repoPath: resolvedPath)
  }
  
  func findRagDuplicates(repoPath: String?, minFiles: Int, constructTypes: [String]?, sortBy: String, limit: Int) async throws -> [LocalRAGStore.DuplicateGroup] {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    return try await localRagStore.findDuplicates(repoPath: resolvedPath, minTokens: minFiles, limit: limit)
  }
  
  func findRagPatterns(repoPath: String?, constructType: String?, limit: Int) async throws -> [LocalRAGStore.PatternGroup] {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    return try await localRagStore.findPatterns(repoPath: resolvedPath, limit: limit)
  }
  
  func findRagHotspots(repoPath: String?, constructType: String?, minTokens: Int, limit: Int) async throws -> [LocalRAGStore.Hotspot] {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    return try await localRagStore.findHotspots(repoPath: resolvedPath, tokenThreshold: minTokens, limit: limit)
  }
  
  func clearRagAnalysis(repoPath: String?) async throws {
    let resolvedPath = await resolveRepoPathForTool(repoPath)
    try await localRagStore.clearAnalysis(repoPath: resolvedPath)
  }
  #endif
  
  // MARK: - Repo Path Resolution Helper
  
  /// Resolve a repo path via RepoRegistry to support portable repo identifiers.
  /// This enables cross-machine SQLite sync by resolving git remote URLs to local paths.
  /// - Parameter repoPath: The path or remote URL to resolve (nil passes through as nil)
  /// - Returns: Resolved local path if possible, original path otherwise, or nil if input was nil
  private func resolveRepoPathForTool(_ repoPath: String?) async -> String? {
    guard let repoPath else { return nil }
    
    // If path exists locally, use it directly
    if FileManager.default.fileExists(atPath: repoPath) {
      return repoPath
    }
    
    // Try RepoRegistry in case repoPath is a remote URL or identifier
    if let resolved = RepoRegistry.shared.getLocalPath(for: repoPath),
       FileManager.default.fileExists(atPath: resolved) {
      return resolved
    }
    
    // Fall back to original (will likely fail in RAGStore, but preserves caller's intent)
    return repoPath
  }

  // MARK: - Skill File I/O (#264)

  private static let skillsFileName = ".peel/skills.json"

  /// Codable envelope for .peel/skills.json
  private struct SkillsFile: Codable {
    var version: Int = 1
    var skills: [SkillEntry]

    struct SkillEntry: Codable {
      var title: String
      var body: String
      var tags: String
      var priority: Int
      var isActive: Bool
    }
  }

  private func skillsFilePath(repoPath: String) -> String {
    (repoPath as NSString).appendingPathComponent(Self.skillsFileName)
  }

  func exportSkillsToFile(repoPath: String) throws -> (count: Int, path: String) {
    let skills = listRepoGuidanceSkills(repoPath: repoPath, repoRemoteURL: nil, includeInactive: true, limit: nil)
    let entries = skills.map { s in
      SkillsFile.SkillEntry(title: s.title, body: s.body, tags: s.tags, priority: s.priority, isActive: s.isActive)
    }
    let file = SkillsFile(version: 1, skills: entries)
    let filePath = skillsFilePath(repoPath: repoPath)
    let dir = (filePath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(file)
    try data.write(to: URL(fileURLWithPath: filePath))
    return (entries.count, filePath)
  }

  func importSkillsFromFile(repoPath: String) throws -> (imported: Int, skipped: Int) {
    let filePath = skillsFilePath(repoPath: repoPath)
    let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
    let file = try JSONDecoder().decode(SkillsFile.self, from: data)
    let existing = Set(listRepoGuidanceSkills(repoPath: repoPath, repoRemoteURL: nil, includeInactive: true, limit: nil).map { $0.title })
    var imported = 0
    var skipped = 0
    for entry in file.skills {
      if existing.contains(entry.title) {
        skipped += 1
      } else {
        addRepoGuidanceSkill(repoPath: repoPath, repoRemoteURL: nil, repoName: nil,
          title: entry.title, body: entry.body, source: "file",
          tags: entry.tags, priority: entry.priority, isActive: entry.isActive)
        imported += 1
      }
    }
    return (imported, skipped)
  }

  func syncSkillsWithFile(repoPath: String) throws -> (exported: Int, imported: Int, path: String) {
    let filePath = skillsFilePath(repoPath: repoPath)
    let fm = FileManager.default
    // Load existing file skills (if any)
    var fileEntries: [SkillsFile.SkillEntry] = []
    if fm.fileExists(atPath: filePath) {
      let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
      fileEntries = (try? JSONDecoder().decode(SkillsFile.self, from: data))?.skills ?? []
    }
    let fileTitles = Set(fileEntries.map { $0.title })
    let dbSkills = listRepoGuidanceSkills(repoPath: repoPath, repoRemoteURL: nil, includeInactive: true, limit: nil)
    let dbTitles = Set(dbSkills.map { $0.title })
    // Export DB skills not in file
    let toExport = dbSkills.filter { !fileTitles.contains($0.title) }
    let newEntries = toExport.map { s in
      SkillsFile.SkillEntry(title: s.title, body: s.body, tags: s.tags, priority: s.priority, isActive: s.isActive)
    }
    let merged = SkillsFile(version: 1, skills: fileEntries + newEntries)
    let dir = (filePath as NSString).deletingLastPathComponent
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(merged)
    try data.write(to: URL(fileURLWithPath: filePath))
    // Import file skills not in DB
    var imported = 0
    for entry in fileEntries where !dbTitles.contains(entry.title) {
      addRepoGuidanceSkill(repoPath: repoPath, repoRemoteURL: nil, repoName: nil,
        title: entry.title, body: entry.body, source: "file",
        tags: entry.tags, priority: entry.priority, isActive: entry.isActive)
      imported += 1
    }
    return (newEntries.count, imported, filePath)
  }

  // MARK: - Branch-Aware RAG Indexing (Issue #260)

  func indexBranchRepository(
    repoPath: String,
    baseBranch: String,
    baseRepoPath: String?,
    progressHandler: (@Sendable (RAGToolIndexProgress) -> Void)?
  ) async throws -> (report: RAGToolIndexReport, changedFilesCount: Int, deletedFilesCount: Int, wasCopiedFromBase: Bool, baseRepoPath: String?) {
    // Get DB URL
    let status = await localRagStore.status()
    let dbURL = URL(fileURLWithPath: status.dbPath)

    // Detect main repo path
    let resolvedBaseRepoPath = baseRepoPath ?? BranchIndexService.gitMainWorktreePath(from: repoPath)

    // Find changed/deleted files relative to baseBranch
    let (changedFiles, deletedFiles) = BranchIndexService.gitChangedFiles(repoPath: repoPath, baseBranch: baseBranch)

    // Attempt to copy index from base repo if this repo has no existing index
    var wasCopiedFromBase = false
    if let base = resolvedBaseRepoPath {
      do {
        let existingStats = try await getIndexStats(repoPath: repoPath)
        if existingStats.fileCount == 0 {
          let copied = try BranchIndexService.copyRepoIndex(from: base, to: repoPath, dbURL: dbURL)
          if copied > 0 {
            wasCopiedFromBase = true
          }
        }
      } catch {
        // Log but don't fail — fall through to full reindex
        await logWarning("Branch index copy failed, falling back to full index", metadata: [
          "error": error.localizedDescription,
          "repoPath": repoPath,
          "baseRepoPath": base
        ])
      }
    }

    // Run incremental index (re-indexes changed files, removes deleted)
    let report = try await indexRepository(
      path: repoPath,
      forceReindex: false,
      allowWorkspace: false,
      excludeSubrepos: true,
      progressHandler: progressHandler
    )

    return (
      report: report,
      changedFilesCount: changedFiles.count,
      deletedFilesCount: deletedFiles.count,
      wasCopiedFromBase: wasCopiedFromBase,
      baseRepoPath: resolvedBaseRepoPath
    )
  }

  func cleanupBranchIndexes(dryRun: Bool) async throws -> (removedCount: Int, removedPaths: [String]) {
    let repos = try await listRagRepos()
    let stale = repos.filter { !FileManager.default.fileExists(atPath: $0.rootPath) }

    if dryRun {
      return (stale.count, stale.map { $0.rootPath })
    }

    var removedPaths = [String]()
    for repo in stale {
      _ = try await deleteRagRepo(repoId: repo.id, repoPath: nil)
      removedPaths.append(repo.rootPath)
    }
    if !removedPaths.isEmpty {
      await refreshRagSummary()
    }
    return (removedPaths.count, removedPaths)
  }
}
