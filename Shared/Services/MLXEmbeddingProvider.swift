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
import RAGCore
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
  
  /// Built-in models — local defaults before Firestore fetch
  static let builtinModels: [MLXEmbeddingModelConfig] = [
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

  /// Available models — uses Firestore registry if available, falls back to builtins
  static var availableModels: [MLXEmbeddingModelConfig] {
    MLXModelRegistry.shared.embeddingModels
  }

  /// Select the best model for the current machine
  static func recommendedModel(forCodeSearch: Bool = true) -> MLXEmbeddingModelConfig {
    let availableMemoryGB = getAvailableMemoryGB()
    let tier: MLXEmbeddingModelTier
    
    // Re-enabled large tier (Qwen3-Embedding) for 24GB+ machines.
    // The Metal GPU crash (QuantizedMatmul::eval_gpu) was caused by a race
    // condition in MLX clearCache, fixed in mlx-swift 0.30.3 (#331).
    if availableMemoryGB >= 24 {
      tier = .large
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
actor MLXEmbeddingProvider: LocalRAGEmbeddingProvider, BatchAwareEmbeddingProvider {
  private var container: MLXEmbedders.ModelContainer?
  private let config: MLXEmbeddingModelConfig
  private var isLoaded = false
  /// Cached load error — prevents retrying a failed/corrupt model on every embed call.
  private var loadError: Error?
  
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

    // If a previous load already failed, fast-fail so we don't retry
    // a corrupt download on every embed call in a batch.
    if let previousError = loadError {
      throw previousError
    }
    
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

    // Pre-flight: verify model cache isn't corrupt before handing to MLX
    // (MLX C++ can SIGABRT on truncated safetensors, which isn't catchable)
    if let cacheIssue = Self.validateModelCache(huggingFaceId: config.huggingFaceId) {
      let err = MLXEmbeddingError.embeddingFailed("Model cache validation failed for \(config.name): \(cacheIssue). Delete ~/Documents/huggingface/models/\(config.huggingFaceId) and re-run.")
      loadError = err
      print("[MLX] \(err.localizedDescription)")
      throw err
    }

    print("[MLX] Loading model: \(config.name) (\(config.huggingFaceId))")
    let startTime = CFAbsoluteTimeGetCurrent()
    
    do {
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
    } catch {
      // Cache the error so subsequent calls fail fast instead of retrying
      loadError = error
      print("[MLX] Model load FAILED for \(config.name): \(error.localizedDescription)")
      throw error
    }
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
    // Wrap with withError to convert MLX C++ errors into Swift throws
    // instead of fatalError (see ErrorHandler.dispatch in mlx-swift)
    let results = try await container.perform { (model: EmbeddingModel, tokenizer: any Tokenizer, pooling: Pooling) -> [[Float]] in
      try withError {
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

  // MARK: - BatchAwareEmbeddingProvider

  nonisolated func didCompleteBatch() async {
    if LocalRAGEmbeddingProviderFactory.mlxClearCacheAfterBatch {
      MLX.Memory.clearCache()
    }
  }
}

// MARK: - Error Types

enum MLXEmbeddingError: LocalizedError {
  case modelNotLoaded
  case embeddingFailed(String)
  case modelNotSupported(String)
  case evaluationFailed(String)
  case modelCacheCorrupt(String)
  
  var errorDescription: String? {
    switch self {
    case .modelNotLoaded:
      return "MLX model not loaded"
    case .embeddingFailed(let reason):
      return "Embedding failed: \(reason)"
    case .modelNotSupported(let model):
      return "Model not supported: \(model)"
    case .evaluationFailed(let reason):
      return "MLX evaluation failed: \(reason)"
    case .modelCacheCorrupt(let reason):
      return "Model cache corrupt: \(reason)"
    }
  }
}

// MARK: - Model Cache Validation & Recovery

extension MLXEmbeddingProvider {
  /// The HuggingFace Hub caches models under ~/Documents/huggingface/models/<org>/<repo>/
  /// If a download was interrupted (e.g. WAN sync), safetensor files may be truncated.
  /// MLX C++ will SIGABRT on corrupt safetensors, which isn't catchable.
  /// This validates the cache pre-flight to provide a graceful error instead.
  static func modelCacheURL(huggingFaceId: String) -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return documents
      .appendingPathComponent("huggingface")
      .appendingPathComponent("models")
      .appendingPathComponent(huggingFaceId)
  }

  /// Validate that cached model files are complete. Returns nil if OK, or a description of the issue.
  static func validateModelCache(huggingFaceId: String) -> String? {
    let modelDir = modelCacheURL(huggingFaceId: huggingFaceId)
    let fm = FileManager.default

    // No cache dir = model hasn't been downloaded yet, Hub will handle download
    guard fm.fileExists(atPath: modelDir.path) else { return nil }

    // Check for .incomplete files — indicates an interrupted download
    let cacheDir = modelDir.appendingPathComponent(".cache")
    if fm.fileExists(atPath: cacheDir.path) {
      if let cacheContents = try? fm.contentsOfDirectory(atPath: cacheDir.path) {
        // Recursively check for .incomplete files
        if hasIncompleteFiles(in: cacheDir, fm: fm) {
          return "Found .incomplete download marker files — download was interrupted"
        }
        _ = cacheContents  // suppress unused warning
      }
    }

    // Check that config.json exists (basic sanity — if this is missing, nothing works)
    let configPath = modelDir.appendingPathComponent("config.json")
    guard fm.fileExists(atPath: configPath.path) else {
      return "Missing config.json — partial download"
    }

    // Check safetensor files aren't empty/tiny (a truncated download)
    let safetensorFiles = (try? fm.contentsOfDirectory(atPath: modelDir.path))?
      .filter { $0.hasSuffix(".safetensors") } ?? []
    for file in safetensorFiles {
      let filePath = modelDir.appendingPathComponent(file)
      if let attrs = try? fm.attributesOfItem(atPath: filePath.path),
         let size = attrs[.size] as? Int64 {
        // A valid safetensors file has at minimum a JSON header + some weights.
        // Anything under 1KB is clearly truncated/corrupt.
        if size < 1024 {
          return "Safetensors file '\(file)' is only \(size) bytes — likely truncated"
        }
      }
    }

    return nil
  }

  /// Recursively check for .incomplete files in the cache directory
  private static func hasIncompleteFiles(in dir: URL, fm: FileManager) -> Bool {
    guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
    while let url = enumerator.nextObject() as? URL {
      if url.lastPathComponent.hasSuffix(".incomplete") {
        return true
      }
    }
    return false
  }

  /// Remove the cached model directory so it can be re-downloaded cleanly.
  /// Call this when the user wants to recover from a corrupt download.
  @discardableResult
  static func clearModelCache(huggingFaceId: String) -> Bool {
    let modelDir = modelCacheURL(huggingFaceId: huggingFaceId)
    let fm = FileManager.default
    guard fm.fileExists(atPath: modelDir.path) else { return true }
    do {
      try fm.removeItem(at: modelDir)
      print("[MLX] Cleared model cache for \(huggingFaceId)")
      return true
    } catch {
      print("[MLX] Failed to clear model cache for \(huggingFaceId): \(error)")
      return false
    }
  }

  /// Clear caches for all known embedding models.
  static func clearAllModelCaches() {
    for model in MLXEmbeddingModelConfig.availableModels {
      clearModelCache(huggingFaceId: model.huggingFaceId)
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
