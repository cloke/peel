//
//  AgentManager.swift
//  KitchenSync
//
//  Created on 1/7/26.
//

import Foundation
import Observation

#if os(macOS)
import Git
import Network
import SwiftData

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
  public let workspaceManager = WorkspaceManager()
  
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
  public struct RunSummary: Sendable {
    public let chainId: UUID
    public let chainName: String
    public let stateDescription: String
    public let results: [AgentChainResult]
    public let mergeConflicts: [String]
    public let errorMessage: String?
  }

  private let agentManager: AgentManager
  private let cliService: CLIService
  private let sessionTracker: SessionTracker

  public init(
    agentManager: AgentManager,
    cliService: CLIService,
    sessionTracker: SessionTracker
  ) {
    self.agentManager = agentManager
    self.cliService = cliService
    self.sessionTracker = sessionTracker
  }

  public func runChain(_ chain: AgentChain, prompt: String) async -> RunSummary {
    var mergeConflicts: [String] = []
    var errorMessage: String?

    chain.reset()
    chain.clearLiveStatus()
    chain.runStartTime = Date()
    chain.state = .running(agentIndex: 0)
    chain.addStatusMessage("Starting chain execution...", type: .info)

    do {
      try await runAgentsWithParallelImplementers(chain: chain, prompt: prompt, mergeConflicts: &mergeConflicts)

      if chain.enableReviewLoop {
        try await runReviewLoop(chain: chain, prompt: prompt)
      }

      chain.state = .complete
      chain.addStatusMessage("✓ Chain completed successfully!", type: .complete)
      sessionTracker.recordChainRun(chain)
    } catch {
      errorMessage = error.localizedDescription
      chain.state = .failed(message: error.localizedDescription)
      chain.addStatusMessage("Error: \(error.localizedDescription)", type: .error)
    }

    return RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: chain.state.displayName,
      results: chain.results,
      mergeConflicts: mergeConflicts,
      errorMessage: errorMessage
    )
  }

  private func runAgentsSequentially(chain: AgentChain, prompt: String) async throws {
    for (index, agent) in chain.agents.enumerated() {
      chain.state = .running(agentIndex: index)
      chain.currentAgentStartTime = Date()
      chain.addStatusMessage("Starting \(agent.name) (\(agent.model.shortName))...", type: .progress)
      let result = try await runSingleAgent(agent, at: index, chain: chain, prompt: prompt)
      chain.results.append(result)
      chain.addStatusMessage("\(agent.name) completed", type: .complete)
    }
  }

  private func runAgentsWithParallelImplementers(
    chain: AgentChain,
    prompt: String,
    mergeConflicts: inout [String]
  ) async throws {
    let implementerIndices = chain.agents.indices.filter { chain.agents[$0].role == .implementer }
    guard implementerIndices.count > 1 else {
      try await runAgentsSequentially(chain: chain, prompt: prompt)
      return
    }

    guard let firstImplementer = implementerIndices.first,
          let lastImplementer = implementerIndices.last else {
      try await runAgentsSequentially(chain: chain, prompt: prompt)
      return
    }

    let hasGaps = (firstImplementer...lastImplementer).contains { index in
      chain.agents[index].role != .implementer
    }
    if hasGaps {
      try await runAgentsSequentially(chain: chain, prompt: prompt)
      return
    }

    if firstImplementer > 0 {
      for index in 0..<firstImplementer {
        let agent = chain.agents[index]
        chain.state = .running(agentIndex: index)
        chain.currentAgentStartTime = Date()
        chain.addStatusMessage("Starting \(agent.name) (\(agent.model.shortName))...", type: .progress)
        let result = try await runSingleAgent(agent, at: index, chain: chain, prompt: prompt)
        chain.results.append(result)
        chain.addStatusMessage("\(agent.name) completed", type: .complete)
      }
    }

    let sharedContext = chain.contextForAgent(at: firstImplementer)
    let parallelResults = try await runImplementersInParallel(
      chain: chain,
      indices: Array(firstImplementer...lastImplementer),
      context: sharedContext,
      prompt: prompt
    )

    for index in firstImplementer...lastImplementer {
      if let result = parallelResults[index] {
        chain.results.append(result)
      }
    }

    chain.addStatusMessage("Merging implementer branches...", type: .progress)
    let conflicts = try await mergeImplementerBranches(chain: chain, indices: Array(firstImplementer...lastImplementer))
    if !conflicts.isEmpty {
      mergeConflicts = conflicts
      throw NSError(
        domain: "AgentChain",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Merge conflicts detected. Resolve conflicts and re-run the reviewer."]
      )
    }
    chain.addStatusMessage("Merge completed", type: .complete)

    if lastImplementer + 1 < chain.agents.count {
      for index in (lastImplementer + 1)..<chain.agents.count {
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
    guard let workingDirectory = chain.workingDirectory else {
      throw NSError(
        domain: "AgentChain",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Select a working directory to create parallel worktrees."]
      )
    }

    let repoURL = URL(fileURLWithPath: workingDirectory)
    let repository = Model.Repository(name: repoURL.lastPathComponent, path: workingDirectory)

    for index in indices {
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
      agent.workspace = workspace
      agent.workingDirectory = workspace.path.path
    }

    var results: [Int: AgentChainResult] = [:]
    try await withThrowingTaskGroup(of: (Int, AgentChainResult).self) { group in
      for index in indices {
        let agent = chain.agents[index]
        group.addTask {
          let result = try await self.runSingleAgent(
            agent,
            at: index,
            chain: chain,
            prompt: prompt,
            contextOverride: context
          )
          return (index, result)
        }
      }

      for try await (index, result) in group {
        results[index] = result
      }
    }

    return results
  }

  private func mergeImplementerBranches(chain: AgentChain, indices: [Int]) async throws -> [String] {
    guard let workingDirectory = chain.workingDirectory else {
      return []
    }

    let repoURL = URL(fileURLWithPath: workingDirectory)
    let repository = Model.Repository(name: repoURL.lastPathComponent, path: workingDirectory)

    let statusLines = try await Commands.simple(arguments: ["status", "--porcelain"], in: repository)
    if statusLines.contains(where: { !$0.isEmpty }) {
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
    let context = contextOverride ?? chain.contextForAgent(at: index)

    let fullPrompt = agent.buildPrompt(
      userPrompt: prompt,
      context: context.isEmpty ? nil : context
    )

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

    let result = AgentChainResult(
      agentId: agent.id,
      agentName: agent.name,
      model: agent.model.displayName,
      prompt: fullPrompt,
      output: response.content,
      duration: response.duration,
      premiumCost: premiumCost,
      reviewVerdict: verdict
    )
    return result
  }

  private func runReviewLoop(chain: AgentChain, prompt: String) async throws {
    guard let initialReviewerResult = chain.results.last(where: { $0.reviewVerdict != nil }),
          let verdict = initialReviewerResult.reviewVerdict,
          verdict == .needsChanges else {
      return
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

    var errorDescription: String? {
      switch self {
      case .reviewRejected(let reason):
        return "Review rejected: \(reason.prefix(200))..."
      }
    }
  }
}

// MARK: - MCP Server

@MainActor
@Observable
public final class MCPServerService {
  private enum StorageKey {
    static let enabled = "mcp.server.enabled"
    static let port = "mcp.server.port"
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

  public private(set) var isRunning: Bool = false
  public var lastError: String?
  public private(set) var activeRequests: Int = 0
  public private(set) var lastRequestMethod: String?
  public private(set) var lastRequestAt: Date?
  public private(set) var isCleaningAgentWorkspaces: Bool = false
  public private(set) var lastCleanupAt: Date?
  public private(set) var lastCleanupSummary: String?
  public private(set) var lastCleanupError: String?

  public let agentManager: AgentManager
  public let cliService: CLIService
  public let sessionTracker: SessionTracker
  private let chainRunner: AgentChainRunner
  private var dataService: DataService?

  private let listenerQueue = DispatchQueue(label: "MCPServer.Listener")
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]
  private var connectionStates: [UUID: ConnectionState] = [:]

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
    if self.port == 0 {
      self.port = 8765
    }

    if isEnabled {
      start()
    }
  }

  public func configure(modelContext: ModelContext) {
    if dataService == nil {
      dataService = DataService(modelContext: modelContext)
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
    activeRequests += 1
    defer { activeRequests -= 1 }
    do {
      let json = try JSONSerialization.jsonObject(with: body, options: [])
      guard let dict = json as? [String: Any] else {
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
      } else {
        lastRequestMethod = method
      }

      switch method {
      case "initialize":
        let result: [String: Any] = [
          "serverInfo": ["name": "Peel MCP Test Harness", "version": "0.1"],
          "capabilities": ["tools": [:]]
        ]
        return (200, makeRPCResult(id: id, result: result))

      case "tools/list":
        return (200, makeRPCResult(id: id, result: ["tools": toolList()]))

      case "tools/call":
        return await handleToolCall(id: id, params: params)

      default:
        return (400, makeRPCError(id: id, code: -32601, message: "Method not found"))
      }
    } catch {
      return (500, makeRPCError(id: nil, code: -32603, message: error.localizedDescription))
    }
  }

  private func handleToolCall(id: Any?, params: [String: Any]?) async -> (Int, Data) {
    guard let params, let name = params["name"] as? String else {
      return (400, makeRPCError(id: id, code: -32602, message: "Invalid params"))
    }

    let arguments = params["arguments"] as? [String: Any] ?? [:]

    switch name {
    case "templates.list":
      let templates = templateList()
      return (200, makeRPCResult(id: id, result: ["templates": templates]))

    case "chains.run":
      return await handleChainRun(id: id, arguments: arguments)

    default:
      return (400, makeRPCError(id: id, code: -32601, message: "Unknown tool"))
    }
  }

  private func handleChainRun(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let prompt = arguments["prompt"] as? String else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing prompt"))
    }

    let templateId = arguments["templateId"] as? String
    let templateName = arguments["templateName"] as? String
    let workingDirectory = arguments["workingDirectory"] as? String
    let enableReviewLoop = arguments["enableReviewLoop"] as? Bool

    let templates = agentManager.allTemplates
    let template: ChainTemplate? = {
      if let templateId, let uuid = UUID(uuidString: templateId) {
        return templates.first { $0.id == uuid }
      }
      if let templateName {
        return templates.first { $0.name.lowercased() == templateName.lowercased() }
      }
      return templates.first
    }()

    guard let template else {
      return (400, makeRPCError(id: id, code: -32602, message: "Template not found"))
    }

    let chain = agentManager.createChainFromTemplate(template, workingDirectory: workingDirectory)
    chain.runSource = .mcp
    if let enableReviewLoop {
      chain.enableReviewLoop = enableReviewLoop
    }

    let summary = await chainRunner.runChain(chain, prompt: prompt)

    dataService?.recordMCPRun(
      templateId: template.id.uuidString,
      templateName: template.name,
      prompt: prompt,
      workingDirectory: workingDirectory,
      success: summary.errorMessage == nil,
      errorMessage: summary.errorMessage,
      mergeConflictsCount: summary.mergeConflicts.count,
      resultCount: summary.results.count
    )

    let result: [String: Any] = [
      "chain": [
        "id": chain.id.uuidString,
        "name": chain.name,
        "state": summary.stateDescription
      ],
      "success": summary.errorMessage == nil,
      "errorMessage": summary.errorMessage as Any,
      "mergeConflicts": summary.mergeConflicts,
      "results": summarizeResults(summary.results)
    ]

    return (200, makeRPCResult(id: id, result: result))
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
        workspace.path.path.contains("/\(WorkspaceManager.workspacesDirName)/")
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
      lastCleanupError = errors.prefix(3).joined(separator: "\n")
    }

    lastCleanupSummary = "Removed \(removedWorktrees) worktrees, deleted \(deletedBranches) branches."
  }

  private func toolList() -> [[String: Any]] {
    return [
      [
        "name": "templates.list",
        "description": "List available chain templates",
        "inputSchema": [
          "type": "object",
          "properties": [:]
        ]
      ],
      [
        "name": "chains.run",
        "description": "Run a chain template with a prompt",
        "inputSchema": [
          "type": "object",
          "properties": [
            "templateId": ["type": "string"],
            "templateName": ["type": "string"],
            "prompt": ["type": "string"],
            "workingDirectory": ["type": "string"],
            "enableReviewLoop": ["type": "boolean"]
          ],
          "required": ["prompt"]
        ]
      ]
    ]
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
      return item
    }
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
}

#else
// iOS stub
@MainActor
@Observable
public final class AgentManager {
  public private(set) var agents: [Agent] = []
  public let workspaceManager = WorkspaceManager()
  public var selectedAgent: Agent?
  public init() {}
}
#endif
