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
  private let telemetryProvider: MCPTelemetryProviding
  private let validationRunner = ValidationRunner()
  private let mergeCoordinator = MergeCoordinator.shared
  private let screenshotService = ScreenshotService()
  private let localRagStore = LocalRAGStore()
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
        telemetryProvider.recordChainRun(chain)
      } else {
        try checkCancellation(chain: chain)
        if chain.enableReviewLoop {
          try await runReviewLoop(chain: chain, prompt: prompt)
        }

        chain.state = .complete
        chain.addStatusMessage("✓ Chain completed successfully!", type: .complete)
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
      await telemetryProvider.warning("Local RAG context build failed", metadata: ["error": error.localizedDescription])
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
