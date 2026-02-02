// SwarmStatusView.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// SwiftUI view showing swarm status and connected workers.

import SwiftUI
import os.log

/// View showing distributed swarm status
public struct SwarmStatusView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @State private var coordinator = SwarmCoordinator.shared
  @State private var delegateWrapper = SwarmStatusCoordinatorWrapper()
  @State private var errorMessage: String?
  @State private var taskLog: [String] = []
  @State private var displayName: String = ""
  
  public init() {}
  
  public var body: some View {
    VStack(spacing: 0) {
      headerSection
      
      Divider()
      
      if coordinator.isActive {
        activeContent
      } else {
        inactiveContent
      }
    }
    .onAppear {
      delegateWrapper.onEvent = { event in
        handleEvent(event)
      }
      coordinator.delegate = delegateWrapper
      displayName = WorkerCapabilities.configuredDisplayName() ?? ""
    }
    .frame(minWidth: 400, minHeight: 300)
    #if os(macOS)
    .toolbar {
      ToolSelectionToolbar()
    }
    #endif
  }
  
  // MARK: - Header
  
  private var headerSection: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Distributed Swarm")
          .font(.headline)
        
        HStack(spacing: 4) {
          Circle()
            .fill(coordinator.isActive ? Color.green : Color.secondary)
            .frame(width: 8, height: 8)
          
          Text(coordinator.isActive ? "Active (\(roleDisplayName))" : "Inactive")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      
      Spacer()
      
      if coordinator.isActive {
        Button("Stop") {
          stopSwarm()
        }
      } else {
        Menu {
          Button("Start as Crown") {
            startSwarm(role: .brain)
          }
          Button("Start as Peel") {
            startSwarm(role: .worker)
          }
          Button("Start as Crown + Peel") {
            startSwarm(role: .hybrid)
          }
        } label: {
          Text("Start")
        }
        .menuStyle(.borderlessButton)
      }
    }
    .padding()
  }
  
  // MARK: - Active Content
  
  @ViewBuilder
  private var activeContent: some View {
    HSplitView {
      // Workers list
      workersSection
        .frame(minWidth: 200)
      
      // Task log
      taskLogSection
        .frame(minWidth: 200)
    }
  }
  
  private var workersSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Local stats at top
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Role:")
          Spacer()
          Text(roleDisplayName)
            .foregroundStyle(.secondary)
        }
        if coordinator.role == .worker {
          HStack {
            Text("Current Task:")
            Spacer()
            Text(coordinator.currentTask?.id.uuidString.prefix(8).description ?? "Idle")
              .foregroundStyle(.secondary)
          }
        }
        HStack {
          Text("Tasks Completed:")
          Spacer()
          Text("\(coordinator.tasksCompleted)")
            .foregroundStyle(.secondary)
        }
        HStack {
          Text("Tasks Failed:")
          Spacer()
          Text("\(coordinator.tasksFailed)")
            .foregroundStyle(coordinator.tasksFailed > 0 ? .red : .secondary)
        }
        Divider()
      }
      .font(.caption)
      .padding(.horizontal)
      .padding(.top)
      
      // Title adapts based on role
      Text(sectionTitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
      
      if coordinator.connectedWorkers.isEmpty {
        Text(emptyStateDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal)
        Spacer()
      } else {
        List(coordinator.connectedWorkers, id: \.id) { worker in
          PeerRow(peer: worker, role: coordinator.role, status: coordinator.workerStatuses[worker.id])
        }
        .listStyle(.plain)
      }
    }
  }
  
  // MARK: - Role-Aware Labels
  
  private var sectionTitle: String {
    switch coordinator.role {
    case .brain:
      return "Connected Peels"
    case .worker:
      return "Connected to Crown"
    case .hybrid:
      return "Connected Peers"
    }
  }
  
  private var emptyStateTitle: String {
    switch coordinator.role {
    case .brain:
      return "No Peels"
    case .worker:
      return "No Crown Connected"
    case .hybrid:
      return "No Peers"
    }
  }
  
  private var emptyStateIcon: String {
    switch coordinator.role {
    case .brain:
      return "desktopcomputer.trianglebadge.exclamationmark"
    case .worker:
      return "crown"
    case .hybrid:
      return "network"
    }
  }
  
  private var emptyStateDescription: String {
    switch coordinator.role {
    case .brain:
      return "Waiting for peels to connect..."
    case .worker:
      return "Waiting for crown to connect..."
    case .hybrid:
      return "Waiting for peers to connect..."
    }
  }
  
  private var taskLogSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Task Log")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        
        Spacer()
        
        Button("Clear") {
          taskLog.removeAll()
        }
        .buttonStyle(.borderless)
        .font(.caption)
      }
      .padding(.horizontal)
      .padding(.top)
      
      if taskLog.isEmpty {
        Text("Task activity will appear here")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal)
        Spacer()
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
              ForEach(Array(taskLog.enumerated()), id: \.offset) { index, entry in
                Text(entry)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .id(index)
              }
            }
            .padding(.horizontal)
          }
          .onChange(of: taskLog.count) { _, newCount in
            withAnimation {
              proxy.scrollTo(newCount - 1, anchor: .bottom)
            }
          }
        }
      }
    }
  }
  
  // MARK: - Inactive Content
  
  private var inactiveContent: some View {
    VStack(spacing: 16) {
      Spacer()
      
      Image(systemName: "network")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      
      Text("Distributed Swarm")
        .font(.title2)
      
      Text("Connect multiple Peel instances to parallelize agent work across your local network.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 300)
      
      // Display name configuration
      HStack {
        Text("Display Name:")
          .foregroundStyle(.secondary)
        TextField("e.g. Mac Studio, Supreme Overlord", text: $displayName)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 200)
          .onSubmit {
            WorkerCapabilities.saveDisplayName(displayName.isEmpty ? nil : displayName)
          }
          .onChange(of: displayName) { _, newValue in
            WorkerCapabilities.saveDisplayName(newValue.isEmpty ? nil : newValue)
          }
      }
      .padding(.horizontal)
      
      if let error = errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.horizontal)
      }
      
      Spacer()
      
      VStack(alignment: .leading, spacing: 8) {
        Text("Quick Start:")
          .font(.caption.bold())
        
        Text("• **Crown**: Dispatches work to other machines")
        Text("• **Peel**: Executes work from the Crown")
        Text("• **Crown + Peel**: Does both")
        
        Text("\nOr run from terminal:")
          .font(.caption.bold())
          .padding(.top, 4)
        
        Text("`Peel.app/Contents/MacOS/Peel --worker`")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .padding()
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      .padding()
      
      Spacer()
    }
  }
  
  // MARK: - Actions
  
  private func startSwarm(role: SwarmRole) {
    errorMessage = nil
    coordinator.delegate = delegateWrapper
    
    // Configure chain executor for worker/hybrid roles so they can actually execute chains
    if role == .worker || role == .hybrid {
      mcpServer.configureSwarmExecutor()
    }
    
    do {
      try coordinator.start(role: role)
      log("Swarm started as \(roleDisplayName)")
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func stopSwarm() {
    coordinator.stop()
    log("Swarm stopped")
  }
  
  private func handleEvent(_ event: SwarmEvent) {
    switch event {
    case .workerConnected(let peer):
      log("\(peerRoleLabel) connected: \(peer.name)")
      
    case .workerDisconnected(let id):
      log("\(peerRoleLabel) disconnected: \(id)")
      
    case .taskReceived(let request):
      log("Task received: \(request.id)")
      log("  Template: \(request.templateName)")
      log("  Prompt: \(request.prompt.prefix(100))...")
      
    case .taskStarted(let id):
      log("Task started: \(id)")
      
    case .taskCompleted(let result):
      log("Task completed: \(result.requestId) (\(String(format: "%.2fs", result.duration)))")
      log("  Status: \(result.status.rawValue)")
      log("  Peel: \(result.workerDeviceName)")
      if !result.outputs.isEmpty {
        log("  Outputs: \(result.outputs.count) items")
        for output in result.outputs.prefix(3) {
          let content = output.content ?? "(no content)"
          let preview = content.prefix(200).replacingOccurrences(of: "\n", with: " ")
          log("    [\(output.name)] \(preview)...")
        }
      }
      if let error = result.errorMessage {
        log("  Error: \(error)")
      }
      
    case .taskFailed(let id, let error):
      log("Task failed: \(id) - \(error.localizedDescription)")
    }
  }
  
  private func log(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    taskLog.append("[\(timestamp)] \(message)")
  }
}

// MARK: - Peer Row

struct PeerRow: View {
  let peer: ConnectedPeer
  let role: SwarmRole
  let status: WorkerStatus?
  
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: peerIcon)
        .foregroundStyle(iconColor)
      
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(peer.displayName)
            .font(.body)
            .help(peer.name)  // Show hostname on hover
          if role == .worker {
            Text("(Crown)")
              .font(.caption)
              .foregroundStyle(.blue)
          }
        }
        
        Text("\(peer.capabilities.gpuCores) GPU • \(peer.capabilities.neuralEngineCores) Neural • \(peer.capabilities.memoryGB)GB")
          .font(.caption)
          .foregroundStyle(.secondary)

        if let rag = status?.ragArtifacts {
          if let staleReason = rag.staleReason {
            Text("RAG stale • \(staleReason)")
              .font(.caption2)
              .foregroundStyle(.orange)
          } else if let lastSyncedAt = rag.lastSyncedAt {
            HStack(spacing: 4) {
              Text("RAG synced")
              RelativeTimeText(lastSyncedAt)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
          } else {
            Text("RAG artifacts: \(rag.manifestVersion)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      
      Spacer()
      
      Circle()
        .fill(Color.green)
        .frame(width: 6, height: 6)
    }
    .padding(.vertical, 4)
  }
  
  private var peerIcon: String {
    if role == .worker {
      // We're a peel, so connected peer is the crown
      return "crown"
    } else {
      // We're crown/hybrid, so this is a peel
      return peer.capabilities.gpuCores > 30 ? "desktopcomputer" : "laptopcomputer"
    }
  }
  
  private var iconColor: Color {
    role == .worker ? .blue : .secondary
  }
}

// MARK: - Labels

private extension SwarmStatusView {
  var roleDisplayName: String {
    switch coordinator.role {
    case .brain:
      return "Crown"
    case .worker:
      return "Peel"
    case .hybrid:
      return "Crown + Peel"
    }
  }
  
  var peerRoleLabel: String {
    coordinator.role == .worker ? "Crown" : "Peel"
  }
}

// MARK: - Coordinator Wrapper

/// Wrapper to handle delegate callbacks from SwarmCoordinator
@MainActor
final class SwarmStatusCoordinatorWrapper: SwarmCoordinatorDelegate {
  var onEvent: ((SwarmEvent) -> Void)?
  
  func swarmCoordinator(_ coordinator: SwarmCoordinator, didEmit event: SwarmEvent) {
    onEvent?(event)
  }
  
  func swarmCoordinator(_ coordinator: SwarmCoordinator, shouldExecute request: ChainRequest) -> Bool {
    return true
  }
}

#Preview {
  SwarmStatusView()
    .frame(width: 600, height: 400)
}
