//
//  LocalRRFMerger.swift
//  Peel
//
//  Reciprocal Rank Fusion (RRF) for merging text + vector search lists.
//
//  Formula: score(d) = Σ 1 / (k + r_i(d))   where k = 60 (per Cormack 2009)
//
//  Runs entirely locally — no API calls, no models, no API limits.
//  Used when mode: "hybrid" is passed to rag.search.
//

import Foundation

enum LocalRRFMerger {
  /// Standard RRF k constant. Higher k = less penalisation for low ranks.
  static let k: Float = 60

  /// Merge two ranked result lists with RRF.
  ///
  /// - Parameters:
  ///   - text:    Results from text/keyword search, ordered best-first.
  ///   - vector:  Results from vector/semantic search, ordered best-first.
  ///   - topK:    Maximum number of merged results to return.
  /// - Returns:   De-duplicated, RRF-scored results sorted best-first.
  static func merge(
    text: [RAGToolSearchResult],
    vector: [RAGToolSearchResult],
    topK: Int
  ) -> [RAGToolSearchResult] {
    // key = "filePath:startLine" — unique per chunk
    var rrfScores: [String: Float] = [:]
    var lookup: [String: RAGToolSearchResult] = [:]

    func accumulate(_ results: [RAGToolSearchResult]) {
      for (rank, result) in results.enumerated() {
        let key = "\(result.filePath):\(result.startLine)"
        rrfScores[key, default: 0] += 1.0 / (k + Float(rank + 1))
        if lookup[key] == nil { lookup[key] = result }
      }
    }

    accumulate(text)
    accumulate(vector)

    return rrfScores
      .sorted { $0.value > $1.value }
      .prefix(topK)
      .compactMap { (key, rrfScore) in
        guard let base = lookup[key] else { return nil }
        return RAGToolSearchResult(
          filePath: base.filePath,
          startLine: base.startLine,
          endLine: base.endLine,
          snippet: base.snippet,
          isTest: base.isTest,
          lineCount: base.lineCount,
          constructType: base.constructType,
          constructName: base.constructName,
          language: base.language,
          score: Double(rrfScore),
          modulePath: base.modulePath,
          featureTags: base.featureTags,
          aiSummary: base.aiSummary,
          aiTags: base.aiTags,
          tokenCount: base.tokenCount
        )
      }
  }
}
