//
//  RAGStoreApp.swift
//  Peel
//
//  App-level integration for RAGCore. Provides:
//  - Backward-compatible typealiases (LocalRAGStore → RAGStore, etc.)
//  - Singleton RAGStore instance
//  - Artifact bundle methods (Firestore sync)
//  - Repo path remapping (uses RepoRegistry)
//

import CryptoKit
import CSQLite
import Foundation
import RAGCore

// MARK: - Backward-Compatible Typealiases

typealias LocalRAGStore = RAGStore
typealias LocalRAGIndexReport = RAGIndexReport
typealias LocalRAGIndexProgress = RAGIndexProgress
typealias LocalRAGProgressCallback = @Sendable (RAGIndexProgress) -> Void
typealias LocalRAGSearchResult = RAGSearchResult
typealias LocalRAGLesson = RAGLesson
typealias LocalRAGQueryHint = RAGQueryHint
typealias LocalRAGChunk = RAGChunk
typealias LocalRAGFileSummary = RAGFileSummary

extension RAGStore {
  typealias LocalRAGError = RAGError
}

// MARK: - Factory (no-arg, uses app defaults)

/// Creates a RAGStore with the app's default embedding provider and memory monitor.
func makeDefaultRAGStore(
  dbURL: URL? = nil,
  chunkAnalyzer: ChunkAnalyzer? = nil
) -> RAGStore {
  #if os(macOS)
  let analysisEnabled = UserDefaults.standard.bool(forKey: "rag.analyzer.enabled")
  let tierRaw = UserDefaults.standard.string(forKey: "rag.analyzer.tier")
  let tier = tierRaw.flatMap { MLXAnalyzerModelTier(rawValue: $0) } ?? .auto
  let analyzer: ChunkAnalyzer? = chunkAnalyzer ?? (analysisEnabled ? MLXCodeAnalyzerFactory.makeAnalyzer(tier: tier) : nil)
  #else
  let analyzer = chunkAnalyzer
  #endif
  
  return RAGStore(
    dbURL: dbURL,
    embeddingProvider: LocalRAGEmbeddingProviderFactory.makeDefault(),
    chunkAnalyzer: analyzer,
    memoryMonitor: MLXMemoryPressureMonitor()
  )
}

// MARK: - Singleton

extension RAGStore {
  static let shared = RAGStore(
    embeddingProvider: LocalRAGEmbeddingProviderFactory.makeDefault(),
    memoryMonitor: MLXMemoryPressureMonitor()
  )
}

// MARK: - Artifact Bundle (Firestore Sync)

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
    status: RAGStore.Status,
    stats: RAGStore.Stats?,
    repos: [RAGStore.RepoInfo]
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
    status: RAGStore.Status,
    stats: RAGStore.Stats?,
    repos: [RAGStore.RepoInfo]
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

    let extractedRoot = resolveExtractedRoot(tempDir: tempDir, manifest: manifest)

    let manifestPaths = Set(manifest.files.map { $0.relativePath })
    let existingArtifacts = artifactFiles().map { $0.path.replacingOccurrences(of: baseURL.path + "/", with: "") }
    for relativePath in existingArtifacts where !manifestPaths.contains(relativePath) {
      let target = baseURL.appendingPathComponent(relativePath)
      if FileManager.default.fileExists(atPath: target.path) {
        try? FileManager.default.removeItem(at: target)
      }
    }

    for file in manifest.files {
      let source = extractedRoot.appendingPathComponent(file.relativePath)
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

  private static func resolveExtractedRoot(tempDir: URL, manifest: RAGArtifactManifest) -> URL {
    if let firstFile = manifest.files.first {
      let directPath = tempDir.appendingPathComponent(firstFile.relativePath)
      if FileManager.default.fileExists(atPath: directPath.path) {
        return tempDir
      }
    }
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) {
      let subdirs = entries.filter { entry in
        var isDir: ObjCBool = false
        let path = tempDir.appendingPathComponent(entry).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
      }
      if subdirs.count == 1 {
        let candidate = tempDir.appendingPathComponent(subdirs[0])
        if let firstFile = manifest.files.first {
          let nestedPath = candidate.appendingPathComponent(firstFile.relativePath)
          if FileManager.default.fileExists(atPath: nestedPath.path) {
            return candidate
          }
        }
      }
    }
    return tempDir
  }

  static func repoSnapshot(for repo: RAGStore.RepoInfo) async -> RAGArtifactRepoSnapshot {
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
      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256Hex(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func zipItem(at sourceURL: URL, to destinationURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", sourceURL.path, destinationURL.path]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw RAGStore.RAGError.sqlite("Failed to create RAG artifact bundle")
    }
  }

  private static func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", sourceURL.path, destinationURL.path]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw RAGStore.RAGError.sqlite("Failed to extract RAG artifact bundle")
    }
  }
}

// MARK: - Artifact Bundle Methods on RAGStore

extension RAGStore {
  /// Create an artifact bundle for a specific repository (Firestore sync).
  func createArtifactBundle(for repoPath: String) async throws -> LocalRAGArtifactBundle? {
    let repos = try listRepos()
    guard let repo = repos.first(where: { $0.rootPath == repoPath }) else {
      return nil
    }
    let currentStatus = status()
    let currentStats = try? stats()
    return try await LocalRAGArtifacts.createBundle(
      status: currentStatus, stats: currentStats, repos: [repo]
    )
  }

  /// Import an artifact bundle for a specific repository (Firestore sync).
  func importArtifactBundle(_ bundle: LocalRAGArtifactBundle, for repoPath: String) async throws {
    try LocalRAGArtifacts.applyBundle(bundleURL: bundle.bundleURL, manifest: bundle.manifest)
    _ = try initialize()
    await RepoRegistry.shared.registerRepo(at: repoPath)
    let remapped = try await remapRepoPaths()
    if remapped > 0 {
      print("[RAG] Remapped \(remapped) repo path(s) after artifact import")
    }
  }
}

// MARK: - Portable Repo Identification (Issue #278)
//
// To support cross-machine SQLite sync:
// 1. `repoIdentifier` column stores normalized git remote URL
// 2. `RepoRegistry.shared` maps remote URLs to local paths
// 3. `remapRepoPaths()` updates `root_path` when DB is synced to a new machine
// 4. All MCP tools resolve repoPath via RepoRegistry before querying
//
// This allows the same RAG database to work on different machines
// where repos are cloned at different paths.

// MARK: - Repo Path Remapping (uses RepoRegistry)

extension RAGStore {

  /// Resolve a repo path to its local equivalent using RepoRegistry.
  /// - Parameter repoPath: Path or remote URL to resolve
  /// - Returns: Local path if resolvable, original path otherwise
  func resolveRepoPath(_ repoPath: String) async -> String {
    // First, try the path as-is if it exists locally
    if FileManager.default.fileExists(atPath: repoPath) {
      return repoPath
    }
    
    // Try RepoRegistry in case repoPath is a remote URL or identifier
    if let resolved = await RepoRegistry.shared.getLocalPath(for: repoPath),
       FileManager.default.fileExists(atPath: resolved) {
      return resolved
    }
    
    // Fall back to original path (may not exist, but preserves caller's intent)
    return repoPath
  }

  @discardableResult
  func remapRepoPaths() async throws -> Int {
    let remapLog: (String) -> Void = { message in
      print("[RAG remap] \(message)")
    }

    remapLog("Starting remapRepoPaths")

    let reposToRemap = try listReposNeedingRemap()
    var remaps: [(id: String, newPath: String)] = []

    for (repoId, currentPath, identifier) in reposToRemap {
      remapLog("Checking repo: id=\(repoId), path=\(currentPath), identifier=\(identifier)")

      if FileManager.default.fileExists(atPath: currentPath) {
        remapLog("  Path exists locally, skipping: \(currentPath)")
        continue
      }

      if let localPath = await RepoRegistry.shared.getLocalPath(for: identifier),
         FileManager.default.fileExists(atPath: localPath) {
        remapLog("  RepoRegistry resolved: \(identifier) -> \(localPath)")
        remaps.append((id: repoId, newPath: localPath))
        continue
      }

      if let localPath = await discoverRepoPath(for: identifier) {
        await RepoRegistry.shared.registerRepo(at: localPath)
        remapLog("  Discovered via scan: \(identifier) -> \(localPath)")
        remaps.append((id: repoId, newPath: localPath))
      }
    }

    remapLog("Remapping \(remaps.count) repo(s)")
    try applyRemaps(remaps)
    return remaps.count
  }

  /// List repos that have a repo_identifier (needed for remapping).
  private func listReposNeedingRemap() throws -> [(id: String, path: String, identifier: String)] {
    // This accesses the raw SQLite - we need the internal db handle.
    // Use the public listRepos() and filter.
    let repos = try listRepos()
    return repos.compactMap { repo in
      guard let identifier = repo.repoIdentifier else { return nil }
      return (id: repo.id, path: repo.rootPath, identifier: identifier)
    }
  }

  /// Apply remap updates within a transaction.
  private func applyRemaps(_ remaps: [(id: String, newPath: String)]) throws {
    // We need to call internal SQLite methods. Since remapRepoPaths
    // uses the actor's db, we need internal access. For now, re-use
    // the public API by deleting and re-adding repos (or use raw SQL via extension).
    // This is a simplified version that updates via exec statements.
    for remap in remaps {
      try remapRepoPath(oldId: remap.id, newPath: remap.newPath)
    }
  }

  private func discoverRepoPath(for repoIdentifier: String) async -> String? {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    let candidateDirs = [
      "\(homeDir)/code", "\(homeDir)/Code",
      "\(homeDir)/projects", "\(homeDir)/Projects",
      "\(homeDir)/src", "\(homeDir)/repos",
      "\(homeDir)/Developer", "\(homeDir)/dev",
      "\(homeDir)/workspace",
      "\(homeDir)/github", "\(homeDir)/GitHub",
    ]

    let normalizedIdentifier = await RepoRegistry.shared.normalizeRemoteURL(repoIdentifier)
    let fm = FileManager.default

    for dir in candidateDirs {
      guard fm.fileExists(atPath: dir) else { continue }
      guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
      for entry in entries {
        let candidatePath = "\(dir)/\(entry)"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: candidatePath, isDirectory: &isDir), isDir.boolValue else { continue }
        guard fm.fileExists(atPath: "\(candidatePath)/.git") else { continue }
        guard let remoteURL = RAGStore.discoverNormalizedRemoteURL(for: candidatePath) else { continue }
        // discoverNormalizedRemoteURL already normalizes
        if remoteURL == normalizedIdentifier {
          return candidatePath
        }
      }
    }
    return nil
  }
}
