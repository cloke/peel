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

  nonisolated func createRepoSyncBundle(repoIdentifier: String, excludeFileHashes: Set<String>) async throws -> RAGRepoExportBundle? {
    let log = Logger(subsystem: "com.peel.mcp", category: "RAGSync")
    log.notice("RAG repo sync: exporting '\(repoIdentifier)', excluding \(excludeFileHashes.count) hashes")
    let store = await localRagStore
    let start = ContinuousClock.now
    let bundle = try await store.exportRepo(identifier: repoIdentifier, excludeFileHashes: excludeFileHashes)
    let elapsed = ContinuousClock.now - start
    if let bundle {
      log.notice("RAG repo sync: exported \(bundle.files.count) files, \(bundle.files.flatMap(\.chunks).count) chunks in \(elapsed)")
    } else {
      log.warning("RAG repo sync: repo '\(repoIdentifier)' not found (took \(elapsed))")
    }
    return bundle
  }

  nonisolated func createRepoSyncManifest(repoIdentifier: String) async throws -> RAGRepoSyncManifest? {
    let store = await localRagStore
    let manifest = try await store.repoSyncManifest(identifier: repoIdentifier)
    return manifest
  }

  nonisolated func applyRepoSyncBundle(_ bundle: RAGRepoExportBundle, localRepoPath: String?, forceImportEmbeddings: Bool) async throws -> RAGRepoImporter.ImportResult {
    let log = Logger(subsystem: "com.peel.mcp", category: "RAGSync")
    let store = await localRagStore

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
        log.info("RAG repo sync: resolved '\(identifier)' to '\(registryPath)' via RepoRegistry")
      } else {
        // Fall back to filesystem discovery
        resolvedPath = await store.discoverRepoPathPublic(for: identifier)
        if let discovered = resolvedPath {
          log.info("RAG repo sync: discovered '\(identifier)' at '\(discovered)' via filesystem scan")
          await RepoRegistry.shared.registerRepo(at: discovered)
        } else {
          log.warning("RAG repo sync: could not resolve local path for '\(identifier)' — using remote path")
        }
      }
    } else {
      resolvedPath = nil
    }

    log.info("RAG repo sync: importing '\(bundle.manifest.repoIdentifier)', \(bundle.files.count) files, localPath: \(resolvedPath ?? "nil"), forceEmbeddings: \(forceImportEmbeddings)")
    let result = try await store.importRepoBundle(bundle, localRepoPath: resolvedPath, forceImportEmbeddings: forceImportEmbeddings)

    if result.needsLocalReembedding {
      let remoteModel = result.remoteEmbeddingModel ?? "unknown"
      let skipped = result.embeddingsSkippedModelMismatch
      log.warning("RAG repo sync: imported text/analysis only — embedding model mismatch (remote: \(remoteModel), local model differs). Skipped \(skipped) embeddings. Re-index to generate local embeddings.")
    }
    log.info("RAG repo sync: imported — files \(result.filesImported), skipped \(result.filesSkipped), chunks \(result.chunksImported), embeddings \(result.embeddingsImported), analysisUpdated \(result.chunksAnalysisUpdated), embeddingsBackfilled \(result.embeddingsBackfilled), pruned \(result.filesPruned)")

    // Update UI state on MainActor (quick writes only)
    await MainActor.run {
      if let remoteModel = result.remoteEmbeddingModel, result.embeddingsImported > 0 {
        self.ragSyncedEmbeddingModels[bundle.manifest.repoIdentifier] = remoteModel
      }
    }
    await refreshRagSummary()
    return result
  }

  nonisolated func localRepoFileHashes(repoIdentifier: String) async throws -> Set<String> {
    let store = await localRagStore
    return try await store.localFileHashes(identifier: repoIdentifier)
  }

  // MARK: - Overlay sync

  nonisolated func createRepoOverlayBundle(repoIdentifier: String, excludeFileHashes: Set<String>) async throws -> RAGRepoOverlayBundle? {
    let store = await localRagStore
    let bundle = try await store.exportRepoOverlay(identifier: repoIdentifier, excludeFileHashes: excludeFileHashes)
    return bundle
  }

  nonisolated func applyRepoOverlayBundle(_ bundle: RAGRepoOverlayBundle) async throws -> RAGRepoImporter.OverlayImportResult {
    let log = Logger(subsystem: "com.peel.mcp", category: "RAGSync")
    let store = await localRagStore
    log.info("RAG overlay import: '\(bundle.manifest.repoIdentifier)', \(bundle.files.count) files, model: \(bundle.manifest.embeddingModel) (\(bundle.manifest.embeddingDimensions)d)")
    let result = try await store.importRepoOverlay(bundle)

    if result.isSuccess {
      log.info("RAG overlay import: matched \(result.filesMatched) files, \(result.embeddingsApplied) embeddings (\(result.embeddingsReplaced) replaced), \(result.analysisApplied) analysis updates, \(result.chunksUnmatched) chunks unmatched")
    } else {
      log.error("RAG overlay import failed: \(result.error ?? "unknown")")
    }

    // Update UI state on MainActor (quick writes only)
    await MainActor.run {
      if result.isSuccess, result.embeddingsApplied > 0, let remoteModel = result.remoteEmbeddingModel {
        self.ragSyncedEmbeddingModels[bundle.manifest.repoIdentifier] = remoteModel
      }
    }
    await refreshRagSummary()
    return result
  }
}
