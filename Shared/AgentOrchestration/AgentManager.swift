//
//  AgentManager.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation
import Observation

#if os(macOS)
import AppKit
import Git
import IOKit.pwr_mgt
import Network
import SwiftData
import TaskRunner

/// Manages the lifecycle of AI coding agents
@MainActor
@Observable
public final class AgentManager {
  private let mcpLog = MCPLogService.shared
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
    workingDirectory: String? = nil,
    customCLIPath: String? = nil
  ) -> Agent {
    let agent = Agent(
      name: name,
      type: type,
      role: role,
      model: model,
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
  
  /// Assign a task to an agent and optionally create a workspace
  public func assignTask(
    _ task: AgentTask,
    to agent: Agent,
    repository: Model.Repository? = nil
  ) async throws {
    agent.assignTask(task)
    
    // Create workspace if repository provided
    if let repo = repository {
      let workspace = try await workspaceManager.createWorkspace(
        for: repo,
        task: task,
        agentId: agent.id
      )
      agent.workspace = workspace
    }
  }
  
  /// Start an agent working on its current task
  public func startAgent(_ agent: Agent) {
    guard agent.currentTask != nil else { return }
    agent.updateState(.working)
    agent.currentTask?.start()
  }
  
  /// Mark an agent as complete
  public func completeAgent(_ agent: Agent, result: String? = nil) {
    agent.currentTask?.complete(result: result)
    agent.updateState(.complete)
  }
  
  /// Mark an agent as blocked
  public func blockAgent(_ agent: Agent, reason: String) {
    agent.updateState(.blocked(reason: reason))
  }
  
  /// Reset an agent to idle state
  public func resetAgent(_ agent: Agent) async {
    if let workspace = agent.workspace {
      try? await workspaceManager.cleanupWorkspace(workspace)
      agent.workspace = nil
    }
    agent.clearTask()
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
      chain.addAgent(agent)
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
        customInstructions: agent.customInstructions
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
  
  /// Delete a saved template (cannot delete built-in)
  public func deleteTemplate(_ template: ChainTemplate) {
    guard !template.isBuiltIn else { return }
    savedTemplates.removeAll { $0.id == template.id }
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
  
  /// Get active agents (planning, working, or testing)
  public var activeAgents: [Agent] {
    agents.filter { $0.state.isActive }
  }
  
  /// Get idle agents
  public var idleAgents: [Agent] {
    agents.filter { $0.state == .idle }
  }
  
}

// MARK: - Agent Chain Runner

@MainActor
@Observable
public final class AgentChainRunner {
  private enum RagDefaults {
    static let query = "localrag.query"
    static let searchMode = "localrag.searchMode"
    static let searchLimit = "localrag.searchLimit"
  }
  private actor ChainRunGate {
    enum Mode {
      case running
      case paused
      case step
    }

    private var mode: Mode = .running
    private var continuation: CheckedContinuation<Void, Never>?

    func waitIfPaused() async {
      switch mode {
      case .running:
        return
      case .step:
        mode = .paused
        return
      case .paused:
        await withCheckedContinuation { continuation in
          self.continuation = continuation
        }
        if mode == .step {
          mode = .paused
        }
      }
    }

    func pause() {
      mode = .paused
    }

    func resume() {
      mode = .running
      continuation?.resume()
      continuation = nil
    }

    func step() {
      switch mode {
      case .running:
        mode = .step
      case .paused:
        mode = .step
        continuation?.resume()
        continuation = nil
      case .step:
        return
      }
    }
  }

  public struct ChainRunOptions: Sendable {
    public let allowPlannerModelSelection: Bool
    public let allowPlannerImplementerScaling: Bool
    public let maxImplementers: Int?
    public let maxPremiumCost: Double?

    public init(
      allowPlannerModelSelection: Bool = false,
      allowPlannerImplementerScaling: Bool = false,
      maxImplementers: Int? = nil,
      maxPremiumCost: Double? = nil
    ) {
      self.allowPlannerModelSelection = allowPlannerModelSelection
      self.allowPlannerImplementerScaling = allowPlannerImplementerScaling
      self.maxImplementers = maxImplementers
      self.maxPremiumCost = maxPremiumCost
    }
  }

  public struct RunSummary: Sendable {
    public let chainId: UUID
    public let chainName: String
    public let stateDescription: String
    public let results: [AgentChainResult]
    public let mergeConflicts: [String]
    public let errorMessage: String?
    public let noWorkReason: String?
    public let validationResult: ValidationResult?
  }

  private let agentManager: AgentManager
  private let cliService: CLIService
  private let sessionTracker: SessionTracker
  private let validationRunner = ValidationRunner()
  private let mcpLog = MCPLogService.shared
  private let mergeCoordinator = MergeCoordinator.shared
  private let screenshotService = ScreenshotService()
  private let localRagStore = LocalRAGStore()
  private var runGates: [UUID: ChainRunGate] = [:]

  public init(
    agentManager: AgentManager,
    cliService: CLIService,
    sessionTracker: SessionTracker
  ) {
    self.agentManager = agentManager
    self.cliService = cliService
    self.sessionTracker = sessionTracker
  }

  public func runChain(
    _ chain: AgentChain,
    prompt: String,
    validationConfig: ValidationConfiguration? = nil,
    runOptions: ChainRunOptions? = nil
  ) async -> RunSummary {
    let gate = ChainRunGate()
    runGates[chain.id] = gate
    defer { runGates[chain.id] = nil }
    let sleepAssertionId = beginSleepPrevention(for: chain)
    defer {
      if let sleepAssertionId {
        endSleepPrevention(assertionId: sleepAssertionId)
      }
    }

    var mergeConflicts: [String] = []
    var errorMessage: String?
    var validationResult: ValidationResult? = nil

    chain.reset()
    chain.clearLiveStatus()
    chain.runStartTime = Date()
    chain.state = .running(agentIndex: 0)
    chain.addStatusMessage("Starting chain execution...", type: .info)
    if let runOptions {
      chain.plannerOverridesAllowed = runOptions.allowPlannerImplementerScaling
        || runOptions.allowPlannerModelSelection
        || runOptions.maxImplementers != nil
        || runOptions.maxPremiumCost != nil
      chain.plannerOverridesApplied = false
      if chain.plannerOverridesAllowed {
        chain.addStatusMessage("Planner overrides pending (showing template agents)", type: .info)
      }
    } else {
      chain.plannerOverridesAllowed = false
      chain.plannerOverridesApplied = false
    }

    do {
      try checkCancellation(chain: chain)
      try await runAgentsWithParallelImplementers(
        chain: chain,
        prompt: prompt,
        mergeConflicts: &mergeConflicts,
        runOptions: runOptions
      )

      if case .complete = chain.state {
        sessionTracker.recordChainRun(chain)
      } else {
        try checkCancellation(chain: chain)
        if chain.enableReviewLoop {
          try await runReviewLoop(chain: chain, prompt: prompt)
        }

        chain.state = .complete
        chain.addStatusMessage("✓ Chain completed successfully!", type: .complete)
        sessionTracker.recordChainRun(chain)
      }
    } catch {
      switch error {
      case ChainError.cancelled:
        errorMessage = "Cancelled"
        chain.state = .failed(message: "Cancelled")
        chain.addStatusMessage("✋ Chain cancelled.", type: .error)
      default:
        errorMessage = error.localizedDescription
        chain.state = .failed(message: error.localizedDescription)
        chain.addStatusMessage("Error: \(error.localizedDescription)", type: .error)
      }
    }

    let noWorkReason = chain.results.first(where: { $0.plannerDecision?.shouldSkipWork == true })?.plannerDecision?.noWorkReason

    // Run validation if configured
    if let config = validationConfig, !config.enabledRules.isEmpty {
      chain.addStatusMessage("Running validation...", type: .info)
      let summary = RunSummary(
        chainId: chain.id,
        chainName: chain.name,
        stateDescription: chain.state.displayName,
        results: chain.results,
        mergeConflicts: mergeConflicts,
        errorMessage: errorMessage,
        noWorkReason: noWorkReason,
        validationResult: nil
      )
      
      let rules = config.createRules()
      validationResult = await validationRunner.runValidation(
        rules: rules,
        chain: chain,
        summary: summary,
        workingDirectory: chain.workingDirectory
      )
      
      switch validationResult?.status {
      case .passed:
        chain.addStatusMessage("✓ Validation passed", type: .complete)
      case .failed:
        chain.addStatusMessage("✗ Validation failed", type: .error)
      case .warning:
        chain.addStatusMessage("⚠ Validation warnings", type: .error)
      case .skipped, .none:
        break
      }
    }

        return RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: chain.state.displayName,
      results: chain.results,
      mergeConflicts: mergeConflicts,
      errorMessage: errorMessage,
      noWorkReason: noWorkReason,
      validationResult: validationResult
        )
  }

  private func runAgentsSequentially(chain: AgentChain, prompt: String) async throws {
    for (index, agent) in chain.agents.enumerated() {
      try checkCancellation(chain: chain)
      await waitForGate(chain: chain)
      chain.state = .running(agentIndex: index)
      chain.currentAgentStartTime = Date()
      chain.addStatusMessage("Starting \(agent.name) (\(agent.model.shortName))...", type: .progress)
      let result = try await runSingleAgent(agent, at: index, chain: chain, prompt: prompt)
      chain.results.append(result)
      chain.addStatusMessage("\(agent.name) completed", type: .complete)
      if agent.role == .planner,
         let decision = result.plannerDecision,
         decision.shouldSkipWork {
        let reason = decision.noWorkReason ?? "Planner determined no work is required."
        chain.addStatusMessage("Planner gated implementers: \(reason)", type: .complete)
        chain.state = .complete
        return
      }
    }
  }

  private func beginSleepPrevention(for chain: AgentChain) -> IOPMAssertionID? {
    let reason = "Peel chain execution: \(chain.name)"
    var assertionId: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypeNoDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason as CFString,
      &assertionId
    )
    if result == kIOReturnSuccess {
      chain.addStatusMessage("Preventing sleep during chain run", type: .info)
      return assertionId
    }
    return nil
  }

  private func endSleepPrevention(assertionId: IOPMAssertionID) {
    IOPMAssertionRelease(assertionId)
  }

  private func applyPlannerOverrides(
    chain: AgentChain,
    decision: PlannerDecision,
    options: ChainRunOptions
  ) async {
    guard options.allowPlannerImplementerScaling ||
            options.allowPlannerModelSelection ||
            options.maxImplementers != nil ||
            options.maxPremiumCost != nil else {
      return
    }

    let tasks = decision.tasks
    guard !tasks.isEmpty else { return }

    let implementerIndices = chain.agents.indices.filter { chain.agents[$0].role == .implementer }
    guard let firstImplementer = implementerIndices.first,
          let lastImplementer = implementerIndices.last else {
      return
    }

    let preAgents = Array(chain.agents.prefix(firstImplementer))
    let postAgents = Array(chain.agents.suffix(from: lastImplementer + 1))

    var desiredCount = implementerIndices.count
    if options.allowPlannerImplementerScaling {
      desiredCount = tasks.count
    }
    if let maxImplementers = options.maxImplementers, maxImplementers > 0 {
      desiredCount = min(desiredCount, maxImplementers)
    }

    let nonImplementerCount = preAgents.count + postAgents.count
    let maxBySteps = max(1, MCPTemplateValidator.maxSteps - nonImplementerCount)
    desiredCount = min(desiredCount, maxBySteps)

    if desiredCount != implementerIndices.count {
      chain.addStatusMessage("Planner requested \(desiredCount) implementer(s)", type: .info)
    }

    var implementers = implementerIndices.map { chain.agents[$0] }

    if desiredCount < implementers.count {
      let removed = implementers.suffix(from: desiredCount)
      implementers = Array(implementers.prefix(desiredCount))
      for agent in removed {
        await agentManager.removeAgent(agent)
      }
    } else if desiredCount > implementers.count {
      let startIndex = implementers.count
      for index in startIndex..<desiredCount {
        let taskTitle = tasks.indices.contains(index) ? tasks[index].title : "Implementer \(index + 1)"
        let agent = agentManager.createAgent(
          name: taskTitle,
          type: .copilot,
          role: .implementer,
          model: implementers.first?.model ?? .claudeSonnet45,
          workingDirectory: chain.workingDirectory
        )
        implementers.append(agent)
      }
    }

    if options.allowPlannerModelSelection {
      for (index, agent) in implementers.enumerated() {
        guard index < tasks.count,
              let modelName = tasks[index].recommendedModel,
              let model = CopilotModel.fromString(modelName) else {
          continue
        }
        agent.model = model
      }
      chain.addStatusMessage("Applied planner model recommendations", type: .info)
    }

    if let maxPremiumCost = options.maxPremiumCost, maxPremiumCost >= 0 {
      let cheapest = preferredLowCostModel()
      var totalCost = implementers.reduce(0) { $0 + $1.model.premiumCost }
      var downgraded = 0

      if totalCost > maxPremiumCost {
        let sorted = implementers.sorted { $0.model.premiumCost > $1.model.premiumCost }
        for agent in sorted {
          guard totalCost > maxPremiumCost else { break }
          guard agent.model.premiumCost > cheapest.premiumCost else { continue }
          totalCost -= agent.model.premiumCost
          agent.model = cheapest
          totalCost += cheapest.premiumCost
          downgraded += 1
        }
      }

      if downgraded > 0 {
        chain.addStatusMessage("Cost cap applied: downgraded \(downgraded) implementer(s)", type: .info)
      }
      if totalCost > maxPremiumCost {
        chain.addStatusMessage("Cost cap exceeded after downgrades", type: .error)
      }
    }

    chain.plannerOverridesApplied = true
    chain.addStatusMessage("Planner overrides applied", type: .info)

    chain.agents = preAgents + implementers + postAgents
  }

  private func preferredLowCostModel() -> CopilotModel {
    if let free = CopilotModel.allCases.first(where: { $0.isFree }) {
      return free
    }
    return CopilotModel.allCases.min(by: { $0.premiumCost < $1.premiumCost }) ?? .gpt41
  }

  private func runAgentsWithParallelImplementers(
    chain: AgentChain,
    prompt: String,
    mergeConflicts: inout [String],
    runOptions: ChainRunOptions?
  ) async throws {
    try checkCancellation(chain: chain)
    let initialImplementerIndices = chain.agents.indices.filter { chain.agents[$0].role == .implementer }
    guard let firstImplementer = initialImplementerIndices.first else {
      try await runAgentsSequentially(chain: chain, prompt: prompt)
      return
    }

    if firstImplementer > 0 {
      for index in 0..<firstImplementer {
        try checkCancellation(chain: chain)
        await waitForGate(chain: chain)
        let agent = chain.agents[index]
        chain.state = .running(agentIndex: index)
        chain.currentAgentStartTime = Date()
        chain.addStatusMessage("Starting \(agent.name) (\(agent.model.shortName))...", type: .progress)
        let result = try await runSingleAgent(agent, at: index, chain: chain, prompt: prompt)
        chain.results.append(result)
        chain.addStatusMessage("\(agent.name) completed", type: .complete)
        if agent.role == .planner,
           let decision = result.plannerDecision,
           decision.shouldSkipWork {
          let reason = decision.noWorkReason ?? "Planner determined no work is required."
          chain.addStatusMessage("Planner gated implementers: \(reason)", type: .complete)
          chain.state = .complete
          return
        }
      }
    }

    if let options = runOptions,
       let decision = chain.results.first(where: { $0.plannerDecision != nil })?.plannerDecision {
      await applyPlannerOverrides(chain: chain, decision: decision, options: options)
    }

    let implementerIndices = chain.agents.indices.filter { chain.agents[$0].role == .implementer }
    guard let updatedFirst = implementerIndices.first else {
      return
    }

    guard implementerIndices.count > 1 else {
      for index in updatedFirst..<chain.agents.count {
        try checkCancellation(chain: chain)
        await waitForGate(chain: chain)
        let agent = chain.agents[index]
        chain.state = .running(agentIndex: index)
        chain.currentAgentStartTime = Date()
        chain.addStatusMessage("Starting \(agent.name) (\(agent.model.shortName))...", type: .progress)
        let result = try await runSingleAgent(agent, at: index, chain: chain, prompt: prompt)
        chain.results.append(result)
        chain.addStatusMessage("\(agent.name) completed", type: .complete)
      }
      return
    }

    guard let updatedLast = implementerIndices.last else {
      return
    }

    let hasGaps = (updatedFirst...updatedLast).contains { index in
      chain.agents[index].role != .implementer
    }
    if hasGaps {
      try await runAgentsSequentially(chain: chain, prompt: prompt)
      return
    }

    try checkCancellation(chain: chain)
    await waitForGate(chain: chain)
    let sharedContext = chain.contextForAgent(at: updatedFirst)
    let parallelResults = try await runImplementersInParallel(
      chain: chain,
      indices: Array(updatedFirst...updatedLast),
      context: sharedContext,
      prompt: prompt
    )

    for index in updatedFirst...updatedLast {
      try checkCancellation(chain: chain)
      if let result = parallelResults[index] {
        chain.results.append(result)
      }
    }

    chain.addStatusMessage("Merging implementer branches...", type: .progress)
    let conflicts = try await mergeImplementerBranches(chain: chain, indices: Array(updatedFirst...updatedLast))
    if !conflicts.isEmpty {
      mergeConflicts = conflicts
      throw NSError(
        domain: "AgentChain",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Merge conflicts detected. Resolve conflicts and re-run the reviewer."]
      )
    }
    chain.addStatusMessage("Merge completed", type: .complete)

    if updatedLast + 1 < chain.agents.count {
      for index in (updatedLast + 1)..<chain.agents.count {
        try checkCancellation(chain: chain)
        await waitForGate(chain: chain)
        let agent = chain.agents[index]
        chain.state = .running(agentIndex: index)
        chain.currentAgentStartTime = Date()
        chain.addStatusMessage("Starting \(agent.name) (\(agent.model.shortName))...", type: .progress)
        let result = try await runSingleAgent(agent, at: index, chain: chain, prompt: prompt)
        chain.results.append(result)
        chain.addStatusMessage("\(agent.name) completed", type: .complete)
      }
    }
  }

  private func runImplementersInParallel(
    chain: AgentChain,
    indices: [Int],
    context: String,
    prompt: String
  ) async throws -> [Int: AgentChainResult] {
    try checkCancellation(chain: chain)
    guard let workingDirectory = chain.workingDirectory else {
      throw NSError(
        domain: "AgentChain",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Select a working directory to create parallel worktrees."]
      )
    }

    let repoURL = URL(fileURLWithPath: workingDirectory)
    let repository = Model.Repository(name: repoURL.lastPathComponent, path: workingDirectory)

    var ragContexts: [UUID: String] = [:]
    for index in indices {
      try checkCancellation(chain: chain)
      let agent = chain.agents[index]
      let task = AgentTask(
        title: "\(chain.name) - \(agent.name)",
        prompt: prompt,
        repositoryPath: workingDirectory
      )
      let workspace = try await agentManager.workspaceManager.createWorkspace(
        for: repository,
        task: task,
        agentId: agent.id
      )
      await mcpLog.info("Parallel implementer workspace created", metadata: [
        "chainId": chain.id.uuidString,
        "agentId": agent.id.uuidString,
        "agentName": agent.name,
        "role": agent.role.displayName,
        "branch": workspace.branch,
        "workingDirectory": workspace.path.path
      ])
      agent.workspace = workspace
      agent.workingDirectory = workspace.path.path

      let storedQuery = UserDefaults.standard.string(forKey: RagDefaults.query) ?? ""
      let ragQuery = storedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? prompt
      : storedQuery
      if let ragContext = await buildRagContext(query: ragQuery, repoPath: workspace.path.path) {
        ragContexts[agent.id] = ragContext
      }
    }

    var results: [Int: AgentChainResult] = [:]
    try await withThrowingTaskGroup(of: (Int, AgentChainResult).self) { group in
      for index in indices {
        let agent = chain.agents[index]
        let agentContext = [context, ragContexts[agent.id]].compactMap { value in
          let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n\n")
        group.addTask {
          try await Task { @MainActor in
            try self.checkCancellation(chain: chain)
            await self.mcpLog.info("Parallel implementer start", metadata: [
              "chainId": chain.id.uuidString,
              "agentId": agent.id.uuidString,
              "agentName": agent.name,
              "role": agent.role.displayName,
              "model": agent.model.displayName,
              "workingDirectory": agent.workingDirectory ?? ""
            ])
            let result = try await self.runSingleAgent(
              agent,
              at: index,
              chain: chain,
              prompt: prompt,
              contextOverride: agentContext
            )
            await self.mcpLog.info("Parallel implementer complete", metadata: [
              "chainId": chain.id.uuidString,
              "agentId": agent.id.uuidString,
              "agentName": agent.name,
              "role": agent.role.displayName,
              "model": agent.model.displayName,
              "duration": result.duration ?? "",
              "premiumCost": "\(result.premiumCost)"
            ])
            return (index, result)
          }.value
        }
      }

      for try await (index, result) in group {
        try checkCancellation(chain: chain)
        results[index] = result
      }
    }

    return results
  }

  private func buildRagContext(query: String, repoPath: String) async -> String? {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return nil }

    let mode = UserDefaults.standard.string(forKey: RagDefaults.searchMode) ?? "text"
    let storedLimit = UserDefaults.standard.integer(forKey: RagDefaults.searchLimit)
    let limit = storedLimit == 0 ? 5 : storedLimit

    do {
      let results: [LocalRAGSearchResult]
      if mode.lowercased() == "vector" {
        results = try await localRagStore.searchVector(query: trimmedQuery, repoPath: repoPath, limit: limit)
      } else {
        results = try await localRagStore.search(query: trimmedQuery, repoPath: repoPath, limit: limit)
      }

      guard !results.isEmpty else { return nil }

      let snippets = results.map { result in
        "- \(result.filePath) [\(result.startLine)-\(result.endLine)]:\n\(result.snippet)"
      }
      return ([
        "Local RAG context for: \"\(trimmedQuery)\"",
        snippets.joined(separator: "\n\n")
      ]).joined(separator: "\n")
    } catch {
      await mcpLog.warning("Local RAG context build failed", metadata: ["error": error.localizedDescription])
      return nil
    }
  }

  private func mergeImplementerBranches(chain: AgentChain, indices: [Int]) async throws -> [String] {
    guard let workingDirectory = chain.workingDirectory else {
      return []
    }

    await mergeCoordinator.acquire(workingDirectory)
    defer {
      Task { await mergeCoordinator.release(workingDirectory) }
    }

    let repoURL = URL(fileURLWithPath: workingDirectory)
    let repository = Model.Repository(name: repoURL.lastPathComponent, path: workingDirectory)

    let statusLines = try await Commands.simple(arguments: ["status", "--porcelain"], in: repository)
    if statusLines.contains(where: { !$0.isEmpty }) {
      await mcpLog.warning("Merge aborted: dirty working tree", metadata: ["repo": workingDirectory])
      throw NSError(
        domain: "AgentChain",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Working tree has uncommitted changes. Clean it before merging."]
      )
    }

    var conflicts: [String] = []
    for index in indices {
      guard let workspace = chain.agents[index].workspace else { continue }
      do {
        _ = try await Commands.simple(arguments: ["merge", "--no-ff", workspace.branch], in: repository)
      } catch {
        _ = try? await Commands.simple(arguments: ["merge", "--abort"], in: repository)
        let conflictLines = try? await Commands.simple(arguments: ["diff", "--name-only", "--diff-filter=U"], in: repository)
        conflicts = conflictLines?.filter { !$0.isEmpty } ?? []
        await mcpLog.warning("Merge conflicts detected", metadata: [
          "repo": workingDirectory,
          "conflicts": conflicts.joined(separator: ", ")
        ])
        break
      }
    }

    return conflicts
  }

  private func runSingleAgent(
    _ agent: Agent,
    at index: Int,
    chain: AgentChain,
    prompt: String,
    contextOverride: String? = nil
  ) async throws -> AgentChainResult {
    try checkCancellation(chain: chain)
    let context = contextOverride ?? chain.contextForAgent(at: index)

    await mcpLog.info("Agent run start", metadata: [
      "chainId": chain.id.uuidString,
      "agentId": agent.id.uuidString,
      "agentName": agent.name,
      "role": agent.role.displayName,
      "model": agent.model.displayName,
      "workingDirectory": agent.workingDirectory ?? chain.workingDirectory ?? ""
    ])

    let fullPrompt = agent.buildPrompt(
      userPrompt: prompt,
      context: context.isEmpty ? nil : context
    )
    agent.updateState(.working)

    do {
      let response = try await cliService.runCopilotSession(
        prompt: fullPrompt,
        model: agent.model,
        role: agent.role,
        workingDirectory: agent.workingDirectory ?? chain.workingDirectory,
        onOutput: { [chain] line in
          let statusLine = self.parseStreamingLine(line)
          if let statusLine {
            chain.addStatusMessage(statusLine.message, type: statusLine.type)
          }
        }
      )

      var premiumCost = agent.model.premiumCost
      if let premiumStr = response.premiumRequests,
         let num = Double(premiumStr.components(separatedBy: " ").first ?? "") {
        premiumCost = num
      }

      var verdict: ReviewVerdict?
      if agent.role == .reviewer {
        verdict = ReviewVerdict.parse(from: response.content)
      }

      var plannerDecision: PlannerDecision?
      if agent.role == .planner {
        plannerDecision = PlannerDecision.parse(from: response.content)
      }

      var result = AgentChainResult(
        agentId: agent.id,
        agentName: agent.name,
        model: agent.model.displayName,
        prompt: fullPrompt,
        output: response.content,
        duration: response.duration,
        premiumCost: premiumCost,
        reviewVerdict: verdict,
        plannerDecision: plannerDecision
      )
      agent.updateState(.complete)
      await mcpLog.info("Agent run complete", metadata: [
        "chainId": chain.id.uuidString,
        "agentId": agent.id.uuidString,
        "agentName": agent.name,
        "role": agent.role.displayName,
        "model": agent.model.displayName,
        "duration": response.duration ?? "",
        "premiumCost": "\(premiumCost)"
      ])

      do {
        let url = try await screenshotService.capture(label: "\(chain.id.uuidString)-\(agent.name)")
        result.screenshotPath = url.path
        chain.addStatusMessage("📸 Screenshot captured", type: .tool)
        await mcpLog.info("Screenshot saved", metadata: ["path": url.path])
      } catch {
        // Non-fatal: log and continue
        await mcpLog.warning("Screenshot failed", metadata: ["error": error.localizedDescription])
        chain.addStatusMessage("Screenshot failed: \(error.localizedDescription)", type: .error)
      }

      return result
    } catch {
      if case ChainError.cancelled = error {
        await mcpLog.warning("Agent run cancelled", metadata: [
          "agent": agent.name,
          "role": agent.role.displayName,
          "model": agent.model.displayName
        ])
        agent.updateState(.failed(message: "Cancelled"))
        throw error
      }
      await mcpLog.error(error, context: "Agent run failed", metadata: [
        "agent": agent.name,
        "role": agent.role.displayName,
        "model": agent.model.displayName
      ])
      agent.updateState(.failed(message: error.localizedDescription))
      throw error
    }
  }

  private func runReviewLoop(chain: AgentChain, prompt: String) async throws {
    guard let initialReviewerResult = chain.results.last(where: { $0.reviewVerdict != nil }),
          let verdict = initialReviewerResult.reviewVerdict,
          verdict == .needsChanges else {
      return
    }

    if chain.pauseOnReview {
      chain.addStatusMessage("Reviewer requested changes. Paused before review loop.", type: .info)
      if let gate = runGates[chain.id] {
        await gate.pause()
      }
      await waitForGate(chain: chain)
    }

    guard let implementerIndex = chain.agents.firstIndex(where: { $0.role == .implementer }),
          let reviewerIndex = chain.agents.firstIndex(where: { $0.role == .reviewer }) else {
      return
    }

    let implementer = chain.agents[implementerIndex]
    let reviewer = chain.agents[reviewerIndex]
    var latestFeedback = initialReviewerResult.output
    var currentPrompt = prompt

    while chain.currentReviewIteration < chain.maxReviewIterations {
      try checkCancellation(chain: chain)
      await waitForGate(chain: chain)
      chain.currentReviewIteration += 1
      chain.state = .reviewing(iteration: chain.currentReviewIteration)

      let feedbackPrompt = """
        The reviewer has requested changes. Here is their feedback:

        \(latestFeedback)

        Please address the feedback and make the necessary changes.
        Original task: \(currentPrompt)
        """

      let originalPrompt = currentPrompt
      currentPrompt = feedbackPrompt

      let implementerResult = try await runSingleAgent(
        implementer,
        at: implementerIndex,
        chain: chain,
        prompt: currentPrompt
      )
      chain.results.append(implementerResult)

      await waitForGate(chain: chain)
      let reviewerResult = try await runSingleAgent(
        reviewer,
        at: reviewerIndex,
        chain: chain,
        prompt: currentPrompt
      )
      chain.results.append(reviewerResult)

      currentPrompt = originalPrompt

      if let newReviewerResult = chain.results.last(where: { $0.reviewVerdict != nil }),
         let newVerdict = newReviewerResult.reviewVerdict {
        if newVerdict == .approved {
          return
        } else if newVerdict == .rejected {
          throw ChainError.reviewRejected(reason: newReviewerResult.output)
        }
        latestFeedback = newReviewerResult.output
      }
    }

    throw ChainError.reviewRejected(
      reason: "Review loop reached maximum iterations (\(chain.maxReviewIterations)) without approval"
    )
  }

  private func parseStreamingLine(_ line: String) -> (message: String, type: LiveStatusMessage.MessageType)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.count < 3 && (trimmed.contains("�") || trimmed.contains("●") || trimmed.contains("○") || trimmed.contains("◐")) {
      return nil
    }

    if trimmed.lowercased().contains("read_file") || trimmed.lowercased().contains("reading") {
      return ("📖 Reading file...", .tool)
    }
    if trimmed.lowercased().contains("write_file") || trimmed.lowercased().contains("writing") ||
       trimmed.lowercased().contains("editing") || trimmed.lowercased().contains("insert_edit") ||
       trimmed.lowercased().contains("replace_string") {
      return ("✏️ Editing file...", .tool)
    }
    if trimmed.lowercased().contains("run_in_terminal") || trimmed.lowercased().contains("running command") {
      return ("⚡ Running command...", .tool)
    }
    if trimmed.lowercased().contains("grep_search") || trimmed.lowercased().contains("searching") {
      return ("🔍 Searching...", .tool)
    }
    if trimmed.lowercased().contains("semantic_search") {
      return ("🧠 Semantic search...", .tool)
    }
    if trimmed.lowercased().contains("list_dir") {
      return ("📁 Listing directory...", .tool)
    }
    if trimmed.lowercased().contains("create_file") {
      return ("📝 Creating file...", .tool)
    }

    let displayLine = trimmed.count > 100 ? String(trimmed.prefix(97)) + "..." : trimmed
    return (displayLine, .progress)
  }

  enum ChainError: LocalizedError {
    case reviewRejected(reason: String)
    case cancelled

    var errorDescription: String? {
      switch self {
      case .reviewRejected(let reason):
        return "Review rejected: \(reason.prefix(200))..."
      case .cancelled:
        return "Chain cancelled"
      }
    }
  }

  private func checkCancellation(chain: AgentChain) throws {
    guard Task.isCancelled else { return }
    chain.state = .failed(message: "Cancelled")
    chain.addStatusMessage("✋ Chain cancelled.", type: .error)
    throw ChainError.cancelled
  }

  private func waitForGate(chain: AgentChain) async {
    if let gate = runGates[chain.id] {
      await gate.waitIfPaused()
    }
  }

  public func pause(chainId: UUID) async {
    if let gate = runGates[chainId] {
      await gate.pause()
    }
  }

  public func resume(chainId: UUID) async {
    if let gate = runGates[chainId] {
      await gate.resume()
    }
  }

  public func step(chainId: UUID) async {
    if let gate = runGates[chainId] {
      await gate.step()
    }
  }
}

// MARK: - MCP Server

@MainActor
@Observable
public final class MCPServerService {
  private let mcpLog = MCPLogService.shared
  private enum StorageKey {
    static let enabled = "mcp.server.enabled"
    static let port = "mcp.server.port"
    static let maxConcurrentChains = "mcp.server.maxConcurrentChains"
    static let maxQueuedChains = "mcp.server.maxQueuedChains"
    static let autoCleanupWorkspaces = "mcp.server.autoCleanupWorkspaces"
    static let toolPermissions = "mcp.server.toolPermissions"
    static let localRagRepoPath = "localrag.repoPath"
    static let localRagQuery = "localrag.query"
    static let localRagSearchMode = "localrag.searchMode"
    static let localRagSearchLimit = "localrag.searchLimit"
    static let localRagUseCoreML = "localrag.useCoreML"
  }

  public enum ToolCategory: String, CaseIterable {
    case chains
    case parallelWorktrees
    case logs
    case server
    case app
    case diagnostics
    case ui
    case state
    case rag

    var displayName: String {
      switch self {
      case .chains: return "Chains"
      case .parallelWorktrees: return "Parallel Worktrees"
      case .logs: return "Logs"
      case .server: return "Server"
      case .app: return "App"
      case .diagnostics: return "Diagnostics"
      case .ui: return "UI Automation"
      case .state: return "State"
      case .rag: return "Local RAG"
      }
    }
  }

  public enum RAGSearchMode: String, CaseIterable {
    case text
    case vector
  }

  public enum ToolGroup: String, CaseIterable {
    case screenshots
    case uiNavigation
    case mutating
    case backgroundSafe

    var displayName: String {
      switch self {
      case .screenshots: return "Screenshots"
      case .uiNavigation: return "UI Navigation"
      case .mutating: return "Mutating"
      case .backgroundSafe: return "Background-safe"
      }
    }
  }

  public struct ToolDefinition: Identifiable {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    public let category: ToolCategory
    public let isMutating: Bool
    public let requiresForeground: Bool

    public var id: String { name }

    public init(
      name: String,
      description: String,
      inputSchema: [String: Any],
      category: ToolCategory,
      isMutating: Bool,
      requiresForeground: Bool = false
    ) {
      self.name = name
      self.description = description
      self.inputSchema = inputSchema
      self.category = category
      self.isMutating = isMutating
      self.requiresForeground = requiresForeground
    }
  }

  public struct ControlDoc: Identifiable {
    public let controlId: String
    public let values: [String]

    public var id: String { controlId }
  }

  public struct ViewControlDoc: Identifiable {
    public let viewId: String
    public let title: String
    public let controls: [ControlDoc]

    public var id: String { viewId }
  }

  public struct UIAction: Identifiable {
    public let id: UUID
    public let controlId: String

    public init(controlId: String) {
      self.id = UUID()
      self.controlId = controlId
    }
  }

  public struct UIActionRecord: Identifiable {
    public let id: UUID
    public let controlId: String
    public let status: String
    public let timestamp: Date

    public init(controlId: String, status: String, timestamp: Date = Date()) {
      self.id = UUID()
      self.controlId = controlId
      self.status = status
      self.timestamp = timestamp
    }
  }

  public var isEnabled: Bool {
    didSet {
      UserDefaults.standard.set(isEnabled, forKey: StorageKey.enabled)
      if isEnabled {
        start()
      } else {
        stop()
      }
    }
  }

  public var port: Int {
    didSet {
      UserDefaults.standard.set(port, forKey: StorageKey.port)
      if isRunning {
        stop()
        start()
      }
    }
  }

  public var maxConcurrentChains: Int {
    didSet {
      if maxConcurrentChains < 1 {
        maxConcurrentChains = 1
      }
      UserDefaults.standard.set(maxConcurrentChains, forKey: StorageKey.maxConcurrentChains)
    }
  }

  public var maxQueuedChains: Int {
    didSet {
      if maxQueuedChains < 0 {
        maxQueuedChains = 0
      }
      UserDefaults.standard.set(maxQueuedChains, forKey: StorageKey.maxQueuedChains)
    }
  }

  public var autoCleanupWorkspaces: Bool {
    didSet {
      UserDefaults.standard.set(autoCleanupWorkspaces, forKey: StorageKey.autoCleanupWorkspaces)
    }
  }

  public private(set) var isRunning: Bool = false
  public var lastError: String?
  public private(set) var activeRequests: Int = 0
  public private(set) var lastRequestMethod: String?
  public private(set) var lastRequestAt: Date?
  public private(set) var lastBlockedTool: String?
  public private(set) var lastBlockedToolAt: Date?
  public private(set) var lastToolRequiresForeground: Bool?
  public private(set) var lastToolRequiresForegroundAt: Date?
  public private(set) var lastUIActionHandled: String?
  public private(set) var lastUIActionHandledAt: Date?
  public private(set) var recentUIActions: [UIActionRecord] = []
  public var isAppActive: Bool {
    NSApp.isActive
  }

  public var isAppFrontmost: Bool {
    NSApp.keyWindow?.isKeyWindow ?? false
  }
  public private(set) var isCleaningAgentWorkspaces: Bool = false
  public private(set) var lastCleanupAt: Date?
  public private(set) var lastCleanupSummary: String?
  public private(set) var lastCleanupError: String?
  public var lastUIAction: UIAction?
  public var localRagRepoPath: String = "" {
    didSet { UserDefaults.standard.set(localRagRepoPath, forKey: StorageKey.localRagRepoPath) }
  }
  public var localRagQuery: String = "" {
    didSet { UserDefaults.standard.set(localRagQuery, forKey: StorageKey.localRagQuery) }
  }
  public var localRagSearchMode: RAGSearchMode = .text {
    didSet { UserDefaults.standard.set(localRagSearchMode.rawValue, forKey: StorageKey.localRagSearchMode) }
  }
  public var localRagSearchLimit: Int = 5 {
    didSet { UserDefaults.standard.set(localRagSearchLimit, forKey: StorageKey.localRagSearchLimit) }
  }
  public var localRagUseCoreML: Bool = false {
    didSet { UserDefaults.standard.set(localRagUseCoreML, forKey: StorageKey.localRagUseCoreML) }
  }
  private(set) var ragStatus: LocalRAGStore.Status?
  private(set) var ragStats: LocalRAGStore.Stats?
  private(set) var lastRagRefreshAt: Date?
  private(set) var lastRagError: String?
  private(set) var lastRagSearchQuery: String?
  private(set) var lastRagSearchMode: RAGSearchMode?
  private(set) var lastRagSearchRepoPath: String?
  private(set) var lastRagSearchLimit: Int?
  private(set) var lastRagSearchAt: Date?
  private(set) var lastRagSearchResults: [LocalRAGSearchResult] = []

  public let agentManager: AgentManager
  public let cliService: CLIService
  public let sessionTracker: SessionTracker
  private let chainRunner: AgentChainRunner
  private var dataService: DataService?
  private let screenshotService = ScreenshotService()
  let translationValidatorService = TranslationValidatorService()
  let piiScrubberService = PIIScrubberService()
  private let localRagStore = LocalRAGStore()
  private(set) var parallelWorktreeRunner: ParallelWorktreeRunner?

  public struct ActiveRunInfo: Identifiable {
    public let id: UUID
    public let chainId: UUID
    public let templateName: String
    public let prompt: String
    public let workingDirectory: String?
    public let enqueuedAt: Date?
    public let startedAt: Date
    public let priority: Int
    public let timeoutSeconds: Double?
  }

  private struct ChainQueueEntry {
    let id: UUID
    let enqueuedAt: Date
    let priority: Int
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var activeChainRuns: Int = 0
  private var activeChainRunIds: Set<UUID> = []
  private var activeChainTasks: [UUID: Task<AgentChainRunner.RunSummary, Never>] = [:]
  private var activeChainTimeouts: [UUID: Task<Void, Never>] = [:]
  private var activeRunsById: [UUID: ActiveRunInfo] = [:]
  private var activeRunChains: [UUID: AgentChain] = [:]
  private var chainQueue: [ChainQueueEntry] = []
  private var completedRunsById: [UUID: (completedAt: Date, payload: [String: Any])] = [:]

  private let listenerQueue = DispatchQueue(label: "MCPServer.Listener")
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]
  private var connectionStates: [UUID: ConnectionState] = [:]
  private var toolPermissions: [String: Bool] = [:] {
    didSet {
      persistToolPermissions()
    }
  }

  private struct ConnectionState {
    var buffer = Data()
  }

  public init(
    agentManager: AgentManager = AgentManager(),
    cliService: CLIService = CLIService(),
    sessionTracker: SessionTracker = SessionTracker()
  ) {
    self.agentManager = agentManager
    self.cliService = cliService
    self.sessionTracker = sessionTracker
    self.chainRunner = AgentChainRunner(
      agentManager: agentManager,
      cliService: cliService,
      sessionTracker: sessionTracker
    )
    self.isEnabled = UserDefaults.standard.bool(forKey: StorageKey.enabled)
    self.port = UserDefaults.standard.integer(forKey: StorageKey.port)
    self.maxConcurrentChains = UserDefaults.standard.integer(forKey: StorageKey.maxConcurrentChains)
    self.maxQueuedChains = UserDefaults.standard.integer(forKey: StorageKey.maxQueuedChains)
    self.autoCleanupWorkspaces = UserDefaults.standard.bool(forKey: StorageKey.autoCleanupWorkspaces)
    self.localRagRepoPath = UserDefaults.standard.string(forKey: StorageKey.localRagRepoPath) ?? ""
    self.localRagQuery = UserDefaults.standard.string(forKey: StorageKey.localRagQuery) ?? ""
    let storedMode = UserDefaults.standard.string(forKey: StorageKey.localRagSearchMode) ?? RAGSearchMode.text.rawValue
    self.localRagSearchMode = RAGSearchMode(rawValue: storedMode) ?? .text
    let storedLimit = UserDefaults.standard.integer(forKey: StorageKey.localRagSearchLimit)
    self.localRagSearchLimit = storedLimit == 0 ? 5 : storedLimit
    self.localRagUseCoreML = UserDefaults.standard.bool(forKey: StorageKey.localRagUseCoreML)
    if self.port == 0 {
      self.port = 8765
    }
    if self.maxConcurrentChains == 0 {
      self.maxConcurrentChains = 1
    }
    if self.maxQueuedChains == 0 {
      self.maxQueuedChains = 10
    }
    loadToolPermissions()

    // Initialize parallel worktree runner
    self.parallelWorktreeRunner = ParallelWorktreeRunner(workspaceService: agentManager.workspaceManager)
    self.parallelWorktreeRunner?.setRAGStore(localRagStore)

    if isEnabled {
      start()
    }
  }

  public var toolCategories: [ToolCategory] {
    ToolCategory.allCases.filter { category in
      toolDefinitions.contains { $0.category == category }
    }
  }

  public var toolGroups: [ToolGroup] {
    ToolGroup.allCases.filter { group in
      toolDefinitions.contains { !groups(for: $0).filter { $0 == group }.isEmpty }
    }
  }

  public var uiControlDocs: [ViewControlDoc] {
    var docs = availableViewIds().map { viewId -> ViewControlDoc in
      let controls = availableControlIds(for: viewId)
      let values = controlValues(for: viewId)
      let controlDocs = controls.map { controlId in
        ControlDoc(controlId: controlId, values: stringValues(values[controlId]))
      }
      return ViewControlDoc(viewId: viewId, title: viewTitle(for: viewId), controls: controlDocs)
    }

    let toolControls = availableToolControlIds().map { controlId in
      ControlDoc(controlId: controlId, values: [])
    }
    if !toolControls.isEmpty {
      docs.insert(
        ViewControlDoc(viewId: "tool-shortcuts", title: "Tool Shortcuts", controls: toolControls),
        at: 0
      )
    }

    return docs
  }

  public func tools(in category: ToolCategory) -> [ToolDefinition] {
    toolDefinitions
      .filter { $0.category == category }
      .sorted { $0.name < $1.name }
  }

  public func toolCount(in category: ToolCategory) -> Int {
    tools(in: category).count
  }

  public func tools(in group: ToolGroup) -> [ToolDefinition] {
    toolDefinitions
      .filter { groups(for: $0).contains(group) }
      .sorted { $0.name < $1.name }
  }

  public func toolCount(in group: ToolGroup) -> Int {
    tools(in: group).count
  }

  public func enabledToolCount(in category: ToolCategory) -> Int {
    tools(in: category).filter { isToolEnabled($0.name) }.count
  }

  public func enabledToolCount(in group: ToolGroup) -> Int {
    tools(in: group).filter { isToolEnabled($0.name) }.count
  }

  public var foregroundToolCount: Int {
    toolDefinitions.filter { $0.requiresForeground }.count
  }

  public var backgroundToolCount: Int {
    toolDefinitions.filter { !$0.requiresForeground }.count
  }

  public var totalToolCount: Int {
    toolDefinitions.count
  }

  public var enabledToolCount: Int {
    toolDefinitions.filter { isToolEnabled($0.name) }.count
  }

  public func isCategoryEnabled(_ category: ToolCategory) -> Bool {
    let tools = tools(in: category)
    return !tools.isEmpty && tools.allSatisfy { isToolEnabled($0.name) }
  }

  public func isGroupEnabled(_ group: ToolGroup) -> Bool {
    let tools = tools(in: group)
    return !tools.isEmpty && tools.allSatisfy { isToolEnabled($0.name) }
  }

  public func setCategoryEnabled(_ category: ToolCategory, enabled: Bool) {
    var updated = toolPermissions
    for tool in tools(in: category) {
      updated[tool.name] = enabled
    }
    toolPermissions = updated
  }

  public func setGroupEnabled(_ group: ToolGroup, enabled: Bool) {
    var updated = toolPermissions
    for tool in tools(in: group) {
      updated[tool.name] = enabled
    }
    toolPermissions = updated
  }

  public func setAllToolsEnabled(_ enabled: Bool) {
    var updated: [String: Bool] = [:]
    for tool in toolDefinitions {
      updated[tool.name] = enabled
    }
    toolPermissions = updated
  }

  public func isToolEnabled(_ name: String) -> Bool {
    guard toolDefinition(named: name) != nil else { return false }
    return true
  }

  public func setToolEnabled(_ name: String, enabled: Bool) {
    guard toolDefinition(named: name) != nil else { return }
    toolPermissions[name] = enabled
  }

  public struct QueuedRunInfo: Identifiable {
    public let id: UUID
    public let enqueuedAt: Date
    public let priority: Int
    public let position: Int
  }

  public var activeRuns: [ActiveRunInfo] {
    activeRunsById.values.sorted { $0.startedAt < $1.startedAt }
  }

  public var queuedRuns: [QueuedRunInfo] {
    chainQueue.enumerated().map { index, entry in
      QueuedRunInfo(id: entry.id, enqueuedAt: entry.enqueuedAt, priority: entry.priority, position: index + 1)
    }
  }

  public func configure(modelContext: ModelContext) {
    if dataService == nil {
      dataService = DataService(modelContext: modelContext)
    }
  }

  public func refreshRagSummary() async {
    do {
      let status = await localRagStore.status()
      let stats = try await localRagStore.stats()
      ragStatus = status
      ragStats = stats
      lastRagError = nil
      lastRagRefreshAt = Date()
    } catch {
      ragStatus = await localRagStore.status()
      ragStats = nil
      lastRagError = error.localizedDescription
      lastRagRefreshAt = Date()
    }
  }

  func initializeRag(extensionPath: String? = nil) async throws {
    let status = try await localRagStore.initialize(extensionPath: extensionPath)
    ragStatus = status
    ragStats = try await localRagStore.stats()
    lastRagError = nil
    lastRagRefreshAt = Date()
  }

  func indexRag(repoPath: String) async throws -> LocalRAGIndexReport {
    let report = try await localRagStore.indexRepository(path: repoPath)
    ragStatus = await localRagStore.status()
    ragStats = try await localRagStore.stats()
    lastRagError = nil
    lastRagRefreshAt = Date()
    return report
  }

  func searchRag(
    query: String,
    mode: RAGSearchMode,
    repoPath: String? = nil,
    limit: Int = 10
  ) async throws -> [LocalRAGSearchResult] {
    let results: [LocalRAGSearchResult]
    switch mode {
    case .vector:
      results = try await localRagStore.searchVector(query: query, repoPath: repoPath, limit: limit)
    case .text:
      results = try await localRagStore.search(query: query, repoPath: repoPath, limit: limit)
    }
    lastRagSearchQuery = query
    lastRagSearchMode = mode
    lastRagSearchRepoPath = repoPath
    lastRagSearchLimit = limit
    lastRagSearchAt = Date()
    lastRagSearchResults = results
    lastRagError = nil
    return results
  }

  private func buildRagContext(query: String, repoPath: String) async -> String? {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return nil }

    do {
      let results = try await searchRag(
        query: trimmedQuery,
        mode: localRagSearchMode,
        repoPath: repoPath,
        limit: localRagSearchLimit
      )
      guard !results.isEmpty else { return nil }

      let snippets = results.map { result in
        "- \(result.filePath) [\(result.startLine)-\(result.endLine)]:\n\(result.snippet)"
      }
      return ([
        "Local RAG context for: \"\(trimmedQuery)\"",
        snippets.joined(separator: "\n\n")
      ]).joined(separator: "\n")
    } catch {
      await mcpLog.warning("Local RAG context build failed", metadata: ["error": error.localizedDescription])
      return nil
    }
  }

  public struct RunOverrides {
    public var enableReviewLoop: Bool? = nil
    public var pauseOnReview: Bool? = nil
    public var allowPlannerModelSelection: Bool = false
    public var allowPlannerImplementerScaling: Bool = false
    public var maxImplementers: Int? = nil
    public var maxPremiumCost: Double? = nil
    public var priority: Int = 0
    public var timeoutSeconds: Double? = nil

    public init() {}
  }

  public func pauseRun(_ runId: UUID) async {
    if let chain = activeRunChains[runId] {
      await chainRunner.pause(chainId: chain.id)
    }
  }

  public func resumeRun(_ runId: UUID) async {
    if let chain = activeRunChains[runId] {
      await chainRunner.resume(chainId: chain.id)
    }
  }

  public func stepRun(_ runId: UUID) async {
    if let chain = activeRunChains[runId] {
      await chainRunner.step(chainId: chain.id)
    }
  }

  public func stopRun(_ runId: UUID) async {
    if let task = activeChainTasks[runId] {
      task.cancel()
    }
  }

  public func cancelQueuedRun(_ runId: UUID) async -> Bool {
    return cancelQueuedRunInternal(runId: runId)
  }

  func rerun(_ record: MCPRunRecord, overrides: RunOverrides = RunOverrides()) async {
    var arguments: [String: Any] = [
      "templateName": record.templateName,
      "prompt": record.prompt,
      "workingDirectory": record.workingDirectory ?? ""
    ]
    if let enableReviewLoop = overrides.enableReviewLoop {
      arguments["enableReviewLoop"] = enableReviewLoop
    }
    if let pauseOnReview = overrides.pauseOnReview {
      arguments["pauseOnReview"] = pauseOnReview
    }
    arguments["allowPlannerModelSelection"] = overrides.allowPlannerModelSelection
    arguments["allowPlannerImplementerScaling"] = overrides.allowPlannerImplementerScaling
    if let maxImplementers = overrides.maxImplementers {
      arguments["maxImplementers"] = maxImplementers
    }
    if let maxPremiumCost = overrides.maxPremiumCost {
      arguments["maxPremiumCost"] = maxPremiumCost
    }
    if overrides.priority != 0 {
      arguments["priority"] = overrides.priority
    }
    if let timeoutSeconds = overrides.timeoutSeconds {
      arguments["timeoutSeconds"] = timeoutSeconds
    }
    _ = await handleChainRun(id: nil, arguments: arguments)
  }

  public func cleanupWorktrees(paths: [String]) async {
    guard !paths.isEmpty else { return }
    for path in paths {
      guard let workspace = agentManager.workspaceManager.workspaces.first(where: { $0.path.path == path }) else {
        continue
      }
      let repository = Model.Repository(
        name: workspace.parentRepositoryPath.lastPathComponent,
        path: workspace.parentRepositoryPath.path
      )
      let branch = workspace.branch
      try? await agentManager.workspaceManager.cleanupWorkspace(workspace, force: true)
      if !branch.isEmpty {
        _ = try? await Commands.simple(arguments: ["branch", "-D", branch], in: repository)
      }
    }
  }

  public func start() {
    guard !isRunning else { return }
    lastError = nil

    guard port >= 1024 && port <= 65535 else {
      lastError = "Port must be between 1024 and 65535"
      return
    }

    do {
      let portValue = NWEndpoint.Port(rawValue: UInt16(port))
      guard let portValue else {
        lastError = "Invalid port"
        return
      }

      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      let listener = try NWListener(using: parameters, on: portValue)

      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        Task { @MainActor in
          switch state {
          case .ready:
            self.isRunning = true
            self.lastError = nil
          case .failed(let error):
            self.lastError = error.localizedDescription
            self.isRunning = false
          default:
            break
          }
        }
      }

      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in
          self?.handleConnection(connection)
        }
      }

      listener.start(queue: listenerQueue)
      self.listener = listener
    } catch {
      lastError = error.localizedDescription
      isRunning = false
    }
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    for connection in connections.values {
      connection.cancel()
    }
    connections = [:]
    connectionStates = [:]
    isRunning = false
  }

  private func handleConnection(_ connection: NWConnection) {
    guard isLocalConnection(connection) else {
      connection.cancel()
      return
    }

    let id = UUID()
    connections[id] = connection
    connectionStates[id] = ConnectionState()

    connection.stateUpdateHandler = { [weak self] state in
      guard case .failed = state else { return }
      Task { @MainActor in
        self?.closeConnection(id)
      }
    }

    connection.start(queue: listenerQueue)
    receive(on: connection, id: id)
  }

  private func receive(on connection: NWConnection, id: UUID) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      Task { @MainActor in
        guard let self else { return }
        if let data, !data.isEmpty {
          self.connectionStates[id]?.buffer.append(data)
          self.processBuffer(for: id, connection: connection)
        }

        if isComplete || error != nil {
          self.closeConnection(id)
        } else {
          self.receive(on: connection, id: id)
        }
      }
    }
  }

  private func processBuffer(for id: UUID, connection: NWConnection) {
    guard var state = connectionStates[id] else { return }
    if let request = parseRequest(from: &state.buffer) {
      connectionStates[id] = state
      handleRequest(request, on: connection)
    } else {
      connectionStates[id] = state
    }
  }

  private func closeConnection(_ id: UUID) {
    connections[id]?.cancel()
    connections[id] = nil
    connectionStates[id] = nil
  }

  private func isLocalConnection(_ connection: NWConnection) -> Bool {
    switch connection.endpoint {
    case .hostPort(let host, _):
      switch host {
      case .ipv4(let address):
        return address == IPv4Address("127.0.0.1")
      case .ipv6(let address):
        return address == IPv6Address("::1")
      case .name(let name, _):
        return name == "localhost"
      default:
        return false
      }
    default:
      return false
    }
  }

  private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }

  private func parseRequest(from buffer: inout Data) -> HTTPRequest? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerRange = buffer.range(of: delimiter) else { return nil }

    let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

    let lines = headerText.split(separator: "\r\n")
    guard let requestLine = lines.first else { return nil }

    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else { return nil }

    let method = String(requestParts[0])
    let path = String(requestParts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      if let separatorIndex = line.firstIndex(of: ":") {
        let key = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
        headers[key.lowercased()] = value
      }
    }

    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = headerRange.upperBound
    let totalLength = bodyStart + contentLength
    guard buffer.count >= totalLength else { return nil }

    let body = buffer.subdata(in: bodyStart..<totalLength)
    buffer.removeSubrange(0..<totalLength)

    return HTTPRequest(method: method, path: path, headers: headers, body: body)
  }

  private func handleRequest(_ request: HTTPRequest, on connection: NWConnection) {
    guard request.method.uppercased() == "POST", request.path == "/rpc" else {
      sendHTTPResponse(status: 404, body: Data("{\"error\":\"Not Found\"}".utf8), on: connection)
      return
    }

    Task {
      let (status, responseBody) = await handleRPC(body: request.body)
      sendHTTPResponse(status: status, body: responseBody, on: connection)
    }
  }

  private func handleRPC(body: Data) async -> (Int, Data) {
    let startTime = Date()
    var methodForLog = "unknown"
    var statusCode = 500
    defer {
      let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
      Task { await mcpLog.info("RPC complete", metadata: [
        "method": methodForLog,
        "durationMs": "\(durationMs)",
        "status": "\(statusCode)"
      ]) }
    }
    activeRequests += 1
    defer { activeRequests -= 1 }
    do {
      let json = try JSONSerialization.jsonObject(with: body, options: [])
      guard let dict = json as? [String: Any] else {
        await mcpLog.warning("Invalid RPC request: non-object JSON")
        methodForLog = "invalid"
        statusCode = 400
        return (400, makeRPCError(id: nil, code: -32600, message: "Invalid Request"))
      }

      let method = dict["method"] as? String ?? ""
      let id = dict["id"]
      let params = dict["params"] as? [String: Any]
      lastRequestAt = Date()
      if method == "tools/call",
         let params,
         let toolName = params["name"] as? String {
        lastRequestMethod = "tools/call: \(toolName)"
        methodForLog = "tools/call: \(toolName)"
      } else {
        lastRequestMethod = method
        methodForLog = method
      }

      switch method {
      case "initialize":
        let result: [String: Any] = [
          "serverInfo": ["name": "Peel MCP Test Harness", "version": "0.1"],
          "capabilities": ["tools": [:]]
        ]
        statusCode = 200
        return (200, makeRPCResult(id: id, result: result))

      case "tools/list":
        statusCode = 200
        return (200, makeRPCResult(id: id, result: ["tools": toolList()]))

      case "tools/call":
        let result = await handleToolCall(id: id, params: params)
        statusCode = result.0
        return result

      default:
        await mcpLog.warning("RPC method not found", metadata: ["method": method])
        statusCode = 400
        return (400, makeRPCError(id: id, code: -32601, message: "Method not found"))
      }
    } catch {
      await mcpLog.error(error, context: "RPC handling failed")
      statusCode = 500
      return (500, makeRPCError(id: nil, code: -32603, message: error.localizedDescription))
    }
  }

  private func handleToolCall(id: Any?, params: [String: Any]?) async -> (Int, Data) {
    guard let params, let name = params["name"] as? String else {
      await mcpLog.warning("Invalid tool call params")
      return (400, makeRPCError(id: id, code: -32602, message: "Invalid params"))
    }

    guard let tool = toolDefinition(named: name) else {
      await mcpLog.warning("Unknown tool", metadata: ["name": name])
      return (400, makeRPCError(id: id, code: -32601, message: "Unknown tool"))
    }

    lastToolRequiresForeground = tool.requiresForeground
    lastToolRequiresForegroundAt = Date()

    if tool.requiresForeground && !NSApp.isActive {
      await mcpLog.warning("Foreground tool called while app inactive", metadata: ["name": tool.name])
      recordUIActionForegroundNeeded(tool.name)
    }

    if !isToolEnabled(name) {
      await mcpLog.warning("Tool disabled", metadata: ["name": name, "category": tool.category.rawValue])
      lastBlockedTool = name
      lastBlockedToolAt = Date()
      return (400, makeRPCError(id: id, code: -32010, message: "Tool disabled"))
    }

    let arguments = params["arguments"] as? [String: Any] ?? [:]

    switch name {
    case "ui.tap":
      return handleUITap(id: id, arguments: arguments)

    case "ui.setText":
      return handleUISetText(id: id, arguments: arguments)

    case "ui.toggle":
      return handleUIToggle(id: id, arguments: arguments)

    case "ui.select":
      return handleUISelect(id: id, arguments: arguments)

    case "ui.navigate":
      return handleUINavigate(id: id, arguments: arguments)

    case "ui.back":
      return handleUIBack(id: id)

    case "ui.snapshot":
      return handleUISnapshot(id: id)

    case "state.get":
      return handleStateGet(id: id)

    case "state.readonly":
      return handleStateGet(id: id)

    case "state.list":
      return handleStateList(id: id)

    case "rag.status":
      return await handleRagStatus(id: id)

    case "rag.init":
      return await handleRagInit(id: id, arguments: arguments)

    case "rag.index":
      return await handleRagIndex(id: id, arguments: arguments)

    case "rag.search":
      return await handleRagSearch(id: id, arguments: arguments)

    case "rag.model.describe":
      return await handleRagModelDescribe(id: id, arguments: arguments)

    case "rag.ui.status":
      return await handleRagUIStatus(id: id)

    case "templates.list":
      let templates = templateList()
      return (200, makeRPCResult(id: id, result: ["templates": templates]))

    case "chains.run":
      return await handleChainRun(id: id, arguments: arguments)

    case "chains.runBatch":
      return await handleChainRunBatch(id: id, arguments: arguments)

    case "chains.run.status":
      return handleChainRunStatus(id: id, arguments: arguments)

    case "chains.run.list":
      return handleChainRunList(id: id, arguments: arguments)

    case "workspaces.agent.list":
      return handleAgentWorkspacesList(id: id, arguments: arguments)

    case "workspaces.agent.cleanup.status":
      return handleAgentWorkspacesCleanupStatus(id: id)

    case "chains.stop":
      return await handleChainStop(id: id, arguments: arguments)

    case "chains.pause":
      return await handleChainPause(id: id, arguments: arguments)

    case "chains.resume":
      return await handleChainResume(id: id, arguments: arguments)

    case "chains.step":
      return await handleChainStep(id: id, arguments: arguments)

    case "chains.queue.status":
      return (200, makeRPCResult(id: id, result: queueStatus()))

    case "chains.queue.configure":
      return handleQueueConfigure(id: id, arguments: arguments)

    case "chains.queue.cancel":
      return await handleQueueCancel(id: id, arguments: arguments)

    case "logs.mcp.path":
      return (200, makeRPCResult(id: id, result: ["path": await mcpLog.logPath()]))

    case "logs.mcp.tail":
      let lines = arguments["lines"] as? Int ?? 200
      let text = await mcpLog.tail(lines: lines)
      return (200, makeRPCResult(id: id, result: ["text": text]))

    case "server.restart":
      return await handleServerRestart(id: id)

    case "server.port.set":
      return await handleServerPortSet(id: id, arguments: arguments)

    case "server.status":
      return handleServerStatus(id: id)

    case "server.stop":
      stop()
      return (200, makeRPCResult(id: id, result: ["status": "stopped"]))

    case "app.quit":
      scheduleAppQuit()
      return (200, makeRPCResult(id: id, result: ["status": "quitting"]))

    case "app.activate":
      activateApp()
      return (200, makeRPCResult(id: id, result: ["status": "activated"]))

    case "screenshot.capture":
      let label = arguments["label"] as? String
      do {
        let url = try await screenshotService.capture(label: label)
        return (200, makeRPCResult(id: id, result: ["path": url.path]))
      } catch {
        await mcpLog.warning("Screenshot tool failed", metadata: ["error": error.localizedDescription])
        return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
      }

    case "translations.validate":
      return await handleTranslationsValidate(id: id, arguments: arguments)

    case "pii.scrub":
      return await handlePIIScrub(id: id, arguments: arguments)

    // Parallel Worktree Tools
    case "parallel.create":
      return await handleParallelCreate(id: id, arguments: arguments)

    case "parallel.start":
      return await handleParallelStart(id: id, arguments: arguments)

    case "parallel.status":
      return handleParallelStatus(id: id, arguments: arguments)

    case "parallel.list":
      return handleParallelList(id: id, arguments: arguments)

    case "parallel.approve":
      return handleParallelApprove(id: id, arguments: arguments)

    case "parallel.reject":
      return handleParallelReject(id: id, arguments: arguments)

    case "parallel.merge":
      return await handleParallelMerge(id: id, arguments: arguments)

    case "parallel.cancel":
      return await handleParallelCancel(id: id, arguments: arguments)

    default:
      await mcpLog.warning("Unknown tool", metadata: ["name": name])
      return (400, makeRPCError(id: id, code: -32601, message: "Unknown tool"))
    }
  }

  private func handleUINavigate(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let viewId = (arguments["viewId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !viewId.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing viewId"))
    }

    guard availableViewIds().contains(viewId) else {
      return (404, makeRPCError(id: id, code: -32020, message: "Unknown viewId"))
    }

    recordUIActionRequested("ui.navigate:\(viewId)")
    setCurrentToolId(viewId)
    recordUIActionHandled("ui.navigate:\(viewId)")
    return (200, makeRPCResult(id: id, result: ["viewId": viewId, "status": "navigated"]))
  }

  private func handleUITap(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let controlId = (arguments["controlId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !controlId.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing controlId"))
    }

    let currentViewId = currentToolId()
    let availableControls = availableToolControlIds() + availableControlIds(for: currentViewId)
    guard availableControls.contains(controlId) else {
      return (404, makeRPCError(id: id, code: -32022, message: "Unknown controlId"))
    }

    recordUIActionRequested(controlId)
    if controlId.hasPrefix("tool.") {
      let toolId = controlId.replacingOccurrences(of: "tool.", with: "")
      setCurrentToolId(toolId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "status": "tapped"]))
    }

    if controlId.hasPrefix("agents.") {
      UserDefaults.standard.set(controlId, forKey: "agents.selectedInfrastructure")
    }

    lastUIAction = UIAction(controlId: controlId)
    return (200, makeRPCResult(id: id, result: ["controlId": controlId, "status": "queued"]))
  }

  private func handleUISetText(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let controlId = (arguments["controlId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !controlId.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing controlId"))
    }
    let value = arguments["value"] as? String ?? ""

    switch controlId {
    case "brew.search":
      UserDefaults.standard.set(value, forKey: "brew.searchText")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "agents.localRag.repoPath":
      localRagRepoPath = value
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "agents.localRag.query":
      localRagQuery = value
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    default:
      break
    }
    return (400, makeRPCError(id: id, code: -32024, message: "setText not supported"))
  }

  private func handleUIToggle(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let controlId = (arguments["controlId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !controlId.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing controlId"))
    }
    let value = arguments["on"] as? Bool

    switch controlId {
    case "github.showArchived":
      let current = UserDefaults.standard.bool(forKey: "github-show-archived")
      let next = value ?? !current
      UserDefaults.standard.set(next, forKey: "github-show-archived")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": next]))
    case "agents.localRag.useCoreML":
      let current = UserDefaults.standard.bool(forKey: StorageKey.localRagUseCoreML)
      let next = value ?? !current
      localRagUseCoreML = next
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": next]))
    default:
      return (400, makeRPCError(id: id, code: -32025, message: "toggle not supported"))
    }
  }

  private func handleUISelect(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let controlId = (arguments["controlId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !controlId.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing controlId"))
    }
    let value = (arguments["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    switch controlId {
    case "brew.source":
      guard value == "Installed" || value == "Available" else {
        return (400, makeRPCError(id: id, code: -32602, message: "Invalid value"))
      }
      UserDefaults.standard.set(value, forKey: "brew.source")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "agents.localRag.mode":
      let normalized = value.lowercased()
      guard let mode = RAGSearchMode(rawValue: normalized) else {
        return (400, makeRPCError(id: id, code: -32602, message: "Invalid value"))
      }
      localRagSearchMode = mode
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": mode.rawValue]))
    case "agents.localRag.limit":
      guard let parsed = Int(value), (1...25).contains(parsed) else {
        return (400, makeRPCError(id: id, code: -32602, message: "Invalid value"))
      }
      localRagSearchLimit = parsed
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": parsed]))
    case "workspaces.selectWorkspace":
      UserDefaults.standard.set(value, forKey: "workspaces.selectedWorkspaceName")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "workspaces.selectRepo":
      UserDefaults.standard.set(value, forKey: "workspaces.selectedRepoName")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "workspaces.selectWorktree":
      UserDefaults.standard.set(value, forKey: "workspaces.selectedWorktreePath")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "workspaces.selectWorktreeName":
      let nameMap = worktreeNameMapFromDefaults()
      guard let path = nameMap[value], !path.isEmpty else {
        return (400, makeRPCError(id: id, code: -32602, message: "Unknown worktree name"))
      }
      UserDefaults.standard.set(value, forKey: "workspaces.selectedWorktreeName")
      UserDefaults.standard.set(path, forKey: "workspaces.selectedWorktreePath")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value, "path": path]))
    case "git.selectRepo":
      UserDefaults.standard.set(value, forKey: "git.selectedRepoPath")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "github.selectFavorite":
      UserDefaults.standard.set(value, forKey: "github.selectedFavoriteKey")
      UserDefaults.standard.set("", forKey: "github.selectedRecentPRKey")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "github.selectRecentPR":
      UserDefaults.standard.set(value, forKey: "github.selectedRecentPRKey")
      UserDefaults.standard.set("", forKey: "github.selectedFavoriteKey")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    default:
      return (400, makeRPCError(id: id, code: -32026, message: "select not supported"))
    }
  }

  private func handleUIBack(id: Any?) -> (Int, Data) {
    guard let current = currentToolId() else {
      return (400, makeRPCError(id: id, code: -32021, message: "Back not supported"))
    }

    let viewIds = availableViewIds()
    guard let index = viewIds.firstIndex(of: current), index > 0 else {
      return (400, makeRPCError(id: id, code: -32021, message: "Back not supported"))
    }
    let previous = viewIds[index - 1]
    setCurrentToolId(previous)
    return (200, makeRPCResult(id: id, result: ["viewId": previous, "status": "navigated"]))
  }

  private func handleUISnapshot(id: Any?) -> (Int, Data) {
    let currentViewId = currentToolId()
    let controls = availableToolControlIds() + availableControlIds(for: currentViewId)
    let controlValues = controlValues(for: currentViewId)
    let snapshot: [String: Any] = [
      "currentViewId": currentViewId as Any,
      "availableViewIds": availableViewIds(),
      "controls": controls,
      "controlValues": controlValues
    ]
    return (200, makeRPCResult(id: id, result: snapshot))
  }

  private func handleStateGet(id: Any?) -> (Int, Data) {
    let showArchived = UserDefaults.standard.bool(forKey: "github-show-archived")
    let brewSource = UserDefaults.standard.string(forKey: "brew.source")
    let brewSearch = UserDefaults.standard.string(forKey: "brew.searchText")
    let workspaceName = UserDefaults.standard.string(forKey: "workspaces.selectedWorkspaceName")
    let repoName = UserDefaults.standard.string(forKey: "workspaces.selectedRepoName")
    let worktreePath = UserDefaults.standard.string(forKey: "workspaces.selectedWorktreePath")
    let worktreeName = UserDefaults.standard.string(forKey: "workspaces.selectedWorktreeName")
    let workspaceNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableNames")
    let repoNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableRepoNames")
    let worktreePaths = UserDefaults.standard.stringArray(forKey: "workspaces.availableWorktreePaths")
    let worktreeNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableWorktreeNames")
    let favoriteKeys = UserDefaults.standard.stringArray(forKey: "github.availableFavoriteKeys")
    let recentPRKeys = UserDefaults.standard.stringArray(forKey: "github.availableRecentPRKeys")
    let selectedFavoriteKey = UserDefaults.standard.string(forKey: "github.selectedFavoriteKey")
    let selectedRecentPRKey = UserDefaults.standard.string(forKey: "github.selectedRecentPRKey")
    let gitRepoPaths = UserDefaults.standard.stringArray(forKey: "git.availableRepoPaths")
    let gitRepoNames = UserDefaults.standard.stringArray(forKey: "git.availableRepoNames")
    let gitSelectedRepo = UserDefaults.standard.string(forKey: "git.selectedRepoPath")
    let formatter = ISO8601DateFormatter()
    let uniqueGitRepoPaths = dedupeStrings(gitRepoPaths)
    let uniqueGitRepoNames = dedupeStrings(gitRepoNames)
    let uniqueWorkspaceNames = dedupeStrings(workspaceNames)
    let uniqueRepoNames = dedupeStrings(repoNames)
    let uniqueWorktreePaths = dedupeStrings(worktreePaths)
    let uniqueWorktreeNames = dedupeStrings(worktreeNames)
    let uniqueFavoriteKeys = dedupeStrings(favoriteKeys)
    let uniqueRecentPRKeys = dedupeStrings(recentPRKeys)
    let recentActions = recentUIActions.prefix(10).map { action in
      [
        "controlId": action.controlId,
        "status": action.status,
        "timestamp": formatter.string(from: action.timestamp)
      ]
    }
    let state: [String: Any] = [
      "currentTool": currentToolId() as Any,
      "mcpRunning": isRunning,
      "activeRequests": activeRequests,
      "appActive": isAppActive,
      "appFrontmost": isAppFrontmost,
      "lastRequestAt": lastRequestAt?.formatted() as Any,
      "githubShowArchived": showArchived,
      "brewSource": brewSource as Any,
      "brewSearchText": brewSearch as Any,
      "workspacesSelectedWorkspace": workspaceName as Any,
      "workspacesSelectedRepo": repoName as Any,
      "workspacesSelectedWorktree": worktreePath as Any,
      "workspacesSelectedWorktreeName": worktreeName as Any,
      "workspacesAvailable": uniqueWorkspaceNames as Any,
      "workspacesAvailableRepos": uniqueRepoNames as Any,
      "workspacesAvailableWorktrees": uniqueWorktreePaths as Any,
      "workspacesAvailableWorktreeNames": uniqueWorktreeNames as Any,
      "githubAvailableFavorites": uniqueFavoriteKeys as Any,
      "githubAvailableRecentPRs": uniqueRecentPRKeys as Any,
      "githubSelectedFavorite": selectedFavoriteKey as Any,
      "githubSelectedRecentPR": selectedRecentPRKey as Any,
      "gitAvailableRepos": uniqueGitRepoPaths as Any,
      "gitAvailableRepoNames": uniqueGitRepoNames as Any,
      "gitSelectedRepo": gitSelectedRepo as Any,
      "lastUIActionHandled": lastUIActionHandled as Any,
      "lastUIActionHandledAt": lastUIActionHandledAt.map { formatter.string(from: $0) } as Any,
      "pendingUIAction": lastUIAction?.controlId as Any,
      "lastToolRequiresForeground": lastToolRequiresForeground as Any,
      "recentUIActions": recentActions
    ]
    return (200, makeRPCResult(id: id, result: state))
  }

  private func handleStateList(id: Any?) -> (Int, Data) {
    let currentViewId = currentToolId()
    let controls = availableToolControlIds() + availableControlIds(for: currentViewId)
    let controlsByView = Dictionary(uniqueKeysWithValues: availableViewIds().map { viewId in
      (viewId, availableControlIds(for: viewId))
    })
    let controlValuesByView = Dictionary(uniqueKeysWithValues: availableViewIds().map { viewId in
      (viewId, controlValues(for: viewId))
    })
    let toolForegroundByName = Dictionary(uniqueKeysWithValues: toolDefinitions.map { tool in
      (tool.name, tool.requiresForeground)
    })
    let toolGroupsByName = Dictionary(uniqueKeysWithValues: toolDefinitions.map { tool in
      (tool.name, groups(for: tool).map { $0.rawValue })
    })
    let state: [String: Any] = [
      "views": availableViewIds(),
      "tools": toolDefinitions.map { $0.name },
      "controls": controls,
      "controlsByView": controlsByView,
      "controlValuesByView": controlValuesByView,
      "toolRequiresForeground": toolForegroundByName,
      "toolGroups": toolGroupsByName,
      "toolGroupList": toolGroups.map { $0.rawValue },
      "currentViewId": currentViewId as Any
    ]
    return (200, makeRPCResult(id: id, result: state))
  }

  private func handleTranslationsValidate(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let root = (arguments["root"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let translationsPath = arguments["translationsPath"] as? String
    let baseLocale = arguments["baseLocale"] as? String
    let only = arguments["only"] as? String
    let summaryOnly = arguments["summary"] as? Bool ?? false
    let useAppleAI = arguments["useAppleAI"] as? Bool ?? false
    let redactSamples = arguments["redactSamples"] as? Bool ?? true
    let toolPath = arguments["toolPath"] as? String

    guard let root, !root.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing root"))
    }

    let options = TranslationValidatorService.Options(
      root: root,
      translationsPath: translationsPath,
      baseLocale: baseLocale,
      only: only,
      summary: summaryOnly,
      toolPath: toolPath,
      useAppleAI: useAppleAI,
      redactSamples: redactSamples
    )

    do {
      let report = try await translationValidatorService.runValidator(options: options)
      let summary = report.summary()
      return (200, makeRPCResult(id: id, result: [
        "report": encodeJSON(report),
        "summary": encodeJSON(summary)
      ]))
    } catch {
      await mcpLog.warning("Translation validation failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }


  private func handlePIIScrub(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let inputPath = (arguments["inputPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let outputPath = (arguments["outputPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let reportPath = (arguments["reportPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let reportFormat = (arguments["reportFormat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let configPath = (arguments["configPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let seed = (arguments["seed"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let maxSamples = arguments["maxSamples"] as? Int
    let enableNER = arguments["enableNER"] as? Bool ?? false
    let toolPath = arguments["toolPath"] as? String

    guard let inputPath, !inputPath.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing inputPath"))
    }
    guard let outputPath, !outputPath.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing outputPath"))
    }

    let options = PIIScrubberService.Options(
      inputPath: inputPath,
      outputPath: outputPath,
      reportPath: reportPath,
      reportFormat: reportFormat,
      configPath: configPath,
      seed: seed,
      maxSamples: maxSamples,
      enableNER: enableNER,
      toolPath: toolPath
    )

    do {
      let result = try await piiScrubberService.runScrubber(options: options)
      var payload: [String: Any] = [
        "inputPath": result.inputPath,
        "outputPath": result.outputPath,
        "reportPath": result.reportPath as Any
      ]
      if let report = result.report {
        payload["report"] = encodeJSON(report)
      }
      return (200, makeRPCResult(id: id, result: payload))
    } catch {
      await mcpLog.warning("PII scrubber failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  // MARK: - Parallel Worktree Handlers

  private func handleParallelCreate(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = parallelWorktreeRunner else {
      return (500, makeRPCError(id: id, code: -32001, message: "Parallel worktree runner not initialized"))
    }

    guard let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing name"))
    }

    guard let projectPath = (arguments["projectPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !projectPath.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing projectPath"))
    }

    guard let tasksArray = arguments["tasks"] as? [[String: Any]], !tasksArray.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or empty tasks array"))
    }

    let baseBranch = (arguments["baseBranch"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
    let targetBranch = arguments["targetBranch"] as? String
    let requireReviewGate = arguments["requireReviewGate"] as? Bool ?? true
    let autoMergeOnApproval = arguments["autoMergeOnApproval"] as? Bool ?? false

    // Parse tasks
    let tasks: [WorktreeTask] = tasksArray.compactMap { taskDict in
      guard let title = (taskDict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty,
            let prompt = (taskDict["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty else {
        return nil
      }
      let description = taskDict["description"] as? String ?? ""
      let focusPaths = taskDict["focusPaths"] as? [String] ?? []
      return WorktreeTask(
        title: title,
        description: description,
        prompt: prompt,
        focusPaths: focusPaths
      )
    }

    guard tasks.count == tasksArray.count else {
      return (400, makeRPCError(id: id, code: -32602, message: "Invalid task format - each task needs title and prompt"))
    }

    let run = runner.createRun(
      name: name,
      projectPath: projectPath,
      tasks: tasks,
      baseBranch: baseBranch,
      targetBranch: targetBranch,
      requireReviewGate: requireReviewGate,
      autoMergeOnApproval: autoMergeOnApproval
    )

    await mcpLog.info("Parallel run created", metadata: [
      "runId": run.id.uuidString,
      "name": name,
      "taskCount": "\(tasks.count)"
    ])

    return (200, makeRPCResult(id: id, result: encodeParallelRun(run)))
  }

  private func handleParallelStart(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = parallelWorktreeRunner else {
      return (500, makeRPCError(id: id, code: -32001, message: "Parallel worktree runner not initialized"))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
    }

    await mcpLog.info("Starting parallel run", metadata: ["runId": runId.uuidString])

    // Start the run in a task so we don't block
    Task {
      do {
        try await runner.startRun(run)
        await mcpLog.info("Parallel run completed", metadata: [
          "runId": runId.uuidString,
          "status": run.status.displayName
        ])
      } catch {
        await mcpLog.error(error, context: "Parallel run failed")
      }
    }

    return (200, makeRPCResult(id: id, result: [
      "runId": runId.uuidString,
      "status": "starting"
    ]))
  }

  private func handleParallelStatus(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = parallelWorktreeRunner else {
      return (500, makeRPCError(id: id, code: -32001, message: "Parallel worktree runner not initialized"))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
    }

    return (200, makeRPCResult(id: id, result: encodeParallelRun(run, includeDetails: true)))
  }

  private func handleParallelList(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = parallelWorktreeRunner else {
      return (500, makeRPCError(id: id, code: -32001, message: "Parallel worktree runner not initialized"))
    }

    let includeCompleted = arguments["includeCompleted"] as? Bool ?? false

    let runs = runner.runs.filter { run in
      if includeCompleted { return true }
      switch run.status {
      case .completed, .cancelled, .failed: return false
      default: return true
      }
    }

    let result: [[String: Any]] = runs.map { encodeParallelRun($0) }
    return (200, makeRPCResult(id: id, result: ["runs": result]))
  }

  private func handleParallelApprove(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = parallelWorktreeRunner else {
      return (500, makeRPCError(id: id, code: -32001, message: "Parallel worktree runner not initialized"))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
    }

    let approveAll = arguments["approveAll"] as? Bool ?? false

    if approveAll {
      runner.approveAllPending(in: run)
      return (200, makeRPCResult(id: id, result: [
        "runId": runId.uuidString,
        "approved": "all",
        "pendingReviewCount": run.pendingReviewCount
      ]))
    }

    guard let executionIdString = arguments["executionId"] as? String,
          let executionId = UUID(uuidString: executionIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing executionId (or set approveAll=true)"))
    }

    guard let execution = run.executions.first(where: { $0.id == executionId }) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Execution not found"))
    }

    runner.approveExecution(execution, in: run)
    return (200, makeRPCResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "status": execution.status.displayName
    ]))
  }

  private func handleParallelReject(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = parallelWorktreeRunner else {
      return (500, makeRPCError(id: id, code: -32001, message: "Parallel worktree runner not initialized"))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
    }

    guard let executionIdString = arguments["executionId"] as? String,
          let executionId = UUID(uuidString: executionIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing executionId"))
    }

    guard let execution = run.executions.first(where: { $0.id == executionId }) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Execution not found"))
    }

    let reason = arguments["reason"] as? String ?? "Rejected via MCP"
    runner.rejectExecution(execution, reason: reason)

    return (200, makeRPCResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "status": execution.status.displayName
    ]))
  }

  private func handleParallelMerge(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = parallelWorktreeRunner else {
      return (500, makeRPCError(id: id, code: -32001, message: "Parallel worktree runner not initialized"))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
    }

    let mergeAll = arguments["mergeAll"] as? Bool ?? false

    do {
      if mergeAll {
        try await runner.mergeAllApproved(in: run)
        return (200, makeRPCResult(id: id, result: [
          "runId": runId.uuidString,
          "merged": "all",
          "mergedCount": run.mergedCount
        ]))
      }

      guard let executionIdString = arguments["executionId"] as? String,
            let executionId = UUID(uuidString: executionIdString) else {
        return (400, makeRPCError(id: id, code: -32602, message: "Missing executionId (or set mergeAll=true)"))
      }

      guard let execution = run.executions.first(where: { $0.id == executionId }) else {
        return (404, makeRPCError(id: id, code: -32004, message: "Execution not found"))
      }

      try await runner.mergeExecution(execution, in: run)
      return (200, makeRPCResult(id: id, result: [
        "runId": runId.uuidString,
        "executionId": executionId.uuidString,
        "status": execution.status.displayName
      ]))
    } catch {
      await mcpLog.warning("Parallel merge failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleParallelCancel(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = parallelWorktreeRunner else {
      return (500, makeRPCError(id: id, code: -32001, message: "Parallel worktree runner not initialized"))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
    }

    await runner.cancelRun(run)

    await mcpLog.info("Parallel run cancelled", metadata: ["runId": runId.uuidString])

    return (200, makeRPCResult(id: id, result: [
      "runId": runId.uuidString,
      "status": "cancelled"
    ]))
  }

  private func encodeParallelRun(_ run: ParallelWorktreeRun, includeDetails: Bool = false) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    var result: [String: Any] = [
      "id": run.id.uuidString,
      "name": run.name,
      "projectPath": run.projectPath,
      "baseBranch": run.baseBranch,
      "status": run.status.displayName,
      "progress": run.progress,
      "executionCount": run.executions.count,
      "pendingReviewCount": run.pendingReviewCount,
      "readyToMergeCount": run.readyToMergeCount,
      "mergedCount": run.mergedCount,
      "failedCount": run.failedCount,
      "requireReviewGate": run.requireReviewGate,
      "autoMergeOnApproval": run.autoMergeOnApproval,
      "createdAt": formatter.string(from: run.createdAt)
    ]

    if let targetBranch = run.targetBranch {
      result["targetBranch"] = targetBranch
    }
    if let startedAt = run.startedAt {
      result["startedAt"] = formatter.string(from: startedAt)
    }
    if let completedAt = run.completedAt {
      result["completedAt"] = formatter.string(from: completedAt)
    }

    if includeDetails {
      result["executions"] = run.executions.map { encodeExecution($0) }
    }

    return result
  }

  private func encodeExecution(_ execution: ParallelWorktreeExecution) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    var result: [String: Any] = [
      "id": execution.id.uuidString,
      "taskTitle": execution.task.title,
      "taskDescription": execution.task.description,
      "status": execution.status.displayName,
      "filesChanged": execution.filesChanged,
      "insertions": execution.insertions,
      "deletions": execution.deletions,
      "ragSnippetCount": execution.ragSnippets.count,
      "mergeConflictCount": execution.mergeConflicts.count
    ]

    if let worktreePath = execution.worktreePath {
      result["worktreePath"] = worktreePath
    }
    if let branchName = execution.branchName {
      result["branchName"] = branchName
    }
    if let startedAt = execution.startedAt {
      result["startedAt"] = formatter.string(from: startedAt)
    }
    if let completedAt = execution.completedAt {
      result["completedAt"] = formatter.string(from: completedAt)
    }
    if let duration = execution.duration {
      result["durationSeconds"] = duration
    }
    if !execution.mergeConflicts.isEmpty {
      result["mergeConflicts"] = execution.mergeConflicts
    }

    return result
  }

  private func handleRagStatus(id: Any?) async -> (Int, Data) {
    let status = await localRagStore.status()
    let formatter = ISO8601DateFormatter()
    var result: [String: Any] = [
      "dbPath": status.dbPath,
      "exists": status.exists,
      "schemaVersion": status.schemaVersion,
      "extensionLoaded": status.extensionLoaded,
      "embeddingProvider": status.providerName
    ]
    if let lastInitializedAt = status.lastInitializedAt {
      result["lastInitializedAt"] = formatter.string(from: lastInitializedAt)
    }
    return (200, makeRPCResult(id: id, result: result))
  }

  private func handleRagInit(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let extensionPath = arguments["extensionPath"] as? String
    do {
      let status = try await localRagStore.initialize(extensionPath: extensionPath)
      let formatter = ISO8601DateFormatter()
      var result: [String: Any] = [
        "dbPath": status.dbPath,
        "exists": status.exists,
        "schemaVersion": status.schemaVersion,
        "extensionLoaded": status.extensionLoaded
      ]
      if let lastInitializedAt = status.lastInitializedAt {
        result["lastInitializedAt"] = formatter.string(from: lastInitializedAt)
      }
      return (200, makeRPCResult(id: id, result: result))
    } catch {
      await mcpLog.warning("Local RAG init failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleRagIndex(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let repoPath = (arguments["repoPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let repoPath, !repoPath.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing repoPath"))
    }

    do {
      let report = try await localRagStore.indexRepository(path: repoPath)
      let result: [String: Any] = [
        "repoId": report.repoId,
        "repoPath": report.repoPath,
        "filesIndexed": report.filesIndexed,
        "chunksIndexed": report.chunksIndexed,
        "bytesScanned": report.bytesScanned,
        "durationMs": report.durationMs
      ]
      return (200, makeRPCResult(id: id, result: result))
    } catch {
      await mcpLog.warning("Local RAG index failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleRagSearch(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let query, !query.isEmpty else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing query"))
    }
    let repoPath = (arguments["repoPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let limit = arguments["limit"] as? Int ?? 10
    let mode = (arguments["mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "text"

    do {
      let resolvedMode: RAGSearchMode = mode.lowercased() == "vector" ? .vector : .text
      let results = try await searchRag(query: query, mode: resolvedMode, repoPath: repoPath, limit: limit)
      let payload = results.map { result in
        [
          "filePath": result.filePath,
          "startLine": result.startLine,
          "endLine": result.endLine,
          "snippet": result.snippet
        ]
      }
      return (200, makeRPCResult(id: id, result: ["mode": mode, "results": payload]))
    } catch {
      await mcpLog.warning("Local RAG search failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleRagModelDescribe(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let modelName = (arguments["modelName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelExtension = (arguments["extension"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName = modelName?.isEmpty == false ? modelName! : "bge-small-en-v1.5"
    let resolvedExtension = modelExtension?.isEmpty == false ? modelExtension! : "mlpackage"

    guard let url = Bundle.main.url(forResource: resolvedName, withExtension: resolvedExtension) else {
      return (404, makeRPCError(id: id, code: -32021, message: "Model not found in bundle"))
    }

    do {
      let info = try LocalRAGModelDescriptor.describe(modelURL: url)
      return (200, makeRPCResult(id: id, result: ["model": info, "url": url.path]))
    } catch {
      await mcpLog.warning("Local RAG model describe failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleRagUIStatus(id: Any?) async -> (Int, Data) {
    let formatter = ISO8601DateFormatter()
    let status = await localRagStore.status()
    let stats = try? await localRagStore.stats()

    var payload: [String: Any] = [
      "status": [
        "dbPath": status.dbPath,
        "exists": status.exists,
        "schemaVersion": status.schemaVersion,
        "extensionLoaded": status.extensionLoaded,
        "embeddingProvider": status.providerName,
        "lastInitializedAt": status.lastInitializedAt.map { formatter.string(from: $0) } as Any
      ]
    ]

    if let stats {
      payload["stats"] = [
        "repoCount": stats.repoCount,
        "fileCount": stats.fileCount,
        "chunkCount": stats.chunkCount,
        "embeddingCount": stats.embeddingCount,
        "cacheEmbeddingCount": stats.cacheEmbeddingCount,
        "dbSizeBytes": stats.dbSizeBytes,
        "lastIndexedAt": stats.lastIndexedAt.map { formatter.string(from: $0) } as Any,
        "lastIndexedRepoPath": stats.lastIndexedRepoPath as Any
      ]
    }

    let searchPayload = lastRagSearchResults.prefix(10).map { result in
      [
        "filePath": result.filePath,
        "startLine": result.startLine,
        "endLine": result.endLine,
        "snippet": result.snippet
      ]
    }

    payload["lastSearch"] = [
      "query": lastRagSearchQuery as Any,
      "mode": lastRagSearchMode?.rawValue as Any,
      "repoPath": lastRagSearchRepoPath as Any,
      "limit": lastRagSearchLimit as Any,
      "at": lastRagSearchAt.map { formatter.string(from: $0) } as Any,
      "results": searchPayload
    ]

    payload["ui"] = [
      "currentViewId": currentToolId() as Any,
      "selectedInfrastructure": UserDefaults.standard.string(forKey: "agents.selectedInfrastructure") as Any,
      "lastUIActionHandled": lastUIActionHandled as Any,
      "pendingUIAction": lastUIAction?.controlId as Any
    ]

    if let error = lastRagError {
      payload["error"] = error
    }
    if let refreshedAt = lastRagRefreshAt {
      payload["refreshedAt"] = formatter.string(from: refreshedAt)
    }

    return (200, makeRPCResult(id: id, result: payload))
  }

  private func encodeJSON<T: Encodable>(_ value: T) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object
  }

  private func handleChainRunStatus(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    let formatter = ISO8601DateFormatter()

    if let runInfo = activeRunsById[runId] {
      let chain = activeRunChains[runId]
      let result: [String: Any] = [
        "runId": runIdString,
        "status": "running",
        "state": chain?.state.displayName as Any,
        "agentCount": chain?.agents.count as Any,
        "resultsCount": chain?.results.count as Any,
        "templateName": runInfo.templateName,
        "prompt": runInfo.prompt,
        "workingDirectory": runInfo.workingDirectory as Any,
        "startedAt": formatter.string(from: runInfo.startedAt),
        "priority": runInfo.priority,
        "timeoutSeconds": runInfo.timeoutSeconds as Any
      ]
      return (200, makeRPCResult(id: id, result: result))
    }

    if let queuedIndex = chainQueue.firstIndex(where: { $0.id == runId }) {
      let entry = chainQueue[queuedIndex]
      let result: [String: Any] = [
        "runId": runIdString,
        "status": "queued",
        "position": queuedIndex + 1,
        "enqueuedAt": formatter.string(from: entry.enqueuedAt),
        "priority": entry.priority
      ]
      return (200, makeRPCResult(id: id, result: result))
    }

    if let completed = completedRunsById[runId] {
      let result: [String: Any] = [
        "runId": runIdString,
        "status": "completed",
        "completedAt": formatter.string(from: completed.completedAt),
        "result": completed.payload
      ]
      return (200, makeRPCResult(id: id, result: result))
    }

    return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
  }

  private func handleChainRunList(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let dataService else {
      return (500, makeRPCError(id: id, code: -32001, message: "Run history unavailable"))
    }

    let limit = arguments["limit"] as? Int ?? 20
    let chainId = arguments["chainId"] as? String
    let runIdString = arguments["runId"] as? String
    let includeResults = arguments["includeResults"] as? Bool ?? false
    let includeOutputs = arguments["includeOutputs"] as? Bool ?? false

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    func splitLines(_ value: String) -> [String] {
      value
        .split(whereSeparator: { $0.isNewline })
        .map { String($0) }
        .filter { !$0.isEmpty }
    }

    var runs: [MCPRunRecord] = []

    if let runIdString, let runId = UUID(uuidString: runIdString) {
      let recent = dataService.getRecentMCPRuns(limit: max(200, limit))
      if let found = recent.first(where: { $0.id == runId }) {
        runs = [found]
      } else {
        return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
      }
    } else if let chainId, !chainId.isEmpty {
      if let record = dataService.getMCPRun(forChainId: chainId) {
        runs = [record]
      }
    } else {
      runs = dataService.getRecentMCPRuns(limit: min(max(limit, 1), 200))
    }

    let payload: [[String: Any]] = runs.map { run in
      var runPayload: [String: Any] = [
        "runId": run.id.uuidString,
        "chainId": run.chainId,
        "templateId": run.templateId,
        "templateName": run.templateName,
        "prompt": run.prompt,
        "workingDirectory": run.workingDirectory as Any,
        "implementerBranches": splitLines(run.implementerBranches),
        "implementerWorkspacePaths": splitLines(run.implementerWorkspacePaths),
        "screenshotPaths": splitLines(run.screenshotPaths),
        "success": run.success,
        "errorMessage": run.errorMessage as Any,
        "noWorkReason": run.noWorkReason as Any,
        "mergeConflictsCount": run.mergeConflictsCount,
        "resultCount": run.resultCount,
        "validationStatus": run.validationStatus as Any,
        "validationReasons": splitLines(run.validationReasons ?? ""),
        "createdAt": formatter.string(from: run.createdAt)
      ]

      if includeResults, !run.chainId.isEmpty {
        let results = dataService.getMCPRunResults(chainId: run.chainId)
        runPayload["results"] = results.map { result in
          var resultPayload: [String: Any] = [
            "agentId": result.agentId,
            "agentName": result.agentName,
            "model": result.model,
            "prompt": result.prompt,
            "premiumCost": result.premiumCost,
            "reviewVerdict": result.reviewVerdict as Any,
            "createdAt": formatter.string(from: result.createdAt)
          ]
          if includeOutputs {
            resultPayload["output"] = result.output
          }
          return resultPayload
        }
      }

      return runPayload
    }

    return (200, makeRPCResult(id: id, result: ["runs": payload]))
  }

  private func handleAgentWorkspacesList(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let repoPath = arguments["repoPath"] as? String
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let workspaces = agentManager.workspaceManager.workspaces
      .filter { workspace in
        guard let repoPath else { return true }
        return workspace.parentRepositoryPath.path == repoPath
      }
      .map { workspace in
        [
          "id": workspace.id.uuidString,
          "name": workspace.name,
          "path": workspace.path.path,
          "parentRepositoryPath": workspace.parentRepositoryPath.path,
          "branch": workspace.branch,
          "headCommit": workspace.headCommit as Any,
          "status": workspace.status.rawValue,
          "assignedAgentId": workspace.assignedAgentId?.uuidString as Any,
          "createdAt": formatter.string(from: workspace.createdAt),
          "lastAccessedAt": formatter.string(from: workspace.lastAccessedAt),
          "isLocked": workspace.isLocked,
          "lockReason": workspace.lockReason as Any,
          "errorMessage": workspace.errorMessage as Any,
          "activeFiles": workspace.activeFiles
        ]
      }

    return (200, makeRPCResult(id: id, result: ["workspaces": workspaces]))
  }

  private func handleAgentWorkspacesCleanupStatus(id: Any?) -> (Int, Data) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let result: [String: Any] = [
      "isCleaning": isCleaningAgentWorkspaces,
      "lastCleanupAt": lastCleanupAt.map { formatter.string(from: $0) } as Any,
      "lastCleanupSummary": lastCleanupSummary as Any,
      "lastCleanupError": lastCleanupError as Any
    ]

    return (200, makeRPCResult(id: id, result: result))
  }

  private func handleChainRun(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let prompt = arguments["prompt"] as? String else {
      await mcpLog.warning("chains.run missing prompt")
      return (400, makeRPCError(id: id, code: -32602, message: "Missing prompt"))
    }

    let runId = UUID()
    if activeChainRuns >= maxConcurrentChains, chainQueue.count >= maxQueuedChains {
      await mcpLog.warning("Chain queue full", metadata: ["runId": runId.uuidString])
      return (429, makeRPCError(id: id, code: -32000, message: "Chain queue is full"))
    }

    let templateId = arguments["templateId"] as? String
    let templateName = arguments["templateName"] as? String
    let chainSpec = arguments["chainSpec"] as? [String: Any]
    let workingDirectory = arguments["workingDirectory"] as? String
    let enableReviewLoop = arguments["enableReviewLoop"] as? Bool
    let pauseOnReview = arguments["pauseOnReview"] as? Bool
    let allowPlannerModelSelection = arguments["allowPlannerModelSelection"] as? Bool ?? false
    let allowPlannerImplementerScaling = arguments["allowPlannerImplementerScaling"] as? Bool ?? false
    let maxImplementers = arguments["maxImplementers"] as? Int
    let maxPremiumCost = arguments["maxPremiumCost"] as? Double
    let priority = arguments["priority"] as? Int ?? 0
    let timeoutSeconds = arguments["timeoutSeconds"] as? Double
    let returnImmediately = arguments["returnImmediately"] as? Bool ?? false
    let keepWorkspace = arguments["keepWorkspace"] as? Bool ?? false

    let (enqueuedAt, wasCancelled, queuePosition) = await acquireChainRunSlot(runId: runId, priority: priority)
    if wasCancelled {
      await mcpLog.warning("Queued chain cancelled", metadata: ["runId": runId.uuidString])
      return (400, makeRPCError(id: id, code: -32005, message: "Queued run cancelled"))
    }
    defer { releaseChainRunSlot(runId: runId) }

    let templates = agentManager.allTemplates
    let template: ChainTemplate? = {
      if let chainSpec {
        return parseChainSpec(chainSpec)
      }
      if let templateId, let uuid = UUID(uuidString: templateId) {
        return templates.first { $0.id == uuid }
      }
      if let templateName {
        return templates.first { $0.name.lowercased() == templateName.lowercased() }
      }
      return templates.first
    }()

    guard let template else {
      await mcpLog.warning("Template not found", metadata: ["runId": runId.uuidString])
      let message = chainSpec == nil ? "Template not found" : "Invalid chainSpec"
      return (400, makeRPCError(id: id, code: -32602, message: message))
    }

    var chainWorkspace: AgentWorkspace?
    var chainWorkingDirectory = workingDirectory ?? agentManager.lastUsedWorkingDirectory
    if chainWorkingDirectory == nil {
      await mcpLog.warning("chains.run missing workingDirectory", metadata: ["runId": runId.uuidString])
      return (400, makeRPCError(id: id, code: -32602, message: "Missing workingDirectory"))
    }
    if let workingDirectory = chainWorkingDirectory {
      let repoURL = URL(fileURLWithPath: workingDirectory)
      let repository = Model.Repository(name: repoURL.lastPathComponent, path: workingDirectory)
      let task = AgentTask(
        title: "MCP Chain: \(template.name)",
        prompt: prompt,
        repositoryPath: workingDirectory
      )

      do {
        let workspace = try await agentManager.workspaceManager.createWorkspace(
          for: repository,
          task: task
        )
        chainWorkspace = workspace
        chainWorkingDirectory = workspace.path.path
      } catch {
        await mcpLog.error(error, context: "Failed to create chain workspace")
      }
    }

    let chain = agentManager.createChainFromTemplate(template, workingDirectory: chainWorkingDirectory)
    chain.runSource = .mcp
    if let enableReviewLoop {
      chain.enableReviewLoop = enableReviewLoop
    }
    if let pauseOnReview {
      chain.pauseOnReview = pauseOnReview
    }

    let runOptions = AgentChainRunner.ChainRunOptions(
      allowPlannerModelSelection: allowPlannerModelSelection,
      allowPlannerImplementerScaling: allowPlannerImplementerScaling,
      maxImplementers: maxImplementers,
      maxPremiumCost: maxPremiumCost
    )

    await mcpLog.info("Chain run started", metadata: [
      "runId": runId.uuidString,
      "template": template.name,
      "workingDirectory": chainWorkingDirectory ?? "",
      "queued": enqueuedAt == nil ? "false" : "true"
    ])

    activeRunChains[runId] = chain
    activeRunsById[runId] = ActiveRunInfo(
      id: runId,
      chainId: chain.id,
      templateName: template.name,
      prompt: prompt,
      workingDirectory: chainWorkingDirectory,
      enqueuedAt: enqueuedAt,
      startedAt: Date(),
      priority: priority,
      timeoutSeconds: timeoutSeconds
    )

    let runTask = Task { @MainActor in
      await chainRunner.runChain(
        chain,
        prompt: prompt,
        validationConfig: template.validationConfig,
        runOptions: runOptions
      )
    }
    activeChainTasks[runId] = runTask
    activeChainRunIds.insert(runId)
    if let timeoutSeconds, timeoutSeconds > 0 {
      activeChainTimeouts[runId] = Task { [weak self] in
        try? await Task.sleep(for: .seconds(timeoutSeconds))
        guard let self, !(self.activeChainTasks[runId]?.isCancelled ?? true) else { return }
        self.activeChainTasks[runId]?.cancel()
        await self.mcpLog.warning("Chain timeout exceeded", metadata: [
          "runId": runId.uuidString,
          "timeoutSeconds": "\(timeoutSeconds)"
        ])
      }
    }
    let cleanupRun: () -> Void = {
      self.activeChainTasks[runId] = nil
      self.activeChainRunIds.remove(runId)
      self.activeChainTimeouts[runId]?.cancel()
      self.activeChainTimeouts[runId] = nil
      self.activeRunsById[runId] = nil
      self.activeRunChains[runId] = nil
    }
    let finalizeRun: (AgentChainRunner.RunSummary) async -> Void = { summary in
      if !keepWorkspace {
        if let chainWorkspace {
          try? await self.agentManager.workspaceManager.cleanupWorkspace(chainWorkspace, force: true)
        }
        if self.autoCleanupWorkspaces {
          await self.cleanupAgentWorkspaces()
        }
      }
      if let errorMessage = summary.errorMessage {
        await self.mcpLog.error("Chain run failed", metadata: [
          "runId": runId.uuidString,
          "template": template.name,
          "error": errorMessage
        ])
      } else {
        await self.mcpLog.info("Chain run completed", metadata: [
          "runId": runId.uuidString,
          "template": template.name,
          "results": "\(summary.results.count)",
          "mergeConflicts": "\(summary.mergeConflicts.count)"
        ])
      }

      if let ds = self.dataService {
        let workspacePaths = [chainWorkingDirectory].compactMap { $0 }
        let workspaceBranches = [chainWorkspace?.branch].compactMap { $0 }
        let _ = ds.recordMCPRun(
          chainId: chain.id.uuidString,
          templateId: template.id.uuidString,
          templateName: template.name,
          prompt: prompt,
          workingDirectory: workingDirectory,
          implementerBranches: workspaceBranches,
          implementerWorkspacePaths: workspacePaths,
          screenshotPaths: summary.results.compactMap { $0.screenshotPath },
          success: summary.errorMessage == nil,
          errorMessage: summary.errorMessage,
          mergeConflictsCount: summary.mergeConflicts.count,
          mergeConflicts: summary.mergeConflicts,
          resultCount: summary.results.count,
          validationStatus: summary.validationResult?.status.rawValue,
          validationReasons: summary.validationResult?.reasons ?? [],
          noWorkReason: summary.noWorkReason
        )

        for res in summary.results {
          ds.recordMCPRunResult(
            chainId: chain.id.uuidString,
            agentId: res.agentId.uuidString,
            agentName: res.agentName,
            model: res.model,
            prompt: res.prompt,
            output: res.output,
            premiumCost: res.premiumCost,
            reviewVerdict: res.reviewVerdict?.rawValue
          )
        }
      }

      var completedPayload: [String: Any] = [
        "runId": runId.uuidString,
        "chain": [
          "id": chain.id.uuidString,
          "name": chain.name,
          "state": summary.stateDescription,
          "gated": summary.noWorkReason != nil,
          "noWorkReason": summary.noWorkReason as Any
        ],
        "success": summary.errorMessage == nil,
        "errorMessage": summary.errorMessage as Any,
        "mergeConflicts": summary.mergeConflicts,
        "results": self.summarizeResults(summary.results)
      ]

      if let validationResult = summary.validationResult {
        completedPayload["validation"] = validationResult.toDictionary()
      }

      self.completedRunsById[runId] = (Date(), completedPayload)
      if self.completedRunsById.count > 50 {
        let sorted = self.completedRunsById.sorted { $0.value.completedAt < $1.value.completedAt }
        for (id, _) in sorted.prefix(self.completedRunsById.count - 50) {
          self.completedRunsById.removeValue(forKey: id)
        }
      }

      cleanupRun()
    }

    if returnImmediately {
      Task { @MainActor in
        let summary = await runTask.value
        await finalizeRun(summary)
      }
      let result: [String: Any] = [
        "queue": [
          "runId": runId.uuidString,
          "queued": enqueuedAt != nil,
          "position": queuePosition as Any,
          "waitSeconds": enqueuedAt.map { Date().timeIntervalSince($0) } as Any,
          "maxConcurrent": maxConcurrentChains,
          "maxQueued": maxQueuedChains
        ],
        "chain": [
          "id": chain.id.uuidString,
          "name": chain.name,
          "state": "queued",
          "gated": false,
          "noWorkReason": NSNull()
        ],
        "async": true
      ]
      return (200, makeRPCResult(id: id, result: result))
    }

    let summary = await runTask.value
    await finalizeRun(summary)

    let queueWaitSeconds: Double? = {
      guard let enqueuedAt else { return nil }
      return Date().timeIntervalSince(enqueuedAt)
    }()

    var result: [String: Any] = [
      "queue": [
        "runId": runId.uuidString,
        "queued": enqueuedAt != nil,
        "position": queuePosition as Any,
        "waitSeconds": queueWaitSeconds as Any,
        "maxConcurrent": maxConcurrentChains,
        "maxQueued": maxQueuedChains
      ],
      "chain": [
        "id": chain.id.uuidString,
        "name": chain.name,
        "state": summary.stateDescription,
        "gated": summary.noWorkReason != nil,
        "noWorkReason": summary.noWorkReason as Any
      ],
      "success": summary.errorMessage == nil,
      "errorMessage": summary.errorMessage as Any,
      "mergeConflicts": summary.mergeConflicts,
      "results": summarizeResults(summary.results)
    ]

    if let validationResult = summary.validationResult {
      result["validation"] = validationResult.toDictionary()
    }

    return (200, makeRPCResult(id: id, result: result))
  }

  private func handleChainRunBatch(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runs = arguments["runs"] as? [[String: Any]], !runs.isEmpty else {
      await mcpLog.warning("chains.runBatch missing runs")
      return (400, makeRPCError(id: id, code: -32602, message: "Missing runs"))
    }

    let parallel = arguments["parallel"] as? Bool ?? true
    var results = Array(repeating: [String: Any](), count: runs.count)

    var serializedRuns: [(index: Int, data: Data)] = []
    for (index, runArguments) in runs.enumerated() {
      if let data = try? JSONSerialization.data(withJSONObject: runArguments, options: []) {
        serializedRuns.append((index, data))
      } else {
        results[index] = [
          "index": index,
          "status": 400,
          "error": ["code": -32602, "message": "Run arguments are not valid JSON"]
        ]
      }
    }

    let decodePayload: (Int, Int, Data) -> [String: Any] = { index, status, data in
      var payload: [String: Any] = [
        "index": index,
        "status": status
      ]
      if let object = try? JSONSerialization.jsonObject(with: data, options: []),
         let dict = object as? [String: Any] {
        if let result = dict["result"] {
          payload["result"] = result
        }
        if let error = dict["error"] {
          payload["error"] = error
        }
      } else {
        payload["error"] = ["code": -32603, "message": "Invalid response JSON"]
      }
      return payload
    }

    if parallel {
      await withTaskGroup(of: (Int, Int, Data).self) { group in
        for item in serializedRuns {
          group.addTask {
            guard let object = try? JSONSerialization.jsonObject(with: item.data, options: []),
                  let runArguments = object as? [String: Any] else {
              let errorPayload = [
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32602, "message": "Run arguments are not valid JSON"]
              ]
              let data = (try? JSONSerialization.data(withJSONObject: errorPayload, options: [])) ?? Data()
              return (item.index, 400, data)
            }
            let (status, data) = await self.handleChainRun(id: nil, arguments: runArguments)
            return (item.index, status, data)
          }
        }

        for await (index, status, data) in group {
          results[index] = decodePayload(index, status, data)
        }
      }
    } else {
      for item in serializedRuns {
        guard let object = try? JSONSerialization.jsonObject(with: item.data, options: []),
              let runArguments = object as? [String: Any] else {
          results[item.index] = [
            "index": item.index,
            "status": 400,
            "error": ["code": -32602, "message": "Run arguments are not valid JSON"]
          ]
          continue
        }
        let (status, data) = await handleChainRun(id: nil, arguments: runArguments)
        results[item.index] = decodePayload(item.index, status, data)
      }
    }

    let response: [String: Any] = [
      "parallel": parallel,
      "count": runs.count,
      "runs": results
    ]
    return (200, makeRPCResult(id: id, result: response))
  }

  private func handleChainStop(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let runIdString = arguments["runId"] as? String
    let cancelAll = arguments["all"] as? Bool ?? false

    if cancelAll {
      let runIds = Array(activeChainTasks.keys)
      runIds.forEach { activeChainTasks[$0]?.cancel() }
      await mcpLog.warning("Chain cancellation requested", metadata: ["runIds": runIds.map { $0.uuidString }.joined(separator: ",")])
      return (200, makeRPCResult(id: id, result: ["cancelled": runIds.map { $0.uuidString }]))
    }

    guard let runIdString, let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let task = activeChainTasks[runId] else {
      return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
    }

    task.cancel()
    await mcpLog.warning("Chain cancellation requested", metadata: ["runId": runId.uuidString])
    return (200, makeRPCResult(id: id, result: ["cancelled": [runId.uuidString]]))
  }

  private func handleChainPause(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    await chainRunner.pause(chainId: chain.id)
    await mcpLog.info("Chain paused", metadata: ["runId": runId.uuidString])
    return (200, makeRPCResult(id: id, result: ["paused": runId.uuidString]))
  }

  private func handleChainResume(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    await chainRunner.resume(chainId: chain.id)
    await mcpLog.info("Chain resumed", metadata: ["runId": runId.uuidString])
    return (200, makeRPCResult(id: id, result: ["resumed": runId.uuidString]))
  }

  private func handleChainStep(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    await chainRunner.step(chainId: chain.id)
    await mcpLog.info("Chain step", metadata: ["runId": runId.uuidString])
    return (200, makeRPCResult(id: id, result: ["step": runId.uuidString]))
  }

  private func handleServerRestart(id: Any?) async -> (Int, Data) {
    stop()
    start()
    await waitForServerStart()

    if isRunning {
      return (200, makeRPCResult(id: id, result: ["running": true, "port": port]))
    }

    return (500, makeRPCError(id: id, code: -32001, message: lastError ?? "Failed to restart server"))
  }

  private func handleServerPortSet(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let requestedPort = arguments["port"] as? Int else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing port"))
    }

    let autoFind = arguments["autoFind"] as? Bool ?? false
    let maxAttempts = arguments["maxAttempts"] as? Int ?? 25

    let targetPort: Int
    if autoFind, !canBind(port: requestedPort) {
      guard let available = findAvailablePort(startingAt: requestedPort, maxAttempts: maxAttempts) else {
        return (500, makeRPCError(id: id, code: -32002, message: "No available port found"))
      }
      targetPort = available
    } else {
      targetPort = requestedPort
    }

    port = targetPort
    stop()
    start()
    await waitForServerStart()

    if isRunning {
      return (200, makeRPCResult(id: id, result: ["running": true, "port": port]))
    }

    return (500, makeRPCError(id: id, code: -32003, message: lastError ?? "Failed to bind to port"))
  }

  private func handleServerStatus(id: Any?) -> (Int, Data) {
    let status: [String: Any] = [
      "enabled": isEnabled,
      "running": isRunning,
      "port": port,
      "lastError": lastError as Any
    ]
    return (200, makeRPCResult(id: id, result: status))
  }

  private func waitForServerStart(timeoutSeconds: Double = 2.0) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      if isRunning || lastError != nil {
        break
      }
      try? await Task.sleep(for: .milliseconds(75))
    }
  }

  private func canBind(port: Int) -> Bool {
    guard port >= 1024 && port <= 65535 else { return false }
    guard let portValue = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
    do {
      let listener = try NWListener(using: .tcp, on: portValue)
      listener.cancel()
      return true
    } catch {
      return false
    }
  }

  private func findAvailablePort(startingAt port: Int, maxAttempts: Int) -> Int? {
    guard port > 0 else { return nil }
    for offset in 0..<maxAttempts {
      let candidate = port + offset
      if candidate > 65535 { break }
      if canBind(port: candidate) {
        return candidate
      }
    }
    return nil
  }

  private func acquireChainRunSlot(runId: UUID, priority: Int) async -> (Date?, Bool, Int?) {
    if activeChainRuns < maxConcurrentChains {
      activeChainRuns += 1
      activeChainRunIds.insert(runId)
      return (nil, false, nil)
    }

    let enqueuedAt = Date()
    var position: Int?
    let shouldRun = await withCheckedContinuation { continuation in
      chainQueue.append(ChainQueueEntry(id: runId, enqueuedAt: enqueuedAt, priority: priority, continuation: continuation))
      chainQueue.sort {
        if $0.priority != $1.priority {
          return $0.priority > $1.priority
        }
        return $0.enqueuedAt < $1.enqueuedAt
      }
      if let index = chainQueue.firstIndex(where: { $0.id == runId }) {
        position = index + 1
      }
    }
    guard shouldRun else {
      return (enqueuedAt, true, position)
    }
    activeChainRuns += 1
    activeChainRunIds.insert(runId)
    return (enqueuedAt, false, position)
  }

  private func releaseChainRunSlot(runId: UUID) {
    activeChainRuns = max(activeChainRuns - 1, 0)
    activeChainRunIds.remove(runId)
    if !chainQueue.isEmpty {
      let next = chainQueue.removeFirst()
      next.continuation.resume(returning: true)
    }
  }

  private func queueStatus() -> [String: Any] {
    return [
      "activeCount": activeChainRuns,
      "activeRunIds": activeChainRunIds.map { $0.uuidString },
      "queuedCount": chainQueue.count,
      "queued": chainQueue.map {
        [
          "runId": $0.id.uuidString,
          "enqueuedAt": ISO8601DateFormatter().string(from: $0.enqueuedAt),
          "priority": $0.priority
        ]
      },
      "maxConcurrent": maxConcurrentChains,
      "maxQueued": maxQueuedChains
    ]
  }

  private func cancelQueuedRunInternal(runId: UUID) -> Bool {
    guard let index = chainQueue.firstIndex(where: { $0.id == runId }) else {
      return false
    }
    let entry = chainQueue.remove(at: index)
    entry.continuation.resume(returning: false)
    return true
  }

  private func handleQueueConfigure(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    if let maxConcurrent = arguments["maxConcurrent"] as? Int {
      maxConcurrentChains = max(1, maxConcurrent)
    }
    if let maxQueued = arguments["maxQueued"] as? Int {
      maxQueuedChains = max(0, maxQueued)
    }
    return (200, makeRPCResult(id: id, result: queueStatus()))
  }

  private func handleQueueCancel(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    if cancelQueuedRunInternal(runId: runId) {
      await mcpLog.warning("Queued chain cancelled", metadata: ["runId": runId.uuidString])
      return (200, makeRPCResult(id: id, result: ["cancelled": runId.uuidString]))
    }

    return (404, makeRPCError(id: id, code: -32004, message: "Queued run not found"))
  }

  public func cleanupAgentWorkspaces() async {
    guard !isCleaningAgentWorkspaces else { return }
    isCleaningAgentWorkspaces = true
    lastCleanupError = nil
    lastCleanupSummary = nil
    lastCleanupAt = Date()

    defer {
      isCleaningAgentWorkspaces = false
    }

    var repoPaths = Set<String>()
    for workspace in agentManager.workspaceManager.workspaces {
      repoPaths.insert(workspace.parentRepositoryPath.path)
    }

    if let dataService {
      for run in dataService.getRecentMCPRuns(limit: 100) {
        if let path = run.workingDirectory, !path.isEmpty {
          repoPaths.insert(path)
        }
      }
    }

    guard !repoPaths.isEmpty else {
      lastCleanupSummary = "No repositories found for cleanup."
      return
    }

    var removedWorktrees = 0
    var deletedBranches = 0
    var errors: [String] = []

    for path in repoPaths {
      let repoURL = URL(fileURLWithPath: path)
      let repository = Model.Repository(name: repoURL.lastPathComponent, path: path)

      try? await agentManager.workspaceManager.refreshWorkspaces(for: repository)

      let workspaces = agentManager.workspaceManager.workspaces(for: repoURL)
      let agentWorkspaces = workspaces.filter { workspace in
        workspace.path.path.contains("/\(AgentWorkspaceService.workspacesDirName)/")
      }

      for workspace in agentWorkspaces {
        let branch = workspace.branch
        do {
          try await agentManager.workspaceManager.cleanupWorkspace(workspace, force: true)
          removedWorktrees += 1
          if !branch.isEmpty {
            if (try? await Commands.simple(arguments: ["branch", "-D", branch], in: repository)) != nil {
              deletedBranches += 1
            }
          }
        } catch {
          errors.append("\(workspace.path.path): \(error.localizedDescription)")
        }
      }
    }

    if !errors.isEmpty {
      // Surface the first error but keep the full list available in the summary count
      lastCleanupError = errors.first
    }

    let errorNote = errors.isEmpty ? "" : " (\(errors.count) errors)"
    lastCleanupSummary = "Removed \(removedWorktrees) worktrees, deleted \(deletedBranches) branches\(errorNote)."
  }

  private func loadToolPermissions() {
    guard let data = UserDefaults.standard.data(forKey: StorageKey.toolPermissions),
          let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
      toolPermissions = [:]
      return
    }
    toolPermissions = decoded
  }

  private func persistToolPermissions() {
    guard let data = try? JSONEncoder().encode(toolPermissions) else { return }
    UserDefaults.standard.set(data, forKey: StorageKey.toolPermissions)
  }

  private func defaultToolEnabled(_ tool: ToolDefinition) -> Bool {
    true
  }

  private func toolDefinition(named name: String) -> ToolDefinition? {
    toolDefinitions.first { $0.name == name }
  }

  private var toolDefinitions: [ToolDefinition] {
    [
      ToolDefinition(
        name: "ui.tap",
        description: "Tap a control by controlId",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"]
          ],
          "required": ["controlId"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.setText",
        description: "Set text for a control",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"],
            "value": ["type": "string"]
          ],
          "required": ["controlId", "value"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.toggle",
        description: "Toggle a control",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"],
            "on": ["type": "boolean"]
          ],
          "required": ["controlId"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.select",
        description: "Select a value for a control",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"],
            "value": ["type": "string"]
          ],
          "required": ["controlId", "value"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.navigate",
        description: "Navigate to a top-level view by viewId",
        inputSchema: [
          "type": "object",
          "properties": [
            "viewId": ["type": "string"]
          ],
          "required": ["viewId"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.back",
        description: "Navigate back to the previous view (if supported)",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.snapshot",
        description: "Return the current view and visible control IDs",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .ui,
        isMutating: false,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "state.get",
        description: "Get current app state summary",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "state.readonly",
        description: "Background-safe, read-only state snapshot",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "state.list",
        description: "List available view IDs and tools",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "rag.status",
        description: "Get Local RAG database status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      ToolDefinition(
        name: "rag.init",
        description: "Initialize the Local RAG database schema",
        inputSchema: [
          "type": "object",
          "properties": [
            "extensionPath": ["type": "string"]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      ToolDefinition(
        name: "rag.index",
        description: "Index a repository path into the Local RAG database",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: true
      ),
      ToolDefinition(
        name: "rag.search",
        description: "Search indexed content (text match stub)",
        inputSchema: [
          "type": "object",
          "properties": [
            "query": ["type": "string"],
            "repoPath": ["type": "string"],
            "limit": ["type": "integer"],
            "mode": ["type": "string"]
          ],
          "required": ["query"]
        ],
        category: .rag,
        isMutating: false
      ),
      ToolDefinition(
        name: "rag.model.describe",
        description: "Describe the Core ML embedding model",
        inputSchema: [
          "type": "object",
          "properties": [
            "modelName": ["type": "string"],
            "extension": ["type": "string"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      ToolDefinition(
        name: "rag.ui.status",
        description: "Get Local RAG dashboard status snapshot",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      ToolDefinition(
        name: "templates.list",
        description: "List available chain templates",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .chains,
        isMutating: false
      ),
      ToolDefinition(
        name: "chains.run",
        description: "Run a chain template with a prompt",
        inputSchema: [
          "type": "object",
          "properties": [
            "templateId": ["type": "string"],
            "templateName": ["type": "string"],
            "chainSpec": [
              "type": "object",
              "properties": [
                "name": ["type": "string"],
                "description": ["type": "string"],
                "steps": [
                  "type": "array",
                  "items": [
                    "type": "object",
                    "properties": [
                      "role": ["type": "string"],
                      "model": ["type": "string"],
                      "name": ["type": "string"],
                      "frameworkHint": ["type": "string"],
                      "customInstructions": ["type": "string"]
                    ],
                    "required": ["role", "model"]
                  ]
                ]
              ],
              "required": ["steps"]
            ],
            "prompt": ["type": "string"],
            "workingDirectory": ["type": "string"],
            "enableReviewLoop": ["type": "boolean"],
            "pauseOnReview": ["type": "boolean"],
            "allowPlannerModelSelection": ["type": "boolean"],
            "allowPlannerImplementerScaling": ["type": "boolean"],
            "maxImplementers": ["type": "integer"],
            "maxPremiumCost": ["type": "number"],
            "priority": ["type": "integer"],
            "timeoutSeconds": ["type": "number"],
            "returnImmediately": ["type": "boolean"],
            "keepWorkspace": ["type": "boolean"]
          ],
          "required": ["prompt"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.run.status",
        description: "Get status for a running or queued chain by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: false
      ),
      ToolDefinition(
        name: "chains.run.list",
        description: "List recent chain runs and optional logs",
        inputSchema: [
          "type": "object",
          "properties": [
            "limit": ["type": "integer"],
            "chainId": ["type": "string"],
            "runId": ["type": "string"],
            "includeResults": ["type": "boolean"],
            "includeOutputs": ["type": "boolean"]
          ]
        ],
        category: .chains,
        isMutating: false
      ),
      ToolDefinition(
        name: "workspaces.agent.list",
        description: "List agent workspaces and their status",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"]
          ]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "workspaces.agent.cleanup.status",
        description: "Get agent worktree cleanup status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "chains.runBatch",
        description: "Run multiple chains (optionally in parallel)",
        inputSchema: [
          "type": "object",
          "properties": [
            "runs": [
              "type": "array",
              "items": [
                "type": "object",
                "properties": [
                  "templateId": ["type": "string"],
                  "templateName": ["type": "string"],
                  "prompt": ["type": "string"],
                  "workingDirectory": ["type": "string"],
                  "enableReviewLoop": ["type": "boolean"],
                  "pauseOnReview": ["type": "boolean"],
                  "allowPlannerModelSelection": ["type": "boolean"],
                  "allowPlannerImplementerScaling": ["type": "boolean"],
                  "maxImplementers": ["type": "integer"],
                  "maxPremiumCost": ["type": "number"],
                  "priority": ["type": "integer"],
                  "timeoutSeconds": ["type": "number"]
                ],
                "required": ["prompt"]
              ]
            ],
            "parallel": ["type": "boolean"]
          ],
          "required": ["runs"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.stop",
        description: "Cancel a running chain by runId (or all running chains)",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "all": ["type": "boolean"]
          ]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.pause",
        description: "Pause a running chain by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.resume",
        description: "Resume a paused chain by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.step",
        description: "Step a paused chain to the next agent by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.queue.status",
        description: "Get chain queue status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .chains,
        isMutating: false
      ),
      ToolDefinition(
        name: "chains.queue.configure",
        description: "Configure chain queue limits",
        inputSchema: [
          "type": "object",
          "properties": [
            "maxConcurrent": ["type": "integer"],
            "maxQueued": ["type": "integer"]
          ]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.queue.cancel",
        description: "Cancel a queued chain by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "logs.mcp.path",
        description: "Get MCP log file path",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .logs,
        isMutating: false
      ),
      ToolDefinition(
        name: "logs.mcp.tail",
        description: "Get last N lines of MCP log",
        inputSchema: [
          "type": "object",
          "properties": [
            "lines": ["type": "integer"]
          ]
        ],
        category: .logs,
        isMutating: false
      ),
      ToolDefinition(
        name: "server.stop",
        description: "Stop the MCP server",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: true
      ),
      ToolDefinition(
        name: "server.restart",
        description: "Restart the MCP server",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: true
      ),
      ToolDefinition(
        name: "server.port.set",
        description: "Set MCP server port and restart",
        inputSchema: [
          "type": "object",
          "properties": [
            "port": ["type": "integer"],
            "autoFind": ["type": "boolean"],
            "maxAttempts": ["type": "integer"]
          ],
          "required": ["port"]
        ],
        category: .server,
        isMutating: true
      ),
      ToolDefinition(
        name: "server.status",
        description: "Get MCP server status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: false
      ),
      ToolDefinition(
        name: "app.quit",
        description: "Quit the Peel app",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .app,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "app.activate",
        description: "Bring the Peel app to the foreground",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .app,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "screenshot.capture",
        description: "Capture screenshot of current screen state",
        inputSchema: [
          "type": "object",
          "properties": [
            "label": ["type": "string"]
          ]
        ],
        category: .diagnostics,
        isMutating: false,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "translations.validate",
        description: "Validate translation key parity and consistency",
        inputSchema: [
          "type": "object",
          "properties": [
            "root": ["type": "string"],
            "translationsPath": ["type": "string"],
            "baseLocale": ["type": "string"],
            "only": ["type": "string"],
            "summary": ["type": "boolean"],
            "toolPath": ["type": "string"],
            "useAppleAI": ["type": "boolean"],
            "redactSamples": ["type": "boolean"]
          ]
        ],
        category: .diagnostics,
        isMutating: false
      ),
      ToolDefinition(
        name: "pii.scrub",
        description: "Scrub PII from a text file using the pii-scrubber CLI",
        inputSchema: [
          "type": "object",
          "properties": [
            "inputPath": ["type": "string"],
            "outputPath": ["type": "string"],
            "reportPath": ["type": "string"],
            "reportFormat": ["type": "string"],
            "configPath": ["type": "string"],
            "seed": ["type": "string"],
            "maxSamples": ["type": "integer"],
            "enableNER": ["type": "boolean"],
            "toolPath": ["type": "string"]
          ],
          "required": ["inputPath", "outputPath"]
        ],
        category: .diagnostics,
        isMutating: true
      ),
      // Parallel Worktree Tools
      ToolDefinition(
        name: "parallel.create",
        description: "Create a new parallel worktree run with multiple tasks",
        inputSchema: [
          "type": "object",
          "properties": [
            "name": ["type": "string"],
            "projectPath": ["type": "string"],
            "baseBranch": ["type": "string"],
            "targetBranch": ["type": "string"],
            "requireReviewGate": ["type": "boolean"],
            "autoMergeOnApproval": ["type": "boolean"],
            "tasks": [
              "type": "array",
              "items": [
                "type": "object",
                "properties": [
                  "title": ["type": "string"],
                  "description": ["type": "string"],
                  "prompt": ["type": "string"],
                  "focusPaths": [
                    "type": "array",
                    "items": ["type": "string"]
                  ]
                ],
                "required": ["title", "prompt"]
              ]
            ]
          ],
          "required": ["name", "projectPath", "tasks"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.start",
        description: "Start a pending parallel worktree run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.status",
        description: "Get status of a parallel worktree run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: false
      ),
      ToolDefinition(
        name: "parallel.list",
        description: "List all parallel worktree runs",
        inputSchema: [
          "type": "object",
          "properties": [
            "includeCompleted": ["type": "boolean"]
          ]
        ],
        category: .parallelWorktrees,
        isMutating: false
      ),
      ToolDefinition(
        name: "parallel.approve",
        description: "Approve an execution in a parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "approveAll": ["type": "boolean"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.reject",
        description: "Reject an execution in a parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "reason": ["type": "string"]
          ],
          "required": ["runId", "executionId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.merge",
        description: "Merge approved executions in a parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "mergeAll": ["type": "boolean"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.cancel",
        description: "Cancel a parallel worktree run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      )
    ]
  }

  private func toolList() -> [[String: Any]] {
    toolDefinitions.map { tool in
      [
        "name": tool.name,
        "description": tool.description,
        "inputSchema": tool.inputSchema,
        "category": tool.category.rawValue,
        "groups": groups(for: tool).map { $0.rawValue },
        "enabled": isToolEnabled(tool.name),
        "requiresForeground": tool.requiresForeground
      ]
    }
  }

  private func scheduleAppQuit() {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      NSApp.terminate(nil)
    }
  }

  private func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
  }

  private func templateList() -> [[String: Any]] {
    return agentManager.allTemplates.map { template in
      [
        "id": template.id.uuidString,
        "name": template.name,
        "description": template.description,
        "steps": template.steps.map { step in
          [
            "role": step.role.displayName,
            "model": step.model.displayName,
            "name": step.name,
            "frameworkHint": step.frameworkHint.rawValue,
            "customInstructions": step.customInstructions as Any
          ]
        }
      ]
    }
  }

  private func summarizeResults(_ results: [AgentChainResult]) -> [[String: Any]] {
    let formatter = ISO8601DateFormatter()
    return results.map { result in
      var item: [String: Any] = [
        "agentId": result.agentId.uuidString,
        "agentName": result.agentName,
        "model": result.model,
        "prompt": result.prompt,
        "output": result.output,
        "duration": result.duration as Any,
        "premiumCost": result.premiumCost,
        "timestamp": formatter.string(from: result.timestamp)
      ]
      if let verdict = result.reviewVerdict {
        item["reviewVerdict"] = verdict.rawValue
      }
      if let decision = result.plannerDecision {
        item["plannerDecision"] = [
          "branch": decision.branch,
          "tasks": decision.tasks.map { task in
            [
              "title": task.title,
              "description": task.description,
              "recommendedModel": task.recommendedModel as Any,
              "fileHints": task.fileHints as Any
            ]
          },
          "noWorkReason": decision.noWorkReason as Any
        ]
      }
      return item
    }
  }

  private func parseChainSpec(_ spec: [String: Any]) -> ChainTemplate? {
    let name = (spec["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let description = spec["description"] as? String ?? ""
    guard let stepsValue = spec["steps"] as? [[String: Any]], !stepsValue.isEmpty else {
      return nil
    }

    let steps: [AgentStepTemplate] = stepsValue.compactMap { step in
      guard let roleValue = step["role"] as? String,
            let role = AgentRole.fromString(roleValue),
            let modelValue = step["model"] as? String,
            let model = CopilotModel.fromString(modelValue) else {
        return nil
      }
      let stepName = (step["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let frameworkHintValue = (step["frameworkHint"] as? String) ?? FrameworkHint.auto.rawValue
      let frameworkHint = FrameworkHint(rawValue: frameworkHintValue) ?? .auto
      let customInstructions = step["customInstructions"] as? String
      return AgentStepTemplate(
        role: role,
        model: model,
        name: stepName?.isEmpty == false ? stepName! : role.displayName,
        frameworkHint: frameworkHint,
        customInstructions: customInstructions
      )
    }

    guard steps.count == stepsValue.count else { return nil }

    return ChainTemplate(
      name: name?.isEmpty == false ? name! : "Dynamic Chain",
      description: description,
      steps: steps,
      isBuiltIn: false
    )
  }

  private func makeRPCResult(id: Any?, result: Any) -> Data {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id as Any,
      "result": result
    ]
    return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
  }

  private func makeRPCError(id: Any?, code: Int, message: String) -> Data {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id as Any,
      "error": ["code": code, "message": message]
    ]
    return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
  }

  private func sendHTTPResponse(status: Int, body: Data, on connection: NWConnection) {
    let statusLine: String
    switch status {
    case 200: statusLine = "HTTP/1.1 200 OK"
    case 400: statusLine = "HTTP/1.1 400 Bad Request"
    case 404: statusLine = "HTTP/1.1 404 Not Found"
    default: statusLine = "HTTP/1.1 500 Internal Server Error"
    }

    let header = "\(statusLine)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var response = Data(header.utf8)
    response.append(body)

    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  public func recordUIActionHandled(_ controlId: String) {
    lastUIActionHandled = controlId
    lastUIActionHandledAt = Date()
    appendUIActionRecord(controlId: controlId, status: "handled")
  }

  public func recordUIActionRequested(_ controlId: String) {
    appendUIActionRecord(controlId: controlId, status: "requested")
  }

  public func recordUIActionForegroundNeeded(_ controlId: String) {
    appendUIActionRecord(controlId: controlId, status: "foreground-needed")
  }

  private func appendUIActionRecord(controlId: String, status: String) {
    let record = UIActionRecord(controlId: controlId, status: status)
    recentUIActions.insert(record, at: 0)
    if recentUIActions.count > 25 {
      recentUIActions.removeLast(recentUIActions.count - 25)
    }
  }

  private func availableViewIds() -> [String] {
    ["agents", "workspaces", "brew", "git", "github"]
  }

  private func viewTitle(for viewId: String) -> String {
    switch viewId {
    case "agents": return "Agents"
    case "workspaces": return "Workspaces"
    case "brew": return "Homebrew"
    case "git": return "Git"
    case "github": return "GitHub"
    default: return viewId.capitalized
    }
  }

  private func groups(for tool: ToolDefinition) -> [ToolGroup] {
    var groups: [ToolGroup] = []
    if tool.name == "screenshot.capture" {
      groups.append(.screenshots)
    }
    if tool.name == "ui.navigate" || tool.name == "ui.back" || tool.name == "ui.snapshot" {
      groups.append(.uiNavigation)
    }
    if tool.isMutating {
      groups.append(.mutating)
    }
    if !tool.requiresForeground {
      groups.append(.backgroundSafe)
    }
    return groups
  }

  private func stringValues(_ value: Any?) -> [String] {
    if let strings = value as? [String] {
      return strings
    }
    return []
  }

  private func availableToolControlIds() -> [String] {
    availableViewIds().map { "tool.\($0)" }
  }

  private func availableControlIds(for viewId: String?) -> [String] {
    switch viewId {
    case "agents":
      return [
        "agents.newAgent",
        "agents.newChain",
        "agents.mcpDashboard",
        "agents.cliSetup",
        "agents.sessionSummary",
        "agents.vmIsolation",
        "agents.translationValidation",
        "agents.localRag",
        "agents.piiScrubber",
        "agents.localRag.refresh",
        "agents.localRag.repoPath",
        "agents.localRag.init",
        "agents.localRag.index",
        "agents.localRag.query",
        "agents.localRag.mode",
        "agents.localRag.limit",
        "agents.localRag.search",
        "agents.localRag.useCoreML"
      ]
    case "github":
      return [
        "github.login",
        "github.refresh",
        "github.showArchived",
        "github.logout",
        "github.selectFavorite",
        "github.selectRecentPR"
      ]
    case "brew":
      return ["brew.source", "brew.search"]
    case "workspaces":
      return [
        "workspaces.refresh",
        "workspaces.addWorkspace",
        "workspaces.createWorktree",
        "workspaces.openInVSCode",
        "workspaces.selectWorkspace",
        "workspaces.selectRepo",
        "workspaces.selectWorktree",
        "workspaces.selectWorktreeName",
        "workspaces.openSelectedWorktree",
        "workspaces.removeSelectedWorktree"
      ]
    case "git":
      return ["git.openRepository", "git.cloneRepository", "git.openInVSCode", "git.selectRepo"]
    default:
      return []
    }
  }

  private func controlValues(for viewId: String?) -> [String: Any] {
    switch viewId {
    case "github":
      let favoriteKeys = UserDefaults.standard.stringArray(forKey: "github.availableFavoriteKeys") ?? []
      let recentPRKeys = UserDefaults.standard.stringArray(forKey: "github.availableRecentPRKeys") ?? []
      return [
        "github.selectFavorite": favoriteKeys,
        "github.selectRecentPR": recentPRKeys
      ]
    case "brew":
      return [
        "brew.source": ["Installed", "Available"]
      ]
    case "workspaces":
      let workspaceNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableNames") ?? []
      let repoNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableRepoNames") ?? []
      let worktreePaths = UserDefaults.standard.stringArray(forKey: "workspaces.availableWorktreePaths") ?? []
      let worktreeNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableWorktreeNames") ?? []
      return [
        "workspaces.selectWorkspace": workspaceNames,
        "workspaces.selectRepo": repoNames,
        "workspaces.selectWorktree": worktreePaths,
        "workspaces.selectWorktreeName": worktreeNames
      ]
    case "agents":
      let limits = (1...25).map { String($0) }
      return [
        "agents.localRag.mode": RAGSearchMode.allCases.map { $0.rawValue },
        "agents.localRag.limit": limits
      ]
    case "git":
      let repoPaths = UserDefaults.standard.stringArray(forKey: "git.availableRepoPaths") ?? []
      let repoNames = UserDefaults.standard.stringArray(forKey: "git.availableRepoNames") ?? []
      return [
        "git.selectRepo": repoPaths,
        "git.selectRepoNames": repoNames
      ]
    default:
      return [:]
    }
  }

  private func dedupeStrings(_ values: [String]?) -> [String] {
    guard let values else { return [] }
    return Array(Set(values)).sorted()
  }

  private func currentToolId() -> String? {
    UserDefaults.standard.string(forKey: "current-tool")
  }

  private func setCurrentToolId(_ toolId: String) {
    UserDefaults.standard.set(toolId, forKey: "current-tool")
  }

  private func worktreeNameMapFromDefaults() -> [String: String] {
    guard let data = UserDefaults.standard.data(forKey: "workspaces.availableWorktreeNameMap"),
          let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
      return [:]
    }
    return decoded
  }
}

private actor MergeCoordinator {
  static let shared = MergeCoordinator()

  private var locks = Set<String>()
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func acquire(_ key: String) async {
    if !locks.contains(key) {
      locks.insert(key)
      return
    }

    await withCheckedContinuation { continuation in
      waiters[key, default: []].append(continuation)
    }
  }

  func release(_ key: String) {
    if var queue = waiters[key], !queue.isEmpty {
      let continuation = queue.removeFirst()
      waiters[key] = queue
      continuation.resume()
      return
    }

    locks.remove(key)
    waiters[key] = nil
  }
}

#else
// iOS stub
@MainActor
@Observable
public final class AgentManager {
  public private(set) var agents: [Agent] = []
  public let workspaceManager = AgentWorkspaceService()
  public var selectedAgent: Agent?
  public init() {}
}
#endif
