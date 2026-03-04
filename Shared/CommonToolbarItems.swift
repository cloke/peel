//
//  CommonToolbarItems.swift
//  KitchenSync
//
//  Created by Cory Loken on 1/1/21.
//  Updated for better UX on 1/7/26
//

import SwiftUI
import PeelUI

struct ToolSelectionToolbar: ToolbarContent {
  @AppStorage(wrappedValue: .repositories, "current-tool") private var currentTool: CurrentTool
  @AppStorage("feature.showBrew") private var showBrew = false

  var body: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      Picker("Tool", selection: $currentTool) {
        Label("Repositories", systemImage: "tray.full")
          .labelStyle(.titleAndIcon)
          .tag(CurrentTool.repositories)
        Label("Activity", systemImage: "bolt.fill")
          .labelStyle(.titleAndIcon)
          .tag(CurrentTool.activity)
        if showBrew {
          Label("Brew", systemImage: "mug")
            .labelStyle(.titleAndIcon)
            .tag(CurrentTool.brew)
        }
      }
      .pickerStyle(.segmented)
      .help("Switch between tools")
    }
  }
}

/// Global activity indicator showing running/recently-completed chains.
/// Visible from every tab. Clicking navigates directly to the chain.
struct ChainActivityToolbar: ToolbarContent {
  @Environment(MCPServerService.self) private var mcpServer
  @AppStorage("current-tool") private var currentTool: CurrentTool = .agents

  private var agentManager: AgentManager { mcpServer.agentManager }

  private var runningChains: [AgentChain] {
    agentManager.chains.filter {
      if case .running = $0.state { return true }
      if case .reviewing = $0.state { return true }
      return false
    }
  }

  /// Chains that completed in the last 60 seconds and haven't been viewed yet
  private var recentlyFinished: [AgentChain] {
    agentManager.chains.filter { chain in
      switch chain.state {
      case .complete, .failed:
        // Show if finished recently (use results last duration as proxy)
        guard let startTime = chain.runStartTime else { return false }
        // Only show for chains that started in this session (within last hour)
        return Date().timeIntervalSince(startTime) < 3600
          && agentManager.selectedChain?.id != chain.id
      default:
        return false
      }
    }
  }

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      if !runningChains.isEmpty {
        // Running chains — pulsing indicator
        Menu {
          ForEach(runningChains) { chain in
            Button {
              navigateToChain(chain)
            } label: {
              Label(chain.name, systemImage: "bolt.fill")
            }
          }
        } label: {
          HStack(spacing: 4) {
            ProgressView()
              .controlSize(.mini)
            Text("\(runningChains.count) running")
              .font(.caption)
              .fontWeight(.medium)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(.blue.opacity(0.15), in: Capsule())
        }
        .help("Agent chains running — click to view")
      } else if let latest = recentlyFinished.last {
        // Most recent finished chain — show result
        Button {
          navigateToChain(latest)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: latest.state.isComplete ? "checkmark.circle.fill" : "xmark.circle.fill")
              .foregroundStyle(latest.state.isComplete ? .green : .red)
            Text(latest.name)
              .font(.caption)
              .fontWeight(.medium)
              .lineLimit(1)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(
            (latest.state.isComplete ? Color.green : Color.red).opacity(0.1),
            in: Capsule()
          )
        }
        .buttonStyle(.plain)
        .help("Click to view completed chain")
      }
    }
  }

  private func navigateToChain(_ chain: AgentChain) {
    agentManager.selectedChain = chain
    currentTool = .activity
  }
}

struct ToggleSidebarToolbarItem: ToolbarContent {
  let placement: ToolbarItemPlacement
  
  func toggleSidebar() {
    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
  }
  
  var body: some ToolbarContent {
    ToolbarItem(placement: placement) {
      Button { toggleSidebar() }
        label: { Image(systemName: "sidebar.left") }
        .help(Text("Toggle Sidebar"))
    }
  }
}
