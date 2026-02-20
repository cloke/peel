//
//  AgentChainRunner.swift
//  KitchenSync
//
//  Extracted from AgentManager.swift on 1/24/26.
//

import Foundation
import Git
import Observation
import OSLog
import SwiftData
import TaskRunner

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
    public let allowImplementerModelOverride: Bool
    public let allowPlannerImplementerScaling: Bool
    public let maxImplementers: Int?
    public let maxPremiumCost: Double?

    public init(
      allowPlannerModelSelection: Bool = false,
      allowImplementerModelOverride: Bool = false,
      allowPlannerImplementerScaling: Bool = false,
      maxImplementers: Int? = nil,
      maxPremiumCost: Double? = nil
    ) {
      self.allowPlannerModelSelection = allowPlannerModelSelection
      self.allowImplementerModelOverride = allowImplementerModelOverride
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
  private let telemetryProvider: MCPTelemetryProviding
  private let validationRunner = ValidationRunner()
  private let mergeCoordinator = MergeCoordinator.shared
  private let screenshotService = ScreenshotService()
  private let localRagStore = makeDefaultRAGStore()
  private var runGates: [UUID: ChainRunGate] = [:]

  public init(
    agentManager: AgentManager,
    cliService: CLIService,
    telemetryProvider: MCPTelemetryProviding
  ) {
    self.agentManager = agentManager
    self.cliService = cliService
    self.telemetryProvider = telemetryProvider
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
    PeonPingService.shared.chainStarted(name: chain.name)
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
      
      // Run pre-planner if enabled (Issue #133)
      var enrichedPrompt = prompt
      if chain.enablePrePlanner {
        chain.addStatusMessage("Running pre-planner (RAG context gathering)...", type: .progress)
        do {
          let prePlannerOutput = try await runPrePlanner(chain: chain, prompt: prompt)
          chain.prePlannerOutput = prePlannerOutput
          enrichedPrompt = buildEnrichedPrompt(original: prompt, prePlannerOutput: prePlannerOutput)
          chain.addStatusMessage("Pre-planner complete: \(prePlannerOutput.relevantFiles.count) relevant files found", type: .complete)
        } catch {
          chain.addStatusMessage("Pre-planner failed, continuing without enrichment: \(error.localizedDescription)", type: .info)
        }
      }
      
      try await runAgentsWithParallelImplementers(
        chain: chain,
        prompt: enrichedPrompt,
        mergeConflicts: &mergeConflicts,
        runOptions: runOptions
      )

      if case .complete = chain.state {
        telemetryProvider.recordChainRun(chain)
      } else {
        try checkCancellation(chain: chain)
        if chain.enableReviewLoop {
          try await runReviewLoop(chain: chain, prompt: prompt)
        }

        chain.state = .complete
        chain.addStatusMessage("✓ Chain completed successfully!", type: .complete)
        PeonPingService.shared.chainCompleted(name: chain.name)
        telemetryProvider.recordChainRun(chain)
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
        PeonPingService.shared.chainFailed(name: chain.name, error: error.localizedDescription)
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
      kIOPMAssertionTypeNoIdleSleep as CFString,
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
    chain.plannerDecision = decision
    
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
    var newImplementerIds: Set<UUID> = []

    if desiredCount < implementers.count {
      let removed = implementers.suffix(from: desiredCount)
      implementers = Array(implementers.prefix(desiredCount))
      for agent in removed {
        await agentManager.removeAgent(agent)
      }
    } else if desiredCount > implementers.count {
      let startIndex = implementers.count
      for index in startIndex..<desiredCount {
        let task = tasks.indices.contains(index) ? tasks[index] : nil
        let taskTitle = task?.title ?? "Implementer \(index + 1)"
        let taskDescription = task?.description
        let agent = agentManager.createAgent(
          name: taskTitle,
          type: .copilot,
          role: .implementer,
          model: implementers.first?.model ?? .claudeSonnet45,
          customInstructions: taskDescription,
          workingDirectory: chain.workingDirectory
        )
        if let fileHints = task?.fileHints {
          agent.assignedTaskFileHints = fileHints
        }
        implementers.append(agent)
        newImplementerIds.insert(agent.id)
      }
    }

    if options.allowPlannerModelSelection {
      for (index, agent) in implementers.enumerated() {
        if options.allowImplementerModelOverride,
           !newImplementerIds.contains(agent.id) {
          continue
        }
        guard index < tasks.count,
              let modelName = tasks[index].recommendedModel,
              let model = CopilotModel.fromString(modelName) else {
          continue
        }
        agent.model = model
      }
      if options.allowImplementerModelOverride {
        chain.addStatusMessage("Applied planner model recommendations for new implementers", type: .info)
      } else {
        chain.addStatusMessage("Applied planner model recommendations", type: .info)
      }
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
    
    // Check if we're already running inside a managed worktree (e.g. from ParallelWorktreeRunner).
    // In that case, don't create additional workspaces — use the worktree directly.
    let isInChainWorktree = workingDirectory.contains(AgentWorkspaceService.workspacesDirName)
    
    if isInChainWorktree {
      await telemetryProvider.info("Running in existing chain worktree - skipping workspace creation", metadata: [
        "chainId": chain.id.uuidString,
        "workingDirectory": workingDirectory
      ])
    }

    var ragContexts: [UUID: String] = [:]
    for index in indices {
      try checkCancellation(chain: chain)
      let agent = chain.agents[index]
      
      if isInChainWorktree {
        // Use chain's worktree directly - don't create additional workspaces
        agent.workingDirectory = workingDirectory
        await telemetryProvider.info("Parallel implementer using chain worktree", metadata: [
          "chainId": chain.id.uuidString,
          "agentId": agent.id.uuidString,
          "agentName": agent.name,
          "role": agent.role.displayName,
          "workingDirectory": workingDirectory
        ])
      } else {
        // Original behavior: create separate workspaces for each implementer
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
        await telemetryProvider.info("Parallel implementer workspace created", metadata: [
          "chainId": chain.id.uuidString,
          "agentId": agent.id.uuidString,
          "agentName": agent.name,
          "role": agent.role.displayName,
          "branch": workspace.branch,
          "workingDirectory": workspace.path.path
        ])
        agent.workspace = workspace
        agent.workingDirectory = workspace.path.path
      }

      let storedQuery = UserDefaults.standard.string(forKey: RagDefaults.query) ?? ""
      let ragQuery = storedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? prompt
      : storedQuery
      if let ragContext = await buildRagContext(
        query: ragQuery,
        repoPath: agent.workingDirectory ?? workingDirectory,
        fileHints: agent.assignedTaskFileHints
      ) {
        ragContexts[agent.id] = ragContext
      }
    }

    var results: [Int: AgentChainResult] = [:]
    try await withThrowingTaskGroup(of: (Int, AgentChainResult).self) { group in
      for index in indices {
        let agent = chain.agents[index]
        let taskContext = buildTaskContext(agent: agent, chain: chain, index: index)
        let agentContext = [taskContext, context, ragContexts[agent.id]].compactMap { value in
          let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n\n")
        group.addTask {
          try await Task { @MainActor in
            try self.checkCancellation(chain: chain)
            await self.telemetryProvider.info("Parallel implementer start", metadata: [
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
            await self.telemetryProvider.info("Parallel implementer complete", metadata: [
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
  
  private func buildTaskContext(agent: Agent, chain: AgentChain, index: Int) -> String? {
    guard let decision = chain.plannerDecision,
          index < decision.tasks.count else {
      return nil
    }
    
    let task = decision.tasks[index]
    var parts: [String] = []
    
    parts.append("## Assigned Task: \(task.title)")
    
    if !task.description.isEmpty {
      parts.append("\n**Description:**\n\(task.description)")
    }
    
    if let fileHints = agent.assignedTaskFileHints, !fileHints.isEmpty {
      parts.append("\n**Focus on these files:**")
      for hint in fileHints {
        parts.append("- \(hint)")
      }
    }
    
    return parts.joined(separator: "\n")
  }

  private func buildRagContext(
    query: String,
    repoPath: String,
    fileHints: [String]? = nil
  ) async -> String? {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return nil }

    let mode = UserDefaults.standard.string(forKey: RagDefaults.searchMode) ?? "text"
    let storedLimit = UserDefaults.standard.integer(forKey: RagDefaults.searchLimit)
    let limit = storedLimit == 0 ? 5 : storedLimit

    do {
      var results: [LocalRAGSearchResult]
      if mode.lowercased() == "vector" {
        results = try await localRagStore.searchVector(query: trimmedQuery, repoPath: repoPath, limit: limit)
      } else {
        results = try await localRagStore.search(query: trimmedQuery, repoPath: repoPath, limit: limit)
      }

      guard !results.isEmpty else { return nil }
      
      if let hints = fileHints, !hints.isEmpty {
        let prioritized = results.sorted { result1, result2 in
          let path1 = result1.filePath
          let path2 = result2.filePath
          let match1 = hints.contains { hint in path1.contains(hint) }
          let match2 = hints.contains { hint in path2.contains(hint) }
          if match1 && !match2 { return true }
          if !match1 && match2 { return false }
          return false
        }
        results = prioritized
      }

      let snippets = results.map { result in
        "- \(result.filePath) [\(result.startLine)-\(result.endLine)]:\n\(result.snippet)"
      }
      return ([
        "Local RAG context for: \"\(trimmedQuery)\"",
        snippets.joined(separator: "\n\n")
      ]).joined(separator: "\n")
    } catch {
      await telemetryProvider.warning("Local RAG context build failed", metadata: ["error": error.localizedDescription])
      return nil
    }
  }

  private func mergeImplementerBranches(chain: AgentChain, indices: [Int]) async throws -> [String] {
    guard let workingDirectory = chain.workingDirectory else {
      return []
    }
    
    // Check if agents have separate workspaces to merge
    // If running in a chain worktree (from ParallelWorktreeRunner), agents share the same directory
    let hasWorkspacesToMerge = indices.contains { chain.agents[$0].workspace != nil }
    if !hasWorkspacesToMerge {
      await telemetryProvider.info("No separate workspaces to merge - agents shared the same worktree", metadata: [
        "chainId": chain.id.uuidString,
        "workingDirectory": workingDirectory
      ])
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
      await telemetryProvider.warning("Merge aborted: dirty working tree", metadata: ["repo": workingDirectory])
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
        await telemetryProvider.warning("Merge conflicts detected", metadata: [
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

    // Dispatch based on step type
    switch agent.stepType {
    case .deterministic:
      return try await runDeterministicStep(agent, at: index, chain: chain, prompt: prompt)
    case .gate:
      return try await runGateStep(agent, at: index, chain: chain, prompt: prompt)
    case .agentic:
      return try await runAgenticStep(agent, at: index, chain: chain, prompt: prompt, contextOverride: contextOverride)
    }
  }

  // MARK: - Deterministic Step Execution

  /// Run a deterministic step: execute a shell command directly, no LLM involved.
  /// The command string is run via /bin/zsh. Stdout/stderr are captured as the step output.
  private func runDeterministicStep(
    _ agent: Agent,
    at index: Int,
    chain: AgentChain,
    prompt: String
  ) async throws -> AgentChainResult {
    guard let command = agent.command, !command.isEmpty else {
      throw ChainError.configurationError("Deterministic step '\(agent.name)' has no command")
    }

    let workingDirectory = agent.workingDirectory ?? chain.workingDirectory
    let startTime = Date()

    await telemetryProvider.info("Deterministic step start", metadata: [
      "chainId": chain.id.uuidString,
      "agentName": agent.name,
      "command": command,
      "workingDirectory": workingDirectory ?? ""
    ])

    agent.updateState(.working)
    chain.addStatusMessage("Running: \(command)", type: .tool)

    let (exitCode, stdout, stderr) = await runShellCommand(command, in: workingDirectory)
    let duration = Date().timeIntervalSince(startTime)
    let durationStr = String(format: "%.1fs", duration)

    let output = [
      stdout.isEmpty ? nil : stdout,
      stderr.isEmpty ? nil : "stderr: \(stderr)"
    ].compactMap { $0 }.joined(separator: "\n")

    if exitCode != 0 {
      agent.updateState(.failed(message: "Exit code \(exitCode)"))
      chain.addStatusMessage("Step '\(agent.name)' failed (exit \(exitCode))", type: .error)
      await telemetryProvider.warning("Deterministic step failed", metadata: [
        "agentName": agent.name,
        "exitCode": "\(exitCode)",
        "stderr": stderr
      ])
      throw ChainError.deterministicStepFailed(
        stepName: agent.name,
        exitCode: exitCode,
        output: output
      )
    }

    agent.updateState(.complete)
    chain.addStatusMessage("Step '\(agent.name)' completed (\(durationStr))", type: .complete)

    await telemetryProvider.info("Deterministic step complete", metadata: [
      "agentName": agent.name,
      "duration": durationStr
    ])

    return AgentChainResult(
      agentId: agent.id,
      agentName: agent.name,
      model: "deterministic",
      prompt: command,
      output: output,
      duration: durationStr,
      premiumCost: 0
    )
  }

  // MARK: - Gate Step Execution

  /// Run a gate step: execute a shell command and decide whether the chain continues.
  /// Exit code 0 = pass (continue), non-zero = fail (stop chain).
  private func runGateStep(
    _ agent: Agent,
    at index: Int,
    chain: AgentChain,
    prompt: String
  ) async throws -> AgentChainResult {
    guard let command = agent.command, !command.isEmpty else {
      throw ChainError.configurationError("Gate step '\(agent.name)' has no command")
    }

    let workingDirectory = agent.workingDirectory ?? chain.workingDirectory
    let startTime = Date()

    await telemetryProvider.info("Gate step start", metadata: [
      "chainId": chain.id.uuidString,
      "agentName": agent.name,
      "command": command,
      "workingDirectory": workingDirectory ?? ""
    ])

    agent.updateState(.testing)
    chain.addStatusMessage("Gate check: \(command)", type: .tool)

    let (exitCode, stdout, stderr) = await runShellCommand(command, in: workingDirectory)
    let duration = Date().timeIntervalSince(startTime)
    let durationStr = String(format: "%.1fs", duration)

    let output = [
      stdout.isEmpty ? nil : stdout,
      stderr.isEmpty ? nil : "stderr: \(stderr)"
    ].compactMap { $0 }.joined(separator: "\n")

    let passed = exitCode == 0

    if passed {
      agent.updateState(.complete)
      chain.addStatusMessage("Gate '\(agent.name)' passed (\(durationStr))", type: .complete)
    } else {
      agent.updateState(.failed(message: "Gate failed (exit \(exitCode))"))
      chain.addStatusMessage("Gate '\(agent.name)' failed (exit \(exitCode))", type: .error)
    }

    await telemetryProvider.info("Gate step complete", metadata: [
      "agentName": agent.name,
      "passed": "\(passed)",
      "exitCode": "\(exitCode)",
      "duration": durationStr
    ])

    var result = AgentChainResult(
      agentId: agent.id,
      agentName: agent.name,
      model: "gate",
      prompt: command,
      output: output,
      duration: durationStr,
      premiumCost: 0
    )
    result.gateResult = passed ? .passed : .failed(exitCode: exitCode)

    if !passed {
      throw ChainError.gateStepFailed(
        stepName: agent.name,
        exitCode: exitCode,
        output: output
      )
    }

    return result
  }

  /// Execute a shell command via /bin/zsh and return (exitCode, stdout, stderr)
  private func runShellCommand(_ command: String, in workingDirectory: String?) async -> (Int32, String, String) {
    await withCheckedContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-c", command]
      if let wd = workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: wd)
      }

      // Inherit the user's shell environment for PATH, etc.
      var env = ProcessInfo.processInfo.environment
      // Ensure common tool paths are available
      let existingPath = env["PATH"] ?? ""
      env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
      process.environment = env

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      do {
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        continuation.resume(returning: (process.terminationStatus, stdout, stderr))
      } catch {
        continuation.resume(returning: (1, "", error.localizedDescription))
      }
    }
  }

  // MARK: - Agentic Step Execution

  /// Run an agentic step: full LLM invocation through the copilot CLI.
  private func runAgenticStep(
    _ agent: Agent,
    at index: Int,
    chain: AgentChain,
    prompt: String,
    contextOverride: String? = nil
  ) async throws -> AgentChainResult {
    let context = contextOverride ?? chain.contextForAgent(at: index)

    await telemetryProvider.info("Agent run start", metadata: [
      "chainId": chain.id.uuidString,
      "agentId": agent.id.uuidString,
      "agentName": agent.name,
      "role": agent.role.displayName,
      "model": agent.model.displayName,
      "workingDirectory": agent.workingDirectory ?? chain.workingDirectory ?? ""
    ])

    let fullPrompt = agent.buildPrompt(
      userPrompt: applyOperatorGuidance(prompt, chain: chain),
      context: context.isEmpty ? nil : context
    )
    agent.updateState(.working)

    do {
      let response = try await cliService.runCopilotSession(
        prompt: fullPrompt,
        model: agent.model,
        role: agent.role,
        workingDirectory: agent.workingDirectory ?? chain.workingDirectory,
        allowedTools: agent.allowedTools,
        deniedTools: agent.stepDeniedTools,
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
      await telemetryProvider.info("Agent run complete", metadata: [
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
        await telemetryProvider.info("Screenshot saved", metadata: ["path": url.path])
      } catch {
        // Non-fatal: log and continue
        await telemetryProvider.warning("Screenshot failed", metadata: ["error": error.localizedDescription])
        chain.addStatusMessage("Screenshot failed: \(error.localizedDescription)", type: .error)
      }

      return result
    } catch {
      if case ChainError.cancelled = error {
        await telemetryProvider.warning("Agent run cancelled", metadata: [
          "agent": agent.name,
          "role": agent.role.displayName,
          "model": agent.model.displayName
        ])
        agent.updateState(.failed(message: "Cancelled"))
        throw error
      }
      await telemetryProvider.error(error, context: "Agent run failed", metadata: [
        "agent": agent.name,
        "role": agent.role.displayName,
        "model": agent.model.displayName
      ])
      agent.updateState(.failed(message: error.localizedDescription))
      throw error
    }
  }

  private func applyOperatorGuidance(_ prompt: String, chain: AgentChain) -> String {
    guard !chain.operatorGuidance.isEmpty else { return prompt }
    let guidanceBlock = chain.operatorGuidance
      .enumerated()
      .map { index, entry in "\(index + 1). \(entry)" }
      .joined(separator: "\n")
    return [
      prompt,
      "\n\n## Operator Guidance\n",
      guidanceBlock
    ].joined()
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
          await autoCaptureLessonFromFix(
            chain: chain,
            reviewerFeedback: latestFeedback,
            implementerFix: implementerResult.output
          )
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

  enum ChainError: LocalizedError, SimpleMessageError {
    case reviewRejected(reason: String)
    case cancelled
    case configurationError(String)
    case deterministicStepFailed(stepName: String, exitCode: Int32, output: String)
    case gateStepFailed(stepName: String, exitCode: Int32, output: String)

    var errorDescription: String? { defaultErrorDescription }

    var messageValue: String? {
      switch self {
      case .reviewRejected(let reason):
        return "Review rejected: \(reason.prefix(200))..."
      case .cancelled:
        return "Chain cancelled"
      case .configurationError(let msg):
        return "Configuration error: \(msg)"
      case .deterministicStepFailed(let name, let code, _):
        return "Deterministic step '\(name)' failed (exit \(code))"
      case .gateStepFailed(let name, let code, _):
        return "Gate '\(name)' failed (exit \(code))"
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
  
  // MARK: - Pre-Planner (Issue #133)
  
  /// Run the pre-planner step to gather RAG context before the main planner
  private func runPrePlanner(chain: AgentChain, prompt: String) async throws -> PrePlannerOutput {
    let startTime = Date()
    
    // Search RAG for relevant context
    let repoPath = chain.workingDirectory
    let ragResults = try await localRagStore.searchVector(query: prompt, repoPath: repoPath, limit: 15)
    
    // Extract relevant files
    let relevantFiles = ragResults.map { result in
      PrePlannerOutput.RelevantFile(
        path: result.filePath,
        startLine: result.startLine,
        endLine: result.endLine,
        relevanceScore: result.score,
        constructType: result.constructType,
        constructName: result.constructName
      )
    }
    
    // Query lessons relevant to the files we'll be working with (#210)
    let lessons: [PrePlannerOutput.Lesson]
    if let repoPath {
      lessons = await queryRelevantLessons(repoPath: repoPath, relevantFiles: relevantFiles, prompt: prompt)
    } else {
      lessons = []
    }
    
    // Infer goals from the prompt
    let goals = inferGoals(from: prompt)
    
    // Infer constraints from RAG context
    let constraints = inferConstraints(from: ragResults, repoPath: repoPath)
    
    // Build context summary
    let contextSummary = buildContextSummary(files: relevantFiles, ragResults: ragResults)
    
    let duration = Date().timeIntervalSince(startTime)
    
    return PrePlannerOutput(
      goals: goals,
      constraints: constraints,
      relevantFiles: relevantFiles,
      lessons: lessons,
      contextSummary: contextSummary,
      timestamp: Date(),
      durationSeconds: duration
    )
  }
  
  /// Infer goals from the user's prompt
  private func inferGoals(from prompt: String) -> [String] {
    var goals: [String] = []
    
    // Look for imperative verbs and action items
    let actionPatterns = [
      "add", "create", "implement", "build", "fix", "update", "refactor",
      "remove", "delete", "optimize", "improve", "integrate", "migrate"
    ]
    
    let sentences = prompt.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
    for sentence in sentences {
      let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      
      let lowercased = trimmed.lowercased()
      for pattern in actionPatterns {
        if lowercased.hasPrefix(pattern) || lowercased.contains(" \(pattern) ") {
          goals.append(trimmed)
          break
        }
      }
    }
    
    // If no goals found, use the first sentence as the primary goal
    if goals.isEmpty, let firstSentence = sentences.first?.trimmingCharacters(in: .whitespacesAndNewlines), !firstSentence.isEmpty {
      goals.append(firstSentence)
    }
    
    return goals
  }
  
  /// Infer constraints from RAG context
  private func inferConstraints(from ragResults: [LocalRAGSearchResult], repoPath: String?) -> [String] {
    var constraints: [String] = []
    
    // Detect language/framework patterns
    var languages = Set<String>()
    var frameworks = Set<String>()
    
    for result in ragResults {
      if let lang = result.language {
        languages.insert(lang)
      }
      
      // Detect common frameworks from content
      let snippet = result.snippet.lowercased()
      if snippet.contains("swiftui") || snippet.contains("@state") || snippet.contains("@observable") {
        frameworks.insert("SwiftUI")
      }
      if snippet.contains("uikit") || snippet.contains("uiviewcontroller") {
        frameworks.insert("UIKit")
      }
      if snippet.contains("combine") || snippet.contains("publisher") {
        frameworks.insert("Combine")
      }
      if snippet.contains("async") || snippet.contains("await") || snippet.contains("task {") {
        frameworks.insert("Swift Concurrency")
      }
    }
    
    if !languages.isEmpty {
      constraints.append("Primary languages: \(languages.sorted().joined(separator: ", "))")
    }
    if !frameworks.isEmpty {
      constraints.append("Frameworks in use: \(frameworks.sorted().joined(separator: ", "))")
    }
    
    // Check for test patterns
    let hasTests = ragResults.contains { $0.isTest }
    if hasTests {
      constraints.append("Project has existing tests - maintain test coverage")
    }
    
    // Check for module structure
    let modulePaths = Set(ragResults.compactMap { $0.modulePath })
    if modulePaths.count > 3 {
      constraints.append("Modular architecture with \(modulePaths.count) modules - respect module boundaries")
    }
    
    return constraints
  }
  
  /// Build a context summary for the planner
  private func buildContextSummary(files: [PrePlannerOutput.RelevantFile], ragResults: [LocalRAGSearchResult]) -> String {
    guard !files.isEmpty else {
      return "No relevant files found in the codebase for this task."
    }
    
    var summary = "## Relevant Code Context\n\n"
    
    // Group by construct type
    var byType: [String: [(file: PrePlannerOutput.RelevantFile, snippet: String)]] = [:]
    for (file, result) in zip(files, ragResults) {
      let type = file.constructType ?? "other"
      byType[type, default: []].append((file, result.snippet))
    }
    
    // Build summary by type
    for (type, items) in byType.sorted(by: { $0.key < $1.key }) {
      summary += "### \(type.capitalized)s\n"
      for (file, _) in items.prefix(5) {
        var entry = "- `\(file.path)`"
        if let name = file.constructName {
          entry += " (\(name))"
        }
        entry += " [L\(file.startLine)-\(file.endLine)]"
        summary += entry + "\n"
      }
      summary += "\n"
    }
    
    return summary
  }
  
  /// Build enriched prompt with pre-planner context
  private func buildEnrichedPrompt(original: String, prePlannerOutput: PrePlannerOutput) -> String {
    var enriched = ""
    
    // Add goals
    if !prePlannerOutput.goals.isEmpty {
      enriched += "## Inferred Goals\n"
      for goal in prePlannerOutput.goals {
        enriched += "- \(goal)\n"
      }
      enriched += "\n"
    }
    
    // Add constraints
    if !prePlannerOutput.constraints.isEmpty {
      enriched += "## Project Constraints\n"
      for constraint in prePlannerOutput.constraints {
        enriched += "- \(constraint)\n"
      }
      enriched += "\n"
    }
    
    // Add context summary
    if !prePlannerOutput.relevantFiles.isEmpty {
      enriched += prePlannerOutput.contextSummary
      enriched += "\n"
    }
    
    // Add lessons learned (#210)
    if !prePlannerOutput.lessons.isEmpty {
      enriched += "## Lessons Learned (from past fixes)\n\n"
      enriched += "These patterns have been identified from previous work on this codebase:\n\n"
      for lesson in prePlannerOutput.lessons {
        enriched += "### \(lesson.fixDescription)\n"
        if let pattern = lesson.filePattern {
          enriched += "- Applies to: `\(pattern)`\n"
        }
        if let sig = lesson.errorSignature {
          enriched += "- Error pattern: \(sig)\n"
        }
        if let code = lesson.fixCode {
          enriched += "- Fix: `\(code)`\n"
        }
        enriched += "- Confidence: \(Int(lesson.confidence * 100))%\n\n"
      }
    }
    
    // Add original prompt
    enriched += "## User Request\n\n"
    enriched += original
    
    return enriched
  }
  
  // MARK: - Lesson Query (#210)
  
  /// Query lessons relevant to the files we'll be working with
  private func autoCaptureLessonFromFix(
    chain: AgentChain,
    reviewerFeedback: String,
    implementerFix: String
  ) async {
    guard let repoPath = chain.workingDirectory, !repoPath.isEmpty else { return }

    let fileExt = chain.prePlannerOutput?.relevantFiles.first
      .flatMap { URL(fileURLWithPath: $0.path).pathExtension }
      .flatMap { $0.isEmpty ? nil : "*.\($0)" }
    
    let errorSignature: String? = reviewerFeedback
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map { String($0).trimmingCharacters(in: .whitespaces) }
      .flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }

    let fixLine = implementerFix
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    let fixDescription = "Auto-captured: \(String(fixLine.prefix(150)))"

    let fixCode: String? = implementerFix.isEmpty ? nil : String(implementerFix.prefix(500))

    do {
      _ = try await localRagStore.addLesson(
        repoPath: repoPath,
        filePattern: fileExt,
        errorSignature: errorSignature,
        fixDescription: fixDescription,
        fixCode: fixCode,
        source: "auto-capture"
      )
    } catch {
      // Silently ignore capture failures
    }
  }

  private func queryRelevantLessons(repoPath: String, relevantFiles: [PrePlannerOutput.RelevantFile], prompt: String) async -> [PrePlannerOutput.Lesson] {
    guard !repoPath.isEmpty else { return [] }
    
    var allLessons: [LocalRAGLesson] = []
    
    // Query lessons for each relevant file path
    for file in relevantFiles.prefix(5) {
      do {
        let lessons = try await localRagStore.queryLessons(
          repoPath: repoPath,
          filePattern: file.path,
          errorSignature: nil,
          limit: 5
        )
        allLessons.append(contentsOf: lessons)
      } catch {
        // Silently ignore query failures
      }
    }
    
    // Also query with the prompt text for error signature matches
    do {
      let promptLessons = try await localRagStore.queryLessons(
        repoPath: repoPath,
        filePattern: nil,
        errorSignature: prompt,
        limit: 5
      )
      allLessons.append(contentsOf: promptLessons)
    } catch {
      // Silently ignore
    }
    
    // Dedupe by ID, sort by confidence, take top 10
    var seen = Set<String>()
    let uniqueLessons = allLessons.filter { lesson in
      guard !seen.contains(lesson.id) else { return false }
      seen.insert(lesson.id)
      return true
    }
    .sorted { $0.confidence > $1.confidence }
    .prefix(10)
    
    return uniqueLessons.map { lesson in
      PrePlannerOutput.Lesson(
        id: lesson.id,
        filePattern: lesson.filePattern,
        errorSignature: lesson.errorSignature,
        fixDescription: lesson.fixDescription,
        fixCode: lesson.fixCode,
        confidence: lesson.confidence
      )
    }
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
