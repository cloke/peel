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

  func createRepoSyncManifest(repoIdentifier: String) async throws -> RAGRepoSyncManifest? {
    logger.info("RAG repo sync: building manifest for '\(repoIdentifier)'")
    let manifest = try await localRagStore.repoSyncManifest(identifier: repoIdentifier)
    if manifest == nil {
      logger.warning("RAG repo sync: no manifest for '\(repoIdentifier)' (repo not found)")
    }
    return manifest
  }

  func applyRepoSyncBundle(_ bundle: RAGRepoExportBundle, localRepoPath: String?, forceImportEmbeddings: Bool) async throws -> RAGRepoImporter.ImportResult {
    // Resolve local repo path: use provided path, or look up via RepoRegistry, or discover
    let resolvedPath: String?
    if let localRepoPath {
      resolvedPath = localRepoPath
    } else if !bundle.manifest.repoIdentifier.isEmpty {
      let identifier = bundle.manifest.repoIdentifier
      // Try RepoRegistry first
      if let registryPath = await RepoRegistry.shared.getLocalPath(for: identifier),
         FileManager.default.fileExists(atPath: registryPath) {
        resolvedPath = registryPath
        logger.info("RAG repo sync: resolved '\(identifier)' to '\(registryPath)' via RepoRegistry")
      } else {
        // Fall back to filesystem discovery
        resolvedPath = await localRagStore.discoverRepoPathPublic(for: identifier)
        if let discovered = resolvedPath {
          logger.info("RAG repo sync: discovered '\(identifier)' at '\(discovered)' via filesystem scan")
          await RepoRegistry.shared.registerRepo(at: discovered)
        } else {
          logger.warning("RAG repo sync: could not resolve local path for '\(identifier)' — using remote path")
        }
      }
    } else {
      resolvedPath = nil
    }

    logger.info("RAG repo sync: importing '\(bundle.manifest.repoIdentifier)', \(bundle.files.count) files, localPath: \(resolvedPath ?? "nil"), forceEmbeddings: \(forceImportEmbeddings)")
    let result = try await localRagStore.importRepoBundle(bundle, localRepoPath: resolvedPath, forceImportEmbeddings: forceImportEmbeddings)

    // Record the synced embedding model for UX display
    if let remoteModel = result.remoteEmbeddingModel, result.embeddingsImported > 0 {
      let identifier = bundle.manifest.repoIdentifier
      self.ragSyncedEmbeddingModels[identifier] = remoteModel
    }

    if result.needsLocalReembedding {
      let remoteModel = result.remoteEmbeddingModel ?? "unknown"
      let skipped = result.embeddingsSkippedModelMismatch
      logger.warning("RAG repo sync: imported text/analysis only — embedding model mismatch (remote: \(remoteModel), local model differs). Skipped \(skipped) embeddings. Re-index to generate local embeddings.")
    }
    logger.info("RAG repo sync: imported — files \(result.filesImported), skipped \(result.filesSkipped), chunks \(result.chunksImported), embeddings \(result.embeddingsImported), analysisUpdated \(result.chunksAnalysisUpdated), embeddingsBackfilled \(result.embeddingsBackfilled)")
    await refreshRagSummary()
    return result
  }

  func localRepoFileHashes(repoIdentifier: String) async throws -> Set<String> {
    try await localRagStore.localFileHashes(identifier: repoIdentifier)
  }

  // MARK: - Overlay sync

  func createRepoOverlayBundle(repoIdentifier: String, excludeFileHashes: Set<String>) async throws -> RAGRepoOverlayBundle? {
    logger.info("RAG overlay export: '\(repoIdentifier)', excluding \(excludeFileHashes.count) hashes")
    let bundle = try await localRagStore.exportRepoOverlay(identifier: repoIdentifier, excludeFileHashes: excludeFileHashes)
    if let bundle {
      logger.info("RAG overlay export: \(bundle.files.count) files, \(bundle.totalEmbeddings) embeddings, \(bundle.totalAnalysis) analysis entries")
    } else {
      logger.warning("RAG overlay export: repo '\(repoIdentifier)' not found")
    }
    return bundle
  }

  func applyRepoOverlayBundle(_ bundle: RAGRepoOverlayBundle) async throws -> RAGRepoImporter.OverlayImportResult {
    logger.info("RAG overlay import: '\(bundle.manifest.repoIdentifier)', \(bundle.files.count) files, model: \(bundle.manifest.embeddingModel) (\(bundle.manifest.embeddingDimensions)d)")
    let result = try await localRagStore.importRepoOverlay(bundle)

    if result.isSuccess {
      // Record the overlay embedding model for UX display
      if result.embeddingsApplied > 0, let remoteModel = result.remoteEmbeddingModel {
        self.ragSyncedEmbeddingModels[bundle.manifest.repoIdentifier] = remoteModel
      }
      logger.info("RAG overlay import: matched \(result.filesMatched) files, \(result.embeddingsApplied) embeddings (\(result.embeddingsReplaced) replaced), \(result.analysisApplied) analysis updates, \(result.chunksUnmatched) chunks unmatched")
    } else {
      logger.error("RAG overlay import failed: \(result.error ?? "unknown")")
    }

    await refreshRagSummary()
    return result
  }
}
