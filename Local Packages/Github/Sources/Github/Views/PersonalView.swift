//
//  PersonalView.swift
//  
//
//  Created by Cory Loken on 12/12/21.
//  Modernized to @Observable on 1/5/26
//  Updated for loading states on 1/7/26
//

import Charts
import SwiftUI

public struct PersonalHeaderView: View {
  @Binding var showingMyRequests: Bool
  
  public var body: some View {
    HStack {
      Spacer()
      
      Picker("Filter", selection: $showingMyRequests) {
        Text("All").tag(false)
        Text("My Requests").tag(true)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 200)
    }
  }
}

public struct PersonalView: View {
  @Environment(Github.ViewModel.self) private var viewModel
  @State private var allPullRequests = [Github.PullRequest]()
  @State private var filteredPullRequests = [Github.PullRequest]()
  @State private var showingMyRequests = false
  @State private var isLoading = true
  @State private var loadingProgress = ""
  
  let organizations: [Github.User]
  
  public init(organizations: [Github.User]) {
    self.organizations = organizations
  }
  
  public var body: some View {
    NavigationStack {
      VStack {
        PersonalHeaderView(
          showingMyRequests: $showingMyRequests
        )
        .padding(.horizontal)
        
        if isLoading {
          VStack(spacing: 12) {
            ProgressView()
            Text(loadingProgress)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if allPullRequests.isEmpty {
          ContentUnavailableView(
            "No Pull Requests",
            systemImage: "arrow.triangle.pull",
            description: Text("No pull requests found")
          )
        } else {
          List {
            Section {
              PRInsightsChartsView(pullRequests: allPullRequests)
            }
            if filteredPullRequests.isEmpty {
              Section {
                ContentUnavailableView(
                  "No Pull Requests",
                  systemImage: "arrow.triangle.pull",
                  description: Text(showingMyRequests ? "No pull requests assigned to you" : "No pull requests found")
                )
              }
            } else {
              Section {
                ForEach(filteredPullRequests.sorted(by: { $0.updated_at ?? "" > $1.updated_at ?? ""})) { pullRequest in
                  VStack {
                    NavigationLink(destination: PullRequestDetailView(organization: pullRequest.base.repo.owner, repository: pullRequest.base.repo, pullRequest: pullRequest)) {
                      PullRequestsListItemView(pullRequest: pullRequest, organization: pullRequest.base.repo.owner, repository: pullRequest.base.repo, showAvatar: true, showRepository: true)
                    }
                    #if os(macOS)
                    Divider()
                    #endif
                  }
                }
              }
            }
          }
        }
      }
      .navigationTitle("Pull Requests")
    }
    .task {
      await loadPullRequests()
    }
    .onChange(of: showingMyRequests) { _, _ in
      withAnimation {
        applyFilters()
      }
    }
  }
  
  private func loadPullRequests() async {
    isLoading = true
    var newPRs = [Github.PullRequest]()
    
    for organization in organizations {
      loadingProgress = "Loading \(organization.login ?? "organization")..."
      
      do {
        let repositories = try await Github.loadRepositories(organization: organization.login ?? "")
        
        for repository in repositories {
          loadingProgress = "Checking \(repository.name)..."
          do {
            let requests = try await Github.pullRequests(from: repository, state: "all")
            newPRs.append(contentsOf: requests)
          } catch {
            // Continue loading other repositories even if one fails
            continue
          }
        }
      } catch {
        // Continue loading other orgs even if one fails
        continue
      }
    }
    
    allPullRequests = newPRs
    applyFilters()
    isLoading = false
    loadingProgress = ""
  }

  private func applyFilters() {
    if showingMyRequests {
      filteredPullRequests = allPullRequests.filter { viewModel.hasMe(in: $0.requested_reviewers ?? []) }
    } else {
      filteredPullRequests = allPullRequests
    }
  }
}

private struct PRInsightsChartsView: View {
  let pullRequests: [Github.PullRequest]

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let fallbackFormatter = ISO8601DateFormatter()

  private let calendar = Calendar.current
  private let chartWeeks = 12

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text("PR Throughput (Last 12 Weeks)")
            .font(.headline)
          if throughputPoints.allSatisfy({ $0.count == 0 }) {
            Text("No PR throughput data yet")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Chart(throughputPoints) { point in
              BarMark(
                x: .value("Week", point.weekStart, unit: .weekOfYear),
                y: .value("Count", point.count)
              )
              .foregroundStyle(by: .value("Series", point.series))
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
          Text("Median Time to Merge (Days)")
            .font(.headline)
          if cycleTimePoints.isEmpty {
            Text("No merged PRs in the last 12 weeks")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Chart(cycleTimePoints) { point in
              LineMark(
                x: .value("Week", point.weekStart, unit: .weekOfYear),
                y: .value("Median Days", point.medianDays)
              )
              .foregroundStyle(.orange)
              PointMark(
                x: .value("Week", point.weekStart, unit: .weekOfYear),
                y: .value("Median Days", point.medianDays)
              )
              .foregroundStyle(.orange)
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
    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
  }

  private var throughputPoints: [PRThroughputPoint] {
    let weeks = chartWeekStarts
    var openedByWeek = Dictionary(uniqueKeysWithValues: weeks.map { ($0, 0) })
    var mergedByWeek = Dictionary(uniqueKeysWithValues: weeks.map { ($0, 0) })

    for pr in pullRequests {
      if let created = parseDate(pr.created_at) {
        let week = weekStart(for: created)
        if openedByWeek[week] != nil {
          openedByWeek[week, default: 0] += 1
        }
      }
      if let merged = parseDate(pr.merged_at) {
        let week = weekStart(for: merged)
        if mergedByWeek[week] != nil {
          mergedByWeek[week, default: 0] += 1
        }
      }
    }

    return weeks.flatMap { week in
      [
        PRThroughputPoint(weekStart: week, series: "Opened", count: openedByWeek[week] ?? 0),
        PRThroughputPoint(weekStart: week, series: "Merged", count: mergedByWeek[week] ?? 0)
      ]
    }
  }

  private var cycleTimePoints: [PRCycleTimePoint] {
    guard let start = chartWeekStarts.first else { return [] }
    var durationsByWeek: [Date: [Double]] = [:]

    for pr in pullRequests {
      guard let created = parseDate(pr.created_at),
            let merged = parseDate(pr.merged_at) else { continue }
      guard merged >= start else { continue }
      let week = weekStart(for: merged)
      let hours = merged.timeIntervalSince(created) / 3600
      durationsByWeek[week, default: []].append(hours)
    }

    return durationsByWeek.keys.sorted().compactMap { week in
      guard let values = durationsByWeek[week], !values.isEmpty else { return nil }
      let medianHours = median(values)
      return PRCycleTimePoint(weekStart: week, medianDays: medianHours / 24)
    }
  }

  private var chartWeekStarts: [Date] {
    let now = Date()
    let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
    let start = calendar.date(byAdding: .weekOfYear, value: -(chartWeeks - 1), to: currentWeekStart) ?? currentWeekStart
    return (0..<chartWeeks).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: start) }
  }

  private func weekStart(for date: Date) -> Date {
    calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
  }

  private func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    if let parsed = Self.isoFormatter.date(from: value) {
      return parsed
    }
    return Self.fallbackFormatter.date(from: value)
  }

  private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    if sorted.count % 2 == 1 {
      return sorted[sorted.count / 2]
    }
    let upper = sorted.count / 2
    return (sorted[upper - 1] + sorted[upper]) / 2
  }
}

private struct PRThroughputPoint: Identifiable {
  let id = UUID()
  let weekStart: Date
  let series: String
  let count: Int
}

private struct PRCycleTimePoint: Identifiable {
  let id = UUID()
  let weekStart: Date
  let medianDays: Double
}
