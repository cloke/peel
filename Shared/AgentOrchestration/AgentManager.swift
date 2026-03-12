//
//  AgentManager.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation
import Observation
import AppKit
import Git
import IOKit.pwr_mgt
import MCPCore
import Network
import SwiftData
import TaskRunner

/// Manages the lifecycle of AI coding agents
@MainActor
@Observable
public final class AgentManager {
  /// All registered agents
  public private(set) var agents: [Agent] = []
  
  /// All agent chains
  public private(set) var chains: [AgentChain] = []
  
  /// Saved chain templates (user-created)
  public private(set) var savedTemplates: [ChainTemplate] = []
  
  /// All available templates (built-in + saved)
  public var allTemplates: [ChainTemplate] {
    ChainTemplate.builtInTemplates + savedTemplates
  }
  
  /// The workspace manager for creating isolated workspaces
  public let workspaceManager = AgentWorkspaceService()
  
  /// Currently selected agent (for UI)
  public var selectedAgent: Agent?
  
  /// Currently selected chain (for UI)
  public var selectedChain: AgentChain?
  
  /// Last used working directory (persisted)
  public var lastUsedWorkingDirectory: String? {
    didSet {
      if let dir = lastUsedWorkingDirectory {
        UserDefaults.standard.set(dir, forKey: "lastUsedWorkingDirectory")
      }
    }
  }

  /// Whether to warn before running premium chains (persisted)
  public var warnBeforePremiumChains: Bool {
    get {
      UserDefaults.standard.object(forKey: "warnBeforePremiumChains") as? Bool ?? true
    }
    set {
      UserDefaults.standard.set(newValue, forKey: "warnBeforePremiumChains")
    }
  }
  
  public init() {
    // Load last used working directory
    lastUsedWorkingDirectory = UserDefaults.standard.string(forKey: "lastUsedWorkingDirectory")
    loadSavedTemplates()
  }
  
  // MARK: - Agent Lifecycle
  
  /// Create and register a new agent
  public func createAgent(
    name: String,
    type: AgentType,
    role: AgentRole = .implementer,
    model: CopilotModel = .claudeSonnet45,
    customInstructions: String? = nil,
    workingDirectory: String? = nil,
    customCLIPath: String? = nil
  ) -> Agent {
    let agent = Agent(
      name: name,
      type: type,
      role: role,
      model: model,
      customInstructions: customInstructions,
      workingDirectory: workingDirectory,
      customCLIPath: customCLIPath
    )
    agents.append(agent)
    return agent
  }
  
  /// Remove an agent
  public func removeAgent(_ agent: Agent) async {
    // Clean up workspace if exists
    if let workspace = agent.workspace {
      try? await workspaceManager.cleanupWorkspace(workspace, force: true)
    }
    agents.removeAll { $0.id == agent.id }
    if selectedAgent?.id == agent.id {
      selectedAgent = nil
    }
  }
  
  // MARK: - Chain Management
  
  /// Create a new agent chain
  public func createChain(name: String, workingDirectory: String? = nil) -> AgentChain {
    let chain = AgentChain(name: name, workingDirectory: workingDirectory)
    chains.append(chain)
    return chain
  }
  
  /// Remove a chain
  public func removeChain(_ chain: AgentChain) {
    chains.removeAll { $0.id == chain.id }
    if selectedChain?.id == chain.id {
      selectedChain = nil
    }
  }
  
  /// Create a chain from a template
  public func createChainFromTemplate(_ template: ChainTemplate, workingDirectory: String? = nil) -> AgentChain {
    let chain = createChain(name: template.name, workingDirectory: workingDirectory)

    // Copy VM execution settings from template
    chain.executionEnvironment = template.executionEnvironment
    chain.toolchain = template.toolchain
    chain.directoryShares = template.directoryShares
    chain.completionCriteria = template.completionCriteria
    
    for step in template.steps {
      let agent = createAgent(
        name: step.name,
        type: .copilot,
        role: step.role,
        model: step.model,
        workingDirectory: workingDirectory
      )
      agent.frameworkHint = step.frameworkHint
      agent.customInstructions = step.customInstructions
      agent.stepType = step.stepType
      agent.command = step.command
      agent.allowedTools = step.allowedTools
      agent.stepDeniedTools = step.deniedTools
      chain.addAgent(agent)
    }
    
    // Auto-set requiresImplementation if the chain has implementer steps
    if chain.agents.contains(where: { $0.role == .implementer }) {
      chain.requiresImplementation = true
    }
    
    return chain
  }
  
  // MARK: - Template Management
  
  /// Save a chain as a new template
  public func saveChainAsTemplate(_ chain: AgentChain, name: String, description: String = "") {
    let steps = chain.agents.map { agent in
      AgentStepTemplate(
        role: agent.role,
        model: agent.model,
        name: agent.name,
        frameworkHint: agent.frameworkHint,
        customInstructions: agent.customInstructions,
        stepType: agent.stepType,
        command: agent.command,
        allowedTools: agent.allowedTools,
        deniedTools: agent.stepDeniedTools
      )
    }
    
    let template = ChainTemplate(
      name: name,
      description: description,
      steps: steps,
      isBuiltIn: false
    )
    
    savedTemplates.append(template)
    persistTemplates()
  }
  
  /// Load saved templates from disk
  private func loadSavedTemplates() {
    guard let url = templatesFileURL,
          let data = try? Data(contentsOf: url),
          let templates = try? JSONDecoder().decode([ChainTemplate].self, from: data) else {
      return
    }
    savedTemplates = templates
  }
  
  /// Save templates to disk
  private func persistTemplates() {
    guard let url = templatesFileURL,
          let data = try? JSONEncoder().encode(savedTemplates) else {
      return
    }
    try? data.write(to: url)
  }
  
  private var templatesFileURL: URL? {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?
      .appendingPathComponent("Peel")
      .appendingPathComponent("chain_templates.json")
  }
  
  // MARK: - Queries
  
  /// Get agents filtered by state
  public func agents(in state: AgentState) -> [Agent] {
    agents.filter { $0.state == state }
  }
  
  /// Check if we should show premium warning for a chain
  public func shouldShowPremiumWarning(for chain: AgentChain) -> Bool {
    guard warnBeforePremiumChains else { return false }

    let tiers = chain.agents.map { $0.model.costTier }
    return tiers.contains(.premium) || tiers.contains(.standard)
  }
  
}


@MainActor
public final class MCPTelemetryAdapter: MCPTelemetryProviding {
  private let logService: MCPLogService
  private let sessionTracker: SessionTracker

  public init(sessionTracker: SessionTracker) {
    self.logService = .shared
    self.sessionTracker = sessionTracker
  }

  init(
    logService: MCPLogService,
    sessionTracker: SessionTracker
  ) {
    self.logService = logService
    self.sessionTracker = sessionTracker
  }

  public func info(_ message: String, metadata: [String: String] = [:]) async {
    await logService.info(message, metadata: metadata)
  }

  public func warning(_ message: String, metadata: [String: String] = [:]) async {
    await logService.warning(message, metadata: metadata)
  }

  public func error(_ message: String, metadata: [String: String] = [:]) async {
    await logService.error(message, metadata: metadata)
  }

  public func error(_ error: Error, context: String, metadata: [String: String] = [:]) async {
    await logService.error(error, context: context, metadata: metadata)
  }

  public func logPath() async -> String {
    await logService.logPath()
  }

  public func tail(lines: Int) async -> String {
    await logService.tail(lines: lines)
  }

  public func recordChainRun(_ chain: Any) {
    if let typed = chain as? AgentChain {
      sessionTracker.recordChainRun(typed)
    }
  }

  public var totalPremiumUsed: Double {
    sessionTracker.totalPremiumUsed
  }

  public var totalFreeUsed: Int {
    sessionTracker.totalFreeUsed
  }
}

