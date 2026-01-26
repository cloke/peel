import Foundation
import ASTChunker

/// Simple CLI to test the AST chunker on real files
@main
struct CLI {
  static func main() {
    let args = CommandLine.arguments

    guard args.count >= 2 else {
      print("Usage: ast-chunker-cli <file.swift> [--verbose]")
      print("       ast-chunker-cli <directory> [--verbose]")
      return
    }

    let path = args[1]
    let verbose = args.contains("--verbose")
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false

    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
      print("Error: Path does not exist: \(path)")
      return
    }

    if isDirectory.boolValue {
      processDirectory(path, verbose: verbose)
    } else {
      processFile(path, verbose: verbose)
    }
  }

  static func processDirectory(_ directory: String, verbose: Bool) {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(atPath: directory) else {
      print("Error: Cannot enumerate directory")
      return
    }

    var totalChunks = 0
    var totalFiles = 0
    var stats: [ASTChunk.ConstructType: Int] = [:]

    while let relativePath = enumerator.nextObject() as? String {
      guard relativePath.hasSuffix(".swift") else { continue }
      let fullPath = (directory as NSString).appendingPathComponent(relativePath)

      guard let source = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }

      let chunker = SwiftChunker()
      let chunks = chunker.chunk(source: source)

      totalFiles += 1
      totalChunks += chunks.count

      for chunk in chunks {
        stats[chunk.constructType, default: 0] += 1
      }

      if verbose {
        print("\n\(relativePath): \(chunks.count) chunks")
        for chunk in chunks {
          let lineCount = chunk.endLine - chunk.startLine + 1
          print("  \(chunk.constructType): \(chunk.constructName ?? "unnamed") (lines \(chunk.startLine)-\(chunk.endLine), \(lineCount) lines)")
        }
      }
    }

    print("\n=== Summary ===")
    print("Files processed: \(totalFiles)")
    print("Total chunks: \(totalChunks)")
    print("\nBy type:")
    for (type, count) in stats.sorted(by: { $0.value > $1.value }) {
      print("  \(type): \(count)")
    }
  }

  static func processFile(_ path: String, verbose: Bool) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
      print("Error: Cannot read file: \(path)")
      return
    }

    let filename = (path as NSString).lastPathComponent
    let chunker = SwiftChunker()
    let chunks = chunker.chunk(source: source)

    print("File: \(filename)")
    print("Total chunks: \(chunks.count)")
    print("---")

    for chunk in chunks {
      let lineCount = chunk.endLine - chunk.startLine + 1
      print("\(chunk.constructType): \(chunk.constructName ?? "unnamed") (lines \(chunk.startLine)-\(chunk.endLine), \(lineCount) lines)")

      if verbose {
        let preview = chunk.text.split(separator: "\n").prefix(3).joined(separator: "\n")
        print("  Preview: \(preview.prefix(80))...")
      }
    }
  }
}
