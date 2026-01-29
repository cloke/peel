//
//  RAGArtifactSyncing.swift
//  Peel
//
//  Created on 1/29/26.
//

import Foundation

@MainActor
public protocol RAGArtifactSyncDelegate: AnyObject {
  func createRagArtifactBundle() async throws -> LocalRAGArtifactBundle
  func applyRagArtifactBundle(at url: URL, manifest: RAGArtifactManifest, from peerId: String, direction: RAGArtifactSyncDirection) async throws
}
