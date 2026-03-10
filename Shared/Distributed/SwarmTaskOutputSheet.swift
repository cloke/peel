// SwarmTaskOutputSheet.swift
// Peel
//
// Created by Copilot on 2026-03-10.
// Sheet view for inspecting a completed swarm task's full output.

import SwiftUI

struct SwarmTaskOutputSheet: View {
  let result: ChainResult
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Summary") {
          LabeledContent("Status") {
            Text(result.status.rawValue.capitalized)
              .foregroundStyle(statusColor)
              .fontWeight(.medium)
          }
          LabeledContent("Duration") {
            Text(String(format: "%.1fs", result.duration))
          }
          LabeledContent("Worker") {
            Text(result.workerDeviceName)
          }
          LabeledContent("Branch") {
            Text(result.branchName ?? "—")
              .foregroundStyle(result.branchName == nil ? .secondary : .primary)
          }
          if let error = result.errorMessage {
            LabeledContent("Error") {
              Text(error)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            }
          }
        }

        if !result.outputs.isEmpty {
          Section("Outputs") {
            ForEach(result.outputs, id: \.name) { output in
              DisclosureGroup {
                Text(output.content ?? "(empty)")
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.vertical, 4)
              } label: {
                HStack {
                  Image(systemName: outputIcon(for: output.type))
                    .foregroundStyle(.secondary)
                  Text(output.name)
                    .font(.subheadline)
                  Spacer()
                  if let content = output.content {
                    Text("\(content.count) chars")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        } else {
          Section("Outputs") {
            Text("No outputs recorded")
              .foregroundStyle(.secondary)
              .font(.caption)
          }
        }
      }
      .navigationTitle("Task \(result.requestId.uuidString.prefix(8))")
      #if os(macOS)
      .frame(minWidth: 480, minHeight: 400)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var statusColor: Color {
    switch result.status {
    case .completed: return .green
    case .failed, .timedOut: return .red
    case .cancelled: return .orange
    default: return .secondary
    }
  }

  private func outputIcon(for type: ChainOutput.OutputType) -> String {
    switch type {
    case .text: return "doc.text"
    case .file: return "doc"
    case .diff: return "arrow.left.arrow.right"
    case .log: return "terminal"
    }
  }
}
