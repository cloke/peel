// SwarmStatusView.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// SwiftUI view showing swarm status and connected workers.

import SwiftUI
import os.log

/// View showing distributed swarm status
public struct SwarmStatusView: View {
  @State private var coordinator: SwarmCoordinator?
  @State private var delegateWrapper = SwarmStatusCoordinatorWrapper()
  @State private var isActive = false
  @State private var errorMessage: String?
  @State private var taskLog: [String] = []
  
  public init() {}
  
  public var body: some View {
    VStack(spacing: 0) {
      headerSection
      
      Divider()
      
      if isActive {
        activeContent
      } else {
        inactiveContent
      }
    }
    .onAppear {
      delegateWrapper.onEvent = { event in
        handleEvent(event)
      }
    }
    .frame(minWidth: 400, minHeight: 300)
  }
  
  // MARK: - Header
  
  private var headerSection: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Distributed Swarm")
          .font(.headline)
        
        HStack(spacing: 4) {
          Circle()
            .fill(isActive ? Color.green : Color.secondary)
            .frame(width: 8, height: 8)
          
          Text(isActive ? "Active" : "Inactive")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      
      Spacer()
      
      if isActive {
        Button("Stop") {
          stopSwarm()
        }
      } else {
        Menu {
          Button("Start as Brain") {
            startSwarm(role: .brain)
          }
          Button("Start as Worker") {
            startSwarm(role: .worker)
          }
          Button("Start as Hybrid") {
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
      Text("Connected Workers")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.top)
      
      if let coordinator = coordinator {
        if coordinator.connectedWorkers.isEmpty {
          ContentUnavailableView {
            Label("No Workers", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
          } description: {
            Text("Waiting for workers to connect...")
          }
        } else {
          List(coordinator.connectedWorkers, id: \.id) { worker in
            WorkerRow(worker: worker)
          }
          .listStyle(.plain)
        }
      }
      
      Spacer()
      
      // Local stats
      if let coordinator = coordinator {
        VStack(alignment: .leading, spacing: 4) {
          Divider()
          HStack {
            Text("Role:")
            Spacer()
            Text(coordinator.role.rawValue.capitalized)
              .foregroundStyle(.secondary)
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
        }
        .font(.caption)
        .padding()
      }
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
        ContentUnavailableView {
          Label("No Activity", systemImage: "clock")
        } description: {
          Text("Task activity will appear here")
        }
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
        
        Text("• **Brain**: Dispatches work to other machines")
        Text("• **Worker**: Executes work from brain")
        Text("• **Hybrid**: Does both")
        
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
    
    let newCoordinator = SwarmCoordinator(
      role: role,
      capabilities: WorkerCapabilities.current()
    )
    newCoordinator.delegate = delegateWrapper
    
    do {
      try newCoordinator.start()
      coordinator = newCoordinator
      isActive = true
      log("Swarm started as \(role.rawValue)")
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func stopSwarm() {
    coordinator?.stop()
    coordinator = nil
    isActive = false
    log("Swarm stopped")
  }
  
  private func handleEvent(_ event: SwarmEvent) {
    switch event {
    case .workerConnected(let peer):
      log("Worker connected: \(peer.name)")
      
    case .workerDisconnected(let id):
      log("Worker disconnected: \(id)")
      
    case .taskReceived(let request):
      log("Task received: \(request.id)")
      
    case .taskStarted(let id):
      log("Task started: \(id)")
      
    case .taskCompleted(let result):
      log("Task completed: \(result.requestId) (\(String(format: "%.2fs", result.duration)))")
      
    case .taskFailed(let id, let error):
      log("Task failed: \(id) - \(error.localizedDescription)")
    }
  }
  
  private func log(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    taskLog.append("[\(timestamp)] \(message)")
  }
}

// MARK: - Worker Row

struct WorkerRow: View {
  let worker: ConnectedPeer
  
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: worker.capabilities.gpuCores > 0 ? "desktopcomputer" : "laptopcomputer")
        .foregroundStyle(.secondary)
      
      VStack(alignment: .leading, spacing: 2) {
        Text(worker.name)
          .font(.body)
        
        Text("\(worker.capabilities.gpuCores) GPU • \(worker.capabilities.neuralEngineCores) Neural • \(worker.capabilities.memoryGB)GB")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      Circle()
        .fill(Color.green)
        .frame(width: 6, height: 6)
    }
    .padding(.vertical, 4)
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
