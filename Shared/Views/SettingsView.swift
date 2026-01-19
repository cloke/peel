//
//  SettingsView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

struct SettingsView: View {
  #if os(macOS)
  @Environment(MCPServerService.self) private var mcpServer
  #endif
  
  var body: some View {
    Form {
      #if os(macOS)
      Section("MCP Test Harness") {
        Toggle(
          "Enable MCP Server",
          isOn: Binding(
            get: { mcpServer.isEnabled },
            set: { mcpServer.isEnabled = $0 }
          )
        )

        Toggle(
          "Auto-clean agent worktrees",
          isOn: Binding(
            get: { mcpServer.autoCleanupWorkspaces },
            set: { mcpServer.autoCleanupWorkspaces = $0 }
          )
        )
        Text("Remove agent worktrees after MCP runs complete.")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack {
          Text("Port")
          TextField(
            "Port",
            text: Binding(
              get: { String(mcpServer.port) },
              set: { newValue in
                if let value = Int(newValue) {
                  mcpServer.port = value
                }
              }
            )
          )
          .frame(width: 80)
        }

        Text(mcpServer.isRunning ? "Running on localhost:\(mcpServer.port)" : "Stopped")
          .font(.caption)
          .foregroundStyle(mcpServer.isRunning ? .green : .secondary)

        Text("Active requests: \(mcpServer.activeRequests)")
          .font(.caption)
          .foregroundStyle(.secondary)

        if let method = mcpServer.lastRequestMethod,
           let timestamp = mcpServer.lastRequestAt {
          Text("Last request: \(method) at \(timestamp.formatted(date: .omitted, time: .shortened))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let error = mcpServer.lastError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      #endif

      Section("About") {
        Text("Work in progress. If this tool helps you, donations help move it along.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Link("GitHub: crunchybananas", destination: URL(string: "https://github.com/crunchybananas")!)
      }
    }
    .padding()
    .frame(minWidth: 400, minHeight: 400)
  }
}

#Preview {
  SettingsView()
}
