//
//  RAGArtifactSyncing.swift
//  Peel
//
//  Created on 1/29/26.
//

import Foundation

@MainActor
protocol RAGArtifactSyncDelegate: AnyObject {
  func createRagArtifactBundle() async throws -> LocalRAGArtifactBundle
  func applyRagArtifactBundle(at url: URL, manifest: RAGArtifactManifest, from peerId: String, direction: RAGArtifactSyncDirection) async throws

  // MARK: - Per-repo sync (issue #303/#305)

  /// Export a single repo's RAG data as a JSON bundle.
  func createRepoSyncBundle(repoIdentifier: String, excludeFileHashes: Set<String>) async throws -> RAGRepoExportBundle?
  /// Import a per-repo bundle, merging into local DB without touching other repos.
  /// - Parameters:
  ///   - bundle: The exported repo data
  ///   - localRepoPath: Local path where this repo lives (for path remapping). If nil, attempts to resolve via RepoRegistry.
  ///   - forceImportEmbeddings: When true, import embeddings even if models differ (useful when not indexing locally)
  func applyRepoSyncBundle(_ bundle: RAGRepoExportBundle, localRepoPath: String?, forceImportEmbeddings: Bool) async throws -> RAGRepoImporter.ImportResult
  /// Get local file hashes for delta comparison.
  func localRepoFileHashes(repoIdentifier: String) async throws -> Set<String>
}
