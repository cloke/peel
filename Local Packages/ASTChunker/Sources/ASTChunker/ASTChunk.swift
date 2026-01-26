//
//  ASTChunk.swift
//  ASTChunker
//
//  Represents a semantic chunk of code extracted via AST analysis.
//

import Foundation

/// A semantic chunk extracted from source code using AST analysis
public struct ASTChunk: Sendable, Equatable {
  /// The type of code construct this chunk represents
  public enum ConstructType: String, Sendable, CaseIterable {
    case file           // Entire file or fallback chunk
    case imports        // Import block
    case classDecl      // Class definition
    case structDecl     // Struct definition
    case enumDecl       // Enum definition
    case protocolDecl   // Protocol definition
    case `extension`    // Extension
    case actorDecl      // Actor definition
    case function       // Top-level function
    case method         // Method within a type
    case property       // Computed property (if large)
    case module         // Ruby/Python module
    case component      // UI Component (Ember/React)
    case unknown
  }
  
  /// The construct type
  public let constructType: ConstructType
  
  /// Name of the construct (e.g., "MyClass", "MyClass.loadData")
  public let constructName: String?
  
  /// 1-indexed start line in the source file
  public let startLine: Int
  
  /// 1-indexed end line in the source file (inclusive)
  public let endLine: Int
  
  /// The actual source text of this chunk
  public let text: String
  
  /// Language identifier (e.g., "swift", "ruby", "typescript")
  public let language: String
  
  /// Number of lines in this chunk
  public var lineCount: Int {
    endLine - startLine + 1
  }
  
  /// Estimated token count for embedding budget (~4 chars per token for code)
  public var estimatedTokenCount: Int {
    max(1, text.count / 4)
  }
  
  public init(
    constructType: ConstructType,
    constructName: String?,
    startLine: Int,
    endLine: Int,
    text: String,
    language: String
  ) {
    self.constructType = constructType
    self.constructName = constructName
    self.startLine = startLine
    self.endLine = endLine
    self.text = text
    self.language = language
  }
}

extension ASTChunk: CustomStringConvertible {
  public var description: String {
    let name = constructName ?? "<anonymous>"
    return "\(constructType.rawValue): \(name) (lines \(startLine)-\(endLine))"
  }
}
