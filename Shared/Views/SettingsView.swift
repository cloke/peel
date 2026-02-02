//
//  SettingsView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

import PeelUI
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  #if os(macOS)
  @Environment(MCPServerService.self) private var mcpServer
  #endif

  @State private var vscodeServerName = "Peel"
  @State private var vscodeServerURL = "http://127.0.0.1:8765/rpc"
  @State private var vscodeWriteToWorkspace = false
  @State private var vscodeWorkspacePath = ""
  @State private var vscodeConfigStatus: String?
  @State private var vscodeConfigError: String?
  @State private var isWorkspacePickerPresented = false
  @State private var isWritingVSCodeConfig = false
  @State private var showMCPTools = false
  @State private var urlSchemeStatus: String?
  @State private var isRegisteringURLScheme = false
  
  var body: some View {
    TabView {
      #if os(macOS)
      SettingsPage {
        SettingsSection("MCP Server") {
          HStack(spacing: 16) {
            Toggle(
              "Enable MCP Server",
              isOn: Binding(
                get: { mcpServer.isEnabled },
                set: { mcpServer.isEnabled = $0 }
              )
            )
            
            Spacer()
            
            // Compact status
            HStack(spacing: 8) {
              Circle()
                .fill(mcpServer.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
              Text(mcpServer.isRunning ? "Running" : "Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          HStack {
            LabeledContent("Port") {
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
            
            Spacer()
            
            if mcpServer.isRunning {
              Text("localhost:\(mcpServer.port)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            }
          }

          Toggle(
            "Auto-clean agent worktrees",
            isOn: Binding(
              get: { mcpServer.autoCleanupWorkspaces },
              set: { mcpServer.autoCleanupWorkspaces = $0 }
            )
          )
          
          if let error = mcpServer.lastError {
            let portInUse = error.localizedCaseInsensitiveContains("address already in use")
            Text(portInUse ? "Port in use (another Peel instance may be running)" : error)
              .font(.caption)
              .foregroundStyle(portInUse ? .orange : .red)
          }
        }

        SettingsSection("MCP Tools") {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("\(mcpServer.enabledToolCount) tools enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Text("\(mcpServer.foregroundToolCount) UI · \(mcpServer.backgroundToolCount) background")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            DisclosureGroup(isExpanded: $showMCPTools) {
              MCPToolSettingsSection(mcpServer: mcpServer)
                .padding(.top, 8)
            } label: {
              Text(showMCPTools ? "Hide tool permissions" : "Configure tool permissions")
                .font(.subheadline)
            }
          }
        }

        SettingsSection("Worktree Cleanup") {
          WorktreeCleanupSettingsSection()
        }

        SettingsSection("Prompt Rules") {
          PromptRulesSettingsSection(mcpServer: mcpServer)
        }

        SettingsSection("IDE Integration") {
          VStack(alignment: .leading, spacing: 12) {
            Text("Install Peel as an MCP server in VS Code.")
              .font(.caption)
              .foregroundStyle(.secondary)

            HStack(spacing: 12) {
              TextField("Server Name", text: $vscodeServerName)
                .textFieldStyle(.roundedBorder)
              TextField("Server URL", text: $vscodeServerURL)
                .textFieldStyle(.roundedBorder)
            }

            Toggle("Write to workspace settings", isOn: $vscodeWriteToWorkspace)
              .font(.caption)

            if vscodeWriteToWorkspace {
              HStack(spacing: 12) {
                TextField("Workspace folder", text: $vscodeWorkspacePath)
                  .textFieldStyle(.roundedBorder)
                Button("Choose…") { isWorkspacePickerPresented = true }
              }
            }

            HStack {
              Button(isWritingVSCodeConfig ? "Installing…" : "Install VS Code Config") {
                Task { await installVSCodeMCPConfig() }
              }
              .disabled(isWritingVSCodeConfig)
              
              if let status = vscodeConfigStatus {
                Text(status)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              if let error = vscodeConfigError {
                Text(error)
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            }
          }
        }

        SettingsSection("Developer") {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("URL Scheme Registration")
                .font(.subheadline)
              Text("Register peel:// for OAuth callbacks")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isRegisteringURLScheme ? "Registering…" : "Register") {
              Task { await registerURLScheme() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRegisteringURLScheme)
          }

          if let status = urlSchemeStatus {
            Text(status)
              .font(.caption)
              .foregroundStyle(status.contains("✓") ? .green : (status.contains("Error") ? .red : .secondary))
          }
        }
      }
      .tabItem { Label("MCP", systemImage: "bolt.horizontal.circle") }
      
      // MARK: - Swarm Settings Tab
      SwarmManagementView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      .tabItem { Label("Swarm", systemImage: "person.3.fill") }
      #endif

      SettingsPage {
        SettingsSection("About") {
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
      .tabItem { Label("About", systemImage: "info.circle") }
    }
    .frame(minWidth: 680, idealWidth: 720, maxWidth: 900, minHeight: 560, idealHeight: 680, maxHeight: 900)
    .fileImporter(
      isPresented: $isWorkspacePickerPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let selected = urls.first {
          vscodeWorkspacePath = selected.path
        }
      case .failure(let error):
        vscodeConfigError = error.localizedDescription
      }
    }
    .task {
      if vscodeWorkspacePath.isEmpty {
        #if os(macOS)
        vscodeWorkspacePath = mcpServer.agentManager.lastUsedWorkingDirectory ?? ""
        #endif
      }
    }
  }

  private func installVSCodeMCPConfig() async {
    vscodeConfigError = nil
    vscodeConfigStatus = nil
    isWritingVSCodeConfig = true
    defer { isWritingVSCodeConfig = false }

    let scope: VSCodeService.ConfigTarget
    if vscodeWriteToWorkspace {
      let trimmedPath = vscodeWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedPath.isEmpty else {
        vscodeConfigError = "Choose a workspace folder first."
        return
      }
      scope = .workspace(path: trimmedPath)
    } else {
      scope = .user
    }

    do {
      let cleanName = vscodeServerName.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = cleanName.isEmpty ? "Peel" : cleanName
      let url = vscodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
      let path = try await VSCodeService.shared.installMCPConfig(
        serverName: name,
        serverURL: url,
        scope: scope
      )
      vscodeConfigStatus = "Updated VS Code settings: \(path)"
    } catch {
      vscodeConfigError = error.localizedDescription
    }
  }

  #if os(macOS)
  private func registerURLScheme() async {
    urlSchemeStatus = nil
    isRegisteringURLScheme = true
    defer { isRegisteringURLScheme = false }

    // Find the running app's bundle path
    guard let bundlePath = Bundle.main.bundlePath as String? else {
      urlSchemeStatus = "Error: Could not determine app bundle path"
      return
    }

    // Run lsregister to force URL scheme recognition
    let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: lsregisterPath)
    process.arguments = ["-f", bundlePath]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus == 0 {
        urlSchemeStatus = "✓ URL scheme registered for: \(bundlePath)"
      } else {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? "Unknown error"
        urlSchemeStatus = "Error (exit \(process.terminationStatus)): \(output)"
      }
    } catch {
      urlSchemeStatus = "Error: \(error.localizedDescription)"
    }
  }
  #endif
}

private struct SettingsPage<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentMargins(20, for: .scrollContent)
  }
}

// SettingsSection is now a typealias for SectionCard from PeelUI
private typealias SettingsSection = SectionCard

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

// MARK: - Worktree Cleanup Settings

private struct WorktreeCleanupSettingsSection: View {
  @Environment(DataService.self) private var dataService
  @State private var autoCleanup: Bool = true
  @State private var retentionDays: Int = 7
  @State private var maxDiskGB: Double = 10.0
  @State private var isLoaded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Automatically clean up old worktrees created by parallel runs and swarm tasks.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Toggle("Auto-cleanup enabled", isOn: $autoCleanup)
        .onChange(of: autoCleanup) { _, newValue in
          saveSettings()
        }

      if autoCleanup {
        HStack {
          Text("Retention period:")
          Picker("", selection: $retentionDays) {
            Text("1 day").tag(1)
            Text("3 days").tag(3)
            Text("7 days").tag(7)
            Text("14 days").tag(14)
            Text("30 days").tag(30)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .onChange(of: retentionDays) { _, _ in
            saveSettings()
          }
        }

        HStack {
          Text("Max disk usage:")
          Picker("", selection: $maxDiskGB) {
            Text("5 GB").tag(5.0)
            Text("10 GB").tag(10.0)
            Text("20 GB").tag(20.0)
            Text("50 GB").tag(50.0)
            Text("Unlimited").tag(0.0)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .onChange(of: maxDiskGB) { _, _ in
            saveSettings()
          }
        }

        Text("Worktrees older than \(retentionDays) day\(retentionDays == 1 ? "" : "s") will be automatically removed (unless they have uncommitted changes).")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .onAppear {
      loadSettings()
    }
  }

  private func loadSettings() {
    guard !isLoaded else { return }
    let settings = dataService.getDeviceSettings()
    autoCleanup = settings.worktreeAutoCleanup
    retentionDays = settings.worktreeRetentionDays
    maxDiskGB = settings.worktreeMaxDiskGB
    isLoaded = true
  }

  private func saveSettings() {
    guard isLoaded else { return }
    let settings = dataService.getDeviceSettings()
    settings.worktreeAutoCleanup = autoCleanup
    settings.worktreeRetentionDays = retentionDays
    settings.worktreeMaxDiskGB = maxDiskGB
  }
}

// MARK: - Prompt Rules Settings

private struct PromptRulesSettingsSection: View {
  @Bindable var mcpServer: MCPServerService
  @State private var globalPrefix: String = ""
  @State private var enforcePlannerModel: String = ""
  @State private var maxPremiumCost: String = ""
  @State private var requireRagByDefault: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Configure rules that are automatically applied to all chain runs.")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 4) {
        Text("Global Prefix")
          .font(.subheadline)
          .fontWeight(.medium)
        TextEditor(text: $globalPrefix)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 60, maxHeight: 120)
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
          )
        Text("Text prepended to all chain prompts. Use for project-specific instructions.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Enforce Planner Model")
          .font(.subheadline)
          .fontWeight(.medium)
        TextField("e.g., gpt-4.1", text: $enforcePlannerModel)
          .textFieldStyle(.roundedBorder)
        Text("Force all planners to use this model, overriding template settings.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Default Max Premium Cost")
          .font(.subheadline)
          .fontWeight(.medium)
        TextField("e.g., 0.5", text: $maxPremiumCost)
          .textFieldStyle(.roundedBorder)
        Text("Default cost limit for chains. Chains exceeding this emit a warning.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Toggle("Require RAG Usage by Default", isOn: $requireRagByDefault)
      Text("Warn if the planner doesn't use any rag.* tools during execution.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Divider()

      HStack(spacing: 12) {
        Button("Apply Changes") {
          applyChanges()
        }
        .buttonStyle(.borderedProminent)

        Button("Reset to Defaults") {
          resetToDefaults()
        }
        .buttonStyle(.bordered)
      }

      // Show current state
      if !mcpServer.promptRules.globalPrefix.isEmpty ||
         mcpServer.promptRules.enforcePlannerModel != nil ||
         mcpServer.promptRules.maxPremiumCostDefault != nil ||
         mcpServer.promptRules.requireRagByDefault {
        VStack(alignment: .leading, spacing: 4) {
          Text("Active Rules")
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
          if !mcpServer.promptRules.globalPrefix.isEmpty {
            Label("Global prefix: \(mcpServer.promptRules.globalPrefix.prefix(50))...", systemImage: "text.quote")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if let model = mcpServer.promptRules.enforcePlannerModel {
            Label("Planner model: \(model)", systemImage: "cpu")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if let cost = mcpServer.promptRules.maxPremiumCostDefault {
            Label("Max cost: \(cost, specifier: "%.2f")", systemImage: "dollarsign.circle")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if mcpServer.promptRules.requireRagByDefault {
            Label("RAG required", systemImage: "checkmark.circle")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(6)
      }
    }
    .onAppear {
      loadCurrentRules()
    }
  }

  private func loadCurrentRules() {
    globalPrefix = mcpServer.promptRules.globalPrefix
    enforcePlannerModel = mcpServer.promptRules.enforcePlannerModel ?? ""
    if let cost = mcpServer.promptRules.maxPremiumCostDefault {
      maxPremiumCost = String(format: "%.2f", cost)
    } else {
      maxPremiumCost = ""
    }
    requireRagByDefault = mcpServer.promptRules.requireRagByDefault
  }

  private func applyChanges() {
    var rules = mcpServer.promptRules
    rules.globalPrefix = globalPrefix
    rules.enforcePlannerModel = enforcePlannerModel.isEmpty ? nil : enforcePlannerModel
    rules.maxPremiumCostDefault = Double(maxPremiumCost)
    rules.requireRagByDefault = requireRagByDefault
    mcpServer.promptRules = rules
  }

  private func resetToDefaults() {
    mcpServer.promptRules = .default
    loadCurrentRules()
  }
}

#endif

#Preview {
  SettingsView()
}
