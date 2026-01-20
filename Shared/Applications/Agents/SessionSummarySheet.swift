//
//  SessionSummarySheet.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

struct SessionSummarySheet: View {
  @Bindable var sessionTracker: SessionTracker
  @Environment(\.dismiss) private var dismiss
  @State private var showingExportSuccess = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Session stats
          HStack(spacing: 24) {
            StatCard(
              title: "Premium Requests",
              value: sessionTracker.totalPremiumUsed.premiumMultiplierString(),
              icon: "star.fill",
              color: .orange
            )
            StatCard(
              title: "Session Duration",
              value: sessionTracker.sessionDuration,
              icon: "clock.fill",
              color: .blue
            )
            StatCard(
              title: "Chain Runs",
              value: "\(sessionTracker.chainRunHistory.count)",
              icon: "link",
              color: .purple
            )
          }
          .padding(.horizontal)

          Divider()

          // Chain run history
          if sessionTracker.chainRunHistory.isEmpty {
            ContentUnavailableView(
              "No Runs Yet",
              systemImage: "tray",
              description: Text("Run a chain to see results here")
            )
          } else {
            VStack(alignment: .leading, spacing: 12) {
              Text("Run History")
                .font(.headline)
                .padding(.horizontal)

              ForEach(sessionTracker.chainRunHistory) { record in
                GroupBox {
                  VStack(alignment: .leading, spacing: 8) {
                    HStack {
                      Text(record.chainName)
                        .font(.headline)
                      Spacer()
                      Text(record.totalPremium.premiumCostDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Text(record.timestamp, style: .time)
                      .font(.caption)
                      .foregroundStyle(.secondary)

                    // Agent summaries
                    ForEach(record.results) { result in
                      HStack {
                        Image(systemName: "checkmark.circle.fill")
                          .foregroundStyle(.green)
                          .font(.caption)
                        Text(result.agentName)
                          .font(.caption)
                        Text("(\(result.model))")
                          .font(.caption2)
                          .foregroundStyle(.secondary)
                        Spacer()
                        if let duration = result.duration {
                          Text(duration)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                      }
                    }
                  }
                }
                .padding(.horizontal)
              }
            }
          }
        }
        .padding(.vertical)
      }
      .navigationTitle("Session Summary")
      #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
          .accessibilityIdentifier("agents.sessionSummary.done")
        }

        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button {
              exportMarkdown()
            } label: {
              Label("Export as Markdown", systemImage: "doc.text")
            }
            .accessibilityIdentifier("agents.sessionSummary.export")

            Button(role: .destructive) {
              sessionTracker.resetSession()
            } label: {
              Label("Reset Session", systemImage: "trash")
            }
            .accessibilityIdentifier("agents.sessionSummary.reset")
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityIdentifier("agents.sessionSummary.menu")
        }
      }
      #endif
      .frame(minWidth: 500, minHeight: 400)
      .alert("Exported", isPresented: $showingExportSuccess) {
        Button("OK", role: .cancel) { }
      } message: {
        Text("Session report saved to Desktop")
      }
    }
  }

  #if os(macOS)
  private func exportMarkdown() {
    let markdown = sessionTracker.exportAsMarkdown()
    guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
      print("Could not access desktop directory")
      return
    }
    let filename = "agent_session_\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).md"
      .replacingOccurrences(of: ":", with: "-")
    let fileURL = desktopURL.appendingPathComponent(filename)

    do {
      try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
      showingExportSuccess = true
    } catch {
      print("Failed to export: \(error)")
    }
  }
  #endif
}

private struct StatCard: View {
  let title: String
  let value: String
  let icon: String
  let color: Color

  var body: some View {
    GroupBox {
      VStack(spacing: 8) {
        Image(systemName: icon)
          .font(.title2)
          .foregroundStyle(color)
        Text(value)
          .font(.title)
          .fontWeight(.bold)
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
    }
  }
}
