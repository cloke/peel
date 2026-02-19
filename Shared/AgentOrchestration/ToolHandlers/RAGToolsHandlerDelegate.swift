//
//  RAGToolsHandlerDelegate.swift
//  Peel
//
//  Delegate protocol for RAG tools, split from RAGToolsHandler.swift (#301).
//

import Foundation
import MCPCore
import SwiftData

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

