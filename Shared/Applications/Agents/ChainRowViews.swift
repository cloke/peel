//
//  ChainRowViews.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

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

        Chip(
          text: statusText,
          foreground: .blue,
          background: Color.blue.opacity(0.15)
        )
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
            Text("\(chain.results.reduce(0) { $0 + $1.premiumCost }.premiumMultiplierString()) used")
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
