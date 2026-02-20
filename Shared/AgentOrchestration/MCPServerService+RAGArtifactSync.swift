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
    
    // Step 1: Close database before overwriting files
    logger.info("RAG sync: step 1 — closing database")
    await localRagStore.closeDatabase()
    
    // Step 2: Extract and copy bundle files
    do {
      logger.info("RAG sync: step 2 — applying bundle from \(url.path)")
      try LocalRAGArtifacts.applyBundle(bundleURL: url, manifest: manifest)
      logger.info("RAG sync: step 2 — bundle applied successfully")
    } catch {
      logger.error("RAG sync: step 2 FAILED — applyBundle error: \(error.localizedDescription)")
      // Try to re-initialize even if apply failed, so the store isn't left closed
      _ = try? await localRagStore.initialize()
      throw error
    }
    
    // Step 3: Re-open database
    let status: LocalRAGStore.Status
    do {
      logger.info("RAG sync: step 3 — re-initializing database")
      status = try await localRagStore.initialize()
      logger.info("RAG sync: step 3 — re-initialized DB, schema v\(status.schemaVersion), provider: \(status.providerName)")
    } catch {
      logger.error("RAG sync: step 3 FAILED — initialize error: \(error.localizedDescription)")
      throw error
    }
    
    // Step 4: Check repo state
    let repos = (try? await localRagStore.listRepos()) ?? []
    logger.info("RAG sync: step 4 — DB has \(repos.count) repos: \(repos.map { "\($0.name) @ \($0.rootPath) (\($0.fileCount) files)" })")
    
    // Step 5: Remap paths for this machine (non-fatal — log but don't fail)
    do {
      let remapped = try await localRagStore.remapRepoPaths()
      if remapped > 0 {
        logger.info("RAG sync: step 5 — remapped \(remapped) repo path(s) for local machine")
        let reposAfter = (try? await localRagStore.listRepos()) ?? []
        logger.info("RAG sync: step 5 — after remap: \(reposAfter.map { "\($0.name) @ \($0.rootPath) (\($0.fileCount) files)" })")
      } else {
        logger.info("RAG sync: step 5 — no paths needed remapping")
      }
    } catch {
      logger.error("RAG sync: step 5 WARNING — remapRepoPaths failed (non-fatal): \(error.localizedDescription)")
      // Don't rethrow — the DB is still usable, just with paths from the sender
    }
    
    // Step 6: Refresh UI state
    await refreshRagSummary()
    await updateRagArtifactStatus(from: manifest, lastSyncedAt: Date(), direction: direction)
    logger.info("RAG sync: complete — applied bundle \(manifest.version), ragRepos count: \(self.ragRepos.count)")
  }

  // MARK: - Per-repo sync

  func createRepoSyncBundle(repoIdentifier: String, excludeFileHashes: Set<String>) async throws -> RAGRepoExportBundle? {
    logger.info("RAG repo sync: exporting '\(repoIdentifier)', excluding \(excludeFileHashes.count) hashes")
    let bundle = try await localRagStore.exportRepo(identifier: repoIdentifier, excludeFileHashes: excludeFileHashes)
    if let bundle {
      logger.info("RAG repo sync: exported \(bundle.files.count) files, \(bundle.files.flatMap(\.chunks).count) chunks")
    } else {
      logger.warning("RAG repo sync: repo '\(repoIdentifier)' not found")
    }
    return bundle
  }

  func applyRepoSyncBundle(_ bundle: RAGRepoExportBundle, localRepoPath: String?) async throws -> RAGRepoImporter.ImportResult {
    logger.info("RAG repo sync: importing '\(bundle.manifest.repoIdentifier)', \(bundle.files.count) files")
    let result = try await localRagStore.importRepoBundle(bundle, localRepoPath: localRepoPath)
    if result.needsLocalReembedding {
      logger.warning(
        "RAG repo sync: imported text/analysis only — embedding model mismatch "
        + "(remote: \(result.remoteEmbeddingModel ?? "unknown"), local model differs). "
        + "Skipped \(result.embeddingsSkippedModelMismatch) embeddings. Re-index to generate local embeddings."
      )
    }
    logger.info("RAG repo sync: imported — files \(result.filesImported), skipped \(result.filesSkipped), chunks \(result.chunksImported), embeddings \(result.embeddingsImported)")
    await refreshRagSummary()
    return result
  }

  func localRepoFileHashes(repoIdentifier: String) async throws -> Set<String> {
    try await localRagStore.localFileHashes(identifier: repoIdentifier)
  }
}
