//
//  RepositoryInsightsView.swift
//  Github
//
//  Created on 1/20/26.
//

import Charts
import SwiftUI

struct RepositoryInsightsView: View {
  let repository: Github.Repository

  @State private var isLoading = true
  @State private var issuePoints: [RepoTrendPoint] = []
  @State private var prPoints: [RepoTrendPoint] = []
  @State private var errorMessage: String?

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let fallbackFormatter = ISO8601DateFormatter()
  private let calendar = Calendar.current
  private let chartWeeks = 12

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if isLoading {
          ProgressView()
        } else if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        } else {
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Text("Repo Health: Open Issues")
                .font(.headline)
              if issuePoints.isEmpty {
                Text("No issue trend data yet")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else {
                Chart(issuePoints) { point in
                  LineMark(
                    x: .value("Week", point.weekStart, unit: .weekOfYear),
                    y: .value("Open Issues", point.count)
                  )
                  .foregroundStyle(.purple)
                  PointMark(
                    x: .value("Week", point.weekStart, unit: .weekOfYear),
                    y: .value("Open Issues", point.count)
                  )
                  .foregroundStyle(.purple)
                }
                .chartXAxis {
                  AxisMarks(values: .stride(by: .weekOfYear, count: 2))
                }
                .frame(height: 160)
              }
            }
            .padding(.vertical, 4)
          }

          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Text("Repo Health: Open PRs")
                .font(.headline)
              if prPoints.isEmpty {
                Text("No PR trend data yet")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else {
                Chart(prPoints) { point in
                  LineMark(
                    x: .value("Week", point.weekStart, unit: .weekOfYear),
                    y: .value("Open PRs", point.count)
                  )
                  .foregroundStyle(.blue)
                  PointMark(
                    x: .value("Week", point.weekStart, unit: .weekOfYear),
                    y: .value("Open PRs", point.count)
                  )
                  .foregroundStyle(.blue)
                }
                .chartXAxis {
                  AxisMarks(values: .stride(by: .weekOfYear, count: 2))
                }
                .frame(height: 160)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .task(id: repository.id) {
      await loadInsights()
    }
  }

  private func loadInsights() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let allIssues = try await Github.issues(from: repository, state: "all")
      let issues = allIssues.filter { $0.pull_request == nil }
      let pullRequests = try await Github.pullRequests(from: repository, state: "all")

      let issueItems = issues.compactMap { issue in
        makeItem(created: issue.created_at, closed: issue.closed_at)
      }
      let prItems = pullRequests.compactMap { pr in
        makeItem(created: pr.created_at, closed: pr.closed_at)
      }

      let weeks = chartWeekStarts
      issuePoints = weeks.map { week in
        RepoTrendPoint(weekStart: week, count: openCount(items: issueItems, weekStart: week))
      }
      prPoints = weeks.map { week in
        RepoTrendPoint(weekStart: week, count: openCount(items: prItems, weekStart: week))
      }
    } catch {
      errorMessage = "Failed to load insights: \(error.localizedDescription)"
      issuePoints = []
      prPoints = []
    }
  }

  private func makeItem(created: String?, closed: String?) -> RepoTrendItem? {
    guard let createdDate = parseDate(created) else { return nil }
    let closedDate = parseDate(closed)
    return RepoTrendItem(createdAt: createdDate, closedAt: closedDate)
  }

  private func openCount(items: [RepoTrendItem], weekStart: Date) -> Int {
    guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return 0 }
    return items.reduce(0) { total, item in
      guard item.createdAt <= weekEnd else { return total }
      if let closed = item.closedAt, closed <= weekEnd {
        return total
      }
      return total + 1
    }
  }

  private var chartWeekStarts: [Date] {
    let now = Date()
    let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
    let start = calendar.date(byAdding: .weekOfYear, value: -(chartWeeks - 1), to: currentWeekStart) ?? currentWeekStart
    return (0..<chartWeeks).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: start) }
  }

  private func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    if let parsed = Self.isoFormatter.date(from: value) {
      return parsed
    }
    return Self.fallbackFormatter.date(from: value)
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
