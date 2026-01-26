//
//  MLXEmbeddingProvider.swift
//  Peel
//
//  Native Swift embedding provider using MLX (Apple's ML framework).
//  Runs entirely on Apple Silicon - no Python, no external processes.
//
//  Created on 1/25/26.
//

#if os(macOS)
import Foundation
import Hub
import MLX
import MLXEmbedders
import Tokenizers

// MARK: - Model Configuration

/// Embedding model tiers based on machine capability
enum MLXEmbeddingModelTier: String, CaseIterable, Sendable {
  /// Small models (~100MB) - good for machines with 8GB RAM
  /// Fast inference, lower quality for complex queries
  case small
  
  /// Medium models (~350MB) - good for machines with 16GB RAM
  /// Balanced performance and quality
  case medium
  
  /// Large models (~1GB+) - good for machines with 32GB+ RAM
  /// Best quality, especially for code understanding
  case large
  
  /// Auto-select based on available memory
  case auto
  
  var description: String {
    switch self {
    case .small: return "Small (8GB+ RAM)"
    case .medium: return "Medium (16GB+ RAM)"
    case .large: return "Large (32GB+ RAM)"
    case .auto: return "Auto-detect"
    }
  }
}

/// Configuration for an MLX embedding model
struct MLXEmbeddingModelConfig: Sendable {
  let name: String
  let huggingFaceId: String
  let dimensions: Int
  let tier: MLXEmbeddingModelTier
  let isCodeOptimized: Bool
  
  /// Available models in MLXEmbedders - these are known to work with the library
  static let availableModels: [MLXEmbeddingModelConfig] = [
    // Small tier - MiniLM (very fast, good quality)
    MLXEmbeddingModelConfig(
      name: "all-MiniLM-L6-v2",
      huggingFaceId: "sentence-transformers/all-MiniLM-L6-v2",
      dimensions: 384,
      tier: .small,
      isCodeOptimized: false
    ),
    
    // Medium tier - Nomic (good balance)
    MLXEmbeddingModelConfig(
      name: "nomic-embed-text-v1.5",
      huggingFaceId: "nomic-ai/nomic-embed-text-v1.5",
      dimensions: 768,
      tier: .medium,
      isCodeOptimized: false
    ),
    
    // Large tier - Qwen3 Embedding (best for code, quantized)
    MLXEmbeddingModelConfig(
      name: "Qwen3-Embedding-0.6B-4bit",
      huggingFaceId: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
      dimensions: 1024,
      tier: .large,
      isCodeOptimized: true
    )
  ]
  
  /// Select the best model for the current machine
  static func recommendedModel(forCodeSearch: Bool = true) -> MLXEmbeddingModelConfig {
    let availableMemoryGB = getAvailableMemoryGB()
    let tier: MLXEmbeddingModelTier
    
    // TEMPORARY: Force medium tier to avoid quantized model GPU crashes
    // The Qwen3-4bit-DWQ model causes MLX Metal command buffer errors
    // See: https://github.com/ml-explore/mlx-swift/issues
    // TODO: Re-enable large tier once MLX quantized model bug is fixed
    if availableMemoryGB >= 24 {
      tier = .medium  // Was .large - crashes with quantized models
    } else if availableMemoryGB >= 12 {
      tier = .medium
    } else {
      tier = .small
    }
    
    // Find best model for tier, prefer code-optimized if requested
    let candidates = availableModels.filter { $0.tier == tier }
    if forCodeSearch, let codeModel = candidates.first(where: { $0.isCodeOptimized }) {
      return codeModel
    }
    return candidates.first ?? availableModels[0]
  }
  
  private static func getAvailableMemoryGB() -> Double {
    var size = 0
    var sizeOfSize = MemoryLayout<Int>.size
    sysctlbyname("hw.memsize", &size, &sizeOfSize, nil, 0)
    return Double(size) / 1_073_741_824.0  // bytes to GB
  }
}

// MARK: - MLX Embedding Provider

/// Native Swift embedding provider using Apple's MLX framework.
/// Maximizes utilization of Apple Silicon (CPU, GPU, Neural Engine).
actor MLXEmbeddingProvider: LocalRAGEmbeddingProvider {
  private var container: MLXEmbedders.ModelContainer?
  private let config: MLXEmbeddingModelConfig
  private var isLoaded = false
  
  nonisolated let dimensions: Int
  nonisolated let modelName: String
  
  /// Create provider with specific model configuration
  init(config: MLXEmbeddingModelConfig) {
    self.config = config
    self.dimensions = config.dimensions
    self.modelName = config.name
  }
  
  /// Create provider with auto-detected best model for the machine
  init(forCodeSearch: Bool = true) {
    let config = MLXEmbeddingModelConfig.recommendedModel(forCodeSearch: forCodeSearch)
    print("[MLX] Selected model: \(config.name) (tier: \(config.tier), dims: \(config.dimensions), hf: \(config.huggingFaceId))")
    self.config = config
    self.dimensions = config.dimensions
    self.modelName = config.name
  }
  
  /// Load the model (lazy - called on first embed)
  private func ensureLoaded() async throws {
    guard !isLoaded else { return }
    
    if let limitMB = LocalRAGEmbeddingProviderFactory.mlxCacheLimitMB {
      let limitBytes = limitMB * 1_048_576
      MLX.Memory.cacheLimit = limitBytes
      let label = limitMB == 0 ? "disabled" : "\(limitMB)MB"
      print("[MLX] Cache limit set to \(label)")
    } else {
      let bytes = defaultCacheLimitBytes()
      MLX.Memory.cacheLimit = bytes
      let label = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
      print("[MLX] Cache limit defaulted to 75% RAM (\(label))")
    }

    print("[MLX] Loading model: \(config.name) (\(config.huggingFaceId))")
    let startTime = CFAbsoluteTimeGetCurrent()
    
    // Use MLXEmbedders to load from HuggingFace
    // The model is downloaded and cached automatically
    let modelConfig = MLXEmbedders.ModelConfiguration(id: config.huggingFaceId)
    let loadedContainer = try await MLXEmbedders.loadModelContainer(
      hub: HubApi(),
      configuration: modelConfig,
      progressHandler: { progress in
        if progress.fractionCompleted > 0 {
          print("[MLX] Download progress: \(Int(progress.fractionCompleted * 100))%")
        }
      }
    )
    
    self.container = loadedContainer
    self.isLoaded = true
    LocalRAGEmbeddingProviderFactory.recordDownloadedMLXModel(config.huggingFaceId)
    
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
    print("[MLX] Model loaded in \(String(format: "%.2f", elapsed))s")
  }

  private func defaultCacheLimitBytes() -> Int {
    var size = 0
    var sizeOfSize = MemoryLayout<Int>.size
    sysctlbyname("hw.memsize", &size, &sizeOfSize, nil, 0)
    let total = max(0, size)
    return Int(Double(total) * 0.75)
  }
  
  nonisolated func embed(texts: [String]) async throws -> [[Float]] {
    try await embedIsolated(texts: texts)
  }
  
  private func embedIsolated(texts: [String]) async throws -> [[Float]] {
    guard !texts.isEmpty else { return [] }
    
    try await ensureLoaded()
    
    guard let container else {
      throw MLXEmbeddingError.modelNotLoaded
    }
    
    // Use the model container for thread-safe embedding
    // Based on MLXEmbedders README usage pattern
    let results = await container.perform { (model: EmbeddingModel, tokenizer: any Tokenizer, pooling: Pooling) -> [[Float]] in
      // Encode all texts
      let encodedInputs = texts.map { text in
        let sanitized = TextSanitizer.sanitize(text)
        return tokenizer.encode(text: sanitized, addSpecialTokens: true)
      }
      
      // Pad to longest sequence
      let maxLength = encodedInputs.reduce(into: 16) { acc, elem in
        acc = max(acc, elem.count)
      }
      
      let padTokenId = tokenizer.eosTokenId ?? 0
      let padded = MLX.stacked(
        encodedInputs.map { elem in
          MLXArray(
            elem + Array(repeating: padTokenId, count: maxLength - elem.count)
          )
        }
      )
      
      // Create attention mask (1 for real tokens, 0 for padding)
      let attentionMask = (padded .!= padTokenId)
      let tokenTypes = MLXArray.zeros(like: padded)
      
      // Run model to get hidden states
      let modelOutput = model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: attentionMask)
      
      // Use mean pooling if the loaded pooling strategy is .none (missing config file case)
      // Many embedding models like Qwen3 don't include 1_Pooling/config.json
      let effectivePooling: Pooling
      if pooling.strategy == .none {
        effectivePooling = Pooling(strategy: .mean)
      } else {
        effectivePooling = pooling
      }
      
      // Apply pooling with mask for proper mean calculation
      let pooledResult = effectivePooling(modelOutput, mask: attentionMask, normalize: true, applyLayerNorm: true)
      
      // Evaluate and convert to Float arrays
      // pooledResult shape should be [batch, hidden_dim]
      pooledResult.eval()
      
      // Convert each batch item to a Float array
      let batchSize = pooledResult.dim(0)
      var embeddings: [[Float]] = []
      for i in 0..<batchSize {
        let embedding = pooledResult[i].asArray(Float.self)
        embeddings.append(embedding)
      }
      return embeddings
    }
    
    return results
  }
  
  /// Get info about the loaded model
  func modelInfo() -> [String: Any] {
    [
      "name": config.name,
      "huggingFaceId": config.huggingFaceId,
      "dimensions": config.dimensions,
      "tier": config.tier.rawValue,
      "isCodeOptimized": config.isCodeOptimized,
      "isLoaded": isLoaded
    ]
  }
}

// MARK: - Error Types

enum MLXEmbeddingError: LocalizedError {
  case modelNotLoaded
  case embeddingFailed(String)
  case modelNotSupported(String)
  
  var errorDescription: String? {
    switch self {
    case .modelNotLoaded:
      return "MLX model not loaded"
    case .embeddingFailed(let reason):
      return "Embedding failed: \(reason)"
    case .modelNotSupported(let model):
      return "Model not supported: \(model)"
    }
  }
}

// MARK: - Factory Extension

extension LocalRAGEmbeddingProviderFactory {
  /// Create an MLX-based provider (preferred on macOS with Apple Silicon)
  static func makeMLX(forCodeSearch: Bool = true) -> MLXEmbeddingProvider {
    MLXEmbeddingProvider(forCodeSearch: forCodeSearch)
  }
  
  /// Create an MLX provider with specific model tier
  static func makeMLX(tier: MLXEmbeddingModelTier, forCodeSearch: Bool = true) -> MLXEmbeddingProvider {
    let candidates = MLXEmbeddingModelConfig.availableModels.filter { 
      tier == .auto || $0.tier == tier 
    }
    
    let config: MLXEmbeddingModelConfig
    if forCodeSearch, let codeModel = candidates.first(where: { $0.isCodeOptimized }) {
      config = codeModel
    } else {
      config = candidates.first ?? MLXEmbeddingModelConfig.recommendedModel(forCodeSearch: forCodeSearch)
    }
    
    return MLXEmbeddingProvider(config: config)
  }
}

#endif
