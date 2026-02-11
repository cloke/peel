//
//  MCPServerService+RAGArtifactSync.swift
//  KitchenSync
//
//  Extracted from MCPServerService.swift for maintainability.
//

import Foundation
import OSLog

// MARK: - RAGArtifactSyncDelegate

extension MCPServerService: RAGArtifactSyncDelegate {
  public func createRagArtifactBundle() async throws -> LocalRAGArtifactBundle {
    logger.info("RAG sync: creating local artifact bundle")
    let status = await localRagStore.status()
    let stats = try? await localRagStore.stats()
    let repos = (try? await localRagStore.listRepos()) ?? []
    let bundle = try await LocalRAGArtifacts.createBundle(status: status, stats: stats, repos: repos)
    logger.info("RAG sync: bundle created \(bundle.manifest.version), \(bundle.bundleSizeBytes) bytes")
    return bundle
  }

  public func applyRagArtifactBundle(
    at url: URL,
    manifest: RAGArtifactManifest,
    from peerId: String,
    direction: RAGArtifactSyncDirection
  ) async throws {
    ragArtifactSyncError = nil
    logger.info("RAG sync: applying bundle \(manifest.version) from \(peerId), files: \(manifest.files.map(\.relativePath)), repos: \(manifest.repos.map(\.name))")
    await localRagStore.closeDatabase()
    try LocalRAGArtifacts.applyBundle(bundleURL: url, manifest: manifest)
    
    // Re-open and remap paths for this machine
    let status = try await localRagStore.initialize()
    logger.info("RAG sync: re-initialized DB, schema v\(status.schemaVersion), provider: \(status.providerName)")
    
    let repos = (try? await localRagStore.listRepos()) ?? []
    logger.info("RAG sync: DB now has \(repos.count) repos: \(repos.map { "\($0.name) @ \($0.rootPath) (\($0.fileCount) files)" })")
    
    let remapped = try await localRagStore.remapRepoPaths()
    if remapped > 0 {
      logger.info("RAG sync: remapped \(remapped) repo path(s) for local machine")
      let reposAfter = (try? await localRagStore.listRepos()) ?? []
      logger.info("RAG sync: after remap, repos: \(reposAfter.map { "\($0.name) @ \($0.rootPath) (\($0.fileCount) files)" })")
    }
    
    await refreshRagSummary()
    await updateRagArtifactStatus(from: manifest, lastSyncedAt: Date(), direction: direction)
    logger.info("RAG sync: applied bundle \(manifest.version), ragRepos count: \(self.ragRepos.count)")
  }
}
