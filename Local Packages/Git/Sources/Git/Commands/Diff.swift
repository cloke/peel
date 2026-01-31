//
//  Diff.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// - Group 1: The header old file line start.
/// - Group 2: The header old file line span. If not present it defaults to 1.
/// - Group 3: The header new file line start.
/// - Group 4: The header new file line span. If not present it defaults to 1.

// Huge help from https://github.com/guillermomuntaner/GitDiff/

import Foundation
import OSLog

private let diffLogger = Logger(subsystem: "Peel", category: "Git.Diff")

#if os(macOS)
/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-add
extension Commands {
  /// Processes a diff based on direct file paths
  static func diff(repository: Model.Repository, path: String) async throws -> Diff {
    let commandStart = Date()
    let lines = try await Self.simple(arguments: ["diff", path], in: repository)
    let commandDurationMs = Int(Date().timeIntervalSince(commandStart) * 1000)
    let processStart = Date()
    let diff = Self.processDiff(lines: lines)
    let processDurationMs = Int(Date().timeIntervalSince(processStart) * 1000)
    let fileCount = diff.files.count
    let chunkCount = diff.files.reduce(0) { $0 + $1.chunks.count }
    let lineCount = diff.files.reduce(0) { total, file in
      total + file.chunks.reduce(0) { $0 + $1.lines.count }
    }
    #if DEBUG
    diffLogger.notice("Diff for \(path, privacy: .public) in \(commandDurationMs)ms (process: \(processDurationMs)ms, files: \(fileCount), chunks: \(chunkCount), lines: \(lineCount))")
    #endif
    return diff
  }
  
  /// Processes a diff based on specific commits
  static func diff(commit: String, on repository: Model.Repository) async throws -> Diff {
    let commandStart = Date()
    let lines = try await Self.simple(arguments: ["diff", "\(commit)~", commit], in: repository)
    let commandDurationMs = Int(Date().timeIntervalSince(commandStart) * 1000)
    let processStart = Date()
    let diff = Self.processDiff(lines: lines)
    let processDurationMs = Int(Date().timeIntervalSince(processStart) * 1000)
    let fileCount = diff.files.count
    let chunkCount = diff.files.reduce(0) { $0 + $1.chunks.count }
    let lineCount = diff.files.reduce(0) { total, file in
      total + file.chunks.reduce(0) { $0 + $1.lines.count }
    }
    #if DEBUG
    diffLogger.notice("Diff for \(commit, privacy: .public) in \(commandDurationMs)ms (process: \(processDurationMs)ms, files: \(fileCount), chunks: \(chunkCount), lines: \(lineCount))")
    #endif
    return diff
  }
  
  public static func processDiff(lines: [String]) -> Diff {
    var diff = Diff()
    // Note: try! is acceptable here - this is a compile-time constant regex pattern
    // that has been validated and will always succeed. Using do/catch would add
    // unnecessary error handling for an impossible failure case.
    let regex = try! NSRegularExpression(
      pattern: "^@@ -(\\d+),?(\\d+)? \\+(\\d+),?(\\d+)? @@",
      options: [])
    var oldLineNumber = 0
    var newLineNumber = 0
    var numberingLines = false
    
    var currentFile: Diff.File? = nil
    var currentChunk: Diff.File.Chunk? = nil
    
    for line in lines {
      switch line {
        // Start of new file
      case let string where line.starts(with: "diff --git"):
        // Save all data if there was a file in process
        if var file = currentFile {
          if let chunk = currentChunk {
            file.chunks.append(chunk)
          }
          diff.files.append(file)
        }
        currentChunk = nil
        currentFile = Diff.File(label: string)
        // Parse a/... and b/... paths from the diff header
        // Format: "diff --git a/path/to/file b/path/to/file"
        let parts = string.components(separatedBy: " ")
        if parts.count >= 4 {
          currentFile?.oldPath = String(parts[2].dropFirst(2)) // Remove "a/"
          currentFile?.newPath = String(parts[3].dropFirst(2)) // Remove "b/"
        }
        oldLineNumber = 0
        newLineNumber = 0
        numberingLines = false
        continue
        
        // Process a chunk of the file
      case let string where line.starts(with: "@@"):
        let range = NSRange(location: 0, length: string.utf16.count)
        let match = regex.firstMatch(in: line, options: [], range: range)
        
        if let chunk = currentChunk {
          currentFile?.chunks.append(chunk)
        }
        
        currentChunk = Diff.File.Chunk()
        currentChunk?.chunk = match?.group(0, in: line) ?? ""
        
        oldLineNumber = Int(match?.group(1, in: line) ?? "0") ?? 0
        newLineNumber = Int(match?.group(3, in: line) ?? "0") ?? 0
        currentChunk?.parsedObjectName = line.replacingOccurrences(of: (match?.group(0, in: line) ?? ""), with: "")
        //        if line.count > 0 {
        //           This will be the class name that git adds
        //          currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
        //        }
        numberingLines = true
        
        // Ignore these lines. Do we need them?
      case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "---"): ()
      case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "+++"): ()
      case _ where line.starts(with: "\\ No newline at end of file"): ()
        
        // Build up actual line diffs
      case _ where line.starts(with: "-") && numberingLines:
        currentChunk?.lines.append(Diff.File.Chunk.Line(
          line: line,
          status: "-",
          oldLineNumber: oldLineNumber,
          newLineNumber: nil,
          lineNumber: oldLineNumber
        ))
        oldLineNumber += 1
        
      case _ where line.starts(with: "+") && numberingLines:
        currentChunk?.lines.append(Diff.File.Chunk.Line(
          line: line,
          status: "+",
          oldLineNumber: nil,
          newLineNumber: newLineNumber,
          lineNumber: newLineNumber
        ))
        newLineNumber += 1
        
      case _ where line.starts(with: " ") && numberingLines:
        currentChunk?.lines.append(Diff.File.Chunk.Line(
          line: line,
          status: " ",
          oldLineNumber: oldLineNumber,
          newLineNumber: newLineNumber,
          lineNumber: newLineNumber
        ))
        oldLineNumber += 1
        newLineNumber += 1
        
      default: ()
      }
    }
    // This handles the last file in the loop
    if var file = currentFile {
      if let chunk = currentChunk {
        file.chunks.append(chunk)
      }
      diff.files.append(file)
    }
    
    return diff
  }
}
#endif
