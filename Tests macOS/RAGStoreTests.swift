//
//  RAGStoreTests.swift
//  Peel
//
//  Tests for RAG store initialization and analyzer integration
//

import XCTest
@testable import Peel
import RAGCore

#if os(macOS)

@MainActor
final class RAGStoreTests: XCTestCase {

  // MARK: - MLXCodeAnalyzer Tests

  /// Test that MLXCodeAnalyzer conforms to ChunkAnalyzer protocol
  /// Regression: Missing protocol conformance caused type mismatch errors
  func testMLXCodeAnalyzerConformsToChunkAnalyzer() {
    let analyzer = MLXCodeAnalyzerFactory.makeAnalyzer(tier: .tiny)

    // Should compile if conformance exists — this is the regression guard
    let castedAnalyzer: any ChunkAnalyzer = analyzer
    XCTAssertNotNil(castedAnalyzer)

    // Verify protocol requirement: analyzerName
    XCTAssertFalse(analyzer.analyzerName.isEmpty, "Analyzer should have a name")
  }

  /// Test that analyzer factory produces a tier recommendation string
  func testMLXCodeAnalyzerFactoryRecommendation() {
    let recommendation = MLXCodeAnalyzerFactory.recommendedTierDescription()
    XCTAssertFalse(recommendation.isEmpty, "Factory should return recommendation")
    XCTAssertTrue(recommendation.contains("GB RAM"), "Recommendation should mention RAM")
  }

  /// Test MLXCodeAnalyzer tier naming
  func testMLXCodeAnalyzerTiers() {
    let tiny = MLXCodeAnalyzerFactory.makeAnalyzer(tier: .tiny)
    let small = MLXCodeAnalyzerFactory.makeAnalyzer(tier: .small)
    let medium = MLXCodeAnalyzerFactory.makeAnalyzer(tier: .medium)

    XCTAssertFalse(tiny.analyzerName.isEmpty)
    XCTAssertFalse(small.analyzerName.isEmpty)
    XCTAssertFalse(medium.analyzerName.isEmpty)

    // Different tiers should have different model names
    XCTAssertNotEqual(tiny.analyzerName, medium.analyzerName,
      "Tiny and medium tiers should use different models")
  }

  // MARK: - MockChunkAnalyzer Tests

  /// Test that MockChunkAnalyzer satisfies ChunkAnalyzer protocol
  func testMockChunkAnalyzerProtocol() async throws {
    let mock = MockChunkAnalyzer()
    let result = try await mock.analyze(
      chunk: "func test() {}",
      constructType: "function",
      constructName: "test",
      language: "Swift"
    )
    XCTAssertTrue(result.summary.contains("test"), "Mock should include construct name")
    XCTAssertTrue(result.tags.contains("mock"), "Mock should return mock tags")
  }

  /// Test makeDefaultRAGStore can accept a custom analyzer without model loading
  func testMakeDefaultRAGStoreWithMockAnalyzer() {
    let mock = MockChunkAnalyzer()
    // Pass mock to avoid loading real MLX models
    let store = makeDefaultRAGStore(chunkAnalyzer: mock)
    XCTAssertNotNil(store, "RAGStore should be created with mock analyzer")
  }
}

// MARK: - Mock Analyzer

/// Mock analyzer for testing (avoids loading real MLX models)
final class MockChunkAnalyzer: ChunkAnalyzer, @unchecked Sendable {
  nonisolated var analyzerName: String { "MockAnalyzer" }

  func analyze(
    chunk: String,
    constructType: String?,
    constructName: String?,
    language: String?
  ) async throws -> ChunkAnalysis {
    ChunkAnalysis(
      summary: "Mock summary for \(constructName ?? "unknown")",
      tags: ["mock", "test"]
    )
  }
}

#endif
