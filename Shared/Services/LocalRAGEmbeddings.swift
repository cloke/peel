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
  static func makeDefault() -> LocalRAGEmbeddingProvider {
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

  var errorDescription: String? {
    switch self {
    case .modelNotConfigured:
      return "Core ML model is not configured"
    case .unsupportedModel:
      return "Core ML model output format is not supported"
    }
  }
}

struct CoreMLEmbeddingProvider: LocalRAGEmbeddingProvider {
  let modelURL: URL?
  let dimensions: Int

  init(modelURL: URL?, dimensions: Int) {
    self.modelURL = modelURL
    self.dimensions = dimensions
  }

  func embed(texts: [String]) async throws -> [[Float]] {
    guard let modelURL else {
      throw LocalRAGEmbeddingError.modelNotConfigured
    }
    _ = try MLModel(contentsOf: modelURL)
    throw LocalRAGEmbeddingError.unsupportedModel
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
