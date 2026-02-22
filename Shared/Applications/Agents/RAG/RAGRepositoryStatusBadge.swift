import SwiftUI

struct RAGRepositoryStatusBadge: View {
  let status: RAGRepoStatus

  var body: some View {
    ZStack {
      Circle()
        .fill(status.color.opacity(0.2))
        .frame(width: 40, height: 40)

      if case .indexing = status {
        ProgressView()
          .scaleEffect(0.6)
      } else if case .analyzing = status {
        ProgressView()
          .scaleEffect(0.6)
          .tint(.purple)
      } else {
        Image(systemName: statusIcon)
          .font(.system(size: 18))
          .foregroundStyle(status.color)
      }
    }
  }

  private var statusIcon: String {
    switch status {
    case .notIndexed: return "folder.badge.questionmark"
    case .indexing: return "arrow.clockwise"
    case .indexedOnly: return "folder"
    case .analyzing: return "cpu"
    case .partiallyAnalyzed: return "chart.pie"
    case .fullyAnalyzed: return "checkmark.circle.fill"
    case .stale: return "exclamationmark.triangle"
    }
  }
}