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
struct MLXModelEntry: Codable, Hashable, Sendable, Identifiable {
  let name: String
  let huggingFaceId: String
  let tier: String
  let maxTokens: Int?
  let contextLength: Int?
  let dimensions: Int?
  let isCodeOptimized: Bool?

  // Display metadata for Labs UI
  let description: String?
  let estimatedSizeGB: Double?
  let minimumRAMGB: Double?

  var id: String { huggingFaceId }
}

/// Model categories for display grouping
enum MLXModelCategory: String, CaseIterable, Sendable, Identifiable {
  case editor = "Code Editing"
  case analyzer = "Code Analysis"
  case embedding = "Embeddings"
  case imageGeneration = "Image Generation"
  case tts = "Text-to-Speech"
  case stt = "Speech-to-Text"

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .editor: return "chevron.left.forwardslash.chevron.right"
    case .analyzer: return "magnifyingglass"
    case .embedding: return "cube"
    case .imageGeneration: return "photo"
    case .tts: return "speaker.wave.3"
    case .stt: return "mic"
    }
  }

  /// Whether models in this category can be used for text generation chat
  var supportsChat: Bool {
    switch self {
    case .editor, .analyzer: return true
    case .embedding, .imageGeneration, .tts, .stt: return false
    }
  }
}

/// Shape of the Firestore document at config/mlx_models
struct MLXModelsDocument: Codable, Sendable {
  let editor: [MLXModelEntry]?
  let analyzer: [MLXModelEntry]?
  let embedding: [MLXModelEntry]?
  let imageGeneration: [MLXModelEntry]?
  let tts: [MLXModelEntry]?
  let stt: [MLXModelEntry]?
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

  // MARK: - Image Generation Models

  var imageGenerationModels: [MLXModelEntry] {
    let remote = state.withLock { $0.remoteDocument?.imageGeneration }
    guard let remote, !remote.isEmpty else {
      return Self.builtinImageGenerationModels
    }
    return remote
  }

  // MARK: - TTS Models

  var ttsModels: [MLXModelEntry] {
    let remote = state.withLock { $0.remoteDocument?.tts }
    guard let remote, !remote.isEmpty else {
      return Self.builtinTTSModels
    }
    return remote
  }

  // MARK: - STT Models

  var sttModels: [MLXModelEntry] {
    let remote = state.withLock { $0.remoteDocument?.stt }
    guard let remote, !remote.isEmpty else {
      return Self.builtinSTTModels
    }
    return remote
  }

  // MARK: - All Models by Category

  /// All models grouped by category for Labs UI
  var allModelsByCategory: [(category: MLXModelCategory, models: [MLXModelEntry])] {
    let editorEntries = editorModels.map { m in
      MLXModelEntry(
        name: m.name, huggingFaceId: m.huggingFaceId, tier: m.tier.rawValue,
        maxTokens: m.maxTokens, contextLength: m.contextLength,
        dimensions: nil, isCodeOptimized: nil,
        description: "Code editing model (\(m.tier.rawValue) tier)",
        estimatedSizeGB: nil, minimumRAMGB: nil
      )
    }
    let analyzerEntries = analyzerModels.map { m in
      MLXModelEntry(
        name: m.name, huggingFaceId: m.huggingFaceId, tier: m.tier.rawValue,
        maxTokens: m.maxTokens, contextLength: m.contextLength,
        dimensions: nil, isCodeOptimized: nil,
        description: "Code analysis model (\(m.tier.rawValue) tier)",
        estimatedSizeGB: nil, minimumRAMGB: nil
      )
    }
    let embeddingEntries = embeddingModels.map { m in
      MLXModelEntry(
        name: m.name, huggingFaceId: m.huggingFaceId, tier: m.tier.rawValue,
        maxTokens: nil, contextLength: nil,
        dimensions: m.dimensions, isCodeOptimized: m.isCodeOptimized,
        description: "Embedding model (\(m.tier.rawValue) tier, \(m.dimensions)d)",
        estimatedSizeGB: nil, minimumRAMGB: nil
      )
    }
    return [
      (.editor, editorEntries),
      (.analyzer, analyzerEntries),
      (.embedding, embeddingEntries),
      (.imageGeneration, imageGenerationModels),
      (.tts, ttsModels),
      (.stt, sttModels),
    ]
  }

  // MARK: - Builtin Labs Models

  /// Built-in image generation models
  static let builtinImageGenerationModels: [MLXModelEntry] = [
    MLXModelEntry(
      name: "FLUX.1 schnell",
      huggingFaceId: "mlx-community/FLUX.1-schnell-4bit-quantized",
      tier: "small",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "Fast 4-step image generation. 12B params, 4-bit quantized. Best speed/quality ratio.",
      estimatedSizeGB: 7.0, minimumRAMGB: 18
    ),
    MLXModelEntry(
      name: "Stable Diffusion 3.5 Large",
      huggingFaceId: "mlx-community/stable-diffusion-3.5-large",
      tier: "large",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "High-quality 50-step image generation. 8B MMDiT model for detailed outputs.",
      estimatedSizeGB: 16.5, minimumRAMGB: 36
    ),
    MLXModelEntry(
      name: "FLUX.1 dev",
      huggingFaceId: "mlx-community/FLUX.1-dev-4bit-quantized",
      tier: "medium",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "High-quality 20-step image generation. Slower but better than schnell.",
      estimatedSizeGB: 7.0, minimumRAMGB: 24
    ),
  ]

  /// Built-in TTS models
  static let builtinTTSModels: [MLXModelEntry] = [
    MLXModelEntry(
      name: "Soprano 80M",
      huggingFaceId: "mlx-community/Soprano-80M-bf16",
      tier: "small",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "Ultra-lightweight TTS. 80M params, fast generation, good quality for its size.",
      estimatedSizeGB: 0.3, minimumRAMGB: 8
    ),
    MLXModelEntry(
      name: "Qwen3-TTS 0.6B",
      huggingFaceId: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
      tier: "medium",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "Alibaba's TTS model with natural prosody and multi-language support. 8-bit quantized.",
      estimatedSizeGB: 0.4, minimumRAMGB: 8
    ),
    MLXModelEntry(
      name: "Orpheus 3B",
      huggingFaceId: "mlx-community/orpheus-3b-0.1-ft-bf16",
      tier: "large",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "High-quality multi-voice TTS. 3B params. Voices: tara, leah, jess, leo, dan, mia, zac, zoe.",
      estimatedSizeGB: 6.0, minimumRAMGB: 16
    ),
    MLXModelEntry(
      name: "VyvoTTS EN Beta",
      huggingFaceId: "mlx-community/VyvoTTS-EN-Beta-4bit",
      tier: "medium",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "English TTS model. 4-bit quantized for efficient inference.",
      estimatedSizeGB: 0.5, minimumRAMGB: 8
    ),
    MLXModelEntry(
      name: "Pocket TTS",
      huggingFaceId: "mlx-community/pocket-tts",
      tier: "small",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "Compact TTS model optimized for fast on-device generation.",
      estimatedSizeGB: 0.2, minimumRAMGB: 8
    ),
  ]

  /// Built-in STT models
  static let builtinSTTModels: [MLXModelEntry] = [
    MLXModelEntry(
      name: "Qwen3-ASR 0.6B",
      huggingFaceId: "mlx-community/Qwen3-ASR-0.6B-4bit",
      tier: "small",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "Alibaba's ASR model. 0.6B params, 4-bit quantized. Multi-language support with timestamps.",
      estimatedSizeGB: 0.4, minimumRAMGB: 8
    ),
    MLXModelEntry(
      name: "Qwen3-ASR 1.7B",
      huggingFaceId: "mlx-community/Qwen3-ASR-1.7B-bf16",
      tier: "medium",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "Larger Qwen3 ASR model. Higher accuracy with timestamps and multi-language support.",
      estimatedSizeGB: 3.4, minimumRAMGB: 12
    ),
    MLXModelEntry(
      name: "Parakeet TDT 0.6B v3",
      huggingFaceId: "mlx-community/parakeet-tdt-0.6b-v3",
      tier: "small",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "NVIDIA's fast ASR model. 0.6B params, English-optimized, high accuracy.",
      estimatedSizeGB: 1.2, minimumRAMGB: 8
    ),
    MLXModelEntry(
      name: "GLM-ASR Nano",
      huggingFaceId: "mlx-community/GLM-ASR-Nano-2512-4bit",
      tier: "small",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "Compact ASR model. Nano size with 4-bit quantization for fast transcription.",
      estimatedSizeGB: 0.3, minimumRAMGB: 8
    ),
    MLXModelEntry(
      name: "Voxtral Mini 4B",
      huggingFaceId: "mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16",
      tier: "large",
      maxTokens: nil, contextLength: nil,
      dimensions: nil, isCodeOptimized: nil,
      description: "Mistral's real-time ASR model. 4B params, high accuracy, fp16 precision.",
      estimatedSizeGB: 8.0, minimumRAMGB: 18
    ),
  ]

  // MARK: - Seed Firestore

  /// Write current local defaults to Firestore (call once to seed the document).
  func seedFirestore() async throws {
    let db = Firestore.firestore()
    let doc = MLXModelsDocument(
      editor: MLXEditorModelConfig.builtinModels.map { m in
        MLXModelEntry(
          name: m.name, huggingFaceId: m.huggingFaceId, tier: m.tier.rawValue,
          maxTokens: m.maxTokens, contextLength: m.contextLength,
          dimensions: nil, isCodeOptimized: nil,
          description: nil, estimatedSizeGB: nil, minimumRAMGB: nil
        )
      },
      analyzer: MLXAnalyzerModelConfig.builtinModels.map { m in
        MLXModelEntry(
          name: m.name, huggingFaceId: m.huggingFaceId, tier: m.tier.rawValue,
          maxTokens: m.maxTokens, contextLength: m.contextLength,
          dimensions: nil, isCodeOptimized: nil,
          description: nil, estimatedSizeGB: nil, minimumRAMGB: nil
        )
      },
      embedding: MLXEmbeddingModelConfig.builtinModels.map { m in
        MLXModelEntry(
          name: m.name, huggingFaceId: m.huggingFaceId, tier: m.tier.rawValue,
          maxTokens: nil, contextLength: nil,
          dimensions: m.dimensions, isCodeOptimized: m.isCodeOptimized,
          description: nil, estimatedSizeGB: nil, minimumRAMGB: nil
        )
      },
      imageGeneration: Self.builtinImageGenerationModels,
      tts: Self.builtinTTSModels,
      stt: Self.builtinSTTModels
    )
    try db.collection("config").document("mlx_models").setData(from: doc)
    logger.info("Seeded Firestore with current local model defaults")
  }
}
