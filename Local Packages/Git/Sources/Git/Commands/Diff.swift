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

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-add

extension Commands {
  /// Processes a diff based on direct file paths
  static func diff(repository: Model.Repository, path: String, callback: ((Diff) -> ())? = nil) {
    try? Commands.run(.git, command: ["-C", repository.path, "diff", path]) {
      switch $0 {
      case .complete(_, let lines):
        callback?(self.processDiff(lines: lines))
      default: ()
      }
    }
  }
  
  /// Processes a diff based on specific commits
  static func diff(commit: String, on respository: Model.Repository, callback: ((Diff) -> ())? = nil) {
    try? Commands.run(.git, command: ["-C", respository.path, "diff", "\(commit)~", commit]) {
      switch $0 {
      case .complete(_, let lines):
        callback?(self.processDiff(lines: lines))
      default: ()
      }
    }
  }
  
  public static func processDiff(lines: [String]) -> Diff {
    var diff = Diff()
    let regex = try! NSRegularExpression(
      pattern: "^(?:(?:@@ -(\\d+),?(\\d+)? \\+(\\d+),?(\\d+)? @@)|([-+\\s])(.*))",
      options: [])
    var lineNumber = 0
    var lineOffset = 0
    var numberingLines = false
    
    var currentFile: Diff.File? = nil
    var currentChunk: Diff.File.Chunk? = nil
    
    for var line in lines {
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
        lineNumber = 1 // Probably not the right place
        lineOffset = 0
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
        
        lineNumber = Int(match?.group(3, in: line) ?? "0") ?? 0
        line = line.replacingOccurrences(of: (match?.group(0, in: line) ?? ""), with: "")
        if line.count > 0 {
          currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
        }
        lineOffset = 0
        numberingLines = true
        
      // Ignore these lines. Do we need them?
      case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "---"): ()
      case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "+++"): ()
        
      // Build up actual line diffs
      case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "-") && numberingLines:
        lineOffset -= 1
        currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
        lineNumber += 1
        
      case _ where (line.trimmingCharacters(in: .whitespaces).starts(with: "+") || line.starts(with: " ")) && numberingLines:
        lineNumber += lineOffset
        lineOffset = 0
        currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
        lineNumber += 1
        
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
