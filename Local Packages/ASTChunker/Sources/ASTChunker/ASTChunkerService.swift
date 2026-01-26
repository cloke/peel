//
//  ASTChunkerService.swift
//  ASTChunker
//
//  Main entry point for AST-based chunking across multiple languages.
//

import Foundation

/// Service that provides AST-aware chunking for multiple languages
public struct ASTChunkerService: Sendable {
  
  /// Default maximum lines per chunk
  public static let defaultMaxChunkLines = 150
  
  private let swiftChunker = SwiftChunker()
  private let rubyChunker: RubyChunker?
  
  public init(
    treeSitterLibPath: String? = nil,
    treeSitterCLIPath: String? = nil
  ) {
    // Initialize Ruby chunker if tree-sitter is available
    let cliPath = treeSitterCLIPath ?? "/opt/homebrew/bin/tree-sitter"
    let libPath = treeSitterLibPath ?? (("~/code/tree-sitter-grammars/tree-sitter-ruby/ruby.dylib" as NSString).expandingTildeInPath)
    
    if FileManager.default.fileExists(atPath: cliPath) &&
       FileManager.default.fileExists(atPath: libPath) {
      self.rubyChunker = RubyChunker(treeSitterLibPath: libPath, treeSitterCLIPath: cliPath)
    } else {
      self.rubyChunker = nil
    }
  }
  
  /// Chunk source code with automatic language detection
  /// - Parameters:
  ///   - source: The source code to chunk
  ///   - filename: Filename to detect language from extension
  ///   - maxChunkLines: Maximum lines per chunk
  /// - Returns: Array of semantic chunks
  public func chunk(
    source: String,
    filename: String,
    maxChunkLines: Int = defaultMaxChunkLines
  ) -> [ASTChunk] {
    let language = detectLanguage(for: filename)
    
    switch language {
    case "swift":
      return swiftChunker.chunk(source: source, maxChunkLines: maxChunkLines)
    case "ruby":
      if let rubyChunker = rubyChunker {
        return rubyChunker.chunk(source: source, maxChunkLines: maxChunkLines)
      }
      return fallbackChunk(source: source, language: language, maxChunkLines: maxChunkLines)
    default:
      return fallbackChunk(source: source, language: language, maxChunkLines: maxChunkLines)
    }
  }
  
  /// Detect language from filename
  public func detectLanguage(for filename: String) -> String {
    let lowercased = filename.lowercased()
    let ext = (lowercased as NSString).pathExtension
    
    // Swift
    if ext == "swift" {
      return "swift"
    }
    
    // Ruby (for future)
    if ext == "rb" || ext == "rake" || ext == "gemspec" ||
       lowercased.hasSuffix("gemfile") || lowercased.hasSuffix("rakefile") {
      return "ruby"
    }
    
    // TypeScript/JavaScript (for future)
    if ["ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs", "gts", "gjs"].contains(ext) {
      return "typescript"
    }
    
    // Python (future)
    if ext == "py" {
      return "python"
    }
    
    // Rust (future)
    if ext == "rs" {
      return "rust"
    }
    
    return "unknown"
  }
  
  /// Basic line-based chunking fallback
  private func fallbackChunk(
    source: String,
    language: String,
    maxChunkLines: Int
  ) -> [ASTChunk] {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else { return [] }
    
    var chunks: [ASTChunk] = []
    var start = 0
    
    while start < lines.count {
      let end = min(start + maxChunkLines, lines.count)
      let chunkLines = lines[start..<end]
      
      chunks.append(ASTChunk(
        constructType: .file,
        constructName: nil,
        startLine: start + 1,
        endLine: end,
        text: chunkLines.joined(separator: "\n"),
        language: language
      ))
      
      start = end
    }
    
    return chunks
  }
}
