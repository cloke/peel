//
//  AgentRowView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

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
    .accessibilityIdentifier("agents.agentRow.\(agent.id.uuidString)")
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
