//
//  HFReranker.swift
//  Peel
//
//  Hugging Face Inference API-based reranker for improving RAG search quality.
//  Cross-encoders provide better relevance scoring than bi-encoders alone.
//
//  Created for Issue #128
//

import Foundation

// MARK: - Reranker Result

/// Simplified result type for reranking
struct RerankerSearchResult: Sendable {
  let filePath: String
  let startLine: Int
  let endLine: Int
  let snippet: String
  let isTest: Bool
  let lineCount: Int
  let constructType: String?
  let constructName: String?
  let language: String?
  var score: Float?
  let modulePath: String?
  let featureTags: [String]
}

// MARK: - Reranker Protocol

/// Protocol for reranking search results
protocol LocalRAGReranker: Sendable {
  /// Rerank results based on relevance to query
  /// - Parameters:
  ///   - query: The search query
  ///   - results: Initial search results to rerank
  ///   - topK: Maximum results to return after reranking
  /// - Returns: Reranked results with updated scores
  func rerank(query: String, results: [RerankerSearchResult], topK: Int) async throws -> [RerankerSearchResult]
  
  /// Provider name for display/logging
  var providerName: String { get }
}

// MARK: - HuggingFace Reranker Configuration

/// Configuration for HuggingFace reranker
struct HFRerankerConfig: Sendable, Codable {
  /// HuggingFace API token (optional for some models)
  let apiToken: String?
  
  /// Model ID on HuggingFace Hub
  let modelId: String
  
  /// Whether to use serverless inference API
  let useServerless: Bool
  
  /// Custom endpoint URL (for dedicated endpoints)
  let customEndpoint: String?
  
  /// Request timeout in seconds
  let timeoutSeconds: Double
  
  static let `default` = HFRerankerConfig(
    apiToken: nil,
    modelId: "BAAI/bge-reranker-base",  // Popular open reranker, ~1.1GB
    useServerless: true,
    customEndpoint: nil,
    timeoutSeconds: 30
  )
  
  /// Smaller reranker for faster inference
  static let fast = HFRerankerConfig(
    apiToken: nil,
    modelId: "BAAI/bge-reranker-v2-m3",  // Smaller, faster
    useServerless: true,
    customEndpoint: nil,
    timeoutSeconds: 15
  )
  
  /// Large reranker for best quality
  static let large = HFRerankerConfig(
    apiToken: nil,
    modelId: "BAAI/bge-reranker-large",  // Best quality, ~1.3GB
    useServerless: true,
    customEndpoint: nil,
    timeoutSeconds: 45
  )
}

// MARK: - HuggingFace Reranker

/// Reranker using HuggingFace Inference API with cross-encoder models
actor HFReranker: LocalRAGReranker {
  private let config: HFRerankerConfig
  private let session: URLSession
  
  nonisolated var providerName: String { "HuggingFace (\(config.modelId))" }
  
  init(config: HFRerankerConfig = .default) {
    self.config = config
    
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = config.timeoutSeconds
    sessionConfig.timeoutIntervalForResource = config.timeoutSeconds * 2
    self.session = URLSession(configuration: sessionConfig)
  }
  
  /// Convenience initializer with just API token
  init(apiToken: String?) {
    let defaultConfig = HFRerankerConfig.default
    self.config = HFRerankerConfig(
      apiToken: apiToken,
      modelId: defaultConfig.modelId,
      useServerless: defaultConfig.useServerless,
      customEndpoint: defaultConfig.customEndpoint,
      timeoutSeconds: defaultConfig.timeoutSeconds
    )
    
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = config.timeoutSeconds
    sessionConfig.timeoutIntervalForResource = config.timeoutSeconds * 2
    self.session = URLSession(configuration: sessionConfig)
  }
  
  func rerank(query: String, results: [RerankerSearchResult], topK: Int) async throws -> [RerankerSearchResult] {
    guard !results.isEmpty else { return [] }
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return results }
    
    // Build request for HuggingFace Inference API
    let url = try buildEndpointURL()
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    if let token = config.apiToken ?? getStoredAPIToken() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    
    // Prepare texts for reranking
    // Cross-encoder models expect query-document pairs
    let texts = results.map { result -> [String] in
      // Use snippet as document, trim to reasonable length
      let document = result.snippet.prefix(2000)
      return [query, String(document)]
    }
    
    // HF Inference API expects {"inputs": {"source_sentence": query, "sentences": [...]}}
    // But for cross-encoders, we use {"inputs": [["query", "doc1"], ["query", "doc2"], ...]}
    let payload: [String: Any] = [
      "inputs": texts,
      "options": [
        "wait_for_model": true
      ]
    ]
    
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    
    let (data, response) = try await session.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse else {
      throw HFRerankerError.invalidResponse
    }
    
    // Handle API errors
    if httpResponse.statusCode == 503 {
      // Model loading
      throw HFRerankerError.modelLoading
    }
    
    if httpResponse.statusCode == 401 {
      throw HFRerankerError.unauthorized
    }
    
    if httpResponse.statusCode != 200 {
      let message = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw HFRerankerError.apiError(statusCode: httpResponse.statusCode, message: message)
    }
    
    // Parse response - expects array of scores
    let scores = try parseScores(from: data)
    
    guard scores.count == results.count else {
      throw HFRerankerError.scoreMismatch(expected: results.count, got: scores.count)
    }
    
    // Combine results with scores and sort
    var scoredResults = zip(results, scores).map { (result, score) in
      var updated = result
      updated.score = score
      return updated
    }
    
    // Sort by score descending
    scoredResults.sort { ($0.score ?? 0) > ($1.score ?? 0) }
    
    // Return top K
    return Array(scoredResults.prefix(topK))
  }
  
  // MARK: - Private Helpers
  
  private func buildEndpointURL() throws -> URL {
    if let custom = config.customEndpoint {
      guard let url = URL(string: custom) else { throw URLError(.badURL) }
      return url
    }
    
    // HuggingFace Serverless Inference API
    guard let url = URL(string: "https://api-inference.huggingface.co/models/\(config.modelId)") else {
      throw URLError(.badURL)
    }
    return url
  }
  
  private func getStoredAPIToken() -> String? {
    // Check UserDefaults for stored token
    UserDefaults.standard.string(forKey: "hf.apiToken")
  }
  
  private func parseScores(from data: Data) throws -> [Float] {
    // HF returns array of scores for cross-encoder
    // Format: [[score1], [score2], ...] or [score1, score2, ...]
    
    if let arrayOfArrays = try? JSONDecoder().decode([[Float]].self, from: data) {
      return arrayOfArrays.map { $0.first ?? 0 }
    }
    
    if let flatArray = try? JSONDecoder().decode([Float].self, from: data) {
      return flatArray
    }
    
    // Try parsing as dictionary with scores
    if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let scores = dict["scores"] as? [Double] {
      return scores.map { Float($0) }
    }
    
    throw HFRerankerError.parseError(String(data: data, encoding: .utf8) ?? "unparseable")
  }
}

// MARK: - Errors

enum HFRerankerError: LocalizedError {
  case invalidResponse
  case modelLoading
  case unauthorized
  case apiError(statusCode: Int, message: String)
  case scoreMismatch(expected: Int, got: Int)
  case parseError(String)
  
  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "Invalid response from HuggingFace API"
    case .modelLoading:
      return "Model is loading on HuggingFace - please retry in a few seconds"
    case .unauthorized:
      return "HuggingFace API token required or invalid"
    case .apiError(let code, let message):
      return "HuggingFace API error (\(code)): \(message)"
    case .scoreMismatch(let expected, let got):
      return "Score count mismatch: expected \(expected), got \(got)"
    case .parseError(let raw):
      return "Failed to parse reranker response: \(raw.prefix(200))"
    }
  }
}

// MARK: - Factory & Preferences

enum HFRerankerFactory {
  private static let enabledKey = "rag.reranker.enabled"
  private static let modelIdKey = "rag.reranker.modelId"
  private static let apiTokenKey = "hf.apiToken"
  
  /// Whether HF reranking is enabled
  static var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: enabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }
  
  /// Selected reranker model ID
  static var modelId: String {
    get { UserDefaults.standard.string(forKey: modelIdKey) ?? HFRerankerConfig.default.modelId }
    set { UserDefaults.standard.set(newValue, forKey: modelIdKey) }
  }
  
  /// HuggingFace API token
  static var apiToken: String? {
    get { UserDefaults.standard.string(forKey: apiTokenKey) }
    set {
      if let value = newValue, !value.isEmpty {
        UserDefaults.standard.set(value, forKey: apiTokenKey)
      } else {
        UserDefaults.standard.removeObject(forKey: apiTokenKey)
      }
    }
  }
  
  /// Create reranker if enabled
  static func makeIfEnabled() -> (any LocalRAGReranker)? {
    guard isEnabled else { return nil }
    
    let config = HFRerankerConfig(
      apiToken: apiToken,
      modelId: modelId,
      useServerless: true,
      customEndpoint: nil,
      timeoutSeconds: 30
    )
    
    return HFReranker(config: config)
  }
  
  /// Available model presets
  static let availableModels: [(id: String, name: String, description: String)] = [
    ("BAAI/bge-reranker-base", "BGE Reranker Base", "Good balance of speed and quality (~1.1GB)"),
    ("BAAI/bge-reranker-v2-m3", "BGE Reranker v2 M3", "Fast, multilingual support"),
    ("BAAI/bge-reranker-large", "BGE Reranker Large", "Best quality, slower (~1.3GB)"),
    ("cross-encoder/ms-marco-MiniLM-L-6-v2", "MS MARCO MiniLM", "Very fast, good for passages"),
  ]
}
