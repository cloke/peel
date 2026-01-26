//
//  LocalRAGEmbeddings.swift
//  Peel
//
//  Created on 1/19/26.
//

import CoreML
import CryptoKit
import Foundation
@preconcurrency import NaturalLanguage
import SwiftBPETokenizer

protocol LocalRAGEmbeddingProvider: Sendable {
  func embed(texts: [String]) async throws -> [[Float]]
  var dimensions: Int { get }
  var modelName: String { get }
}

/// Provider preference for embedding generation
enum EmbeddingProviderType: String, CaseIterable {
  case mlx       // MLX native Swift (preferred - uses all Apple Silicon chips)
  case coreml    // CoreML with pre-converted model
  case system    // Apple NLEmbedding (built-in, no model download)
  case hash      // Hash-based fallback (no semantic understanding)
  case auto      // Auto-select best available
}

enum LocalRAGEmbeddingProviderFactory {
  private static let providerKey = "localrag.provider"
  private static let useCoreMLKey = "localrag.useCoreML"  // legacy
  private static let useSystemKey = "localrag.useSystem"  // legacy
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
      #if os(macOS)
      print("[RAG] Using MLXEmbeddingProvider (native Swift + Apple Silicon)")
      return MLXEmbeddingProvider(forCodeSearch: true)
      #else
      print("[RAG] MLX not available on iOS, falling back")
      return makeFallbackProvider()
      #endif
      
    case .coreml:
      if let provider = CoreMLEmbeddingProvider.makeDefault(modelFolderName: modelFolderName) {
        print("[RAG] Using CoreMLEmbeddingProvider")
        return provider
      }
      print("[RAG] CoreML model not found, falling back")
      return makeFallbackProvider()
      
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
  /// Priority: MLX > CoreML > System > Hash
  private static func makeAutoProvider() -> LocalRAGEmbeddingProvider {
    #if os(macOS)
    // On macOS, prefer MLX for best Apple Silicon utilization
    print("[RAG] Auto-selecting MLXEmbeddingProvider (best for Apple Silicon)")
    return MLXEmbeddingProvider(forCodeSearch: true)
    #else
    // On iOS, try CoreML, then System, then Hash
    if let coreMLProvider = CoreMLEmbeddingProvider.makeDefault(modelFolderName: modelFolderName) {
      print("[RAG] Auto-selected CoreMLEmbeddingProvider")
      return coreMLProvider
    }
    if let provider = SystemEmbeddingProvider() {
      print("[RAG] Auto-selected SystemEmbeddingProvider")
      return provider
    }
    print("[RAG] Auto-selected HashEmbeddingProvider (fallback)")
    return HashEmbeddingProvider()
    #endif
  }
  
  /// Fallback provider chain
  private static func makeFallbackProvider() -> LocalRAGEmbeddingProvider {
    if let provider = SystemEmbeddingProvider() {
      return provider
    }
    return HashEmbeddingProvider()
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

/// Batch tokenizer that calls Python once for all texts.
/// ~100x faster than spawning Python per-text.
struct BatchExternalTokenizer: LocalRAGBatchTokenizer {
  let scriptURL: URL
  let modelId: String
  
  init?(scriptURL: URL, modelId: String) {
    guard FileManager.default.fileExists(atPath: scriptURL.path) else {
      return nil
    }
    self.scriptURL = scriptURL
    self.modelId = modelId
  }
  
  func encode(_ text: String, maxLength: Int) -> ([Int32], [Int32]) {
    // Single text - still use batch for consistency
    let results = encodeBatch([text], maxLength: maxLength)
    return results.first ?? fallbackEncoding(text: text, maxLength: maxLength)
  }
  
  func encodeBatch(_ texts: [String], maxLength: Int) -> [([Int32], [Int32])] {
    guard !texts.isEmpty else { return [] }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      scriptURL.path,
      "--model-id", modelId,
      "--max-length", String(maxLength),
      "--batch"
    ]
    
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    
    do {
      try process.run()
      
      // Write JSON array of texts to stdin
      let jsonData = try JSONSerialization.data(withJSONObject: texts)
      inputPipe.fileHandleForWriting.write(jsonData)
      inputPipe.fileHandleForWriting.closeFile()
      
      process.waitUntilExit()
    } catch {
      return texts.map { fallbackEncoding(text: $0, maxLength: maxLength) }
    }
    
    guard process.terminationStatus == 0 else {
      return texts.map { fallbackEncoding(text: $0, maxLength: maxLength) }
    }
    
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return texts.map { fallbackEncoding(text: $0, maxLength: maxLength) }
    }
    
    return results.enumerated().map { index, dict in
      guard let idsAny = dict["input_ids"],
            let maskAny = dict["attention_mask"] else {
        return fallbackEncoding(text: texts[index], maxLength: maxLength)
      }
      let ids = parseIntArray(idsAny, maxLength: maxLength)
      let mask = parseIntArray(maskAny, maxLength: maxLength)
      return (ids.map(Int32.init), mask.map(Int32.init))
    }
  }
  
  private func parseIntArray(_ value: Any, maxLength: Int) -> [Int] {
    if let array = value as? [Int] {
      return normalize(array, maxLength: maxLength)
    }
    if let array = value as? [NSNumber] {
      return normalize(array.map { $0.intValue }, maxLength: maxLength)
    }
    return Array(repeating: 0, count: maxLength)
  }
  
  private func normalize(_ array: [Int], maxLength: Int) -> [Int] {
    if array.count == maxLength { return array }
    if array.count > maxLength { return Array(array.prefix(maxLength)) }
    return array + Array(repeating: 0, count: maxLength - array.count)
  }
  
  private func fallbackEncoding(text: String, maxLength: Int) -> ([Int32], [Int32]) {
    let words = text.split { $0.isWhitespace || $0.isNewline }
    var ids = [Int](repeating: 0, count: maxLength)
    var mask = [Int](repeating: 0, count: maxLength)
    let count = min(words.count, maxLength)
    for index in 0..<count {
      ids[index] = 1
      mask[index] = 1
    }
    return (ids.map(Int32.init), mask.map(Int32.init))
  }
}

/// Legacy per-text tokenizer (kept for fallback)
struct ExternalTokenizer: LocalRAGTokenizer {
  let scriptURL: URL
  let modelId: String

  init?(scriptURL: URL, modelId: String) {
    guard FileManager.default.isExecutableFile(atPath: scriptURL.path) ||
            FileManager.default.fileExists(atPath: scriptURL.path) else {
      return nil
    }
    self.scriptURL = scriptURL
    self.modelId = modelId
  }

  func encode(_ text: String, maxLength: Int) -> ([Int32], [Int32]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      scriptURL.path,
      "--model-id", modelId,
      "--max-length", String(maxLength),
      "--text", text
    ]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return fallbackEncoding(text: text, maxLength: maxLength)
    }

    guard process.terminationStatus == 0 else {
      return fallbackEncoding(text: text, maxLength: maxLength)
    }

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let idsAny = json["input_ids"],
          let maskAny = json["attention_mask"] else {
      return fallbackEncoding(text: text, maxLength: maxLength)
    }

    let ids = parseIntArray(idsAny, maxLength: maxLength)
    let mask = parseIntArray(maskAny, maxLength: maxLength)
    return (ids.map(Int32.init), mask.map(Int32.init))
  }

  private func parseIntArray(_ value: Any, maxLength: Int) -> [Int] {
    if let array = value as? [Int] {
      return normalize(array, maxLength: maxLength)
    }
    if let array = value as? [NSNumber] {
      return normalize(array.map { $0.intValue }, maxLength: maxLength)
    }
    return Array(repeating: 0, count: maxLength)
  }

  private func normalize(_ array: [Int], maxLength: Int) -> [Int] {
    if array.count == maxLength {
      return array
    }
    if array.count > maxLength {
      return Array(array.prefix(maxLength))
    }
    return array + Array(repeating: 0, count: maxLength - array.count)
  }

  private func fallbackEncoding(text: String, maxLength: Int) -> ([Int32], [Int32]) {
    let words = text.split { $0.isWhitespace || $0.isNewline }
    var ids = [Int](repeating: 0, count: maxLength)
    var mask = [Int](repeating: 0, count: maxLength)
    let count = min(words.count, maxLength)
    for index in 0..<count {
      ids[index] = 1
      mask[index] = 1
    }
    return (ids.map(Int32.init), mask.map(Int32.init))
  }
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

/// Adapts SwiftBPETokenizer package's BPETokenizer to LocalRAGBatchTokenizer protocol
struct PackageBPETokenizerAdapter: LocalRAGBatchTokenizer {
  private let tokenizer: BPETokenizer
  
  init?(vocabURL: URL, mergesURL: URL) {
    guard let tokenizer = try? BPETokenizer(vocabURL: vocabURL, mergesURL: mergesURL) else {
      return nil
    }
    self.tokenizer = tokenizer
  }
  
  func encode(_ text: String, maxLength: Int) -> ([Int32], [Int32]) {
    let output = tokenizer.encode(text, maxLength: maxLength)
    return (output.inputIds, output.attentionMask)
  }
  
  func encodeBatch(_ texts: [String], maxLength: Int) -> [([Int32], [Int32])] {
    tokenizer.encodeBatch(texts, maxLength: maxLength).map { ($0.inputIds, $0.attentionMask) }
  }
}

struct CoreMLEmbeddingProvider: LocalRAGEmbeddingProvider, @unchecked Sendable {
  let model: MLModel
  let tokenizer: LocalRAGTokenizer
  let batchTokenizer: LocalRAGBatchTokenizer?
  let maxLength: Int
  let outputName: String
  let dimensions: Int
  let modelName: String = "CodeBERT-base-256"

  static func makeDefault(modelFolderName: String) -> CoreMLEmbeddingProvider? {
    let modelDirectories = candidateModelDirectories(modelFolderName: modelFolderName)
    let helperURL = firstExistingHelper(in: modelDirectories)
    for directory in modelDirectories {
      let modelURL = directory.appendingPathComponent("codebert-base-256.mlmodelc")
      let vocabURL = directory.appendingPathComponent("codebert-base.vocab.json")
      let mergesURL = directory.appendingPathComponent("codebert-base.merges.txt")
      if FileManager.default.fileExists(atPath: modelURL.path) {
        let fallbackHelper = directory.appendingPathComponent("tokenize_codebert.py")
        return CoreMLEmbeddingProvider(
          modelURL: modelURL,
          vocabURL: vocabURL,
          mergesURL: mergesURL,
          helperURL: helperURL ?? fallbackHelper,
          maxLength: 256
        )
      }
    }
    return nil
  }

  private static func candidateModelDirectories(modelFolderName: String) -> [URL] {
    var directories: [URL] = []
    if let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      directories.append(baseURL)
    }
    if let bundleId = Bundle.main.bundleIdentifier {
      let containerBase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers")
        .appendingPathComponent(bundleId)
        .appendingPathComponent("Data/Library/Application Support")
      directories.append(containerBase)
    }

    var seen = Set<String>()
    return directories
      .map { $0.appendingPathComponent(modelFolderName, isDirectory: true) }
      .filter { url in
        let path = url.standardizedFileURL.path
        guard !seen.contains(path) else { return false }
        seen.insert(path)
        return true
      }
  }

  private static func firstExistingHelper(in directories: [URL]) -> URL? {
    for directory in directories {
      let helperURL = directory.appendingPathComponent("tokenize_codebert.py")
      if FileManager.default.fileExists(atPath: helperURL.path) {
        return helperURL
      }
    }
    return nil
  }

  init?(modelURL: URL, vocabURL: URL, mergesURL: URL, helperURL: URL, maxLength: Int) {
    guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
    
    // Priority order for tokenizers:
    // 1. Native Swift BPE (fastest - no subprocess at all!)
    // 2. Batch Python tokenizer (one subprocess for all texts)
    // 3. Single-call Python tokenizer (slowest - subprocess per text)
    // 4. Simple vocab fallback (inaccurate but works)
    
    let tokenizer: LocalRAGTokenizer
    let batchTokenizer: LocalRAGBatchTokenizer?
    
    if let swiftBPE = PackageBPETokenizerAdapter(vocabURL: vocabURL, mergesURL: mergesURL) {
      // Best option: pure Swift via swift-bpe-tokenizer package
      tokenizer = swiftBPE
      batchTokenizer = swiftBPE
      #if DEBUG
      print("[RAG] Using native Swift BPE tokenizer (swift-bpe-tokenizer package)")
      #endif
    } else if let batch = BatchExternalTokenizer(scriptURL: helperURL, modelId: "microsoft/codebert-base") {
      tokenizer = batch
      batchTokenizer = batch
      #if DEBUG
      print("[RAG] Using batch Python tokenizer")
      #endif
    } else if let external = ExternalTokenizer(scriptURL: helperURL, modelId: "microsoft/codebert-base") {
      tokenizer = external
      batchTokenizer = nil
      #if DEBUG
      print("[RAG] Using single-call Python tokenizer (slow)")
      #endif
    } else if let fallback = SimpleVocabTokenizer(vocabURL: vocabURL) {
      tokenizer = fallback
      batchTokenizer = nil
      #if DEBUG
      print("[RAG] Using simple vocab tokenizer (fallback)")
      #endif
    } else {
      return nil
    }
    
    guard let model = try? MLModel(contentsOf: modelURL) else { return nil }
    guard let outputName = model.modelDescription.outputDescriptionsByName.keys.first else { return nil }

    self.model = model
    self.tokenizer = tokenizer
    self.batchTokenizer = batchTokenizer
    self.maxLength = maxLength
    self.outputName = outputName
    if let output = model.modelDescription.outputDescriptionsByName[outputName],
       let multiArray = output.multiArrayConstraint,
       let lastDim = multiArray.shape.last?.intValue {
      self.dimensions = lastDim
    } else {
      self.dimensions = 0
    }
  }

  func embed(texts: [String]) async throws -> [[Float]] {
    guard !texts.isEmpty else { return [] }
    guard dimensions > 0 else { throw LocalRAGEmbeddingError.unsupportedModel }

    // Use batch tokenization if available (single Python call for all texts)
    let tokenizedTexts: [([Int32], [Int32])]
    if let batchTokenizer {
      tokenizedTexts = batchTokenizer.encodeBatch(texts, maxLength: maxLength)
    } else {
      tokenizedTexts = texts.map { tokenizer.encode($0, maxLength: maxLength) }
    }
    
    // Generate embeddings for each tokenized text
    return try tokenizedTexts.map { (ids, mask) in
      guard let inputIds = try? MLMultiArray(shape: [1, NSNumber(value: maxLength)], dataType: .int32),
            let attentionMask = try? MLMultiArray(shape: [1, NSNumber(value: maxLength)], dataType: .int32) else {
        throw LocalRAGEmbeddingError.invalidInput
      }

      for index in 0..<maxLength {
        inputIds[index] = NSNumber(value: ids[index])
        attentionMask[index] = NSNumber(value: mask[index])
      }

      let provider = try MLDictionaryFeatureProvider(dictionary: [
        "input_ids": inputIds,
        "attention_mask": attentionMask
      ])
      let prediction = try model.prediction(from: provider)
      guard let output = prediction.featureValue(for: outputName)?.multiArrayValue else {
        throw LocalRAGEmbeddingError.predictionFailed
      }
      return multiArrayToFloatArray(output)
    }
  }

  private func multiArrayToFloatArray(_ array: MLMultiArray) -> [Float] {
    let count = array.count
    var result = [Float]()
    result.reserveCapacity(count)
    for index in 0..<count {
      result.append(Float(truncating: array[index]))
    }
    return result
  }
}

struct LocalRAGModelDescriptor {
  static func describe(modelURL: URL) throws -> [String: Any] {
    let model = try MLModel(contentsOf: modelURL)
    let description = model.modelDescription
    let inputDescriptions = description.inputDescriptionsByName.mapValues { value in
      featureDescription(value)
    }
    let outputDescriptions = description.outputDescriptionsByName.mapValues { value in
      featureDescription(value)
    }

    return [
      "name": description.metadata[.author] as Any,
      "inputs": inputDescriptions,
      "outputs": outputDescriptions
    ]
  }

  private static func featureDescription(_ description: MLFeatureDescription) -> [String: Any] {
    var info: [String: Any] = [
      "type": "\(description.type)",
      "isOptional": description.isOptional
    ]
    if let multiArray = description.multiArrayConstraint {
      info["multiArrayShape"] = multiArray.shape
      info["multiArrayDataType"] = "\(multiArray.dataType)"
    }
    if let imageConstraint = description.imageConstraint {
      info["imageWidth"] = imageConstraint.pixelsWide
      info["imageHeight"] = imageConstraint.pixelsHigh
      info["imagePixelFormat"] = "\(imageConstraint.pixelFormatType)"
    }
    return info
  }
}

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
