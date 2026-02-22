import SwiftUI

// MARK: - Repository Status

/// Visual status states for a repository
enum RAGRepoStatus: Equatable {
  case notIndexed
  case indexing
  case indexedOnly
  case analyzing(progress: Double)
  case partiallyAnalyzed(progress: Double)
  case fullyAnalyzed
  case stale
  
  var badge: String {
    switch self {
    case .notIndexed: return "○"
    case .indexing: return "◐"
    case .indexedOnly: return "◑"
    case .analyzing: return "◐"
    case .partiallyAnalyzed: return "◕"
    case .fullyAnalyzed: return "●"
    case .stale: return "⚠"
    }
  }
  
  var color: Color {
    switch self {
    case .notIndexed: return .gray
    case .indexing: return .blue
    case .indexedOnly: return .yellow
    case .analyzing: return .purple
    case .partiallyAnalyzed: return .orange
    case .fullyAnalyzed: return .green
    case .stale: return .orange
    }
  }
  
  var label: String {
    switch self {
    case .notIndexed: return "Not indexed"
    case .indexing: return "Indexing..."
    case .indexedOnly: return "Indexed"
    case .analyzing(let progress): return "Analyzing \(Int(progress * 100))%"
    case .partiallyAnalyzed(let progress): return "\(Int(progress * 100))% analyzed"
    case .fullyAnalyzed: return "Complete"
    case .stale: return "Stale"
    }
  }
}
