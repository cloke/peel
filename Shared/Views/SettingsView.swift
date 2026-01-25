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

          Section("Local RAG") {
            Toggle(
              "Enable Local RAG",
              isOn: Binding(
                get: { mcpServer.localRagEnabled },
                set: { mcpServer.localRagEnabled = $0 }
              )
            )
            Text("Use local codebase indexing to provide context to agents.")
              .font(.caption)
              .foregroundStyle(.secondary)

            if mcpServer.localRagEnabled {
              Toggle(
                "Use Core ML embeddings",
                isOn: Binding(
                  get: { mcpServer.localRagUseCoreML },
                  set: { mcpServer.localRagUseCoreML = $0 }
                )
              )
              Text("Requires local Core ML model setup. Falls back to text search if unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)

              Picker("Default search mode", selection: Binding(
                get: { mcpServer.localRagSearchMode },
                set: { mcpServer.localRagSearchMode = $0 }
              )) {
                Text("Text").tag(MCPServerService.RAGSearchMode.text)
                Text("Vector").tag(MCPServerService.RAGSearchMode.vector)
              }
              .pickerStyle(.segmented)

              Stepper(
                "Search limit: \(mcpServer.localRagSearchLimit)",
                value: Binding(
                  get: { mcpServer.localRagSearchLimit },
                  set: { mcpServer.localRagSearchLimit = $0 }
                ),
                in: 1...20
              )

              if let status = mcpServer.ragStatus {
                VStack(alignment: .leading, spacing: 4) {
                  Text("DB: \(status.exists ? "Ready" : "Not initialized")")
                    .font(.caption)
                    .foregroundStyle(status.exists ? .green : .secondary)
                  Text("Embeddings: \(status.providerName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }

              if let stats = mcpServer.ragStats {
                Text("Indexed: \(stats.fileCount) files, \(stats.chunkCount) chunks")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
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

    var icon: String {
      switch self {
      case .yolo: return "bolt.fill"
      case .paranoid: return "lock.shield"
      case .voyeur: return "eye"
      }
    }

    var description: String {
      switch self {
      case .yolo:
        return "Full power mode. Enables all tools including file writes, git operations, and shell commands. Best for trusted development workflows."
      case .paranoid:
        return "Read-only safety. Only background-safe tools that can't modify your system. Great for exploration and code review."
      case .voyeur:
        return "Screenshot observer. Read-only tools plus screenshot capture for visual verification. Useful for UI testing."
      }
    }
  }

  @Bindable var mcpServer: MCPServerService
  @State private var selectedPreset: ToolPreset = .yolo

  var body: some View {
    let _ = mcpServer.permissionsVersion
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Quick Presets")
          .font(.headline)
        Text("Choose a preset to quickly configure tool permissions based on your trust level.")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          ForEach(ToolPreset.allCases) { preset in
            PresetButton(
              preset: preset,
              isSelected: selectedPreset == preset,
              onSelect: {
                selectedPreset = preset
                applyPreset(preset)
              }
            )
          }
        }
        
        // Show description for selected preset
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: selectedPreset.icon)
            .foregroundStyle(.tint)
          Text(selectedPreset.description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(6)
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

  private struct PresetButton: View {
    let preset: ToolPreset
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
      Button(action: onSelect) {
        VStack(spacing: 4) {
          Image(systemName: preset.icon)
            .font(.title2)
          Text(preset.label)
            .font(.caption)
            .fontWeight(isSelected ? .semibold : .regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .help(preset.description)
    }
  }
}
#endif

#Preview {
  SettingsView()
}
