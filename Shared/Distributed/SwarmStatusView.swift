// SwarmStatusView.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// SwiftUI view showing swarm status and connected workers.

import SwiftUI
import SwiftData
import os.log

/// View showing distributed swarm status
public struct SwarmStatusView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(\.modelContext) private var modelContext
  private var coordinator: SwarmCoordinator { .shared }
  private var firebaseService: FirebaseService { .shared }
  @State private var delegateWrapper = SwarmStatusCoordinatorWrapper()
  @State private var errorMessage: String?
  @State private var taskLog: [String] = []
  @State private var selectedTask: ChainResult? = nil
  @State private var displayName: String = ""
  @State private var messageText: String = ""
  @State private var isSendingMessage = false
  @State private var loggedMessageIds = Set<String>()
  @Query(filter: #Predicate<TrackedWorktree> { $0.source == "swarm" },
         sort: \TrackedWorktree.createdAt, order: .reverse)
  private var swarmWorktrees: [TrackedWorktree]
  @State private var diskSizes: [String: Int64] = [:]
  @State private var firestoreWorkersListening = false
  
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
      // Start Firestore worker listeners so we see WAN workers
      // Guard: only start if active AND listeners not already running
      if coordinator.isActive && !firestoreWorkersListening {
        firestoreWorkersListening = true
        startFirestoreWorkerListeners()
      }
    }
    .frame(minWidth: 400, minHeight: 300)

  }
  
  // MARK: - Header
  
  private var headerSection: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text("Distributed Swarm")
            .font(.headline)
          
          if FirebaseService.shared.isUsingEmulators {
            Text("EMULATOR")
              .font(.caption2.bold())
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.orange.opacity(0.2))
              .foregroundStyle(.orange)
              .clipShape(RoundedRectangle(cornerRadius: 4))
              .help("Connected to local Firebase emulator at \(FirebaseService.shared.emulatorHost ?? "localhost")")
          }
        }
        
        HStack(spacing: 6) {
          Circle()
            .fill(coordinator.isActive ? Color.green : Color.secondary)
            .frame(width: 8, height: 8)
          
          VStack(alignment: .leading, spacing: 0) {
            Text(coordinator.isActive ? "Active (\(roleDisplayName))" : "Inactive")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
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

      // Swarm worktrees (brain/hybrid only) or completed tasks (worker)
      if coordinator.role == .worker {
        completedTasksSection
          .frame(minWidth: 180)
      } else {
        worktreesSection
          .frame(minWidth: 180)
      }
      
      // Task log + messages
      VStack(spacing: 0) {
        taskLogSection
        
        Divider()
        
        messageInputBar
      }
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
      
      if coordinator.connectedWorkers.isEmpty && remoteFirestoreWorkers.isEmpty {
        Text(emptyStateDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal)
        Spacer()
      } else {
        List {
          // LAN Peers
          if !coordinator.connectedWorkers.isEmpty {
            Section {
              ForEach(coordinator.connectedWorkers, id: \.id) { worker in
                PeerRow(peer: worker, role: coordinator.role, status: coordinator.workerStatuses[worker.id])
              }
            } header: {
              Label("LAN", systemImage: "wifi")
                .font(.caption.bold())
            }
          }

          // Firestore/WAN Workers (excluding self and LAN-connected peers)
          if !remoteFirestoreWorkers.isEmpty {
            Section {
              ForEach(remoteFirestoreWorkers) { worker in
                FirestoreWorkerRow(worker: worker)
              }
            } header: {
              Label("Swarm (\(remoteFirestoreWorkers.count))", systemImage: "globe")
                .font(.caption.bold())
            }
          }
        }
        .listStyle(.plain)
      }
    }
  }

  // MARK: - Worktrees Section

  private var worktreesSection: some View {
    let cutoff = Date().addingTimeInterval(-7200)
    let visible = swarmWorktrees.filter {
      $0.taskStatus == TrackedWorktree.Status.active ||
      ($0.completedAt.map { $0 > cutoff } ?? false)
    }
    let activeCount = swarmWorktrees.filter { $0.taskStatus == TrackedWorktree.Status.active }.count

    return VStack(alignment: .leading, spacing: 0) {
      DisclosureGroup {
        if visible.isEmpty {
          Text("No swarm worktrees recently")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)
        } else {
          ForEach(visible) { wt in
            HStack(spacing: 6) {
              Text(wt.taskId.isEmpty ? "–" : String(wt.taskId.prefix(8)))
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
              Text(wt.branch.hasPrefix("swarm/") ? String(wt.branch.dropFirst(6)) : wt.branch)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer()
              Circle()
                .fill(statusColor(wt.taskStatus))
                .frame(width: 7, height: 7)
              Text(relativeAge(from: wt.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
              if let bytes = diskSizes[wt.localPath] {
                Text("\(bytes / 1_048_576) MB")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal)
            .padding(.vertical, 2)
            .task(id: wt.localPath) {
              diskSizes[wt.localPath] = SwarmWorktreeManager.calculateDiskSize(for: wt.localPath)
            }
          }
        }
      } label: {
        HStack {
          Text("Worktrees")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          if activeCount > 0 {
            Text("(\(activeCount) active)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
      }
      Spacer()
    }
  }

  private var completedTasksSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      DisclosureGroup {
        if coordinator.completedResults.isEmpty {
          Text("No completed tasks yet")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)
        } else {
          List(coordinator.completedResults) { result in
            HStack(spacing: 6) {
              Image(systemName: result.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.status == .completed ? Color.green : .red)
                .font(.caption)
              VStack(alignment: .leading, spacing: 1) {
                Text(result.requestId.uuidString.prefix(8))
                  .font(.caption.monospaced())
                Text(String(format: "%.1fs", result.duration))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(result.completedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedTask = result }
          }
          .listStyle(.plain)
        }
      } label: {
        HStack {
          Text("Completed Tasks")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          if !coordinator.completedResults.isEmpty {
            Text("(\(coordinator.completedResults.count))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
      }
      Spacer()
    }
    .sheet(item: $selectedTask) { result in
      SwarmTaskOutputSheet(result: result)
    }
  }

  private func statusColor(_ status: String) -> Color {
    switch status {
    case TrackedWorktree.Status.active:    return .green
    case TrackedWorktree.Status.committed: return .blue
    case TrackedWorktree.Status.failed:    return .red
    default:                               return .gray
    }
  }

  private func relativeAge(from date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
  }

  /// Firestore workers excluding self and any already shown as LAN peers
  private var remoteFirestoreWorkers: [FirestoreWorker] {
    let localDeviceId = coordinator.capabilities.deviceId
    let lanPeerIds = Set(coordinator.connectedWorkers.map { $0.id })
    return firebaseService.swarmWorkers.filter { worker in
      worker.id != localDeviceId && !lanPeerIds.contains(worker.id)
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
      // Persist the chosen role so auto-start uses it next launch
      persistSwarmRole(role)
      startFirestoreWorkerListeners()
      log("Swarm started as \(roleDisplayName)")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func persistSwarmRole(_ role: SwarmRole) {
    let descriptor = FetchDescriptor<DeviceSettings>()
    if let settings = try? modelContext.fetch(descriptor).first {
      settings.swarmRole = role.rawValue
      try? modelContext.save()
    }
  }

  private func startFirestoreWorkerListeners() {
    guard firebaseService.isSignedIn else { return }
    Task {
      // Resolve WAN address so peers can connect to us across networks
      let wanAddress = await WANAddressResolver.resolve()
      SwarmCoordinator.shared.setResolvedWANAddress(wanAddress)
      let capabilities = WorkerCapabilities.current(
        wanAddress: wanAddress,
        wanPort: 8766
      )
      for swarm in firebaseService.memberSwarms where swarm.role.canRegisterWorkers {
        _ = try? await firebaseService.registerWorker(swarmId: swarm.id, capabilities: capabilities)
        firebaseService.startWorkerListener(swarmId: swarm.id)
        firebaseService.startMessageListener(swarmId: swarm.id)
      }
    }
  }

  // MARK: - Message Input

  private var messageInputBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "megaphone")
        .foregroundStyle(.secondary)
        .font(.caption)

      TextField("Broadcast to swarm...", text: $messageText)
        .textFieldStyle(.plain)
        .font(.caption)
        .onSubmit { sendBroadcast() }

      Button {
        sendBroadcast()
      } label: {
        Image(systemName: "paperplane.fill")
          .font(.caption)
      }
      .buttonStyle(.borderless)
      .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty || isSendingMessage)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .onChange(of: firebaseService.swarmMessages) { _, messages in
      loggedMessageIds.formIntersection(Set(messages.map(\.id)))
      for message in messages where !loggedMessageIds.contains(message.id) {
        let prefix = message.isBroadcast ? "\u{1F4E2}" : "\u{1F4AC}"
        log("\(prefix) \(message.senderName): \(message.text)")
        loggedMessageIds.insert(message.id)
      }
    }
  }

  private func sendBroadcast() {
    let text = messageText.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    isSendingMessage = true
    messageText = ""

    Task {
      for swarm in firebaseService.memberSwarms where swarm.role.canRegisterWorkers {
        try? await firebaseService.sendMessage(swarmId: swarm.id, text: text)
      }
      log("\u{1F4E8} You: \(text)")
      isSendingMessage = false
    }
  }
  
  private func stopSwarm() {
    // Unregister from Firestore and stop listeners
    if firebaseService.isSignedIn {
      Task {
        for swarm in firebaseService.memberSwarms {
          try? await firebaseService.unregisterWorker(swarmId: swarm.id)
          firebaseService.stopWorkerListener(swarmId: swarm.id)
          firebaseService.stopMessageListener(swarmId: swarm.id)
        }
      }
    }
    coordinator.stop()
    firestoreWorkersListening = false
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
            Text("RAG synced \(lastSyncedAt, format: .relative(presentation: .named))")
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
        .fill(statusColor)
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

  private var statusColor: Color {
    switch status?.state {
    case .idle:
      return .green
    case .busy:
      return .blue
    case .offline:
      return .orange
    case .error:
      return .red
    case nil:
      return .secondary
    }
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

// MARK: - Firestore Worker Row

struct FirestoreWorkerRow: View {
  let worker: FirestoreWorker
  @State private var isConnecting = false
  @State private var connectError: String?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "globe")
        .foregroundStyle(.blue)

      VStack(alignment: .leading, spacing: 2) {
        Text(worker.displayName)
          .font(.body)
          .help(worker.deviceName)

        HStack(spacing: 4) {
          if let version = worker.version {
            Text("v\(version) • \(worker.lastHeartbeat, format: .relative(presentation: .named))")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text(worker.lastHeartbeat, format: .relative(presentation: .named))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 4) {
          if worker.hasWANEndpoint {
            Label("WAN", systemImage: "network")
              .font(.caption2)
              .foregroundStyle(.blue)
          }
          if worker.hasSTUNEndpoint {
            Label("STUN", systemImage: "arrow.triangle.2.circlepath")
              .font(.caption2)
              .foregroundStyle(.cyan)
          }
          if !worker.hasWANEndpoint && !worker.hasSTUNEndpoint {
            Label("Relay only", systemImage: "icloud")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        if let connectError {
          Text(connectError)
            .font(.caption2)
            .foregroundStyle(.red)
            .lineLimit(2)
        }
      }

      Spacer()

      if isConnecting {
        ProgressView()
          .controlSize(.small)
      } else if worker.status == .online && !worker.isStale {
        Button("Connect") {
          isConnecting = true
          connectError = nil
          Task {
            do {
              try await SwarmCoordinator.shared.connectToWANWorker(worker)
            } catch {
              connectError = error.localizedDescription
            }
            isConnecting = false
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
    }
    .padding(.vertical, 4)
  }

  private var statusColor: Color {
    if worker.isStale {
      return .orange
    }
    switch worker.status {
    case .online:
      return .green
    case .busy:
      return .blue
    case .offline:
      return .orange
    }
  }
}

#Preview {
  SwarmStatusView()
    .frame(width: 600, height: 400)
}
