//
//  LocalRAGEmbeddings.swift
//  Peel
//
//  Created on 1/19/26.
//

import CryptoKit
import Foundation
import MLX
@preconcurrency import NaturalLanguage
import RAGCore
import SwiftBPETokenizer

/// Backward-compatible alias — the protocol signatures are identical.
typealias LocalRAGEmbeddingProvider = EmbeddingProvider

/// Provider preference for embedding generation
enum EmbeddingProviderType: String, CaseIterable {
  case mlx       // MLX native Swift (preferred - uses all Apple Silicon chips)
  case system    // Apple NLEmbedding (built-in, no model download)
  case hash      // Hash-based fallback (no semantic understanding)
  case auto      // Auto-select best available
}

enum LocalRAGEmbeddingProviderFactory {
  private static let providerKey = "localrag.provider"
  private static let useSystemKey = "localrag.useSystem"  // legacy
  private static let mlxModelIdKey = "localrag.mlxModelId"
  private static let mlxDownloadedModelsKey = "localrag.mlxDownloadedModels"
  private static let mlxCacheLimitMBKey = "localrag.mlxCacheLimitMB"
  private static let mlxClearCacheAfterBatchKey = "localrag.mlxClearCacheAfterBatch"
  private static let modelFolderName = "Peel/RAG/Models"

  /// Get the configured provider preference
  static var preferredProvider: EmbeddingProviderType {
    get {
      if let raw = UserDefaults.standard.string(forKey: providerKey),
         let type = EmbeddingProviderType(rawValue: raw) {
        return type
      }
      // Check legacy keys
      if UserDefaults.standard.bool(forKey: useSystemKey) {
        return .system
      }
      return .auto
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
    }
  }

  static func makeDefault() -> LocalRAGEmbeddingProvider {
    let preference = preferredProvider
    print("[RAG] LocalRAGEmbeddingProviderFactory: preference=\(preference.rawValue)")
    
    switch preference {
    case .mlx:
      print("[RAG] Using MLXEmbeddingProvider (native Swift + Apple Silicon)")
      return makePreferredMLX(forCodeSearch: true)
      
    case .system:
      if let provider = SystemEmbeddingProvider() {
        print("[RAG] Using SystemEmbeddingProvider (Apple NLEmbedding)")
        return provider
      }
      print("[RAG] SystemEmbeddingProvider not available, falling back")
      return makeFallbackProvider()
      
    case .hash:
      print("[RAG] Using HashEmbeddingProvider (no semantic understanding)")
      return HashEmbeddingProvider()
      
    case .auto:
      return makeAutoProvider()
    }
  }
  
  /// Auto-select the best available provider
  /// Priority: MLX > System > Hash
  private static func makeAutoProvider() -> LocalRAGEmbeddingProvider {
    // On macOS, prefer MLX for best Apple Silicon utilization
    print("[RAG] Auto-selecting MLXEmbeddingProvider (best for Apple Silicon)")
    return makePreferredMLX(forCodeSearch: true)
  }
  
  /// Fallback provider chain
  private static func makeFallbackProvider() -> LocalRAGEmbeddingProvider {
    if let provider = SystemEmbeddingProvider() {
      return provider
    }
    return HashEmbeddingProvider()
  }

  // MARK: - MLX Preferences (macOS)

  static var preferredMLXModelId: String? {
    get {
      UserDefaults.standard.string(forKey: mlxModelIdKey)
    }
    set {
      if let newValue, !newValue.isEmpty {
        UserDefaults.standard.set(newValue, forKey: mlxModelIdKey)
      } else {
        UserDefaults.standard.removeObject(forKey: mlxModelIdKey)
      }
    }
  }

  static var downloadedMLXModels: [String] {
    get {
      UserDefaults.standard.stringArray(forKey: mlxDownloadedModelsKey) ?? []
    }
    set {
      UserDefaults.standard.set(Array(Set(newValue)), forKey: mlxDownloadedModelsKey)
    }
  }

  static func recordDownloadedMLXModel(_ modelId: String) {
    guard !modelId.isEmpty else { return }
    var current = downloadedMLXModels
    current.append(modelId)
    downloadedMLXModels = current
  }

  static var mlxCacheLimitMB: Int? {
    get {
      guard UserDefaults.standard.object(forKey: mlxCacheLimitMBKey) != nil else {
        return nil
      }
      return UserDefaults.standard.integer(forKey: mlxCacheLimitMBKey)
    }
    set {
      if let newValue {
        UserDefaults.standard.set(newValue, forKey: mlxCacheLimitMBKey)
      } else {
        UserDefaults.standard.removeObject(forKey: mlxCacheLimitMBKey)
      }
    }
  }

  static var mlxClearCacheAfterBatch: Bool {
    get {
      // Default to true for memory safety - prevents unbounded GPU memory growth
      if UserDefaults.standard.object(forKey: mlxClearCacheAfterBatchKey) == nil {
        return true
      }
      return UserDefaults.standard.bool(forKey: mlxClearCacheAfterBatchKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: mlxClearCacheAfterBatchKey)
    }
  }

  // MARK: - Memory Pressure Management

  private static let mlxMemoryLimitGBKey = "localrag.mlxMemoryLimitGB"

  /// Maximum process memory in GB before pausing indexing (default: 80% of physical RAM)
  static var mlxMemoryLimitGB: Double {
    get {
      if UserDefaults.standard.object(forKey: mlxMemoryLimitGBKey) != nil {
        return UserDefaults.standard.double(forKey: mlxMemoryLimitGBKey)
      }
      // Default to 80% of physical RAM
      return Double(physicalMemoryBytes()) / 1_073_741_824.0 * 0.8
    }
    set {
      UserDefaults.standard.set(newValue, forKey: mlxMemoryLimitGBKey)
    }
  }

  /// Check if current process memory exceeds the configured limit
  static func isMemoryPressureHigh() -> Bool {
    let currentGB = Double(currentProcessMemoryBytes()) / 1_073_741_824.0
    return currentGB > mlxMemoryLimitGB
  }

  /// Get current process resident memory in bytes
  static func currentProcessMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size)
  }

  /// Get physical RAM in bytes
  static func physicalMemoryBytes() -> UInt64 {
    var size: UInt64 = 0
    var sizeOfSize = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &size, &sizeOfSize, nil, 0)
    return size
  }

  private static func makePreferredMLX(forCodeSearch: Bool = true) -> LocalRAGEmbeddingProvider {
    if let selectedId = preferredMLXModelId,
       let config = MLXEmbeddingModelConfig.availableModels.first(where: {
         $0.huggingFaceId == selectedId || $0.name == selectedId
       }) {
      return MLXEmbeddingProvider(config: config)
    }
    return MLXEmbeddingProvider(forCodeSearch: forCodeSearch)
  }
}

struct SystemEmbeddingProvider: LocalRAGEmbeddingProvider, @unchecked Sendable {
  let embedding: NLEmbedding
  let dimensions: Int
  let modelName: String = "Apple NLEmbedding"

  /// Maximum text length to avoid CoreNLP issues
  private let maxTextLength = 10_000

  init?() {
    guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
      return nil
    }
    self.embedding = embedding
    self.dimensions = embedding.dimension
  }

  func embed(texts: [String]) async throws -> [[Float]] {
    texts.map { text in
      let sanitized = TextSanitizer.sanitize(text)
      guard !sanitized.isEmpty else {
        return Array(repeating: Float(0), count: dimensions)
      }
      let vector = embedding.vector(for: sanitized) ?? Array(repeating: 0, count: dimensions)
      return vector.map { Float($0) }
    }
  }
}

enum LocalRAGEmbeddingError: LocalizedError {
  case modelNotConfigured
  case unsupportedModel
  case tokenizerMissing
  case invalidInput
  case predictionFailed

  var errorDescription: String? {
    switch self {
    case .modelNotConfigured:
      return "Core ML model is not configured"
    case .unsupportedModel:
      return "Core ML model output format is not supported"
    case .tokenizerMissing:
      return "Tokenizer assets are missing for the Core ML embedding model"
    case .invalidInput:
      return "Invalid embedding input"
    case .predictionFailed:
      return "Core ML prediction failed"
    }
  }
}

protocol LocalRAGTokenizer: Sendable {
  func encode(_ text: String, maxLength: Int) -> ([Int32], [Int32])
}

/// Protocol for batch tokenization - critical for performance
protocol LocalRAGBatchTokenizer: LocalRAGTokenizer {
  func encodeBatch(_ texts: [String], maxLength: Int) -> [([Int32], [Int32])]
}
struct SimpleVocabTokenizer: LocalRAGTokenizer {
  private let vocab: [String: Int]
  private let unknownId: Int
  private let padId: Int
  private let bosId: Int
  private let eosId: Int

  init?(vocabURL: URL) {
    guard let data = try? Data(contentsOf: vocabURL),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    var parsed: [String: Int] = [:]
    parsed.reserveCapacity(raw.count)
    for (key, value) in raw {
      if let intValue = value as? Int {
        parsed[key] = intValue
      } else if let number = value as? NSNumber {
        parsed[key] = number.intValue
      }
    }
    guard !parsed.isEmpty else { return nil }
    vocab = parsed
    unknownId = vocab["<unk>"] ?? 0
    padId = vocab["<pad>"] ?? 1
    bosId = vocab["<s>"] ?? 0
    eosId = vocab["</s>"] ?? 2
  }

  func encode(_ text: String, maxLength: Int) -> ([Int32], [Int32]) {
    let tokens = text
      .split { $0.isWhitespace || $0.isNewline }
      .map { String($0) }

    var ids: [Int] = [bosId]
    ids.append(contentsOf: tokens.map { vocab[$0] ?? unknownId })
    ids.append(eosId)

    if ids.count > maxLength {
      ids = Array(ids.prefix(maxLength))
      if ids.count > 1 {
        ids[ids.count - 1] = eosId
      }
    }

    var mask = Array(repeating: 0, count: maxLength)
    for index in 0..<min(ids.count, maxLength) {
      mask[index] = 1
    }

    if ids.count < maxLength {
      ids.append(contentsOf: Array(repeating: padId, count: maxLength - ids.count))
    }

    return (ids.map(Int32.init), mask.map(Int32.init))
  }
}

// MARK: - Package Tokenizer Adapter

struct HashEmbeddingProvider: LocalRAGEmbeddingProvider {
  let dimensions: Int = 128
  let modelName: String = "Hash-based (no semantic)"

  func embed(texts: [String]) async throws -> [[Float]] {
    texts.map { text in
      let digest = SHA256.hash(data: Data(text.utf8))
      var vector = [Float](repeating: 0, count: dimensions)
      for (index, byte) in digest.enumerated() {
        let value = Float(byte) / 255.0
        let slot = index % dimensions
        vector[slot] = (vector[slot] + value).truncatingRemainder(dividingBy: 1.0)
      }
      return normalize(vector)
    }
  }

  private func normalize(_ vector: [Float]) -> [Float] {
    let sumSquares = vector.reduce(0) { $0 + $1 * $1 }
    let magnitude = sqrt(max(sumSquares, 0.000001))
    return vector.map { $0 / magnitude }
  }
}

// MARK: - MLX Memory Pressure Monitor

/// Bridges the app's MLX memory management into RAGCore's protocol.
struct MLXMemoryPressureMonitor: MemoryPressureMonitor {
  func isMemoryPressureHigh() -> Bool {
    LocalRAGEmbeddingProviderFactory.isMemoryPressureHigh()
  }

  func clearCaches() async {
    #if os(macOS)
    if LocalRAGEmbeddingProviderFactory.mlxClearCacheAfterBatch {
      await MainActor.run {
        MLX.Memory.clearCache()
      }
    }
    #endif
  }

  func memoryDescription() -> String {
    #if os(macOS)
    let snapshot = MLX.Memory.snapshot()
    let peakMB = Double(snapshot.peakMemory) / 1_048_576
    let currentMB = Double(snapshot.activeMemory) / 1_048_576
    return String(format: "MLX active=%.1f MB, peak=%.1f MB", currentMB, peakMB)
    #else
    return "no MLX on iOS"
    #endif
  }
}
