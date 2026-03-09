//
//  RepoDetailActivityTabView.swift
//  Peel
//

import SwiftUI

// MARK: - Activity Tab

struct ActivityTabView: View {
  let repo: UnifiedRepository
  @Environment(ActivityFeed.self) private var activityFeed
  @State private var selectedItem: ActivityItem?
  @State private var filterMode: RepoActivityFilter = .all

  var body: some View {
    let repoItems = filteredItems

    Group {
      if activityFeed.items(for: repo.normalizedRemoteURL).isEmpty {
        ContentUnavailableView {
          Label("No Activity", systemImage: "clock")
        } description: {
          Text("No recent activity for this repository.")
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            // Filter bar
            HStack {
              SectionHeader("Activity")
              Spacer()
              Picker("Filter", selection: $filterMode) {
                ForEach(RepoActivityFilter.allCases, id: \.self) { mode in
                  Text(mode.rawValue).tag(mode)
                }
              }
              .pickerStyle(.segmented)
              .frame(maxWidth: 280)
            }

            if repoItems.isEmpty {
              ContentUnavailableView {
                Label("No Matching Activity", systemImage: "line.3.horizontal.decrease.circle")
              } description: {
                Text("No \(filterMode.rawValue.lowercased()) activity for this repository.")
              }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
          } else {
            // Grouped by day
            let grouped = groupedByDay(repoItems)
            ForEach(grouped, id: \.date) { group in
              VStack(alignment: .leading, spacing: 4) {
                Text(group.label)
                  .font(.caption)
                  .fontWeight(.medium)
                  .foregroundStyle(.secondary)
                  .padding(.top, 4)

                LazyVStack(spacing: 1) {
                  ForEach(group.items) { item in
                    RepoActivityItemRow(item: item)
                      .contentShape(Rectangle())
                      .onTapGesture { selectedItem = item }
                  }
                }
                #if os(macOS)
                .background(Color(nsColor: .controlBackgroundColor))
                #else
                .background(Color(.systemGroupedBackground))
                #endif
                .clipShape(RoundedRectangle(cornerRadius: 8))
              }
            }
          }
        }
        .padding(16)
      }
      #if os(macOS)
      .sheet(item: $selectedItem) { item in
        ActivityItemDetailSheet(item: item)
      }
      #endif
    }
    }
    .task(id: repo.normalizedRemoteURL) {
      activityFeed.rebuild()
    }
  }

  private var filteredItems: [ActivityItem] {
    let all = activityFeed.items(for: repo.normalizedRemoteURL)
    switch filterMode {
    case .all: return all
    case .chains:
      return all.filter { item in
        switch item.kind {
        case .chainStarted, .chainCompleted: return true
        default: return false
        }
      }
    case .pulls:
      return all.filter { item in
        if case .pullCompleted = item.kind { return true }
        return false
      }
    case .errors:
      return all.filter(\.isError)
    }
  }

  private struct DayGroup {
    let date: Date
    let label: String
    let items: [ActivityItem]
  }

  private func groupedByDay(_ items: [ActivityItem]) -> [DayGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: items) { item in
      calendar.startOfDay(for: item.timestamp)
    }

    return grouped.keys.sorted(by: >).map { date in
      let label: String
      if calendar.isDateInToday(date) {
        label = "Today"
      } else if calendar.isDateInYesterday(date) {
        label = "Yesterday"
      } else {
        label = date.formatted(.dateTime.month(.wide).day().year())
      }
      return DayGroup(date: date, label: label, items: grouped[date]!.sorted { $0.timestamp > $1.timestamp })
    }
  }
}

enum RepoActivityFilter: String, CaseIterable {
  case all = "All"
  case chains = "Chains"
  case pulls = "Pulls"
  case errors = "Errors"
}
