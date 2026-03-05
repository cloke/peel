//
//  SwarmActivityView.swift
//  Peel
//
//  Activity log and event row views for swarm activity tracking
//

import SwiftUI

// MARK: - Swarm Messages View

@MainActor
struct SwarmMessagesView: View {
  let swarmId: String
  let myRole: SwarmPermissionRole
  @Binding var selectedWorker: FirestoreWorker?

  @State private var firebaseService = FirebaseService.shared
  @State private var messageText = ""
  @State private var isSending = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("\(firebaseService.swarmMessages.count) messages")
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        if myRole.canSubmitTasks {
          Button {
            selectedWorker = nil
            if !messageText.isEmpty {
              messageText = ""
            }
          } label: {
            Label("Broadcast", systemImage: "megaphone")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Compose a broadcast message to all workers")
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)

      Divider()

      if firebaseService.swarmMessages.isEmpty {
        ContentUnavailableView(
          "No Messages Yet",
          systemImage: "message",
          description: Text("Worker messages and broadcasts will appear here.")
        )
      } else {
        List(firebaseService.swarmMessages) { message in
          SwarmMessageRow(
            message: message,
            isMe: message.senderId == firebaseService.currentUserId
          )
        }
        .listStyle(.plain)
      }

      if myRole.canSubmitTasks {
        Divider()
        HStack(alignment: .bottom, spacing: 8) {
          VStack(alignment: .leading, spacing: 4) {
            Text(selectedWorker == nil ? "Broadcast to all workers" : "Message to \(selectedWorker?.displayName ?? "worker")")
              .font(.caption)
              .foregroundStyle(.secondary)

            TextField("Type a message...", text: $messageText, axis: .vertical)
              .textFieldStyle(.roundedBorder)
              .lineLimit(1...3)
          }

          Button {
            Task {
              await sendMessage()
            }
          } label: {
            Label("Send", systemImage: "paperplane.fill")
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSending || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
      }
    }
    .alert("Message Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func sendMessage() async {
    let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    isSending = true
    do {
      try await firebaseService.sendMessage(
        swarmId: swarmId,
        text: trimmed,
        targetWorkerId: selectedWorker?.id
      )
      messageText = ""
      selectedWorker = nil
    } catch {
      errorMessage = error.localizedDescription
    }
    isSending = false
  }
}

private struct SwarmMessageRow: View {
  let message: SwarmMessage
  let isMe: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(message.isBroadcast ? "📢" : "💬")
          .font(.caption)

        Text(message.senderName)
          .font(.caption)
          .fontWeight(.semibold)

        if isMe {
          Text("You")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.15))
            .foregroundStyle(.blue)
            .clipShape(Capsule())
        }

        Spacer()

        Text(message.createdAt, style: .time)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Text(message.text)
        .font(.body)
        .textSelection(.enabled)
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Activity Log View

struct ActivityLogView: View {
  @State private var firebaseService = FirebaseService.shared
  @State private var filterType: SwarmActivityType?

  var filteredEvents: [SwarmActivityEvent] {
    if let filter = filterType {
      return firebaseService.activityLog.filter { $0.type == filter }
    }
    return firebaseService.activityLog
  }

  var body: some View {
    VStack(spacing: 0) {
      // Filter bar
      HStack {
        Text("\(filteredEvents.count) events")
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Picker("Filter", selection: $filterType) {
          Text("All Events").tag(nil as SwarmActivityType?)
          Divider()
          Text("🟢 Workers").tag(SwarmActivityType.workerOnline as SwarmActivityType?)
          Text("📤 Tasks").tag(SwarmActivityType.taskSubmitted as SwarmActivityType?)
          Text("⚠️ Errors").tag(SwarmActivityType.error as SwarmActivityType?)
        }
        .pickerStyle(.menu)
        .frame(width: 140)

        Button {
          // Clear log
          firebaseService.clearActivityLog()
        } label: {
          Label("Clear", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .disabled(firebaseService.activityLog.isEmpty)
      }
      .padding(.horizontal)
      .padding(.vertical, 8)

      Divider()

      if filteredEvents.isEmpty {
        ContentUnavailableView(
          "No Activity",
          systemImage: "chart.line.flattrend.xyaxis",
          description: Text("Swarm events like worker registration, tasks, and messages will appear here.")
        )
      } else {
        List(filteredEvents) { event in
          ActivityEventRow(event: event)
        }
        .listStyle(.plain)
      }
    }
  }
}

// MARK: - Activity Event Row

struct ActivityEventRow: View {
  let event: SwarmActivityEvent
  @State private var showingDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top) {
        Text(event.type.emoji)
          .font(.title3)

        VStack(alignment: .leading, spacing: 2) {
          Text(event.message)
            .fontWeight(.medium)

          Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if event.details != nil {
          Button {
            showingDetails.toggle()
          } label: {
            Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
        }
      }

      // Details disclosure
      if showingDetails, let details = event.details {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(details.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
            HStack(alignment: .top) {
              Text(key + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

              Text(value)
                .font(.caption)
                .textSelection(.enabled)
            }
          }
        }
        .padding(.leading, 32)
        .padding(.top, 4)
      }
    }
    .padding(.vertical, 4)
  }
}
