//
//  SwarmWorkersView.swift
//  Peel
//
//  Workers list, worker row, message sheet, and quick message button for swarm workers
//

import SwiftUI

// MARK: - Workers List View

@MainActor
struct WorkersListView: View {
  let swarmId: String
  let myRole: SwarmPermissionRole
  private var firebaseService: FirebaseService { .shared }
  private var swarm: SwarmCoordinator { .shared }
  @State private var showingMessageSheet = false
  @State private var selectedWorker: FirestoreWorker?
  @State private var messageText = ""
  @State private var messageSent = false

  var body: some View {
    VStack(spacing: 0) {
      // Info banner explaining how Firestore swarm works
      if !firebaseService.swarmWorkers.isEmpty {
        firestoreInfoBanner
      }

      // Quick action bar
      HStack {
        Text("\(onlineWorkerCount) workers online")
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        if myRole.canSubmitTasks {
          Button {
            selectedWorker = nil
            showingMessageSheet = true
          } label: {
            Label("Broadcast", systemImage: "megaphone")
          }
          .buttonStyle(.bordered)
          .help("Send message to all workers")
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)

      Divider()

      if firebaseService.swarmWorkers.isEmpty {
        ContentUnavailableView(
          "No Workers Online",
          systemImage: "desktopcomputer",
          description: Text("Workers automatically connect when they join this swarm. Click 'Join Swarm' in the sidebar to participate.")
        )
      } else {
        List(firebaseService.swarmWorkers, id: \.id) { worker in
          WorkerRow(
            worker: worker,
            tcpHeartbeat: tcpHeartbeat(for: worker),
            canMessage: myRole.canSubmitTasks,
            onMessage: {
              selectedWorker = worker
              showingMessageSheet = true
            }
          )
        }
      }
    }
    .task {
      firebaseService.startWorkerListener(swarmId: swarmId)
    }
    .sheet(isPresented: $showingMessageSheet) {
      SendMessageSheet(
        worker: selectedWorker,
        swarmId: swarmId,
        messageText: $messageText,
        onSend: sendMessage
      )
    }
    .alert("Message Sent", isPresented: $messageSent) {
      Button("OK") { }
    } message: {
      Text("Your message has been queued for delivery.")
    }
  }

  // MARK: - Firestore Info Banner

  @ViewBuilder
  private var firestoreInfoBanner: some View {
    HStack(spacing: 12) {
      Image(systemName: "cloud.fill")
        .font(.title3)
        .foregroundStyle(.blue)

      VStack(alignment: .leading, spacing: 2) {
        Text("Cloud Coordinated")
          .font(.caption)
          .fontWeight(.medium)

        Text("Workers communicate via Firestore - no network config needed")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.blue.opacity(0.05))
  }

  /// If this Firestore worker is also TCP-connected, return the TCP heartbeat date.
  private func tcpHeartbeat(for worker: FirestoreWorker) -> Date? {
    if let status = swarm.workerStatuses[worker.id] {
      return status.lastHeartbeat
    }
    if swarm.connectedWorkers.contains(where: { $0.id == worker.id }) {
      return Date() // TCP connected but no status yet — treat as now
    }
    return nil
  }

  /// Count workers that are online: not offline via Firestore OR TCP-connected.
  private var onlineWorkerCount: Int {
    firebaseService.swarmWorkers.filter { worker in
      !worker.isStale || tcpHeartbeat(for: worker) != nil
    }.count
  }

  private func sendMessage() {
    guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

    Task {
      do {
        try await firebaseService.sendMessage(
          swarmId: swarmId,
          text: messageText,
          targetWorkerId: selectedWorker?.id
        )
      } catch {
        print("Failed to send message: \(error)")
      }
      messageText = ""
      showingMessageSheet = false
      messageSent = true
    }
  }
}

// MARK: - Worker Row

struct WorkerRow: View {
  let worker: FirestoreWorker
  /// TCP heartbeat override — when non-nil, this worker is LAN-connected
  /// and the TCP heartbeat is more current than the Firestore one.
  var tcpHeartbeat: Date? = nil
  let canMessage: Bool
  let onMessage: () -> Void

  private var isLANConnected: Bool { tcpHeartbeat != nil }
  private var effectiveOffline: Bool { isLANConnected ? false : worker.isStale }
  private var effectiveLastSeen: Date { tcpHeartbeat ?? worker.lastHeartbeat }

  var body: some View {
    HStack {
      // Status indicator
      Circle()
        .fill(effectiveOffline ? .orange : .green)
        .frame(width: 8, height: 8)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(worker.displayName)
            .fontWeight(.medium)
          if isLANConnected {
            Text("LAN")
              .font(.caption2.bold())
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color.green.opacity(0.15))
              .foregroundStyle(.green)
              .clipShape(Capsule())
          }
        }

        HStack(spacing: 8) {
          Text(worker.deviceName)
            .font(.caption)
            .foregroundStyle(.secondary)

          if let version = worker.version {
            Text("v\(version)")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }

        Text("Last seen \(effectiveLastSeen.formatted(.relative(presentation: .named)))")
          .font(.caption2)
          .foregroundStyle(effectiveOffline ? Color.orange : Color.secondary)
      }

      Spacer()

      // Status badge
      Text(isLANConnected ? "Connected" : worker.status.rawValue.capitalized)
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(effectiveOffline ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
        .foregroundStyle(effectiveOffline ? .orange : .green)
        .clipShape(Capsule())

      if canMessage {
        Button {
          onMessage()
        } label: {
          Image(systemName: "message")
        }
        .buttonStyle(.borderless)
        .help("Send message to this worker")
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Send Message Sheet

struct SendMessageSheet: View {
  let worker: FirestoreWorker?  // nil = broadcast to all
  let swarmId: String
  @Binding var messageText: String
  let onSend: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        // Recipient info
        HStack {
          Image(systemName: worker == nil ? "megaphone.fill" : "person.fill")
            .foregroundStyle(.secondary)
          Text(worker == nil ? "Broadcast to all workers" : "Message to \(worker!.displayName)")
            .font(.headline)
          Spacer()
        }
        .padding(.horizontal)

        // Message input
        TextEditor(text: $messageText)
          .font(.body)
          .frame(minHeight: 100)
          .padding(8)
          .background(.quaternary)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .padding(.horizontal)

        // Suggestions
        VStack(alignment: .leading, spacing: 8) {
          Text("Quick messages:")
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack(spacing: 8) {
            QuickMessageButton(text: "Pause current task", messageText: $messageText)
            QuickMessageButton(text: "Focus on tests", messageText: $messageText)
            QuickMessageButton(text: "Skip code review", messageText: $messageText)
          }
        }
        .padding(.horizontal)

        Spacer()
      }
      .padding(.top)
      .navigationTitle(worker == nil ? "Broadcast Message" : "Send Message")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") { onSend() }
            .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .frame(minWidth: 450, minHeight: 300)
  }
}

// MARK: - Quick Message Button

struct QuickMessageButton: View {
  let text: String
  @Binding var messageText: String

  var body: some View {
    Button(text) {
      messageText = text
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }
}
