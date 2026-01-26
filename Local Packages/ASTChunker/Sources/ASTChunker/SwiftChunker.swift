//
//  SwiftChunker.swift
//  ASTChunker
//
//  AST-based chunker for Swift source files using SwiftSyntax.
//

import Foundation
import SwiftParser
import SwiftSyntax

/// AST-based chunker for Swift source files using Apple's SwiftSyntax
public struct SwiftChunker: LanguageChunker, Sendable {
  public static let language = "swift"
  public static let fileExtensions: Set<String> = ["swift"]
  
  public init() {}
  
  public func chunk(source: String, maxChunkLines: Int = 150) -> [ASTChunk] {
    let sourceFile = Parser.parse(source: source)
    let lineMap = LineMap(source: source)
    var chunks: [ASTChunk] = []
    
    // Collect imports
    var importStatements: [ImportDeclSyntax] = []
    
    // Process top-level statements
    for statement in sourceFile.statements {
      let item = statement.item
      
      // Collect imports to group them
      if let importDecl = item.as(ImportDeclSyntax.self) {
        importStatements.append(importDecl)
        continue
      }
      
      // Process declarations - try each declaration type
      processItem(
        item,
        lineMap: lineMap,
        maxChunkLines: maxChunkLines,
        chunks: &chunks
      )
    }
    
    // Create import chunk if we have imports
    if !importStatements.isEmpty {
      let startLine = lineMap.line(for: importStatements.first!.position)
      let endLine = lineMap.line(for: importStatements.last!.endPosition)
      let text = lineMap.text(from: startLine, to: endLine)
      
      chunks.insert(ASTChunk(
        constructType: .imports,
        constructName: nil,
        startLine: startLine,
        endLine: endLine,
        text: text,
        language: Self.language
      ), at: 0)
    }
    
    // Sort by line number
    chunks.sort { $0.startLine < $1.startLine }
    
    // Fallback if no chunks
    if chunks.isEmpty && !source.isEmpty {
      return fallbackChunks(source: source, lineMap: lineMap, maxChunkLines: maxChunkLines)
    }
    
    return chunks
  }
  
  // MARK: - Declaration Processing
  
  /// Process a code block item, checking for various declaration types
  private func processItem(
    _ item: CodeBlockItemSyntax.Item,
    lineMap: LineMap,
    maxChunkLines: Int,
    chunks: inout [ASTChunk]
  ) {
    // Try each declaration type we care about
    if let classDecl = item.as(ClassDeclSyntax.self) {
      processDeclaration(classDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil)
    } else if let structDecl = item.as(StructDeclSyntax.self) {
      processDeclaration(structDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil)
    } else if let enumDecl = item.as(EnumDeclSyntax.self) {
      processDeclaration(enumDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil)
    } else if let protocolDecl = item.as(ProtocolDeclSyntax.self) {
      processDeclaration(protocolDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil)
    } else if let extensionDecl = item.as(ExtensionDeclSyntax.self) {
      processDeclaration(extensionDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil)
    } else if let actorDecl = item.as(ActorDeclSyntax.self) {
      processDeclaration(actorDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil)
    } else if let funcDecl = item.as(FunctionDeclSyntax.self) {
      processDeclaration(funcDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil)
    }
    // Ignore other statement types (variables, expressions, etc.)
  }
  
  private func processDeclaration(
    _ decl: any DeclSyntaxProtocol,
    lineMap: LineMap,
    maxChunkLines: Int,
    chunks: inout [ASTChunk],
    parentName: String?
  ) {
    let (constructType, name) = extractTypeAndName(from: decl)
    
    // Skip unknown declarations
    guard constructType != .unknown else { return }
    
    // Use positionAfterSkippingLeadingTrivia to get actual declaration start (not leading whitespace)
    let startLine = lineMap.line(for: decl.positionAfterSkippingLeadingTrivia)
    let endLine = lineMap.line(for: decl.endPositionBeforeTrailingTrivia)
    let lineCount = endLine - startLine + 1
    let fullName = combineName(parent: parentName, child: name)
    
    if lineCount <= maxChunkLines {
      // Small enough - single chunk
      let text = lineMap.text(from: startLine, to: endLine)
      chunks.append(ASTChunk(
        constructType: constructType,
        constructName: fullName,
        startLine: startLine,
        endLine: endLine,
        text: text,
        language: Self.language
      ))
    } else {
      // Too large - split by members
      splitLargeDeclaration(
        decl,
        constructType: constructType,
        constructName: fullName,
        lineMap: lineMap,
        maxChunkLines: maxChunkLines,
        chunks: &chunks
      )
    }
  }
  
  private func extractTypeAndName(from decl: any DeclSyntaxProtocol) -> (ASTChunk.ConstructType, String?) {
    switch decl {
    case let classDecl as ClassDeclSyntax:
      return (.classDecl, classDecl.name.text)
    case let structDecl as StructDeclSyntax:
      return (.structDecl, structDecl.name.text)
    case let enumDecl as EnumDeclSyntax:
      return (.enumDecl, enumDecl.name.text)
    case let protocolDecl as ProtocolDeclSyntax:
      return (.protocolDecl, protocolDecl.name.text)
    case let extensionDecl as ExtensionDeclSyntax:
      let typeName = extensionDecl.extendedType.trimmedDescription
      return (.extension, "extension \(typeName)")
    case let actorDecl as ActorDeclSyntax:
      return (.actorDecl, actorDecl.name.text)
    case let funcDecl as FunctionDeclSyntax:
      return (.function, funcDecl.name.text)
    case let initDecl as InitializerDeclSyntax:
      // Check for failable init
      let failable = initDecl.optionalMark != nil ? "?" : ""
      return (.method, "init\(failable)")
    case let deinitDecl as DeinitializerDeclSyntax:
      _ = deinitDecl
      return (.method, "deinit")
    case let subscriptDecl as SubscriptDeclSyntax:
      _ = subscriptDecl
      return (.method, "subscript")
    default:
      return (.unknown, nil)
    }
  }
  
  // MARK: - Large Declaration Splitting
  
  private func splitLargeDeclaration(
    _ decl: any DeclSyntaxProtocol,
    constructType: ASTChunk.ConstructType,
    constructName: String?,
    lineMap: LineMap,
    maxChunkLines: Int,
    chunks: inout [ASTChunk]
  ) {
    // Get member block if this is a type with members
    guard let memberBlock = getMemberBlock(from: decl) else {
      // No member block - just split by lines
      let startLine = lineMap.line(for: decl.position)
      let endLine = lineMap.line(for: decl.endPosition)
      chunks.append(contentsOf: splitByLines(
        startLine: startLine,
        endLine: endLine,
        lineMap: lineMap,
        maxChunkLines: maxChunkLines,
        constructType: constructType,
        constructName: constructName
      ))
      return
    }
    
    // Collect methods and their boundaries
    var memberBoundaries: [(start: Int, end: Int, name: String, type: ASTChunk.ConstructType)] = []
    
    for member in memberBlock.members {
      if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
        let start = lineMap.line(for: funcDecl.positionAfterSkippingLeadingTrivia)
        let end = lineMap.line(for: funcDecl.endPositionBeforeTrailingTrivia)
        memberBoundaries.append((start, end, funcDecl.name.text, .method))
      } else if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
        let start = lineMap.line(for: initDecl.positionAfterSkippingLeadingTrivia)
        let end = lineMap.line(for: initDecl.endPositionBeforeTrailingTrivia)
        let failable = initDecl.optionalMark != nil ? "?" : ""
        memberBoundaries.append((start, end, "init\(failable)", .method))
      } else if let subscriptDecl = member.decl.as(SubscriptDeclSyntax.self) {
        let start = lineMap.line(for: subscriptDecl.positionAfterSkippingLeadingTrivia)
        let end = lineMap.line(for: subscriptDecl.endPositionBeforeTrailingTrivia)
        memberBoundaries.append((start, end, "subscript", .method))
      } else if let deinitDecl = member.decl.as(DeinitializerDeclSyntax.self) {
        let start = lineMap.line(for: deinitDecl.positionAfterSkippingLeadingTrivia)
        let end = lineMap.line(for: deinitDecl.endPositionBeforeTrailingTrivia)
        memberBoundaries.append((start, end, "deinit", .method))
      }
    }
    
    memberBoundaries.sort { $0.start < $1.start }
    
    let declStart = lineMap.line(for: decl.positionAfterSkippingLeadingTrivia)
    let declEnd = lineMap.line(for: decl.endPositionBeforeTrailingTrivia)
    
    if memberBoundaries.isEmpty {
      // No methods to split on
      chunks.append(contentsOf: splitByLines(
        startLine: declStart,
        endLine: declEnd,
        lineMap: lineMap,
        maxChunkLines: maxChunkLines,
        constructType: constructType,
        constructName: constructName
      ))
      return
    }
    
    var currentStart = declStart
    
    for (memberStart, memberEnd, memberName, memberType) in memberBoundaries {
      // Header/properties before this method
      if memberStart > currentStart + 1 {
        let headerEnd = memberStart - 1
        let headerLineCount = headerEnd - currentStart + 1
        
        if headerLineCount >= 3 { // Only if substantial
          let text = lineMap.text(from: currentStart, to: headerEnd)
          chunks.append(ASTChunk(
            constructType: constructType,
            constructName: constructName,
            startLine: currentStart,
            endLine: headerEnd,
            text: text,
            language: Self.language
          ))
        }
      }
      
      // The method itself
      let methodLineCount = memberEnd - memberStart + 1
      let fullMemberName = combineName(parent: constructName, child: memberName)
      
      if methodLineCount <= maxChunkLines {
        let text = lineMap.text(from: memberStart, to: memberEnd)
        chunks.append(ASTChunk(
          constructType: memberType,
          constructName: fullMemberName,
          startLine: memberStart,
          endLine: memberEnd,
          text: text,
          language: Self.language
        ))
      } else {
        // Very large method - split by lines
        chunks.append(contentsOf: splitByLines(
          startLine: memberStart,
          endLine: memberEnd,
          lineMap: lineMap,
          maxChunkLines: maxChunkLines,
          constructType: memberType,
          constructName: fullMemberName
        ))
      }
      
      currentStart = memberEnd + 1
    }
    
    // Trailing content (closing brace, etc.)
    if currentStart < declEnd {
      let text = lineMap.text(from: currentStart, to: declEnd)
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      // Only add if more than just closing brace
      if trimmed.count > 1 {
        chunks.append(ASTChunk(
          constructType: constructType,
          constructName: constructName,
          startLine: currentStart,
          endLine: declEnd,
          text: text,
          language: Self.language
        ))
      }
    }
  }
  
  private func getMemberBlock(from decl: any DeclSyntaxProtocol) -> MemberBlockSyntax? {
    switch decl {
    case let classDecl as ClassDeclSyntax:
      return classDecl.memberBlock
    case let structDecl as StructDeclSyntax:
      return structDecl.memberBlock
    case let enumDecl as EnumDeclSyntax:
      return enumDecl.memberBlock
    case let extensionDecl as ExtensionDeclSyntax:
      return extensionDecl.memberBlock
    case let actorDecl as ActorDeclSyntax:
      return actorDecl.memberBlock
    case let protocolDecl as ProtocolDeclSyntax:
      return protocolDecl.memberBlock
    default:
      return nil
    }
  }
  
  // MARK: - Helpers
  
  private func combineName(parent: String?, child: String?) -> String? {
    switch (parent, child) {
    case let (p?, c?):
      return "\(p).\(c)"
    case let (p?, nil):
      return p
    case let (nil, c?):
      return c
    case (nil, nil):
      return nil
    }
  }
  
  private func splitByLines(
    startLine: Int,
    endLine: Int,
    lineMap: LineMap,
    maxChunkLines: Int,
    constructType: ASTChunk.ConstructType,
    constructName: String?
  ) -> [ASTChunk] {
    var chunks: [ASTChunk] = []
    var current = startLine
    
    while current <= endLine {
      let chunkEnd = min(current + maxChunkLines - 1, endLine)
      let text = lineMap.text(from: current, to: chunkEnd)
      
      chunks.append(ASTChunk(
        constructType: constructType,
        constructName: constructName,
        startLine: current,
        endLine: chunkEnd,
        text: text,
        language: Self.language
      ))
      
      current = chunkEnd + 1
    }
    
    return chunks
  }
  
  private func fallbackChunks(source: String, lineMap: LineMap, maxChunkLines: Int) -> [ASTChunk] {
    let totalLines = lineMap.lineCount
    return splitByLines(
      startLine: 1,
      endLine: totalLines,
      lineMap: lineMap,
      maxChunkLines: maxChunkLines,
      constructType: .file,
      constructName: nil
    )
  }
}

// MARK: - LineMap Helper

/// Helper to convert between byte offsets and line numbers
private struct LineMap {
  private let lines: [String]
  private let lineStartOffsets: [Int]
  
  var lineCount: Int { lines.count }
  
  init(source: String) {
    self.lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    
    var offsets: [Int] = [0]
    var currentOffset = 0
    for line in lines {
      currentOffset += line.utf8.count + 1 // +1 for newline
      offsets.append(currentOffset)
    }
    self.lineStartOffsets = offsets
  }
  
  /// Convert AbsolutePosition to 1-indexed line number
  func line(for position: AbsolutePosition) -> Int {
    let offset = position.utf8Offset
    
    // Binary search for the line
    var low = 0
    var high = lineStartOffsets.count - 1
    
    while low < high {
      let mid = (low + high + 1) / 2
      if lineStartOffsets[mid] <= offset {
        low = mid
      } else {
        high = mid - 1
      }
    }
    
    return low + 1 // Convert to 1-indexed
  }
  
  /// Get text for a line range (1-indexed, inclusive)
  func text(from startLine: Int, to endLine: Int) -> String {
    let start = max(0, startLine - 1)
    let end = min(lines.count, endLine)
    guard start < end else { return "" }
    return lines[start..<end].joined(separator: "\n")
  }
}
