//
//  Agents_RootView.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import SwiftData
import SwiftUI
import AppKit

/// Infrastructure views that can be shown in detail pane
enum InfrastructureView: String, Hashable {
  case vmIsolation = "vm-isolation"
  case mcpDashboard = "mcp-dashboard"
  case templateGallery = "template-gallery"
  case translationValidation = "translation-validation"
  case localRag = "local-rag"
  case piiScrubber = "pii-scrubber"
  case parallelWorktrees = "parallel-worktrees"
  case worktrees = "worktrees"
}

/// Main view for AI Agent Orchestration
struct Agents_RootView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(\.modelContext) private var modelContext
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var showingNewAgentSheet = false
  @State private var showingNewChainSheet = false
  @State private var showingSetupSheet = false
  @State private var showingSessionSummary = false
  @State private var selectedInfrastructure: InfrastructureView?

  private var agentManager: AgentManager { mcpServer.agentManager }
  private var cliService: CLIService { mcpServer.cliService }
  private var sessionTracker: SessionTracker { mcpServer.sessionTracker }
  
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      AgentsSidebarView(
        agentManager: agentManager,
        cliService: cliService,
        showingSetupSheet: $showingSetupSheet,
        showingNewChainSheet: $showingNewChainSheet,
        showingNewAgentSheet: $showingNewAgentSheet,
        selectedInfrastructure: $selectedInfrastructure
      )
    } detail: {
      detailView
    }
    .navigationSplitViewStyle(.balanced)
    .task {
      mcpServer.configure(modelContext: modelContext)
      await cliService.checkAllCLIs()
    }
    .onChange(of: mcpServer.lastUIAction?.id) {
      guard let action = mcpServer.lastUIAction else { return }
      switch action.controlId {
      case "agents.newAgent":
        showingNewAgentSheet = true
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.newChain":
        showingNewChainSheet = true
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.mcpDashboard":
        selectedInfrastructure = .mcpDashboard
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.cliSetup":
        showingSetupSheet = true
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.sessionSummary":
        showingSessionSummary = true
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.vmIsolation":
        selectedInfrastructure = .vmIsolation
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.translationValidation":
        selectedInfrastructure = .translationValidation
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.templateGallery":
        selectedInfrastructure = .templateGallery
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.localRag":
        selectedInfrastructure = .localRag
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.piiScrubber":
        selectedInfrastructure = .piiScrubber
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.parallelWorktrees":
        selectedInfrastructure = .parallelWorktrees
        mcpServer.recordUIActionHandled(action.controlId)
      case "agents.worktrees":
        selectedInfrastructure = .worktrees
        mcpServer.recordUIActionHandled(action.controlId)
      default:
        break
      }
      mcpServer.lastUIAction = nil
    }
    .onChange(of: selectedInfrastructure) { _, newValue in
      if let newValue {
        UserDefaults.standard.set("infra:\(newValue.rawValue)", forKey: "agents.selectedInfrastructure")
      } else {
        UserDefaults.standard.removeObject(forKey: "agents.selectedInfrastructure")
      }
    }
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          showingSessionSummary = true
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")
            Text(sessionTracker.totalPremiumUsed.premiumMultiplierString())
              .font(.caption)
              .fontWeight(.medium)
          }
        }
        .accessibilityIdentifier("agents.sessionSummary")
        .help("Session Usage: \(sessionTracker.totalPremiumUsed.premiumMultiplierString()) premium requests")
      }
      ToolSelectionToolbar()
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
  
  @ViewBuilder
  private var detailView: some View {
    if let infra = selectedInfrastructure {
      switch infra {
      case .vmIsolation:
        VMIsolationDashboardView()
      case .mcpDashboard:
        MCPDashboardView(mcpServer: mcpServer, sessionTracker: sessionTracker)
      case .templateGallery:
        ChainTemplateGalleryView(agentManager: agentManager, cliService: cliService)
      case .translationValidation:
        TranslationValidationView()
      case .localRag:
        LocalRAGDashboardView(mcpServer: mcpServer)
      case .piiScrubber:
        PIIScrubberView()
      case .parallelWorktrees:
        ParallelWorktreeDashboardView(mcpServer: mcpServer)
      case .worktrees:
        WorktreesView()
      }
    } else if let chain = agentManager.selectedChain {
      ChainDetailView(chain: chain, agentManager: agentManager, cliService: cliService, sessionTracker: sessionTracker)
    } else if let agent = agentManager.selectedAgent {
      AgentDetailView(agent: agent, agentManager: agentManager)
    } else {
      emptyStateView
    }
  }
  
  private var emptyStateView: some View {
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
        .accessibilityIdentifier("agents.emptyState.newAgent")
        
        Button {
          showingNewChainSheet = true
        } label: {
          Label("New Chain", systemImage: "link")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("agents.emptyState.newChain")
      }
    }
  }
  
  private var cliStatusIcon: String {
    return (cliService.copilotStatus.isAvailable || cliService.claudeStatus.isAvailable) 
      ? "checkmark.circle.fill" : "exclamationmark.triangle"
  }
}

#Preview {
  Agents_RootView()
}
