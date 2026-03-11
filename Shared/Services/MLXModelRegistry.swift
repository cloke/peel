//
//  MLXModelRegistry.swift
//  Peel
//
//  Centralized registry for MLX model configurations.
//  Merges Firestore remote configs with local defaults so new models
//  can be added without redeploying the app.
//

import FirebaseFirestore
import Foundation
import os

// MARK: - Firestore Model Document

/// Shape of a model entry stored in Firestore
struct MLXModelEntry: Codable, Sendable {
  let name: String
  let huggingFaceId: String
  let tier: String
  let maxTokens: Int?
  let contextLength: Int?
  let dimensions: Int?
  let isCodeOptimized: Bool?
}

/// Shape of the Firestore document at config/mlx_models
struct MLXModelsDocument: Codable, Sendable {
  let editor: [MLXModelEntry]?
  let analyzer: [MLXModelEntry]?
  let embedding: [MLXModelEntry]?
}

// MARK: - Registry

/// Thread-safe registry for MLX model configs.
/// Uses lock-based storage so model reads work from any actor context.
final class MLXModelRegistry: Sendable {
  static let shared = MLXModelRegistry()

  private let logger = Logger(subsystem: "com.peel.mlx", category: "ModelRegistry")

  /// Lock-protected state
  private struct State: Sendable {
    var remoteDocument: MLXModelsDocument?
    var hasFetched = false
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  private init() {}

  /// Whether we've fetched from Firestore at least once this launch
  var hasFetched: Bool {
    state.withLock { $0.hasFetched }
  }

  // MARK: - Fetch

  /// Fetch model configs from Firestore. Call once on app launch.
  /// Falls back silently to local defaults if Firestore is unavailable.
  @MainActor
  func fetchIfNeeded() async {
    guard !hasFetched else { return }
    guard FirebaseService.shared.isFirebaseAvailable else {
      logger.info("Firebase unavailable, using local model defaults")
      state.withLock { $0.hasFetched = true }
      return
    }

    do {
      let db = Firestore.firestore()
      let doc = try await db.collection("config").document("mlx_models").getDocument()
      if doc.exists {
        let remote = try doc.data(as: MLXModelsDocument.self)
        state.withLock { $0.remoteDocument = remote }
        logger.info("Loaded MLX model registry from Firestore")
      } else {
        logger.info("No mlx_models config in Firestore, seeding with local defaults")
        try? await seedFirestore()
      }
    } catch {
      logger.warning("Failed to fetch MLX model registry: \(error.localizedDescription)")
    }
    state.withLock { $0.hasFetched = true }
  }

  // MARK: - Editor Models

  var editorModels: [MLXEditorModelConfig] {
    let remote = state.withLock { $0.remoteDocument?.editor }
    guard let remote, !remote.isEmpty else {
      return MLXEditorModelConfig.builtinModels
    }
    return remote.compactMap { entry in
      guard let tier = MLXEditorModelTier(rawValue: entry.tier) else { return nil }
      return MLXEditorModelConfig(
        name: entry.name,
        huggingFaceId: entry.huggingFaceId,
        tier: tier,
        maxTokens: entry.maxTokens ?? 4096,
        contextLength: entry.contextLength ?? 32768
      )
    }
  }

  // MARK: - Analyzer Models

  var analyzerModels: [MLXAnalyzerModelConfig] {
    let remote = state.withLock { $0.remoteDocument?.analyzer }
    guard let remote, !remote.isEmpty else {
      return MLXAnalyzerModelConfig.builtinModels
    }
    return remote.compactMap { entry in
      guard let tier = MLXAnalyzerModelTier(rawValue: entry.tier) else { return nil }
      return MLXAnalyzerModelConfig(
        name: entry.name,
        huggingFaceId: entry.huggingFaceId,
        tier: tier,
        maxTokens: entry.maxTokens ?? 256,
        contextLength: entry.contextLength ?? 4096
      )
    }
  }

  // MARK: - Embedding Models

  var embeddingModels: [MLXEmbeddingModelConfig] {
    let remote = state.withLock { $0.remoteDocument?.embedding }
    guard let remote, !remote.isEmpty else {
      return MLXEmbeddingModelConfig.builtinModels
    }
    return remote.compactMap { entry in
      guard let tier = MLXEmbeddingModelTier(rawValue: entry.tier) else { return nil }
      return MLXEmbeddingModelConfig(
        name: entry.name,
        huggingFaceId: entry.huggingFaceId,
        dimensions: entry.dimensions ?? 768,
        tier: tier,
        isCodeOptimized: entry.isCodeOptimized ?? false
      )
    }
  }

  // MARK: - Seed Firestore

  /// Write current local defaults to Firestore (call once to seed the document).
  func seedFirestore() async throws {
    let db = Firestore.firestore()
    let doc = MLXModelsDocument(
      editor: MLXEditorModelConfig.builtinModels.map { m in
        MLXModelEntry(
          name: m.name, huggingFaceId: m.huggingFaceId, tier: m.tier.rawValue,
          maxTokens: m.maxTokens, contextLength: m.contextLength,
          dimensions: nil, isCodeOptimized: nil
        )
      },
      analyzer: MLXAnalyzerModelConfig.builtinModels.map { m in
        MLXModelEntry(
          name: m.name, huggingFaceId: m.huggingFaceId, tier: m.tier.rawValue,
          maxTokens: m.maxTokens, contextLength: m.contextLength,
          dimensions: nil, isCodeOptimized: nil
        )
      },
      embedding: MLXEmbeddingModelConfig.builtinModels.map { m in
        MLXModelEntry(
          name: m.name, huggingFaceId: m.huggingFaceId, tier: m.tier.rawValue,
          maxTokens: nil, contextLength: nil,
          dimensions: m.dimensions, isCodeOptimized: m.isCodeOptimized
        )
      }
    )
    try db.collection("config").document("mlx_models").setData(from: doc)
    logger.info("Seeded Firestore with current local model defaults")
  }
}
