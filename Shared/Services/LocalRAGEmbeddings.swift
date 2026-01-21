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

protocol LocalRAGEmbeddingProvider: Sendable {
  func embed(texts: [String]) async throws -> [[Float]]
  var dimensions: Int { get }
}

enum LocalRAGEmbeddingProviderFactory {
  private static let useCoreMLKey = "localrag.useCoreML"
  private static let modelFolderName = "Peel/RAG/Models"

  static func makeDefault() -> LocalRAGEmbeddingProvider {
    let wantsCoreML = UserDefaults.standard.object(forKey: useCoreMLKey) as? Bool ?? false
    if wantsCoreML,
       let coreMLProvider = CoreMLEmbeddingProvider.makeDefault(modelFolderName: modelFolderName) {
      return coreMLProvider
    }
    if let coreMLProvider = CoreMLEmbeddingProvider.makeDefault(modelFolderName: modelFolderName) {
      return coreMLProvider
    }
    if let provider = SystemEmbeddingProvider() {
      return provider
    }
    return HashEmbeddingProvider()
  }
}

struct SystemEmbeddingProvider: LocalRAGEmbeddingProvider, @unchecked Sendable {
  let embedding: NLEmbedding
  let dimensions: Int

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
      // Sanitize text to prevent CoreNLP crashes
      let sanitized = sanitizeText(text)
      guard !sanitized.isEmpty else {
        return Array(repeating: Float(0), count: dimensions)
      }
      let vector = embedding.vector(for: sanitized) ?? Array(repeating: 0, count: dimensions)
      return vector.map { Float($0) }
    }
  }

  /// Sanitizes text to prevent NLEmbedding crashes from malformed input
  private func sanitizeText(_ text: String) -> String {
    // Truncate overly long text
    var result = text.count > maxTextLength ? String(text.prefix(maxTextLength)) : text

    // Remove null bytes and other control characters that crash CoreNLP
    result = result.unicodeScalars
      .filter { scalar in
        // Keep printable characters, newlines, tabs, and standard whitespace
        scalar == "\n" || scalar == "\r" || scalar == "\t" ||
          scalar.properties.isWhitespace ||
          (scalar.value >= 0x20 && scalar.value < 0x7F) ||  // ASCII printable
          (scalar.value >= 0xA0 && !scalar.properties.isNoncharacterCodePoint)  // Extended printable
      }
      .map { Character($0) }
      .reduce(into: "") { $0.append($1) }

    // Collapse excessive whitespace
    result =
      result
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")

    return result
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

struct CoreMLEmbeddingProvider: LocalRAGEmbeddingProvider, @unchecked Sendable {
  let model: MLModel
  let tokenizer: LocalRAGTokenizer
  let maxLength: Int
  let outputName: String
  let dimensions: Int

  static func makeDefault(modelFolderName: String) -> CoreMLEmbeddingProvider? {
    guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let modelsURL = baseURL.appendingPathComponent(modelFolderName, isDirectory: true)
    let modelURL = modelsURL.appendingPathComponent("codebert-base-256.mlmodelc")
    let vocabURL = modelsURL.appendingPathComponent("codebert-base.vocab.json")
    return CoreMLEmbeddingProvider(modelURL: modelURL, vocabURL: vocabURL, maxLength: 256)
  }

  init?(modelURL: URL, vocabURL: URL, maxLength: Int) {
    guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
    guard let tokenizer = SimpleVocabTokenizer(vocabURL: vocabURL) else { return nil }
    guard let model = try? MLModel(contentsOf: modelURL) else { return nil }
    guard let outputName = model.modelDescription.outputDescriptionsByName.keys.first else { return nil }

    self.model = model
    self.tokenizer = tokenizer
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

    return try texts.map { text in
      let (ids, mask) = tokenizer.encode(text, maxLength: maxLength)
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
