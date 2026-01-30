//
//  LocalRAGStore.swift
//  Peel
//
//  Created on 1/19/26.
//

import ASTChunker
import CryptoKit
import CSQLite  // Custom SQLite with extension loading support (not system SQLite3)
import Darwin
import Foundation
import MachO
import MCPCore
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
  
  // AI analysis results (schema v7+)
  let aiSummary: String?        // AI-generated summary of this chunk
  let aiTags: [String]          // AI-generated semantic tags
  
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

// MARK: - Dependency Graph Types (Issue #176)

/// Type of dependency relationship between code units
enum LocalRAGDependencyType: String, Sendable, CaseIterable, Codable {
  case `import` = "import"       // Swift: import, TS/JS: import, Ruby: require
  case require = "require"       // Ruby: require, require_relative
  case include = "include"       // Ruby: include (mixin)
  case extend = "extend"         // Ruby: extend (class methods mixin)
  case inherit = "inherit"       // Class inheritance (< in Ruby, : in Swift)
  case conform = "conform"       // Protocol/interface conformance
  case call = "call"             // Function/method call reference (future)
}

/// Represents a dependency relationship between source and target
struct LocalRAGDependency: Sendable {
  let id: String
  let repoId: String
  let sourceFileId: String
  let sourceSymbolId: String?
  let targetPath: String           // Resolved path or module name
  let targetSymbolName: String?    // Optional: specific symbol being imported
  let targetFileId: String?        // Resolved target file (if in same repo)
  let dependencyType: LocalRAGDependencyType
  let rawImport: String            // Original import statement text
  
  init(
    id: String = UUID().uuidString,
    repoId: String,
    sourceFileId: String,
    sourceSymbolId: String? = nil,
    targetPath: String,
    targetSymbolName: String? = nil,
    targetFileId: String? = nil,
    dependencyType: LocalRAGDependencyType,
    rawImport: String
  ) {
    self.id = id
    self.repoId = repoId
    self.sourceFileId = sourceFileId
    self.sourceSymbolId = sourceSymbolId
    self.targetPath = targetPath
    self.targetSymbolName = targetSymbolName
    self.targetFileId = targetFileId
    self.dependencyType = dependencyType
    self.rawImport = rawImport
  }
}

/// Result from dependency queries
struct LocalRAGDependencyResult: Sendable {
  let sourceFile: String           // Relative path of source file
  let targetPath: String           // Module/path being depended on
  let targetFile: String?          // Resolved target file (if in repo)
  let dependencyType: LocalRAGDependencyType
  let rawImport: String
}

/// Summary of dependencies for a file
struct LocalRAGDependencySummary: Sendable {
  let filePath: String
  let dependencies: [LocalRAGDependencyResult]    // What this file depends on
  let dependents: [LocalRAGDependencyResult]      // What depends on this file
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
    case embeddingFailed(String)

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
      case .embeddingFailed(let message):
        return "Embedding failed: \(message)"
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
    var memoryPauseCount = 0

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
    
    // Memory pressure management - check every N files
    let memoryCheckInterval = 10
    let memoryLimitGB = LocalRAGEmbeddingProviderFactory.mlxMemoryLimitGB
    print("[RAG] Memory limit set to \(String(format: "%.1f", memoryLimitGB)) GB")

    for (fileIndex, candidate) in scannedFiles.enumerated() {
      progress?(.analyzing(current: fileIndex + 1, total: scannedFiles.count, fileName: URL(fileURLWithPath: candidate.path).lastPathComponent))
      
      // Memory pressure check - aggressively clear caches if approaching limit
      if fileIndex % memoryCheckInterval == 0 {
        logMemory("analyzing \(fileIndex + 1)/\(scannedFiles.count): \(URL(fileURLWithPath: candidate.path).lastPathComponent)")
        
        if LocalRAGEmbeddingProviderFactory.isMemoryPressureHigh() {
          memoryPauseCount += 1
          let currentGB = Double(LocalRAGEmbeddingProviderFactory.currentProcessMemoryBytes()) / 1_073_741_824.0
          print("[RAG] ⚠️ Memory pressure detected: \(String(format: "%.1f", currentGB)) GB > \(String(format: "%.1f", memoryLimitGB)) GB limit")
          
          // Aggressive memory cleanup
          embeddingCache.removeAll()
          seenTextHashes.removeAll()
          MLX.Memory.clearCache()
          
          // Give the system a moment to reclaim memory
          try await Task.sleep(for: .milliseconds(500))
          
          let newGB = Double(LocalRAGEmbeddingProviderFactory.currentProcessMemoryBytes()) / 1_073_741_824.0
          print("[RAG] After cleanup: \(String(format: "%.1f", newGB)) GB")
        }
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

          // Always clear MLX cache after each batch to prevent memory accumulation
          // This is critical for preventing unbounded memory growth on large repos
          if LocalRAGEmbeddingProviderFactory.mlxClearCacheAfterBatch {
            MLX.Memory.clearCache()
          }
        }

        let embedDuration = Int(Date().timeIntervalSince(embedStart) * 1000)
        embeddingDurationMs += embedDuration
        progress?(.embedding(current: missingEmbeddings.count, total: missingEmbeddings.count))
        
        // Clear embedding cache after storing to DB - no need to keep in memory
        embeddingCache.removeAll(keepingCapacity: false)
      }

      progress?(.storing(current: filesIndexed + 1, total: scannedFiles.count))
      
      // Extract facets for filtering/grouping
      let modulePath = extractModulePath(from: relativePath)
      let featureTags = extractFeatureTags(from: relativePath, language: file.language, chunks: chunks)
      let featureTagsJson = featureTags.isEmpty ? nil : (try? JSONEncoder().encode(featureTags)).flatMap { String(data: $0, encoding: .utf8) }
      
      // Calculate structural metrics (Issue #174)
      let lineCount = chunks.map(\.endLine).max() ?? 0
      let methodCount = chunks.filter { chunk in
        guard let ct = chunk.constructType?.lowercased() else { return false }
        return ct == "function" || ct == "method" || ct == "init" || ct == "deinit"
      }.count
      
      try upsertFile(
        id: fileId,
        repoId: repoId,
        path: relativePath,
        hash: fileHash,
        language: file.language,
        updatedAt: now,
        modulePath: modulePath,
        featureTags: featureTagsJson,
        lineCount: lineCount,
        methodCount: methodCount,
        byteSize: file.byteCount
      )
      try deleteChunks(for: fileId)
      
      // Delete old dependencies before re-indexing
      try deleteDependencies(for: fileId)

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
      
      // Extract and store dependencies from chunk metadata (Issue #176)
      let fileDeps = extractDependencies(
        from: chunks,
        repoId: repoId,
        fileId: fileId,
        relativePath: relativePath,
        language: file.language
      )
      if !fileDeps.isEmpty {
        try insertDependencies(fileDeps)
      }

      chunkCount += chunks.count
      bytesScanned += file.byteCount
      filesIndexed += 1
    }
    logMemory("index complete")
    
    // Log AST stats and memory stats
    print("[RAG] AST stats: \(astFilesChunked) AST, \(lineFilesChunked) line-based, \(chunkingFailures) failures")
    if memoryPauseCount > 0 {
      print("[RAG] Memory pressure pauses: \(memoryPauseCount)")
    }

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
           chunks.construct_type, chunks.construct_name, files.language, files.module_path, files.feature_tags,
           chunks.ai_summary, chunks.ai_tags
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
  
  // MARK: - AI Analysis (#198)
  
  #if os(macOS)
  /// Analyze un-analyzed chunks using MLX code analyzer.
  /// Returns count of chunks analyzed.
  func analyzeChunks(
    repoPath: String? = nil,
    limit: Int = 100,
    modelTier: MLXAnalyzerModelTier = .auto,
    progress: (@Sendable (Int, Int) -> Void)? = nil
  ) async throws -> Int {
    try openIfNeeded()
    
    // Get un-analyzed chunks
    let sql: String
    if let repoPath {
      sql = """
      SELECT c.id, c.text, c.construct_type, c.construct_name, f.language
      FROM chunks c
      JOIN files f ON c.file_id = f.id
      JOIN repos r ON f.repo_id = r.id
      WHERE c.ai_summary IS NULL AND r.root_path = ?
      LIMIT ?
      """
    } else {
      sql = """
      SELECT c.id, c.text, c.construct_type, c.construct_name, f.language
      FROM chunks c
      JOIN files f ON c.file_id = f.id
      WHERE c.ai_summary IS NULL
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
    
    var bindIndex: Int32 = 1
    if let repoPath {
      bindText(statement, bindIndex, repoPath)
      bindIndex += 1
    }
    sqlite3_bind_int(statement, bindIndex, Int32(limit))
    
    // Collect chunks to analyze
    struct ChunkToAnalyze {
      let id: String
      let text: String
      let constructType: String?
      let constructName: String?
      let language: String?
    }
    
    var chunksToAnalyze: [ChunkToAnalyze] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let id = String(cString: sqlite3_column_text(statement, 0))
      let text = String(cString: sqlite3_column_text(statement, 1))
      let constructType = sqlite3_column_text(statement, 2).map { String(cString: $0) }
      let constructName = sqlite3_column_text(statement, 3).map { String(cString: $0) }
      let language = sqlite3_column_text(statement, 4).map { String(cString: $0) }
      chunksToAnalyze.append(ChunkToAnalyze(
        id: id, text: text, constructType: constructType, 
        constructName: constructName, language: language
      ))
    }
    
    guard !chunksToAnalyze.isEmpty else { return 0 }
    
    // Create analyzer with specified tier (or auto-detect if .auto)
    let effectiveTier = modelTier == .auto 
      ? MLXAnalyzerModelTier.recommended(forMemoryGB: Double(LocalRAGEmbeddingProviderFactory.physicalMemoryBytes()) / 1_073_741_824.0)
      : modelTier
    let analyzer = await MLXCodeAnalyzerFactory.makeAnalyzer(tier: effectiveTier)
    let now = dateFormatter.string(from: Date())
    var analyzedCount = 0
    
    for (index, chunk) in chunksToAnalyze.enumerated() {
      progress?(index + 1, chunksToAnalyze.count)
      
      do {
        let result = try await analyzer.analyze(
          code: chunk.text,
          language: chunk.language,
          constructType: chunk.constructType,
          constructName: chunk.constructName
        )
        
        // Store the analysis result
        let tagsJson = try? JSONEncoder().encode(result.tags)
        let tagsString = tagsJson.flatMap { String(data: $0, encoding: .utf8) }
        
        try updateChunkAnalysis(
          chunkId: chunk.id,
          aiSummary: result.summary,
          aiTags: tagsString,
          analyzedAt: now,
          analyzerModel: result.model
        )
        analyzedCount += 1
      } catch {
        print("[RAG] Chunk analysis failed for \(chunk.id): \(error)")
        // Continue with next chunk
      }
    }
    
    // Unload the model to free memory
    await analyzer.unload()
    
    return analyzedCount
  }
  
  /// Update chunk with AI analysis results
  private func updateChunkAnalysis(
    chunkId: String,
    aiSummary: String,
    aiTags: String?,
    analyzedAt: String,
    analyzerModel: String
  ) throws {
    let sql = """
    UPDATE chunks SET ai_summary = ?, ai_tags = ?, analyzed_at = ?, analyzer_model = ?
    WHERE id = ?
    """
    try execute(sql: sql) { statement in
      bindText(statement, 1, aiSummary)
      if let aiTags {
        bindText(statement, 2, aiTags)
      } else {
        sqlite3_bind_null(statement, 2)
      }
      bindText(statement, 3, analyzedAt)
      bindText(statement, 4, analyzerModel)
      bindText(statement, 5, chunkId)
    }
  }
  
  /// Get count of un-analyzed chunks
  func getUnanalyzedChunkCount(repoPath: String? = nil) throws -> Int {
    try openIfNeeded()
    
    if let repoPath {
      return try queryInt("""
        SELECT COUNT(*) FROM chunks c
        JOIN files f ON c.file_id = f.id
        JOIN repos r ON f.repo_id = r.id
        WHERE c.ai_summary IS NULL AND r.root_path = ?
        """, bind: { stmt in bindText(stmt, 1, repoPath) })
    } else {
      return try queryInt("SELECT COUNT(*) FROM chunks WHERE ai_summary IS NULL")
    }
  }
  
  /// Get count of analyzed chunks
  func getAnalyzedChunkCount(repoPath: String? = nil) throws -> Int {
    try openIfNeeded()
    
    if let repoPath {
      return try queryInt("""
        SELECT COUNT(*) FROM chunks c
        JOIN files f ON c.file_id = f.id
        JOIN repos r ON f.repo_id = r.id
        WHERE c.ai_summary IS NOT NULL AND r.root_path = ?
        """, bind: { stmt in bindText(stmt, 1, repoPath) })
    } else {
      return try queryInt("SELECT COUNT(*) FROM chunks WHERE ai_summary IS NOT NULL")
    }
  }
  #endif

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

    // Use accelerated search if sqlite-vec is loaded
    if extensionLoaded {
      return try searchVectorAccelerated(queryVector: queryVector, repoPath: repoPath, limit: limit)
    }
    
    // Fallback to brute-force search
    return try searchVectorBruteForce(queryVector: queryVector, repoPath: repoPath, limit: limit)
  }
  
  /// Accelerated vector search using sqlite-vec extension
  private func searchVectorAccelerated(queryVector: [Float], repoPath: String?, limit: Int) throws -> [LocalRAGSearchResult] {
    guard let db else { throw LocalRAGError.sqlite("Database not open") }
    
    // Encode query vector as blob
    let queryBlob = encodeVector(queryVector)
    
    // sqlite-vec uses vec_distance_cosine for cosine distance (1 - similarity)
    // We want highest similarity, so ORDER BY distance ASC
    var sql = """
      SELECT 
        repos.root_path || '/' || files.path as file_path,
        chunks.start_line,
        chunks.end_line,
        chunks.text,
        chunks.construct_type,
        chunks.construct_name,
        files.language,
        files.module_path,
        files.feature_tags,
        vec_distance_cosine(v.embedding, ?) as distance,
        chunks.ai_summary,
        chunks.ai_tags
      FROM vec_chunks v
      JOIN chunks ON chunks.id = v.chunk_id
      JOIN files ON files.id = chunks.file_id
      JOIN repos ON repos.id = files.repo_id
      """
    
    if repoPath != nil {
      sql += " WHERE repos.root_path = ?"
    }
    
    sql += " ORDER BY distance ASC LIMIT ?"
    
    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let stmt = statement else {
      let message = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite("Failed to prepare accelerated search: \(message)")
    }
    defer { sqlite3_finalize(stmt) }
    
    // Bind query vector blob using NSData to avoid closure issues
    var bindIndex: Int32 = 1
    let nsData = queryBlob as NSData
    sqlite3_bind_blob(stmt, bindIndex, nsData.bytes, Int32(nsData.length), sqliteTransient)
    bindIndex += 1
    
    // Bind repo path filter if provided
    if let repoPath {
      bindText(stmt, bindIndex, repoPath)
      bindIndex += 1
    }
    
    // Bind limit
    sqlite3_bind_int(stmt, bindIndex, Int32(limit))
    
    var results: [LocalRAGSearchResult] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let filePath = String(cString: sqlite3_column_text(stmt, 0))
      let startLine = Int(sqlite3_column_int(stmt, 1))
      let endLine = Int(sqlite3_column_int(stmt, 2))
      let text = String(cString: sqlite3_column_text(stmt, 3))
      let constructType = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
      let constructName = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
      let language = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
      let modulePath = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
      let featureTagsJSON = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
      let distance = Float(sqlite3_column_double(stmt, 9))
      let aiSummary = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
      let aiTagsJSON = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
      
      // Convert cosine distance to similarity score (1 - distance)
      let score = 1.0 - distance
      
      // Parse feature tags from JSON
      var featureTags: [String] = []
      if let json = featureTagsJSON,
         let data = json.data(using: .utf8),
         let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
        featureTags = parsed
      }
      
      // Parse AI tags from JSON
      var aiTags: [String] = []
      if let json = aiTagsJSON,
         let data = json.data(using: .utf8),
         let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
        aiTags = parsed
      }
      
      let snippet = String(text.prefix(240))
      let result = LocalRAGSearchResult(
        filePath: filePath,
        startLine: startLine,
        endLine: endLine,
        snippet: snippet,
        constructType: constructType,
        constructName: constructName,
        language: language,
        isTest: isTestFile(filePath),
        score: score,
        modulePath: modulePath,
        featureTags: featureTags,
        aiSummary: aiSummary,
        aiTags: aiTags
      )
      results.append(result)
    }
    
    return results
  }
  
  /// Brute-force vector search (fallback when extension not available)
  private func searchVectorBruteForce(queryVector: [Float], repoPath: String?, limit: Int) throws -> [LocalRAGSearchResult] {
    let candidateLimit = max(limit * 50, 200)
    let sqlBase = """
    SELECT repos.root_path || '/' || files.path, chunks.start_line, chunks.end_line, chunks.text, embeddings.embedding,
           chunks.construct_type, chunks.construct_name, files.language, files.module_path, files.feature_tags,
           chunks.ai_summary, chunks.ai_tags
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
        featureTags: row.featureTags,
        aiSummary: row.aiSummary,
        aiTags: row.aiTags
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
    
    // Try to load sqlite-vec extension immediately after opening
    try loadExtensionIfAvailable(extensionPath: nil)
    
    // Ensure schema is up-to-date (runs migrations if needed)
    // This guarantees that queries can use columns from the latest schema version
    try ensureSchema()
  }

  func closeDatabase() {
    if let handle = db {
      sqlite3_close(handle)
      db = nil
    }
  }

  /// Attempt to load sqlite-vec extension for accelerated vector search
  /// Uses CustomSQLite which is compiled with SQLITE_ENABLE_LOAD_EXTENSION
  private func loadExtensionIfAvailable(extensionPath: String?) throws {
    extensionLoaded = false
    
    guard let handle = db else {
      return
    }

    // Try paths in order: explicit path, app bundle, Application Support
    var pathsToTry: [String] = []

    if let path = extensionPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
      // User provided path - remove .dylib if present since SQLite appends it
      let cleanPath = path.hasSuffix(".dylib") ? String(path.dropLast(6)) : path
      pathsToTry.append(cleanPath)
    }

    // Check app bundle first (auto-signed by Xcode during build)
    if let bundlePath = Bundle.main.path(forResource: "vec0", ofType: "dylib") {
      // Remove .dylib since SQLite appends it
      let cleanPath = bundlePath.hasSuffix(".dylib") ? String(bundlePath.dropLast(6)) : bundlePath
      pathsToTry.append(cleanPath)
    }

    // Fall back to Application Support/Peel/Extensions (non-sandboxed path)
    // Note: SQLite auto-appends .dylib on macOS, so we provide path without extension
    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let extensionDir = appSupport.appendingPathComponent("Peel/Extensions")
      // Provide path without .dylib - SQLite will add it
      let vecPath = extensionDir.appendingPathComponent("vec0").path
      pathsToTry.append(vecPath)
    }
    
    print("[RAG] Looking for sqlite-vec in paths: \(pathsToTry)")

    // Try each path
    for extensionPath in pathsToTry {
      // Check if the file exists (with .dylib extension)
      let pathWithExtension = extensionPath.hasSuffix(".dylib") ? extensionPath : "\(extensionPath).dylib"
      let exists = FileManager.default.fileExists(atPath: pathWithExtension)
      print("[RAG] Checking \(pathWithExtension): exists=\(exists)")
      guard exists else {
        continue
      }

      // Enable extension loading (CSQLite is compiled with this support)
      let enableResult = sqlite3_enable_load_extension(handle, 1)
      guard enableResult == SQLITE_OK else {
        continue
      }

      // Load the extension
      var errorMsg: UnsafeMutablePointer<CChar>?
      let loadResult = sqlite3_load_extension(handle, extensionPath, "sqlite3_vec_init", &errorMsg)

      if loadResult == SQLITE_OK {
        extensionLoaded = true
        print("[RAG] sqlite-vec extension loaded successfully")

        // Disable extension loading after successful load (security)
        sqlite3_enable_load_extension(handle, 0)
        return
      } else {
        let errorString = errorMsg.map { String(cString: $0) } ?? "unknown error"
        sqlite3_free(errorMsg)
        print("[RAG] Failed to load sqlite-vec: \(errorString)")
      }
    }

    // Extension not found or failed to load - this is fine, we'll use brute-force search
  }
  
  /// Create or update the vec_chunks virtual table for accelerated vector search
  private func ensureVecTable() throws {
    guard extensionLoaded, let handle = db else { return }
    
    // Get embedding dimensions from provider
    let dimensions = embeddingProvider.dimensions
    
    // Create the vec_chunks virtual table if it doesn't exist
    // vec0 uses float[N] syntax for vector columns
    let createSQL = """
      CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
        chunk_id TEXT PRIMARY KEY,
        embedding float[\(dimensions)]
      )
      """
    
    var errorMsg: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, createSQL, nil, nil, &errorMsg)
    
    if result != SQLITE_OK {
      let error = errorMsg.map { String(cString: $0) } ?? "unknown error"
      sqlite3_free(errorMsg)
      print("[RAG] Failed to create vec_chunks table: \(error)")
      // Don't throw - we can still use brute-force search
      extensionLoaded = false
      return
    }
    
    print("[RAG] vec_chunks virtual table ready (dimensions: \(dimensions))")
  }
  
  /// Sync embeddings to the vec_chunks table for accelerated search
  private func syncVecTable() throws {
    guard extensionLoaded else { return }
    
    // Count embeddings not yet in vec_chunks
    let missingCount = try queryInt("""
      SELECT COUNT(*) FROM embeddings e
      WHERE NOT EXISTS (SELECT 1 FROM vec_chunks v WHERE v.chunk_id = e.chunk_id)
      AND e.embedding IS NOT NULL
      """)
    
    guard missingCount > 0 else { return }
    
    print("[RAG] Syncing \(missingCount) embeddings to vec_chunks...")
    
    // Insert missing embeddings in batches
    let batchSize = 500
    var synced = 0
    
    while synced < missingCount {
      let sql = """
        INSERT OR REPLACE INTO vec_chunks (chunk_id, embedding)
        SELECT e.chunk_id, e.embedding
        FROM embeddings e
        WHERE NOT EXISTS (SELECT 1 FROM vec_chunks v WHERE v.chunk_id = e.chunk_id)
        AND e.embedding IS NOT NULL
        LIMIT ?
        """
      
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { break }
      defer { sqlite3_finalize(stmt) }
      
      sqlite3_bind_int(stmt, 1, Int32(batchSize))
      
      if sqlite3_step(stmt) == SQLITE_DONE {
        let changes = Int(sqlite3_changes(db))
        synced += changes
        if changes == 0 { break }
      } else {
        break
      }
    }
    
    print("[RAG] Synced \(synced) embeddings to vec_chunks")
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
    
    // Migration to v5: Add dependencies table for code graph (issue #176)
    // This enables dependency queries: "what does X depend on?" and "what depends on X?"
    if currentVersion < 5 {
      // Create symbols table - normalized symbols across files
      try exec("""
        CREATE TABLE IF NOT EXISTS symbols (
          id TEXT PRIMARY KEY,
          repo_id TEXT NOT NULL,
          file_id TEXT,
          name TEXT NOT NULL,
          qualified_name TEXT,
          symbol_type TEXT NOT NULL,
          start_line INTEGER,
          end_line INTEGER,
          FOREIGN KEY(repo_id) REFERENCES repos(id) ON DELETE CASCADE,
          FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
        )
        """)
      
      // Create dependencies table - edges between files/symbols
      // source_file_id: the file that has the import/reference
      // target_path: the resolved path or module name being imported
      // dependency_type: 'import', 'require', 'include', 'inherit', 'conform', 'extend', 'call'
      try exec("""
        CREATE TABLE IF NOT EXISTS dependencies (
          id TEXT PRIMARY KEY,
          repo_id TEXT NOT NULL,
          source_file_id TEXT NOT NULL,
          source_symbol_id TEXT,
          target_path TEXT NOT NULL,
          target_symbol_name TEXT,
          target_file_id TEXT,
          dependency_type TEXT NOT NULL,
          raw_import TEXT,
          FOREIGN KEY(repo_id) REFERENCES repos(id) ON DELETE CASCADE,
          FOREIGN KEY(source_file_id) REFERENCES files(id) ON DELETE CASCADE,
          FOREIGN KEY(source_symbol_id) REFERENCES symbols(id) ON DELETE SET NULL,
          FOREIGN KEY(target_file_id) REFERENCES files(id) ON DELETE SET NULL
        )
        """)
      
      // Index for forward queries (what does X depend on)
      try exec("CREATE INDEX IF NOT EXISTS idx_deps_source ON dependencies(source_file_id)")
      
      // Index for reverse queries (what depends on X)
      try exec("CREATE INDEX IF NOT EXISTS idx_deps_target ON dependencies(target_file_id)")
      try exec("CREATE INDEX IF NOT EXISTS idx_deps_target_path ON dependencies(target_path)")
      
      // Index for symbol lookups
      try exec("CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name)")
      try exec("CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id)")
      
      try exec("UPDATE rag_meta SET value = '5' WHERE key = 'schema_version'")
    }
    
    // Migration to v6: Add structural metrics for code intelligence queries (#174)
    // Enables queries like "find files >1000 lines" or "classes with >20 methods"
    if currentVersion < 6 {
      // Add line_count to files table
      if try !columnExists(table: "files", column: "line_count") {
        try exec("ALTER TABLE files ADD COLUMN line_count INTEGER DEFAULT 0")
      }
      
      // Add method_count to files table (populated from chunks with construct_type = 'function'/'method')
      if try !columnExists(table: "files", column: "method_count") {
        try exec("ALTER TABLE files ADD COLUMN method_count INTEGER DEFAULT 0")
      }
      
      // Add byte_size to files table
      if try !columnExists(table: "files", column: "byte_size") {
        try exec("ALTER TABLE files ADD COLUMN byte_size INTEGER DEFAULT 0")
      }
      
      // Index for structural queries
      try exec("CREATE INDEX IF NOT EXISTS idx_files_line_count ON files(line_count)")
      try exec("CREATE INDEX IF NOT EXISTS idx_files_method_count ON files(method_count)")
      
      try exec("UPDATE rag_meta SET value = '6' WHERE key = 'schema_version'")
    }
    
    // Migration to v7: Add AI analysis columns for code analyzer (#198)
    // Enables semantic summaries and tags from local MLX models
    if currentVersion < 7 {
      // AI-generated summary of the chunk content
      if try !columnExists(table: "chunks", column: "ai_summary") {
        try exec("ALTER TABLE chunks ADD COLUMN ai_summary TEXT")
      }
      
      // AI-generated semantic tags (JSON array)
      if try !columnExists(table: "chunks", column: "ai_tags") {
        try exec("ALTER TABLE chunks ADD COLUMN ai_tags TEXT")
      }
      
      // When this chunk was analyzed
      if try !columnExists(table: "chunks", column: "analyzed_at") {
        try exec("ALTER TABLE chunks ADD COLUMN analyzed_at TEXT")
      }
      
      // Which model was used for analysis (for cache invalidation when model changes)
      if try !columnExists(table: "chunks", column: "analyzer_model") {
        try exec("ALTER TABLE chunks ADD COLUMN analyzer_model TEXT")
      }
      
      // Index for finding unanalyzed chunks
      try exec("CREATE INDEX IF NOT EXISTS idx_chunks_analyzed ON chunks(analyzed_at)")
      
      try exec("UPDATE rag_meta SET value = '7' WHERE key = 'schema_version'")
    }
    
    schemaVersion = 7
    
    // Set up vec_chunks virtual table if extension is loaded
    if extensionLoaded {
      try ensureVecTable()
      try syncVecTable()
    }
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
    let aiSummary: String?
    let aiTags: [String]
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
      
      // AI analysis columns (10, 11) - schema v7+
      let aiSummary: String? = sqlite3_column_type(statement, 10) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 10)) : nil
      let aiTagsJson: String? = sqlite3_column_type(statement, 11) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 11)) : nil
      let aiTags: [String] = aiTagsJson.flatMap { json in
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
            featureTags: featureTags,
            aiSummary: aiSummary,
            aiTags: aiTags
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
      
      // AI analysis columns (9, 10) - schema v7+
      let aiSummary: String? = sqlite3_column_type(statement, 9) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 9)) : nil
      let aiTagsJson: String? = sqlite3_column_type(statement, 10) != SQLITE_NULL
        ? String(cString: sqlite3_column_text(statement, 10)) : nil
      let aiTags: [String] = aiTagsJson.flatMap { json in
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
          featureTags: featureTags,
          aiSummary: aiSummary,
          aiTags: aiTags
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
    featureTags: String?,
    lineCount: Int = 0,
    methodCount: Int = 0,
    byteSize: Int = 0
  ) throws {
    // Use INSERT ... ON CONFLICT to avoid cascade delete of chunks
    let sql = """
    INSERT INTO files (id, repo_id, path, hash, language, updated_at, module_path, feature_tags, line_count, method_count, byte_size)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      repo_id = excluded.repo_id,
      path = excluded.path,
      hash = excluded.hash,
      language = excluded.language,
      updated_at = excluded.updated_at,
      module_path = excluded.module_path,
      feature_tags = excluded.feature_tags,
      line_count = excluded.line_count,
      method_count = excluded.method_count,
      byte_size = excluded.byte_size
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
      sqlite3_bind_int(statement, 9, Int32(lineCount))
      sqlite3_bind_int(statement, 10, Int32(methodCount))
      sqlite3_bind_int(statement, 11, Int32(byteSize))
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
    metadata: String?,
    aiSummary: String? = nil,
    aiTags: String? = nil,
    analyzedAt: String? = nil,
    analyzerModel: String? = nil
  ) throws {
    let sql = """
    INSERT OR REPLACE INTO chunks (id, file_id, start_line, end_line, text, token_count, construct_type, construct_name, metadata, ai_summary, ai_tags, analyzed_at, analyzer_model)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
      // AI analysis columns
      if let aiSummary {
        bindText(statement, 10, aiSummary)
      } else {
        sqlite3_bind_null(statement, 10)
      }
      if let aiTags {
        bindText(statement, 11, aiTags)
      } else {
        sqlite3_bind_null(statement, 11)
      }
      if let analyzedAt {
        bindText(statement, 12, analyzedAt)
      } else {
        sqlite3_bind_null(statement, 12)
      }
      if let analyzerModel {
        bindText(statement, 13, analyzerModel)
      } else {
        sqlite3_bind_null(statement, 13)
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

    // Also sync to vec_chunks for accelerated search if extension is loaded
    if extensionLoaded {
      let vecSql = """
      INSERT OR REPLACE INTO vec_chunks (chunk_id, embedding)
      VALUES (?, ?)
      """
      try execute(sql: vecSql) { statement in
        bindText(statement, 1, chunkId)
        _ = data.withUnsafeBytes { bytes in
          sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), sqliteTransient)
        }
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
  
  // MARK: - Dependency Graph Methods (Issue #176)
  
  /// Extract dependencies from chunk metadata
  /// Parses imports, inheritance, and protocol conformance from AST metadata
  private func extractDependencies(
    from chunks: [LocalRAGChunk],
    repoId: String,
    fileId: String,
    relativePath: String,
    language: String
  ) -> [LocalRAGDependency] {
    var dependencies: [LocalRAGDependency] = []
    var seenImports = Set<String>()       // Dedupe imports across chunks
    var seenProtocols = Set<String>()     // Dedupe protocol conformance
    var seenInheritance = Set<String>()   // Dedupe inheritance
    var seenMixins = Set<String>()        // Dedupe Ruby mixins
    
    for chunk in chunks {
      guard let metadataJson = chunk.metadata,
            let metadataData = metadataJson.data(using: .utf8),
            let metadata = try? JSONDecoder().decode(ASTChunkMetadata.self, from: metadataData) else {
        continue
      }
      
      // Extract imports
      for importPath in metadata.imports {
        guard !seenImports.contains(importPath) else { continue }
        seenImports.insert(importPath)
        
        let depType = determineImportType(importPath: importPath, language: language)
        let resolvedTargetFile = resolveTargetFile(targetPath: importPath, inRepo: repoId, fromFile: relativePath)
        
        dependencies.append(LocalRAGDependency(
          repoId: repoId,
          sourceFileId: fileId,
          targetPath: importPath,
          targetFileId: resolvedTargetFile,
          dependencyType: depType,
          rawImport: importPath
        ))
      }
      
      // Extract superclass (inheritance)
      if let superclass = metadata.superclass {
        guard !seenInheritance.contains(superclass) else { continue }
        seenInheritance.insert(superclass)
        
        dependencies.append(LocalRAGDependency(
          repoId: repoId,
          sourceFileId: fileId,
          targetPath: superclass,
          targetSymbolName: superclass,
          dependencyType: .inherit,
          rawImport: superclass
        ))
      }
      
      // Extract protocol conformance
      for proto in metadata.protocols {
        guard !seenProtocols.contains(proto) else { continue }
        seenProtocols.insert(proto)
        
        dependencies.append(LocalRAGDependency(
          repoId: repoId,
          sourceFileId: fileId,
          targetPath: proto,
          targetSymbolName: proto,
          dependencyType: .conform,
          rawImport: proto
        ))
      }
      
      // Extract Ruby mixins (include/extend)
      for mixin in metadata.mixins {
        guard !seenMixins.contains(mixin) else { continue }
        seenMixins.insert(mixin)
        
        // Ruby mixins can be "include Foo" or "extend Bar"
        let depType: LocalRAGDependencyType = mixin.lowercased().hasPrefix("extend") ? .extend : .include
        let moduleName = mixin.replacingOccurrences(of: "include ", with: "")
                              .replacingOccurrences(of: "extend ", with: "")
                              .trimmingCharacters(in: .whitespaces)
        dependencies.append(LocalRAGDependency(
          repoId: repoId,
          sourceFileId: fileId,
          targetPath: moduleName,
          targetSymbolName: moduleName,
          dependencyType: depType,
          rawImport: mixin
        ))
      }
    }
    
    return dependencies
  }
  
  /// Determine the import type based on language and import syntax
  private func determineImportType(importPath: String, language: String) -> LocalRAGDependencyType {
    let lowercased = importPath.lowercased()
    
    // Ruby
    if language == "ruby" || language == "Ruby" {
      if lowercased.hasPrefix("require_relative") || lowercased.hasPrefix("require ") {
        return .require
      }
    }
    
    // Default to import for Swift, TypeScript, JavaScript
    return .import
  }
  
  /// Insert a dependency relationship
  func insertDependency(_ dep: LocalRAGDependency) throws {
    let sql = """
      INSERT OR REPLACE INTO dependencies 
        (id, repo_id, source_file_id, source_symbol_id, target_path, target_symbol_name, target_file_id, dependency_type, raw_import)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    try execute(sql: sql) { statement in
      bindText(statement, 1, dep.id)
      bindText(statement, 2, dep.repoId)
      bindText(statement, 3, dep.sourceFileId)
      if let symbolId = dep.sourceSymbolId {
        bindText(statement, 4, symbolId)
      } else {
        sqlite3_bind_null(statement, 4)
      }
      bindText(statement, 5, dep.targetPath)
      if let targetSymbol = dep.targetSymbolName {
        bindText(statement, 6, targetSymbol)
      } else {
        sqlite3_bind_null(statement, 6)
      }
      if let targetFileId = dep.targetFileId {
        bindText(statement, 7, targetFileId)
      } else {
        sqlite3_bind_null(statement, 7)
      }
      bindText(statement, 8, dep.dependencyType.rawValue)
      bindText(statement, 9, dep.rawImport)
    }
  }
  
  /// Insert multiple dependencies in a transaction
  func insertDependencies(_ deps: [LocalRAGDependency]) throws {
    guard !deps.isEmpty else { return }
    try exec("BEGIN TRANSACTION")
    do {
      for dep in deps {
        try insertDependency(dep)
      }
      try exec("COMMIT")
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }
  
  /// Delete all dependencies for a file (called before re-indexing)
  func deleteDependencies(for fileId: String) throws {
    let sql = "DELETE FROM dependencies WHERE source_file_id = ?"
    try execute(sql: sql) { statement in
      bindText(statement, 1, fileId)
    }
  }
  
  /// Delete all dependencies for a repo
  func deleteDependencies(forRepo repoId: String) throws {
    let sql = "DELETE FROM dependencies WHERE repo_id = ?"
    try execute(sql: sql) { statement in
      bindText(statement, 1, repoId)
    }
  }
  
  /// Get what a file depends on (forward dependencies)
  /// - Parameters:
  ///   - filePath: Relative path of the file within the repo (or filename for fuzzy match)
  ///   - repoPath: Root path of the repository
  /// - Returns: List of dependencies (what this file imports/requires)
  func getDependencies(for filePath: String, inRepo repoPath: String) throws -> [LocalRAGDependencyResult] {
    try openIfNeeded()
    
    let sql = """
      SELECT 
        files.path as source_file,
        d.target_path,
        target_files.path as target_file,
        d.dependency_type,
        d.raw_import
      FROM dependencies d
      JOIN files ON files.id = d.source_file_id
      JOIN repos ON repos.id = d.repo_id
      LEFT JOIN files target_files ON target_files.id = d.target_file_id
      WHERE repos.root_path = ? AND (
        files.path = ? OR
        files.path LIKE ?
      )
      ORDER BY d.dependency_type, d.target_path
      """
    
    return try queryDependencies(sql: sql) { statement in
      bindText(statement, 1, repoPath)
      bindText(statement, 2, filePath)
      // Support filename-only queries (e.g., "LocalRAGStore.swift" matches "Shared/Services/LocalRAGStore.swift")
      bindText(statement, 3, "%/\(filePath)")
    }
  }
  
  /// Get what depends on a file (reverse dependencies)
  /// - Parameters:
  ///   - filePath: Relative path of the file within the repo
  ///   - repoPath: Root path of the repository
  /// - Returns: List of files that depend on this file
  func getDependents(for filePath: String, inRepo repoPath: String) throws -> [LocalRAGDependencyResult] {
    try openIfNeeded()
    
    // First, get the file ID for the target file
    let fileIdSql = """
      SELECT files.id FROM files
      JOIN repos ON repos.id = files.repo_id
      WHERE files.path = ? AND repos.root_path = ?
      """
    
    var targetFileId: String?
    var statement: OpaquePointer?
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    var result = sqlite3_prepare_v2(db, fileIdSql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt = statement else {
      throw LocalRAGError.sqlite("Failed to prepare statement")
    }
    defer { sqlite3_finalize(stmt) }
    
    bindText(stmt, 1, filePath)
    bindText(stmt, 2, repoPath)
    
    if sqlite3_step(stmt) == SQLITE_ROW {
      if let text = sqlite3_column_text(stmt, 0) {
        targetFileId = String(cString: text)
      }
    }
    
    // Query by both resolved file_id and by target_path (for unresolved imports)
    // This handles both: imports within the same repo (resolved) and external imports (path match)
    let sql = """
      SELECT 
        source_files.path as source_file,
        d.target_path,
        target_files.path as target_file,
        d.dependency_type,
        d.raw_import
      FROM dependencies d
      JOIN files source_files ON source_files.id = d.source_file_id
      JOIN repos ON repos.id = d.repo_id
      LEFT JOIN files target_files ON target_files.id = d.target_file_id
      WHERE repos.root_path = ? AND (
        d.target_file_id = ? OR
        d.target_path = ? OR
        d.target_path LIKE ?
      )
      ORDER BY source_files.path
      """
    
    return try queryDependencies(sql: sql) { statement in
      bindText(statement, 1, repoPath)
      bindText(statement, 2, targetFileId ?? "")
      bindText(statement, 3, filePath)
      // Also match partial paths (e.g., "./utils" matching "src/utils.ts")
      bindText(statement, 4, "%/\(filePath)")
    }
  }
  
  /// Get dependency statistics for a repo
  func getDependencyStats(for repoPath: String) throws -> (totalDeps: Int, byType: [String: Int]) {
    try openIfNeeded()
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    let sql = """
      SELECT d.dependency_type, COUNT(*) as count
      FROM dependencies d
      JOIN repos ON repos.id = d.repo_id
      WHERE repos.root_path = ?
      GROUP BY d.dependency_type
      """
    
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt = statement else {
      throw LocalRAGError.sqlite("Failed to prepare statement")
    }
    defer { sqlite3_finalize(stmt) }
    
    bindText(stmt, 1, repoPath)
    
    var byType: [String: Int] = [:]
    var total = 0
    
    while sqlite3_step(stmt) == SQLITE_ROW {
      if let typeText = sqlite3_column_text(stmt, 0) {
        let typeName = String(cString: typeText)
        let count = Int(sqlite3_column_int(stmt, 1))
        byType[typeName] = count
        total += count
      }
    }
    
    return (total, byType)
  }
  
  /// Helper to query dependencies and map results
  private func queryDependencies(sql: String, binder: (OpaquePointer) -> Void) throws -> [LocalRAGDependencyResult] {
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt = statement else {
      throw LocalRAGError.sqlite("Failed to prepare statement")
    }
    defer { sqlite3_finalize(stmt) }
    
    binder(stmt)
    
    var results: [LocalRAGDependencyResult] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let sourceFile = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
      let targetPath = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
      let targetFile = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
      let depTypeStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "import"
      let rawImport = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
      
      let depType = LocalRAGDependencyType(rawValue: depTypeStr) ?? .import
      
      results.append(LocalRAGDependencyResult(
        sourceFile: sourceFile,
        targetPath: targetPath,
        targetFile: targetFile,
        dependencyType: depType,
        rawImport: rawImport
      ))
    }
    
    return results
  }
  
  /// Resolve target path to a file ID within the repo (for internal dependencies)
  func resolveTargetFile(targetPath: String, inRepo repoId: String, fromFile sourceFile: String) -> String? {
    // Try to resolve relative paths
    let candidates = generateResolutionCandidates(targetPath: targetPath, sourceFile: sourceFile)
    
    for candidate in candidates {
      if let fileId = try? findFileByPath(candidate, inRepo: repoId) {
        return fileId
      }
    }
    
    return nil
  }
  
  /// Generate candidate paths for resolving an import
  private func generateResolutionCandidates(targetPath: String, sourceFile: String) -> [String] {
    var candidates: [String] = []
    
    // Get directory of source file
    let sourceDir = (sourceFile as NSString).deletingLastPathComponent
    
    // Handle relative paths
    if targetPath.hasPrefix("./") || targetPath.hasPrefix("../") {
      var relativePath = targetPath
      // Normalize ../ paths
      while relativePath.hasPrefix("../") {
        relativePath = String(relativePath.dropFirst(3))
      }
      relativePath = relativePath.replacingOccurrences(of: "./", with: "")
      let resolved = (sourceDir as NSString).appendingPathComponent(relativePath)
      candidates.append(resolved)
      // Try with common extensions
      for ext in ["", ".swift", ".ts", ".tsx", ".js", ".jsx", ".rb", ".py"] {
        candidates.append(resolved + ext)
      }
    } else {
      // Absolute or module import - try exact first
      candidates.append(targetPath)
      
      // Try common directory structures
      let commonPrefixes = ["", "src/", "lib/", "app/", "Shared/", "Sources/"]
      for prefix in commonPrefixes {
        for ext in ["", ".swift", ".ts", ".tsx", ".js", ".jsx", ".rb", ".py", "/index.ts", "/index.js", "/index.tsx"] {
          candidates.append(prefix + targetPath + ext)
        }
      }
      
      // For Ruby - try converting module path to file path (Foo::Bar -> foo/bar.rb)
      if targetPath.contains("::") {
        let rubyPath = targetPath.replacingOccurrences(of: "::", with: "/").lowercased()
        for prefix in ["", "app/models/", "app/services/", "lib/"] {
          candidates.append(prefix + rubyPath + ".rb")
        }
      }
    }
    
    return candidates
  }
  
  /// Find a file by relative path within a repo (exact match or suffix match)
  private func findFileByPath(_ path: String, inRepo repoId: String) throws -> String? {
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    // Try exact match first
    let exactSql = "SELECT id FROM files WHERE path = ? AND repo_id = ?"
    var statement: OpaquePointer?
    var result = sqlite3_prepare_v2(db, exactSql, -1, &statement, nil)
    if result == SQLITE_OK, let stmt = statement {
      bindText(stmt, 1, path)
      bindText(stmt, 2, repoId)
      
      if sqlite3_step(stmt) == SQLITE_ROW {
        if let text = sqlite3_column_text(stmt, 0) {
          sqlite3_finalize(stmt)
          return String(cString: text)
        }
      }
      sqlite3_finalize(stmt)
    }
    
    // Try suffix match (e.g., "LocalRAGStore" matches "Shared/Services/LocalRAGStore.swift")
    let suffixSql = "SELECT id FROM files WHERE (path LIKE ? OR path LIKE ?) AND repo_id = ? LIMIT 1"
    result = sqlite3_prepare_v2(db, suffixSql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt = statement else { return nil }
    defer { sqlite3_finalize(stmt) }
    
    bindText(stmt, 1, "%/\(path)")
    bindText(stmt, 2, "%/\(path).%")  // Handle extension-less imports
    bindText(stmt, 3, repoId)
    
    if sqlite3_step(stmt) == SQLITE_ROW {
      if let text = sqlite3_column_text(stmt, 0) {
        return String(cString: text)
      }
    }
    return nil
  }
  
  // MARK: - Structural Queries (Issue #174)
  
  /// Result type for structural queries
  struct LocalRAGStructuralResult: Sendable {
    let path: String
    let language: String
    let lineCount: Int
    let methodCount: Int
    let byteSize: Int
    let modulePath: String?
  }
  
  /// Query files by structural characteristics (line count, method count, file size)
  /// - Parameters:
  ///   - repoPath: Root path of the repository
  ///   - minLines: Minimum line count (optional)
  ///   - maxLines: Maximum line count (optional)
  ///   - minMethods: Minimum method count (optional)
  ///   - maxMethods: Maximum method count (optional)
  ///   - minBytes: Minimum file size in bytes (optional)
  ///   - maxBytes: Maximum file size in bytes (optional)
  ///   - language: Filter by language (optional)
  ///   - sortBy: Sort field - "lines", "methods", "bytes" (default: "lines")
  ///   - limit: Maximum results (default: 50)
  /// - Returns: List of files matching the criteria
  func queryFilesByStructure(
    inRepo repoPath: String,
    minLines: Int? = nil,
    maxLines: Int? = nil,
    minMethods: Int? = nil,
    maxMethods: Int? = nil,
    minBytes: Int? = nil,
    maxBytes: Int? = nil,
    language: String? = nil,
    sortBy: String = "lines",
    limit: Int = 50
  ) throws -> [LocalRAGStructuralResult] {
    try openIfNeeded()
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    // Build WHERE clauses dynamically
    var conditions = ["repos.root_path = ?"]
    var params: [Any] = [repoPath]
    
    if let minLines {
      conditions.append("files.line_count >= ?")
      params.append(minLines)
    }
    if let maxLines {
      conditions.append("files.line_count <= ?")
      params.append(maxLines)
    }
    if let minMethods {
      conditions.append("files.method_count >= ?")
      params.append(minMethods)
    }
    if let maxMethods {
      conditions.append("files.method_count <= ?")
      params.append(maxMethods)
    }
    if let minBytes {
      conditions.append("files.byte_size >= ?")
      params.append(minBytes)
    }
    if let maxBytes {
      conditions.append("files.byte_size <= ?")
      params.append(maxBytes)
    }
    if let language, !language.isEmpty {
      conditions.append("files.language = ?")
      params.append(language)
    }
    
    // Determine sort column
    let sortColumn: String
    switch sortBy.lowercased() {
    case "methods": sortColumn = "files.method_count"
    case "bytes", "size": sortColumn = "files.byte_size"
    default: sortColumn = "files.line_count"
    }
    
    let sql = """
      SELECT files.path, files.language, 
             COALESCE(files.line_count, 0) as line_count,
             COALESCE(files.method_count, 0) as method_count,
             COALESCE(files.byte_size, 0) as byte_size,
             files.module_path
      FROM files
      JOIN repos ON repos.id = files.repo_id
      WHERE \(conditions.joined(separator: " AND "))
      ORDER BY \(sortColumn) DESC
      LIMIT ?
      """
    
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt = statement else {
      throw LocalRAGError.sqlite("Failed to prepare structural query")
    }
    defer { sqlite3_finalize(stmt) }
    
    // Bind parameters
    var paramIndex: Int32 = 1
    for param in params {
      if let str = param as? String {
        bindText(stmt, paramIndex, str)
      } else if let int = param as? Int {
        sqlite3_bind_int(stmt, paramIndex, Int32(int))
      }
      paramIndex += 1
    }
    sqlite3_bind_int(stmt, paramIndex, Int32(limit))
    
    var results: [LocalRAGStructuralResult] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let path = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
      let lang = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
      let lines = Int(sqlite3_column_int(stmt, 2))
      let methods = Int(sqlite3_column_int(stmt, 3))
      let bytes = Int(sqlite3_column_int(stmt, 4))
      let modulePath = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
      
      results.append(LocalRAGStructuralResult(
        path: path,
        language: lang,
        lineCount: lines,
        methodCount: methods,
        byteSize: bytes,
        modulePath: modulePath
      ))
    }
    
    return results
  }
  
  /// Get structural statistics for a repository
  func getStructuralStats(for repoPath: String) throws -> (
    totalFiles: Int,
    totalLines: Int,
    totalMethods: Int,
    avgLinesPerFile: Double,
    avgMethodsPerFile: Double,
    largestFile: (path: String, lines: Int)?,
    mostMethods: (path: String, count: Int)?
  ) {
    try openIfNeeded()
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    // Aggregate stats
    let statsSql = """
      SELECT 
        COUNT(*) as file_count,
        COALESCE(SUM(line_count), 0) as total_lines,
        COALESCE(SUM(method_count), 0) as total_methods
      FROM files
      JOIN repos ON repos.id = files.repo_id
      WHERE repos.root_path = ?
      """
    
    var statement: OpaquePointer?
    var result = sqlite3_prepare_v2(db, statsSql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt = statement else {
      throw LocalRAGError.sqlite("Failed to prepare stats query")
    }
    
    bindText(stmt, 1, repoPath)
    
    var totalFiles = 0
    var totalLines = 0
    var totalMethods = 0
    
    if sqlite3_step(stmt) == SQLITE_ROW {
      totalFiles = Int(sqlite3_column_int(stmt, 0))
      totalLines = Int(sqlite3_column_int(stmt, 1))
      totalMethods = Int(sqlite3_column_int(stmt, 2))
    }
    sqlite3_finalize(stmt)
    
    // Largest file by lines
    let largestSql = """
      SELECT files.path, COALESCE(files.line_count, 0) as lines
      FROM files
      JOIN repos ON repos.id = files.repo_id
      WHERE repos.root_path = ?
      ORDER BY lines DESC
      LIMIT 1
      """
    
    result = sqlite3_prepare_v2(db, largestSql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt2 = statement else {
      throw LocalRAGError.sqlite("Failed to prepare largest file query")
    }
    
    bindText(stmt2, 1, repoPath)
    
    var largestFile: (String, Int)?
    if sqlite3_step(stmt2) == SQLITE_ROW {
      let path = sqlite3_column_text(stmt2, 0).map { String(cString: $0) } ?? ""
      let lines = Int(sqlite3_column_int(stmt2, 1))
      if lines > 0 {
        largestFile = (path, lines)
      }
    }
    sqlite3_finalize(stmt2)
    
    // Most methods
    let mostMethodsSql = """
      SELECT files.path, COALESCE(files.method_count, 0) as methods
      FROM files
      JOIN repos ON repos.id = files.repo_id
      WHERE repos.root_path = ?
      ORDER BY methods DESC
      LIMIT 1
      """
    
    result = sqlite3_prepare_v2(db, mostMethodsSql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt3 = statement else {
      throw LocalRAGError.sqlite("Failed to prepare most methods query")
    }
    
    bindText(stmt3, 1, repoPath)
    
    var mostMethods: (String, Int)?
    if sqlite3_step(stmt3) == SQLITE_ROW {
      let path = sqlite3_column_text(stmt3, 0).map { String(cString: $0) } ?? ""
      let count = Int(sqlite3_column_int(stmt3, 1))
      if count > 0 {
        mostMethods = (path, count)
      }
    }
    sqlite3_finalize(stmt3)
    
    let avgLines = totalFiles > 0 ? Double(totalLines) / Double(totalFiles) : 0
    let avgMethods = totalFiles > 0 ? Double(totalMethods) / Double(totalFiles) : 0
    
    return (totalFiles, totalLines, totalMethods, avgLines, avgMethods, largestFile, mostMethods)
  }
  
  // MARK: - Similar Code Detection (Issue #175)
  
  /// Result type for similar code queries
  struct LocalRAGSimilarResult: Sendable {
    let path: String
    let startLine: Int
    let endLine: Int
    let snippet: String
    let similarity: Double  // 0.0 to 1.0
    let constructType: String?
    let constructName: String?
  }
  
  /// Find code chunks similar to a given code snippet or text query
  /// Uses embedding-based semantic similarity search
  /// - Parameters:
  ///   - query: Code snippet or text to find similar code for
  ///   - repoPath: Repository to search in (optional - searches all if nil)
  ///   - threshold: Minimum similarity score (0.0-1.0, default: 0.6)
  ///   - limit: Maximum results (default: 10)
  ///   - excludePath: File path to exclude from results (useful when finding code similar to an existing file)
  /// - Returns: List of similar code chunks ordered by similarity
  func findSimilarCode(
    query: String,
    repoPath: String? = nil,
    threshold: Double = 0.6,
    limit: Int = 10,
    excludePath: String? = nil
  ) async throws -> [LocalRAGSimilarResult] {
    try openIfNeeded()
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    // Generate embedding for the query using self method
    let embeddings = try await generateEmbeddings(for: [query])
    guard let queryEmbedding = embeddings.first, !queryEmbedding.isEmpty else {
      throw LocalRAGError.embeddingFailed("Failed to generate embedding for query")
    }
    
    // Use vector search (accelerated if extension loaded, otherwise brute-force)
    if extensionLoaded {
      return try findSimilarCodeAccelerated(
        queryVector: queryEmbedding,
        repoPath: repoPath,
        threshold: threshold,
        limit: limit,
        excludePath: excludePath
      )
    } else {
      return try findSimilarCodeBruteForce(
        queryVector: queryEmbedding,
        repoPath: repoPath,
        threshold: threshold,
        limit: limit,
        excludePath: excludePath
      )
    }
  }
  
  /// Find similar code using sqlite-vec accelerated search
  private func findSimilarCodeAccelerated(
    queryVector: [Float],
    repoPath: String?,
    threshold: Double,
    limit: Int,
    excludePath: String?
  ) throws -> [LocalRAGSimilarResult] {
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    // Use vec_chunks table for accelerated search
    // vec0 distance function returns L2 distance, we need to convert to similarity
    let sql = """
      SELECT 
        c.id,
        f.path,
        c.start_line,
        c.end_line,
        c.snippet,
        c.construct_type,
        c.construct_name,
        vec_distance_cosine(v.embedding, ?) as distance
      FROM vec_chunks v
      JOIN chunks c ON c.id = v.chunk_id
      JOIN files f ON f.id = c.file_id
      JOIN repos r ON r.id = f.repo_id
      WHERE (\(repoPath == nil ? "1=1" : "r.root_path = ?"))
        \(excludePath != nil ? "AND f.path != ?" : "")
      ORDER BY distance ASC
      LIMIT ?
      """
    
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt = statement else {
      throw LocalRAGError.sqlite("Failed to prepare similar code query")
    }
    defer { sqlite3_finalize(stmt) }
    
    // Bind query vector as blob
    let vectorData = queryVector.withUnsafeBytes { Data($0) }
    vectorData.withUnsafeBytes { ptr in
      sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(vectorData.count), nil)
    }
    
    var paramIndex: Int32 = 2
    if let repoPath {
      bindText(stmt, paramIndex, repoPath)
      paramIndex += 1
    }
    if let excludePath {
      bindText(stmt, paramIndex, excludePath)
      paramIndex += 1
    }
    sqlite3_bind_int(stmt, paramIndex, Int32(limit * 2))  // Fetch more to filter by threshold
    
    var results: [LocalRAGSimilarResult] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let path = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
      let startLine = Int(sqlite3_column_int(stmt, 2))
      let endLine = Int(sqlite3_column_int(stmt, 3))
      let snippet = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
      let constructType = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
      let constructName = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
      let distance = sqlite3_column_double(stmt, 7)
      
      // Convert cosine distance to similarity (1 - distance for normalized vectors)
      let similarity = max(0.0, 1.0 - distance)
      
      guard similarity >= threshold else { continue }
      
      results.append(LocalRAGSimilarResult(
        path: path,
        startLine: startLine,
        endLine: endLine,
        snippet: snippet,
        similarity: similarity,
        constructType: constructType,
        constructName: constructName
      ))
      
      if results.count >= limit { break }
    }
    
    return results
  }
  
  /// Find similar code using brute-force cosine similarity
  private func findSimilarCodeBruteForce(
    queryVector: [Float],
    repoPath: String?,
    threshold: Double,
    limit: Int,
    excludePath: String?
  ) throws -> [LocalRAGSimilarResult] {
    guard let db else { throw LocalRAGError.sqlite("Database not initialized") }
    
    // Query all embeddings with chunk metadata
    var sql = """
      SELECT 
        e.embedding,
        c.id,
        f.path,
        c.start_line,
        c.end_line,
        c.snippet,
        c.construct_type,
        c.construct_name
      FROM embeddings e
      JOIN chunks c ON c.id = e.chunk_id
      JOIN files f ON f.id = c.file_id
      JOIN repos r ON r.id = f.repo_id
      WHERE 1=1
      """
    
    if repoPath != nil {
      sql += " AND r.root_path = ?"
    }
    if excludePath != nil {
      sql += " AND f.path != ?"
    }
    
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let stmt = statement else {
      let errMsg = String(cString: sqlite3_errmsg(db))
      throw LocalRAGError.sqlite("Failed to prepare brute-force similarity query: \(errMsg) (code \(result))")
    }
    defer { sqlite3_finalize(stmt) }
    
    var paramIndex: Int32 = 1
    if let repoPath {
      bindText(stmt, paramIndex, repoPath)
      paramIndex += 1
    }
    if let excludePath {
      bindText(stmt, paramIndex, excludePath)
    }
    
    var candidates: [(path: String, startLine: Int, endLine: Int, snippet: String, similarity: Double, constructType: String?, constructName: String?)] = []
    
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let embeddingBlob = sqlite3_column_blob(stmt, 0) else { continue }
      let embeddingBytes = sqlite3_column_bytes(stmt, 0)
      
      // Parse embedding
      let floatCount = Int(embeddingBytes) / MemoryLayout<Float>.size
      let embeddingVector = Array(UnsafeBufferPointer(
        start: embeddingBlob.assumingMemoryBound(to: Float.self),
        count: floatCount
      ))
      
      // Calculate cosine similarity (use existing method, convert Float -> Double)
      let similarityFloat = self.cosineSimilarity(queryVector, embeddingVector)
      let similarity = Double(similarityFloat)
      guard similarity >= threshold else { continue }
      
      let path = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
      let startLine = Int(sqlite3_column_int(stmt, 3))
      let endLine = Int(sqlite3_column_int(stmt, 4))
      let snippet = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
      let constructType = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
      let constructName = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
      
      candidates.append((path, startLine, endLine, snippet, similarity, constructType, constructName))
    }
    
    // Sort by similarity descending and take top results
    candidates.sort { $0.similarity > $1.similarity }
    
    return candidates.prefix(limit).map { c in
      LocalRAGSimilarResult(
        path: c.path,
        startLine: c.startLine,
        endLine: c.endLine,
        snippet: c.snippet,
        similarity: c.similarity,
        constructType: c.constructType,
        constructName: c.constructName
      )
    }
  }
}

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
