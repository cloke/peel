//
//  LocalRAGStore.swift
//  Peel
//
//  Created on 1/19/26.
//

import CryptoKit
import Foundation
import SQLite3

struct LocalRAGIndexReport: Sendable {
  let repoId: String
  let repoPath: String
  let filesIndexed: Int
  let chunksIndexed: Int
  let bytesScanned: Int
  let durationMs: Int
  let embeddingCount: Int
  let embeddingDurationMs: Int
}

struct LocalRAGSearchResult: Sendable {
  let filePath: String
  let startLine: Int
  let endLine: Int
  let snippet: String
}

struct LocalRAGScannedFile: Sendable {
  let path: String
  let text: String
  let lineCount: Int
  let byteCount: Int
  let language: String
}

struct LocalRAGChunk: Sendable {
  let startLine: Int
  let endLine: Int
  let text: String
  let tokenCount: Int
}

struct LocalRAGChunker {
  var maxLines: Int = 200
  var overlapLines: Int = 20

  func chunk(text: String) -> [LocalRAGChunk] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard !lines.isEmpty else { return [] }

    var chunks: [LocalRAGChunk] = []
    chunks.reserveCapacity(max(1, lines.count / maxLines))

    var start = 0
    while start < lines.count {
      let end = min(lines.count, start + maxLines)
      let slice = lines[start..<end]
      let chunkText = slice.joined(separator: "\n")
      let tokenCount = approximateTokenCount(for: chunkText)
      chunks.append(
        LocalRAGChunk(
          startLine: start + 1,
          endLine: end,
          text: chunkText,
          tokenCount: tokenCount
        )
      )
      if end == lines.count { break }
      start = max(0, end - overlapLines)
    }

    return chunks
  }

  private func approximateTokenCount(for text: String) -> Int {
    let words = text.split { $0.isWhitespace || $0.isNewline }
    return max(1, words.count)
  }
}

struct LocalRAGFileScanner {
  var maxFileBytes: Int = 1_000_000
  var excludedDirectories: Set<String> = [
    ".git",
    ".build",
    ".swiftpm",
    "build",
    "DerivedData",
    "node_modules",
    "Carthage"
  ]

  func scan(rootURL: URL) -> [LocalRAGScannedFile] {
    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    var results: [LocalRAGScannedFile] = []

    for case let fileURL as URL in enumerator {
      if shouldSkip(url: fileURL) {
        enumerator.skipDescendants()
        continue
      }

      guard isTextFile(url: fileURL) else { continue }

      if let file = readFile(url: fileURL) {
        results.append(file)
      }
    }

    return results
  }

  private func shouldSkip(url: URL) -> Bool {
    let lastComponent = url.lastPathComponent
    if excludedDirectories.contains(lastComponent) {
      return true
    }
    return false
  }

  private func isTextFile(url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if ext.isEmpty { return false }
    return [
      "swift", "md", "txt", "json", "yml", "yaml", "toml", "rb", "py",
      "js", "ts", "tsx", "jsx", "html", "css", "scss", "sql", "sh",
      "zsh", "bash", "cfg", "ini", "plist", "xml"
    ].contains(ext)
  }

  private func readFile(url: URL) -> LocalRAGScannedFile? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let fileSize = attrs[.size] as? NSNumber else {
      return nil
    }

    let byteCount = min(fileSize.intValue, maxFileBytes)
    guard byteCount > 0 else { return nil }

    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
      return nil
    }

    let slice = data.prefix(byteCount)
    guard let text = String(data: slice, encoding: .utf8) else { return nil }
    let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count

    return LocalRAGScannedFile(
      path: url.path,
      text: text,
      lineCount: lineCount,
      byteCount: byteCount,
      language: languageFor(url: url)
    )
  }

  private func languageFor(url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "swift": return "Swift"
    case "md": return "Markdown"
    case "rb": return "Ruby"
    case "py": return "Python"
    case "js", "jsx": return "JavaScript"
    case "ts", "tsx": return "TypeScript"
    case "yml", "yaml": return "YAML"
    case "json": return "JSON"
    case "toml": return "TOML"
    case "html": return "HTML"
    case "css", "scss": return "CSS"
    case "sql": return "SQL"
    case "sh", "zsh", "bash": return "Shell"
    case "plist", "xml": return "XML"
    default: return url.pathExtension.uppercased()
    }
  }
}

actor LocalRAGStore {
  struct Status: Sendable {
    let dbPath: String
    let exists: Bool
    let schemaVersion: Int
    let extensionLoaded: Bool
    let lastInitializedAt: Date?
    let providerName: String
    let coreMLModelPresent: Bool
    let coreMLVocabPresent: Bool
    let coreMLTokenizerHelperPresent: Bool
  }

  struct Stats: Sendable {
    let repoCount: Int
    let fileCount: Int
    let chunkCount: Int
    let embeddingCount: Int
    let cacheEmbeddingCount: Int
    let dbSizeBytes: Int
    let lastIndexedAt: Date?
    let lastIndexedRepoPath: String?
  }

  enum LocalRAGError: LocalizedError {
    case sqlite(String)
    case invalidPath

    var errorDescription: String? {
      switch self {
      case .sqlite(let message):
        return message
      case .invalidPath:
        return "Invalid database path"
      }
    }
  }

  private let dbURL: URL
  private var db: OpaquePointer?
  private var schemaVersion: Int = 0
  private var extensionLoaded: Bool = false
  private var lastInitializedAt: Date?
  private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private let scanner = LocalRAGFileScanner()
  private let chunker = LocalRAGChunker()
  private let embeddingProvider: LocalRAGEmbeddingProvider

  private let dateFormatter = ISO8601DateFormatter()

  init(embeddingProvider: LocalRAGEmbeddingProvider? = nil) {
    self.embeddingProvider = embeddingProvider ?? LocalRAGEmbeddingProviderFactory.makeDefault()
    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let ragURL = baseURL.appendingPathComponent("Peel/RAG", isDirectory: true)
    if !FileManager.default.fileExists(atPath: ragURL.path) {
      try? FileManager.default.createDirectory(at: ragURL, withIntermediateDirectories: true)
    }
    self.dbURL = ragURL.appendingPathComponent("rag.sqlite")
  }


  func status() -> Status {
    let modelsURL = dbURL.deletingLastPathComponent().appendingPathComponent("Models", isDirectory: true)
    let modelURL = modelsURL.appendingPathComponent("codebert-base-256.mlmodelc")
    let vocabURL = modelsURL.appendingPathComponent("codebert-base.vocab.json")
    let helperURL = modelsURL.appendingPathComponent("tokenize_codebert.py")
    Status(
      dbPath: dbURL.path,
      exists: FileManager.default.fileExists(atPath: dbURL.path),
      schemaVersion: schemaVersion,
      extensionLoaded: extensionLoaded,
      lastInitializedAt: lastInitializedAt,
      providerName: String(describing: type(of: embeddingProvider)),
      coreMLModelPresent: FileManager.default.fileExists(atPath: modelURL.path),
      coreMLVocabPresent: FileManager.default.fileExists(atPath: vocabURL.path),
      coreMLTokenizerHelperPresent: FileManager.default.fileExists(atPath: helperURL.path)
    )
  }

  func initialize(extensionPath: String? = nil) throws -> Status {
    try openIfNeeded()
    try loadExtensionIfAvailable(extensionPath: extensionPath)
    try ensureSchema()
    lastInitializedAt = Date()
    return status()
  }

  func stats() throws -> Stats {
    try openIfNeeded()
    try ensureSchema()

    let repoCount = try queryInt("SELECT COUNT(*) FROM repos")
    let fileCount = try queryInt("SELECT COUNT(*) FROM files")
    let chunkCount = try queryInt("SELECT COUNT(*) FROM chunks")
    let embeddingCount = try queryInt("SELECT COUNT(*) FROM embeddings")
    let cacheEmbeddingCount = try queryInt("SELECT COUNT(*) FROM cache_embeddings")

    let lastIndexedRow = try queryRow(
      "SELECT root_path, last_indexed_at FROM repos WHERE last_indexed_at IS NOT NULL ORDER BY last_indexed_at DESC LIMIT 1"
    )
    let lastIndexedRepoPath = lastIndexedRow?.0
    let lastIndexedAt = lastIndexedRow.flatMap { dateFormatter.date(from: $0.1) }

    let dbSizeBytes = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? NSNumber)?.intValue ?? 0

    return Stats(
      repoCount: repoCount,
      fileCount: fileCount,
      chunkCount: chunkCount,
      embeddingCount: embeddingCount,
      cacheEmbeddingCount: cacheEmbeddingCount,
      dbSizeBytes: dbSizeBytes,
      lastIndexedAt: lastIndexedAt,
      lastIndexedRepoPath: lastIndexedRepoPath
    )
  }

  func indexRepository(path: String) async throws -> LocalRAGIndexReport {
    let startTime = Date()
    _ = try initialize()

    let repoURL = URL(fileURLWithPath: path)
    let scannedFiles = scanner.scan(rootURL: repoURL)
    let repoId = stableId(for: path)
    let repoName = repoURL.lastPathComponent
    let now = dateFormatter.string(from: Date())

    try upsertRepo(id: repoId, name: repoName, rootPath: path, lastIndexedAt: now)

    var chunkCount = 0
    var bytesScanned = 0
    var embeddingCount = 0
    var embeddingDurationMs = 0

    for file in scannedFiles {
      let fileId = stableId(for: "\(repoId):\(file.path)")
      let fileHash = stableId(for: file.text)
      try upsertFile(
        id: fileId,
        repoId: repoId,
        path: file.path,
        hash: fileHash,
        language: file.language,
        updatedAt: now
      )
      try deleteChunks(for: fileId)

      let chunks = chunker.chunk(text: file.text)
      let chunkTexts = chunks.map { $0.text }
      let chunkHashes = chunkTexts.map { stableId(for: $0) }

      var embeddings = Array(repeating: [Float](), count: chunks.count)
      var missingIndexes: [Int] = []

      for (index, textHash) in chunkHashes.enumerated() {
        if let cached = try fetchCachedEmbedding(textHash: textHash) {
          embeddings[index] = cached
        } else {
          missingIndexes.append(index)
        }
      }

      if !missingIndexes.isEmpty {
        let missingTexts = missingIndexes.map { chunkTexts[$0] }
        let embedStart = Date()
        let missingEmbeddings = try await embeddingProvider.embed(texts: missingTexts)
        let embedDuration = Int(Date().timeIntervalSince(embedStart) * 1000)
        embeddingDurationMs += embedDuration
        embeddingCount += missingEmbeddings.count
        for (offset, index) in missingIndexes.enumerated() {
          guard offset < missingEmbeddings.count else { break }
          let vector = missingEmbeddings[offset]
          embeddings[index] = vector
          if !vector.isEmpty {
            try upsertCacheEmbedding(textHash: chunkHashes[index], vector: vector)
          }
        }
      }

      for (index, chunk) in chunks.enumerated() {
        let chunkId = stableId(for: "\(fileId):\(chunk.startLine):\(chunk.endLine):\(chunk.text)")
        try upsertChunk(
          id: chunkId,
          fileId: fileId,
          startLine: chunk.startLine,
          endLine: chunk.endLine,
          text: chunk.text,
          tokenCount: chunk.tokenCount
        )
        if index < embeddings.count {
          try upsertEmbedding(chunkId: chunkId, vector: embeddings[index])
        }
      }

      chunkCount += chunks.count
      bytesScanned += file.byteCount
    }

    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
    return LocalRAGIndexReport(
      repoId: repoId,
      repoPath: path,
      filesIndexed: scannedFiles.count,
      chunksIndexed: chunkCount,
      bytesScanned: bytesScanned,
      durationMs: durationMs,
      embeddingCount: embeddingCount,
      embeddingDurationMs: embeddingDurationMs
    )
  }

  func search(query: String, repoPath: String? = nil, limit: Int = 10) async throws -> [LocalRAGSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }
    try openIfNeeded()

    let sqlBase = """
    SELECT files.path, chunks.start_line, chunks.end_line, chunks.text
    FROM chunks
    JOIN files ON files.id = chunks.file_id
    JOIN repos ON repos.id = files.repo_id
    WHERE chunks.text LIKE ?
    """

    let sql: String
    if repoPath != nil {
      sql = sqlBase + " AND repos.root_path = ? ORDER BY files.path LIMIT ?"
    } else {
      sql = sqlBase + " ORDER BY files.path LIMIT ?"
    }

    return try queryRows(sql: sql) { statement in
      bindText(statement, 1, "%\(trimmedQuery)%")
      var bindIndex: Int32 = 2
      if let repoPath {
        bindText(statement, bindIndex, repoPath)
        bindIndex += 1
      }
      sqlite3_bind_int(statement, bindIndex, Int32(max(1, limit)))
    }
  }

  func searchVector(query: String, repoPath: String? = nil, limit: Int = 10) async throws -> [LocalRAGSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }
    try openIfNeeded()

    let queryVector = try await embeddingProvider.embed(texts: [trimmedQuery]).first ?? []
    if queryVector.isEmpty {
      return []
    }

    let candidateLimit = max(limit * 50, 200)
    let sqlBase = """
    SELECT files.path, chunks.start_line, chunks.end_line, chunks.text, embeddings.embedding
    FROM embeddings
    JOIN chunks ON chunks.id = embeddings.chunk_id
    JOIN files ON files.id = chunks.file_id
    JOIN repos ON repos.id = files.repo_id
    WHERE embeddings.embedding IS NOT NULL
    """

    let sql: String
    if repoPath != nil {
      sql = sqlBase + " AND repos.root_path = ? LIMIT ?"
    } else {
      sql = sqlBase + " LIMIT ?"
    }

    let rows = try queryEmbeddingRows(sql: sql) { statement in
      var bindIndex: Int32 = 1
      if let repoPath {
        bindText(statement, bindIndex, repoPath)
        bindIndex += 1
      }
      sqlite3_bind_int(statement, bindIndex, Int32(candidateLimit))
    }

    let scored = rows.compactMap { row -> (LocalRAGSearchResult, Float)? in
      guard let vector = decodeVector(row.embeddingData) else { return nil }
      let score = cosineSimilarity(queryVector, vector)
      let snippet = String(row.text.prefix(240))
      let result = LocalRAGSearchResult(
        filePath: row.filePath,
        startLine: row.startLine,
        endLine: row.endLine,
        snippet: snippet
      )
      return (result, score)
    }

    let top = scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    return Array(top)
  }

  private func openIfNeeded() throws {
    if db != nil {
      return
    }
    guard dbURL.isFileURL else {
      throw LocalRAGError.invalidPath
    }
    var handle: OpaquePointer?
    let result = sqlite3_open(dbURL.path, &handle)
    guard result == SQLITE_OK, let handle else {
      if let handle {
        let message = String(cString: sqlite3_errmsg(handle))
        throw LocalRAGError.sqlite(message)
      }
      throw LocalRAGError.sqlite("Failed to open SQLite database")
    }
    db = handle
    sqlite3_exec(handle, "PRAGMA foreign_keys = ON;", nil, nil, nil)
  }

  private func loadExtensionIfAvailable(extensionPath: String?) throws {
    extensionLoaded = false
    let path = extensionPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let path, !path.isEmpty else {
      return
    }
    throw LocalRAGError.sqlite("SQLite extension loading is not enabled in this build (path: \(path))")
  }

  private func ensureSchema() throws {
    try exec("CREATE TABLE IF NOT EXISTS rag_meta (key TEXT PRIMARY KEY, value TEXT)")
    try exec("CREATE TABLE IF NOT EXISTS repos (id TEXT PRIMARY KEY, name TEXT, root_path TEXT, last_indexed_at TEXT)")
    try exec("CREATE TABLE IF NOT EXISTS files (id TEXT PRIMARY KEY, repo_id TEXT, path TEXT, hash TEXT, language TEXT, updated_at TEXT, FOREIGN KEY(repo_id) REFERENCES repos(id) ON DELETE CASCADE)")
    try exec("CREATE TABLE IF NOT EXISTS chunks (id TEXT PRIMARY KEY, file_id TEXT, start_line INTEGER, end_line INTEGER, text TEXT, token_count INTEGER, FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE)")
    try exec("CREATE TABLE IF NOT EXISTS embeddings (chunk_id TEXT PRIMARY KEY, embedding BLOB, FOREIGN KEY(chunk_id) REFERENCES chunks(id) ON DELETE CASCADE)")
    try exec("CREATE TABLE IF NOT EXISTS cache_embeddings (text_hash TEXT PRIMARY KEY, embedding BLOB, updated_at TEXT)")

    let now = dateFormatter.string(from: Date())
    try exec("INSERT OR IGNORE INTO rag_meta (key, value) VALUES ('schema_version', '1')")
    try exec("INSERT OR IGNORE INTO rag_meta (key, value) VALUES ('created_at', '\(now)')")
    try exec("INSERT OR REPLACE INTO rag_meta (key, value) VALUES ('updated_at', '\(now)')")

    let versionText = try queryString("SELECT value FROM rag_meta WHERE key = 'schema_version'")
    schemaVersion = Int(versionText ?? "") ?? 0
  }

  private func exec(_ sql: String) throws {
    guard let db else {
      throw LocalRAGError.sqlite("Database not initialized")
    }
    var errorMessage: UnsafeMutablePointer<Int8>?
    let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    if result != SQLITE_OK {
      let message = errorMessage.map { String(cString: $0) } ?? "SQLite error"
      if let errorMessage {
        sqlite3_free(errorMessage)
      }
      throw LocalRAGError.sqlite(message)
    }
  }

  private func queryString(_ sql: String) throws -> String? {
    guard let db else {
      throw LocalRAGError.sqlite("Database not initialized")
    }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK else {
      let message = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite(message)
    }
    defer { sqlite3_finalize(statement) }

    if sqlite3_step(statement) == SQLITE_ROW,
       let text = sqlite3_column_text(statement, 0) {
      return String(cString: text)
    }
    return nil
  }

  private func queryInt(_ sql: String) throws -> Int {
    let value = try queryString(sql) ?? "0"
    return Int(value) ?? 0
  }

  private func queryRow(_ sql: String) throws -> (String, String)? {
    guard let db else {
      throw LocalRAGError.sqlite("Database not initialized")
    }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      let message = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite(message)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
      return nil
    }

    guard let firstText = sqlite3_column_text(statement, 0),
          let secondText = sqlite3_column_text(statement, 1) else {
      return nil
    }

    return (String(cString: firstText), String(cString: secondText))
  }

  private struct EmbeddingRow {
    let filePath: String
    let startLine: Int
    let endLine: Int
    let text: String
    let embeddingData: Data
  }

  private func queryEmbeddingRows(
    sql: String,
    binder: (OpaquePointer) -> Void
  ) throws -> [EmbeddingRow] {
    guard let db else {
      throw LocalRAGError.sqlite("Database not initialized")
    }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      let message = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite(message)
    }
    defer { sqlite3_finalize(statement) }

    binder(statement)

    var rows: [EmbeddingRow] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let path = String(cString: sqlite3_column_text(statement, 0))
      let startLine = Int(sqlite3_column_int(statement, 1))
      let endLine = Int(sqlite3_column_int(statement, 2))
      let text = String(cString: sqlite3_column_text(statement, 3))
      let blobPointer = sqlite3_column_blob(statement, 4)
      let blobSize = sqlite3_column_bytes(statement, 4)
      if let blobPointer, blobSize > 0 {
        let data = Data(bytes: blobPointer, count: Int(blobSize))
        rows.append(
          EmbeddingRow(
            filePath: path,
            startLine: startLine,
            endLine: endLine,
            text: text,
            embeddingData: data
          )
        )
      }
    }

    return rows
  }

  private func queryRows(
    sql: String,
    binder: (OpaquePointer) -> Void
  ) throws -> [LocalRAGSearchResult] {
    guard let db else {
      throw LocalRAGError.sqlite("Database not initialized")
    }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      let message = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite(message)
    }
    defer { sqlite3_finalize(statement) }

    binder(statement)

    var results: [LocalRAGSearchResult] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let path = String(cString: sqlite3_column_text(statement, 0))
      let startLine = Int(sqlite3_column_int(statement, 1))
      let endLine = Int(sqlite3_column_int(statement, 2))
      let text = String(cString: sqlite3_column_text(statement, 3))
      let snippet = String(text.prefix(240))
      results.append(
        LocalRAGSearchResult(
          filePath: path,
          startLine: startLine,
          endLine: endLine,
          snippet: snippet
        )
      )
    }

    return results
  }

  private func upsertRepo(id: String, name: String, rootPath: String, lastIndexedAt: String) throws {
    let sql = """
    INSERT OR REPLACE INTO repos (id, name, root_path, last_indexed_at)
    VALUES (?, ?, ?, ?)
    """
    try execute(sql: sql) { statement in
      bindText(statement, 1, id)
      bindText(statement, 2, name)
      bindText(statement, 3, rootPath)
      bindText(statement, 4, lastIndexedAt)
    }
  }

  private func upsertFile(
    id: String,
    repoId: String,
    path: String,
    hash: String,
    language: String,
    updatedAt: String
  ) throws {
    let sql = """
    INSERT OR REPLACE INTO files (id, repo_id, path, hash, language, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)
    """
    try execute(sql: sql) { statement in
      bindText(statement, 1, id)
      bindText(statement, 2, repoId)
      bindText(statement, 3, path)
      bindText(statement, 4, hash)
      bindText(statement, 5, language)
      bindText(statement, 6, updatedAt)
    }
  }

  private func upsertChunk(
    id: String,
    fileId: String,
    startLine: Int,
    endLine: Int,
    text: String,
    tokenCount: Int
  ) throws {
    let sql = """
    INSERT OR REPLACE INTO chunks (id, file_id, start_line, end_line, text, token_count)
    VALUES (?, ?, ?, ?, ?, ?)
    """
    try execute(sql: sql) { statement in
      bindText(statement, 1, id)
      bindText(statement, 2, fileId)
      sqlite3_bind_int(statement, 3, Int32(startLine))
      sqlite3_bind_int(statement, 4, Int32(endLine))
      bindText(statement, 5, text)
      sqlite3_bind_int(statement, 6, Int32(tokenCount))
    }
  }

  private func deleteChunks(for fileId: String) throws {
    let sql = "DELETE FROM chunks WHERE file_id = ?"
    try execute(sql: sql) { statement in
      bindText(statement, 1, fileId)
    }
  }

  private func execute(sql: String, binder: (OpaquePointer) -> Void) throws {
    guard let db else {
      throw LocalRAGError.sqlite("Database not initialized")
    }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK else {
      let message = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite(message)
    }
    guard let statement else {
      throw LocalRAGError.sqlite("Failed to prepare statement")
    }
    defer { sqlite3_finalize(statement) }

    binder(statement)
    let stepResult = sqlite3_step(statement)
    guard stepResult == SQLITE_DONE else {
      let message = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite(message)
    }
  }

  private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
    sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
  }

  private func upsertEmbedding(chunkId: String, vector: [Float]) throws {
    let sql = """
    INSERT OR REPLACE INTO embeddings (chunk_id, embedding)
    VALUES (?, ?)
    """
    let data = encodeVector(vector)
    try execute(sql: sql) { statement in
      bindText(statement, 1, chunkId)
      _ = data.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), sqliteTransient)
      }
    }
  }

  private func fetchCachedEmbedding(textHash: String) throws -> [Float]? {
    guard let db else {
      throw LocalRAGError.sqlite("Database not initialized")
    }
    let sql = "SELECT embedding FROM cache_embeddings WHERE text_hash = ? LIMIT 1"
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      let message = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite(message)
    }
    defer { sqlite3_finalize(statement) }

    bindText(statement, 1, textHash)

    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let blobPointer = sqlite3_column_blob(statement, 0)
    let blobSize = sqlite3_column_bytes(statement, 0)
    guard let blobPointer, blobSize > 0 else { return nil }
    let data = Data(bytes: blobPointer, count: Int(blobSize))
    return decodeVector(data)
  }

  private func upsertCacheEmbedding(textHash: String, vector: [Float]) throws {
    let sql = "INSERT OR REPLACE INTO cache_embeddings (text_hash, embedding, updated_at) VALUES (?, ?, ?)"
    let data = encodeVector(vector)
    let now = dateFormatter.string(from: Date())
    try execute(sql: sql) { statement in
      bindText(statement, 1, textHash)
      _ = data.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), sqliteTransient)
      }
      bindText(statement, 3, now)
    }
  }

  private func encodeVector(_ vector: [Float]) -> Data {
    var copy = vector
    return Data(bytes: &copy, count: MemoryLayout<Float>.stride * copy.count)
  }

  private func decodeVector(_ data: Data) -> [Float]? {
    let stride = MemoryLayout<Float>.stride
    guard data.count % stride == 0 else { return nil }
    let count = data.count / stride
    return data.withUnsafeBytes { buffer in
      let pointer = buffer.bindMemory(to: Float.self)
      guard pointer.count >= count else { return nil }
      return Array(pointer.prefix(count))
    }
  }

  private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
    let count = min(lhs.count, rhs.count)
    guard count > 0 else { return 0 }
    var dot: Float = 0
    var lhsSum: Float = 0
    var rhsSum: Float = 0
    for i in 0..<count {
      dot += lhs[i] * rhs[i]
      lhsSum += lhs[i] * lhs[i]
      rhsSum += rhs[i] * rhs[i]
    }
    let denom = sqrt(max(lhsSum * rhsSum, 0.000001))
    return dot / denom
  }

  private func stableId(for value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
