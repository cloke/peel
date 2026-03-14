//
//  RAGRepoSync.swift
//  Peel
//
//  Per-repo export/import for RAG sync (#303).
//  Enables syncing a single repo's RAG data without overwriting
//  other repos in the database. Uses repoIdentifier (normalized
//  git remote URL) for cross-machine matching.
//

import CryptoKit
import CSQLite
import Foundation
import RAGCore

// MARK: - Export/Import Bundle Types

/// A per-repo export bundle containing all RAG data for one repository.
/// When the repo has sub-packages (e.g. Local Packages/Git), they are included
/// in `subPackages` so the receiver gets the full index.
struct RAGRepoExportBundle: Codable, Sendable {
  let manifest: RAGRepoSyncManifest
  let repo: ExportedRepo
  let files: [ExportedFile]
  /// Sub-packages that share the same repoIdentifier (e.g. Swift local packages).
  /// Optional for backward compatibility with bundles from older senders.
  let subPackages: [SubPackageExport]?

  var totalChunks: Int {
    let main = files.reduce(0) { $0 + $1.chunks.count }
    let sub = (subPackages ?? []).reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.chunks.count } }
    return main + sub
  }
  var totalEmbeddings: Int {
    let main = files.reduce(0) { $0 + $1.chunks.filter { $0.embeddingBase64 != nil }.count }
    let sub = (subPackages ?? []).reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.chunks.filter { $0.embeddingBase64 != nil }.count } }
    return main + sub
  }
}

/// A sub-package export: its repo row + files/chunks.
struct SubPackageExport: Codable, Sendable {
  let repo: ExportedRepo
  let files: [ExportedFile]
  let fileHashes: [RAGRepoSyncManifest.FileHashEntry]
}

/// Manifest for a per-repo sync — describes what the sender has.
public struct RAGRepoSyncManifest: Codable, Sendable {
  let repoIdentifier: String
  let repoName: String
  let schemaVersion: Int
  let embeddingModel: String
  let embeddingDimensions: Int
  let createdAt: Date
  let headSHA: String?
  let fileCount: Int
  let chunkCount: Int
  let fileHashes: [FileHashEntry]

  public struct FileHashEntry: Codable, Sendable {
    let fileId: String
    let path: String
    let hash: String
    let chunkCount: Int
    let language: String?
    let updatedAt: String?
  }
}

/// Exported repo row.
struct ExportedRepo: Codable, Sendable {
  let id: String
  let name: String
  let rootPath: String
  let repoIdentifier: String
  let lastIndexedAt: String?
  let parentRepoId: String?
  let embeddingModel: String?
  let embeddingDimensions: Int?
}

fileprivate struct MatchedRepoCandidate: Sendable {
  let repo: ExportedRepo
  let fileCount: Int
  let chunkCount: Int
}

/// Exported file with its chunks and embeddings.
struct ExportedFile: Codable, Sendable {
  let id: String
  let path: String
  let hash: String
  let language: String?
  let updatedAt: String?
  let modulePath: String?
  let featureTags: String?
  let lineCount: Int
  let methodCount: Int
  let byteSize: Int
  let chunks: [ExportedChunk]
}

/// Exported chunk with optional embedding.
struct ExportedChunk: Codable, Sendable {
  let id: String
  let startLine: Int
  let endLine: Int
  let text: String
  let tokenCount: Int
  let constructType: String?
  let constructName: String?
  let metadata: String?
  let aiSummary: String?
  let aiTags: String?
  let analyzedAt: String?
  let analyzerModel: String?
  let enrichedAt: String?
  /// Base64-encoded embedding blob (Float array).
  let embeddingBase64: String?
}

// MARK: - Overlay Sync Types

/// Lightweight overlay bundle: embeddings + analysis only, no chunk text.
/// Used when the receiver already has the repo indexed locally (same source code)
/// and just needs pre-computed embeddings and AI analysis from a more powerful peer.
/// Typically ~100x smaller than a full export bundle.
struct RAGRepoOverlayBundle: Codable, Sendable {
  let manifest: RAGRepoOverlayManifest
  let files: [OverlayFileData]

  var totalEntries: Int { files.reduce(0) { $0 + $1.chunks.count } }
  var totalEmbeddings: Int { files.reduce(0) { $0 + $1.chunks.filter { $0.embeddingBase64 != nil }.count } }
  var totalAnalysis: Int { files.reduce(0) { $0 + $1.chunks.filter { $0.aiSummary != nil }.count } }
}

/// Manifest for an overlay sync — describes what the sender has and the embedding model used.
struct RAGRepoOverlayManifest: Codable, Sendable {
  let repoIdentifier: String
  let repoName: String
  let schemaVersion: Int
  let embeddingModel: String
  let embeddingDimensions: Int
  let createdAt: Date
  let headSHA: String?
  let fileCount: Int
  let chunkCount: Int
  /// File hashes for matching — receiver uses these to find locally-indexed files.
  let fileHashes: [RAGRepoSyncManifest.FileHashEntry]
}

/// Per-file overlay data: just the file hash (matching key) and chunk overlays.
struct OverlayFileData: Codable, Sendable {
  /// File content hash — used to match against the receiver's locally-indexed file.
  let hash: String
  /// Relative path (for logging/diagnostics only, not used for matching).
  let path: String
  let chunks: [OverlayChunkData]
}

/// Per-chunk overlay: matching key (line range) + embeddings + analysis. No source text.
struct OverlayChunkData: Codable, Sendable {
  // Matching key: file hash (from parent) + line range identifies the chunk
  let startLine: Int
  let endLine: Int

  // Embedding (the expensive part from the powerful machine)
  let embeddingBase64: String?

  // AI analysis (expensive LLM-generated enrichment)
  let aiSummary: String?
  let aiTags: String?
  let analyzedAt: String?
  let analyzerModel: String?
  let enrichedAt: String?
}

// MARK: - RAGRepoExporter

/// Reads a RAG SQLite database and exports one repo's data.
/// Uses a separate read-only connection to avoid blocking the main RAGStore actor.
enum RAGRepoExporter {

  /// Export a single repo's data from the RAG database.
  /// - Parameters:
  ///   - dbPath: Path to rag.sqlite
  ///   - repoIdentifier: Normalized git remote URL (e.g. "github.com/tuitionio/tio-front-end")
  ///   - schemaVersion: Current schema version
  ///   - embeddingModel: Embedding model name
  ///   - embeddingDimensions: Embedding vector dimensions
  ///   - excludeFileHashes: Set of file hashes the receiver already has (for delta sync)
  /// - Returns: RAGRepoExportBundle or nil if repo not found
  static func exportRepo(
    dbPath: String,
    repoIdentifier: String,
    schemaVersion: Int,
    embeddingModel: String,
    embeddingDimensions: Int,
    excludeFileHashes: Set<String> = []
  ) throws -> RAGRepoExportBundle? {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    let result = sqlite3_open_v2(dbPath, &db, flags, nil)
    guard result == SQLITE_OK, let db else {
      throw RAGStore.RAGError.sqlite("Cannot open database for export: \(result)")
    }
    defer { sqlite3_close(db) }

    // Find all matching repos for this identifier (parent + sub-packages).
    let candidates = queryRepoCandidates(db: db, repoIdentifier: repoIdentifier)
    guard let primaryCandidate = selectBestRepoCandidate(candidates) else {
      return nil
    }
    let repo = primaryCandidate.repo

    // Query all files for the primary repo
    let allFileHashes = queryFileHashes(db: db, repoId: repo.id)

    // Build manifest — counts include sub-packages for accurate totals
    let headSHA = gitHeadSHA(for: repo.rootPath)
    let (effectiveEmbeddingModel, effectiveEmbeddingDimensions) = resolveEmbeddingProfile(
      for: primaryCandidate,
      among: candidates,
      defaultEmbeddingModel: embeddingModel,
      defaultEmbeddingDimensions: embeddingDimensions
    )

    // Export sub-packages (other candidates that aren't the primary)
    var subPackages: [SubPackageExport] = []
    for candidate in candidates where candidate.repo.id != repo.id {
      let subFileHashes = queryFileHashes(db: db, repoId: candidate.repo.id)
      var subFiles: [ExportedFile] = []
      for fileHash in subFileHashes {
        if excludeFileHashes.contains(fileHash.hash) { continue }
        if let file = queryFile(db: db, fileId: fileHash.fileId) {
          subFiles.append(file)
        }
      }
      if !subFiles.isEmpty || !subFileHashes.isEmpty {
        subPackages.append(SubPackageExport(
          repo: candidate.repo,
          files: subFiles,
          fileHashes: subFileHashes
        ))
      }
    }

    // Aggregate counts across primary + sub-packages
    let totalFileCount = allFileHashes.count + subPackages.reduce(0) { $0 + $1.fileHashes.count }
    let totalChunkCount = allFileHashes.reduce(0) { $0 + $1.chunkCount }
      + subPackages.reduce(0) { $0 + $1.fileHashes.reduce(0) { $0 + $1.chunkCount } }
    let allManifestHashes = allFileHashes + subPackages.flatMap(\.fileHashes)

    let manifest = RAGRepoSyncManifest(
      repoIdentifier: repoIdentifier,
      repoName: repo.name,
      schemaVersion: schemaVersion,
      embeddingModel: effectiveEmbeddingModel,
      embeddingDimensions: effectiveEmbeddingDimensions,
      createdAt: Date(),
      headSHA: headSHA,
      fileCount: totalFileCount,
      chunkCount: totalChunkCount,
      fileHashes: allManifestHashes
    )

    // Export primary repo files (skipping those the receiver already has)
    var exportedFiles: [ExportedFile] = []
    for fileHash in allFileHashes {
      if excludeFileHashes.contains(fileHash.hash) {
        continue // Receiver already has this version
      }
      if let file = queryFile(db: db, fileId: fileHash.fileId) {
        exportedFiles.append(file)
      }
    }

    return RAGRepoExportBundle(
      manifest: manifest,
      repo: repo,
      files: exportedFiles,
      subPackages: subPackages.isEmpty ? nil : subPackages
    )
  }

  /// Build a manifest-only (no file data) for delta negotiation.
  static func buildManifest(
    dbPath: String,
    repoIdentifier: String,
    schemaVersion: Int,
    embeddingModel: String,
    embeddingDimensions: Int
  ) throws -> RAGRepoSyncManifest? {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    let result = sqlite3_open_v2(dbPath, &db, flags, nil)
    guard result == SQLITE_OK, let db else {
      throw RAGStore.RAGError.sqlite("Cannot open database for manifest: \(result)")
    }
    defer { sqlite3_close(db) }

    let candidates = queryRepoCandidates(db: db, repoIdentifier: repoIdentifier)
    guard let candidate = selectBestRepoCandidate(candidates) else {
      return nil
    }
    let repo = candidate.repo

    let fileHashes = queryFileHashes(db: db, repoId: repo.id)
    let headSHA = gitHeadSHA(for: repo.rootPath)

    let (effectiveEmbeddingModel, effectiveEmbeddingDimensions) = resolveEmbeddingProfile(
      for: candidate,
      among: candidates,
      defaultEmbeddingModel: embeddingModel,
      defaultEmbeddingDimensions: embeddingDimensions
    )

    // Include sub-package file hashes in manifest for accurate totals
    var allHashes = fileHashes
    for c in candidates where c.repo.id != repo.id {
      allHashes += queryFileHashes(db: db, repoId: c.repo.id)
    }

    return RAGRepoSyncManifest(
      repoIdentifier: repoIdentifier,
      repoName: repo.name,
      schemaVersion: schemaVersion,
      embeddingModel: effectiveEmbeddingModel,
      embeddingDimensions: effectiveEmbeddingDimensions,
      createdAt: Date(),
      headSHA: headSHA,
      fileCount: allHashes.count,
      chunkCount: allHashes.reduce(0) { $0 + $1.chunkCount },
      fileHashes: allHashes
    )
  }

  // MARK: - Schema Introspection

  /// Check if a column exists in a table (works on read-only connections).
  private static func columnExists(_ db: OpaquePointer, table: String, column: String) -> Bool {
    let sql = "PRAGMA table_info(\(table))"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW {
      if let name = sqlite3_column_text(stmt, 1) {
        if String(cString: name) == column { return true }
      }
    }
    return false
  }

  /// Read current schema version from rag_meta.
  private static func readSchemaVersion(_ db: OpaquePointer) -> Int {
    let sql = "SELECT CAST(value AS INTEGER) FROM rag_meta WHERE key = 'schema_version'"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int(stmt, 0))
  }

  // MARK: - Private Queries

  fileprivate static func queryRepoCandidates(db: OpaquePointer, repoIdentifier: String) -> [MatchedRepoCandidate] {
    // repo_identifier added in v11, parent_repo_id in v12 — adapt query for older schemas
    let hasRepoIdentifier = columnExists(db, table: "repos", column: "repo_identifier")
    let hasParentRepoId = columnExists(db, table: "repos", column: "parent_repo_id")
    let hasEmbeddingModel = columnExists(db, table: "repos", column: "embedding_model")
    let hasEmbeddingDimensions = columnExists(db, table: "repos", column: "embedding_dimensions")

    // If the source DB doesn't have repo_identifier column, we can't match by it
    guard hasRepoIdentifier else { return [] }

    var columns = "id, name, root_path, repo_identifier, last_indexed_at"
    if hasParentRepoId { columns += ", parent_repo_id" }
    if hasEmbeddingModel { columns += ", embedding_model" }
    if hasEmbeddingDimensions { columns += ", embedding_dimensions" }
    columns += ", (SELECT COUNT(*) FROM files f WHERE f.repo_id = repos.id) AS file_count"
    columns += ", (SELECT COUNT(*) FROM chunks c JOIN files f ON c.file_id = f.id WHERE f.repo_id = repos.id) AS chunk_count"

    // Strategy 1: Match by exact repo_identifier
    let exactMatches = execQueryRepos(db: db, columns: columns,
        whereClause: "repo_identifier = ?", bindValue: repoIdentifier,
        hasParentRepoId: hasParentRepoId, hasEmbeddingModel: hasEmbeddingModel,
        hasEmbeddingDimensions: hasEmbeddingDimensions)
    if !exactMatches.isEmpty {
      return exactMatches
    }

    // Strategy 2: Extract the last path component (repo name) from the identifier
    // e.g., "github.com/cloke/peel" → "peel", "/Users/me/code/kitchen-sink" → "kitchen-sink"
    // Also handles short names like "tio-api" (no slashes → repoName == repoIdentifier)
    let repoName = repoIdentifier.split(separator: "/").last.map(String.init) ?? repoIdentifier
    if !repoName.isEmpty {
      // First try matching by name column
      let nameMatches = execQueryRepos(db: db, columns: columns,
          whereClause: "name = ?", bindValue: repoName,
          hasParentRepoId: hasParentRepoId, hasEmbeddingModel: hasEmbeddingModel,
          hasEmbeddingDimensions: hasEmbeddingDimensions)
      if !nameMatches.isEmpty {
        return nameMatches
      }

      // Also try matching the short name against the last component of stored repo_identifiers
      // e.g., "tio-api" should match a row where repo_identifier = "github.com/tuitionio/tio-api"
      let suffixMatches = execQueryRepos(db: db, columns: columns,
          whereClause: "repo_identifier LIKE ?", bindValue: "%/\(repoName)",
          hasParentRepoId: hasParentRepoId, hasEmbeddingModel: hasEmbeddingModel,
          hasEmbeddingDimensions: hasEmbeddingDimensions)
      if !suffixMatches.isEmpty {
        return suffixMatches
      }
    }

    // Strategy 3: Match root_path ending with the repo name (handles NULL repo_identifier)
    if !repoName.isEmpty {
      let pathMatches = execQueryRepos(db: db, columns: columns,
          whereClause: "root_path LIKE ?", bindValue: "%/\(repoName)",
          hasParentRepoId: hasParentRepoId, hasEmbeddingModel: hasEmbeddingModel,
          hasEmbeddingDimensions: hasEmbeddingDimensions)
      if !pathMatches.isEmpty {
        return pathMatches
      }
    }

    return []
  }

  /// Execute a repo query with the given WHERE clause and bind value.
  private static func execQueryRepos(
    db: OpaquePointer,
    columns: String,
    whereClause: String,
    bindValue: String,
    hasParentRepoId: Bool,
    hasEmbeddingModel: Bool,
    hasEmbeddingDimensions: Bool
  ) -> [MatchedRepoCandidate] {
    let sql = "SELECT \(columns) FROM repos WHERE \(whereClause)"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, bindValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

    let parentIndex: Int32 = hasParentRepoId ? 5 : -1
    let embeddingModelIndex: Int32 = hasEmbeddingModel ? (hasParentRepoId ? 6 : 5) : -1
    let embeddingDimensionsIndex: Int32 = hasEmbeddingDimensions ? (embeddingModelIndex >= 0 ? embeddingModelIndex + 1 : (hasParentRepoId ? 6 : 5)) : -1

    let fileCountIndex = embeddingDimensionsIndex >= 0
      ? embeddingDimensionsIndex + 1
      : (embeddingModelIndex >= 0 ? embeddingModelIndex + 1 : (hasParentRepoId ? 6 : 5))
    let chunkCountIndex = fileCountIndex + 1

    var results: [MatchedRepoCandidate] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let repo = ExportedRepo(
        id: columnString(stmt, 0),
        name: columnString(stmt, 1),
        rootPath: columnString(stmt, 2),
        repoIdentifier: columnString(stmt, 3),
        lastIndexedAt: columnOptionalString(stmt, 4),
        parentRepoId: parentIndex >= 0 ? columnOptionalString(stmt, parentIndex) : nil,
        embeddingModel: embeddingModelIndex >= 0 ? columnOptionalString(stmt, embeddingModelIndex) : nil,
        embeddingDimensions: embeddingDimensionsIndex >= 0 ? columnOptionalInt(stmt, embeddingDimensionsIndex) : nil
      )
      results.append(MatchedRepoCandidate(
        repo: repo,
        fileCount: Int(sqlite3_column_int(stmt, fileCountIndex)),
        chunkCount: Int(sqlite3_column_int(stmt, chunkCountIndex))
      ))
    }
    return results
  }

  fileprivate static func selectBestRepoCandidate(_ candidates: [MatchedRepoCandidate]) -> MatchedRepoCandidate? {
    candidates.max { lhs, rhs in
      if lhs.fileCount != rhs.fileCount {
        return lhs.fileCount < rhs.fileCount
      }
      if lhs.chunkCount != rhs.chunkCount {
        return lhs.chunkCount < rhs.chunkCount
      }
      let lhsIsParent = lhs.repo.parentRepoId == nil
      let rhsIsParent = rhs.repo.parentRepoId == nil
      if lhsIsParent != rhsIsParent {
        return !lhsIsParent && rhsIsParent
      }
      return lhs.repo.rootPath.count > rhs.repo.rootPath.count
    }
  }

  private static func resolveEmbeddingProfile(
    for candidate: MatchedRepoCandidate,
    among candidates: [MatchedRepoCandidate],
    defaultEmbeddingModel: String,
    defaultEmbeddingDimensions: Int
  ) -> (String, Int) {
    if candidates.count > 1 {
      let models = Set(candidates.compactMap {
        let trimmed = $0.repo.embeddingModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
      })
      let dimensions = Set(candidates.compactMap(\.repo.embeddingDimensions))
      let hasIncompleteMetadata = candidates.contains {
        let model = $0.repo.embeddingModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return model == nil || model?.isEmpty == true || $0.repo.embeddingDimensions == nil
      }
      if hasIncompleteMetadata || models.count != 1 || dimensions.count != 1 {
        return (defaultEmbeddingModel, defaultEmbeddingDimensions)
      }
    }

    let repoModel = candidate.repo.embeddingModel?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let repoModel, !repoModel.isEmpty,
       let repoDimensions = candidate.repo.embeddingDimensions {
      return (repoModel, repoDimensions)
    }
    return (defaultEmbeddingModel, defaultEmbeddingDimensions)
  }

  private static func queryFileHashes(db: OpaquePointer, repoId: String) -> [RAGRepoSyncManifest.FileHashEntry] {
    let sql = """
      SELECT f.id, f.path, f.hash, f.language, f.updated_at,
             (SELECT COUNT(*) FROM chunks WHERE file_id = f.id) as chunk_count
      FROM files f WHERE f.repo_id = ?
      ORDER BY f.path
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, repoId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

    var entries: [RAGRepoSyncManifest.FileHashEntry] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      entries.append(RAGRepoSyncManifest.FileHashEntry(
        fileId: columnString(stmt, 0),
        path: columnString(stmt, 1),
        hash: columnString(stmt, 2),
        chunkCount: Int(sqlite3_column_int(stmt, 5)),
        language: columnOptionalString(stmt, 3),
        updatedAt: columnOptionalString(stmt, 4)
      ))
    }
    return entries
  }

  private static func queryFile(db: OpaquePointer, fileId: String) -> ExportedFile? {
    // module_path/feature_tags added in v7, line_count/method_count/byte_size in v13
    let hasModulePath = columnExists(db, table: "files", column: "module_path")
    let hasLineCount = columnExists(db, table: "files", column: "line_count")

    var columns = "id, path, hash, language, updated_at"
    // Track column indices dynamically
    var idx: Int32 = 5
    let modulePathIdx: Int32?
    let featureTagsIdx: Int32?
    let lineCountIdx: Int32?
    let methodCountIdx: Int32?
    let byteSizeIdx: Int32?

    if hasModulePath {
      columns += ", module_path, feature_tags"
      modulePathIdx = idx; idx += 1
      featureTagsIdx = idx; idx += 1
    } else {
      modulePathIdx = nil; featureTagsIdx = nil
    }
    if hasLineCount {
      columns += ", line_count, method_count, byte_size"
      lineCountIdx = idx; idx += 1
      methodCountIdx = idx; idx += 1
      byteSizeIdx = idx; idx += 1
    } else {
      lineCountIdx = nil; methodCountIdx = nil; byteSizeIdx = nil
    }

    let fileSql = "SELECT \(columns) FROM files WHERE id = ?"
    var fileStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, fileSql, -1, &fileStmt, nil) == SQLITE_OK, let fileStmt else { return nil }
    defer { sqlite3_finalize(fileStmt) }

    sqlite3_bind_text(fileStmt, 1, fileId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(fileStmt) == SQLITE_ROW else { return nil }

    let file = (
      id: columnString(fileStmt, 0),
      path: columnString(fileStmt, 1),
      hash: columnString(fileStmt, 2),
      language: columnOptionalString(fileStmt, 3),
      updatedAt: columnOptionalString(fileStmt, 4),
      modulePath: modulePathIdx.flatMap { columnOptionalString(fileStmt, $0) },
      featureTags: featureTagsIdx.flatMap { columnOptionalString(fileStmt, $0) },
      lineCount: lineCountIdx.map { Int(sqlite3_column_int(fileStmt, $0)) } ?? 0,
      methodCount: methodCountIdx.map { Int(sqlite3_column_int(fileStmt, $0)) } ?? 0,
      byteSize: byteSizeIdx.map { Int(sqlite3_column_int(fileStmt, $0)) } ?? 0
    )

    // Query chunks for this file
    let chunks = queryChunks(db: db, fileId: fileId)

    return ExportedFile(
      id: file.id,
      path: file.path,
      hash: file.hash,
      language: file.language,
      updatedAt: file.updatedAt,
      modulePath: file.modulePath,
      featureTags: file.featureTags,
      lineCount: file.lineCount,
      methodCount: file.methodCount,
      byteSize: file.byteSize,
      chunks: chunks
    )
  }

  private static func queryChunks(db: OpaquePointer, fileId: String) -> [ExportedChunk] {
    // ai_summary/ai_tags/analyzed_at/analyzer_model added in v6, enriched_at in v8
    let hasAnalysis = columnExists(db, table: "chunks", column: "ai_summary")
    let hasEnrichedAt = columnExists(db, table: "chunks", column: "enriched_at")

    var columns = "c.id, c.start_line, c.end_line, c.text, c.token_count, c.construct_type, c.construct_name, c.metadata"
    // Track column indices dynamically (base columns = 0..7)
    var idx: Int32 = 8
    let aiSummaryIdx: Int32?
    let aiTagsIdx: Int32?
    let analyzedAtIdx: Int32?
    let analyzerModelIdx: Int32?
    let enrichedAtIdx: Int32?
    let embeddingIdx: Int32

    if hasAnalysis {
      columns += ", c.ai_summary, c.ai_tags, c.analyzed_at, c.analyzer_model"
      aiSummaryIdx = idx; idx += 1
      aiTagsIdx = idx; idx += 1
      analyzedAtIdx = idx; idx += 1
      analyzerModelIdx = idx; idx += 1
    } else {
      aiSummaryIdx = nil; aiTagsIdx = nil; analyzedAtIdx = nil; analyzerModelIdx = nil
    }
    if hasEnrichedAt {
      columns += ", c.enriched_at"
      enrichedAtIdx = idx; idx += 1
    } else {
      enrichedAtIdx = nil
    }
    columns += ", e.embedding"
    embeddingIdx = idx

    let sql = """
      SELECT \(columns)
      FROM chunks c
      LEFT JOIN embeddings e ON e.chunk_id = c.id
      WHERE c.file_id = ?
      ORDER BY c.start_line
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, fileId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

    var chunks: [ExportedChunk] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      // Read embedding blob as base64
      var embeddingBase64: String?
      if let blob = sqlite3_column_blob(stmt, embeddingIdx) {
        let blobSize = Int(sqlite3_column_bytes(stmt, embeddingIdx))
        let data = Data(bytes: blob, count: blobSize)
        embeddingBase64 = data.base64EncodedString()
      }

      chunks.append(ExportedChunk(
        id: columnString(stmt, 0),
        startLine: Int(sqlite3_column_int(stmt, 1)),
        endLine: Int(sqlite3_column_int(stmt, 2)),
        text: columnString(stmt, 3),
        tokenCount: Int(sqlite3_column_int(stmt, 4)),
        constructType: columnOptionalString(stmt, 5),
        constructName: columnOptionalString(stmt, 6),
        metadata: columnOptionalString(stmt, 7),
        aiSummary: aiSummaryIdx.flatMap { columnOptionalString(stmt, $0) },
        aiTags: aiTagsIdx.flatMap { columnOptionalString(stmt, $0) },
        analyzedAt: analyzedAtIdx.flatMap { columnOptionalString(stmt, $0) },
        analyzerModel: analyzerModelIdx.flatMap { columnOptionalString(stmt, $0) },
        enrichedAt: enrichedAtIdx.flatMap { columnOptionalString(stmt, $0) },
        embeddingBase64: embeddingBase64
      ))
    }
    return chunks
  }

  // MARK: - Helpers

  private static func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String {
    guard let text = sqlite3_column_text(stmt, index) else { return "" }
    return String(cString: text)
  }

  private static func columnOptionalString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
          let text = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: text)
  }

  private static func columnOptionalInt(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int(stmt, index))
  }

  private static func gitHeadSHA(for repoPath: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "HEAD"]
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }

  // MARK: - Overlay Export

  /// Export only embeddings + analysis for a repo (no chunk text, no file content).
  /// Used when the receiver already has the repo indexed locally and just needs
  /// pre-computed data from a more powerful peer.
  ///
  /// - Parameters:
  ///   - dbPath: Path to rag.sqlite
  ///   - repoIdentifier: Normalized git remote URL
  ///   - schemaVersion: Current schema version
  ///   - embeddingModel: Embedding model name
  ///   - embeddingDimensions: Embedding vector dimensions
  ///   - excludeFileHashes: Set of file hashes the receiver already has overlay data for
  /// - Returns: RAGRepoOverlayBundle or nil if repo not found
  static func exportRepoOverlay(
    dbPath: String,
    repoIdentifier: String,
    schemaVersion: Int,
    embeddingModel: String,
    embeddingDimensions: Int,
    excludeFileHashes: Set<String> = []
  ) throws -> RAGRepoOverlayBundle? {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    let result = sqlite3_open_v2(dbPath, &db, flags, nil)
    guard result == SQLITE_OK, let db else {
      throw RAGStore.RAGError.sqlite("Cannot open database for overlay export: \(result)")
    }
    defer { sqlite3_close(db) }

    let candidates = queryRepoCandidates(db: db, repoIdentifier: repoIdentifier)
    guard let candidate = selectBestRepoCandidate(candidates) else {
      return nil
    }
    let repo = candidate.repo

    let allFileHashes = queryFileHashes(db: db, repoId: repo.id)
    let headSHA = gitHeadSHA(for: repo.rootPath)

    let (effectiveEmbeddingModel, effectiveEmbeddingDimensions) = resolveEmbeddingProfile(
      for: candidate,
      among: candidates,
      defaultEmbeddingModel: embeddingModel,
      defaultEmbeddingDimensions: embeddingDimensions
    )

    let manifest = RAGRepoOverlayManifest(
      repoIdentifier: repoIdentifier,
      repoName: repo.name,
      schemaVersion: schemaVersion,
      embeddingModel: effectiveEmbeddingModel,
      embeddingDimensions: effectiveEmbeddingDimensions,
      createdAt: Date(),
      headSHA: headSHA,
      fileCount: allFileHashes.count,
      chunkCount: allFileHashes.reduce(0) { $0 + $1.chunkCount },
      fileHashes: allFileHashes
    )

    // Export overlay data per file (skipping those the receiver already has)
    var overlayFiles: [OverlayFileData] = []
    for fileHash in allFileHashes {
      if excludeFileHashes.contains(fileHash.hash) {
        continue
      }
      let chunks = queryOverlayChunks(db: db, fileId: fileHash.fileId)
      // Only include files that have at least one embedding or analysis entry
      let hasData = chunks.contains { $0.embeddingBase64 != nil || $0.aiSummary != nil }
      if hasData {
        overlayFiles.append(OverlayFileData(
          hash: fileHash.hash,
          path: fileHash.path,
          chunks: chunks
        ))
      }
    }

    return RAGRepoOverlayBundle(
      manifest: manifest,
      files: overlayFiles
    )
  }

  /// Query only the overlay-relevant data for chunks: line range + embedding + analysis.
  /// Omits chunk text, token count, construct metadata.
  private static func queryOverlayChunks(db: OpaquePointer, fileId: String) -> [OverlayChunkData] {
    let hasAnalysis = columnExists(db, table: "chunks", column: "ai_summary")
    let hasEnrichedAt = columnExists(db, table: "chunks", column: "enriched_at")

    var columns = "c.start_line, c.end_line"
    var idx: Int32 = 2
    let aiSummaryIdx: Int32?
    let aiTagsIdx: Int32?
    let analyzedAtIdx: Int32?
    let analyzerModelIdx: Int32?
    let enrichedAtIdx: Int32?
    let embeddingIdx: Int32

    if hasAnalysis {
      columns += ", c.ai_summary, c.ai_tags, c.analyzed_at, c.analyzer_model"
      aiSummaryIdx = idx; idx += 1
      aiTagsIdx = idx; idx += 1
      analyzedAtIdx = idx; idx += 1
      analyzerModelIdx = idx; idx += 1
    } else {
      aiSummaryIdx = nil; aiTagsIdx = nil; analyzedAtIdx = nil; analyzerModelIdx = nil
    }
    if hasEnrichedAt {
      columns += ", c.enriched_at"
      enrichedAtIdx = idx; idx += 1
    } else {
      enrichedAtIdx = nil
    }
    columns += ", e.embedding"
    embeddingIdx = idx

    let sql = """
      SELECT \(columns)
      FROM chunks c
      LEFT JOIN embeddings e ON e.chunk_id = c.id
      WHERE c.file_id = ?
      ORDER BY c.start_line
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, fileId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

    var chunks: [OverlayChunkData] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      var embeddingBase64: String?
      if let blob = sqlite3_column_blob(stmt, embeddingIdx) {
        let blobSize = Int(sqlite3_column_bytes(stmt, embeddingIdx))
        let data = Data(bytes: blob, count: blobSize)
        embeddingBase64 = data.base64EncodedString()
      }

      chunks.append(OverlayChunkData(
        startLine: Int(sqlite3_column_int(stmt, 0)),
        endLine: Int(sqlite3_column_int(stmt, 1)),
        embeddingBase64: embeddingBase64,
        aiSummary: aiSummaryIdx.flatMap { columnOptionalString(stmt, $0) },
        aiTags: aiTagsIdx.flatMap { columnOptionalString(stmt, $0) },
        analyzedAt: analyzedAtIdx.flatMap { columnOptionalString(stmt, $0) },
        analyzerModel: analyzerModelIdx.flatMap { columnOptionalString(stmt, $0) },
        enrichedAt: enrichedAtIdx.flatMap { columnOptionalString(stmt, $0) }
      ))
    }
    return chunks
  }
}

// MARK: - RAGRepoImporter

/// Imports a per-repo export bundle into the local RAG database.
/// Merges data for one repo without affecting other repos.
enum RAGRepoImporter {

  /// Import a repo export bundle into the local database.
  /// - Parameters:
  ///   - bundle: The exported repo data
  ///   - dbPath: Path to the local rag.sqlite
  ///   - localRepoPath: Local path where this repo lives (for path remapping)
  ///   - localEmbeddingModel: The embedding model name used locally (for compatibility check)
  ///   - localEmbeddingDimensions: The embedding dimensions used locally (for compatibility check)
  ///   - forceImportEmbeddings: When true, import embeddings even if models differ (useful when not indexing locally)
  /// - Returns: Import summary
  @discardableResult
  static func importRepo(
    bundle: RAGRepoExportBundle,
    dbPath: String,
    localRepoPath: String? = nil,
    localEmbeddingModel: String? = nil,
    localEmbeddingDimensions: Int? = nil,
    forceImportEmbeddings: Bool = false
  ) throws -> ImportResult {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
    let result = sqlite3_open_v2(dbPath, &db, flags, nil)
    guard result == SQLITE_OK, let db else {
      throw RAGStore.RAGError.sqlite("Cannot open database for import: \(result)")
    }
    defer { sqlite3_close(db) }

    // Enable WAL and busy timeout
    execSQL(db, "PRAGMA journal_mode=WAL")
    execSQL(db, "PRAGMA busy_timeout=5000")

    // Ensure the target DB has all columns needed for import.
    // The main RAGStore.ensureSchema() may not have run on this connection.
    ensureSyncSchema(db)

    var filesImported = 0
    var filesSkipped = 0
    var chunksImported = 0
    var embeddingsImported = 0
    var embeddingsSkippedModelMismatch = 0
    var chunksAnalysisUpdated = 0
    var embeddingsBackfilled = 0
    var filesPruned = 0

    // Check embedding model compatibility: if the bundle has a different
    // embedding model or dimension than the local DB, skip embedding import
    // to avoid mixing incompatible vectors. Text/chunks/AI summaries are
    // still imported so text search works; the receiver can re-embed locally.
    //
    // When forceImportEmbeddings is true, always import (useful when the
    // receiver won't index locally and wants to use the sender's vectors).
    let embeddingsCompatible: Bool
    if forceImportEmbeddings {
      embeddingsCompatible = true
    } else if let localModel = localEmbeddingModel,
              let localDims = localEmbeddingDimensions {
      let modelMatch = bundle.manifest.embeddingModel == localModel
      let dimsMatch = bundle.manifest.embeddingDimensions == localDims
      embeddingsCompatible = modelMatch && dimsMatch
    } else {
      // No local model info provided — assume compatible (legacy callers)
      embeddingsCompatible = true
    }

    execSQL(db, "BEGIN TRANSACTION")

    do {
      // Step 1: Upsert repo row
      let targetRepoId: String
      let targetRootPath = localRepoPath ?? bundle.repo.rootPath

      if let existingId = findRepoByIdentifier(db: db, identifier: bundle.manifest.repoIdentifier) {
        // Update existing repo
        targetRepoId = existingId
        let updateSql = "UPDATE repos SET last_indexed_at = ?, root_path = ?, embedding_model = ?, embedding_dimensions = ? WHERE id = ?"
        try execBind(db, updateSql) { stmt in
          bindTextOrNull(stmt, 1, bundle.repo.lastIndexedAt)
          bindText(stmt, 2, targetRootPath)
          bindTextOrNull(stmt, 3, bundle.manifest.embeddingModel)
          bindIntOrNull(stmt, 4, bundle.manifest.embeddingDimensions)
          bindText(stmt, 5, existingId)
        }
      } else {
        // Insert new repo — use local path-based ID for consistency
        targetRepoId = stableId(for: targetRootPath)
        let insertSql = """
          INSERT INTO repos (id, name, root_path, last_indexed_at, repo_identifier, parent_repo_id, embedding_model, embedding_dimensions)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """
        try execBind(db, insertSql) { stmt in
          bindText(stmt, 1, targetRepoId)
          bindText(stmt, 2, bundle.repo.name)
          bindText(stmt, 3, targetRootPath)
          bindTextOrNull(stmt, 4, bundle.repo.lastIndexedAt)
          bindText(stmt, 5, bundle.manifest.repoIdentifier)
          bindTextOrNull(stmt, 6, bundle.repo.parentRepoId)
          bindTextOrNull(stmt, 7, bundle.manifest.embeddingModel)
          bindIntOrNull(stmt, 8, bundle.manifest.embeddingDimensions)
        }
      }

      // Step 2: Import files, comparing hashes for delta
      for file in bundle.files {
        let existingHash = queryFileHash(db: db, repoId: targetRepoId, path: file.path)
        if existingHash == file.hash {
          // File content unchanged — but incoming bundle may have newer analysis data
          // or embeddings that the local DB lacks (e.g., analysis done on remote after initial sync).
          let updates = try updateAnalysisForExistingFile(
            db: db,
            repoId: targetRepoId,
            file: file,
            embeddingsCompatible: embeddingsCompatible
          )
          chunksAnalysisUpdated += updates.analysisCount
          embeddingsBackfilled += updates.embeddingsCount
          filesSkipped += 1
          continue
        }

        // Delete old file data if it exists (different hash = changed file)
        if existingHash != nil {
          deleteFileData(db: db, repoId: targetRepoId, path: file.path)
        }

        // Generate a stable file ID based on repo + path
        let fileId = stableId(for: "\(targetRepoId):\(file.path)")

        // Insert file
        let fileSql = """
          INSERT OR REPLACE INTO files (id, repo_id, path, hash, language, updated_at,
                                        module_path, feature_tags, line_count, method_count, byte_size)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """
        try execBind(db, fileSql) { stmt in
          bindText(stmt, 1, fileId)
          bindText(stmt, 2, targetRepoId)
          bindText(stmt, 3, file.path)
          bindText(stmt, 4, file.hash)
          bindTextOrNull(stmt, 5, file.language)
          bindTextOrNull(stmt, 6, file.updatedAt)
          bindTextOrNull(stmt, 7, file.modulePath)
          bindTextOrNull(stmt, 8, file.featureTags)
          sqlite3_bind_int(stmt, 9, Int32(file.lineCount))
          sqlite3_bind_int(stmt, 10, Int32(file.methodCount))
          sqlite3_bind_int(stmt, 11, Int32(file.byteSize))
        }

        // Insert chunks and embeddings
        for chunk in file.chunks {
          // Generate stable chunk ID
          let chunkId = stableId(for: "\(fileId):\(chunk.startLine)-\(chunk.endLine)")

          let chunkSql = """
            INSERT OR REPLACE INTO chunks (id, file_id, start_line, end_line, text, token_count,
                                           construct_type, construct_name, metadata,
                                           ai_summary, ai_tags, analyzed_at, analyzer_model, enriched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
          try execBind(db, chunkSql) { stmt in
            bindText(stmt, 1, chunkId)
            bindText(stmt, 2, fileId)
            sqlite3_bind_int(stmt, 3, Int32(chunk.startLine))
            sqlite3_bind_int(stmt, 4, Int32(chunk.endLine))
            bindText(stmt, 5, chunk.text)
            sqlite3_bind_int(stmt, 6, Int32(chunk.tokenCount))
            bindTextOrNull(stmt, 7, chunk.constructType)
            bindTextOrNull(stmt, 8, chunk.constructName)
            bindTextOrNull(stmt, 9, chunk.metadata)
            bindTextOrNull(stmt, 10, chunk.aiSummary)
            bindTextOrNull(stmt, 11, chunk.aiTags)
            bindTextOrNull(stmt, 12, chunk.analyzedAt)
            bindTextOrNull(stmt, 13, chunk.analyzerModel)
            bindTextOrNull(stmt, 14, chunk.enrichedAt)
          }
          chunksImported += 1

          // Insert embedding if present and models are compatible
          if let embeddingBase64 = chunk.embeddingBase64,
             let embeddingData = Data(base64Encoded: embeddingBase64) {
            if embeddingsCompatible {
              let embSql = "INSERT OR REPLACE INTO embeddings (chunk_id, embedding) VALUES (?, ?)"
              try execBind(db, embSql) { stmt in
                bindText(stmt, 1, chunkId)
                sqlite3_bind_blob(stmt, 2, (embeddingData as NSData).bytes, Int32(embeddingData.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
              }
              embeddingsImported += 1
            } else {
              embeddingsSkippedModelMismatch += 1
            }
          }
        }

        filesImported += 1
      }

      // Step 3: Prune local files not present in the sender's primary repo manifest.
      // The bundle.files contains only files for the primary repo. Any local file
      // not in the primary file set was deleted on the sender and should be removed here.
      // Safety: skip pruning if no file hashes (empty manifest = bug or partial export).
      // NOTE: Use only primary repo file paths, not the full manifest which may include sub-packages.
      // If the sender skipped some files (delta sync), also include paths from manifest fileHashes
      // that belong to the primary repo (those with matching fileIds from the primary's export).
      let fullPrimaryPaths: Set<String> = {
        // The manifest.fileHashes may include sub-package hashes. Extract only primary repo hashes:
        // Primary repo files are those NOT in any sub-package's fileHashes.
        let subPkgFileIds = Set((bundle.subPackages ?? []).flatMap { $0.fileHashes.map(\.fileId) })
        let primaryHashes = bundle.manifest.fileHashes.filter { !subPkgFileIds.contains($0.fileId) }
        return Set(primaryHashes.map(\.path))
      }()

      if !fullPrimaryPaths.isEmpty {
        let queryPathsSql = "SELECT path FROM files WHERE repo_id = ?"
        var pathsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, queryPathsSql, -1, &pathsStmt, nil) == SQLITE_OK,
           let pathsStmt {
          let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
          sqlite3_bind_text(pathsStmt, 1, targetRepoId, -1, transient)
          var stalePaths: [String] = []
          while sqlite3_step(pathsStmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(pathsStmt, 0) {
              let path = String(cString: text)
              if !fullPrimaryPaths.contains(path) {
                stalePaths.append(path)
              }
            }
          }
          sqlite3_finalize(pathsStmt)

          for stalePath in stalePaths {
            deleteFileData(db: db, repoId: targetRepoId, path: stalePath)
            filesPruned += 1
          }
        }
      }

      // Step 4: Import sub-packages (if present)
      for subPkg in bundle.subPackages ?? [] {
        let subTargetRepoId: String
        let subTargetRootPath: String
        if let localRepoPath, !subPkg.repo.rootPath.isEmpty {
          // Remap: the sub-package's rootPath is relative to the main repo's rootPath
          // e.g., sender: /Users/bender/code/peel/Local Packages/Git
          //        local:  /Users/me/code/peel/Local Packages/Git
          let senderMainRoot = bundle.repo.rootPath
          if subPkg.repo.rootPath.hasPrefix(senderMainRoot) {
            let suffix = String(subPkg.repo.rootPath.dropFirst(senderMainRoot.count))
            subTargetRootPath = localRepoPath + suffix
          } else {
            subTargetRootPath = subPkg.repo.rootPath
          }
        } else {
          subTargetRootPath = subPkg.repo.rootPath
        }

        if let existingId = findRepoByIdentifier(db: db, identifier: subPkg.repo.repoIdentifier) {
          subTargetRepoId = existingId
          let updateSql = "UPDATE repos SET last_indexed_at = ?, root_path = ?, embedding_model = ?, embedding_dimensions = ?, parent_repo_id = ? WHERE id = ?"
          try execBind(db, updateSql) { stmt in
            bindTextOrNull(stmt, 1, subPkg.repo.lastIndexedAt)
            bindText(stmt, 2, subTargetRootPath)
            bindTextOrNull(stmt, 3, subPkg.repo.embeddingModel)
            bindIntOrNull(stmt, 4, subPkg.repo.embeddingDimensions)
            bindText(stmt, 5, targetRepoId) // parent is the primary repo
            bindText(stmt, 6, existingId)
          }
        } else {
          subTargetRepoId = stableId(for: subTargetRootPath)
          let insertSql = """
            INSERT INTO repos (id, name, root_path, last_indexed_at, repo_identifier, parent_repo_id, embedding_model, embedding_dimensions)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
          try execBind(db, insertSql) { stmt in
            bindText(stmt, 1, subTargetRepoId)
            bindText(stmt, 2, subPkg.repo.name)
            bindText(stmt, 3, subTargetRootPath)
            bindTextOrNull(stmt, 4, subPkg.repo.lastIndexedAt)
            bindText(stmt, 5, subPkg.repo.repoIdentifier)
            bindText(stmt, 6, targetRepoId) // parent is the primary repo
            bindTextOrNull(stmt, 7, subPkg.repo.embeddingModel)
            bindIntOrNull(stmt, 8, subPkg.repo.embeddingDimensions)
          }
        }

        // Import sub-package files
        for file in subPkg.files {
          let existingHash = queryFileHash(db: db, repoId: subTargetRepoId, path: file.path)
          if existingHash == file.hash {
            let updates = try updateAnalysisForExistingFile(
              db: db, repoId: subTargetRepoId, file: file, embeddingsCompatible: embeddingsCompatible
            )
            chunksAnalysisUpdated += updates.analysisCount
            embeddingsBackfilled += updates.embeddingsCount
            filesSkipped += 1
            continue
          }
          if existingHash != nil {
            deleteFileData(db: db, repoId: subTargetRepoId, path: file.path)
          }

          let fileId = stableId(for: "\(subTargetRepoId):\(file.path)")
          let fileSql = """
            INSERT OR REPLACE INTO files (id, repo_id, path, hash, language, updated_at,
                                          module_path, feature_tags, line_count, method_count, byte_size)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
          try execBind(db, fileSql) { stmt in
            bindText(stmt, 1, fileId)
            bindText(stmt, 2, subTargetRepoId)
            bindText(stmt, 3, file.path)
            bindText(stmt, 4, file.hash)
            bindTextOrNull(stmt, 5, file.language)
            bindTextOrNull(stmt, 6, file.updatedAt)
            bindTextOrNull(stmt, 7, file.modulePath)
            bindTextOrNull(stmt, 8, file.featureTags)
            sqlite3_bind_int(stmt, 9, Int32(file.lineCount))
            sqlite3_bind_int(stmt, 10, Int32(file.methodCount))
            sqlite3_bind_int(stmt, 11, Int32(file.byteSize))
          }

          for chunk in file.chunks {
            let chunkId = stableId(for: "\(fileId):\(chunk.startLine)-\(chunk.endLine)")
            let chunkSql = """
              INSERT OR REPLACE INTO chunks (id, file_id, start_line, end_line, text, token_count,
                                             construct_type, construct_name, metadata,
                                             ai_summary, ai_tags, analyzed_at, analyzer_model, enriched_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              """
            try execBind(db, chunkSql) { stmt in
              bindText(stmt, 1, chunkId)
              bindText(stmt, 2, fileId)
              sqlite3_bind_int(stmt, 3, Int32(chunk.startLine))
              sqlite3_bind_int(stmt, 4, Int32(chunk.endLine))
              bindText(stmt, 5, chunk.text)
              sqlite3_bind_int(stmt, 6, Int32(chunk.tokenCount))
              bindTextOrNull(stmt, 7, chunk.constructType)
              bindTextOrNull(stmt, 8, chunk.constructName)
              bindTextOrNull(stmt, 9, chunk.metadata)
              bindTextOrNull(stmt, 10, chunk.aiSummary)
              bindTextOrNull(stmt, 11, chunk.aiTags)
              bindTextOrNull(stmt, 12, chunk.analyzedAt)
              bindTextOrNull(stmt, 13, chunk.analyzerModel)
              bindTextOrNull(stmt, 14, chunk.enrichedAt)
            }
            chunksImported += 1

            if let embeddingBase64 = chunk.embeddingBase64,
               let embeddingData = Data(base64Encoded: embeddingBase64) {
              if embeddingsCompatible {
                let embSql = "INSERT OR REPLACE INTO embeddings (chunk_id, embedding) VALUES (?, ?)"
                try execBind(db, embSql) { stmt in
                  bindText(stmt, 1, chunkId)
                  sqlite3_bind_blob(stmt, 2, (embeddingData as NSData).bytes, Int32(embeddingData.count),
                                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                embeddingsImported += 1
              } else {
                embeddingsSkippedModelMismatch += 1
              }
            }
          }
          filesImported += 1
        }

        // Prune stale files in sub-package
        let subManifestPaths = Set(subPkg.fileHashes.map(\.path))
        if !subManifestPaths.isEmpty {
          let queryPathsSql = "SELECT path FROM files WHERE repo_id = ?"
          var pathsStmt: OpaquePointer?
          if sqlite3_prepare_v2(db, queryPathsSql, -1, &pathsStmt, nil) == SQLITE_OK,
             let pathsStmt {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(pathsStmt, 1, subTargetRepoId, -1, transient)
            var stalePaths: [String] = []
            while sqlite3_step(pathsStmt) == SQLITE_ROW {
              if let text = sqlite3_column_text(pathsStmt, 0) {
                let path = String(cString: text)
                if !subManifestPaths.contains(path) { stalePaths.append(path) }
              }
            }
            sqlite3_finalize(pathsStmt)
            for stalePath in stalePaths {
              deleteFileData(db: db, repoId: subTargetRepoId, path: stalePath)
              filesPruned += 1
            }
          }
        }
      }

      execSQL(db, "COMMIT")
    } catch {
      execSQL(db, "ROLLBACK")
      throw error
    }

    return ImportResult(
      repoIdentifier: bundle.manifest.repoIdentifier,
      repoName: bundle.manifest.repoName,
      filesImported: filesImported,
      filesSkipped: filesSkipped,
      chunksImported: chunksImported,
      embeddingsImported: embeddingsImported,
      embeddingsSkippedModelMismatch: embeddingsSkippedModelMismatch,
      chunksAnalysisUpdated: chunksAnalysisUpdated,
      embeddingsBackfilled: embeddingsBackfilled,
      filesPruned: filesPruned,
      remoteEmbeddingModel: bundle.manifest.embeddingModel,
      remoteEmbeddingDimensions: bundle.manifest.embeddingDimensions
    )
  }

  /// Compare a remote manifest against local state to determine which files need syncing.
  /// - Returns: Set of file hashes the local DB already has for this repo
  static func localFileHashes(
    dbPath: String,
    repoIdentifier: String
  ) throws -> Set<String> {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    let result = sqlite3_open_v2(dbPath, &db, flags, nil)
    guard result == SQLITE_OK, let db else {
      return []
    }
    defer { sqlite3_close(db) }

    guard let repoId = findRepoByIdentifier(db: db, identifier: repoIdentifier) else {
      return [] // Repo not locally indexed — need everything
    }

    let sql = "SELECT hash FROM files WHERE repo_id = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, repoId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

    var hashes = Set<String>()
    while sqlite3_step(stmt) == SQLITE_ROW {
      if let text = sqlite3_column_text(stmt, 0) {
        hashes.insert(String(cString: text))
      }
    }
    return hashes
  }

  // MARK: - Overlay Import

  /// Import an overlay bundle onto locally-indexed chunks.
  /// Matches by file hash + chunk line range, then writes embeddings and analysis.
  /// The receiver must have already indexed the repo locally (chunks exist with matching hashes/lines).
  ///
  /// - Parameters:
  ///   - bundle: The overlay data (embeddings + analysis, no chunk text)
  ///   - dbPath: Path to the local rag.sqlite
  /// - Returns: Overlay import summary
  @discardableResult
  static func importRepoOverlay(
    bundle: RAGRepoOverlayBundle,
    dbPath: String
  ) throws -> OverlayImportResult {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
    let result = sqlite3_open_v2(dbPath, &db, flags, nil)
    guard result == SQLITE_OK, let db else {
      throw RAGStore.RAGError.sqlite("Cannot open database for overlay import: \(result)")
    }
    defer { sqlite3_close(db) }

    execSQL(db, "PRAGMA journal_mode=WAL")
    execSQL(db, "PRAGMA busy_timeout=5000")
    ensureSyncSchema(db)

    guard let repoId = findRepoByIdentifier(db: db, identifier: bundle.manifest.repoIdentifier) else {
      return OverlayImportResult(
        repoIdentifier: bundle.manifest.repoIdentifier,
        repoName: bundle.manifest.repoName,
        filesMatched: 0, filesUnmatched: 0,
        embeddingsApplied: 0, embeddingsReplaced: 0,
        embeddingsSkippedModelMismatch: 0,
        analysisApplied: 0, chunksUnmatched: 0,
        remoteEmbeddingModel: bundle.manifest.embeddingModel,
        remoteEmbeddingDimensions: bundle.manifest.embeddingDimensions,
        localEmbeddingModel: nil,
        localEmbeddingDimensions: nil,
        error: "Repo not locally indexed — run local index first"
      )
    }

    // Read the local repo's current embedding model to detect mismatches.
    // If the local repo already has embeddings from a different model (e.g. Qwen3 from swarm),
    // we skip embedding replacement and only apply analysis data.
    var localModel: String?
    var localDims: Int?
    let readModelSql = "SELECT embedding_model, embedding_dimensions FROM repos WHERE id = ?"
    var readStmt: OpaquePointer?
    if sqlite3_prepare_v2(db, readModelSql, -1, &readStmt, nil) == SQLITE_OK, let readStmt {
      sqlite3_bind_text(readStmt, 1, repoId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      if sqlite3_step(readStmt) == SQLITE_ROW {
        if let text = sqlite3_column_text(readStmt, 0) {
          localModel = String(cString: text)
        }
        let dims = sqlite3_column_int(readStmt, 1)
        if dims > 0 { localDims = Int(dims) }
      }
      sqlite3_finalize(readStmt)
    }

    let remoteModel = bundle.manifest.embeddingModel
    let remoteDims = bundle.manifest.embeddingDimensions

    // Embeddings are compatible if: (a) local has no model yet (first overlay), or
    // (b) models and dimensions match. Mismatch → analysis-only overlay.
    let embeddingsCompatible: Bool
    if let localModel, let localDims {
      embeddingsCompatible = (localModel == remoteModel && localDims == remoteDims)
    } else {
      // No local model recorded → accept the remote embeddings (first time)
      embeddingsCompatible = true
    }

    // Only update repo model/dimensions if we'll actually write embeddings
    if embeddingsCompatible {
      let updateRepoSql = "UPDATE repos SET embedding_model = ?, embedding_dimensions = ? WHERE id = ?"
      try execBind(db, updateRepoSql) { stmt in
        bindText(stmt, 1, remoteModel)
        sqlite3_bind_int(stmt, 2, Int32(remoteDims))
        bindText(stmt, 3, repoId)
      }
    }

    var filesMatched = 0
    var filesUnmatched = 0
    var embeddingsApplied = 0
    var embeddingsReplaced = 0
    var embeddingsSkippedModelMismatch = 0
    var analysisApplied = 0
    var chunksUnmatched = 0

    execSQL(db, "BEGIN TRANSACTION")

    do {
      for file in bundle.files {
        // Find the local file by repo + hash
        let localFileId = findFileByHash(db: db, repoId: repoId, hash: file.hash)
        guard let fileId = localFileId else {
          filesUnmatched += 1
          continue
        }
        filesMatched += 1

        for chunk in file.chunks {
          // Match local chunk by file ID + line range
          let chunkId = findChunkByLineRange(
            db: db, fileId: fileId,
            startLine: chunk.startLine, endLine: chunk.endLine
          )
          guard let chunkId else {
            chunksUnmatched += 1
            continue
          }

          // Apply embedding only if models are compatible.
          // When models differ (e.g. local has Qwen3 1024d from swarm, overlay has nomic 768d),
          // we skip embedding writes to avoid downgrading vector quality.
          if let embeddingBase64 = chunk.embeddingBase64,
             let embeddingData = Data(base64Encoded: embeddingBase64) {
            if embeddingsCompatible {
              // Check if embedding already exists
              let existsSQL = "SELECT COUNT(*) FROM embeddings WHERE chunk_id = ?"
              var existsStmt: OpaquePointer?
              var existed = false
              if sqlite3_prepare_v2(db, existsSQL, -1, &existsStmt, nil) == SQLITE_OK,
                 let existsStmt {
                sqlite3_bind_text(existsStmt, 1, chunkId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if sqlite3_step(existsStmt) == SQLITE_ROW {
                  existed = sqlite3_column_int(existsStmt, 0) > 0
                }
                sqlite3_finalize(existsStmt)
              }

              let embSql = "INSERT OR REPLACE INTO embeddings (chunk_id, embedding) VALUES (?, ?)"
              try execBind(db, embSql) { stmt in
                bindText(stmt, 1, chunkId)
                sqlite3_bind_blob(stmt, 2, (embeddingData as NSData).bytes, Int32(embeddingData.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
              }
              if existed {
                embeddingsReplaced += 1
              }
              embeddingsApplied += 1
            } else {
              embeddingsSkippedModelMismatch += 1
            }
          }

          // Apply analysis (only if incoming has analysis and it's newer or local lacks it)
          if chunk.analyzedAt != nil {
            let updateSql = """
              UPDATE chunks SET
                ai_summary = ?, ai_tags = ?, analyzed_at = ?, analyzer_model = ?, enriched_at = ?
              WHERE id = ? AND (analyzed_at IS NULL OR analyzed_at < ?)
              """
            try execBind(db, updateSql) { stmt in
              bindTextOrNull(stmt, 1, chunk.aiSummary)
              bindTextOrNull(stmt, 2, chunk.aiTags)
              bindTextOrNull(stmt, 3, chunk.analyzedAt)
              bindTextOrNull(stmt, 4, chunk.analyzerModel)
              bindTextOrNull(stmt, 5, chunk.enrichedAt)
              bindText(stmt, 6, chunkId)
              bindTextOrNull(stmt, 7, chunk.analyzedAt)
            }
            if sqlite3_changes(db) > 0 {
              analysisApplied += 1
            }
          }
        }
      }

      execSQL(db, "COMMIT")
    } catch {
      execSQL(db, "ROLLBACK")
      throw error
    }

    return OverlayImportResult(
      repoIdentifier: bundle.manifest.repoIdentifier,
      repoName: bundle.manifest.repoName,
      filesMatched: filesMatched,
      filesUnmatched: filesUnmatched,
      embeddingsApplied: embeddingsApplied,
      embeddingsReplaced: embeddingsReplaced,
      embeddingsSkippedModelMismatch: embeddingsSkippedModelMismatch,
      analysisApplied: analysisApplied,
      chunksUnmatched: chunksUnmatched,
      remoteEmbeddingModel: bundle.manifest.embeddingModel,
      remoteEmbeddingDimensions: bundle.manifest.embeddingDimensions,
      localEmbeddingModel: localModel,
      localEmbeddingDimensions: localDims,
      error: nil
    )
  }

  /// Find a file in the local DB by repo ID and content hash.
  private static func findFileByHash(db: OpaquePointer, repoId: String, hash: String) -> String? {
    let sql = "SELECT id FROM files WHERE repo_id = ? AND hash = ? LIMIT 1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, repoId, -1, transient)
    sqlite3_bind_text(stmt, 2, hash, -1, transient)

    guard sqlite3_step(stmt) == SQLITE_ROW,
          let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
  }

  /// Find a chunk by file ID and line range.
  private static func findChunkByLineRange(
    db: OpaquePointer, fileId: String,
    startLine: Int, endLine: Int
  ) -> String? {
    let sql = "SELECT id FROM chunks WHERE file_id = ? AND start_line = ? AND end_line = ? LIMIT 1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, fileId, -1, transient)
    sqlite3_bind_int(stmt, 2, Int32(startLine))
    sqlite3_bind_int(stmt, 3, Int32(endLine))

    guard sqlite3_step(stmt) == SQLITE_ROW,
          let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
  }

  // MARK: - Overlay Result Type

  public struct OverlayImportResult: Sendable {
    let repoIdentifier: String
    let repoName: String
    /// Files from the overlay that matched locally-indexed files by hash.
    let filesMatched: Int
    /// Files from the overlay with no matching local file (file changed or not indexed).
    let filesUnmatched: Int
    /// Embeddings written (new or replaced).
    let embeddingsApplied: Int
    /// Of embeddingsApplied, how many replaced existing local embeddings.
    let embeddingsReplaced: Int
    /// Embeddings skipped because the local repo already has a different model's embeddings.
    let embeddingsSkippedModelMismatch: Int
    /// Analysis fields updated on locally-indexed chunks.
    let analysisApplied: Int
    /// Chunks from the overlay with no matching local chunk (different chunking).
    let chunksUnmatched: Int
    /// The embedding model used by the sender.
    let remoteEmbeddingModel: String?
    /// The embedding dimensions used by the sender.
    let remoteEmbeddingDimensions: Int?
    /// The local repo's current embedding model (for mismatch diagnostics).
    let localEmbeddingModel: String?
    /// The local repo's current embedding dimensions.
    let localEmbeddingDimensions: Int?
    /// Error if the repo is not locally indexed.
    let error: String?

    var isSuccess: Bool { error == nil }
    var totalOverlayEntries: Int { embeddingsApplied + analysisApplied }
    var hadModelMismatch: Bool { embeddingsSkippedModelMismatch > 0 }
  }

  // MARK: - Result Type

  public struct ImportResult: Sendable {
    let repoIdentifier: String
    let repoName: String
    let filesImported: Int
    let filesSkipped: Int
    let chunksImported: Int
    let embeddingsImported: Int
    /// Number of embeddings skipped because the remote model differs from local.
    let embeddingsSkippedModelMismatch: Int
    /// Number of chunks whose analysis fields (ai_summary, etc.) were updated from incoming data.
    let chunksAnalysisUpdated: Int
    /// Number of embeddings backfilled on existing (hash-matched) files.
    let embeddingsBackfilled: Int
    /// Number of local files pruned because they no longer exist on the sender.
    let filesPruned: Int
    /// The embedding model used by the sender.
    let remoteEmbeddingModel: String?
    /// The embedding dimensions used by the sender.
    let remoteEmbeddingDimensions: Int?

    var totalFiles: Int { filesImported + filesSkipped }
    var isDelta: Bool { filesSkipped > 0 }
    /// True if embeddings were skipped due to model mismatch. Receiver should re-embed locally.
    var needsLocalReembedding: Bool { embeddingsSkippedModelMismatch > 0 }
    /// True if analysis data was synced for already-imported files.
    var hadAnalysisUpdates: Bool { chunksAnalysisUpdated > 0 }
    /// True if stale files were pruned during this sync.
    var hadPruning: Bool { filesPruned > 0 }
  }

  // MARK: - Private Helpers

  /// Ensure the target database has all columns needed for sync import.
  /// This handles the case where the target DB was created by an older version
  /// of RAGStore and hasn't had migrations run via ensureSchema().
  private static func ensureSyncSchema(_ db: OpaquePointer) {
    // v6 columns on chunks
    if !columnExists(db, table: "chunks", column: "ai_summary") {
      execSQL(db, "ALTER TABLE chunks ADD COLUMN ai_summary TEXT")
    }
    if !columnExists(db, table: "chunks", column: "ai_tags") {
      execSQL(db, "ALTER TABLE chunks ADD COLUMN ai_tags TEXT")
    }
    if !columnExists(db, table: "chunks", column: "analyzed_at") {
      execSQL(db, "ALTER TABLE chunks ADD COLUMN analyzed_at TEXT")
    }
    if !columnExists(db, table: "chunks", column: "analyzer_model") {
      execSQL(db, "ALTER TABLE chunks ADD COLUMN analyzer_model TEXT")
    }
    // v7 columns on files
    if !columnExists(db, table: "files", column: "module_path") {
      execSQL(db, "ALTER TABLE files ADD COLUMN module_path TEXT")
    }
    if !columnExists(db, table: "files", column: "feature_tags") {
      execSQL(db, "ALTER TABLE files ADD COLUMN feature_tags TEXT")
    }
    // v8 column on chunks
    if !columnExists(db, table: "chunks", column: "enriched_at") {
      execSQL(db, "ALTER TABLE chunks ADD COLUMN enriched_at TEXT")
    }
    // v11 column on repos
    if !columnExists(db, table: "repos", column: "repo_identifier") {
      execSQL(db, "ALTER TABLE repos ADD COLUMN repo_identifier TEXT")
    }
    // v12 column on repos
    if !columnExists(db, table: "repos", column: "parent_repo_id") {
      execSQL(db, "ALTER TABLE repos ADD COLUMN parent_repo_id TEXT")
    }
    // v14 columns on repos
    if !columnExists(db, table: "repos", column: "embedding_model") {
      execSQL(db, "ALTER TABLE repos ADD COLUMN embedding_model TEXT")
    }
    if !columnExists(db, table: "repos", column: "embedding_dimensions") {
      execSQL(db, "ALTER TABLE repos ADD COLUMN embedding_dimensions INTEGER")
    }
    // v13 columns on files
    if !columnExists(db, table: "files", column: "line_count") {
      execSQL(db, "ALTER TABLE files ADD COLUMN line_count INTEGER DEFAULT 0")
    }
    if !columnExists(db, table: "files", column: "method_count") {
      execSQL(db, "ALTER TABLE files ADD COLUMN method_count INTEGER DEFAULT 0")
    }
    if !columnExists(db, table: "files", column: "byte_size") {
      execSQL(db, "ALTER TABLE files ADD COLUMN byte_size INTEGER DEFAULT 0")
    }
  }

  /// Check if a column exists in a table.
  private static func columnExists(_ db: OpaquePointer, table: String, column: String) -> Bool {
    let sql = "PRAGMA table_info(\(table))"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW {
      if let name = sqlite3_column_text(stmt, 1) {
        if String(cString: name) == column { return true }
      }
    }
    return false
  }

  private static func findRepoByIdentifier(db: OpaquePointer, identifier: String) -> String? {
    RAGRepoExporter.selectBestRepoCandidate(
      RAGRepoExporter.queryRepoCandidates(db: db, repoIdentifier: identifier)
    )?.repo.id
  }

  private static func queryFileHash(db: OpaquePointer, repoId: String, path: String) -> String? {
    let sql = "SELECT hash FROM files WHERE repo_id = ? AND path = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, repoId, -1, transient)
    sqlite3_bind_text(stmt, 2, path, -1, transient)

    guard sqlite3_step(stmt) == SQLITE_ROW,
          let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
  }

  private static func deleteFileData(db: OpaquePointer, repoId: String, path: String) {
    // Find the file ID
    let sql = "SELECT id FROM files WHERE repo_id = ? AND path = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
    defer { sqlite3_finalize(stmt) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, repoId, -1, transient)
    sqlite3_bind_text(stmt, 2, path, -1, transient)

    guard sqlite3_step(stmt) == SQLITE_ROW,
          let text = sqlite3_column_text(stmt, 0) else { return }
    let fileId = String(cString: text)

    // Delete embeddings, chunks, then file
    execSQL(db, "DELETE FROM embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE file_id = '\(fileId.replacingOccurrences(of: "'", with: "''"))')")
    execSQL(db, "DELETE FROM chunks WHERE file_id = '\(fileId.replacingOccurrences(of: "'", with: "''"))'")
    execSQL(db, "DELETE FROM files WHERE id = '\(fileId.replacingOccurrences(of: "'", with: "''"))'")
  }

  /// Update analysis fields and backfill embeddings for an existing file whose hash hasn't changed.
  /// This handles the case where a file was imported in a prior sync without analysis data,
  /// and the sender has since analyzed those chunks.
  private static func updateAnalysisForExistingFile(
    db: OpaquePointer,
    repoId: String,
    file: ExportedFile,
    embeddingsCompatible: Bool
  ) throws -> (analysisCount: Int, embeddingsCount: Int) {
    let fileId = stableId(for: "\(repoId):\(file.path)")
    var analysisCount = 0
    var embeddingsCount = 0

    for chunk in file.chunks {
      let chunkId = stableId(for: "\(fileId):\(chunk.startLine)-\(chunk.endLine)")

      // Update analysis fields if incoming chunk has analysis and local doesn't (or is older)
      if chunk.analyzedAt != nil {
        let updateSql = """
          UPDATE chunks SET
            ai_summary = ?, ai_tags = ?, analyzed_at = ?, analyzer_model = ?, enriched_at = ?
          WHERE id = ? AND (analyzed_at IS NULL OR analyzed_at < ?)
          """
        try execBind(db, updateSql) { stmt in
          bindTextOrNull(stmt, 1, chunk.aiSummary)
          bindTextOrNull(stmt, 2, chunk.aiTags)
          bindTextOrNull(stmt, 3, chunk.analyzedAt)
          bindTextOrNull(stmt, 4, chunk.analyzerModel)
          bindTextOrNull(stmt, 5, chunk.enrichedAt)
          bindText(stmt, 6, chunkId)
          bindTextOrNull(stmt, 7, chunk.analyzedAt)
        }
        if sqlite3_changes(db) > 0 {
          analysisCount += 1
        }
      }

      // Backfill embedding if compatible and local chunk lacks one
      if let embeddingBase64 = chunk.embeddingBase64,
         let embeddingData = Data(base64Encoded: embeddingBase64),
         embeddingsCompatible {
        // INSERT OR IGNORE: only inserts if no embedding exists for this chunk
        let embSql = "INSERT OR IGNORE INTO embeddings (chunk_id, embedding) VALUES (?, ?)"
        try execBind(db, embSql) { stmt in
          bindText(stmt, 1, chunkId)
          sqlite3_bind_blob(stmt, 2, (embeddingData as NSData).bytes, Int32(embeddingData.count),
                            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        if sqlite3_changes(db) > 0 {
          embeddingsCount += 1
        }
      }
    }

    return (analysisCount, embeddingsCount)
  }

  private static func stableId(for input: String) -> String {
    let hash = SHA256.hash(data: Data(input.utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  @discardableResult
  private static func execSQL(_ db: OpaquePointer, _ sql: String) -> Bool {
    var errMsg: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
    if let errMsg { sqlite3_free(errMsg) }
    return result == SQLITE_OK
  }

  private static func execBind(_ db: OpaquePointer, _ sql: String, binder: (OpaquePointer) throws -> Void) throws {
    var stmt: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard result == SQLITE_OK, let stmt else {
      let message = String(cString: sqlite3_errmsg(db))
      throw RAGStore.RAGError.sqlite("Prepare failed: \(message)")
    }
    defer { sqlite3_finalize(stmt) }
    try binder(stmt)
    let stepResult = sqlite3_step(stmt)
    guard stepResult == SQLITE_DONE else {
      let message = String(cString: sqlite3_errmsg(db))
      throw RAGStore.RAGError.sqlite("Step failed: \(message)")
    }
  }

  private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
    sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1,
                      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }

  private static func bindTextOrNull(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
    if let value {
      bindText(stmt, index, value)
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  private static func bindIntOrNull(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
    if let value {
      sqlite3_bind_int(stmt, index, Int32(value))
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }
}

// MARK: - RAGStore Extension for Per-Repo Sync

extension RAGStore {

  /// Export a single repo by its identifier (git remote URL).
  /// Returns nil if the repo is not found.
  func exportRepo(
    identifier: String,
    excludeFileHashes: Set<String> = []
  ) async throws -> RAGRepoExportBundle? {
    let currentStatus = status()
    return try RAGRepoExporter.exportRepo(
      dbPath: currentStatus.dbPath,
      repoIdentifier: identifier,
      schemaVersion: currentStatus.schemaVersion,
      embeddingModel: currentStatus.embeddingModelName,
      embeddingDimensions: currentStatus.embeddingDimensions,
      excludeFileHashes: excludeFileHashes
    )
  }

  /// Build a sync manifest for delta negotiation (no data, just file hashes).
  func repoSyncManifest(identifier: String) async throws -> RAGRepoSyncManifest? {
    let currentStatus = status()
    return try RAGRepoExporter.buildManifest(
      dbPath: currentStatus.dbPath,
      repoIdentifier: identifier,
      schemaVersion: currentStatus.schemaVersion,
      embeddingModel: currentStatus.embeddingModelName,
      embeddingDimensions: currentStatus.embeddingDimensions
    )
  }

  /// Get the set of file hashes for a repo (for delta comparison).
  func localFileHashes(identifier: String) async throws -> Set<String> {
    try RAGRepoImporter.localFileHashes(
      dbPath: status().dbPath,
      repoIdentifier: identifier
    )
  }

  /// Import a per-repo bundle, merging into existing data.
  /// Call this when the DB is open — it opens a separate connection for the import.
  @discardableResult
  func importRepoBundle(
    _ bundle: RAGRepoExportBundle,
    localRepoPath: String? = nil,
    forceImportEmbeddings: Bool = false
  ) async throws -> RAGRepoImporter.ImportResult {
    let currentStatus = status()
    let dbPath = currentStatus.dbPath
    // Close our connection so the importer can write
    closeDatabase()

    let result: RAGRepoImporter.ImportResult
    do {
      result = try RAGRepoImporter.importRepo(
        bundle: bundle,
        dbPath: dbPath,
        localRepoPath: localRepoPath,
        localEmbeddingModel: currentStatus.embeddingModelName,
        localEmbeddingDimensions: currentStatus.embeddingDimensions,
        forceImportEmbeddings: forceImportEmbeddings
      )
    } catch {
      // Re-open db
      _ = try? initialize()
      throw error
    }

    // Re-open db
    _ = try initialize()
    return result
  }

  // MARK: - Overlay Sync

  /// Export an overlay bundle (embeddings + analysis only, no chunk text).
  func exportRepoOverlay(
    identifier: String,
    excludeFileHashes: Set<String> = []
  ) async throws -> RAGRepoOverlayBundle? {
    let currentStatus = status()
    return try RAGRepoExporter.exportRepoOverlay(
      dbPath: currentStatus.dbPath,
      repoIdentifier: identifier,
      schemaVersion: currentStatus.schemaVersion,
      embeddingModel: currentStatus.embeddingModelName,
      embeddingDimensions: currentStatus.embeddingDimensions,
      excludeFileHashes: excludeFileHashes
    )
  }

  /// Import an overlay bundle onto locally-indexed chunks.
  /// Call this when the DB is open — it opens a separate connection for the import.
  @discardableResult
  func importRepoOverlay(
    _ bundle: RAGRepoOverlayBundle
  ) async throws -> RAGRepoImporter.OverlayImportResult {
    let dbPath = status().dbPath
    closeDatabase()

    let result: RAGRepoImporter.OverlayImportResult
    do {
      result = try RAGRepoImporter.importRepoOverlay(
        bundle: bundle,
        dbPath: dbPath
      )
    } catch {
      _ = try? initialize()
      throw error
    }

    _ = try initialize()
    return result
  }
}
