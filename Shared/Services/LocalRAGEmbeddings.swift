//
//  LocalRAGEmbeddings.swift
//  Peel
//
//  Created on 1/19/26.
//

import CoreML
import CryptoKit
import Foundation

protocol LocalRAGEmbeddingProvider: Sendable {
  func embed(texts: [String]) async throws -> [[Float]]
  var dimensions: Int { get }
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
