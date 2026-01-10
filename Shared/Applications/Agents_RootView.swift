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
  @State private var sessionTracker = SessionTracker()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var showingNewAgentSheet = false
  @State private var showingNewChainSheet = false
  @State private var showingSetupSheet = false
  @State private var showingSessionSummary = false
  
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
        ChainDetailView(chain: chain, agentManager: agentManager, cliService: cliService, sessionTracker: sessionTracker)
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
      ToolbarItem(placement: .automatic) {
        Button {
          showingSessionSummary = true
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")
            Text("\(sessionTracker.totalPremiumUsed)×")
              .font(.caption)
              .fontWeight(.medium)
          }
        }
        .help("Session Usage: \(sessionTracker.totalPremiumUsed) premium requests")
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
    .sheet(isPresented: $showingSessionSummary) {
      SessionSummarySheet(sessionTracker: sessionTracker)
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
  
  // Track selection as a string: "chain:id" or "agent:id"
  @State private var selection: String?
  
  var body: some View {
    VStack(spacing: 0) {
      List(selection: $selection) {
        // Running chains - show prominently at top
        let runningChains = agentManager.chains.filter { 
          if case .running = $0.state { return true }
          if case .reviewing = $0.state { return true }
          return false
        }
        if !runningChains.isEmpty {
          Section {
            ForEach(runningChains) { chain in
              RunningChainRowView(chain: chain)
                .tag("chain:\(chain.id.uuidString)")
            }
          } header: {
            Label("Running Now", systemImage: "bolt.fill")
              .foregroundStyle(.blue)
          }
        }
        
        // Saved chain templates / recent chains
        let idleChains = agentManager.chains.filter {
          if case .idle = $0.state { return true }
          if case .complete = $0.state { return true }
          if case .failed = $0.state { return true }
          return false
        }
        if !idleChains.isEmpty {
          Section("Recent Chains") {
            ForEach(idleChains) { chain in
              ChainRowView(chain: chain)
                .tag("chain:\(chain.id.uuidString)")
            }
          }
        }
        
        if !agentManager.activeAgents.isEmpty {
          Section("Active") {
            ForEach(agentManager.activeAgents) { agent in
              AgentRowView(agent: agent)
                .tag("agent:\(agent.id.uuidString)")
            }
          }
        }
        
        Section("Agents") {
          ForEach(agentManager.idleAgents) { agent in
            AgentRowView(agent: agent)
              .tag("agent:\(agent.id.uuidString)")
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
    .onChange(of: selection) { _, newValue in
      handleSelection(newValue)
    }
    .onAppear {
      // Sync selection from manager on appear
      if let chain = agentManager.selectedChain {
        selection = "chain:\(chain.id.uuidString)"
      } else if let agent = agentManager.selectedAgent {
        selection = "agent:\(agent.id.uuidString)"
      }
    }
  }
  
  private func handleSelection(_ value: String?) {
    guard let value else {
      agentManager.selectedAgent = nil
      agentManager.selectedChain = nil
      return
    }
    
    if value.hasPrefix("chain:") {
      let idStr = String(value.dropFirst(6))
      if let uuid = UUID(uuidString: idStr),
         let chain = agentManager.chains.first(where: { $0.id == uuid }) {
        agentManager.selectedAgent = nil
        agentManager.selectedChain = chain
      }
    } else if value.hasPrefix("agent:") {
      let idStr = String(value.dropFirst(6))
      if let uuid = UUID(uuidString: idStr),
         let agent = agentManager.agents.first(where: { $0.id == uuid }) {
        agentManager.selectedChain = nil
        agentManager.selectedAgent = agent
      }
    }
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

// MARK: - Running Chain Row View (prominent display for active chains)

struct RunningChainRowView: View {
  let chain: AgentChain
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 16, height: 16)
        
        Text(chain.name)
          .font(.callout)
          .fontWeight(.medium)
        
        Spacer()
        
        Text(statusText)
          .font(.caption2)
          .foregroundStyle(.blue)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.blue.opacity(0.15))
          .clipShape(Capsule())
      }
      
      // Progress bar showing which agent
      HStack(spacing: 2) {
        ForEach(Array(chain.agents.enumerated()), id: \.element.id) { index, agent in
          RoundedRectangle(cornerRadius: 2)
            .fill(progressColor(for: index))
            .frame(height: 4)
        }
      }
      
      // Current agent name
      if let currentAgent = currentRunningAgent {
        Text(currentAgent.name)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
  
  private var statusText: String {
    switch chain.state {
    case .running(let idx):
      return "Agent \(idx + 1)/\(chain.agents.count)"
    case .reviewing(let iter):
      return "Review #\(iter)"
    default:
      return "Running"
    }
  }
  
  private var currentRunningAgent: Agent? {
    if case .running(let idx) = chain.state, idx < chain.agents.count {
      return chain.agents[idx]
    }
    return nil
  }
  
  private func progressColor(for index: Int) -> Color {
    switch chain.state {
    case .running(let currentIdx):
      if index < currentIdx { return .green }
      if index == currentIdx { return .blue }
      return .secondary.opacity(0.3)
    case .reviewing:
      return .orange
    default:
      return .secondary.opacity(0.3)
    }
  }
}

// MARK: - Chain Row View (for idle/completed chains)

struct ChainRowView: View {
  let chain: AgentChain
  
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: stateIcon)
        .foregroundStyle(stateColor)
        .font(.caption)
      VStack(alignment: .leading, spacing: 2) {
        Text(chain.name).font(.callout)
        HStack(spacing: 4) {
          Text("\(chain.agents.count) agents")
          if !chain.results.isEmpty {
            Text("•")
            Text("\(chain.results.reduce(0) { $0 + $1.premiumCost })× used")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }
  
  private var stateIcon: String {
    switch chain.state {
    case .idle: return "link"
    case .running: return "play.circle.fill"
    case .reviewing: return "arrow.triangle.2.circlepath"
    case .complete: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    }
  }
  
  private var stateColor: Color {
    switch chain.state {
    case .idle: return .secondary
    case .running: return .blue
    case .reviewing: return .orange
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
          #if os(macOS)
          HStack {
            Image(systemName: "folder.fill")
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
            }
            Button("Select...") { selectFolder() }
          }
          
          if workingDirectory == nil {
            Label("Required: Select a project folder to focus the agent", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          #endif
        } header: {
          Text("Project")
        }
        
        // Template selection
        Section {
          Toggle("Use Template", isOn: $useTemplate)
          
          if useTemplate {
            Picker("Template", selection: $selectedTemplate) {
              Text("Select...").tag(nil as ChainTemplate?)
              
              Section("Built-in") {
                ForEach(ChainTemplate.builtInTemplates) { template in
                  HStack {
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
            
            // Template preview
            if let template = selectedTemplate {
              VStack(alignment: .leading, spacing: 8) {
                if !template.description.isEmpty {
                  Text(template.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
      }
      .formStyle(.grouped)
      .navigationTitle("New Chain")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
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

// MARK: - Chain Detail View

struct ChainDetailView: View {
  let chain: AgentChain
  @Bindable var agentManager: AgentManager
  @Bindable var cliService: CLIService
  @Bindable var sessionTracker: SessionTracker
  
  @State private var prompt = ""
  @State private var isRunning = false
  @State private var errorMessage: String?
  @State private var showingSaveTemplate = false
  
  /// Calculate total duration from run start time
  private var totalDuration: String? {
    guard let startTime = chain.runStartTime,
          case .complete = chain.state else { return nil }
    let elapsed = Date().timeIntervalSince(startTime)
    let minutes = Int(elapsed) / 60
    let seconds = Int(elapsed) % 60
    if minutes > 0 {
      return "\(minutes)m \(seconds)s"
    } else {
      return "\(seconds)s"
    }
  }
  
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
        
        // Working directory - REQUIRED
        #if os(macOS)
        GroupBox {
          HStack {
            Image(systemName: "folder.fill")
              .foregroundStyle(chain.workingDirectory == nil ? .orange : .green)
            Text("Project Folder")
              .font(.subheadline)
            Spacer()
            if let dir = chain.workingDirectory {
              Text(URL(fileURLWithPath: dir).lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
              Button {
                chain.workingDirectory = nil
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
            }
            Button("Select...") {
              selectFolder()
            }
            .buttonStyle(.bordered)
          }
          
          if chain.workingDirectory == nil {
            Label("Select a project folder to run the chain", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(.top, 4)
          }
        }
        #endif
        
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
        
        // Review loop settings (only show if there's a reviewer in the chain)
        if chain.agents.contains(where: { $0.role == .reviewer }) {
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Toggle(isOn: Binding(
                get: { chain.enableReviewLoop },
                set: { chain.enableReviewLoop = $0 }
              )) {
                Label("Enable Review Loop", systemImage: "arrow.triangle.2.circlepath")
              }
              
              if chain.enableReviewLoop {
                HStack {
                  Text("Max iterations:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Picker("", selection: Binding(
                    get: { chain.maxReviewIterations },
                    set: { chain.maxReviewIterations = $0 }
                  )) {
                    ForEach([1, 2, 3, 5], id: \.self) { num in
                      Text("\(num)").tag(num)
                    }
                  }
                  .pickerStyle(.segmented)
                  .frame(width: 150)
                }
                
                Text("If reviewer requests changes, re-run implementer with feedback")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        
        #if os(macOS)
        // Run button
        HStack {
          Button {
            // Save working directory for next time
            if let dir = chain.workingDirectory {
              agentManager.lastUsedWorkingDirectory = dir
            }
            Task { await runChain() }
          } label: {
            Label(isRunning ? "Running..." : "Run Chain", systemImage: isRunning ? "hourglass" : "play.fill")
          }
          .buttonStyle(.borderedProminent)
          .disabled(isRunning || prompt.isEmpty || chain.workingDirectory == nil)
          
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
        
        // Live status panel when running
        if isRunning {
          LiveStatusPanel(chain: chain)
        }
        
        // Completion banner (show when just completed)
        if case .complete = chain.state, !chain.results.isEmpty {
          GroupBox {
            HStack(spacing: 12) {
              Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
              VStack(alignment: .leading, spacing: 2) {
                Text("Chain Completed")
                  .font(.headline)
                  .foregroundStyle(.green)
                HStack {
                  Text("\(chain.results.count) agents")
                  Text("•")
                  Text(String(format: "%.1f× premium", chain.results.reduce(0.0) { $0 + $1.premiumCost }))
                  if let duration = totalDuration {
                    Text("•")
                    Text(duration)
                  }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              Spacer()
              
              Button {
                // Clear results to run again
                prompt = ""
              } label: {
                Label("New Task", systemImage: "plus")
              }
              .buttonStyle(.bordered)
            }
          }
          .background(Color.green.opacity(0.1))
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
            HStack {
              Label("Results", systemImage: "doc.text").font(.headline)
              Spacer()
              if case .complete = chain.state {
                Text("Completed")
                  .font(.caption)
                  .foregroundStyle(.green)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 2)
                  .background(Color.green.opacity(0.15))
                  .clipShape(Capsule())
              }
            }
            
            ForEach(chain.results) { result in
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(result.agentName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                  Text("(\(result.model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  
                  // Show review verdict if present
                  if let verdict = result.reviewVerdict {
                    Spacer()
                    HStack(spacing: 4) {
                      Image(systemName: verdict.iconName)
                      Text(verdict.displayName)
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(verdictColor(verdict))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(verdictColor(verdict).opacity(0.15))
                    .clipShape(Capsule())
                  }
                  
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
          
          // Save as template option (after successful run)
          if case .complete = chain.state {
            Divider()
            
            HStack {
              VStack(alignment: .leading) {
                Text("Save Configuration")
                  .font(.subheadline)
                  .fontWeight(.medium)
                Text("Save this chain as a reusable template")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              
              Spacer()
              
              Button {
                showingSaveTemplate = true
              } label: {
                Label("Save as Template", systemImage: "square.and.arrow.down")
              }
              .buttonStyle(.bordered)
            }
          }
        }
        #endif
        
        Spacer()
      }
      .padding()
    }
    .navigationTitle(chain.name)
    .sheet(isPresented: $showingSaveTemplate) {
      SaveTemplateSheet(chain: chain, agentManager: agentManager)
    }
    .onAppear {
      // Load last working directory if chain doesn't have one
      if chain.workingDirectory == nil {
        chain.workingDirectory = agentManager.lastUsedWorkingDirectory
      }
    }
  }
  
  #if os(macOS)
  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a project folder for this chain"
    panel.prompt = "Select"
    
    if panel.runModal() == .OK, let url = panel.url {
      chain.workingDirectory = url.path
      agentManager.lastUsedWorkingDirectory = url.path
    }
  }
  
  private func verdictColor(_ verdict: ReviewVerdict) -> Color {
    switch verdict {
    case .approved: return .green
    case .needsChanges: return .orange
    case .rejected: return .red
    }
  }
  
  private func runChain() async {
    isRunning = true
    defer { isRunning = false }  // Always reset, even on error
    
    errorMessage = nil
    chain.reset()
    chain.clearLiveStatus()
    chain.runStartTime = Date()
    chain.state = .running(agentIndex: 0)
    chain.addStatusMessage("Starting chain execution...", type: .info)
    
    do {
      // Run all agents in sequence
      try await runAgentsSequentially()
      
      // Check if we should do a review loop
      if chain.enableReviewLoop {
        try await runReviewLoop()
      }
      
      chain.state = .complete
      chain.addStatusMessage("✓ Chain completed successfully!", type: .complete)
      
      // Play completion sound
      #if os(macOS)
      NSSound.beep()
      #endif
      
      // Record to session tracker
      sessionTracker.recordChainRun(chain)
    } catch {
      errorMessage = error.localizedDescription
      chain.state = .failed(message: error.localizedDescription)
      chain.addStatusMessage("Error: \(error.localizedDescription)", type: .error)
    }
    
    isRunning = false
  }
  
  /// Run all agents in the chain sequentially
  private func runAgentsSequentially() async throws {
    for (index, agent) in chain.agents.enumerated() {
      chain.state = .running(agentIndex: index)
      chain.currentAgentStartTime = Date()
      chain.addStatusMessage("Starting \(agent.name) (\(agent.model.shortName))...", type: .progress)
      try await runSingleAgent(agent, at: index)
      chain.addStatusMessage("\(agent.name) completed", type: .complete)
    }
  }
  
  /// Run a single agent and record its result
  private func runSingleAgent(_ agent: Agent, at index: Int) async throws {
    // Get context from previous agents
    let context = chain.contextForAgent(at: index)
    
    // Build prompt with role instructions, framework hints, and context
    let fullPrompt = agent.buildPrompt(
      userPrompt: prompt,
      context: context.isEmpty ? nil : context
    )
    
    // Run the agent with streaming output
    let response = try await cliService.runCopilotSession(
      prompt: fullPrompt,
      model: agent.model,
      role: agent.role,
      workingDirectory: agent.workingDirectory ?? chain.workingDirectory,
      onOutput: { [chain] line in
        // Parse the streaming line for meaningful info
        let statusLine = parseStreamingLine(line)
        if let statusLine {
          chain.addStatusMessage(statusLine.message, type: statusLine.type)
        }
      }
    )
    
    // Parse premium cost from response
    var premiumCost = agent.model.premiumCost
    if let premiumStr = response.premiumRequests,
       let num = Double(premiumStr.components(separatedBy: " ").first ?? "") {
      premiumCost = num
    }
    
    // Parse review verdict if this is a reviewer
    var verdict: ReviewVerdict?
    if agent.role == .reviewer {
      verdict = ReviewVerdict.parse(from: response.content)
    }
    
    // Record result
    let result = AgentChainResult(
      agentId: agent.id,
      agentName: agent.name,
      model: agent.model.displayName,
      prompt: fullPrompt,
      output: response.content,
      duration: response.duration,
      premiumCost: premiumCost,
      reviewVerdict: verdict
    )
    chain.results.append(result)
  }
  
  /// Run the review loop if enabled and reviewer requests changes
  private func runReviewLoop() async throws {
    // Find the last reviewer result
    guard let initialReviewerResult = chain.results.last(where: { $0.reviewVerdict != nil }),
          let verdict = initialReviewerResult.reviewVerdict,
          verdict == .needsChanges else {
      // No reviewer or already approved
      return
    }
    
    // Find the implementer agent index
    guard let implementerIndex = chain.agents.firstIndex(where: { $0.role == .implementer }),
          let reviewerIndex = chain.agents.firstIndex(where: { $0.role == .reviewer }) else {
      return
    }
    
    let implementer = chain.agents[implementerIndex]
    let reviewer = chain.agents[reviewerIndex]
    
    // Track the latest feedback for each iteration
    var latestFeedback = initialReviewerResult.output
    
    // Loop until approved or max iterations reached
    while chain.currentReviewIteration < chain.maxReviewIterations {
      chain.currentReviewIteration += 1
      chain.state = .reviewing(iteration: chain.currentReviewIteration)
      
      // Build prompt with the latest review feedback
      let feedbackPrompt = """
        The reviewer has requested changes. Here is their feedback:
        
        \(latestFeedback)
        
        Please address the feedback and make the necessary changes.
        Original task: \(prompt)
        """
      
      // Temporarily override the prompt for the re-run
      let originalPrompt = prompt
      prompt = feedbackPrompt
      
      // Re-run implementer with feedback context
      try await runSingleAgent(implementer, at: implementerIndex)
      
      // Re-run reviewer on the new changes
      try await runSingleAgent(reviewer, at: reviewerIndex)
      
      // Restore original prompt
      prompt = originalPrompt
      
      // Check the new verdict
      if let newReviewerResult = chain.results.last(where: { $0.reviewVerdict != nil }),
         let newVerdict = newReviewerResult.reviewVerdict {
        if newVerdict == .approved {
          // Success! Exit the loop
          return
        } else if newVerdict == .rejected {
          // Hard rejection, stop trying
          throw ChainError.reviewRejected(reason: newReviewerResult.output)
        }
        // Update feedback for next iteration
        latestFeedback = newReviewerResult.output
      }
    }
    
    // Reached max iterations without approval
    errorMessage = "Review loop reached maximum iterations (\(chain.maxReviewIterations)) without approval"
  }
  
  /// Parse a streaming output line from copilot into a status message
  private func parseStreamingLine(_ line: String) -> (message: String, type: LiveStatusMessage.MessageType)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    
    // Skip empty lines
    guard !trimmed.isEmpty else { return nil }
    
    // Skip spinner/progress characters only
    if trimmed.count < 3 && (trimmed.contains("�") || trimmed.contains("●") || trimmed.contains("○") || trimmed.contains("◐")) {
      return nil
    }
    
    // Tool invocations - highlight these
    if trimmed.lowercased().contains("read_file") || trimmed.lowercased().contains("reading") {
      return ("📖 Reading file...", .tool)
    }
    if trimmed.lowercased().contains("write_file") || trimmed.lowercased().contains("writing") || 
       trimmed.lowercased().contains("editing") || trimmed.lowercased().contains("insert_edit") ||
       trimmed.lowercased().contains("replace_string") {
      return ("✏️ Editing file...", .tool)
    }
    if trimmed.lowercased().contains("run_in_terminal") || trimmed.lowercased().contains("running command") {
      return ("⚡ Running command...", .tool)
    }
    if trimmed.lowercased().contains("grep_search") || trimmed.lowercased().contains("searching") {
      return ("🔍 Searching...", .tool)
    }
    if trimmed.lowercased().contains("semantic_search") {
      return ("🧠 Semantic search...", .tool)
    }
    if trimmed.lowercased().contains("list_dir") {
      return ("📁 Listing directory...", .tool)
    }
    if trimmed.lowercased().contains("create_file") {
      return ("📝 Creating file...", .tool)
    }
    
    // Show the actual output - truncate if too long
    let displayLine = trimmed.count > 100 ? String(trimmed.prefix(97)) + "..." : trimmed
    return (displayLine, .progress)
  }
  
  /// Errors that can occur during chain execution
  enum ChainError: LocalizedError {
    case reviewRejected(reason: String)
    
    var errorDescription: String? {
      switch self {
      case .reviewRejected(let reason):
        return "Review rejected: \(reason.prefix(200))..."
      }
    }
  }
  #endif
}

// MARK: - Save Template Sheet

struct SaveTemplateSheet: View {
  let chain: AgentChain
  @Bindable var agentManager: AgentManager
  @Environment(\.dismiss) private var dismiss
  
  @State private var templateName = ""
  @State private var templateDescription = ""
  
  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Template Name", text: $templateName, prompt: Text(chain.name))
          TextField("Description (optional)", text: $templateDescription, axis: .vertical)
            .lineLimit(2...4)
        }
        
        Section("Agents in Template") {
          ForEach(Array(chain.agents.enumerated()), id: \.element.id) { index, agent in
            HStack {
              Text("\(index + 1).")
                .foregroundStyle(.secondary)
              Image(systemName: agent.role.iconName)
                .foregroundStyle(roleColor(agent.role))
              VStack(alignment: .leading) {
                Text(agent.name)
                  .font(.subheadline)
                Text(agent.model.shortName)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(agent.role.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        
        Section {
          Text("This template can be reused to quickly create new chains with the same agent configuration.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Save as Template")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            let name = templateName.isEmpty ? chain.name : templateName
            agentManager.saveChainAsTemplate(chain, name: name, description: templateDescription)
            dismiss()
          }
        }
      }
      .frame(minWidth: 400, minHeight: 350)
    }
  }
  
  private func roleColor(_ role: AgentRole) -> Color {
    switch role {
    case .planner: return .blue
    case .implementer: return .green
    case .reviewer: return .orange
    }
  }
}

// MARK: - Session Summary Sheet

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
              value: "\(sessionTracker.totalPremiumUsed)",
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
                      Text("\(record.totalPremium)× Premium")
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
        }
        
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button {
              exportMarkdown()
            } label: {
              Label("Export as Markdown", systemImage: "doc.text")
            }
            
            Button(role: .destructive) {
              sessionTracker.resetSession()
            } label: {
              Label("Reset Session", systemImage: "trash")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
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
    let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
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

// MARK: - Stat Card

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

// MARK: - Live Status Panel

struct LiveStatusPanel: View {
  let chain: AgentChain
  
  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        // Header with elapsed time
        HStack {
          Label("Live Status", systemImage: "bolt.fill")
            .font(.headline)
            .foregroundStyle(.blue)
          
          Spacer()
          
          if let startTime = chain.runStartTime {
            ElapsedTimeView(startTime: startTime)
          }
        }
        
        // Progress indicator
        HStack(spacing: 2) {
          ForEach(Array(chain.agents.enumerated()), id: \.element.id) { index, agent in
            VStack(spacing: 4) {
              RoundedRectangle(cornerRadius: 3)
                .fill(progressColor(for: index))
                .frame(height: 6)
              
              Text(agent.role.displayName)
                .font(.caption2)
                .foregroundStyle(index == currentAgentIndex ? .primary : .secondary)
            }
          }
        }
        
        Divider()
        
        // Status messages log
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
              ForEach(chain.liveStatusMessages) { message in
                HStack(alignment: .top, spacing: 6) {
                  Image(systemName: message.type.icon)
                    .font(.caption2)
                    .foregroundStyle(messageColor(message.type))
                    .frame(width: 12)
                  
                  Text(message.message)
                    .font(.caption)
                    .foregroundStyle(message.type == .error ? .red : .primary)
                  
                  Spacer()
                  
                  Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .id(message.id)
              }
            }
          }
          .frame(maxHeight: 120)
          .onChange(of: chain.liveStatusMessages.count) { _, _ in
            if let lastMessage = chain.liveStatusMessages.last {
              withAnimation {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
              }
            }
          }
        }
        
        // Current agent status
        if let currentAgent = currentRunningAgent {
          HStack {
            ProgressView()
              .scaleEffect(0.6)
            Text("Running: \(currentAgent.name)")
              .font(.caption)
              .foregroundStyle(.secondary)
            
            if let agentStart = chain.currentAgentStartTime {
              Text("•")
                .foregroundStyle(.tertiary)
              ElapsedTimeView(startTime: agentStart)
                .font(.caption)
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
    .background(Color.blue.opacity(0.05))
  }
  
  private var currentAgentIndex: Int {
    if case .running(let idx) = chain.state { return idx }
    return -1
  }
  
  private var currentRunningAgent: Agent? {
    if case .running(let idx) = chain.state, idx < chain.agents.count {
      return chain.agents[idx]
    }
    return nil
  }
  
  private func progressColor(for index: Int) -> Color {
    let currentIdx = currentAgentIndex
    if index < currentIdx { return .green }
    if index == currentIdx { return .blue }
    return .secondary.opacity(0.3)
  }
  
  private func messageColor(_ type: LiveStatusMessage.MessageType) -> Color {
    switch type {
    case .info: return .secondary
    case .tool: return .purple
    case .progress: return .blue
    case .error: return .red
    case .complete: return .green
    }
  }
}

// MARK: - Elapsed Time View

struct ElapsedTimeView: View {
  let startTime: Date
  @State private var elapsed: TimeInterval = 0
  
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  
  var body: some View {
    Text(formattedElapsed)
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .onReceive(timer) { _ in
        elapsed = Date().timeIntervalSince(startTime)
      }
      .onAppear {
        elapsed = Date().timeIntervalSince(startTime)
      }
  }
  
  private var formattedElapsed: String {
    let minutes = Int(elapsed) / 60
    let seconds = Int(elapsed) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}
#endif

#Preview {
  Agents_RootView()
}
