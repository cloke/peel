//
//  MLXCodeAnalyzer.swift
//  Peel
//
//  Local code analyzer using MLX LLM models.
//  Generates semantic summaries and tags for RAG chunks.
//
//  Created on 1/30/26.
//

#if os(macOS)
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Model Configuration

/// Code analyzer model tiers based on machine capability
enum MLXAnalyzerModelTier: String, CaseIterable, Sendable {
  /// Auto-select based on available RAM
  case auto
  
  /// Tiny models (~0.5B) - good for machines with 8-12GB RAM
  /// Fast inference, basic summaries
  case tiny
  
  /// Small models (~1.5B) - good for machines with 12-24GB RAM
  /// Good balance of speed and quality - DEFAULT for M3 18GB
  case small
  
  /// Medium models (~3B) - good for machines with 24-48GB RAM
  /// Better quality summaries
  case medium
  
  /// Large models (~7B) - good for machines with 48GB+ RAM
  /// Best quality - ideal for Mac Studio
  case large
  
  var description: String {
    switch self {
    case .auto: return "Auto (based on RAM)"
    case .tiny: return "Tiny (8-12GB RAM)"
    case .small: return "Small (12-24GB RAM)"
    case .medium: return "Medium (24-48GB RAM)"
    case .large: return "Large (48GB+ RAM)"
    }
  }
  
  var modelName: String {
    switch self {
    case .auto: return "Auto"
    case .tiny: return "Qwen2.5-Coder-0.5B"
    case .small: return "Qwen2.5-Coder-1.5B"
    case .medium: return "Qwen2.5-Coder-3B"
    case .large: return "Qwen2.5-Coder-7B"
    }
  }
  
  /// Get recommended tier for given RAM
  static func recommended(forMemoryGB gb: Double) -> MLXAnalyzerModelTier {
    if gb >= 48 {
      return .large   // Mac Studio / Mac Pro
    } else if gb >= 24 {
      return .medium  // MacBook Pro 32GB
    } else if gb >= 12 {
      return .small   // M3 18GB (default team machine)
    } else {
      return .tiny    // 8GB machines
    }
  }
}

/// Configuration for an MLX code analyzer model
struct MLXAnalyzerModelConfig: Sendable {
  let name: String
  let huggingFaceId: String
  let tier: MLXAnalyzerModelTier
  let maxTokens: Int
  let contextLength: Int
  
  /// Available Qwen2.5-Coder models for code analysis
  static let availableModels: [MLXAnalyzerModelConfig] = [
    // Tiny tier - Qwen2.5-Coder-0.5B (fast, basic quality)
    MLXAnalyzerModelConfig(
      name: "Qwen2.5-Coder-0.5B",
      huggingFaceId: "mlx-community/Qwen2.5-Coder-0.5B-Instruct-4bit",
      tier: .tiny,
      maxTokens: 256,
      contextLength: 4096
    ),
    
    // Small tier - Qwen2.5-Coder-1.5B (default for 18GB M3)
    MLXAnalyzerModelConfig(
      name: "Qwen2.5-Coder-1.5B",
      huggingFaceId: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
      tier: .small,
      maxTokens: 256,
      contextLength: 8192
    ),
    
    // Medium tier - Qwen2.5-Coder-3B (better quality)
    MLXAnalyzerModelConfig(
      name: "Qwen2.5-Coder-3B",
      huggingFaceId: "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
      tier: .medium,
      maxTokens: 256,
      contextLength: 16384
    ),
    
    // Large tier - Qwen2.5-Coder-7B (best quality for Mac Studio)
    MLXAnalyzerModelConfig(
      name: "Qwen2.5-Coder-7B",
      huggingFaceId: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
      tier: .large,
      maxTokens: 256,
      contextLength: 32768
    )
  ]
  
  /// Select the best model for the current machine's RAM
  static func recommendedModel() -> MLXAnalyzerModelConfig {
    let availableMemoryGB = getAvailableMemoryGB()
    let tier: MLXAnalyzerModelTier
    
    if availableMemoryGB >= 48 {
      tier = .large   // Mac Studio / Mac Pro
    } else if availableMemoryGB >= 24 {
      tier = .medium  // MacBook Pro 32GB
    } else if availableMemoryGB >= 12 {
      tier = .small   // M3 18GB (default team machine)
    } else {
      tier = .tiny    // 8GB machines
    }
    
    return availableModels.first { $0.tier == tier } ?? availableModels[0]
  }
  
  /// Get model for a specific tier
  static func model(for tier: MLXAnalyzerModelTier) -> MLXAnalyzerModelConfig? {
    availableModels.first { $0.tier == tier }
  }
  
  private static func getAvailableMemoryGB() -> Double {
    var size = 0
    var sizeOfSize = MemoryLayout<Int>.size
    sysctlbyname("hw.memsize", &size, &sizeOfSize, nil, 0)
    return Double(size) / 1_073_741_824.0  // bytes to GB
  }
}

// MARK: - Analyzer Result

/// Result of analyzing a code chunk
struct MLXAnalysisResult: Sendable {
  let summary: String
  let tags: [String]
  let model: String
  let analyzedAt: Date
}

// MARK: - MLX Code Analyzer Actor

/// Analyzes code chunks using local MLX LLM models.
/// Generates semantic summaries and tags for better RAG retrieval.
actor MLXCodeAnalyzer {
  private var modelContainer: ModelContainer?
  private let config: MLXAnalyzerModelConfig
  private var isLoaded = false
  /// Cached load error — prevents retrying a failed download for every chunk in a batch.
  private var loadError: Error?

  nonisolated let modelName: String
  nonisolated let tier: MLXAnalyzerModelTier
  
  /// Create analyzer with specific model configuration
  init(config: MLXAnalyzerModelConfig) {
    self.config = config
    self.modelName = config.name
    self.tier = config.tier
  }
  
  /// Create analyzer with auto-detected best model for the machine
  init() {
    let config = MLXAnalyzerModelConfig.recommendedModel()
    print("[MLXAnalyzer] Selected model: \(config.name) (tier: \(config.tier))")
    self.config = config
    self.modelName = config.name
    self.tier = config.tier
  }
  
  /// Create analyzer for a specific tier
  init(tier: MLXAnalyzerModelTier) {
    let config = MLXAnalyzerModelConfig.model(for: tier) ?? MLXAnalyzerModelConfig.recommendedModel()
    print("[MLXAnalyzer] Selected model: \(config.name) (tier: \(tier))")
    self.config = config
    self.modelName = config.name
    self.tier = tier
  }
  
  /// Pre-load the model so download/init errors surface early.
  /// Call this before starting a batch analysis loop to verify the model works.
  func preload() async throws {
    try await ensureLoaded()
  }

  /// Load the model (lazy - called on first analyze)
  private func ensureLoaded() async throws {
    guard !isLoaded else { return }

    // If a previous load already failed, fast-fail so we don't retry the download
    // for every chunk in a batch.
    if let previousError = loadError {
      throw previousError
    }

    print("[MLXAnalyzer] Loading model: \(config.huggingFaceId)")

    do {
      // Create ModelConfiguration with the HuggingFace ID
      let modelConfig = ModelConfiguration(id: config.huggingFaceId)

      // Load the model with progress tracking
      modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig) { progress in
        // Progress is Foundation.Progress
        let percent = Int(progress.fractionCompleted * 100)
        print("[MLXAnalyzer] Loading: \(percent)% - \(progress.localizedDescription ?? "")")
      }

      isLoaded = true
      print("[MLXAnalyzer] Model ready: \(config.name)")
    } catch {
      // Cache the error so subsequent calls fail fast instead of retrying
      // the download 4000+ times in a batch loop.
      loadError = error
      print("[MLXAnalyzer] Model load FAILED: \(error.localizedDescription)")
      throw error
    }
  }
  
  /// Analyze a code chunk and generate summary + tags
  func analyze(code: String, language: String?, constructType: String?, constructName: String?) async throws -> MLXAnalysisResult {
    try await ensureLoaded()
    
    guard let container = modelContainer else {
      throw MLXAnalyzerError.modelNotLoaded
    }
    
    // Build the prompt
    let prompt = buildPrompt(code: code, language: language, constructType: constructType, constructName: constructName)
    
    // Create chat messages
    let messages: [Chat.Message] = [
      .system(systemPrompt),
      .user(prompt)
    ]
    
    // Create UserInput from chat messages
    let userInput = UserInput(chat: messages)
    
    // Prepare input and generate response
    let lmInput = try await container.prepare(input: userInput)
    
    let parameters = GenerateParameters(
      maxTokens: config.maxTokens,
      temperature: 0.1,  // Low temperature for consistent analysis
      topP: 0.9
    )
    
    // Generate using the async stream API
    var outputText = ""
    let stream = try await container.generate(input: lmInput, parameters: parameters)
    
    for await generation in stream {
      switch generation {
      case .chunk(let text):
        outputText += text
      case .info:
        // Generation complete
        break
      case .toolCall:
        break
      }
    }
    
    // Parse the response
    let parsed = parseResponse(outputText)
    
    return MLXAnalysisResult(
      summary: parsed.summary,
      tags: parsed.tags,
      model: config.name,
      analyzedAt: Date()
    )
  }
  
  /// Analyze multiple chunks in batch
  func analyzeBatch(chunks: [(code: String, language: String?, constructType: String?, constructName: String?)]) async throws -> [MLXAnalysisResult] {
    var results: [MLXAnalysisResult] = []
    
    for chunk in chunks {
      let result = try await analyze(
        code: chunk.code,
        language: chunk.language,
        constructType: chunk.constructType,
        constructName: chunk.constructName
      )
      results.append(result)
    }
    
    return results
  }
  
  /// Unload the model to free memory
  func unload() {
    modelContainer = nil
    isLoaded = false
    loadError = nil
    print("[MLXAnalyzer] Model unloaded")
  }
  
  // MARK: - Private Helpers
  
  private let systemPrompt = """
  You are a code analysis assistant. Analyze code and provide:
  1. A brief one-sentence summary of what the code does
  2. 3-5 semantic tags describing the code's purpose and patterns
  
  Respond in JSON format:
  {"summary": "...", "tags": ["tag1", "tag2", ...]}
  
  Tags should be lowercase, single words or hyphenated phrases like:
  - validation, authentication, api-call, data-transformation
  - error-handling, logging, caching, database
  - ui-component, form-handling, state-management
  - async, concurrency, networking, file-io
  """
  
  private func buildPrompt(code: String, language: String?, constructType: String?, constructName: String?) -> String {
    var context = ""
    if let lang = language { context += "Language: \(lang)\n" }
    if let type = constructType { context += "Type: \(type)\n" }
    if let name = constructName { context += "Name: \(name)\n" }
    
    let truncatedCode = String(code.prefix(2000))  // Limit code size
    
    return """
    \(context.isEmpty ? "" : context + "\n")Code:
    ```
    \(truncatedCode)
    ```
    
    Analyze this code and respond with JSON containing summary and tags.
    """
  }
  
  private func parseResponse(_ response: String) -> (summary: String, tags: [String]) {
    // Try to parse JSON response
    if let data = response.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      let summary = json["summary"] as? String ?? "Code chunk"
      let tags = json["tags"] as? [String] ?? []
      return (summary, tags)
    }
    
    // Fallback: try to extract JSON from response
    if let jsonStart = response.firstIndex(of: "{"),
       let jsonEnd = response.lastIndex(of: "}") {
      let jsonString = String(response[jsonStart...jsonEnd])
      if let data = jsonString.data(using: .utf8),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let summary = json["summary"] as? String ?? "Code chunk"
        let tags = json["tags"] as? [String] ?? []
        return (summary, tags)
      }
    }
    
    // Final fallback: use raw response as summary
    return (String(response.prefix(200)), [])
  }
}

// MARK: - Errors

enum MLXAnalyzerError: LocalizedError {
  case modelNotLoaded
  case analysisFailed
  case invalidResponse
  
  var errorDescription: String? {
    switch self {
    case .modelNotLoaded: return "MLX analyzer model not loaded"
    case .analysisFailed: return "Code analysis failed"
    case .invalidResponse: return "Invalid response from model"
    }
  }
}

// MARK: - ChunkAnalyzer Conformance

import RAGCore

extension MLXCodeAnalyzer: ChunkAnalyzer {
  nonisolated var analyzerName: String {
    modelName
  }
  
  func analyze(
    chunk: String,
    constructType: String?,
    constructName: String?,
    language: String?
  ) async throws -> ChunkAnalysis {
    let result = try await analyze(
      code: chunk,
      language: language,
      constructType: constructType,
      constructName: constructName
    )
    return ChunkAnalysis(summary: result.summary, tags: result.tags)
  }
}

// MARK: - Factory

enum MLXCodeAnalyzerFactory {
  /// User's preferred analyzer tier (nil = auto-detect), persisted to UserDefaults
  @MainActor static var preferredTier: MLXAnalyzerModelTier? {
    get {
      guard let raw = UserDefaults.standard.string(forKey: "rag.analyzer.tier") else { return nil }
      return MLXAnalyzerModelTier(rawValue: raw)
    }
    set {
      if let newValue {
        UserDefaults.standard.set(newValue.rawValue, forKey: "rag.analyzer.tier")
      } else {
        UserDefaults.standard.removeObject(forKey: "rag.analyzer.tier")
      }
    }
  }
  
  /// Whether AI analysis is enabled during indexing
  @MainActor static var analysisEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "rag.analyzer.enabled") }
    set { UserDefaults.standard.set(newValue, forKey: "rag.analyzer.enabled") }
  }
  
  /// Create analyzer with user preference or auto-detect
  @MainActor static func makeAnalyzer() -> MLXCodeAnalyzer {
    if let tier = preferredTier {
      return MLXCodeAnalyzer(tier: tier)
    }
    return MLXCodeAnalyzer()
  }
  
  /// Create analyzer with specific tier
  nonisolated static func makeAnalyzer(tier: MLXAnalyzerModelTier) -> MLXCodeAnalyzer {
    MLXCodeAnalyzer(tier: tier)
  }
  
  /// Get recommended tier description for the current machine
  nonisolated static func recommendedTierDescription() -> String {
    let config = MLXAnalyzerModelConfig.recommendedModel()
    let memGB = Int(getAvailableMemoryGB())
    return "\(config.name) recommended for \(memGB)GB RAM"
  }
  
  private nonisolated static func getAvailableMemoryGB() -> Double {
    var size = 0
    var sizeOfSize = MemoryLayout<Int>.size
    sysctlbyname("hw.memsize", &size, &sizeOfSize, nil, 0)
    return Double(size) / 1_073_741_824.0
  }
}

#endif
