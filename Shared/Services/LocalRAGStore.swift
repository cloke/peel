//
//  LocalRAGStore.swift
//  Peel
//
//  Created on 1/19/26.
//

import ASTChunker
import CryptoKit
import Darwin
import Foundation
import SQLite3
import MachO
import MLX

struct LocalRAGIndexReport: Sendable {
  let repoId: String
  let repoPath: String
  let filesIndexed: Int
  let filesSkipped: Int
  let chunksIndexed: Int
  let bytesScanned: Int
  let durationMs: Int
  let embeddingCount: Int
  let embeddingDurationMs: Int
  
  // AST chunking stats
  let astFilesChunked: Int
  let lineFilesChunked: Int
  let chunkingFailures: Int
}

/// Progress updates during indexing operations
enum LocalRAGIndexProgress: Sendable {
  case scanning(fileCount: Int)
  case analyzing(current: Int, total: Int, fileName: String)
  case embedding(current: Int, total: Int)
  case storing(current: Int, total: Int)
  case complete(report: LocalRAGIndexReport)
  
  var description: String {
    switch self {
    case .scanning(let count):
      return "Scanning files... (\(count) found)"
    case .analyzing(let current, let total, let fileName):
      return "Analyzing \(current)/\(total): \(fileName)"
    case .embedding(let current, let total):
      return "Generating embeddings... \(current)/\(total)"
    case .storing(let current, let total):
      return "Storing chunks... \(current)/\(total)"
    case .complete(let report):
      return "Complete: \(report.filesIndexed) files, \(report.chunksIndexed) chunks in \(report.durationMs)ms"
    }
  }
  
  var progress: Double {
    switch self {
    case .scanning: return 0.1
    case .analyzing(let current, let total, _): return 0.1 + 0.3 * Double(current) / Double(max(1, total))
    case .embedding(let current, let total): return 0.4 + 0.4 * Double(current) / Double(max(1, total))
    case .storing(let current, let total): return 0.8 + 0.2 * Double(current) / Double(max(1, total))
    case .complete: return 1.0
    }
  }
  
  var isComplete: Bool {
    if case .complete = self { return true }
    return false
  }
}

/// Callback type for progress updates
typealias LocalRAGProgressCallback = @Sendable (LocalRAGIndexProgress) -> Void

struct LocalRAGSearchResult: Sendable {
  let filePath: String
  let startLine: Int
  let endLine: Int
  let snippet: String
  
  // Metadata for agent understanding
  let constructType: String?    // "class", "function", "component", etc.
  let constructName: String?    // "UserService", "validateForm", etc.
  let language: String?         // "Swift", "Ruby", "Glimmer TypeScript"
  let isTest: Bool              // true if in test/spec directory
  let score: Float?             // relevance score for vector search
  
  // Facets for filtering/grouping (schema v4+)
  let modulePath: String?       // e.g., "Shared/Services", "Local Packages/Git"
  let featureTags: [String]     // e.g., ["rag", "indexing"], derived from path/metadata
  
  /// Number of lines in this chunk
  var lineCount: Int { endLine - startLine + 1 }
}

struct LocalRAGQueryHint: Sendable {
  let query: String
  let repoPath: String?
  let mode: String
  let resultCount: Int
  let useCount: Int
  let lastUsedAt: Date
}

struct LocalRAGFileCandidate: Sendable {
  let path: String
  let byteCount: Int
  let language: String
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
  
  // AST metadata (nil for line-based chunks)
  let constructType: String?
  let constructName: String?
  
  /// JSON-encoded metadata from AST analysis (decorators, protocols, imports, etc.)
  let metadata: String?
  
  init(startLine: Int, endLine: Int, text: String, tokenCount: Int, constructType: String? = nil, constructName: String? = nil, metadata: String? = nil) {
    self.startLine = startLine
    self.endLine = endLine
    self.text = text
    self.tokenCount = tokenCount
    self.constructType = constructType
    self.constructName = constructName
    self.metadata = metadata
  }
}

struct LocalRAGChunker {
  var maxLines: Int = 100  // Reduced from 200 for better granularity
  var minLines: Int = 20   // Don't create tiny chunks
  var overlapLines: Int = 10

  func chunk(text: String) -> [LocalRAGChunk] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    guard !lines.isEmpty else { return [] }

    var chunks: [LocalRAGChunk] = []
    chunks.reserveCapacity(max(1, lines.count / maxLines))

    var start = 0
    while start < lines.count {
      // Find a good end point - prefer semantic boundaries
      var end = min(lines.count, start + maxLines)

      // If not at file end, try to find a semantic boundary
      if end < lines.count {
        end = findSemanticBoundary(lines: lines, from: start, preferredEnd: end)
      }

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

  /// Find a semantic boundary (MARK comment, type definition, extension, etc.)
  /// Search backwards from preferredEnd to find a good split point
  private func findSemanticBoundary(lines: [String], from start: Int, preferredEnd: Int) -> Int {
    // Patterns that indicate semantic boundaries (start of new sections)
    let boundaryPatterns = [
      "// MARK: -",           // Swift section markers
      "// MARK:",
      "// FIXME:",
      "// TODO:",
      "// ===",               // Section dividers
      "// ---",
      "struct ",              // Type definitions
      "class ",
      "enum ",
      "protocol ",
      "extension ",
      "actor ",
      "func ",                // Top-level functions
      "public func ",
      "private func ",
      "internal func ",
      "@MainActor",           // Attributes that start declarations
      "@Observable",
      "## ",                  // Markdown headers
      "### ",
      "#### ",
    ]

    // Search backwards from preferredEnd, but not past minLines from start
    let searchStart = max(start + minLines, preferredEnd - 30)

    for i in stride(from: preferredEnd - 1, through: searchStart, by: -1) {
      let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

      // Check if this line starts a new semantic block
      for pattern in boundaryPatterns {
        if trimmed.hasPrefix(pattern) {
          // Found a boundary - return the line BEFORE this (end of previous section)
          return i
        }
      }

      // Also break on blank lines followed by comments or declarations
      if trimmed.isEmpty && i + 1 < lines.count {
        let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
        if nextTrimmed.hasPrefix("//") || nextTrimmed.hasPrefix("///") ||
           nextTrimmed.hasPrefix("struct") || nextTrimmed.hasPrefix("class") ||
           nextTrimmed.hasPrefix("func") || nextTrimmed.hasPrefix("enum") ||
           nextTrimmed.hasPrefix("extension") || nextTrimmed.hasPrefix("protocol") {
          return i + 1
        }
      }
    }

    // No good boundary found, use the preferred end
    return preferredEnd
  }

  private func approximateTokenCount(for text: String) -> Int {
    let words = text.split { $0.isWhitespace || $0.isNewline }
    return max(1, words.count)
  }
}

// MARK: - Chunking Health Tracker

/// Tracks chunking failures to enable auto-fallback and diagnostics.
/// Records failures per file so problematic files automatically use line-based chunking on re-index.
struct ChunkingHealthTracker: Sendable {
  
  enum FailureType: String, Codable, Sendable {
    case timeout = "timeout"
    case crash = "crash"
    case stackOverflow = "stack_overflow"
    case parseError = "parse_error"
    case unknown = "unknown"
  }
  
  struct FailureRecord: Codable, Sendable {
    let filePath: String
    let language: String
    let errorType: FailureType
    let errorMessage: String?
    let timestamp: Date
    let fileHash: String
  }
  
  private static let cacheURL: URL = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let peelDir = appSupport.appendingPathComponent("Peel", isDirectory: true)
    try? FileManager.default.createDirectory(at: peelDir, withIntermediateDirectories: true)
    return peelDir.appendingPathComponent("chunking_failures.json")
  }()
  
  private var failures: [FailureRecord] = []
  private let maxFailures = 500  // Limit stored failures
  
  init() {
    loadFailures()
  }
  
  /// Check if we should skip AST chunking for a file based on previous failures
  func shouldSkipAST(for filePath: String, hash: String) -> Bool {
    failures.contains { $0.filePath == filePath && $0.fileHash == hash }
  }
  
  /// Record a chunking failure
  mutating func recordFailure(
    filePath: String,
    language: String,
    errorType: FailureType,
    errorMessage: String?,
    fileHash: String
  ) {
    // Remove old failure for this file if any
    failures.removeAll { $0.filePath == filePath }
    
    let record = FailureRecord(
      filePath: filePath,
      language: language,
      errorType: errorType,
      errorMessage: errorMessage,
      timestamp: Date(),
      fileHash: fileHash
    )
    failures.append(record)
    
    // Trim old failures if over limit
    if failures.count > maxFailures {
      failures = Array(failures.suffix(maxFailures))
    }
    
    saveFailures()
    print("[ChunkingHealth] Recorded failure: \(filePath) - \(errorType.rawValue)")
  }
  
  /// Clear failures for files that have changed (hash differs)
  mutating func clearStaleFailures(currentFiles: [(path: String, hash: String)]) {
    let currentMap = Dictionary(uniqueKeysWithValues: currentFiles.map { ($0.path, $0.hash) })
    let before = failures.count
    failures.removeAll { record in
      guard let currentHash = currentMap[record.filePath] else {
        // File no longer exists - remove failure
        return true
      }
      // File changed - remove old failure
      return currentHash != record.fileHash
    }
    let removed = before - failures.count
    if removed > 0 {
      print("[ChunkingHealth] Cleared \(removed) stale failures")
      saveFailures()
    }
  }
  
  /// Get all current failures for diagnostics
  func getFailures() -> [FailureRecord] {
    failures
  }
  
  /// Get failures grouped by language
  func failuresByLanguage() -> [String: Int] {
    Dictionary(grouping: failures, by: { $0.language }).mapValues { $0.count }
  }
  
  private mutating func loadFailures() {
    guard FileManager.default.fileExists(atPath: Self.cacheURL.path),
          let data = try? Data(contentsOf: Self.cacheURL),
          let decoded = try? JSONDecoder().decode([FailureRecord].self, from: data) else {
      return
    }
    failures = decoded
    print("[ChunkingHealth] Loaded \(failures.count) failure records")
  }
  
  private func saveFailures() {
    do {
      let data = try JSONEncoder().encode(failures)
      try data.write(to: Self.cacheURL)
    } catch {
      print("[ChunkingHealth] Failed to save: \(error)")
    }
  }
}

// MARK: - Hybrid Chunker

/// Result of chunking with metadata about how it was processed
struct ChunkingResult: Sendable {
  let chunks: [LocalRAGChunk]
  let usedAST: Bool
  let failureType: ChunkingHealthTracker.FailureType?
  let failureMessage: String?
}

/// Hybrid chunker that uses AST-aware chunking for supported languages (Swift, Ruby, GTS)
/// and falls back to line-based chunking for others.
/// Note: TypeScript/JavaScript/GTS/GJS now use JavaScriptCore-based chunker.
/// Swift uses subprocess isolation (ast-chunker-cli) to prevent stack overflow crashes.
struct HybridChunker {
  private let lineChunker = LocalRAGChunker()
  private let rubyChunker: RubyChunker?
  private let glimmerChunker: GlimmerChunker?
  private let jsChunker: JSCoreTypeScriptChunker
  
  /// Path to ast-chunker-cli (resolved lazily)
  private let astChunkerCLIPath: String?
  
  /// Subprocess timeout for Swift AST parsing
  private let swiftSubprocessTimeout: TimeInterval = 5.0
  
  /// Max file size for Swift subprocess (very large files still timeout)
  private let swiftSubprocessMaxBytes = 500_000  // 500KB
  
  /// Max file size for tree-sitter parsing (very large files are too slow)
  private let treeSitterMaxBytes = 500_000  // 500KB
  
  /// Max file size for JSCore parsing (very large files may be slow)
  private let jsMaxBytes = 500_000  // 500KB
  
  /// Languages that have AST chunker support
  private var astSupportedLanguages: Set<String> {
    var languages: Set<String> = []
    // Swift uses subprocess isolation via ast-chunker-cli (re-enabled in #177/#178)
    if astChunkerCLIPath != nil {
      languages.insert("Swift")
    }
    if rubyChunker != nil {
      languages.insert("Ruby")
    }
    // TypeScript/JavaScript/GTS/GJS use JSCore chunker (issue #173)
    if jsChunker.isAvailable {
      languages.insert("TypeScript")
      languages.insert("JavaScript")
      languages.insert("Glimmer TypeScript")
      languages.insert("Glimmer JavaScript")
    }
    return languages
  }
  
  /// Find the ast-chunker-cli binary
  private static func findASTChunkerCLI() -> String? {
    // Check in app bundle first
    if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("ast-chunker-cli").path,
       FileManager.default.fileExists(atPath: bundlePath) {
      return bundlePath
    }
    
    // Check Frameworks directory
    if let frameworksPath = Bundle.main.privateFrameworksPath {
      let cliPath = (frameworksPath as NSString).appendingPathComponent("ast-chunker-cli")
      if FileManager.default.fileExists(atPath: cliPath) {
        return cliPath
      }
    }
    
    // Development: check build directory
    let devPaths = [
      "~/code/KitchenSink/Local Packages/ASTChunker/.build/release/ast-chunker-cli",
      "~/code/KitchenSink/Local Packages/ASTChunker/.build/debug/ast-chunker-cli",
    ]
    for path in devPaths {
      let expanded = (path as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: expanded) {
        return expanded
      }
    }
    
    return nil
  }
  
  init() {
    let cliPath = "/opt/homebrew/bin/tree-sitter"
    
    // Initialize Ruby chunker if tree-sitter is available
    let rubyLibPath = ("~/code/tree-sitter-grammars/tree-sitter-ruby/ruby.dylib" as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: cliPath) &&
       FileManager.default.fileExists(atPath: rubyLibPath) {
      self.rubyChunker = RubyChunker(treeSitterLibPath: rubyLibPath, treeSitterCLIPath: cliPath)
    } else {
      self.rubyChunker = nil
    }
    
    // Initialize Glimmer chunker if tree-sitter grammar is available
    let glimmerChunker = GlimmerChunker()
    self.glimmerChunker = glimmerChunker.isAvailable ? glimmerChunker : nil
    
    // Find ast-chunker-cli for Swift subprocess chunking
    self.astChunkerCLIPath = Self.findASTChunkerCLI()
    
    // Initialize JSCore chunker for TypeScript/JavaScript (issue #173)
    self.jsChunker = JSCoreTypeScriptChunker.shared
    
    print("[HybridChunker] Ruby chunker available: \(rubyChunker != nil)")
    print("[HybridChunker] Glimmer chunker available: \(glimmerChunker.isAvailable)")
    print("[HybridChunker] Swift CLI available: \(astChunkerCLIPath != nil) at \(astChunkerCLIPath ?? "N/A")")
    print("[HybridChunker] JSCore TS/JS chunker available: \(jsChunker.isAvailable)")
    print("[HybridChunker] AST supported languages: \(astSupportedLanguages)")
  }
  
  /// Chunk with full error tracking and health-aware fallback
  func chunkSafe(
    text: String,
    language: String,
    filePath: String,
    fileHash: String,
    healthTracker: ChunkingHealthTracker
  ) -> ChunkingResult {
    // Check if we should skip AST for this file due to previous failures
    if healthTracker.shouldSkipAST(for: filePath, hash: fileHash) {
      print("[HybridChunker] Skipping AST for \(filePath) due to previous failure")
      return ChunkingResult(
        chunks: lineChunker.chunk(text: text),
        usedAST: false,
        failureType: nil,
        failureMessage: "Skipped due to previous failure"
      )
    }
    
    // Use AST chunking for supported languages
    if astSupportedLanguages.contains(language) {
      let result = chunkWithASTSafe(text: text, language: language, filePath: filePath)
      return result
    }
    
    // Fall back to line-based chunking
    return ChunkingResult(
      chunks: lineChunker.chunk(text: text),
      usedAST: false,
      failureType: nil,
      failureMessage: nil
    )
  }
  
  /// Legacy method for backward compatibility
  func chunk(text: String, language: String) -> [LocalRAGChunk] {
    print("[HybridChunker] chunk called with language: \(language)")
    // Use AST chunking for supported languages
    if astSupportedLanguages.contains(language) {
      let chunks = chunkWithAST(text: text, language: language)
      print("[RAG] AST chunking \(language): \(chunks.count) chunks")
      return chunks
    }
    
    // Fall back to line-based chunking
    print("[HybridChunker] Falling back to line-based chunking for \(language)")
    return lineChunker.chunk(text: text)
  }
  
  /// Safe AST chunking with error capture
  private func chunkWithASTSafe(text: String, language: String, filePath: String) -> ChunkingResult {
    let byteCount = text.utf8.count
    
    // Pre-flight checks based on language
    switch language {
    case "Swift":
      // Use subprocess isolation for Swift (handles crash/timeout safely)
      if byteCount > swiftSubprocessMaxBytes {
        print("[HybridChunker] Swift file too large for subprocess (\(byteCount) bytes), using line chunking")
        return ChunkingResult(
          chunks: lineChunker.chunk(text: text),
          usedAST: false,
          failureType: .timeout,
          failureMessage: "File too large: \(byteCount) bytes"
        )
      }
      return chunkSwiftWithSubprocess(text: text, filePath: filePath)
    case "Ruby":
      if byteCount > treeSitterMaxBytes {
        print("[HybridChunker] File too large for tree-sitter (\(byteCount) bytes)")
        return ChunkingResult(
          chunks: lineChunker.chunk(text: text),
          usedAST: false,
          failureType: .timeout,
          failureMessage: "File too large: \(byteCount) bytes"
        )
      }
    case "TypeScript", "JavaScript", "Glimmer TypeScript", "Glimmer JavaScript":
      // Use JSCore chunker for TypeScript/JavaScript/GTS/GJS (issue #173)
      if byteCount > jsMaxBytes {
        print("[HybridChunker] File too large for JSCore (\(byteCount) bytes)")
        return ChunkingResult(
          chunks: lineChunker.chunk(text: text),
          usedAST: false,
          failureType: .timeout,
          failureMessage: "File too large: \(byteCount) bytes"
        )
      }
      return chunkJSWithJSCore(text: text, language: language, filePath: filePath)
    default:
      break
    }
    
    // Attempt AST chunking for non-Swift languages
    let astChunks = chunkWithAST(text: text, language: language)
    
    if astChunks.isEmpty {
      return ChunkingResult(
        chunks: lineChunker.chunk(text: text),
        usedAST: false,
        failureType: .parseError,
        failureMessage: "AST returned empty"
      )
    }
    
    return ChunkingResult(
      chunks: astChunks,
      usedAST: true,
      failureType: nil,
      failureMessage: nil
    )
  }
  
  // MARK: - Swift Subprocess Chunking
  
  /// JSON output structure from ast-chunker-cli
  private struct CLIChunk: Codable {
    let startLine: Int
    let endLine: Int
    let text: String
    let constructType: String
    let constructName: String?
    let tokenCount: Int
    let metadata: String?  // JSON-encoded ASTChunkMetadata
  }
  
  /// Chunk Swift file using subprocess isolation (issues #177, #178)
  /// Subprocess approach prevents SwiftSyntax stack overflow from crashing the main app.
  private func chunkSwiftWithSubprocess(text: String, filePath: String) -> ChunkingResult {
    guard let cliPath = astChunkerCLIPath else {
      print("[HybridChunker] Swift CLI not available, falling back to line chunking")
      return ChunkingResult(
        chunks: lineChunker.chunk(text: text),
        usedAST: false,
        failureType: nil,
        failureMessage: "CLI not available"
      )
    }
    
    // Write source to temp file (CLI reads from file)
    let tempDir = FileManager.default.temporaryDirectory
    let tempFile = tempDir.appendingPathComponent("swift_\(UUID().uuidString).swift")
    
    do {
      try text.write(to: tempFile, atomically: true, encoding: .utf8)
    } catch {
      print("[HybridChunker] Failed to write temp file: \(error)")
      return ChunkingResult(
        chunks: lineChunker.chunk(text: text),
        usedAST: false,
        failureType: .parseError,
        failureMessage: "Failed to write temp file"
      )
    }
    
    defer {
      try? FileManager.default.removeItem(at: tempFile)
    }
    
    // Run ast-chunker-cli --json <file>
    let process = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()
    
    process.executableURL = URL(fileURLWithPath: cliPath)
    process.arguments = ["--json", tempFile.path]
    process.standardOutput = pipe
    process.standardError = errorPipe
    
    // Async pipe reading to prevent deadlock on large output
    final class DataBox: @unchecked Sendable {
      var data = Data()
    }
    let outputBox = DataBox()
    let errorBox = DataBox()
    let group = DispatchGroup()
    
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      outputBox.data = pipe.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      errorBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    
    do {
      try process.run()
      
      // Wait with timeout
      let result = group.wait(timeout: .now() + swiftSubprocessTimeout)
      
      if result == .timedOut {
        process.terminate()
        let fileName = (filePath as NSString).lastPathComponent
        print("[HybridChunker] Swift CLI timeout for \(fileName)")
        return ChunkingResult(
          chunks: lineChunker.chunk(text: text),
          usedAST: false,
          failureType: .timeout,
          failureMessage: "Subprocess timeout"
        )
      }
      
      process.waitUntilExit()
      
      let outputData = outputBox.data
      let errorData = errorBox.data

      if process.terminationStatus != 0 {
        let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        let fileName = (filePath as NSString).lastPathComponent
        print("[HybridChunker] Swift CLI failed for \(fileName): exit \(process.terminationStatus), \(errorMsg)")
        return ChunkingResult(
          chunks: lineChunker.chunk(text: text),
          usedAST: false,
          failureType: .crash,
          failureMessage: "CLI exit \(process.terminationStatus)"
        )
      }
      
      // Parse JSON output
      let decoder = JSONDecoder()
      let cliChunks = try decoder.decode([CLIChunk].self, from: outputData)
      
      // Log metadata stats for debugging
      let fileName = (filePath as NSString).lastPathComponent
      let chunksWithMeta = cliChunks.filter { $0.metadata != nil }.count
      print("[HybridChunker] Swift CLI for \(fileName): \(cliChunks.count) chunks, \(chunksWithMeta) with metadata")
      
      if cliChunks.isEmpty {
        return ChunkingResult(
          chunks: lineChunker.chunk(text: text),
          usedAST: false,
          failureType: .parseError,
          failureMessage: "CLI returned empty chunks"
        )
      }
      
      // Convert to LocalRAGChunk
      let chunks = cliChunks.map { cli in
        LocalRAGChunk(
          startLine: cli.startLine,
          endLine: cli.endLine,
          text: cli.text,
          tokenCount: cli.tokenCount,
          constructType: cli.constructType,
          constructName: cli.constructName,
          metadata: cli.metadata
        )
      }
      
      print("[HybridChunker] Swift subprocess: \(chunks.count) chunks for \(fileName)")
      
      return ChunkingResult(
        chunks: chunks,
        usedAST: true,
        failureType: nil,
        failureMessage: nil
      )
      
    } catch {
      let fileName = (filePath as NSString).lastPathComponent
      print("[HybridChunker] Swift CLI error for \(fileName): \(error)")
      return ChunkingResult(
        chunks: lineChunker.chunk(text: text),
        usedAST: false,
        failureType: .parseError,
        failureMessage: error.localizedDescription
      )
    }
  }
  
  // MARK: - TypeScript/JavaScript JSCore Chunking
  
  /// Chunk TypeScript/JavaScript using JavaScriptCore (issue #173)
  private func chunkJSWithJSCore(text: String, language: String, filePath: String) -> ChunkingResult {
    let fileName = (filePath as NSString).lastPathComponent
    
    // Map language string to file extension for JSCore chunker
    let ext = mapLanguageToExtension(language, filePath: filePath)
    
    // Get chunks from JSCore chunker
    let astChunks = jsChunker.chunk(source: text, language: ext)
    
    if astChunks.isEmpty {
      print("[HybridChunker] JSCore returned empty for \(fileName)")
      return ChunkingResult(
        chunks: lineChunker.chunk(text: text),
        usedAST: false,
        failureType: .parseError,
        failureMessage: "JSCore returned empty"
      )
    }
    
    // Convert ASTChunk to LocalRAGChunk
    let chunks = astChunks.map { chunk in
      LocalRAGChunk(
        startLine: chunk.startLine,
        endLine: chunk.endLine,
        text: chunk.text,
        tokenCount: chunk.estimatedTokenCount,
        constructType: chunk.constructType.rawValue,
        constructName: chunk.constructName,
        metadata: chunk.metadata.toJSON()
      )
    }
    
    print("[HybridChunker] JSCore: \(chunks.count) chunks for \(fileName)")
    
    return ChunkingResult(
      chunks: chunks,
      usedAST: true,
      failureType: nil,
      failureMessage: nil
    )
  }
  
  /// Map language string to file extension for JSCore chunker
  private func mapLanguageToExtension(_ language: String, filePath: String) -> String {
    // Try to get actual extension from file path
    let ext = (filePath as NSString).pathExtension.lowercased()
    if !ext.isEmpty && ["ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs", "gts", "gjs"].contains(ext) {
      return ext
    }
    // Fall back to language name
    switch language {
    case "TypeScript":
      return "ts"
    case "JavaScript":
      return "js"
    default:
      return "ts"
    }
  }
  
  private func chunkWithAST(text: String, language: String) -> [LocalRAGChunk] {
    let astChunks: [ASTChunk]
    
    switch language {
    case "Swift":
      // Swift uses subprocess chunking via chunkSwiftWithSubprocess()
      // This path should not be reached, but handle gracefully
      print("[HybridChunker] Warning: Swift should use subprocess path")
      return lineChunker.chunk(text: text)
    case "Ruby":
      if let rubyChunker = rubyChunker {
        astChunks = rubyChunker.chunk(source: text)
      } else {
        return lineChunker.chunk(text: text)
      }
    case "Glimmer TypeScript", "Glimmer JavaScript":
      // GTS/GJS: Use JSCore chunker for proper class-level AST chunks (issue #173)
      // The JSCore chunker handles <template> preprocessing via regex
      let lang = language == "Glimmer TypeScript" ? "gts" : "gjs"
      astChunks = jsChunker.chunk(source: text, language: lang)
    case "TypeScript", "JavaScript":
      // Use JSCore chunker for TypeScript/JavaScript (issue #173)
      astChunks = jsChunker.chunk(source: text, language: language == "TypeScript" ? "ts" : "js")
    default:
      // Should not reach here if astSupportedLanguages is correct
      return lineChunker.chunk(text: text)
    }
    
    // Convert ASTChunk to LocalRAGChunk, preserving metadata
    return astChunks.map { astChunk in
      LocalRAGChunk(
        startLine: astChunk.startLine,
        endLine: astChunk.endLine,
        text: astChunk.text,
        tokenCount: astChunk.estimatedTokenCount,
        constructType: astChunk.constructType.rawValue,
        constructName: astChunk.constructName,
        metadata: astChunk.metadata.toJSON()
      )
    }
  }
}

struct LocalRAGFileScanner {
  var maxFileBytes: Int = 1_000_000
  var excludedDirectories: Set<String> = [
    ".git",
    ".build",
    ".swiftpm",
    "build",
    "dist",
    "DerivedData",
    "node_modules",
    "coverage",
    "tmp",
    "Carthage",
    ".turbo",
    "__snapshots__",
    "vendor"
  ]
  
  /// Files that are always excluded regardless of extension
  private let excludedFiles: Set<String> = [
    "pnpm-lock.yaml",
    "package-lock.json",
    "yarn.lock",
    "Gemfile.lock",
    "Podfile.lock",
    "Cargo.lock",
    "composer.lock",
    "poetry.lock"
  ]
  
  /// File patterns to exclude (checked against filename)
  private let excludedPatterns: [String] = [
    ".min.",      // Minified files: *.min.js, *.min.css, *.min.mjs
    ".bundle.",   // Bundled files
    ".chunk.",    // Webpack chunks
    "-bundle.",
    ".packed."
  ]

  func scan(rootURL: URL, excludingRoots: [String] = []) -> [LocalRAGFileCandidate] {
    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    let ignorePatterns = loadIgnorePatterns(rootURL: rootURL)
    var results: [LocalRAGFileCandidate] = []

    for case let fileURL as URL in enumerator {
      if shouldSkip(url: fileURL, rootURL: rootURL, ignorePatterns: ignorePatterns, excludedRoots: excludingRoots) {
        enumerator.skipDescendants()
        continue
      }

      guard isTextFile(url: fileURL) else { continue }

      let size = fileSize(for: fileURL)
      let byteCount = min(max(0, size), maxFileBytes)
      guard byteCount > 0 else { continue }
      results.append(
        LocalRAGFileCandidate(
          path: fileURL.path,
          byteCount: byteCount,
          language: languageFor(url: fileURL)
        )
      )
    }

    return results
  }

  private func shouldSkip(url: URL, rootURL: URL, ignorePatterns: [String], excludedRoots: [String]) -> Bool {
    let lastComponent = url.lastPathComponent
    let path = url.path
    for root in excludedRoots {
      if path == root || path.hasPrefix(root + "/") {
        return true
      }
    }
    // Skip excluded directories
    if excludedDirectories.contains(lastComponent) {
      return true
    }
    // Skip excluded files (lock files, etc.)
    if excludedFiles.contains(lastComponent) {
      return true
    }
    // Skip minified and bundled files
    let lowercasedName = lastComponent.lowercased()
    for pattern in excludedPatterns {
      if lowercasedName.contains(pattern) {
        return true
      }
    }
    if matchesIgnore(url: url, rootURL: rootURL, patterns: ignorePatterns) {
      return true
    }
    return false
  }

  private func loadIgnorePatterns(rootURL: URL) -> [String] {
    let ignoreURL = rootURL.appendingPathComponent(".ragignore")
    guard let contents = try? String(contentsOf: ignoreURL, encoding: .utf8) else {
      return []
    }
    return contents
      .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
  }

  private func matchesIgnore(url: URL, rootURL: URL, patterns: [String]) -> Bool {
    guard !patterns.isEmpty else { return false }
    let path = url.path
    let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    let fileName = url.lastPathComponent

    for pattern in patterns {
      if fnmatch(pattern, relative, 0) == 0 { return true }
      if fnmatch(pattern, fileName, 0) == 0 { return true }
      if pattern.hasSuffix("/") && relative.hasPrefix(pattern) { return true }
    }
    return false
  }

  private func isTextFile(url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if ext.isEmpty { return false }
    return Self.supportedExtensions.contains(ext)
  }

  /// Comprehensive list of code and config file extensions for RAG indexing.
  /// Organized by category for maintainability.
  private static let supportedExtensions: Set<String> = {
    var extensions = Set<String>()

    // Swift / Apple
    extensions.formUnion(["swift"])

    // JavaScript / TypeScript ecosystem
    extensions.formUnion(["js", "ts", "tsx", "jsx", "mjs", "cjs", "mts", "cts"])

    // Ember / Glimmer (CRITICAL for tio-front-end)
    extensions.formUnion(["gts", "gjs", "hbs"])

    // Web frameworks
    extensions.formUnion(["vue", "svelte", "astro"])

    // Ruby
    extensions.formUnion(["rb", "rake", "gemspec", "erb"])

    // Python
    extensions.formUnion(["py", "pyi", "pyx"])

    // Systems languages
    extensions.formUnion(["rs", "go", "c", "h", "cpp", "hpp", "cc", "cxx"])

    // JVM languages
    extensions.formUnion(["java", "kt", "kts", "scala", "groovy", "gradle"])

    // Markup & documentation
    extensions.formUnion(["md", "mdx", "txt", "rst", "adoc"])

    // Data formats
    extensions.formUnion(["json", "jsonc", "json5", "yml", "yaml", "toml", "xml", "plist"])

    // Styles
    extensions.formUnion(["css", "scss", "sass", "less", "styl"])

    // HTML / templates
    extensions.formUnion(["html", "htm", "ejs", "njk", "liquid"])

    // Shell / scripts
    extensions.formUnion(["sh", "bash", "zsh", "fish", "ps1", "bat", "cmd"])

    // Database / query
    extensions.formUnion(["sql", "graphql", "gql", "prisma"])

    // Infrastructure / DevOps
    extensions.formUnion(["dockerfile", "tf", "hcl", "proto"])

    // Config files
    extensions.formUnion(["cfg", "ini", "conf", "env"])

    return extensions
  }()

  func loadFile(candidate: LocalRAGFileCandidate) -> LocalRAGScannedFile? {
    let url = URL(fileURLWithPath: candidate.path)
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
      return nil
    }

    let slice = data.prefix(candidate.byteCount)
    guard let text = String(data: slice, encoding: .utf8) else { return nil }
    let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count

    return LocalRAGScannedFile(
      path: candidate.path,
      text: text,
      lineCount: lineCount,
      byteCount: candidate.byteCount,
      language: candidate.language
    )
  }

  private func fileSize(for url: URL) -> Int {
    if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
       let size = values.fileSize {
      return size
    }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let fileSize = attrs[.size] as? NSNumber {
      return fileSize.intValue
    }
    return 0
  }

  private func languageFor(url: URL) -> String {
    switch url.pathExtension.lowercased() {
    // Swift / Apple
    case "swift": return "Swift"

    // JavaScript / TypeScript ecosystem
    case "js", "jsx", "mjs", "cjs": return "JavaScript"
    case "ts", "tsx", "mts", "cts": return "TypeScript"

    // Ember / Glimmer
    case "gts": return "Glimmer TypeScript"
    case "gjs": return "Glimmer JavaScript"
    case "hbs": return "Handlebars"

    // Web frameworks
    case "vue": return "Vue"
    case "svelte": return "Svelte"
    case "astro": return "Astro"

    // Ruby
    case "rb", "rake", "gemspec": return "Ruby"
    case "erb": return "ERB"

    // Python
    case "py", "pyi", "pyx": return "Python"

    // Systems languages
    case "rs": return "Rust"
    case "go": return "Go"
    case "c", "h": return "C"
    case "cpp", "hpp", "cc", "cxx": return "C++"

    // JVM languages
    case "java": return "Java"
    case "kt", "kts": return "Kotlin"
    case "scala": return "Scala"
    case "groovy", "gradle": return "Groovy"

    // Markup & documentation
    case "md", "mdx": return "Markdown"
    case "txt": return "Text"
    case "rst": return "reStructuredText"
    case "adoc": return "AsciiDoc"

    // Data formats
    case "json", "jsonc", "json5": return "JSON"
    case "yml", "yaml": return "YAML"
    case "toml": return "TOML"
    case "xml", "plist": return "XML"

    // Styles
    case "css", "scss", "sass", "less", "styl": return "CSS"

    // HTML / templates
    case "html", "htm": return "HTML"
    case "ejs", "njk", "liquid": return "Template"

    // Shell / scripts
    case "sh", "bash", "zsh", "fish": return "Shell"
    case "ps1": return "PowerShell"
    case "bat", "cmd": return "Batch"

    // Database / query
    case "sql": return "SQL"
    case "graphql", "gql": return "GraphQL"
    case "prisma": return "Prisma"

    // Infrastructure / DevOps
    case "dockerfile": return "Dockerfile"
    case "tf", "hcl": return "Terraform"
    case "proto": return "Protocol Buffers"

    // Config files
    case "cfg", "ini", "conf", "env": return "Config"

    default: return url.pathExtension.uppercased()
    }
  }
}

/// Lightweight struct for decoding chunk metadata to extract facets
private struct ChunkMetadataForFacets: Decodable {
  let frameworks: [String]?
  let usesEmberConcurrency: Bool?
  let hasTemplate: Bool?
}

actor LocalRAGStore {
  struct Status: Sendable {
    let dbPath: String
    let exists: Bool
    let schemaVersion: Int
    let extensionLoaded: Bool
    let lastInitializedAt: Date?
    let providerName: String
    let embeddingModelName: String
    let embeddingDimensions: Int
    let coreMLModelPresent: Bool
    let coreMLVocabPresent: Bool
    
    /// Returns user-facing warning messages for missing Core ML assets.
    /// Extracted from duplicated UI logic in LocalRAGDashboardView.swift lines ~653-658.
    func assetWarnings() -> [String] {
      var warnings: [String] = []
      if !coreMLModelPresent || !coreMLVocabPresent {
        warnings.append("model/vocab missing — falling back to system embeddings")
      }
      return warnings
    }
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
    case workspaceDetected(rootPath: String, repoPaths: [String])

    var errorDescription: String? {
      switch self {
      case .sqlite(let message):
        return message
      case .invalidPath:
        return "Invalid database path"
      case .workspaceDetected(let rootPath, let repoPaths):
        let preview = repoPaths.prefix(6).joined(separator: "\n")
        let suffix = repoPaths.count > 6 ? "\n…" : ""
        return "Workspace detected at \(rootPath). Index sub-repos instead:\n\(preview)\(suffix)"
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
  private let chunker = HybridChunker()
  private let embeddingProvider: LocalRAGEmbeddingProvider
  private var healthTracker = ChunkingHealthTracker()

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

  private func detectWorkspaceRepos(rootURL: URL) -> [String] {
    let resolvedRoot = rootURL.resolvingSymlinksInPath()
    guard let enumerator = FileManager.default.enumerator(
      at: resolvedRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    let excluded = Set([".git", ".build", ".swiftpm", "build", "dist", "DerivedData", "node_modules", "coverage", "tmp", "Carthage", ".turbo", "__snapshots__", "vendor"])
    let baseDepth = resolvedRoot.pathComponents.count
    var repos: [String] = []

    for case let url as URL in enumerator {
      let depth = url.pathComponents.count - baseDepth
      if depth <= 0 { continue }
      if depth > 4 {
        enumerator.skipDescendants()
        continue
      }
      if excluded.contains(url.lastPathComponent) {
        enumerator.skipDescendants()
        continue
      }
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
      if isGitRepo(at: url) {
        repos.append(url.path)
        enumerator.skipDescendants()
      }
    }

    return Array(Set(repos)).sorted()
  }

  private func isGitRepo(at url: URL) -> Bool {
    let gitURL = url.appendingPathComponent(".git")
    var isDir = ObjCBool(false)
    let exists = FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDir)
    if exists { return true }
    return FileManager.default.fileExists(atPath: gitURL.path)
  }

  private func logMemory(_ label: String) {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }

    guard result == KERN_SUCCESS else {
      print("[RAG] Memory \(label): unavailable (kern \(result))")
      return
    }

    let rss = ByteCountFormatter.string(fromByteCount: Int64(info.resident_size), countStyle: .memory)
    let vms = ByteCountFormatter.string(fromByteCount: Int64(info.virtual_size), countStyle: .memory)
    print("[RAG] Memory \(label): RSS \(rss), VMS \(vms)")
    let snapshot = MLX.Memory.snapshot()
    let active = ByteCountFormatter.string(fromByteCount: Int64(snapshot.activeMemory), countStyle: .memory)
    let cache = ByteCountFormatter.string(fromByteCount: Int64(snapshot.cacheMemory), countStyle: .memory)
    print("[RAG] MLX Memory \(label): active \(active), cache \(cache)")
  }


  func status() -> Status {
    let modelsURLs = candidateModelDirectories(primary: dbURL.deletingLastPathComponent())
    let modelPresent = modelsURLs.contains { url in
      FileManager.default.fileExists(atPath: url.appendingPathComponent("codebert-base-256.mlmodelc").path)
    }
    let vocabPresent = modelsURLs.contains { url in
      FileManager.default.fileExists(atPath: url.appendingPathComponent("codebert-base.vocab.json").path)
    }
    return Status(
      dbPath: dbURL.path,
      exists: FileManager.default.fileExists(atPath: dbURL.path),
      schemaVersion: schemaVersion,
      extensionLoaded: extensionLoaded,
      lastInitializedAt: lastInitializedAt,
      providerName: String(describing: type(of: embeddingProvider)),
      embeddingModelName: embeddingProvider.modelName,
      embeddingDimensions: embeddingProvider.dimensions,
      coreMLModelPresent: modelPresent,
      coreMLVocabPresent: vocabPresent
    )
  }
  
  /// Get chunking health information including failures
  struct ChunkingHealthInfo: Sendable {
    let totalFailures: Int
    let failuresByLanguage: [String: Int]
    let recentFailures: [(path: String, language: String, errorType: String, timestamp: Date)]
  }
  
  func getChunkingHealth() -> ChunkingHealthInfo {
    let failures = healthTracker.getFailures()
    let byLanguage = healthTracker.failuresByLanguage()
    let recent = failures.suffix(20).map { (
      path: $0.filePath,
      language: $0.language,
      errorType: $0.errorType.rawValue,
      timestamp: $0.timestamp
    )}
    return ChunkingHealthInfo(
      totalFailures: failures.count,
      failuresByLanguage: byLanguage,
      recentFailures: recent
    )
  }
  
  /// Clear chunking failures (useful after code changes)
  func clearChunkingFailures() {
    healthTracker = ChunkingHealthTracker()
    print("[RAG] Cleared all chunking failures")
  }

  private func candidateModelDirectories(primary: URL) -> [URL] {
    var directories: [URL] = [primary]
    if let bundleId = Bundle.main.bundleIdentifier {
      let containerBase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers")
        .appendingPathComponent(bundleId)
        .appendingPathComponent("Data/Library/Application Support")
      directories.append(containerBase.appendingPathComponent("Peel/RAG", isDirectory: true))
    }

    var seen = Set<String>()
    return directories
      .map { $0.appendingPathComponent("Models", isDirectory: true) }
      .filter { url in
        let path = url.standardizedFileURL.path
        guard !seen.contains(path) else { return false }
        seen.insert(path)
        return true
      }
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

  struct RepoInfo {
    let id: String
    let name: String
    let rootPath: String
    let lastIndexedAt: Date?
    let fileCount: Int
    let chunkCount: Int
  }

  func listRepos() throws -> [RepoInfo] {
    try openIfNeeded()
    try ensureSchema()

    let sql = """
      SELECT r.id, r.name, r.root_path, r.last_indexed_at,
             (SELECT COUNT(*) FROM files WHERE repo_id = r.id) as file_count,
             (SELECT COUNT(*) FROM chunks c JOIN files f ON c.file_id = f.id WHERE f.repo_id = r.id) as chunk_count
      FROM repos r
      ORDER BY r.name
      """

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

    var repos: [RepoInfo] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let id = String(cString: sqlite3_column_text(statement, 0))
      let name = String(cString: sqlite3_column_text(statement, 1))
      let rootPath = String(cString: sqlite3_column_text(statement, 2))
      let lastIndexedAtStr = sqlite3_column_text(statement, 3).map { String(cString: $0) }
      let lastIndexedAt = lastIndexedAtStr.flatMap { dateFormatter.date(from: $0) }
      let fileCount = Int(sqlite3_column_int(statement, 4))
      let chunkCount = Int(sqlite3_column_int(statement, 5))

      repos.append(RepoInfo(
        id: id,
        name: name,
        rootPath: rootPath,
        lastIndexedAt: lastIndexedAt,
        fileCount: fileCount,
        chunkCount: chunkCount
      ))
    }
    return repos
  }

  func deleteRepo(repoId: String? = nil, repoPath: String? = nil) throws -> Int {
    try openIfNeeded()
    try ensureSchema()

    guard let db else {
      throw LocalRAGError.sqlite("Database not initialized")
    }

    // Determine target repo ID
    let targetId: String
    if let repoId {
      targetId = repoId
    } else if let repoPath {
      targetId = stableId(for: repoPath)
    } else {
      throw LocalRAGError.sqlite("Must provide repoId or repoPath")
    }

    // Count files before deletion
    let countSql = "SELECT COUNT(*) FROM files WHERE repo_id = ?"
    var countStmt: OpaquePointer?
    sqlite3_prepare_v2(db, countSql, -1, &countStmt, nil)
    defer { sqlite3_finalize(countStmt) }
    sqlite3_bind_text(countStmt, 1, targetId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    var deletedFiles = 0
    if sqlite3_step(countStmt) == SQLITE_ROW {
      deletedFiles = Int(sqlite3_column_int(countStmt, 0))
    }

    // Delete orphaned embeddings (chunks that belong to files of this repo)
    let deleteEmbeddingsSql = """
      DELETE FROM embeddings WHERE chunk_id IN (
        SELECT c.id FROM chunks c
        JOIN files f ON c.file_id = f.id
        WHERE f.repo_id = ?
      )
      """
    var embStmt: OpaquePointer?
    sqlite3_prepare_v2(db, deleteEmbeddingsSql, -1, &embStmt, nil)
    defer { sqlite3_finalize(embStmt) }
    sqlite3_bind_text(embStmt, 1, targetId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_step(embStmt)

    // Delete chunks
    let deleteChunksSql = """
      DELETE FROM chunks WHERE file_id IN (
        SELECT id FROM files WHERE repo_id = ?
      )
      """
    var chunkStmt: OpaquePointer?
    sqlite3_prepare_v2(db, deleteChunksSql, -1, &chunkStmt, nil)
    defer { sqlite3_finalize(chunkStmt) }
    sqlite3_bind_text(chunkStmt, 1, targetId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_step(chunkStmt)

    // Delete files
    let deleteFilesSql = "DELETE FROM files WHERE repo_id = ?"
    var fileStmt: OpaquePointer?
    sqlite3_prepare_v2(db, deleteFilesSql, -1, &fileStmt, nil)
    defer { sqlite3_finalize(fileStmt) }
    sqlite3_bind_text(fileStmt, 1, targetId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_step(fileStmt)

    // Delete repo
    let deleteRepoSql = "DELETE FROM repos WHERE id = ?"
    var repoStmt: OpaquePointer?
    sqlite3_prepare_v2(db, deleteRepoSql, -1, &repoStmt, nil)
    defer { sqlite3_finalize(repoStmt) }
    sqlite3_bind_text(repoStmt, 1, targetId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_step(repoStmt)

    return deletedFiles
  }

  /// Index a repository without progress reporting
  func indexRepository(path: String) async throws -> LocalRAGIndexReport {
    try await indexRepository(path: path, forceReindex: false, allowWorkspace: false, excludeSubrepos: true, progress: nil)
  }
  
  /// Index a repository with progress reporting callback
  func indexRepository(
    path: String,
    forceReindex: Bool = false,
    allowWorkspace: Bool = false,
    excludeSubrepos: Bool = true,
    progress: LocalRAGProgressCallback?
  ) async throws -> LocalRAGIndexReport {
    let startTime = Date()
    _ = try initialize()
    logMemory("index start")

    let repoURL = URL(fileURLWithPath: path)
    let workspaceRepos = detectWorkspaceRepos(rootURL: repoURL)
    if !allowWorkspace {
      if workspaceRepos.count >= 2 {
        throw LocalRAGError.workspaceDetected(rootPath: path, repoPaths: workspaceRepos)
      }
    }
    let excludedRoots = (allowWorkspace && excludeSubrepos) ? workspaceRepos : []
    let scannedFiles = scanner.scan(rootURL: repoURL, excludingRoots: excludedRoots)
    logMemory("after scan \(scannedFiles.count) files")
    progress?(.scanning(fileCount: scannedFiles.count))
    
    let repoId = stableId(for: path)
    let repoName = repoURL.lastPathComponent
    let now = dateFormatter.string(from: Date())

    try upsertRepo(id: repoId, name: repoName, rootPath: path, lastIndexedAt: now)

    var chunkCount = 0
    var bytesScanned = 0
    var embeddingCount = 0
    var embeddingDurationMs = 0
    var skippedUnchanged = 0
    
    // AST chunking stats
    var astFilesChunked = 0
    var lineFilesChunked = 0
    var chunkingFailures = 0

    struct MissingEmbedding {
      let textHash: String
      let text: String
    }

    var filesIndexed = 0
    var seenTextHashes = Set<String>()

    // Batch embed missing texts in small chunks to avoid GPU memory issues
    // MLX Metal backend can crash with large batches, so we limit to 4 texts per batch
    // The quantized model (4bit-DWQ) has memory issues with larger batches
    var embeddingCache: [String: [Float]] = [:]
    let embeddingBatchSize = 4

    for (fileIndex, candidate) in scannedFiles.enumerated() {
      progress?(.analyzing(current: fileIndex + 1, total: scannedFiles.count, fileName: URL(fileURLWithPath: candidate.path).lastPathComponent))
      
      // Log memory more frequently during debugging
      if fileIndex % 10 == 0 {
        logMemory("analyzing \(fileIndex + 1)/\(scannedFiles.count): \(URL(fileURLWithPath: candidate.path).lastPathComponent)")
      }

      guard let file = scanner.loadFile(candidate: candidate) else { continue }
      
      // Compute relative path for storage (portable across machines)
      let relativePath = file.path.hasPrefix(path + "/") 
        ? String(file.path.dropFirst(path.count + 1))
        : file.path

      let fileId = stableId(for: "\(repoId):\(relativePath)")
      let fileHash = stableId(for: file.text)

      // Incremental indexing: skip unchanged files (unless forceReindex is true)
      if !forceReindex {
        let existingHash = try fetchFileHashByPath(repoId: repoId, path: relativePath)
        if let existingHash, existingHash == fileHash {
          skippedUnchanged += 1
          bytesScanned += file.byteCount
          continue
        }
      }

      // Use safe chunking with health tracking
      let chunkResult = chunker.chunkSafe(
        text: file.text,
        language: file.language,
        filePath: relativePath,
        fileHash: fileHash,
        healthTracker: healthTracker
      )
      
      // Track chunking stats
      if chunkResult.usedAST {
        astFilesChunked += 1
      } else {
        lineFilesChunked += 1
      }
      
      // Record any failures to health tracker for future runs
      if let failureType = chunkResult.failureType {
        chunkingFailures += 1
        healthTracker.recordFailure(
          filePath: relativePath,
          language: file.language,
          errorType: failureType,
          errorMessage: chunkResult.failureMessage,
          fileHash: fileHash
        )
      }
      
      let chunks = chunkResult.chunks
      let chunkHashes = chunks.map { stableId(for: $0.text) }

      // Find missing embeddings for this file
      var missingEmbeddings: [MissingEmbedding] = []
      for (index, textHash) in chunkHashes.enumerated() {
        if !seenTextHashes.contains(textHash) {
          let cached = try fetchCachedEmbedding(textHash: textHash)
          if cached == nil {
            missingEmbeddings.append(MissingEmbedding(textHash: textHash, text: chunks[index].text))
          }
          seenTextHashes.insert(textHash)
        }
      }

      if !missingEmbeddings.isEmpty {
        progress?(.embedding(current: 0, total: missingEmbeddings.count))
        let embedStart = Date()

        for batchStart in stride(from: 0, to: missingEmbeddings.count, by: embeddingBatchSize) {
          let batchEnd = min(batchStart + embeddingBatchSize, missingEmbeddings.count)
          let batchTexts = missingEmbeddings[batchStart..<batchEnd].map { $0.text }

          let batchEmbeddings = try await embeddingProvider.embed(texts: batchTexts)
          embeddingCount += batchEmbeddings.count

          for (offset, vector) in batchEmbeddings.enumerated() {
            let missing = missingEmbeddings[batchStart + offset]
            embeddingCache[missing.textHash] = vector
            if !vector.isEmpty {
              try upsertCacheEmbedding(textHash: missing.textHash, vector: vector)
            }
          }

          progress?(.embedding(current: batchEnd, total: missingEmbeddings.count))

          if LocalRAGEmbeddingProviderFactory.mlxClearCacheAfterBatch {
            MLX.Memory.clearCache()
            let snapshot = MLX.Memory.snapshot()
            print("[RAG] MLX cache cleared. active=\(snapshot.activeMemory) cache=\(snapshot.cacheMemory)")
          }
        }

        let embedDuration = Int(Date().timeIntervalSince(embedStart) * 1000)
        embeddingDurationMs += embedDuration
        progress?(.embedding(current: missingEmbeddings.count, total: missingEmbeddings.count))
        if fileIndex % 50 == 0 {
          logMemory("after embedding \(fileIndex + 1)/\(scannedFiles.count)")
        }
      }

      progress?(.storing(current: filesIndexed + 1, total: scannedFiles.count))
      
      // Extract facets for filtering/grouping
      let modulePath = extractModulePath(from: relativePath)
      let featureTags = extractFeatureTags(from: relativePath, language: file.language, chunks: chunks)
      let featureTagsJson = featureTags.isEmpty ? nil : (try? JSONEncoder().encode(featureTags)).flatMap { String(data: $0, encoding: .utf8) }
      
      try upsertFile(
        id: fileId,
        repoId: repoId,
        path: relativePath,
        hash: fileHash,
        language: file.language,
        updatedAt: now,
        modulePath: modulePath,
        featureTags: featureTagsJson
      )
      try deleteChunks(for: fileId)

      for (index, chunk) in chunks.enumerated() {
        let chunkId = stableId(for: "\(fileId):\(chunk.startLine):\(chunk.endLine):\(chunk.text)")
        try upsertChunk(
          id: chunkId,
          fileId: fileId,
          startLine: chunk.startLine,
          endLine: chunk.endLine,
          text: chunk.text,
          tokenCount: chunk.tokenCount,
          constructType: chunk.constructType,
          constructName: chunk.constructName,
          metadata: chunk.metadata
        )

        let textHash = chunkHashes[index]
        let embedding: [Float]
        if let cached = embeddingCache[textHash] {
          embedding = cached
        } else if let dbCached = try fetchCachedEmbedding(textHash: textHash) {
          embedding = dbCached
        } else {
          embedding = []
        }

        if !embedding.isEmpty {
          try upsertEmbedding(chunkId: chunkId, vector: embedding)
        }
      }

      chunkCount += chunks.count
      bytesScanned += file.byteCount
      filesIndexed += 1
      embeddingCache.removeAll(keepingCapacity: true)
    }
    logMemory("index complete")
    
    // Log AST stats
    print("[RAG] AST stats: \(astFilesChunked) AST, \(lineFilesChunked) line-based, \(chunkingFailures) failures")

    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
    let report = LocalRAGIndexReport(
      repoId: repoId,
      repoPath: path,
      filesIndexed: filesIndexed,
      filesSkipped: skippedUnchanged,
      chunksIndexed: chunkCount,
      bytesScanned: bytesScanned,
      durationMs: durationMs,
      embeddingCount: embeddingCount,
      embeddingDurationMs: embeddingDurationMs,
      astFilesChunked: astFilesChunked,
      lineFilesChunked: lineFilesChunked,
      chunkingFailures: chunkingFailures
    )
    progress?(.complete(report: report))
    return report
  }

  func search(query: String, repoPath: String? = nil, limit: Int = 10, matchAll: Bool = true) async throws -> [LocalRAGSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }
    try openIfNeeded()

    // Split query into words for matching
    let words = trimmedQuery
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }

    // Build WHERE clause - search both text and construct_name
    // matchAll=true: all words must appear (AND)
    // matchAll=false: any word can appear (OR) - better for multi-concept queries
    var whereClauses = [String]()
    for _ in words {
      whereClauses.append("(chunks.text LIKE ? OR chunks.construct_name LIKE ?)")
    }
    
    let joinOperator = matchAll ? " AND " : " OR "

    let sqlBase = """
    SELECT repos.root_path || '/' || files.path, chunks.start_line, chunks.end_line, chunks.text,
           chunks.construct_type, chunks.construct_name, files.language, files.module_path, files.feature_tags
    FROM chunks
    JOIN files ON files.id = chunks.file_id
    JOIN repos ON repos.id = files.repo_id
    WHERE (\(whereClauses.joined(separator: joinOperator)))
    """

    let sql: String
    if repoPath != nil {
      sql = sqlBase + " AND repos.root_path = ? ORDER BY files.path LIMIT ?"
    } else {
      sql = sqlBase + " ORDER BY files.path LIMIT ?"
    }

    return try querySearchResults(sql: sql, withScore: false) { statement in
      var bindIndex: Int32 = 1
      for word in words {
        let pattern = "%\(word)%"
        bindText(statement, bindIndex, pattern)      // text LIKE
        bindText(statement, bindIndex + 1, pattern)  // construct_name LIKE
        bindIndex += 2
      }
      if let repoPath {
        bindText(statement, bindIndex, repoPath)
        bindIndex += 1
      }
      sqlite3_bind_int(statement, bindIndex, Int32(max(1, limit)))
    }
  }

  func clearEmbeddingCache() throws -> Int {
    try openIfNeeded()
    try ensureSchema()
    let cleared = try queryInt("SELECT COUNT(*) FROM cache_embeddings")
    try exec("DELETE FROM cache_embeddings")
    return cleared
  }
  
  // MARK: - Stats & Analytics
  
  /// Get construct type distribution for a repo
  func getConstructTypeStats(repoPath: String? = nil) throws -> [(type: String, count: Int)] {
    try openIfNeeded()
    
    let sql: String
    if repoPath != nil {
      sql = """
      SELECT COALESCE(c.construct_type, 'unknown') as type, COUNT(*) as cnt
      FROM chunks c
      JOIN files f ON c.file_id = f.id
      JOIN repos r ON f.repo_id = r.id
      WHERE r.root_path = ?
      GROUP BY type
      ORDER BY cnt DESC
      """
    } else {
      sql = """
      SELECT COALESCE(c.construct_type, 'unknown') as type, COUNT(*) as cnt
      FROM chunks c
      GROUP BY type
      ORDER BY cnt DESC
      """
    }
    
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw LocalRAGError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    
    if let repoPath {
      bindText(statement, 1, repoPath)
    }
    
    var stats: [(type: String, count: Int)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let type = String(cString: sqlite3_column_text(statement, 0))
      let count = Int(sqlite3_column_int(statement, 1))
      stats.append((type: type, count: count))
    }
    return stats
  }
  
  /// Facet counts for filtering/grouping search results
  struct FacetCounts: Sendable {
    let modulePaths: [(path: String, count: Int)]
    let featureTags: [(tag: String, count: Int)]
    let languages: [(language: String, count: Int)]
    let constructTypes: [(type: String, count: Int)]
  }
  
  /// Get facet counts for a repository or all repositories
  func getFacets(repoPath: String? = nil) throws -> FacetCounts {
    try openIfNeeded()
    
    // Module paths
    let modulePathsSql: String
    if repoPath != nil {
      modulePathsSql = """
      SELECT f.module_path, COUNT(*) as cnt
      FROM files f
      JOIN repos r ON f.repo_id = r.id
      WHERE r.root_path = ? AND f.module_path IS NOT NULL
      GROUP BY f.module_path
      ORDER BY cnt DESC
      """
    } else {
      modulePathsSql = """
      SELECT f.module_path, COUNT(*) as cnt
      FROM files f
      WHERE f.module_path IS NOT NULL
      GROUP BY f.module_path
      ORDER BY cnt DESC
      """
    }
    let modulePaths = try queryFacetCounts(sql: modulePathsSql, repoPath: repoPath)
    
    // Feature tags (need to parse JSON and aggregate)
    let featureTags = try queryFeatureTagCounts(repoPath: repoPath)
    
    // Languages
    let languagesSql: String
    if repoPath != nil {
      languagesSql = """
      SELECT f.language, COUNT(*) as cnt
      FROM files f
      JOIN repos r ON f.repo_id = r.id
      WHERE r.root_path = ? AND f.language IS NOT NULL
      GROUP BY f.language
      ORDER BY cnt DESC
      """
    } else {
      languagesSql = """
      SELECT f.language, COUNT(*) as cnt
      FROM files f
      WHERE f.language IS NOT NULL
      GROUP BY f.language
      ORDER BY cnt DESC
      """
    }
    let languages = try queryFacetCounts(sql: languagesSql, repoPath: repoPath)
    
    // Construct types
    let constructTypesSql: String
    if repoPath != nil {
      constructTypesSql = """
      SELECT COALESCE(c.construct_type, 'unknown'), COUNT(*) as cnt
      FROM chunks c
      JOIN files f ON c.file_id = f.id
      JOIN repos r ON f.repo_id = r.id
      WHERE r.root_path = ?
      GROUP BY c.construct_type
      ORDER BY cnt DESC
      """
    } else {
      constructTypesSql = """
      SELECT COALESCE(c.construct_type, 'unknown'), COUNT(*) as cnt
      FROM chunks c
      GROUP BY c.construct_type
      ORDER BY cnt DESC
      """
    }
    let constructTypes = try queryFacetCounts(sql: constructTypesSql, repoPath: repoPath)
    
    return FacetCounts(
      modulePaths: modulePaths.map { ($0.0, $0.1) },
      featureTags: featureTags,
      languages: languages.map { ($0.0, $0.1) },
      constructTypes: constructTypes.map { ($0.0, $0.1) }
    )
  }
  
  private func queryFacetCounts(sql: String, repoPath: String?) throws -> [(String, Int)] {
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw LocalRAGError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    
    if let repoPath {
      bindText(statement, 1, repoPath)
    }
    
    var counts: [(String, Int)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let value = String(cString: sqlite3_column_text(statement, 0))
      let count = Int(sqlite3_column_int(statement, 1))
      counts.append((value, count))
    }
    return counts
  }
  
  private func queryFeatureTagCounts(repoPath: String?) throws -> [(tag: String, count: Int)] {
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    let sql: String
    if repoPath != nil {
      sql = """
      SELECT f.feature_tags
      FROM files f
      JOIN repos r ON f.repo_id = r.id
      WHERE r.root_path = ? AND f.feature_tags IS NOT NULL
      """
    } else {
      sql = """
      SELECT feature_tags FROM files WHERE feature_tags IS NOT NULL
      """
    }
    
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw LocalRAGError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    
    if let repoPath {
      bindText(statement, 1, repoPath)
    }
    
    var tagCounts: [String: Int] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      let json = String(cString: sqlite3_column_text(statement, 0))
      if let data = json.data(using: .utf8),
         let tags = try? JSONDecoder().decode([String].self, from: data) {
        for tag in tags {
          tagCounts[tag, default: 0] += 1
        }
      }
    }
    
    return tagCounts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
  }
  
  /// Get largest files/chunks for a repo (useful for finding refactor targets)
  func getLargeFiles(repoPath: String? = nil, limit: Int = 20) throws -> [(path: String, chunkCount: Int, totalLines: Int, language: String?)] {
    try openIfNeeded()
    
    let sql: String
    if repoPath != nil {
      sql = """
      SELECT r.root_path || '/' || f.path as full_path, 
             COUNT(*) as chunk_count, 
             SUM(c.end_line - c.start_line) as total_lines,
             f.language
      FROM chunks c
      JOIN files f ON c.file_id = f.id
      JOIN repos r ON f.repo_id = r.id
      WHERE r.root_path = ?
      GROUP BY f.id
      ORDER BY total_lines DESC
      LIMIT ?
      """
    } else {
      sql = """
      SELECT r.root_path || '/' || f.path as full_path, 
             COUNT(*) as chunk_count, 
             SUM(c.end_line - c.start_line) as total_lines,
             f.language
      FROM chunks c
      JOIN files f ON c.file_id = f.id
      JOIN repos r ON f.repo_id = r.id
      GROUP BY f.id
      ORDER BY total_lines DESC
      LIMIT ?
      """
    }
    
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw LocalRAGError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    
    if let repoPath {
      bindText(statement, 1, repoPath)
      sqlite3_bind_int(statement, 2, Int32(limit))
    } else {
      sqlite3_bind_int(statement, 1, Int32(limit))
    }
    
    var files: [(path: String, chunkCount: Int, totalLines: Int, language: String?)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let path = String(cString: sqlite3_column_text(statement, 0))
      let chunkCount = Int(sqlite3_column_int(statement, 1))
      let totalLines = Int(sqlite3_column_int(statement, 2))
      let language: String? = sqlite3_column_type(statement, 3) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 3)) : nil
      files.append((path: path, chunkCount: chunkCount, totalLines: totalLines, language: language))
    }
    return files
  }
  
  /// Get overall index statistics
  func getIndexStats(repoPath: String? = nil) throws -> (fileCount: Int, chunkCount: Int, embeddingCount: Int, totalLines: Int) {
    try openIfNeeded()
    
    let fileCount: Int
    let chunkCount: Int
    let embeddingCount: Int
    let totalLines: Int
    
    if let repoPath {
      fileCount = try queryInt("""
        SELECT COUNT(*) FROM files f
        JOIN repos r ON f.repo_id = r.id
        WHERE r.root_path = ?
        """, bind: { stmt in bindText(stmt, 1, repoPath) })
      
      chunkCount = try queryInt("""
        SELECT COUNT(*) FROM chunks c
        JOIN files f ON c.file_id = f.id
        JOIN repos r ON f.repo_id = r.id
        WHERE r.root_path = ?
        """, bind: { stmt in bindText(stmt, 1, repoPath) })
      
      embeddingCount = try queryInt("""
        SELECT COUNT(*) FROM embeddings e
        JOIN chunks c ON e.chunk_id = c.id
        JOIN files f ON c.file_id = f.id
        JOIN repos r ON f.repo_id = r.id
        WHERE r.root_path = ?
        """, bind: { stmt in bindText(stmt, 1, repoPath) })
      
      totalLines = try queryInt("""
        SELECT COALESCE(SUM(c.end_line - c.start_line), 0) FROM chunks c
        JOIN files f ON c.file_id = f.id
        JOIN repos r ON f.repo_id = r.id
        WHERE r.root_path = ?
        """, bind: { stmt in bindText(stmt, 1, repoPath) })
    } else {
      fileCount = try queryInt("SELECT COUNT(*) FROM files")
      chunkCount = try queryInt("SELECT COUNT(*) FROM chunks")
      embeddingCount = try queryInt("SELECT COUNT(*) FROM embeddings")
      totalLines = try queryInt("SELECT COALESCE(SUM(end_line - start_line), 0) FROM chunks")
    }
    
    return (fileCount: fileCount, chunkCount: chunkCount, embeddingCount: embeddingCount, totalLines: totalLines)
  }

  /// Generate embeddings for the given texts using the configured provider.
  /// Exposed for testing MLX/embedding providers via MCP.
  func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
    try await embeddingProvider.embed(texts: texts)
  }

  // MARK: - Query Hints

  func recordQueryHint(query: String, repoPath: String?, mode: String, resultCount: Int) throws {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return }
    try openIfNeeded()
    try ensureSchema()

    let normalizedRepo = repoPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let now = dateFormatter.string(from: Date())
    let sql = """
    INSERT INTO rag_query_hints (query, repo_path, mode, result_count, use_count, last_used_at)
    VALUES (?, ?, ?, ?, 1, ?)
    ON CONFLICT(query, repo_path, mode) DO UPDATE SET
      result_count = excluded.result_count,
      use_count = use_count + 1,
      last_used_at = excluded.last_used_at
    """

    try execute(sql: sql) { statement in
      bindText(statement, 1, trimmedQuery)
      bindText(statement, 2, normalizedRepo)
      bindText(statement, 3, mode)
      sqlite3_bind_int(statement, 4, Int32(resultCount))
      bindText(statement, 5, now)
    }
  }

  func fetchQueryHints(limit: Int = 10) throws -> [LocalRAGQueryHint] {
    try openIfNeeded()
    try ensureSchema()
    let sql = """
    SELECT query, repo_path, mode, result_count, use_count, last_used_at
    FROM rag_query_hints
    ORDER BY last_used_at DESC
    LIMIT ?
    """

    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw LocalRAGError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_int(statement, 1, Int32(max(1, limit)))

    var hints: [LocalRAGQueryHint] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let query = String(cString: sqlite3_column_text(statement, 0))
      let repoRaw = String(cString: sqlite3_column_text(statement, 1))
      let mode = String(cString: sqlite3_column_text(statement, 2))
      let resultCount = Int(sqlite3_column_int(statement, 3))
      let useCount = Int(sqlite3_column_int(statement, 4))
      let lastUsedRaw = String(cString: sqlite3_column_text(statement, 5))
      let lastUsedAt = dateFormatter.date(from: lastUsedRaw) ?? Date()
      let repoPath = repoRaw.isEmpty ? nil : repoRaw
      hints.append(LocalRAGQueryHint(
        query: query,
        repoPath: repoPath,
        mode: mode,
        resultCount: resultCount,
        useCount: useCount,
        lastUsedAt: lastUsedAt
      ))
    }
    return hints
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
    SELECT repos.root_path || '/' || files.path, chunks.start_line, chunks.end_line, chunks.text, embeddings.embedding,
           chunks.construct_type, chunks.construct_name, files.language, files.module_path, files.feature_tags
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
        snippet: snippet,
        constructType: row.constructType,
        constructName: row.constructName,
        language: row.language,
        isTest: isTestFile(row.filePath),
        score: score,
        modulePath: row.modulePath,
        featureTags: row.featureTags
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

  func closeDatabase() {
    if let handle = db {
      sqlite3_close(handle)
      db = nil
    }
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
    try exec("CREATE TABLE IF NOT EXISTS chunks (id TEXT PRIMARY KEY, file_id TEXT, start_line INTEGER, end_line INTEGER, text TEXT, token_count INTEGER, construct_type TEXT, construct_name TEXT, metadata TEXT, FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE)")
    try exec("CREATE TABLE IF NOT EXISTS embeddings (chunk_id TEXT PRIMARY KEY, embedding BLOB, FOREIGN KEY(chunk_id) REFERENCES chunks(id) ON DELETE CASCADE)")
    try exec("CREATE TABLE IF NOT EXISTS cache_embeddings (text_hash TEXT PRIMARY KEY, embedding BLOB, updated_at TEXT)")
    try exec("""
      CREATE TABLE IF NOT EXISTS rag_query_hints (
        query TEXT COLLATE NOCASE NOT NULL,
        repo_path TEXT NOT NULL DEFAULT '',
        mode TEXT NOT NULL,
        result_count INTEGER NOT NULL,
        use_count INTEGER NOT NULL,
        last_used_at TEXT NOT NULL,
        PRIMARY KEY (query, repo_path, mode)
      )
      """)
    
    let now = dateFormatter.string(from: Date())
    try exec("INSERT OR IGNORE INTO rag_meta (key, value) VALUES ('schema_version', '1')")
    try exec("INSERT OR IGNORE INTO rag_meta (key, value) VALUES ('created_at', '\(now)')")
    try exec("INSERT OR REPLACE INTO rag_meta (key, value) VALUES ('updated_at', '\(now)')")

    // Check current schema version and migrate if needed
    let versionText = try queryString("SELECT value FROM rag_meta WHERE key = 'schema_version'")
    let currentVersion = Int(versionText ?? "0") ?? 0
    
    // Migration to v4: Add module_path and feature_tags columns to files table for faceted search
    if currentVersion < 4 {
      // Check if columns exist before adding (in case of partial migration)
      let hasModulePath = try columnExists(table: "files", column: "module_path")
      let hasFeatureTags = try columnExists(table: "files", column: "feature_tags")
      
      if !hasModulePath {
        try exec("ALTER TABLE files ADD COLUMN module_path TEXT")
      }
      if !hasFeatureTags {
        try exec("ALTER TABLE files ADD COLUMN feature_tags TEXT")
      }
      
      // Update schema version
      try exec("UPDATE rag_meta SET value = '4' WHERE key = 'schema_version'")
    }
    
    schemaVersion = 4
  }
  
  /// Check if a column exists in a table
  private func columnExists(table: String, column: String) throws -> Bool {
    guard let db else {
      throw LocalRAGError.sqlite("Database not initialized")
    }
    var statement: OpaquePointer?
    let sql = "PRAGMA table_info(\(table))"
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      let message = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite(message)
    }
    defer { sqlite3_finalize(statement) }
    
    while sqlite3_step(statement) == SQLITE_ROW {
      // Column 1 is the column name
      if let name = sqlite3_column_text(statement, 1) {
        if String(cString: name) == column {
          return true
        }
      }
    }
    return false
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
  
  private func queryInt(_ sql: String, bind: (OpaquePointer) -> Void) throws -> Int {
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
    
    bind(statement)
    
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int(statement, 0))
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
    let constructType: String?
    let constructName: String?
    let language: String?
    let modulePath: String?
    let featureTags: [String]
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
      
      // Metadata columns (5, 6, 7)
      let constructType: String? = sqlite3_column_type(statement, 5) != SQLITE_NULL 
        ? String(cString: sqlite3_column_text(statement, 5)) : nil
      let constructName: String? = sqlite3_column_type(statement, 6) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 6)) : nil
      let language: String? = sqlite3_column_type(statement, 7) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 7)) : nil
      
      // Facet columns (8, 9) - schema v4+
      let modulePath: String? = sqlite3_column_type(statement, 8) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 8)) : nil
      let featureTagsJson: String? = sqlite3_column_type(statement, 9) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 9)) : nil
      let featureTags: [String] = featureTagsJson.flatMap { json in
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
      } ?? []
      
      if let blobPointer, blobSize > 0 {
        let data = Data(bytes: blobPointer, count: Int(blobSize))
        rows.append(
          EmbeddingRow(
            filePath: path,
            startLine: startLine,
            endLine: endLine,
            text: text,
            embeddingData: data,
            constructType: constructType,
            constructName: constructName,
            language: language,
            modulePath: modulePath,
            featureTags: featureTags
          )
        )
      }
    }

    return rows
  }
  
  /// Detect if file path indicates a test file
  private func isTestFile(_ path: String) -> Bool {
    let lowercased = path.lowercased()
    return lowercased.contains("/test/") ||
           lowercased.contains("/tests/") ||
           lowercased.contains("/spec/") ||
           lowercased.contains("_test.") ||
           lowercased.contains("-test.") ||
           lowercased.contains("_spec.") ||
           lowercased.contains("-spec.") ||
           lowercased.contains(".test.") ||
           lowercased.contains(".spec.")
  }
  
  // MARK: - Facet Extraction
  
  /// Extract module path from file path (e.g., "Shared/Services" from "Shared/Services/LocalRAGStore.swift")
  private func extractModulePath(from path: String) -> String? {
    let components = path.split(separator: "/").map(String.init)
    guard components.count > 1 else { return nil }
    
    // Remove the filename, keep directory structure
    let directory = components.dropLast().joined(separator: "/")
    
    // Return up to 2 levels of directory for meaningful grouping
    let parts = directory.split(separator: "/").prefix(2).map(String.init)
    return parts.isEmpty ? nil : parts.joined(separator: "/")
  }
  
  /// Extract feature tags from file path, language, and chunk metadata
  private func extractFeatureTags(from path: String, language: String, chunks: [LocalRAGChunk]) -> [String] {
    var tags = Set<String>()
    let lowercasedPath = path.lowercased()
    
    // Path-based feature detection
    if lowercasedPath.contains("rag") { tags.insert("rag") }
    if lowercasedPath.contains("mcp") { tags.insert("mcp") }
    if lowercasedPath.contains("agent") { tags.insert("agent") }
    if lowercasedPath.contains("swarm") { tags.insert("swarm") }
    if lowercasedPath.contains("git") { tags.insert("git") }
    if lowercasedPath.contains("github") { tags.insert("github") }
    if lowercasedPath.contains("brew") { tags.insert("brew") }
    if lowercasedPath.contains("service") { tags.insert("service") }
    if lowercasedPath.contains("view") { tags.insert("ui") }
    if lowercasedPath.contains("model") { tags.insert("model") }
    if lowercasedPath.contains("handler") { tags.insert("handler") }
    if lowercasedPath.contains("tool") { tags.insert("tools") }
    if lowercasedPath.contains("embed") { tags.insert("embedding") }
    if lowercasedPath.contains("index") { tags.insert("indexing") }
    if lowercasedPath.contains("search") { tags.insert("search") }
    if lowercasedPath.contains("chunk") { tags.insert("chunking") }
    if lowercasedPath.contains("ast") { tags.insert("ast") }
    if lowercasedPath.contains("vm") { tags.insert("vm") }
    if lowercasedPath.contains("distributed") { tags.insert("distributed") }
    if lowercasedPath.contains("worktree") { tags.insert("worktree") }
    if lowercasedPath.contains("chain") { tags.insert("chain") }
    if lowercasedPath.contains("template") { tags.insert("template") }
    if lowercasedPath.contains("config") { tags.insert("config") }
    
    // Framework detection from chunks metadata
    for chunk in chunks {
      if let metadataJson = chunk.metadata,
         let data = metadataJson.data(using: .utf8),
         let metadata = try? JSONDecoder().decode(ChunkMetadataForFacets.self, from: data) {
        for framework in metadata.frameworks ?? [] {
          tags.insert(framework.lowercased())
        }
        if metadata.usesEmberConcurrency == true { tags.insert("ember-concurrency") }
        if metadata.hasTemplate == true { tags.insert("glimmer") }
      }
    }
    
    // Language as tag
    tags.insert(language.lowercased())
    
    return tags.sorted()
  }
  
  /// Query search results with metadata
  private func querySearchResults(
    sql: String,
    withScore: Bool,
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
      
      // Metadata columns (4, 5, 6)
      let constructType: String? = sqlite3_column_type(statement, 4) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 4)) : nil
      let constructName: String? = sqlite3_column_type(statement, 5) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 5)) : nil
      let language: String? = sqlite3_column_type(statement, 6) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 6)) : nil
      
      // Facet columns (7, 8) - schema v4+
      let modulePath: String? = sqlite3_column_type(statement, 7) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 7)) : nil
      let featureTagsJson: String? = sqlite3_column_type(statement, 8) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 8)) : nil
      let featureTags: [String] = featureTagsJson.flatMap { json in
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
      } ?? []
      
      results.append(
        LocalRAGSearchResult(
          filePath: path,
          startLine: startLine,
          endLine: endLine,
          snippet: snippet,
          constructType: constructType,
          constructName: constructName,
          language: language,
          isTest: isTestFile(path),
          score: nil,
          modulePath: modulePath,
          featureTags: featureTags
        )
      )
    }

    return results
  }

  private func upsertRepo(id: String, name: String, rootPath: String, lastIndexedAt: String) throws {
    // Use INSERT ... ON CONFLICT ... DO UPDATE to avoid triggering CASCADE DELETE
    // INSERT OR REPLACE would delete the repo row and cascade delete all files!
    let sql = """
    INSERT INTO repos (id, name, root_path, last_indexed_at)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      name = excluded.name,
      root_path = excluded.root_path,
      last_indexed_at = excluded.last_indexed_at
    """
    try execute(sql: sql) { statement in
      bindText(statement, 1, id)
      bindText(statement, 2, name)
      bindText(statement, 3, rootPath)
      bindText(statement, 4, lastIndexedAt)
    }
  }

  private func fetchFileHash(fileId: String) throws -> String? {
    let sql = "SELECT hash FROM files WHERE id = ?"
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

    bindText(statement, 1, fileId)
    let stepResult = sqlite3_step(statement)
    if stepResult == SQLITE_ROW,
       let text = sqlite3_column_text(statement, 0) {
      return String(cString: text)
    }
    return nil
  }

  private func fetchFileHashByPath(repoId: String, path: String) throws -> String? {
    let sql = "SELECT hash FROM files WHERE repo_id = ? AND path = ?"
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

    bindText(statement, 1, repoId)
    bindText(statement, 2, path)
    let stepResult = sqlite3_step(statement)
    if stepResult == SQLITE_ROW,
       let text = sqlite3_column_text(statement, 0) {
      return String(cString: text)
    }
    return nil
  }

  private func upsertFile(
    id: String,
    repoId: String,
    path: String,
    hash: String,
    language: String,
    updatedAt: String,
    modulePath: String?,
    featureTags: String?
  ) throws {
    // Use INSERT ... ON CONFLICT to avoid cascade delete of chunks
    let sql = """
    INSERT INTO files (id, repo_id, path, hash, language, updated_at, module_path, feature_tags)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      repo_id = excluded.repo_id,
      path = excluded.path,
      hash = excluded.hash,
      language = excluded.language,
      updated_at = excluded.updated_at,
      module_path = excluded.module_path,
      feature_tags = excluded.feature_tags
    """
    try execute(sql: sql) { statement in
      bindText(statement, 1, id)
      bindText(statement, 2, repoId)
      bindText(statement, 3, path)
      bindText(statement, 4, hash)
      bindText(statement, 5, language)
      bindText(statement, 6, updatedAt)
      if let modulePath {
        bindText(statement, 7, modulePath)
      } else {
        sqlite3_bind_null(statement, 7)
      }
      if let featureTags {
        bindText(statement, 8, featureTags)
      } else {
        sqlite3_bind_null(statement, 8)
      }
    }
  }

  private func upsertChunk(
    id: String,
    fileId: String,
    startLine: Int,
    endLine: Int,
    text: String,
    tokenCount: Int,
    constructType: String?,
    constructName: String?,
    metadata: String?
  ) throws {
    let sql = """
    INSERT OR REPLACE INTO chunks (id, file_id, start_line, end_line, text, token_count, construct_type, construct_name, metadata)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
    try execute(sql: sql) { statement in
      bindText(statement, 1, id)
      bindText(statement, 2, fileId)
      sqlite3_bind_int(statement, 3, Int32(startLine))
      sqlite3_bind_int(statement, 4, Int32(endLine))
      bindText(statement, 5, text)
      sqlite3_bind_int(statement, 6, Int32(tokenCount))
      if let constructType {
        bindText(statement, 7, constructType)
      } else {
        sqlite3_bind_null(statement, 7)
      }
      if let constructName {
        bindText(statement, 8, constructName)
      } else {
        sqlite3_bind_null(statement, 8)
      }
      if let metadata {
        bindText(statement, 9, metadata)
      } else {
        sqlite3_bind_null(statement, 9)
      }
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
    // Use SQLITE_TRANSIENT to have SQLite make a copy of the string data
    let cString = (value as NSString).utf8String
    sqlite3_bind_text(statement, index, cString, -1, sqliteTransient)
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

// MARK: - Local RAG Artifacts (Sync)

public struct LocalRAGArtifactBundle: Sendable {
  public let manifest: RAGArtifactManifest
  public let bundleURL: URL
  public let bundleSizeBytes: Int

  public init(manifest: RAGArtifactManifest, bundleURL: URL, bundleSizeBytes: Int) {
    self.manifest = manifest
    self.bundleURL = bundleURL
    self.bundleSizeBytes = bundleSizeBytes
  }
}

enum LocalRAGArtifacts {
  static let formatVersion = 1

  static func ragBaseURL() -> URL {
    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let ragURL = baseURL.appendingPathComponent("Peel/RAG", isDirectory: true)
    if !FileManager.default.fileExists(atPath: ragURL.path) {
      try? FileManager.default.createDirectory(at: ragURL, withIntermediateDirectories: true)
    }
    return ragURL
  }

  static func graphStoreURL() -> URL {
    let graphURL = ragBaseURL().appendingPathComponent("Graph", isDirectory: true)
    if !FileManager.default.fileExists(atPath: graphURL.path) {
      try? FileManager.default.createDirectory(at: graphURL, withIntermediateDirectories: true)
    }
    let graphDB = graphURL.appendingPathComponent("graph.sqlite")
    if !FileManager.default.fileExists(atPath: graphDB.path) {
      FileManager.default.createFile(atPath: graphDB.path, contents: Data())
    }
    return graphDB
  }

  static func artifactFiles() -> [URL] {
    let ragURL = ragBaseURL()
    let ragDB = ragURL.appendingPathComponent("rag.sqlite")
    let ragWAL = ragURL.appendingPathComponent("rag.sqlite-wal")
    let ragSHM = ragURL.appendingPathComponent("rag.sqlite-shm")
    let graphDB = graphStoreURL()
    let graphWAL = graphDB.deletingLastPathComponent().appendingPathComponent("graph.sqlite-wal")
    let graphSHM = graphDB.deletingLastPathComponent().appendingPathComponent("graph.sqlite-shm")

    let candidates = [ragDB, ragWAL, ragSHM, graphDB, graphWAL, graphSHM]
    return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  static func buildManifest(
    status: LocalRAGStore.Status,
    stats: LocalRAGStore.Stats?,
    repos: [LocalRAGStore.RepoInfo]
  ) async -> RAGArtifactManifest {
    let baseURL = ragBaseURL()
    let files = artifactFiles().compactMap { file -> RAGArtifactFileInfo? in
      let relative = file.path.replacingOccurrences(of: baseURL.path + "/", with: "")
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            let size = attributes[.size] as? NSNumber else {
        return nil
      }
      let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
      let sha256 = (try? sha256Hex(for: file)) ?? ""
      return RAGArtifactFileInfo(
        relativePath: relative,
        sizeBytes: size.intValue,
        sha256: sha256,
        modifiedAt: modifiedAt
      )
    }

    let totalBytes = files.reduce(0) { $0 + $1.sizeBytes }
    var snapshots: [RAGArtifactRepoSnapshot] = []
    for repo in repos {
      snapshots.append(await repoSnapshot(for: repo))
    }

    let hashSeed = files.map { "\($0.relativePath):\($0.sha256)" }.joined(separator: "|")
      + "|schema:\(status.schemaVersion)"
      + "|repos:\(snapshots.map(\.fingerprint).joined(separator: ","))"
    let versionHash = sha256Hex(for: Data(hashSeed.utf8)).prefix(12)

    return RAGArtifactManifest(
      formatVersion: formatVersion,
      version: "v\(formatVersion)-\(versionHash)",
      createdAt: Date(),
      schemaVersion: status.schemaVersion,
      totalBytes: totalBytes,
      embeddingCacheCount: stats?.cacheEmbeddingCount ?? 0,
      lastIndexedAt: stats?.lastIndexedAt,
      files: files,
      repos: snapshots
    )
  }

  static func createBundle(
    status: LocalRAGStore.Status,
    stats: LocalRAGStore.Stats?,
    repos: [LocalRAGStore.RepoInfo]
  ) async throws -> LocalRAGArtifactBundle {
    let manifest = await buildManifest(status: status, stats: stats, repos: repos)
    return try createBundle(from: manifest)
  }

  static func createBundle(from manifest: RAGArtifactManifest) throws -> LocalRAGArtifactBundle {
    let baseURL = ragBaseURL()
    let artifactsDir = baseURL.appendingPathComponent("Artifacts", isDirectory: true)
    if !FileManager.default.fileExists(atPath: artifactsDir.path) {
      try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
    }

    let bundleId = UUID().uuidString
    let stagingURL = artifactsDir.appendingPathComponent("bundle-\(bundleId)", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

    for file in manifest.files {
      let source = baseURL.appendingPathComponent(file.relativePath)
      let destination = stagingURL.appendingPathComponent(file.relativePath)
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
    }

    let manifestURL = stagingURL.appendingPathComponent("manifest.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: manifestURL, options: [.atomic])

    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let bundleURL = artifactsDir.appendingPathComponent("rag-artifacts-\(timestamp).zip")
    if FileManager.default.fileExists(atPath: bundleURL.path) {
      try FileManager.default.removeItem(at: bundleURL)
    }

    try zipItem(at: stagingURL, to: bundleURL)
    try? FileManager.default.removeItem(at: stagingURL)

    let bundleSize = (try? FileManager.default.attributesOfItem(atPath: bundleURL.path)[.size] as? NSNumber)?.intValue ?? 0
    return LocalRAGArtifactBundle(manifest: manifest, bundleURL: bundleURL, bundleSizeBytes: bundleSize)
  }

  static func applyBundle(bundleURL: URL, manifest: RAGArtifactManifest) throws {
    let baseURL = ragBaseURL()
    let tempDir = baseURL.appendingPathComponent("Artifacts/apply-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try unzipItem(at: bundleURL, to: tempDir)

    let manifestPaths = Set(manifest.files.map { $0.relativePath })
    let existingArtifacts = artifactFiles().map { $0.path.replacingOccurrences(of: baseURL.path + "/", with: "") }
    for relativePath in existingArtifacts where !manifestPaths.contains(relativePath) {
      let target = baseURL.appendingPathComponent(relativePath)
      if FileManager.default.fileExists(atPath: target.path) {
        try? FileManager.default.removeItem(at: target)
      }
    }

    for file in manifest.files {
      let source = tempDir.appendingPathComponent(file.relativePath)
      let destination = baseURL.appendingPathComponent(file.relativePath)
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.copyItem(at: source, to: destination)
      }
    }

    try? FileManager.default.removeItem(at: tempDir)
  }

  static func repoSnapshot(for repo: LocalRAGStore.RepoInfo) async -> RAGArtifactRepoSnapshot {
    let remoteURL = await RepoRegistry.shared.registerRepo(at: repo.rootPath)
    let headSHA = gitOutput(args: ["rev-parse", "HEAD"], repoPath: repo.rootPath)
    let dirty = !(gitOutput(args: ["status", "--porcelain"], repoPath: repo.rootPath) ?? "").isEmpty
    let commitTimestamp = gitOutput(args: ["log", "-1", "--format=%ct"], repoPath: repo.rootPath)
      .flatMap { TimeInterval($0) }
      .map { Date(timeIntervalSince1970: $0) }

    return RAGArtifactRepoSnapshot(
      repoId: repo.id,
      name: repo.name,
      rootPath: repo.rootPath,
      remoteURL: remoteURL,
      headSHA: headSHA,
      isDirty: dirty,
      lastCommitAt: commitTimestamp,
      lastIndexedAt: repo.lastIndexedAt
    )
  }

  static func stalenessInfo(for manifest: RAGArtifactManifest) async -> (Bool, String?) {
    for repo in manifest.repos {
      guard let localPath = await resolveLocalRepoPath(for: repo) else { continue }
      let currentHead = gitOutput(args: ["rev-parse", "HEAD"], repoPath: localPath)
      let currentDirty = !(gitOutput(args: ["status", "--porcelain"], repoPath: localPath) ?? "").isEmpty
      if currentHead != repo.headSHA {
        return (true, "Repo updated: \(repo.name)")
      }
      if currentDirty != repo.isDirty {
        return (true, "Repo dirty state changed: \(repo.name)")
      }
    }
    return (false, nil)
  }

  private static func resolveLocalRepoPath(for snapshot: RAGArtifactRepoSnapshot) async -> String? {
    if FileManager.default.fileExists(atPath: snapshot.rootPath) {
      return snapshot.rootPath
    }
    if let remoteURL = snapshot.remoteURL,
       let mapped = await RepoRegistry.shared.getLocalPath(for: remoteURL),
       FileManager.default.fileExists(atPath: mapped) {
      return mapped
    }
    return nil
  }

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
      guard process.terminationStatus == 0 else {
        return nil
      }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return output
    } catch {
      return nil
    }
  }

  private static func sha256Hex(for fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }

    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256Hex(for data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func zipItem(at sourceURL: URL, to destinationURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", sourceURL.path, destinationURL.path]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw LocalRAGStore.LocalRAGError.sqlite("Failed to create RAG artifact bundle")
    }
  }

  private static func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", sourceURL.path, destinationURL.path]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw LocalRAGStore.LocalRAGError.sqlite("Failed to extract RAG artifact bundle")
    }
  }
}
