//
//  ActionListView.swift
//  SwiftUIView
//
//  Created by Cory Loken on 8/1/21.
//

import Charts
import SwiftUI
import PeelUI

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
  let repository: Github.Repository
  
  var body: some View {
    AsyncContentView(
      load: { try await loadActionsData(for: repository) },
      isEmpty: { $0.actions.isEmpty },
      content: { data in
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ReliabilityChart(points: data.reliabilityPoints)
            FailuresChart(points: data.failurePoints)
            ActionsListView(repository: repository, actions: data.actions)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
      },
      loadingView: { ProgressView() },
      emptyView: { EmptyStateView("No Actions", systemImage: "gearshape.2") }
    )
    .id(repository.id)
  }
}

// MARK: - Data Loading

private struct ActionsData {
  let actions: [Github.Action]
  let reliabilityPoints: [ActionReliabilityPoint]
  let failurePoints: [ActionFailurePoint]
}

private func loadActionsData(for repository: Github.Repository) async throws -> ActionsData {
  let workflows = try await Github.workflows(from: repository)
  
  // Load all workflow runs in parallel
  let allActions = try await withThrowingTaskGroup(of: [Github.Action].self) { group in
    for workflow in workflows {
      group.addTask {
        try await Github.runs(from: workflow, repository: repository)
      }
    }
    var results = [Github.Action]()
    for try await actions in group {
      results.append(contentsOf: actions)
    }
    return results
  }
  
  let calendar = Calendar.current
  let weeks = chartWeekStarts(calendar: calendar)
  
  // Calculate reliability
  var totals = Dictionary(uniqueKeysWithValues: weeks.map { ($0, 0) })
  var successes = Dictionary(uniqueKeysWithValues: weeks.map { ($0, 0) })
  
  for action in allActions {
    guard let created = GithubDateParser.parse(action.created_at) else { continue }
    let week = calendar.dateInterval(of: .weekOfYear, for: created)?.start ?? created
    guard totals[week] != nil, let conclusion = action.conclusion else { continue }
    totals[week, default: 0] += 1
    if conclusion == "success" { successes[week, default: 0] += 1 }
  }
  
  let reliabilityPoints = weeks.map { week in
    let total = totals[week] ?? 0
    let success = successes[week] ?? 0
    let rate = total == 0 ? 0 : (Double(success) / Double(total)) * 100
    return ActionReliabilityPoint(weekStart: week, successRate: rate)
  }
  
  // Calculate failures by workflow
  var failures: [String: Int] = [:]
  for action in allActions where action.conclusion == "failure" {
    failures[action.name, default: 0] += 1
  }
  let failurePoints = failures
    .sorted { $0.value > $1.value }
    .prefix(8)
    .map { ActionFailurePoint(workflow: $0.key, count: $0.value) }
  
  return ActionsData(actions: allActions, reliabilityPoints: reliabilityPoints, failurePoints: failurePoints)
}

// chartWeekStarts() and parseDate() moved to Date+Formatting.swift

// MARK: - Charts

private struct ReliabilityChart: View {
  let points: [ActionReliabilityPoint]
  
  var body: some View {
    SectionCard("Actions Reliability (Last 12 Weeks)") {
      if points.isEmpty {
        Text("No reliability data yet").font(.caption).foregroundStyle(.secondary)
      } else {
        Chart(points) { point in
          LineMark(x: .value("Week", point.weekStart, unit: .weekOfYear), y: .value("Success %", point.successRate))
            .foregroundStyle(.green)
          PointMark(x: .value("Week", point.weekStart, unit: .weekOfYear), y: .value("Success %", point.successRate))
            .foregroundStyle(.green)
        }
        .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) }
        .chartYScale(domain: 0...100)
        .frame(height: 160)
      }
    }
  }
}

private struct FailuresChart: View {
  let points: [ActionFailurePoint]
  
  var body: some View {
    SectionCard("Failures by Workflow") {
      if points.isEmpty {
        Text("No failures recorded").font(.caption).foregroundStyle(.secondary)
      } else {
        Chart(points) { point in
          BarMark(x: .value("Workflow", point.workflow), y: .value("Failures", point.count))
            .foregroundStyle(.red)
        }
        .frame(height: 160)
      }
    }
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

// MARK: - List Views

struct ActionsListItemView: View {
  let action: Github.Action
  
  var body: some View {
    VStack(alignment: .leading) {
      HStack(alignment: .top) {
        if action.status == "in_progress" {
          ProgressView().scaleEffect(0.5)
        } else {
          ActionConclusionView(conclusion: action.conclusion ?? "")
        }
        Text("#\(action.run_number)")
        Text(action.updatedAtFormatted).font(.subheadline)
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
      NavigationLink(destination: ActionDetailView(action: action)) {
        ActionsListItemView(action: action)
      }
    }
  }
}

