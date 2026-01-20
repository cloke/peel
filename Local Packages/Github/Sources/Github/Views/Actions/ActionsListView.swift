//
//  ActionListView.swift
//  SwiftUIView
//
//  Created by Cory Loken on 8/1/21.
//

import Charts
import SwiftUI

public struct ActionConclusionView: View {
  let conclusion: String
  
  public init(conclusion: String) {
    self.conclusion = conclusion
  }
  
  public var body: some View {
    Group {
      switch conclusion {
      case "success":
        Image(systemName: "checkmark.circle")
          .foregroundColor(.green)
      case "failure":
        Image(systemName: "xmark.circle")
          .foregroundColor(.red)
      case "cancelled":
        Image(systemName: "nosign")
          .foregroundColor(.yellow)
      default:
        Image(systemName: "questionmark.circle")
      }
    }
    .help(conclusion)
  }
}

struct ActionsView: View {
  public let repository: Github.Repository
  
  @State private var isLoading = true
  @State private var actions = [Github.Action]()
  private let calendar = Calendar.current
  private let chartWeeks = 12

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let fallbackFormatter = ISO8601DateFormatter()
  
  var body: some View {
    VStack {
      if isLoading {
        ProgressView()
      } else if !actions.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            GroupBox {
              VStack(alignment: .leading, spacing: 8) {
                Text("Actions Reliability (Last 12 Weeks)")
                  .font(.headline)
                if reliabilityPoints.isEmpty {
                  Text("No reliability data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                  Chart(reliabilityPoints) { point in
                    LineMark(
                      x: .value("Week", point.weekStart, unit: .weekOfYear),
                      y: .value("Success %", point.successRate)
                    )
                    .foregroundStyle(.green)
                    PointMark(
                      x: .value("Week", point.weekStart, unit: .weekOfYear),
                      y: .value("Success %", point.successRate)
                    )
                    .foregroundStyle(.green)
                  }
                  .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2))
                  }
                  .chartYScale(domain: 0...100)
                  .frame(height: 160)
                }
              }
              .padding(.vertical, 4)
            }

            GroupBox {
              VStack(alignment: .leading, spacing: 8) {
                Text("Failures by Workflow")
                  .font(.headline)
                if failurePoints.isEmpty {
                  Text("No failures recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                  Chart(failurePoints) { point in
                    BarMark(
                      x: .value("Workflow", point.workflow),
                      y: .value("Failures", point.count)
                    )
                    .foregroundStyle(.red)
                  }
                  .frame(height: 160)
                }
              }
              .padding(.vertical, 4)
            }

            ActionsListView(repository: repository, actions: actions)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
      } else {
        Text("No Actions Found")
      }
    }
    .task(id: repository.id) {
      isLoading = true
      actions = []
      do {
        for workflow in try await Github.workflows(from: repository) {
          let actions = try await Github.runs(from: workflow, repository: repository)
          self.actions.append(contentsOf: actions)
        }
      } catch {
        print(error)
      }
      isLoading = false
    }
  }

  private var reliabilityPoints: [ActionReliabilityPoint] {
    let weeks = chartWeekStarts
    var totals = Dictionary(uniqueKeysWithValues: weeks.map { ($0, 0) })
    var successes = Dictionary(uniqueKeysWithValues: weeks.map { ($0, 0) })

    for action in actions {
      guard let created = parseDate(action.created_at) else { continue }
      let week = weekStart(for: created)
      guard totals[week] != nil else { continue }
      guard let conclusion = action.conclusion else { continue }
      totals[week, default: 0] += 1
      if conclusion == "success" {
        successes[week, default: 0] += 1
      }
    }

    return weeks.map { week in
      let total = totals[week] ?? 0
      let success = successes[week] ?? 0
      let rate = total == 0 ? 0 : (Double(success) / Double(total)) * 100
      return ActionReliabilityPoint(weekStart: week, successRate: rate)
    }
  }

  private var failurePoints: [ActionFailurePoint] {
    var failures: [String: Int] = [:]
    for action in actions {
      guard action.conclusion == "failure" else { continue }
      failures[action.name, default: 0] += 1
    }
    return failures
      .sorted { $0.value > $1.value }
      .prefix(8)
      .map { ActionFailurePoint(workflow: $0.key, count: $0.value) }
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

  private func parseDate(_ value: String) -> Date? {
    if let parsed = Self.isoFormatter.date(from: value) {
      return parsed
    }
    return Self.fallbackFormatter.date(from: value)
  }
}

private struct ActionReliabilityPoint: Identifiable {
  let id = UUID()
  let weekStart: Date
  let successRate: Double
}

private struct ActionFailurePoint: Identifiable {
  let id = UUID()
  let workflow: String
  let count: Int
}

struct ActionsListItemView: View {
  let action: Github.Action
  
  public var body: some View {
    VStack(alignment: .leading) {
      HStack(alignment: .top) {
        if action.status == "in_progress" {
          ProgressView()
            .scaleEffect(0.5)
        } else {
          ActionConclusionView(conclusion: action.conclusion ?? "")
        }
        Text("#\(action.run_number)")
        Text(action.updatedAtFormatted)
          .font(.subheadline)
      }
      Text(action.head_commit.message.components(separatedBy: "\n\n").first ?? "")
      Spacer()
      
      HStack {
        Text(action.repository.name)
        Text(action.name)
        Spacer()
      }
    }
  }
}

struct ActionsListView: View {
  let repository: Github.Repository
  let actions: [Github.Action]
  
  var body: some View {
    List(actions.sorted(by: { $0.updated_at > $1.updated_at })) { action in
      VStack {
        NavigationLink(destination: ActionDetailView(action: action)) {
          ActionsListItemView(action: action)
        }
        Divider()
      }
    }
  }
}

//struct ActionsListView_Previews: PreviewProvider {
//  static var previews: some View {
////    ActionsListView()
//  }
//}

