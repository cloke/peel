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
struct RAGRepoExportBundle: Codable, Sendable {
  let manifest: RAGRepoSyncManifest
  let repo: ExportedRepo
  let files: [ExportedFile]

  var totalChunks: Int { files.reduce(0) { $0 + $1.chunks.count } }
  var totalEmbeddings: Int { files.reduce(0) { $0 + $1.chunks.filter { $0.embeddingBase64 != nil }.count } }
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

    // Find the repo by identifier
    guard let repo = queryRepo(db: db, repoIdentifier: repoIdentifier) else {
      return nil
    }

    // Query all files for this repo
    let allFileHashes = queryFileHashes(db: db, repoId: repo.id)

    // Build manifest
    let headSHA = gitHeadSHA(for: repo.rootPath)
    let effectiveEmbeddingModel = repo.embeddingModel ?? embeddingModel
    let effectiveEmbeddingDimensions = repo.embeddingDimensions ?? embeddingDimensions
    let manifest = RAGRepoSyncManifest(
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

    // Export files (skipping those the receiver already has)
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
      files: exportedFiles
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

    guard let repo = queryRepo(db: db, repoIdentifier: repoIdentifier) else {
      return nil
    }

    let fileHashes = queryFileHashes(db: db, repoId: repo.id)
    let headSHA = gitHeadSHA(for: repo.rootPath)

    let effectiveEmbeddingModel = repo.embeddingModel ?? embeddingModel
    let effectiveEmbeddingDimensions = repo.embeddingDimensions ?? embeddingDimensions

    return RAGRepoSyncManifest(
      repoIdentifier: repoIdentifier,
      repoName: repo.name,
      schemaVersion: schemaVersion,
      embeddingModel: effectiveEmbeddingModel,
      embeddingDimensions: effectiveEmbeddingDimensions,
      createdAt: Date(),
      headSHA: headSHA,
      fileCount: fileHashes.count,
      chunkCount: fileHashes.reduce(0) { $0 + $1.chunkCount },
      fileHashes: fileHashes
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

  private static func queryRepo(db: OpaquePointer, repoIdentifier: String) -> ExportedRepo? {
    // repo_identifier added in v11, parent_repo_id in v12 — adapt query for older schemas
    let hasRepoIdentifier = columnExists(db, table: "repos", column: "repo_identifier")
    let hasParentRepoId = columnExists(db, table: "repos", column: "parent_repo_id")
    let hasEmbeddingModel = columnExists(db, table: "repos", column: "embedding_model")
    let hasEmbeddingDimensions = columnExists(db, table: "repos", column: "embedding_dimensions")

    // If the source DB doesn't have repo_identifier column, we can't match by it
    guard hasRepoIdentifier else { return nil }

    var columns = "id, name, root_path, repo_identifier, last_indexed_at"
    if hasParentRepoId { columns += ", parent_repo_id" }
    if hasEmbeddingModel { columns += ", embedding_model" }
    if hasEmbeddingDimensions { columns += ", embedding_dimensions" }

    let sql = "SELECT \(columns) FROM repos WHERE repo_identifier = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, repoIdentifier, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

    let parentIndex: Int32 = hasParentRepoId ? 5 : -1
    let embeddingModelIndex: Int32 = hasEmbeddingModel ? (hasParentRepoId ? 6 : 5) : -1
    let embeddingDimensionsIndex: Int32 = hasEmbeddingDimensions ? (embeddingModelIndex >= 0 ? embeddingModelIndex + 1 : (hasParentRepoId ? 6 : 5)) : -1

    return ExportedRepo(
      id: columnString(stmt, 0),
      name: columnString(stmt, 1),
      rootPath: columnString(stmt, 2),
      repoIdentifier: columnString(stmt, 3),
      lastIndexedAt: columnOptionalString(stmt, 4),
      parentRepoId: parentIndex >= 0 ? columnOptionalString(stmt, parentIndex) : nil,
      embeddingModel: embeddingModelIndex >= 0 ? columnOptionalString(stmt, embeddingModelIndex) : nil,
      embeddingDimensions: embeddingDimensionsIndex >= 0 ? columnOptionalInt(stmt, embeddingDimensionsIndex) : nil
    )
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
    let sql = "SELECT id FROM repos WHERE repo_identifier = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, identifier, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

    guard sqlite3_step(stmt) == SQLITE_ROW,
          let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
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
}
