//
//  LiveStatusPanel.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

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
