//
//  AgentSheets.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

// MARK: - New Agent Sheet

struct NewAgentSheet: View {
  @Bindable var agentManager: AgentManager
  @Bindable var cliService: CLIService
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var type: AgentType = .copilot
  @State private var model: CopilotModel = .claudeSonnet45
  @State private var role: AgentRole = .implementer

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Agent Name", text: $name)
            .accessibilityIdentifier("agents.newAgent.name")
          Picker("Type", selection: $type) {
            ForEach(AgentType.allCases) { t in
              Label(t.displayName, systemImage: t.iconName).tag(t)
            }
          }
          .accessibilityIdentifier("agents.newAgent.type")
        }

        #if os(macOS)
        // Role and Model picker for Copilot agents
        if type == .copilot {
          Section("Role") {
            Picker("Role", selection: $role) {
              ForEach(AgentRole.allCases) { r in
                Label {
                  VStack(alignment: .leading) {
                    Text(r.displayName)
                    Text(r.description)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                } icon: {
                  Image(systemName: r.iconName)
                }
                .tag(r)
              }
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("agents.newAgent.role")

            if !role.canWrite {
              Label("This role cannot edit files", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }

          Section("Model") {
            Picker("Model", selection: $model) {
              Section("Free") {
                ForEach(CopilotModel.allCases.filter { $0.isFree }) { m in
                  Text(m.displayNameWithCost).tag(m)
                }
              }
              Section("Claude") {
                ForEach(CopilotModel.allCases.filter { $0.isClaude }) { m in
                  Text(m.displayNameWithCost).tag(m)
                }
              }
              Section("GPT") {
                ForEach(CopilotModel.allCases.filter { $0.isGPT && !$0.isFree }) { m in
                  Text(m.displayNameWithCost).tag(m)
                }
              }
              Section("Gemini") {
                ForEach(CopilotModel.allCases.filter { $0.isGemini && !$0.isFree }) { m in
                  Text(m.displayNameWithCost).tag(m)
                }
              }
            }
            .accessibilityIdentifier("agents.newAgent.model")
          }
        }

        if !isAvailable(type) {
          Section {
            Text(type == .claude ? CLIService.claudeInstallInstructions : CLIService.copilotInstallInstructions)
              .font(.caption).foregroundStyle(.secondary)
          } header: {
            Label("Setup Required", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
        }
        #endif
      }
      .formStyle(.grouped)
      .navigationTitle("New Agent")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .accessibilityIdentifier("agents.newAgent.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            let agent = agentManager.createAgent(
              name: name.isEmpty ? "\(role.displayName) (\(model.shortName))" : name,
              type: type,
              role: role,
              model: model
            )
            agentManager.selectedAgent = agent
            dismiss()
          }
          .accessibilityIdentifier("agents.newAgent.create")
        }
      }
    }.frame(minWidth: 400, minHeight: 400)
  }

  #if os(macOS)
  private func isAvailable(_ type: AgentType) -> Bool {
    switch type {
    case .claude: return cliService.claudeStatus.isAvailable
    case .copilot: return cliService.copilotStatus.isAvailable
    case .custom: return true
    }
  }
  #endif
}

// MARK: - Assign Task Sheet

struct AssignTaskSheet: View {
  let agent: Agent
  @Bindable var agentManager: AgentManager
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var prompt = ""

  var body: some View {
    NavigationStack {
      Form {
        TextField("Task Title", text: $title)
          .accessibilityIdentifier("agents.assignTask.title")
        Section("Prompt") {
          TextEditor(text: $prompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 150)
            .accessibilityIdentifier("agents.assignTask.prompt")
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Assign Task")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .accessibilityIdentifier("agents.assignTask.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Assign") {
            let task = AgentTask(title: title, prompt: prompt)
            Task {
              try? await agentManager.assignTask(task, to: agent)
              agentManager.startAgent(agent)
            }
            dismiss()
          }.disabled(title.isEmpty || prompt.isEmpty)
          .accessibilityIdentifier("agents.assignTask.assign")
        }
      }
    }.frame(minWidth: 500, minHeight: 400)
  }

}

// MARK: - CLI Setup Sheet

#if os(macOS)
struct CLISetupSheet: View {
  @Bindable var cliService: CLIService
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // GitHub Copilot Section
          GroupBox {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Image(systemName: copilotIcon)
                  .foregroundStyle(copilotColor)
                  .font(.title)
                VStack(alignment: .leading) {
                  Text("GitHub Copilot CLI").font(.headline)
                  Text(copilotStatusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
              }

              Divider()

              if !cliService.copilotStatus.isAvailable {
                CopilotInstallSteps(cliService: cliService)
              } else {
                Label("Ready to use!", systemImage: "checkmark.circle.fill")
                  .foregroundStyle(.green)
              }
            }.padding(.vertical, 4)
          }

          // Claude Section
          GroupBox {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Image(systemName: cliService.claudeStatus.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                  .foregroundStyle(cliService.claudeStatus.isAvailable ? .green : .secondary)
                  .font(.title)
                VStack(alignment: .leading) {
                  Text("Claude CLI").font(.headline)
                  Text(cliService.claudeStatus.isAvailable ? "Ready" : "Not installed")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
              }

              if !cliService.claudeStatus.isAvailable {
                Divider()
                Text(CLIService.claudeInstallInstructions)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
              }
            }.padding(.vertical, 4)
          }

          // Output log
          if !cliService.installOutput.isEmpty {
            GroupBox("Installation Log") {
              ScrollView {
                Text(cliService.installOutput.joined(separator: "\n"))
                  .font(.system(.caption, design: .monospaced))
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .textSelection(.enabled)
              }.frame(maxHeight: 150)
            }
          }
        }.padding()
      }
      .navigationTitle("CLI Setup")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("agents.cliSetup.done")
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            cliService.resetInstall()
            Task { await cliService.checkAllCLIs(force: true) }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .accessibilityIdentifier("agents.cliSetup.refresh")
        }
      }
    }.frame(minWidth: 550, minHeight: 500)
  }

  private var copilotIcon: String {
    switch cliService.copilotStatus {
    case .available: return "checkmark.circle.fill"
    case .needsExtension: return "exclamationmark.circle.fill"
    case .notAuthenticated: return "exclamationmark.triangle.fill"
    default: return "xmark.circle"
    }
  }

  private var copilotColor: Color {
    switch cliService.copilotStatus {
    case .available: return .green
    case .needsExtension: return .blue
    case .notAuthenticated: return .orange
    default: return .secondary
    }
  }

  private var copilotStatusText: String {
    switch cliService.copilotStatus {
    case .available(let v): return "Ready" + (v.map { " (\($0))" } ?? "")
    case .needsExtension: return "Needs authentication"  // Legacy, shouldn't occur
    case .notAuthenticated: return "Needs authentication"
    case .notInstalled: return "Not installed"
    case .checking: return "Checking..."
    case .error(let e): return "Error: \(e)"
    }
  }
}

struct CopilotInstallSteps: View {
  @Bindable var cliService: CLIService

  // Derive states from cliService.copilotStatus - single source of truth
  private var cliInstalled: Bool {
    switch cliService.copilotStatus {
    case .notInstalled, .checking, .error: return false
    default: return true
    }
  }

  private var isReady: Bool {
    cliService.copilotStatus.isAvailable
  }

  private var isInstalling: Bool {
    if case .installing = cliService.copilotInstallStep { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Step 1: Install copilot-cli
      StepRow(number: 1, title: "Install Copilot CLI", cmd: "brew install copilot-cli",
              isComplete: cliInstalled, isActive: !cliInstalled && !isInstalling) {
        Button("Install with Homebrew") {
          Task { await cliService.installCopilotCLI() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isInstalling)
        .accessibilityIdentifier("agents.cliSetup.installCopilot")
      }

      // Step 2: Authenticate
      StepRow(number: 2, title: "Authenticate with GitHub", cmd: "copilot (follow prompts)",
              isComplete: isReady, isActive: cliInstalled && !isReady && !isInstalling) {
        VStack(alignment: .leading, spacing: 8) {
          Button("Open Terminal to Login") {
            cliService.openCopilotAuth()
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("agents.cliSetup.openCopilotAuth")

          Text("Run 'copilot' and follow the authentication prompts.")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text("After completing login in Terminal, click below:")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button("I've Completed Authentication") {
            Task { await cliService.checkCopilot() }
          }
          .buttonStyle(.bordered)
          .disabled(isInstalling)
          .accessibilityIdentifier("agents.cliSetup.confirmCopilotAuth")
        }
      }
    }
  }
}
#endif

struct StepRow<Actions: View>: View {
  let number: Int
  let title: String
  let cmd: String
  let isComplete: Bool
  let isActive: Bool
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle().fill(isComplete ? Color.green : (isActive ? Color.blue : Color.secondary.opacity(0.3)))
          .frame(width: 28, height: 28)
        if isComplete {
          Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
        } else {
          Text("\(number)").font(.caption.bold()).foregroundStyle(isActive ? .white : .secondary)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.subheadline).fontWeight(isActive ? .semibold : .regular)
        Text(cmd).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        if isActive && !isComplete {
          HStack(spacing: 8) { actions() }.padding(.top, 4)
        }
      }
      Spacer()
    }.opacity(isComplete ? 0.7 : 1.0)
  }
}
