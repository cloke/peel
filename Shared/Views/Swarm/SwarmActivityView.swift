//
//  SwarmActivityView.swift
//  Peel
//
//  Activity log and event row views for swarm activity tracking
//

import SwiftUI

// MARK: - Activity Log View

struct ActivityLogView: View {
  @State private var firebaseService = FirebaseService.shared
  @State private var filterType: SwarmActivityType?

  var filteredEvents: [SwarmActivityEvent] {
    if let filter = filterType {
      return firebaseService.activityLog.filter { $0.type == filter }
    }
    return firebaseService.activityLog
  }

  var body: some View {
    VStack(spacing: 0) {
      // Filter bar
      HStack {
        Text("\(filteredEvents.count) events")
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Picker("Filter", selection: $filterType) {
          Text("All Events").tag(nil as SwarmActivityType?)
          Divider()
          Text("🟢 Workers").tag(SwarmActivityType.workerOnline as SwarmActivityType?)
          Text("📤 Tasks").tag(SwarmActivityType.taskSubmitted as SwarmActivityType?)
          Text("⚠️ Errors").tag(SwarmActivityType.error as SwarmActivityType?)
        }
        .pickerStyle(.menu)
        .frame(width: 140)

        Button {
          // Clear log
          firebaseService.clearActivityLog()
        } label: {
          Label("Clear", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .disabled(firebaseService.activityLog.isEmpty)
      }
      .padding(.horizontal)
      .padding(.vertical, 8)

      Divider()

      if filteredEvents.isEmpty {
        ContentUnavailableView(
          "No Activity",
          systemImage: "chart.line.flattrend.xyaxis",
          description: Text("Swarm events like worker registration, tasks, and messages will appear here.")
        )
      } else {
        List(filteredEvents) { event in
          ActivityEventRow(event: event)
        }
        .listStyle(.plain)
      }
    }
  }
}

// MARK: - Activity Event Row

struct ActivityEventRow: View {
  let event: SwarmActivityEvent
  @State private var showingDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top) {
        Text(event.type.emoji)
          .font(.title3)

        VStack(alignment: .leading, spacing: 2) {
          Text(event.message)
            .fontWeight(.medium)

          Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if event.details != nil {
          Button {
            showingDetails.toggle()
          } label: {
            Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
        }
      }

      // Details disclosure
      if showingDetails, let details = event.details {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(details.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
            HStack(alignment: .top) {
              Text(key + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

              Text(value)
                .font(.caption)
                .textSelection(.enabled)
            }
          }
        }
        .padding(.leading, 32)
        .padding(.top, 4)
      }
    }
    .padding(.vertical, 4)
  }
}
