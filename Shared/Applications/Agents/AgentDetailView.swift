//
//  AgentDetailView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI
import AppKit

struct AgentDetailView: View {
  let agent: Agent
  @Bindable var agentManager: AgentManager
  @State private var showingTaskSheet = false
  @State private var isRunning = false
  @State private var output = ""
  @State private var modelInfo = ""  // Model and stats info
  @State private var errorMessage: String?
  @State private var statusMessage = ""  // Live status while running
  @State private var runningSeconds = 0
  @State private var statusTimer: Timer?

  // Need CLI service to run agents
  @State private var cliService = CLIService()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        // Header
        HStack(spacing: 16) {
          ZStack {
            Circle()
              .fill(agent.model.isClaude ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
              .frame(width: 60, height: 60)
            Image(systemName: agent.type.iconName)
              .font(.title)
              .foregroundStyle(agent.model.isClaude ? .orange : .blue)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text(agent.name).font(.title2).fontWeight(.semibold)
            HStack {
              Label(agent.type.displayName, systemImage: agent.type.iconName)
              Text("•")
              Label(agent.state.displayName, systemImage: agent.state.iconName)
            }.font(.subheadline).foregroundStyle(.secondary)
          }
          Spacer()
        }

        // Model picker
        if agent.type == .copilot {
          HStack {
            Text("Model").font(.subheadline).foregroundStyle(.secondary)
            Picker("", selection: Binding(
              get: { agent.model },
              set: { agent.model = $0 }
            )) {
              Section("Free") {
                ForEach(CopilotModel.allCases.filter { $0.isFree }) { m in
                  ModelLabelView(model: m).tag(m)
                }
              }
              Section("Claude") {
                ForEach(CopilotModel.allCases.filter { $0.isClaude }) { m in
                  ModelLabelView(model: m).tag(m)
                }
              }
              Section("GPT") {
                ForEach(CopilotModel.allCases.filter { $0.isGPT && !$0.isFree }) { m in
                  ModelLabelView(model: m).tag(m)
                }
              }
              Section("Gemini") {
                ForEach(CopilotModel.allCases.filter { $0.isGemini && !$0.isFree }) { m in
                  ModelLabelView(model: m).tag(m)
                }
              }
            }
            .labelsHidden()
            .frame(maxWidth: 250)
            .accessibilityIdentifier("agents.agentDetail.modelPicker")
          }

          // Role picker
          HStack {
            Text("Role").font(.subheadline).foregroundStyle(.secondary)
            Picker("", selection: Binding(
              get: { agent.role },
              set: { agent.role = $0 }
            )) {
              ForEach(AgentRole.allCases) { r in
                Label(r.displayName, systemImage: r.iconName).tag(r)
              }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
            .accessibilityIdentifier("agents.agentDetail.rolePicker")

            if !agent.role.canWrite {
              Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .help("Read-only: cannot edit files")
            }
          }

          // Framework picker
          HStack {
            Text("Framework").font(.subheadline).foregroundStyle(.secondary)
            Picker("", selection: Binding(
              get: { agent.frameworkHint },
              set: { agent.frameworkHint = $0 }
            )) {
              ForEach(FrameworkHint.allCases) { f in
                Label(f.displayName, systemImage: f.iconName).tag(f)
              }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
            .accessibilityIdentifier("agents.agentDetail.frameworkPicker")
          }

          // Working directory picker
          HStack {
            Text("Project").font(.subheadline).foregroundStyle(.secondary)
            if let dir = agent.workingDirectory {
              Chip(
                text: URL(fileURLWithPath: dir).lastPathComponent,
                style: .rounded(4),
                font: .subheadline,
                background: Color.secondary.opacity(0.1),
                horizontalPadding: 8,
                verticalPadding: 4
              )
              Button(role: .destructive) {
                agent.workingDirectory = nil
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("agents.agentDetail.project.clear")
            } else {
              Text("None").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Select Folder...") {
              selectFolder()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.agentDetail.project.select")
          }
        }

        if let chain = activeChain {
          GroupBox("Chain Activity") {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(chain.name)
                  .font(.subheadline)
                  .fontWeight(.medium)
                Spacer()
                Text(chain.state.displayName)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              if let result = chain.results.last(where: { $0.agentId == agent.id }) {
                Text(result.output)
                  .font(.caption)
                  .textSelection(.enabled)
              } else if !chain.liveStatusMessages.isEmpty {
                ForEach(chain.liveStatusMessages) { message in
                  HStack(alignment: .top, spacing: 6) {
                    Image(systemName: message.type.icon)
                      .foregroundStyle(message.type.color)
                      .font(.caption)
                    Text(message.message)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              } else {
                Text("No chain output yet.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        Divider()

        if let task = agent.currentTask {
          VStack(alignment: .leading, spacing: 12) {
            Label("Current Task", systemImage: "checklist").font(.headline)
            GroupBox {
              VStack(alignment: .leading, spacing: 8) {
                Text(task.title).font(.subheadline).fontWeight(.medium)
                if !task.description.isEmpty {
                  Text(task.description).font(.caption).foregroundStyle(.secondary)
                }
                if !task.prompt.isEmpty {
                  Text(task.prompt)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }

            // Run button and status
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Button {
                  Task { await runTask(task) }
                } label: {
                  Label(isRunning ? "Running..." : "Run with \(agent.type.displayName)",
                        systemImage: isRunning ? "hourglass" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
                .accessibilityIdentifier("agents.agentDetail.task.run")

                if isRunning {
                  ProgressView()
                    .scaleEffect(0.8)
                  Text("\(runningSeconds)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
              }

              // Live status message
              if isRunning && !statusMessage.isEmpty {
                HStack(spacing: 6) {
                  Image(systemName: "gearshape.2")
                    .symbolEffect(.rotate, isActive: isRunning)
                  Text(statusMessage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
              }
            }

            // Error message
            if let error = errorMessage {
              GroupBox {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                  .foregroundStyle(.red)
              }
            }

            // Output
            if !output.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Label("Output", systemImage: "text.alignleft").font(.headline)
                  Spacer()
                  if !modelInfo.isEmpty {
                    Text(modelInfo)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .padding(.horizontal, 8)
                      .padding(.vertical, 4)
                      .background(Color.secondary.opacity(0.1))
                      .clipShape(RoundedRectangle(cornerRadius: 4))
                  }
                }
                GroupBox {
                  ScrollView {
                    Text(output)
                      .font(.system(.body, design: .monospaced))
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .textSelection(.enabled)
                  }
                  .frame(maxHeight: 300)
                }
              }
            }
          }
        } else {
          VStack(alignment: .leading, spacing: 12) {
            Label("No Task Assigned", systemImage: "tray").font(.headline)
            Text("This agent is idle. Assign a task to get started.")
              .font(.subheadline).foregroundStyle(.secondary)
            Button("Assign Task") { showingTaskSheet = true }
              .buttonStyle(.borderedProminent)
              .disabled(activeChain != nil)
              .accessibilityIdentifier("agents.agentDetail.task.assign")
            if let chain = activeChain {
              Text("Assign Task is disabled while \(chain.name) is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Spacer()
      }.padding()
    }
    .navigationTitle(agent.name)
    .toolbar {
      if agent.state == .idle || agent.currentTask == nil {
        Button("Assign Task") { showingTaskSheet = true }
          .disabled(activeChain != nil)
          .accessibilityIdentifier("agents.agentDetail.toolbar.assign")
      }
    }
    .sheet(isPresented: $showingTaskSheet) {
      AssignTaskSheet(agent: agent, agentManager: agentManager)
    }
    .task {
      await cliService.checkAllCLIs()
    }
  }

  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a project folder for this agent"
    panel.prompt = "Select"

    if panel.runModal() == .OK, let url = panel.url {
      agent.workingDirectory = url.path
    }
  }

  private func startStatusTimer() {
    runningSeconds = 0
    statusMessage = "Initializing \(agent.role.displayName)..."

    // Simulate status updates based on time elapsed
    statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      Task { @MainActor in
        runningSeconds += 1

        // Update status message based on elapsed time
        switch runningSeconds {
        case 1...3:
          statusMessage = "Connecting to \(agent.model.shortName)..."
        case 4...8:
          statusMessage = "Reading project files..."
        case 9...15:
          statusMessage = "Analyzing code..."
        case 16...25:
          if agent.role == .implementer {
            statusMessage = "Making changes..."
          } else {
            statusMessage = "Generating response..."
          }
        case 26...40:
          statusMessage = "Still working..."
        default:
          statusMessage = "Processing (\(runningSeconds)s)..."
        }
      }
    }
  }

  private func stopStatusTimer() {
    statusTimer?.invalidate()
    statusTimer = nil
    statusMessage = ""
  }

  private func runTask(_ task: AgentTask) async {
    isRunning = true
    output = ""
    modelInfo = ""
    errorMessage = nil
    startStatusTimer()

    do {
      switch agent.type {
      case .copilot:
        // Build prompt with role and framework instructions
        let fullPrompt = agent.buildPrompt(userPrompt: task.prompt)
        let response = try await cliService.runCopilotSession(
          prompt: fullPrompt,
          model: agent.model,
          role: agent.role,
          workingDirectory: agent.workingDirectory
        )
        output = response.content
        modelInfo = response.statsText
      case .claude:
        output = try await cliService.runClaudeSession(
          prompt: task.prompt,
          workingDirectory: agent.workingDirectory
        )
        modelInfo = "Claude CLI"
      case .custom:
        errorMessage = "Custom agents not yet supported"
      }

      // Mark task as complete
      agentManager.completeAgent(agent, result: output)
    } catch {
      errorMessage = error.localizedDescription
      agentManager.blockAgent(agent, reason: error.localizedDescription)
    }

    stopStatusTimer()
    isRunning = false
  }

  private var activeChain: AgentChain? {
    agentManager.chains.first { chain in
      chain.agents.contains(where: { $0.id == agent.id }) && chain.state != .idle
    }
  }
}
