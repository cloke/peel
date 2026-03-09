import XCTest
@testable import Peel
import CSQLite

#if os(macOS)

final class RAGRepoSyncTests: XCTestCase {

  func testExportRepoPrefersLargestMatchingRepoAndProviderProfileWhenMetadataIsAmbiguous() throws {
    let dbURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rag-repo-sync-tests-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }

    try makeTestDatabase(at: dbURL.path)

    let bundle = try RAGRepoExporter.exportRepo(
      dbPath: dbURL.path,
      repoIdentifier: "github.com/cloke/peel",
      schemaVersion: 14,
      embeddingModel: "Qwen3-Embedding-0.6B-4bit",
      embeddingDimensions: 1024,
      excludeFileHashes: []
    )

    XCTAssertNotNil(bundle)
    XCTAssertEqual(bundle?.repo.id, "root")
    XCTAssertEqual(bundle?.manifest.fileCount, 2)
    XCTAssertEqual(bundle?.manifest.chunkCount, 3)
    XCTAssertEqual(bundle?.files.count, 2)
    XCTAssertEqual(bundle?.manifest.embeddingModel, "Qwen3-Embedding-0.6B-4bit")
    XCTAssertEqual(bundle?.manifest.embeddingDimensions, 1024)
  }

  private func makeTestDatabase(at path: String) throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
    guard let db else {
      XCTFail("Failed to open SQLite DB")
      return
    }
    defer { sqlite3_close(db) }

    try exec(db, """
      CREATE TABLE repos (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        root_path TEXT NOT NULL,
        last_indexed_at TEXT,
        repo_identifier TEXT,
        parent_repo_id TEXT,
        embedding_model TEXT,
        embedding_dimensions INTEGER
      );
      """)
    try exec(db, """
      CREATE TABLE files (
        id TEXT PRIMARY KEY,
        repo_id TEXT NOT NULL,
        path TEXT NOT NULL,
        hash TEXT NOT NULL,
        language TEXT,
        updated_at TEXT,
        module_path TEXT,
        feature_tags TEXT,
        line_count INTEGER DEFAULT 0,
        method_count INTEGER DEFAULT 0,
        byte_size INTEGER DEFAULT 0
      );
      """)
    try exec(db, """
      CREATE TABLE chunks (
        id TEXT PRIMARY KEY,
        file_id TEXT NOT NULL,
        start_line INTEGER NOT NULL,
        end_line INTEGER NOT NULL,
        text TEXT NOT NULL,
        token_count INTEGER NOT NULL,
        construct_type TEXT,
        construct_name TEXT,
        metadata TEXT,
        ai_summary TEXT,
        ai_tags TEXT,
        analyzed_at TEXT,
        analyzer_model TEXT,
        enriched_at TEXT
      );
      """)
    try exec(db, "CREATE TABLE embeddings (chunk_id TEXT PRIMARY KEY, embedding BLOB);")
    try exec(db, "CREATE TABLE rag_meta (key TEXT PRIMARY KEY, value TEXT);")

    try exec(db, """
      INSERT INTO repos (id, name, root_path, repo_identifier, parent_repo_id, embedding_model, embedding_dimensions)
      VALUES
        ('root', 'kitchen-sink', '/tmp/kitchen-sink', 'github.com/cloke/peel', NULL, 'nomic-embed-text-v1.5', 768),
        ('pkg', 'Git', '/tmp/kitchen-sink/Local Packages/Git', 'github.com/cloke/peel', 'root', NULL, NULL);
      """)

    try insertFile(db, repoId: "root", fileId: "root-file-1", path: "Shared/PeelApp.swift", hash: "hash-1")
    try insertFile(db, repoId: "root", fileId: "root-file-2", path: "Shared/RepoDetailView.swift", hash: "hash-2")
    try insertFile(db, repoId: "pkg", fileId: "pkg-file-1", path: "Sources/Git/Git.swift", hash: "hash-3")

    try insertChunk(db, chunkId: "chunk-1", fileId: "root-file-1", startLine: 1, endLine: 10)
    try insertChunk(db, chunkId: "chunk-2", fileId: "root-file-2", startLine: 1, endLine: 20)
    try insertChunk(db, chunkId: "chunk-3", fileId: "root-file-2", startLine: 21, endLine: 30)
    try insertChunk(db, chunkId: "chunk-4", fileId: "pkg-file-1", startLine: 1, endLine: 10)
  }

  private func insertFile(
    _ db: OpaquePointer,
    repoId: String,
    fileId: String,
    path: String,
    hash: String
  ) throws {
    try exec(db, """
      INSERT INTO files (id, repo_id, path, hash, language, updated_at, module_path, feature_tags, line_count, method_count, byte_size)
      VALUES ('\(fileId)', '\(repoId)', '\(path)', '\(hash)', 'swift', NULL, NULL, NULL, 100, 1, 1024);
      """)
  }

  private func insertChunk(
    _ db: OpaquePointer,
    chunkId: String,
    fileId: String,
    startLine: Int,
    endLine: Int
  ) throws {
    try exec(db, """
      INSERT INTO chunks (id, file_id, start_line, end_line, text, token_count, construct_type, construct_name, metadata, ai_summary, ai_tags, analyzed_at, analyzer_model, enriched_at)
      VALUES ('\(chunkId)', '\(fileId)', \(startLine), \(endLine), 'test', 10, 'function', 'demo', NULL, NULL, NULL, NULL, NULL, NULL);
      """)
  }

  private func exec(_ db: OpaquePointer, _ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    if result != SQLITE_OK {
      let message = errorMessage.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(errorMessage)
      XCTFail("SQLite error: \(message)")
      throw NSError(domain: "RAGRepoSyncTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
}

#endif