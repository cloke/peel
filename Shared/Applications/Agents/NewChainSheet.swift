//
//  NewChainSheet.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import MCPCore
import SwiftUI

struct NewChainSheet: View {
  @Bindable var agentManager: AgentManager
  @Bindable var cliService: CLIService
  @Environment(\.dismiss) private var dismiss

  @State private var selectedTemplate: ChainTemplate?
  @State private var name = ""
  @State private var workingDirectory: String?
  @State private var useTemplate = true

  // Manual config (when not using template)
  @State private var agent1Model: CopilotModel = .claudeOpus45
  @State private var agent1Role: AgentRole = .planner
  @State private var agent2Model: CopilotModel = .claudeSonnet45
  @State private var agent2Role: AgentRole = .implementer

  var body: some View {
    NavigationStack {
      Form {
        // Explanation at top
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Label("Create a chain of agents to run a task", systemImage: "info.circle")
              .font(.subheadline)
            Text("Chains run once. After running, you can save the configuration as a template for future use.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        // Project folder (required) - show first for importance
        Section {
          HStack {
            Image(systemName: "folder_fill")
              .foregroundStyle(workingDirectory == nil ? .orange : .green)
            Text("Project Folder")
              .fontWeight(.medium)
            Spacer()
            if let dir = workingDirectory {
              Text(URL(fileURLWithPath: dir).lastPathComponent)
                .foregroundStyle(.secondary)
              Button(role: .destructive) {
                workingDirectory = nil
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("agents.newChain.project.clear")
            }
            Button("Select...") { selectFolder() }
              .accessibilityIdentifier("agents.newChain.project.select")
          }

          if workingDirectory == nil {
            Label("Required: Select a project folder to focus the agent", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        } header: {
          Text("Project")
        }

        // Template selection
        Section {
          Toggle("Use Template", isOn: $useTemplate)
            .accessibilityIdentifier("agents.newChain.useTemplate")

          if useTemplate {
            Picker("Template", selection: $selectedTemplate) {
              Text("Select...").tag(nil as ChainTemplate?)

              Section("Built-in") {
                ForEach(ChainTemplate.builtInTemplates) { template in
                  HStack {
                    if !template.isFullyAvailable(copilotAvailable: cliService.copilotStatus.isAvailable, claudeAvailable: cliService.claudeStatus.isAvailable) {
                      Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    }
                    Text(template.name)
                    Spacer()
                    Text(template.costDisplay)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  .tag(template as ChainTemplate?)
                }
              }

              if !agentManager.savedTemplates.isEmpty {
                Section("Saved") {
                  ForEach(agentManager.savedTemplates) { template in
                    HStack {
                      if !template.isFullyAvailable(copilotAvailable: cliService.copilotStatus.isAvailable, claudeAvailable: cliService.claudeStatus.isAvailable) {
                        Image(systemName: "exclamationmark.triangle.fill")
                          .foregroundStyle(.orange)
                      }
                      Text(template.name)
                      Spacer()
                      Text(template.costDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(template as ChainTemplate?)
                  }
                }
              }
            }
            .accessibilityIdentifier("agents.newChain.template")

            // Template preview
            if let template = selectedTemplate {
              VStack(alignment: .leading, spacing: 8) {
                if !template.description.isEmpty {
                  Text(template.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                let unavailableModels = template.unavailableModels(
                  copilotAvailable: cliService.copilotStatus.isAvailable,
                  claudeAvailable: cliService.claudeStatus.isAvailable
                )
                
                if !unavailableModels.isEmpty {
                  Label("Unavailable models: \(unavailableModels.map(\.displayName).joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                ForEach(Array(template.steps.enumerated()), id: \.element.id) { index, step in
                  HStack(spacing: 8) {
                    Text("\(index + 1).")
                      .font(.caption.bold())
                      .foregroundStyle(.secondary)
                    Image(systemName: step.role.iconName)
                      .foregroundStyle(roleColor(step.role))
                    Text(step.name)
                      .font(.caption)
                    Spacer()
                    Text(step.model.shortName)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .padding(.vertical, 4)
            }
          }
        }

        Section("Chain") {
          TextField("Chain Name", text: $name, prompt: Text(selectedTemplate?.name ?? "My Chain"))
            .accessibilityIdentifier("agents.newChain.name")
        }

        // Manual configuration (only when not using template)
        if !useTemplate {
          Section {
            HStack {
              Image(systemName: agent1Role.iconName)
                .foregroundStyle(.blue)
              Text("Agent 1")
                .fontWeight(.medium)
            }

            Picker("Role", selection: $agent1Role) {
              ForEach(AgentRole.allCases) { r in
                Label(r.displayName, systemImage: r.iconName).tag(r)
              }
            }
            .accessibilityIdentifier("agents.newChain.agent1.role")

            if !agent1Role.canWrite {
              Label("Read-only: cannot edit files", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Picker("Model", selection: $agent1Model) {
              let availableModels = MCPCopilotModel.availableModels(
                copilotAvailable: cliService.copilotStatus.isAvailable,
                claudeAvailable: cliService.claudeStatus.isAvailable
              )
              let freeModels = availableModels.filter { $0.isFree }
              let claudeModels = availableModels.filter { $0.isClaude }
              let gptModels = availableModels.filter { $0.isGPT && !$0.isFree }
              
              if !freeModels.isEmpty {
                Section("Free") {
                  ForEach(freeModels) { m in
                    ModelLabelView(model: m).tag(m)
                  }
                }
              }
              if !claudeModels.isEmpty {
                Section("Claude") {
                  ForEach(claudeModels) { m in
                    ModelLabelView(model: m).tag(m)
                  }
                }
              }
              if !gptModels.isEmpty {
                Section("GPT") {
                  ForEach(gptModels) { m in
                    ModelLabelView(model: m).tag(m)
                  }
                }
              }
            }
            .accessibilityIdentifier("agents.newChain.agent1.model")
          }

          Section {
            HStack {
              Image(systemName: agent2Role.iconName)
                .foregroundStyle(.green)
              Text("Agent 2")
                .fontWeight(.medium)
            }

            Picker("Role", selection: $agent2Role) {
              ForEach(AgentRole.allCases) { r in
                Label(r.displayName, systemImage: r.iconName).tag(r)
              }
            }
            .accessibilityIdentifier("agents.newChain.agent2.role")

            if !agent2Role.canWrite {
              Label("Read-only: cannot edit files", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Picker("Model", selection: $agent2Model) {
              let availableModels = MCPCopilotModel.availableModels(
                copilotAvailable: cliService.copilotStatus.isAvailable,
                claudeAvailable: cliService.claudeStatus.isAvailable
              )
              let freeModels = availableModels.filter { $0.isFree }
              let claudeModels = availableModels.filter { $0.isClaude }
              let gptModels = availableModels.filter { $0.isGPT && !$0.isFree }
              
              if !freeModels.isEmpty {
                Section("Free") {
                  ForEach(freeModels) { m in
                    ModelLabelView(model: m).tag(m)
                  }
                }
              }
              if !claudeModels.isEmpty {
                Section("Claude") {
                  ForEach(claudeModels) { m in
                    ModelLabelView(model: m).tag(m)
                  }
                }
              }
              if !gptModels.isEmpty {
                Section("GPT") {
                  ForEach(gptModels) { m in
                    ModelLabelView(model: m).tag(m)
                  }
                }
              }
            }
            .accessibilityIdentifier("agents.newChain.agent2.model")
          }

          Section {
            HStack {
              Image(systemName: "arrow.right")
              Text("Agent 1 runs first → Output passed to Agent 2")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("New Chain")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .accessibilityIdentifier("agents.newChain.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            // Save working directory for next time
            if let dir = workingDirectory {
              agentManager.lastUsedWorkingDirectory = dir
            }
            createChain()
            dismiss()
          }
          .disabled(workingDirectory == nil || (useTemplate && selectedTemplate == nil))
          .accessibilityIdentifier("agents.newChain.create")
        }
      }
    }
    .frame(minWidth: 500, minHeight: 550)
    .onAppear {
      // Load last used working directory
      if workingDirectory == nil {
        workingDirectory = agentManager.lastUsedWorkingDirectory
      }
    }
  }

  private func roleColor(_ role: AgentRole) -> Color {
    switch role {
    case .planner: return .blue
    case .implementer: return .green
    case .reviewer: return .purple
    }
  }

  private func selectFolder() {
    if let path = FolderPicker.selectFolder(message: "Select a project folder") {
      workingDirectory = path
    }
  }

  private func createChain() {
    let chain: AgentChain

    if useTemplate, let template = selectedTemplate {
      // Create from template
      chain = agentManager.createChainFromTemplate(template, workingDirectory: workingDirectory)
      if !name.isEmpty {
        chain.name = name
      }
    } else {
      // Manual creation
      chain = agentManager.createChain(
        name: name.isEmpty ? "New Chain" : name,
        workingDirectory: workingDirectory
      )

      // Create agent 1
      let agent1 = agentManager.createAgent(
        name: agent1Role.displayName,
        type: .copilot,
        role: agent1Role,
        model: agent1Model,
        workingDirectory: workingDirectory
      )
      chain.addAgent(agent1)

      // Create agent 2
      let agent2 = agentManager.createAgent(
        name: agent2Role.displayName,
        type: .copilot,
        role: agent2Role,
        model: agent2Model,
        workingDirectory: workingDirectory
      )
      chain.addAgent(agent2)
    }

    agentManager.selectedChain = chain
    agentManager.selectedAgent = nil
  }
}
