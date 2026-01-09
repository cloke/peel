//
//  Agents_RootView.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Main view for AI Agent Orchestration
struct Agents_RootView: View {
  @State private var agentManager = AgentManager()
  @State private var cliService = CLIService()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var showingNewAgentSheet = false
  @State private var showingNewChainSheet = false
  @State private var showingSetupSheet = false
  
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      AgentsSidebarView(
        agentManager: agentManager,
        cliService: cliService,
        showingSetupSheet: $showingSetupSheet,
        showingNewChainSheet: $showingNewChainSheet,
        showingNewAgentSheet: $showingNewAgentSheet
      )
    } detail: {
      if let chain = agentManager.selectedChain {
        ChainDetailView(chain: chain, agentManager: agentManager, cliService: cliService)
      } else if let agent = agentManager.selectedAgent {
        AgentDetailView(agent: agent, agentManager: agentManager)
      } else {
        // Empty state with visible create options
        VStack(spacing: 20) {
          Image(systemName: "cpu")
            .font(.system(size: 48))
            .foregroundStyle(.secondary)
          Text("No Agent Selected")
            .font(.title2)
          Text("Create an agent or chain to get started")
            .foregroundStyle(.secondary)
          
          HStack(spacing: 16) {
            Button {
              showingNewAgentSheet = true
            } label: {
              Label("New Agent", systemImage: "cpu")
            }
            .buttonStyle(.bordered)
            
            Button {
              showingNewChainSheet = true
            } label: {
              Label("New Chain", systemImage: "link")
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .task {
      await cliService.checkAllCLIs()
    }
    .toolbar {
      #if os(macOS)
      ToolbarItem(placement: .navigation) {
        Button {
          NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
          )
        } label: {
          Image(systemName: "sidebar.left")
        }
      }
      ToolSelectionToolbar()
      #endif
    }
    .sheet(isPresented: $showingNewAgentSheet) {
      NewAgentSheet(agentManager: agentManager, cliService: cliService)
    }
    .sheet(isPresented: $showingNewChainSheet) {
      NewChainSheet(agentManager: agentManager, cliService: cliService)
    }
    .sheet(isPresented: $showingSetupSheet) {
      CLISetupSheet(cliService: cliService)
    }
  }
  
  private var cliStatusIcon: String {
    #if os(macOS)
    return (cliService.copilotStatus.isAvailable || cliService.claudeStatus.isAvailable) 
      ? "checkmark.circle.fill" : "exclamationmark.triangle"
    #else
    return "xmark.circle"
    #endif
  }
}

// MARK: - Sidebar

struct AgentsSidebarView: View {
  @Bindable var agentManager: AgentManager
  @Bindable var cliService: CLIService
  @Binding var showingSetupSheet: Bool
  @Binding var showingNewChainSheet: Bool
  @Binding var showingNewAgentSheet: Bool
  
  var body: some View {
    VStack(spacing: 0) {
      List(selection: Binding(
        get: { agentManager.selectedAgent?.id },
        set: { id in agentManager.selectedAgent = agentManager.agents.first { $0.id == id } }
      )) {
        // Chains section
        if !agentManager.chains.isEmpty {
          Section("Chains") {
            ForEach(agentManager.chains) { chain in
              ChainRowView(chain: chain)
                .tag(chain.id)
                .onTapGesture {
                  agentManager.selectedAgent = nil
                  agentManager.selectedChain = chain
                }
            }
          }
        }
        
        if !agentManager.activeAgents.isEmpty {
          Section("Active") {
            ForEach(agentManager.activeAgents) { agent in
              AgentRowView(agent: agent).tag(agent.id)
            }
          }
        }
        
        Section("Agents") {
          ForEach(agentManager.idleAgents) { agent in
            AgentRowView(agent: agent)
              .tag(agent.id)
              .onTapGesture {
                agentManager.selectedChain = nil
                agentManager.selectedAgent = agent
              }
          }
        }
        
        #if os(macOS)
        Section("CLI Status") {
          Button {
            showingSetupSheet = true
          } label: {
            HStack {
              Image(systemName: copilotStatusIcon)
                .foregroundStyle(copilotStatusColor)
              Text("Copilot")
              Spacer()
              Text(copilotStatusLabel)
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          
          Button {
            showingSetupSheet = true
          } label: {
            HStack {
              Image(systemName: cliService.claudeStatus.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(cliService.claudeStatus.isAvailable ? .green : .secondary)
              Text("Claude")
              Spacer()
              Text(cliService.claudeStatus.isAvailable ? "Ready" : "Not installed")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
        }
        #endif
      }
      .listStyle(.sidebar)
      
      #if os(macOS)
      // Quick action buttons at bottom of sidebar
      Divider()
      HStack(spacing: 12) {
        Button {
          showingNewAgentSheet = true
        } label: {
          Label("Agent", systemImage: "cpu")
            .font(.caption)
        }
        .buttonStyle(.bordered)
        
        Button {
          showingNewChainSheet = true
        } label: {
          Label("Chain", systemImage: "link")
            .font(.caption)
        }
        .buttonStyle(.bordered)
        
        Spacer()
        
        Button {
          showingSetupSheet = true
        } label: {
          Image(systemName: cliService.copilotStatus.isAvailable ? "checkmark.circle" : "gear")
        }
        .buttonStyle(.borderless)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color(nsColor: .windowBackgroundColor))
      #endif
    }
    .navigationTitle("Agents")
  }
  
  private var copilotStatusIcon: String {
    switch cliService.copilotStatus {
    case .available: return "checkmark.circle.fill"
    case .needsExtension: return "exclamationmark.circle.fill"
    case .notAuthenticated: return "exclamationmark.triangle.fill"
    case .checking: return "circle.dotted"
    default: return "xmark.circle"
    }
  }
  
  private var copilotStatusColor: Color {
    switch cliService.copilotStatus {
    case .available: return .green
    case .needsExtension: return .blue
    case .notAuthenticated: return .orange
    default: return .secondary
    }
  }
  
  private var copilotStatusLabel: String {
    switch cliService.copilotStatus {
    case .available: return "Ready"
    case .needsExtension: return "Needs extension"
    case .notAuthenticated: return "Needs auth"
    case .notInstalled: return "Not installed"
    case .checking: return "Checking..."
    case .error: return "Error"
    }
  }
}

// MARK: - Agent Row

struct AgentRowView: View {
  let agent: Agent
  
  var body: some View {
    HStack(spacing: 10) {
      // Role icon with state color
      ZStack {
        Circle()
          .fill(roleColor.opacity(0.2))
          .frame(width: 28, height: 28)
        Image(systemName: agent.role.iconName)
          .foregroundStyle(roleColor)
          .font(.caption)
      }
      
      VStack(alignment: .leading, spacing: 2) {
        Text(agent.name).font(.callout)
        HStack(spacing: 4) {
          Text(agent.role.displayName)
            .font(.caption2)
            .foregroundStyle(roleColor)
          Text("•")
          Text(agent.model.shortName).font(.caption)
        }.foregroundStyle(.secondary)
      }
      Spacer()
      if agent.state.isActive {
        ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
      }
    }
  }
  
  private var roleColor: Color {
    switch agent.role {
    case .planner: return .blue
    case .implementer: return .green
    case .reviewer: return .purple
    }
  }
  
  private var stateColor: Color {
    switch agent.state {
    case .idle: return .secondary
    case .planning: return .blue
    case .working: return .green
    case .blocked: return .orange
    case .testing: return .purple
    case .complete: return .green
    case .failed: return .red
    }
  }
}

// MARK: - Agent Detail

struct AgentDetailView: View {
  let agent: Agent
  @Bindable var agentManager: AgentManager
  @State private var showingTaskSheet = false
  @State private var isRunning = false
  @State private var output = ""
  @State private var modelInfo = ""  // Model and stats info
  @State private var errorMessage: String?
  
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
        
        #if os(macOS)
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
            .labelsHidden()
            .frame(maxWidth: 250)
          }
          
          // Working directory picker
          HStack {
            Text("Project").font(.subheadline).foregroundStyle(.secondary)
            if let dir = agent.workingDirectory {
              Text(URL(fileURLWithPath: dir).lastPathComponent)
                .font(.subheadline)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
              Button(role: .destructive) {
                agent.workingDirectory = nil
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
            } else {
              Text("None").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Select Folder...") {
              selectFolder()
            }
            .buttonStyle(.bordered)
          }
        }
        #endif
        
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
            
            #if os(macOS)
            // Run button
            HStack {
              Button {
                Task { await runTask(task) }
              } label: {
                Label(isRunning ? "Running..." : "Run with \(agent.type.displayName)", 
                      systemImage: isRunning ? "hourglass" : "play.fill")
              }
              .buttonStyle(.borderedProminent)
              .disabled(isRunning)
              
              if isRunning {
                ProgressView()
                  .scaleEffect(0.8)
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
            #endif
          }
        } else {
          VStack(alignment: .leading, spacing: 12) {
            Label("No Task Assigned", systemImage: "tray").font(.headline)
            Text("This agent is idle. Assign a task to get started.")
              .font(.subheadline).foregroundStyle(.secondary)
            Button("Assign Task") { showingTaskSheet = true }
              .buttonStyle(.borderedProminent)
          }
        }
        
        Spacer()
      }.padding()
    }
    .navigationTitle(agent.name)
    .toolbar {
      if agent.state == .idle || agent.currentTask == nil {
        Button("Assign Task") { showingTaskSheet = true }
      }
    }
    .sheet(isPresented: $showingTaskSheet) {
      AssignTaskSheet(agent: agent, agentManager: agentManager)
    }
    .task {
      await cliService.checkAllCLIs()
    }
  }
  
  #if os(macOS)
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
  
  private func runTask(_ task: AgentTask) async {
    isRunning = true
    output = ""
    modelInfo = ""
    errorMessage = nil
    
    do {
      switch agent.type {
      case .copilot:
        let response = try await cliService.runCopilotSession(
          prompt: task.prompt,
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
    
    isRunning = false
  }
  #endif
}

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
          Picker("Type", selection: $type) {
            ForEach(AgentType.allCases) { t in
              Label(t.displayName, systemImage: t.iconName).tag(t)
            }
          }
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
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
        Section("Prompt") {
          TextEditor(text: $prompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 150)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Assign Task")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Assign") {
            let task = AgentTask(title: title, prompt: prompt)
            Task {
              try? await agentManager.assignTask(task, to: agent)
              agentManager.startAgent(agent)
            }
            dismiss()
          }.disabled(title.isEmpty || prompt.isEmpty)
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
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          Button {
            cliService.resetInstall()
            Task { await cliService.checkAllCLIs() }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
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
      }
      
      // Step 2: Authenticate
      StepRow(number: 2, title: "Authenticate with GitHub", cmd: "copilot (follow prompts)",
              isComplete: isReady, isActive: cliInstalled && !isReady && !isInstalling) {
        VStack(alignment: .leading, spacing: 8) {
          Button("Open Terminal to Login") {
            cliService.openCopilotAuth()
          }
          .buttonStyle(.borderedProminent)
          
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
        }
      }
    }
  }
}


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

// MARK: - Chain Row View

struct ChainRowView: View {
  let chain: AgentChain
  
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "link")
        .foregroundStyle(stateColor)
        .font(.caption)
      VStack(alignment: .leading, spacing: 2) {
        Text(chain.name).font(.callout)
        Text("\(chain.agents.count) agents")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if case .running = chain.state {
        ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
      }
    }
  }
  
  private var stateColor: Color {
    switch chain.state {
    case .idle: return .secondary
    case .running: return .blue
    case .complete: return .green
    case .failed: return .red
    }
  }
}

// MARK: - New Chain Sheet

struct NewChainSheet: View {
  @Bindable var agentManager: AgentManager
  @Bindable var cliService: CLIService
  @Environment(\.dismiss) private var dismiss
  
  @State private var name = ""
  @State private var workingDirectory: String?
  @State private var agent1Model: CopilotModel = .claudeOpus45
  @State private var agent1Role: AgentRole = .planner
  @State private var agent2Model: CopilotModel = .claudeSonnet45
  @State private var agent2Role: AgentRole = .implementer
  
  var body: some View {
    NavigationStack {
      Form {
        Section("Chain") {
          TextField("Chain Name", text: $name)
          
          #if os(macOS)
          HStack {
            Text("Project")
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
            }
            Button("Select...") { selectFolder() }
          }
          #endif
        }
        
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
          
          if !agent1Role.canWrite {
            Label("Read-only: cannot edit files", systemImage: "lock.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          
          Picker("Model", selection: $agent1Model) {
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
          }
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
          
          if !agent2Role.canWrite {
            Label("Read-only: cannot edit files", systemImage: "lock.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          
          Picker("Model", selection: $agent2Model) {
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
          }
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
      .formStyle(.grouped)
      .navigationTitle("New Chain")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            createChain()
            dismiss()
          }
          .disabled(name.isEmpty)
        }
      }
    }
    .frame(minWidth: 450, minHeight: 450)
  }
  
  #if os(macOS)
  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    
    if panel.runModal() == .OK, let url = panel.url {
      workingDirectory = url.path
    }
  }
  #endif
  
  private func createChain() {
    let chain = agentManager.createChain(
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
    
    agentManager.selectedChain = chain
    agentManager.selectedAgent = nil
  }
}

// MARK: - Chain Detail View

struct ChainDetailView: View {
  let chain: AgentChain
  @Bindable var agentManager: AgentManager
  @Bindable var cliService: CLIService
  
  @State private var prompt = ""
  @State private var isRunning = false
  @State private var errorMessage: String?
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        // Header
        HStack(spacing: 16) {
          ZStack {
            Circle()
              .fill(Color.purple.opacity(0.2))
              .frame(width: 60, height: 60)
            Image(systemName: "link")
              .font(.title)
              .foregroundStyle(.purple)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text(chain.name).font(.title2).fontWeight(.semibold)
            HStack {
              Text("\(chain.agents.count) agents")
              Text("•")
              Text(chain.state.displayName)
            }.font(.subheadline).foregroundStyle(.secondary)
          }
          Spacer()
        }
        
        // Working directory
        if let dir = chain.workingDirectory {
          HStack {
            Image(systemName: "folder")
            Text(dir)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        
        Divider()
        
        // Agents in chain
        VStack(alignment: .leading, spacing: 12) {
          Label("Agents in Chain", systemImage: "list.number").font(.headline)
          
          ForEach(Array(chain.agents.enumerated()), id: \.element.id) { index, agent in
            HStack {
              Text("\(index + 1).")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 24)
              
              VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.subheadline).fontWeight(.medium)
                Text(agent.model.displayName)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              
              Spacer()
              
              // Status indicator
              if let result = chain.results.first(where: { $0.agentId == agent.id }) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
                Text("\(result.premiumCost)×")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else if case .running(let idx) = chain.state, idx == index {
                ProgressView().scaleEffect(0.7)
              }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
        }
        
        Divider()
        
        // Prompt input
        VStack(alignment: .leading, spacing: 8) {
          Label("Task Prompt", systemImage: "text.alignleft").font(.headline)
          TextEditor(text: $prompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 100)
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
          
          Text("This prompt will be sent to Agent 1. Agent 2 will receive Agent 1's output as context.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        #if os(macOS)
        // Run button
        HStack {
          Button {
            Task { await runChain() }
          } label: {
            Label(isRunning ? "Running..." : "Run Chain", systemImage: isRunning ? "hourglass" : "play.fill")
          }
          .buttonStyle(.borderedProminent)
          .disabled(isRunning || prompt.isEmpty)
          
          if isRunning {
            ProgressView().scaleEffect(0.8)
          }
          
          Spacer()
          
          if !chain.results.isEmpty {
            Text("Total: \(chain.results.reduce(0) { $0 + $1.premiumCost })× Premium")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        
        // Error
        if let error = errorMessage {
          GroupBox {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
        
        // Results
        if !chain.results.isEmpty {
          VStack(alignment: .leading, spacing: 16) {
            Label("Results", systemImage: "doc.text").font(.headline)
            
            ForEach(chain.results) { result in
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(result.agentName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                  Text("(\(result.model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Spacer()
                  if let duration = result.duration {
                    Text(duration)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                
                GroupBox {
                  ScrollView {
                    Text(result.output)
                      .font(.system(.body, design: .monospaced))
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .textSelection(.enabled)
                  }
                  .frame(maxHeight: 200)
                }
              }
            }
          }
        }
        #endif
        
        Spacer()
      }
      .padding()
    }
    .navigationTitle(chain.name)
  }
  
  #if os(macOS)
  private func runChain() async {
    isRunning = true
    errorMessage = nil
    chain.reset()
    chain.state = .running(agentIndex: 0)
    
    do {
      for (index, agent) in chain.agents.enumerated() {
        chain.state = .running(agentIndex: index)
        
        // Build prompt with context from previous agents
        var fullPrompt = prompt
        let context = chain.contextForAgent(at: index)
        if !context.isEmpty {
          fullPrompt = """
          Previous agent output for context:
          \(context)
          
          ---
          
          Your task: \(prompt)
          """
        }
        
        // Run the agent
        let response = try await cliService.runCopilotSession(
          prompt: fullPrompt,
          model: agent.model,
          role: agent.role,
          workingDirectory: agent.workingDirectory ?? chain.workingDirectory
        )
        
        // Parse premium cost from response
        var premiumCost = agent.model.premiumCost
        if let premiumStr = response.premiumRequests,
           let num = Int(premiumStr.components(separatedBy: " ").first ?? "") {
          premiumCost = num
        }
        
        // Record result
        let result = AgentChainResult(
          agentId: agent.id,
          agentName: agent.name,
          model: agent.model.displayName,
          prompt: fullPrompt,
          output: response.content,
          duration: response.duration,
          premiumCost: premiumCost
        )
        chain.results.append(result)
      }
      
      chain.state = .complete
    } catch {
      errorMessage = error.localizedDescription
      chain.state = .failed(message: error.localizedDescription)
    }
    
    isRunning = false
  }
  #endif
}
#endif

#Preview {
  Agents_RootView()
}
