//
//  ScratchAreaService.swift
//  Peel
//
//  Provides per-repo scratch directories for artifacts (screenshots, diffs, temp outputs).
//  Issue #111
//

import Foundation
import CryptoKit

/// Service for managing per-repo scratch directories under Application Support/Peel/Scratch
enum ScratchAreaService {
  
  enum ScratchError: LocalizedError {
    case cannotCreateDirectory(String)
    case invalidRepoPath
    
    var errorDescription: String? {
      switch self {
      case .cannotCreateDirectory(let path):
        return "Could not create scratch directory at \(path)"
      case .invalidRepoPath:
        return "Invalid repository path"
      }
    }
  }
  
  /// Root scratch directory under Application Support/Peel/Scratch
  static var scratchRoot: URL {
    get throws {
      let fm = FileManager.default
      let appSupport = try fm.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      return appSupport
        .appendingPathComponent("Peel", isDirectory: true)
        .appendingPathComponent("Scratch", isDirectory: true)
    }
  }
  
  /// Generate a stable hash for a repo path (used as folder name)
  static func repoHash(for repoPath: String) -> String {
    let data = Data(repoPath.utf8)
    let hash = SHA256.hash(data: data)
    // Use first 12 chars of hex for reasonable uniqueness + readability
    return hash.prefix(6).map { String(format: "%02x", $0) }.joined()
  }
  
  /// Get or create the scratch directory for a specific repo
  /// Returns path like: ~/Library/Application Support/Peel/Scratch/<hash>-<reponame>/
  static func scratchDirectory(for repoPath: String) throws -> URL {
    guard !repoPath.isEmpty else {
      throw ScratchError.invalidRepoPath
    }
    
    let fm = FileManager.default
    let root = try scratchRoot
    
    // Create folder name from hash + repo basename for human readability
    let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
    let hash = repoHash(for: repoPath)
    let folderName = "\(hash)-\(repoName)"
    
    let scratchDir = root.appendingPathComponent(folderName, isDirectory: true)
    
    // Create directory if needed
    if !fm.fileExists(atPath: scratchDir.path) {
      do {
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)
      } catch {
        throw ScratchError.cannotCreateDirectory(scratchDir.path)
      }
    }
    
    return scratchDir
  }
  
  /// List all scratch directories with their sizes
  static func listScratchDirectories() throws -> [(repoHash: String, path: URL, sizeBytes: Int64)] {
    let fm = FileManager.default
    let root = try scratchRoot
    
    guard fm.fileExists(atPath: root.path) else {
      return []
    }
    
    let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
    
    return contents.compactMap { url in
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
        return nil
      }
      let hash = url.lastPathComponent.components(separatedBy: "-").first ?? url.lastPathComponent
      let size = directorySize(at: url)
      return (repoHash: hash, path: url, sizeBytes: size)
    }
  }
  
  /// Calculate total size of a directory
  private static func directorySize(at url: URL) -> Int64 {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
      return 0
    }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        total += Int64(size)
      }
    }
    return total
  }
  
  /// Delete scratch directory for a specific repo
  static func deleteScratchDirectory(for repoPath: String) throws {
    let scratchDir = try scratchDirectory(for: repoPath)
    let fm = FileManager.default
    if fm.fileExists(atPath: scratchDir.path) {
      try fm.removeItem(at: scratchDir)
    }
  }
  
  /// Delete all scratch directories (cleanup)
  static func deleteAllScratchDirectories() throws {
    let fm = FileManager.default
    let root = try scratchRoot
    if fm.fileExists(atPath: root.path) {
      try fm.removeItem(at: root)
    }
  }
  
  /// Get total size of all scratch directories
  static func totalScratchSize() throws -> Int64 {
    let directories = try listScratchDirectories()
    return directories.reduce(0) { $0 + $1.sizeBytes }
  }
}
