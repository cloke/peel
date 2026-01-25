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
    TabView {
      #if os(macOS)
      ScrollView {
        Form {
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

            Text("Foreground tools: \(mcpServer.foregroundToolCount) · Background tools: \(mcpServer.backgroundToolCount)")
              .font(.caption)
              .foregroundStyle(.secondary)

            Text("App active: \(mcpServer.isAppActive ? "Yes" : "No") · Frontmost: \(mcpServer.isAppFrontmost ? "Yes" : "No")")
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

          Section("MCP Tools") {
            MCPToolSettingsSection(mcpServer: mcpServer)
          }
        }
        .padding()
      }
      .tabItem { Label("Local MCP", systemImage: "bolt.horizontal.circle") }
      #endif

      ScrollView {
        Form {
          Section("About") {
            VStack(alignment: .leading, spacing: 8) {
              Text("Peel keeps GitHub, git, and Homebrew close at hand so you can stay in flow.")
                .font(.callout)
              Text("If this app saves you time, please consider supporting development.")
                .font(.caption)
                .foregroundStyle(.secondary)
              HStack(spacing: 12) {
                Link("GitHub", destination: URL(string: "https://github.com/cloke/peel")!)
                Link("Donate", destination: URL(string: "https://github.com/sponsors/crunchybananas")!)
              }
              .font(.caption)
            }
          }
        }
        .padding()
      }
      .tabItem { Label("About", systemImage: "info.circle") }
    }
    .frame(minWidth: 400, minHeight: 400)
  }
}

#if os(macOS)
private struct MCPToolSettingsSection: View {
  private enum ToolPreset: String, CaseIterable, Identifiable {
    case yolo
    case paranoid
    case voyeur

    var id: String { rawValue }

    var label: String {
      switch self {
      case .yolo: return "YOLO"
      case .paranoid: return "Paranoid"
      case .voyeur: return "Voyeur"
      }
    }
  }

  @Bindable var mcpServer: MCPServerService
  @State private var selectedPreset: ToolPreset = .yolo

  var body: some View {
    let _ = mcpServer.permissionsVersion
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Presets")
          .font(.headline)
        Picker("Tool Preset", selection: $selectedPreset) {
          ForEach(ToolPreset.allCases) { preset in
            Text(preset.label).tag(preset)
          }
        }
        .pickerStyle(.segmented)
        .onChange(of: selectedPreset) { _, newValue in
          applyPreset(newValue)
        }
        Text("YOLO: enable all tools. Paranoid: read-only. Voyeur: screenshots + read-only.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 12) {
        Button("Enable All") {
          mcpServer.setAllToolsEnabled(true)
        }
        Button("Disable All") {
          mcpServer.setAllToolsEnabled(false)
        }
      }
      .buttonStyle(.bordered)

      VStack(alignment: .leading, spacing: 6) {
        Text("Tool Groups")
          .font(.headline)
        ForEach(mcpServer.toolGroups, id: \.self) { group in
          HStack {
            Toggle(
              group.displayName,
              isOn: Binding(
                get: { mcpServer.isGroupEnabled(group) },
                set: { mcpServer.setGroupEnabled(group, enabled: $0) }
              )
            )
            .help("Enable or disable all tools in the \(group.displayName) group.")
            Spacer()
            Text("\(mcpServer.enabledToolCount(in: group))/\(mcpServer.toolCount(in: group)) enabled")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Divider()

      ForEach(mcpServer.toolCategories, id: \.self) { category in
        VStack(alignment: .leading, spacing: 6) {

  private func applyPreset(_ preset: ToolPreset) {
    switch preset {
    case .yolo:
      mcpServer.setAllToolsEnabled(true)
    case .paranoid:
      mcpServer.setAllToolsEnabled(false)
      mcpServer.setGroupEnabled(.backgroundSafe, enabled: true)
    case .voyeur:
      mcpServer.setAllToolsEnabled(false)
      mcpServer.setGroupEnabled(.backgroundSafe, enabled: true)
      mcpServer.setGroupEnabled(.screenshots, enabled: true)
    }
  }
          HStack {
            Toggle(
              category.displayName,
              isOn: Binding(
                get: { mcpServer.isCategoryEnabled(category) },
                set: { mcpServer.setCategoryEnabled(category, enabled: $0) }
              )
            )
            .help("Enable or disable all tools in the \(category.displayName) category.")
            Spacer()
            Text("\(mcpServer.enabledToolCount(in: category))/\(mcpServer.toolCount(in: category)) enabled")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          ForEach(mcpServer.tools(in: category)) { tool in
            VStack(alignment: .leading, spacing: 2) {
              let mutatingLabel = tool.isMutating ? "Mutating" : "Read-only"
              let foregroundLabel = tool.requiresForeground ? "Foreground required" : "Background-safe"
              Toggle(
                tool.name,
                isOn: Binding(
                  get: { mcpServer.isToolEnabled(tool.name) },
                  set: { mcpServer.setToolEnabled(tool.name, enabled: $0) }
                )
              )
              .padding(.leading, 16)
              .help("\(tool.description)\n\(mutatingLabel) · \(foregroundLabel)")
              Text(tool.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 36)
              Text("\(mutatingLabel) · \(foregroundLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 36)
            }
          }
        }
        .padding(.vertical, 6)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("UI Control Reference")
          .font(.headline)
        Text("Use these control IDs with MCP UI tools (navigate/tap/select).")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(mcpServer.uiControlDocs) { doc in
          DisclosureGroup(doc.title) {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(doc.controls) { control in
                VStack(alignment: .leading, spacing: 2) {
                  Text(control.controlId)
                    .font(.caption)
                  if !control.values.isEmpty {
                    Text(control.values.joined(separator: ", "))
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(3)
                  }
                }
              }
            }
            .padding(.leading, 8)
          }
        }
      }
    }
  }
}
#endif

#Preview {
  SettingsView()
}
