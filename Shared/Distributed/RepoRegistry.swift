// RepoRegistry.swift
// Peel
//
// Created by Copilot on 2026-01-28.
// Maps git remote URLs to local paths for cross-machine repo identification.

import Foundation
import OSLog

/// Registry that maps git remote URLs to local repository paths.
/// This enables distributed task execution across machines where the same repo
/// may be cloned at different paths (e.g., /Users/alice/code/peel vs /Users/bob/kitchen-sink).
@MainActor
public final class RepoRegistry: Sendable {
  public static let shared = RepoRegistry()
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "RepoRegistry")
  
  /// Map of normalized remote URL -> local path
  private var urlToPath: [String: String] = [:]
  
  /// Map of local path -> normalized remote URL
  private var pathToURL: [String: String] = [:]
  
  private init() {}
  
  // MARK: - Registration
  
  /// Register a local repository path, automatically discovering its remote URL
  /// - Parameter path: The local path to the git repository
  /// - Returns: The normalized remote URL if discovered, nil otherwise
  @discardableResult
  public func registerRepo(at path: String) async -> String? {
    guard let remoteURL = await discoverRemoteURL(for: path) else {
      logger.warning("Could not get remote URL for repo at \(path)")
      return nil
    }
    
    let normalizedURL = normalizeRemoteURL(remoteURL)
    urlToPath[normalizedURL] = path
    pathToURL[path] = normalizedURL
    
    logger.info("Registered repo: \(normalizedURL) -> \(path)")
    return normalizedURL
  }
  
  /// Register a repo with explicit remote URL (useful when path doesn't have .git folder)
  public func registerRepo(remoteURL: String, localPath: String) {
    let normalizedURL = normalizeRemoteURL(remoteURL)
    urlToPath[normalizedURL] = localPath
    pathToURL[localPath] = normalizedURL
    
    logger.info("Registered repo (explicit): \(normalizedURL) -> \(localPath)")
  }
  
  // MARK: - Lookup
  
  /// Get local path for a remote URL
  /// - Parameter remoteURL: The git remote URL (any format)
  /// - Returns: The local path if registered, nil otherwise
  public func getLocalPath(for remoteURL: String) -> String? {
    let normalizedURL = normalizeRemoteURL(remoteURL)
    return urlToPath[normalizedURL]
  }
  
  /// Get cached remote URL for a local path (doesn't run git)
  /// - Parameter path: The local repository path
  /// - Returns: The normalized remote URL if known, nil otherwise
  public func getCachedRemoteURL(for path: String) -> String? {
    return pathToURL[path]
  }
  
  /// Get all registered repos
  public var registeredRepos: [(remoteURL: String, localPath: String)] {
    urlToPath.map { ($0.key, $0.value) }
  }

  /// Unregister a repo by its local path
  public func unregister(localPath: String) {
    if let url = pathToURL.removeValue(forKey: localPath) {
      urlToPath.removeValue(forKey: url)
      logger.info("Unregistered repo: \(url) -> \(localPath)")
    }
  }

  /// Unregister a repo by its normalized remote URL
  public func unregister(remoteURL: String) {
    let normalized = normalizeRemoteURL(remoteURL)
    if let path = urlToPath.removeValue(forKey: normalized) {
      pathToURL.removeValue(forKey: path)
      logger.info("Unregistered repo: \(normalized) -> \(path)")
    }
  }
  
  // MARK: - Git Operations
  
  /// Discover the remote URL from a git repository by running git command
  /// - Parameter path: Path to the git repository
  /// - Returns: The remote URL or nil if not found
  private func discoverRemoteURL(for path: String) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["remote", "get-url", "origin"]
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    
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
      guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
        return nil
      }
      
      return output
    } catch {
      logger.error("Failed to get remote URL for \(path): \(error.localizedDescription)")
      return nil
    }
  }
  
  // MARK: - URL Normalization
  
  /// Normalize a git remote URL to a canonical form for comparison.
  /// Handles SSH, HTTPS, and git:// URLs.
  /// - Parameter url: The remote URL in any format
  /// - Returns: Normalized URL string
  public func normalizeRemoteURL(_ url: String) -> String {
    var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Remove trailing .git
    if normalized.hasSuffix(".git") {
      normalized = String(normalized.dropLast(4))
    }
    
    // Convert SSH format (git@github.com:user/repo) to normalized form
    if normalized.hasPrefix("git@") {
      // git@github.com:user/repo -> github.com/user/repo
      normalized = normalized
        .replacingOccurrences(of: "git@", with: "")
        .replacingOccurrences(of: ":", with: "/")
    }
    
    // Remove protocol prefixes
    for prefix in ["https://", "http://", "git://", "ssh://"] {
      if normalized.hasPrefix(prefix) {
        normalized = String(normalized.dropFirst(prefix.count))
        break
      }
    }
    
    // Remove www. prefix
    if normalized.hasPrefix("www.") {
      normalized = String(normalized.dropFirst(4))
    }
    
    // Remove authentication info (user@)
    if let atIndex = normalized.firstIndex(of: "@"),
       let slashIndex = normalized.firstIndex(of: "/"),
       atIndex < slashIndex {
      normalized = String(normalized[normalized.index(after: atIndex)...])
    }
    
    // Lowercase for case-insensitive comparison
    return normalized.lowercased()
  }
  
  // MARK: - Bulk Registration

  /// Register multiple local paths, discovering remote URLs via git.
  /// Useful for populating the registry from Git ViewModel, ReviewLocally recents, etc.
  public func registerAllPaths(_ paths: [String]) async {
    for path in paths where !path.isEmpty {
      // Skip already-registered paths
      guard pathToURL[path] == nil else { continue }
      await registerRepo(at: path)
    }
  }

  /// Register multiple explicit remote-URL-to-path mappings.
  /// Useful for RAG repos which already know their remote URL (repoIdentifier).
  public func registerAllExplicit(_ mappings: [(remoteURL: String, localPath: String)]) {
    for mapping in mappings where !mapping.remoteURL.isEmpty && !mapping.localPath.isEmpty {
      let normalizedURL = normalizeRemoteURL(mapping.remoteURL)
      guard urlToPath[normalizedURL] == nil else { continue }
      registerRepo(remoteURL: mapping.remoteURL, localPath: mapping.localPath)
    }
  }

  // MARK: - Convenience
  
  /// Resolve a ChainRequest's working directory for this machine.
  /// If the request has a repoRemoteURL, uses that to find the local path.
  /// Otherwise falls back to the workingDirectory (which may fail on remote machines).
  /// - Parameter request: The chain request
  /// - Returns: The resolved local path, or the original workingDirectory if no match
  public func resolveWorkingDirectory(for request: ChainRequest) -> String {
    // If we have a remote URL, try to resolve it
    if let remoteURL = request.repoRemoteURL,
       let localPath = getLocalPath(for: remoteURL) {
      logger.info("Resolved \(remoteURL) -> \(localPath)")
      return localPath
    }
    
    // Check if the original path exists on this machine
    if FileManager.default.fileExists(atPath: request.workingDirectory) {
      return request.workingDirectory
    }
    
    // Last resort: return original (will likely fail)
    logger.warning("Could not resolve working directory for request \(request.id)")
    return request.workingDirectory
  }
}
