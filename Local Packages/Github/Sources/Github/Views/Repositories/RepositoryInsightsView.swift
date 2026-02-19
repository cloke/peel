//
//  RepositoryInsightsView.swift
//  Github
//
//  Created on 1/20/26.
//

import Charts
import SwiftUI
import PeelUI

struct RepositoryInsightsView: View {
  let repository: Github.Repository

  var body: some View {
    AsyncContentView(
      load: { try await loadInsightsData(for: repository) },
      isEmpty: { $0.issuePoints.isEmpty && $0.prPoints.isEmpty },
      content: { data in
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            TrendChart(title: "Repo Health: Open Issues", points: data.issuePoints, color: .purple)
            TrendChart(title: "Repo Health: Open PRs", points: data.prPoints, color: .blue)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
      },
      loadingView: { ProgressView() },
      emptyView: { EmptyStateView("No Data", systemImage: "chart.line.downtrend.xyaxis") }
    )
    .id(repository.id)
  }
}

// MARK: - Data Loading

private struct InsightsData {
  let issuePoints: [RepoTrendPoint]
  let prPoints: [RepoTrendPoint]
}

private func loadInsightsData(for repository: Github.Repository) async throws -> InsightsData {
  async let issuesTask = Github.issues(from: repository, state: "all")
  async let prsTask = Github.pullRequests(from: repository, state: "all")
  
  let (allIssues, pullRequests) = try await (issuesTask, prsTask)
  let issues = allIssues.filter { $0.pull_request == nil }
  
  let calendar = Calendar.current
  let weeks = chartWeekStarts(calendar: calendar)
  
  let issueItems = issues.compactMap { makeItem(created: $0.created_at, closed: $0.closed_at) }
  let prItems = pullRequests.compactMap { makeItem(created: $0.created_at, closed: $0.closed_at) }
  
  return InsightsData(
    issuePoints: weeks.map { RepoTrendPoint(weekStart: $0, count: openCount(items: issueItems, weekStart: $0, calendar: calendar)) },
    prPoints: weeks.map { RepoTrendPoint(weekStart: $0, count: openCount(items: prItems, weekStart: $0, calendar: calendar)) }
  )
}

// chartWeekStarts() moved to Date+Formatting.swift

private func makeItem(created: String?, closed: String?) -> RepoTrendItem? {
  guard let createdDate = GithubDateParser.parse(created) else { return nil }
  return RepoTrendItem(createdAt: createdDate, closedAt: GithubDateParser.parse(closed))
}

private func openCount(items: [RepoTrendItem], weekStart: Date, calendar: Calendar) -> Int {
  guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return 0 }
  return items.reduce(0) { total, item in
    guard item.createdAt <= weekEnd else { return total }
    if let closed = item.closedAt, closed <= weekEnd { return total }
    return total + 1
  }
}

// parseDate() moved to Date+Formatting.swift — use GithubDateParser.parse()

// MARK: - Supporting Views

private struct TrendChart: View {
  let title: String
  let points: [RepoTrendPoint]
  let color: Color
  
  var body: some View {
    SectionCard(title) {
      if points.isEmpty {
        Text("No data yet").font(.caption).foregroundStyle(.secondary)
      } else {
        Chart(points) { point in
          LineMark(x: .value("Week", point.weekStart, unit: .weekOfYear), y: .value("Count", point.count))
            .foregroundStyle(color)
          PointMark(x: .value("Week", point.weekStart, unit: .weekOfYear), y: .value("Count", point.count))
            .foregroundStyle(color)
        }
        .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) }
        .frame(height: 160)
      }
    }
  }
}

private struct RepoTrendItem {
  let createdAt: Date
  let closedAt: Date?
}

private struct RepoTrendPoint: Identifiable {
  let id = UUID()
  let weekStart: Date
  let count: Int
}
