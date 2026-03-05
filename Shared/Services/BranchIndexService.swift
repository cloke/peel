//
//  BranchIndexService.swift
//  Peel
//
//  Utility methods for branch-aware RAG indexing.
//  Supports copy-on-branch strategy for fast worktree/feature-branch indexing.
//  Issue #260
//

import CSQLite
import CryptoKit
import Foundation

enum BranchIndexService {

  // MARK: - Git Helpers

  /// Returns the current branch name (e.g. "main", "feature/foo") for the given repo path.
  static func gitCurrentBranch(at path: String) -> String? {
    gitOutput(args: ["rev-parse", "--abbrev-ref", "HEAD"], repoPath: path)
  }

  /// Given a worktree path, returns the main worktree path by parsing `git worktree list --porcelain`.
  /// Returns nil if `worktreePath` is already the main worktree, or on failure.
  static func gitMainWorktreePath(from worktreePath: String) -> String? {
    guard let output = gitOutput(args: ["worktree", "list", "--porcelain"], repoPath: worktreePath) else {
      return nil
    }
    // First "worktree" line is the main worktree path.
    let lines = output.components(separatedBy: "\n")
    var firstWorktreePath: String?
    for line in lines {
      if line.hasPrefix("worktree ") {
        firstWorktreePath = String(line.dropFirst("worktree ".count))
        break
      }
    }
    guard let mainPath = firstWorktreePath else { return nil }
    // Don't return self
    let normalized = URL(fileURLWithPath: worktreePath).standardized.path
    let mainNormalized = URL(fileURLWithPath: mainPath).standardized.path
    if normalized == mainNormalized { return nil }
    return mainPath
  }

  /// Returns changed/added and deleted files between `baseBranch` and HEAD in the given repo.
  /// Uses `git diff <baseBranch>...HEAD --name-only` (three-dot diff).
  static func gitChangedFiles(repoPath: String, baseBranch: String) -> (changed: [String], deleted: [String]) {
    let allChanged = gitOutput(
      args: ["diff", "\(baseBranch)...HEAD", "--name-only"],
      repoPath: repoPath
    ) ?? ""
    let deleted = gitOutput(
      args: ["diff", "\(baseBranch)...HEAD", "--name-only", "--diff-filter=D"],
      repoPath: repoPath
    ) ?? ""

    func toList(_ raw: String) -> [String] {
      raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    return (changed: toList(allChanged), deleted: toList(deleted))
  }

  // MARK: - Stable ID

  /// SHA256 hex string for a value — matches the algorithm used in RAGCore's VectorMath.stableId.
  static func stableId(for value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Index Copy

  /// Copies the RAG index for `sourcePath` into `destPath` by remapping IDs directly in SQLite.
  /// Returns the number of files copied (0 if destPath already has an index or sourcePath isn't indexed).
  /// Does NOT touch the RAGStore actor — operates directly on the SQLite file.
  @discardableResult
  static func copyRepoIndex(from sourcePath: String, to destPath: String, dbURL: URL) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
      throw BranchIndexError.cannotOpenDatabase(dbURL.path)
    }
    defer { sqlite3_close(db) }

    // WAL mode + timeout
    sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
    sqlite3_exec(db, "PRAGMA busy_timeout=5000", nil, nil, nil)

    let sourceRepoId = stableId(for: sourcePath)
    let destRepoId = stableId(for: destPath)

    // Check if dest already has files indexed
    let destFileCount = queryInt(db, "SELECT COUNT(*) FROM files WHERE repo_id = ?", args: [destRepoId]) ?? 0
    if destFileCount > 0 { return 0 }

    // Check if source has any files
    let srcFileCount = queryInt(db, "SELECT COUNT(*) FROM files WHERE repo_id = ?", args: [sourceRepoId]) ?? 0
    if srcFileCount == 0 { return 0 }

    let destName = URL(fileURLWithPath: destPath).lastPathComponent

    // Begin transaction
    sqlite3_exec(db, "BEGIN", nil, nil, nil)
    var ok = true

    // Copy repo row
    let insertRepo = """
      INSERT OR IGNORE INTO repos (id, name, root_path, last_indexed_at, repo_identifier, parent_repo_id)
      SELECT ?, ?, ?, last_indexed_at, repo_identifier, parent_repo_id FROM repos WHERE id = ?
      """
    ok = ok && (exec(db, insertRepo, args: [destRepoId, destName, destPath, sourceRepoId]) == SQLITE_OK)

    // Fetch source files
    let srcFiles = queryRows(db, "SELECT id, path, hash, language, updated_at, line_count, method_count, byte_size FROM files WHERE repo_id = ?", args: [sourceRepoId])

    // file id mapping: srcFileId -> destFileId
    var fileIdMap = [String: String]()
    for row in srcFiles {
      guard let srcFileId = row[0] as? String,
            let relPath = row[1] as? String else { continue }
      let destFileId = stableId(for: destRepoId + ":" + relPath)
      fileIdMap[srcFileId] = destFileId

      let insertFile = """
        INSERT OR IGNORE INTO files (id, repo_id, path, hash, language, updated_at, line_count, method_count, byte_size)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
      let hash = row[2] ?? NSNull()
      let lang = row[3] ?? NSNull()
      let updAt = row[4] ?? NSNull()
      let lineCount = row[5] ?? NSNull()
      let methodCount = row[6] ?? NSNull()
      let byteSize = row[7] ?? NSNull()
      ok = ok && (exec(db, insertFile, args: [destFileId, destRepoId, relPath, hash, lang, updAt, lineCount, methodCount, byteSize]) == SQLITE_OK)
    }

    // Copy chunks and embeddings
    for (srcFileId, destFileId) in fileIdMap {
      let chunks = queryRows(db, "SELECT id, start_line, end_line, text, token_count, construct_type, construct_name, metadata FROM chunks WHERE file_id = ?", args: [srcFileId])
      for chunk in chunks {
        guard let srcChunkId = chunk[0] as? String,
              let startLine = chunk[1] as? Int64,
              let endLine = chunk[2] as? Int64,
              let text = chunk[3] as? String else { continue }
        let destChunkId = stableId(for: destFileId + ":" + "\(startLine):\(endLine):" + text)
        let tokenCount = chunk[4] ?? NSNull()
        let constructType = chunk[5] ?? NSNull()
        let constructName = chunk[6] ?? NSNull()
        let metadata = chunk[7] ?? NSNull()

        let insertChunk = """
          INSERT OR IGNORE INTO chunks (id, file_id, start_line, end_line, text, token_count, construct_type, construct_name, metadata)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """
        ok = ok && (exec(db, insertChunk, args: [destChunkId, destFileId, startLine, endLine, text, tokenCount, constructType, constructName, metadata]) == SQLITE_OK)

        // Copy embedding
        if let embData = queryBlob(db, "SELECT embedding FROM embeddings WHERE chunk_id = ?", args: [srcChunkId]) {
          let insertEmb = "INSERT OR IGNORE INTO embeddings (chunk_id, embedding) VALUES (?, ?)"
          ok = ok && (execWithBlob(db, insertEmb, textArg: destChunkId, blobArg: embData) == SQLITE_OK)
        }
      }
    }

    if ok {
      sqlite3_exec(db, "COMMIT", nil, nil, nil)
    } else {
      sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    }

    return ok ? srcFiles.count : 0
  }

  // MARK: - Cleanup

  /// Removes RAG index entries for repo paths no longer present on disk (excluding activeRepoPaths).
  /// Returns count of deleted repos.
  static func cleanupStaleIndexes(retaining activeRepoPaths: [String], dbURL: URL) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
      throw BranchIndexError.cannotOpenDatabase(dbURL.path)
    }
    defer { sqlite3_close(db) }

    sqlite3_exec(db, "PRAGMA busy_timeout=5000", nil, nil, nil)

    let allRepos = queryRows(db, "SELECT id, root_path FROM repos", args: [])
    var removed = 0
    for row in allRepos {
      guard let repoId = row[0] as? String, let rootPath = row[1] as? String else { continue }
      if activeRepoPaths.contains(rootPath) { continue }
      if FileManager.default.fileExists(atPath: rootPath) { continue }
      // Manually cascade delete (foreign keys may not be enforced)
      let fileIds = queryRows(db, "SELECT id FROM files WHERE repo_id = ?", args: [repoId]).compactMap { $0[0] as? String }
      for fileId in fileIds {
        let chunkIds = queryRows(db, "SELECT id FROM chunks WHERE file_id = ?", args: [fileId]).compactMap { $0[0] as? String }
        for chunkId in chunkIds {
          exec(db, "DELETE FROM embeddings WHERE chunk_id = ?", args: [chunkId])
        }
        exec(db, "DELETE FROM chunks WHERE file_id = ?", args: [fileId])
      }
      exec(db, "DELETE FROM dependencies WHERE repo_id = ?", args: [repoId])
      exec(db, "DELETE FROM symbols WHERE repo_id = ?", args: [repoId])
      exec(db, "DELETE FROM files WHERE repo_id = ?", args: [repoId])
      exec(db, "DELETE FROM repos WHERE id = ?", args: [repoId])
      removed += 1
    }
    return removed
  }

  // MARK: - Private SQLite Helpers

  @discardableResult
  private static func exec(_ db: OpaquePointer, _ sql: String, args: [Any?]) -> Int32 {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return SQLITE_ERROR }
    defer { sqlite3_finalize(stmt) }
    bind(stmt: stmt, args: args)
    return sqlite3_step(stmt)
  }

  private static func execWithBlob(_ db: OpaquePointer, _ sql: String, textArg: String, blobArg: Data) -> Int32 {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return SQLITE_ERROR }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, (textArg as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    _ = blobArg.withUnsafeBytes { ptr in
      sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(blobArg.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    return sqlite3_step(stmt)
  }

  private static func queryInt(_ db: OpaquePointer, _ sql: String, args: [Any?]) -> Int? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }
    bind(stmt: stmt, args: args)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  private static func queryBlob(_ db: OpaquePointer, _ sql: String, args: [Any?]) -> Data? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }
    bind(stmt: stmt, args: args)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    guard let ptr = sqlite3_column_blob(stmt, 0) else { return nil }
    let count = Int(sqlite3_column_bytes(stmt, 0))
    return Data(bytes: ptr, count: count)
  }

  private static func queryRows(_ db: OpaquePointer, _ sql: String, args: [Any?]) -> [[Any?]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }
    bind(stmt: stmt, args: args)
    var rows = [[Any?]]()
    while sqlite3_step(stmt) == SQLITE_ROW {
      let colCount = Int(sqlite3_column_count(stmt))
      var row = [Any?]()
      for i in 0..<colCount {
        let colType = sqlite3_column_type(stmt, Int32(i))
        switch colType {
        case SQLITE_INTEGER:
          row.append(sqlite3_column_int64(stmt, Int32(i)))
        case SQLITE_FLOAT:
          row.append(sqlite3_column_double(stmt, Int32(i)))
        case SQLITE_TEXT:
          if let cStr = sqlite3_column_text(stmt, Int32(i)) {
            row.append(String(cString: cStr))
          } else {
            row.append(nil)
          }
        case SQLITE_BLOB:
          if let ptr = sqlite3_column_blob(stmt, Int32(i)) {
            let count = Int(sqlite3_column_bytes(stmt, Int32(i)))
            row.append(Data(bytes: ptr, count: count))
          } else {
            row.append(nil)
          }
        default: // SQLITE_NULL
          row.append(nil)
        }
      }
      rows.append(row)
    }
    return rows
  }

  private static func bind(stmt: OpaquePointer, args: [Any?]) {
    for (i, arg) in args.enumerated() {
      let idx = Int32(i + 1)
      switch arg {
      case let s as String:
        sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      case let n as Int:
        sqlite3_bind_int64(stmt, idx, Int64(n))
      case let n as Int64:
        sqlite3_bind_int64(stmt, idx, n)
      case let d as Double:
        sqlite3_bind_double(stmt, idx, d)
      case let data as Data:
        _ = data.withUnsafeBytes { ptr in
          sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      case is NSNull, nil:
        sqlite3_bind_null(stmt, idx)
      default:
        sqlite3_bind_null(stmt, idx)
      }
    }
  }

  // MARK: - Private Git Helper

  private static func gitOutput(args: [String], repoPath: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
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

// MARK: - Errors

enum BranchIndexError: Error, LocalizedError {
  case cannotOpenDatabase(String)

  var errorDescription: String? {
    switch self {
    case .cannotOpenDatabase(let path): return "Cannot open RAG database at \(path)"
    }
  }
}
