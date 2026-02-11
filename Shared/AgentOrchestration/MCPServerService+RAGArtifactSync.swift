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
    logger.info("RAG sync: applying bundle \(manifest.version) from \(peerId)")
    await localRagStore.closeDatabase()
    try LocalRAGArtifacts.applyBundle(bundleURL: url, manifest: manifest)
    await refreshRagSummary()
    await updateRagArtifactStatus(from: manifest, lastSyncedAt: Date(), direction: direction)
    logger.info("RAG sync: applied bundle \(manifest.version)")
  }
}
