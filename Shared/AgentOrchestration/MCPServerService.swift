//
//  MCPServerService.swift
//  KitchenSync
//
//  Extracted from AgentManager.swift on 1/24/26.
//

import AppKit
import Foundation
import Git
import IOKit.pwr_mgt
import MCPCore
import Network
import Observation
import OSLog
import SwiftData
import TaskRunner

// MARK: - MCP Server

@MainActor
@Observable
public final class MCPServerService {
  private let telemetryProvider: MCPTelemetryProviding
  private enum StorageKey {
    static let enabled = "mcp.server.enabled"
    static let port = "mcp.server.port"
    static let maxConcurrentChains = "mcp.server.maxConcurrentChains"
    static let maxQueuedChains = "mcp.server.maxQueuedChains"
    static let autoCleanupWorkspaces = "mcp.server.autoCleanupWorkspaces"
    static let sleepPreventionEnabled = "mcp.server.sleepPreventionEnabled"
    static let localRagRepoPath = "localrag.repoPath"
    static let localRagQuery = "localrag.query"
    static let localRagSearchMode = "localrag.searchMode"
    static let localRagSearchLimit = "localrag.searchLimit"
    static let localRagUseCoreML = "localrag.useCoreML"
  }

  // Tool types from MCPCore
  public typealias ToolCategory = MCPToolCategory
  public typealias ToolGroup = MCPToolGroup
  public typealias ToolDefinition = MCPToolDefinition

  public enum RAGSearchMode: String, CaseIterable {
    case text
    case vector
  }

  public enum RAGUserAction: String, CaseIterable {
    case copyPath
    case copySnippet
    case openFile
    case markHelpful
    case markIrrelevant
  }

  public struct RAGUsageStats {
    public var searches: Int = 0
    public var textSearches: Int = 0
    public var vectorSearches: Int = 0
    public var emptySearches: Int = 0
    public var totalResults: Int = 0
    public var copyCount: Int = 0
    public var openCount: Int = 0
    public var helpfulCount: Int = 0
    public var irrelevantCount: Int = 0
    public var indexRuns: Int = 0
    public var skillsAdded: Int = 0
    public var skillsUpdated: Int = 0
    public var skillsDeleted: Int = 0
    public var lastSearchAt: Date?
    public var lastIndexAt: Date?
    public var lastCopyAt: Date?
    public var lastOpenAt: Date?
    public var lastHelpfulAt: Date?
    public var lastIrrelevantAt: Date?
    public var lastSkillChangeAt: Date?

    public init() {}
  }

  public struct RAGSessionEvent: Identifiable {
    public enum Kind: String, CaseIterable {
      case search
      case index
      case copy
      case open
      case helpful
      case irrelevant
      case skillAdded
      case skillUpdated
      case skillDeleted
    }

    public let id: UUID
    public let timestamp: Date
    public let title: String
    public let detail: String?
    public let kind: Kind

    public init(timestamp: Date, title: String, detail: String? = nil, kind: Kind) {
      self.id = UUID()
      self.timestamp = timestamp
      self.title = title
      self.detail = detail
      self.kind = kind
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
  
  public var sleepPreventionEnabled: Bool {
    didSet {
      UserDefaults.standard.set(sleepPreventionEnabled, forKey: StorageKey.sleepPreventionEnabled)
      updateSleepPrevention()
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
  public var lastUIActionHandled: String? { uiAutomationProvider.lastUIActionHandled }
  public var lastUIActionHandledAt: Date? { uiAutomationProvider.lastUIActionHandledAt }
  public var recentUIActions: [UIActionRecord] { uiAutomationProvider.recentUIActions }
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
  public var lastUIAction: UIAction? {
    get { uiAutomationProvider.lastUIAction }
    set { uiAutomationProvider.lastUIAction = newValue }
  }
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
  private(set) var ragUsage = RAGUsageStats()
  private(set) var ragSessionEvents: [RAGSessionEvent] = []
  private(set) var lastRagIndexReport: LocalRAGIndexReport?
  private(set) var lastRagIndexAt: Date?
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
  private let uiAutomationProvider: MCPUIAutomationProviding
  private var dataService: DataService?
  private let screenshotService = ScreenshotService()
  let translationValidatorService = TranslationValidatorService()
  let piiScrubberService = PIIScrubberService()
  private let vmIsolationService: VMIsolationService
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
    public let requireRagUsage: Bool
    public let ragSearchAtStart: Date?
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
  private var sleepPreventionAssertionId: IOPMAssertionID?
  private let permissionsStore: MCPToolPermissionsProviding
  public private(set) var permissionsVersion: Int = 0

  private struct ConnectionState {
    var buffer = Data()
  }

  public init(
    agentManager: AgentManager = AgentManager(),
    cliService: CLIService? = nil,
    sessionTracker: SessionTracker = SessionTracker(),
    telemetryProvider: MCPTelemetryProviding? = nil,
    uiAutomationProvider: MCPUIAutomationProviding = MCPUIAutomationStore(),
    permissionsStore: MCPToolPermissionsProviding = MCPToolPermissionsStore(),
    vmIsolationService: VMIsolationService = VMIsolationService()
  ) {
    self.agentManager = agentManager
    self.sessionTracker = sessionTracker
    let resolvedTelemetry = telemetryProvider ?? MCPTelemetryAdapter(sessionTracker: sessionTracker)
    self.telemetryProvider = resolvedTelemetry
    let resolvedCLIService = cliService ?? CLIService(telemetryProvider: resolvedTelemetry)
    self.cliService = resolvedCLIService
    self.uiAutomationProvider = uiAutomationProvider
    self.permissionsStore = permissionsStore
    self.vmIsolationService = vmIsolationService
    self.chainRunner = AgentChainRunner(
      agentManager: agentManager,
      cliService: resolvedCLIService,
      telemetryProvider: resolvedTelemetry
    )
    self.isEnabled = UserDefaults.standard.bool(forKey: StorageKey.enabled)
    self.port = UserDefaults.standard.integer(forKey: StorageKey.port)
    self.maxConcurrentChains = UserDefaults.standard.integer(forKey: StorageKey.maxConcurrentChains)
    self.maxQueuedChains = UserDefaults.standard.integer(forKey: StorageKey.maxQueuedChains)
    self.autoCleanupWorkspaces = UserDefaults.standard.bool(forKey: StorageKey.autoCleanupWorkspaces)
    self.sleepPreventionEnabled = UserDefaults.standard.bool(forKey: StorageKey.sleepPreventionEnabled)
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
    if let store = permissionsStore as? MCPToolPermissionsStore {
      store.onChange = { [weak self] in
        self?.permissionsVersion &+= 1
      }
    }

    // Initialize parallel worktree runner
    self.parallelWorktreeRunner = ParallelWorktreeRunner(
      workspaceService: agentManager.workspaceManager,
      agentManager: agentManager,
      chainRunner: chainRunner
    )
    self.parallelWorktreeRunner?.setRAGStore(localRagStore)

    updateSleepPrevention()

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
    uiAutomationProvider.uiControlDocs
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
    updateToolsEnabled(tools(in: category), enabled: enabled)
  }

  public func setGroupEnabled(_ group: ToolGroup, enabled: Bool) {
    updateToolsEnabled(tools(in: group), enabled: enabled)
  }

  public func setAllToolsEnabled(_ enabled: Bool) {
    updateToolsEnabled(toolDefinitions, enabled: enabled)
  }

  public func isToolEnabled(_ name: String) -> Bool {
    guard toolDefinition(named: name) != nil else { return false }
    if name.hasPrefix("ui.") {
      return true
    }
    if UserDefaults.standard.bool(forKey: "mcp.server.allowAllTools") {
      return true
    }
    return permissionsStore.isToolEnabled(name)
  }

  public func setToolEnabled(_ name: String, enabled: Bool) {
    guard toolDefinition(named: name) != nil else { return }
    permissionsStore.setToolEnabled(name, enabled: enabled)
    permissionsVersion &+= 1
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
    if let dataService {
      parallelWorktreeRunner?.setDataService(dataService)
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

  func listRepoGuidanceSkills(
    repoPath: String? = nil,
    includeInactive: Bool = false,
    limit: Int? = nil
  ) -> [RepoGuidanceSkill] {
    dataService?.listRepoGuidanceSkills(repoPath: repoPath, includeInactive: includeInactive, limit: limit) ?? []
  }

  @discardableResult
  func addRepoGuidanceSkill(
    repoPath: String,
    title: String,
    body: String,
    source: String = "manual",
    tags: String = "",
    priority: Int = 0,
    isActive: Bool = true
  ) -> RepoGuidanceSkill? {
    let created = dataService?.addRepoGuidanceSkill(
      repoPath: repoPath,
      title: title,
      body: body,
      source: source,
      tags: tags,
      priority: priority,
      isActive: isActive
    )
    if created != nil {
      ragUsage.skillsAdded += 1
      ragUsage.lastSkillChangeAt = Date()
      appendRagEvent(
        kind: .skillAdded,
        title: "Skill added",
        detail: title.isEmpty ? repoPath : title
      )
    }
    return created
  }

  @discardableResult
  func updateRepoGuidanceSkill(
    id: UUID,
    repoPath: String? = nil,
    title: String? = nil,
    body: String? = nil,
    source: String? = nil,
    tags: String? = nil,
    priority: Int? = nil,
    isActive: Bool? = nil
  ) -> RepoGuidanceSkill? {
    let updated = dataService?.updateRepoGuidanceSkill(
      id: id,
      repoPath: repoPath,
      title: title,
      body: body,
      source: source,
      tags: tags,
      priority: priority,
      isActive: isActive
    )
    if let updated {
      ragUsage.skillsUpdated += 1
      ragUsage.lastSkillChangeAt = Date()
      appendRagEvent(
        kind: .skillUpdated,
        title: "Skill updated",
        detail: updated.title.isEmpty ? updated.repoPath : updated.title
      )
    }
    return updated
  }

  @discardableResult
  public func deleteRepoGuidanceSkill(id: UUID) -> Bool {
    let deleted = dataService?.deleteRepoGuidanceSkill(id: id) ?? false
    if deleted {
      ragUsage.skillsDeleted += 1
      ragUsage.lastSkillChangeAt = Date()
      appendRagEvent(
        kind: .skillDeleted,
        title: "Skill deleted",
        detail: nil
      )
    }
    return deleted
  }

  func clearMCPRunHistory() {
    dataService?.clearMCPRunHistory()
    sessionTracker.resetSession()
  }

  private func buildRepoGuidance(repoPath: String) async -> String? {
    var sections: [String] = []
    if let dataService,
       let (skillsBlock, skills) = dataService.repoGuidanceSkillsBlock(repoPath: repoPath) {
      sections.append(skillsBlock)
      dataService.markRepoGuidanceSkillsApplied(skills)
    }

    let queries = [
      ".rubocop.yml",
      "rubocop",
      ".eslintrc",
      "eslint",
      "ruff",
      "flake8",
      "pyproject.toml lint",
      "swiftlint",
      "prettier",
      "style guide",
      "lint"
    ]
    var snippets: [LocalRAGSearchResult] = []
    for query in queries {
      do {
        let results = try await localRagStore.search(query: query, repoPath: repoPath, limit: 2)
        snippets.append(contentsOf: results)
      } catch {
        await telemetryProvider.warning("Repo guidance search failed", metadata: [
          "query": query,
          "error": error.localizedDescription
        ])
      }
    }

    let unique = Dictionary(grouping: snippets, by: { $0.filePath })
      .compactMap { $0.value.first }
      .prefix(4)
    if !unique.isEmpty {
      let guidance = unique.map { result in
        let header = "- Follow repo lint/style rules in \(result.filePath)"
        let snippet = result.snippet
          .split(separator: "\n")
          .prefix(8)
          .joined(separator: "\n")
        return "\(header)\n\n\(snippet)"
      }.joined(separator: "\n\n")
      sections.append("## Repo Guidance\n\n\(guidance)")
    }

    guard !sections.isEmpty else { return nil }
    return sections.joined(separator: "\n\n")
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
    ragUsage.indexRuns += 1
    ragUsage.lastIndexAt = Date()
    lastRagIndexReport = report
    lastRagIndexAt = Date()
    appendRagEvent(
      kind: .index,
      title: "Indexed \(report.filesIndexed) files · \(report.chunksIndexed) chunks",
      detail: report.repoPath
    )
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
    ragUsage.searches += 1
    ragUsage.totalResults += results.count
    if results.isEmpty {
      ragUsage.emptySearches += 1
    }
    switch mode {
    case .text:
      ragUsage.textSearches += 1
    case .vector:
      ragUsage.vectorSearches += 1
    }
    ragUsage.lastSearchAt = Date()
    appendRagEvent(
      kind: .search,
      title: "Search · \(results.count) results",
      detail: query
    )
    lastRagSearchQuery = query
    lastRagSearchMode = mode
    lastRagSearchRepoPath = repoPath
    lastRagSearchLimit = limit
    lastRagSearchAt = Date()
    lastRagSearchResults = results
    lastRagError = nil
    return results
  }

  func recordRagUserAction(_ action: RAGUserAction, result: LocalRAGSearchResult? = nil) {
    let now = Date()
    switch action {
    case .copyPath, .copySnippet:
      ragUsage.copyCount += 1
      ragUsage.lastCopyAt = now
      appendRagEvent(
        kind: .copy,
        title: "Snippet copied",
        detail: result?.filePath
      )
    case .openFile:
      ragUsage.openCount += 1
      ragUsage.lastOpenAt = now
      appendRagEvent(
        kind: .open,
        title: "Opened file",
        detail: result?.filePath
      )
    case .markHelpful:
      ragUsage.helpfulCount += 1
      ragUsage.lastHelpfulAt = now
      appendRagEvent(
        kind: .helpful,
        title: "Marked helpful",
        detail: result?.filePath
      )
    case .markIrrelevant:
      ragUsage.irrelevantCount += 1
      ragUsage.lastIrrelevantAt = now
      appendRagEvent(
        kind: .irrelevant,
        title: "Marked not useful",
        detail: result?.filePath
      )
    }
  }

  private func appendRagEvent(kind: RAGSessionEvent.Kind, title: String, detail: String?) {
    let event = RAGSessionEvent(timestamp: Date(), title: title, detail: detail, kind: kind)
    ragSessionEvents.insert(event, at: 0)
    if ragSessionEvents.count > 50 {
      ragSessionEvents.removeLast(ragSessionEvents.count - 50)
    }
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
      await telemetryProvider.warning("Local RAG context build failed", metadata: ["error": error.localizedDescription])
      return nil
    }
  }

  public struct RunOverrides {
    public var enableReviewLoop: Bool? = nil
    public var pauseOnReview: Bool? = nil
    public var allowPlannerModelSelection: Bool = false
    public var allowImplementerModelOverride: Bool = false
    public var allowPlannerImplementerScaling: Bool = false
    public var maxImplementers: Int? = nil
    public var maxPremiumCost: Double? = nil
    public var priority: Int = 0
    public var timeoutSeconds: Double? = nil
    public var requireRagUsage: Bool? = nil

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
    arguments["allowImplementerModelOverride"] = overrides.allowImplementerModelOverride
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
    if let requireRagUsage = overrides.requireRagUsage {
      arguments["requireRagUsage"] = requireRagUsage
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
      Task { await telemetryProvider.info("RPC complete", metadata: [
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
        await telemetryProvider.warning("Invalid RPC request: non-object JSON", metadata: [:])
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
        await telemetryProvider.warning("RPC method not found", metadata: ["method": method])
        statusCode = 400
        return (400, makeRPCError(id: id, code: -32601, message: "Method not found"))
      }
    } catch {
      await telemetryProvider.error(error, context: "RPC handling failed", metadata: [:])
      statusCode = 500
      return (500, makeRPCError(id: nil, code: -32603, message: error.localizedDescription))
    }
  }

  private func handleToolCall(id: Any?, params: [String: Any]?) async -> (Int, Data) {
    guard let params, let name = params["name"] as? String else {
      await telemetryProvider.warning("Invalid tool call params", metadata: [:])
      return (400, makeRPCError(id: id, code: -32602, message: "Invalid params"))
    }

    guard let tool = toolDefinition(named: name) else {
      await telemetryProvider.warning("Unknown tool", metadata: ["name": name])
      return (400, makeRPCError(id: id, code: -32601, message: "Unknown tool"))
    }

    lastToolRequiresForeground = tool.requiresForeground
    lastToolRequiresForegroundAt = Date()

    if tool.requiresForeground && !NSApp.isActive {
      await telemetryProvider.warning("Foreground tool called while app inactive", metadata: ["name": tool.name])
      recordUIActionForegroundNeeded(tool.name)
    }

    if !isToolEnabled(name) {
      await telemetryProvider.warning("Tool disabled", metadata: ["name": name, "category": tool.category.rawValue])
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

    case "rag.skills.list":
      return handleRagSkillsList(id: id, arguments: arguments)

    case "rag.skills.add":
      return handleRagSkillsAdd(id: id, arguments: arguments)

    case "rag.skills.update":
      return handleRagSkillsUpdate(id: id, arguments: arguments)

    case "rag.skills.delete":
      return handleRagSkillsDelete(id: id, arguments: arguments)

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

    case "chains.instruct":
      return await handleChainInstruct(id: id, arguments: arguments)

    case "chains.step":
      return await handleChainStep(id: id, arguments: arguments)

    case "chains.queue.status":
      return (200, makeRPCResult(id: id, result: queueStatus()))

    case "chains.queue.configure":
      return handleQueueConfigure(id: id, arguments: arguments)

    case "chains.queue.cancel":
      return await handleQueueCancel(id: id, arguments: arguments)

    case "logs.mcp.path":
      return (200, makeRPCResult(id: id, result: ["path": await telemetryProvider.logPath()]))

    case "logs.mcp.tail":
      let lines = arguments["lines"] as? Int ?? 200
      let text = await telemetryProvider.tail(lines: lines)
      return (200, makeRPCResult(id: id, result: ["text": text]))

    case "vm.macos.status":
      return await handleMacOSVMStatus(id: id)

    case "vm.macos.restore.download":
      return await handleMacOSVMRestoreDownload(id: id)

    case "vm.macos.install":
      return await handleMacOSVMInstall(id: id)

    case "vm.macos.start":
      return await handleMacOSVMStart(id: id)

    case "vm.macos.stop":
      return await handleMacOSVMStop(id: id)

    case "vm.macos.reset":
      return await handleMacOSVMReset(id: id, arguments: arguments)

    case "server.restart":
      return await handleServerRestart(id: id)

    case "server.port.set":
      return await handleServerPortSet(id: id, arguments: arguments)

    case "server.status":
      return handleServerStatus(id: id)

    case "server.sleep.prevent":
      return handleServerSleepPreventionSet(id: id, arguments: arguments)

    case "server.sleep.prevent.status":
      return handleServerSleepPreventionStatus(id: id)

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
      let requestedOutputDir = arguments["outputDir"] as? String
      let outputDir: String?
    #if DEBUG
      if let requestedOutputDir, !requestedOutputDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        outputDir = requestedOutputDir
      } else {
        outputDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("KitchenSync/Screenshots")
      }
    #else
      outputDir = requestedOutputDir
    #endif
      do {
        let url = try await screenshotService.capture(label: label, outputDir: outputDir)
        return (200, makeRPCResult(id: id, result: ["path": url.path]))
      } catch {
        await telemetryProvider.warning("Screenshot tool failed", metadata: ["error": error.localizedDescription])
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

    case "parallel.reviewed":
      return handleParallelReviewed(id: id, arguments: arguments)

    case "parallel.merge":
      return await handleParallelMerge(id: id, arguments: arguments)

    case "parallel.pause":
      return await handleParallelPause(id: id, arguments: arguments)

    case "parallel.resume":
      return await handleParallelResume(id: id, arguments: arguments)

    case "parallel.instruct":
      return handleParallelInstruct(id: id, arguments: arguments)

    case "parallel.cancel":
      return await handleParallelCancel(id: id, arguments: arguments)

    default:
      await telemetryProvider.warning("Unknown tool", metadata: ["name": name])
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
    case "git.selectSidebarItem":
      UserDefaults.standard.set(value, forKey: "git.selectedSidebarItem")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "git.selectStatusPath":
      UserDefaults.standard.set(value, forKey: "git.selectedStatusPath")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "git.selectBranch":
      UserDefaults.standard.set(value, forKey: "git.selectedBranchName")
      recordUIActionRequested(controlId)
      recordUIActionHandled(controlId)
      return (200, makeRPCResult(id: id, result: ["controlId": controlId, "value": value]))
    case "git.selectCommit":
      UserDefaults.standard.set(value, forKey: "git.selectedCommitSha")
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
      await telemetryProvider.warning("Translation validation failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  // MARK: - VM Isolation Handlers

  private func handleMacOSVMStatus(id: Any?) async -> (Int, Data) {
    await vmIsolationService.initialize()

    let status: [String: Any] = [
      "virtualizationAvailable": vmIsolationService.isVirtualizationAvailable,
      "macOSReady": vmIsolationService.isMacOSReady,
      "macOSRestoreImagePath": vmIsolationService.macOSRestoreImagePath?.path as Any,
      "macOSInstalled": vmIsolationService.isMacOSVMInstalled,
      "macOSRunning": vmIsolationService.isMacOSVMRunning,
      "statusMessage": vmIsolationService.statusMessage
    ]
    return (200, makeRPCResult(id: id, result: status))
  }

  private func handleMacOSVMRestoreDownload(id: Any?) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.downloadMacOSRestoreImage()
      return await handleMacOSVMStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS restore download failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleMacOSVMInstall(id: Any?) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.installMacOSVM()
      return await handleMacOSVMStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS VM install failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleMacOSVMStart(id: Any?) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.startMacOSVM()
      return await handleMacOSVMStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS VM start failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleMacOSVMStop(id: Any?) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.stopMacOSVM()
      return await handleMacOSVMStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS VM stop failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleMacOSVMReset(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let deleteRestoreImage = arguments["deleteRestoreImage"] as? Bool ?? false
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.resetMacOSVM(deleteRestoreImage: deleteRestoreImage)
      return await handleMacOSVMStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS VM reset failed", metadata: ["error": error.localizedDescription])
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
      await telemetryProvider.warning("PII scrubber failed", metadata: ["error": error.localizedDescription])
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
    let templateName = (arguments["templateName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowPlannerModelSelection = arguments["allowPlannerModelSelection"] as? Bool
    let allowImplementerModelOverride = arguments["allowImplementerModelOverride"] as? Bool
    let allowPlannerImplementerScaling = arguments["allowPlannerImplementerScaling"] as? Bool
    let maxImplementers = arguments["maxImplementers"] as? Int
    let maxPremiumCost = arguments["maxPremiumCost"] as? Double

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

    let hasRunOptions = allowPlannerModelSelection != nil
      || allowImplementerModelOverride != nil
      || allowPlannerImplementerScaling != nil
      || maxImplementers != nil
      || maxPremiumCost != nil
    let runOptions = hasRunOptions
      ? AgentChainRunner.ChainRunOptions(
        allowPlannerModelSelection: allowPlannerModelSelection ?? false,
        allowImplementerModelOverride: allowImplementerModelOverride ?? false,
        allowPlannerImplementerScaling: allowPlannerImplementerScaling ?? false,
        maxImplementers: maxImplementers,
        maxPremiumCost: maxPremiumCost
      )
      : nil

    let run = runner.createRun(
      name: name,
      projectPath: projectPath,
      tasks: tasks,
      baseBranch: baseBranch,
      targetBranch: targetBranch,
      requireReviewGate: requireReviewGate,
      autoMergeOnApproval: autoMergeOnApproval,
      templateName: templateName,
      runOptions: runOptions
    )

    await telemetryProvider.info("Parallel run created", metadata: [
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
      await telemetryProvider.warning("Parallel run not found", metadata: [
        "runId": runIdString,
        "knownRunCount": "\(runner.runs.count)"
      ])
      let knownRuns = runner.runs.map { encodeParallelRun($0) }
      return (404, makeRPCError(
        id: id,
        code: -32004,
        message: "Run not found",
        data: [
          "runId": runIdString,
          "knownRunCount": runner.runs.count,
          "knownRuns": knownRuns,
          "hint": "Run not found. The app may have restarted or the run was removed. Use parallel.list to refresh."
        ]
      ))
    }

    await telemetryProvider.info("Starting parallel run", metadata: ["runId": runId.uuidString])

    // Start the run in a task so we don't block
    Task {
      do {
        try await runner.startRun(run)
        await telemetryProvider.info("Parallel run completed", metadata: [
          "runId": runId.uuidString,
          "status": run.status.displayName
        ])
      } catch {
        await telemetryProvider.error(error, context: "Parallel run failed", metadata: [:])
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
      Task { await telemetryProvider.warning("Parallel run not found", metadata: [
        "runId": runIdString,
        "knownRunCount": "\(runner.runs.count)"
      ]) }
      let knownRuns = runner.runs.map { encodeParallelRun($0) }
      return (404, makeRPCError(
        id: id,
        code: -32004,
        message: "Run not found",
        data: [
          "runId": runIdString,
          "knownRunCount": runner.runs.count,
          "knownRuns": knownRuns,
          "hint": "Run not found. The app may have restarted or the run was removed. Use parallel.list to refresh."
        ]
      ))
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
      let snapshot = dataService?.getLatestParallelRunSnapshot(runId: runIdString)
      let snapshotPayload: [String: Any]? = snapshot.map { record in
        [
          "runId": record.runId,
          "name": record.name,
          "projectPath": record.projectPath,
          "baseBranch": record.baseBranch,
          "targetBranch": record.targetBranch as Any,
          "templateName": record.templateName as Any,
          "status": record.status,
          "progress": record.progress,
          "executionCount": record.executionCount,
          "pendingReviewCount": record.pendingReviewCount,
          "readyToMergeCount": record.readyToMergeCount,
          "mergedCount": record.mergedCount,
          "rejectedCount": record.rejectedCount,
          "failedCount": record.failedCount,
          "hungCount": record.hungCount,
          "requireReviewGate": record.requireReviewGate,
          "autoMergeOnApproval": record.autoMergeOnApproval,
          "guidanceCount": record.operatorGuidanceCount,
          "createdAt": record.createdAt.iso8601,
          "updatedAt": record.updatedAt.iso8601,
          "lastUpdatedAt": record.lastUpdatedAt?.iso8601 as Any,
          "executions": record.executionsJSON
        ]
      }
      return (404, makeRPCError(
        id: id,
        code: -32004,
        message: "Run not found",
        data: [
          "runId": runIdString,
          "snapshot": snapshotPayload as Any,
          "hint": "Run not found. The app may have restarted or the run was removed. Use parallel.list to refresh."
        ]
      ))
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
    runner.rejectExecution(execution, in: run, reason: reason)

    return (200, makeRPCResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "status": execution.status.displayName
    ]))
  }

  private func handleParallelReviewed(id: Any?, arguments: [String: Any]) -> (Int, Data) {
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

    let reviewAll = arguments["reviewAll"] as? Bool ?? false

    if reviewAll {
      runner.markAllReviewed(in: run)
      return (200, makeRPCResult(id: id, result: [
        "runId": runId.uuidString,
        "reviewed": "all",
        "pendingReviewCount": run.pendingReviewCount
      ]))
    }

    guard let executionIdString = arguments["executionId"] as? String,
          let executionId = UUID(uuidString: executionIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing executionId (or set reviewAll=true)"))
    }

    guard let execution = run.executions.first(where: { $0.id == executionId }) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Execution not found"))
    }

    runner.markReviewed(execution, in: run)
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
      await telemetryProvider.warning("Parallel merge failed", metadata: ["error": error.localizedDescription])
      return (500, makeRPCError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleParallelPause(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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

    await runner.pauseRun(run)
    await telemetryProvider.info("Parallel run paused", metadata: ["runId": runId.uuidString])
    return (200, makeRPCResult(id: id, result: ["runId": runId.uuidString, "paused": true]))
  }

  private func handleParallelResume(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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

    await runner.resumeRun(run)
    await telemetryProvider.info("Parallel run resumed", metadata: ["runId": runId.uuidString])
    return (200, makeRPCResult(id: id, result: ["runId": runId.uuidString, "paused": false]))
  }

  private func handleParallelInstruct(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = parallelWorktreeRunner else {
      return (500, makeRPCError(id: id, code: -32001, message: "Parallel worktree runner not initialized"))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let guidance = arguments["guidance"] as? String else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing guidance"))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
    }

    var executionId: UUID?
    if let executionIdString = arguments["executionId"] as? String {
      executionId = UUID(uuidString: executionIdString)
    }

    runner.addGuidance(guidance, to: run, executionId: executionId)
    return (200, makeRPCResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId?.uuidString as Any,
      "guidanceCount": run.operatorGuidance.count
    ]))
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

    await telemetryProvider.info("Parallel run cancelled", metadata: ["runId": runId.uuidString])

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
      "rejectedCount": run.rejectedCount,
      "failedCount": run.failedCount,
      "hungCount": run.hungExecutionCount,
      "isPaused": run.isPaused,
      "guidanceCount": run.operatorGuidance.count,
      "requireReviewGate": run.requireReviewGate,
      "autoMergeOnApproval": run.autoMergeOnApproval,
      "createdAt": formatter.string(from: run.createdAt)
    ]

    if let targetBranch = run.targetBranch {
      result["targetBranch"] = targetBranch
    }
    if let templateName = run.templateName {
      result["templateName"] = templateName
    }
    if let runOptions = run.runOptions {
      result["allowPlannerModelSelection"] = runOptions.allowPlannerModelSelection
      result["allowImplementerModelOverride"] = runOptions.allowImplementerModelOverride
      result["allowPlannerImplementerScaling"] = runOptions.allowPlannerImplementerScaling
      if let maxImplementers = runOptions.maxImplementers {
        result["maxImplementers"] = maxImplementers
      }
      if let maxPremiumCost = runOptions.maxPremiumCost {
        result["maxPremiumCost"] = maxPremiumCost
      }
    }
    if let startedAt = run.startedAt {
      result["startedAt"] = formatter.string(from: startedAt)
    }
    if let completedAt = run.completedAt {
      result["completedAt"] = formatter.string(from: completedAt)
    }
    if let lastUpdatedAt = run.lastUpdatedAt {
      result["lastUpdatedAt"] = formatter.string(from: lastUpdatedAt)
    }

    if case .failed(let reason) = run.status {
      result["failureReason"] = reason
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
      "mergeConflictCount": execution.mergeConflicts.count,
      "guidanceCount": execution.operatorGuidance.count
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
    if !execution.output.isEmpty {
      result["output"] = execution.output
    }
    if let diffSummary = execution.diffSummary, !diffSummary.isEmpty {
      result["diffSummary"] = diffSummary
    }
    switch execution.status {
    case .failed(let reason):
      result["failureReason"] = reason
    case .rejected(let reason):
      result["rejectionReason"] = reason
    default:
      break
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
      "embeddingProvider": status.providerName,
      "coreMLModelPresent": status.coreMLModelPresent,
      "coreMLVocabPresent": status.coreMLVocabPresent,
      "coreMLTokenizerHelperPresent": status.coreMLTokenizerHelperPresent
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
      await telemetryProvider.warning("Local RAG init failed", metadata: ["error": error.localizedDescription])
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
      await telemetryProvider.warning("Local RAG index failed", metadata: ["error": error.localizedDescription])
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
      await telemetryProvider.warning("Local RAG search failed", metadata: ["error": error.localizedDescription])
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
      await telemetryProvider.warning("Local RAG model describe failed", metadata: ["error": error.localizedDescription])
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

    if let dataService {
      let repoFilter = localRagRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
      let skills = dataService.listRepoGuidanceSkills(
        repoPath: repoFilter.isEmpty ? nil : repoFilter,
        includeInactive: true,
        limit: 20
      )
      let activeCount = skills.filter { $0.isActive }.count
      let inactiveCount = skills.count - activeCount
      let skillsPayload = skills.prefix(10).map { encodeRepoGuidanceSkill($0, formatter: formatter) }
      payload["skills"] = [
        "repoPath": repoFilter.isEmpty ? nil : repoFilter as Any,
        "activeCount": activeCount,
        "inactiveCount": inactiveCount,
        "skills": skillsPayload
      ]
    }

    if let error = lastRagError {
      payload["error"] = error
    }
    if let refreshedAt = lastRagRefreshAt {
      payload["refreshedAt"] = formatter.string(from: refreshedAt)
    }

    return (200, makeRPCResult(id: id, result: payload))
  }

  private func encodeRepoGuidanceSkill(_ skill: RepoGuidanceSkill, formatter: ISO8601DateFormatter) -> [String: Any] {
    var payload: [String: Any] = [
      "id": skill.id.uuidString,
      "repoPath": skill.repoPath,
      "title": skill.title,
      "body": skill.body,
      "source": skill.source,
      "tags": skill.tags,
      "priority": skill.priority,
      "isActive": skill.isActive,
      "appliedCount": skill.appliedCount,
      "createdAt": formatter.string(from: skill.createdAt),
      "updatedAt": formatter.string(from: skill.updatedAt)
    ]
    if let lastAppliedAt = skill.lastAppliedAt {
      payload["lastAppliedAt"] = formatter.string(from: lastAppliedAt)
    }
    return payload
  }

  private func handleRagSkillsList(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let dataService else {
      return (500, makeRPCError(id: id, code: -32001, message: "Data service not initialized"))
    }
    let repoPath = (arguments["repoPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let includeInactive = arguments["includeInactive"] as? Bool ?? false
    let limit = arguments["limit"] as? Int
    let formatter = ISO8601DateFormatter()
    let skills = dataService.listRepoGuidanceSkills(
      repoPath: repoPath?.isEmpty == false ? repoPath : nil,
      includeInactive: includeInactive,
      limit: limit
    )
    let payload = skills.map { encodeRepoGuidanceSkill($0, formatter: formatter) }
    return (200, makeRPCResult(id: id, result: ["skills": payload]))
  }

  private func handleRagSkillsAdd(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let dataService else {
      return (500, makeRPCError(id: id, code: -32001, message: "Data service not initialized"))
    }
    guard let repoPath = arguments["repoPath"] as? String,
          let title = arguments["title"] as? String,
          let body = arguments["body"] as? String else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing repoPath, title, or body"))
    }
    let source = arguments["source"] as? String ?? "manual"
    let tags = arguments["tags"] as? String ?? ""
    let priority = arguments["priority"] as? Int ?? 0
    let isActive = arguments["isActive"] as? Bool ?? true
    let skill = dataService.addRepoGuidanceSkill(
      repoPath: repoPath,
      title: title,
      body: body,
      source: source,
      tags: tags,
      priority: priority,
      isActive: isActive
    )
    let formatter = ISO8601DateFormatter()
    return (200, makeRPCResult(id: id, result: ["skill": encodeRepoGuidanceSkill(skill, formatter: formatter)]))
  }

  private func handleRagSkillsUpdate(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let dataService else {
      return (500, makeRPCError(id: id, code: -32001, message: "Data service not initialized"))
    }
    guard let skillIdString = arguments["skillId"] as? String,
          let skillId = UUID(uuidString: skillIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid skillId"))
    }
    let skill = dataService.updateRepoGuidanceSkill(
      id: skillId,
      repoPath: arguments["repoPath"] as? String,
      title: arguments["title"] as? String,
      body: arguments["body"] as? String,
      source: arguments["source"] as? String,
      tags: arguments["tags"] as? String,
      priority: arguments["priority"] as? Int,
      isActive: arguments["isActive"] as? Bool
    )
    guard let skill else {
      return (404, makeRPCError(id: id, code: -32004, message: "Skill not found"))
    }
    let formatter = ISO8601DateFormatter()
    return (200, makeRPCResult(id: id, result: ["skill": encodeRepoGuidanceSkill(skill, formatter: formatter)]))
  }

  private func handleRagSkillsDelete(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let dataService else {
      return (500, makeRPCError(id: id, code: -32001, message: "Data service not initialized"))
    }
    guard let skillIdString = arguments["skillId"] as? String,
          let skillId = UUID(uuidString: skillIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid skillId"))
    }
    let deleted = dataService.deleteRepoGuidanceSkill(id: skillId)
    if !deleted {
      return (404, makeRPCError(id: id, code: -32004, message: "Skill not found"))
    }
    return (200, makeRPCResult(id: id, result: ["deleted": skillId.uuidString]))
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
        "timeoutSeconds": runInfo.timeoutSeconds as Any,
        "requireRagUsage": runInfo.requireRagUsage
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
      await telemetryProvider.warning("chains.run missing prompt", metadata: [:])
      return (400, makeRPCError(id: id, code: -32602, message: "Missing prompt"))
    }

    let runId = UUID()
    if activeChainRuns >= maxConcurrentChains, chainQueue.count >= maxQueuedChains {
      await telemetryProvider.warning("Chain queue full", metadata: ["runId": runId.uuidString])
      return (429, makeRPCError(id: id, code: -32000, message: "Chain queue is full"))
    }

    let templateId = arguments["templateId"] as? String
    let templateName = arguments["templateName"] as? String
    let chainSpec = arguments["chainSpec"] as? [String: Any]
    let workingDirectory = arguments["workingDirectory"] as? String
    let enableReviewLoop = arguments["enableReviewLoop"] as? Bool
    let pauseOnReview = arguments["pauseOnReview"] as? Bool
    let allowPlannerModelSelection = arguments["allowPlannerModelSelection"] as? Bool ?? false
    let allowImplementerModelOverride = arguments["allowImplementerModelOverride"] as? Bool ?? false
    let allowPlannerImplementerScaling = arguments["allowPlannerImplementerScaling"] as? Bool ?? false
    let maxImplementers = arguments["maxImplementers"] as? Int
    let maxPremiumCost = arguments["maxPremiumCost"] as? Double
    let priority = arguments["priority"] as? Int ?? 0
    let timeoutSeconds = arguments["timeoutSeconds"] as? Double
    let returnImmediately = arguments["returnImmediately"] as? Bool ?? false
    let keepWorkspace = arguments["keepWorkspace"] as? Bool ?? false
    let requireRagUsage = arguments["requireRagUsage"] as? Bool ?? false

    let (enqueuedAt, wasCancelled, queuePosition) = await acquireChainRunSlot(runId: runId, priority: priority)
    if wasCancelled {
      await telemetryProvider.warning("Queued chain cancelled", metadata: ["runId": runId.uuidString])
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
      await telemetryProvider.warning("Template not found", metadata: ["runId": runId.uuidString])
      let message = chainSpec == nil ? "Template not found" : "Invalid chainSpec"
      return (400, makeRPCError(id: id, code: -32602, message: message))
    }

    var chainWorkspace: AgentWorkspace?
    var chainWorkingDirectory = workingDirectory ?? agentManager.lastUsedWorkingDirectory
    if chainWorkingDirectory == nil {
      await telemetryProvider.warning("chains.run missing workingDirectory", metadata: ["runId": runId.uuidString])
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
        await telemetryProvider.error(error, context: "Failed to create chain workspace", metadata: [:])
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
    if let repoPath = chainWorkingDirectory,
       let guidance = await buildRepoGuidance(repoPath: repoPath) {
      chain.addOperatorGuidance(guidance)
    }
    if requireRagUsage {
      chain.addOperatorGuidance(
        "RAG tool usage is required for this run. Call a rag.* tool (e.g., rag.search) before planning; missing usage will emit a validation warning."
      )
    }

    let runOptions = AgentChainRunner.ChainRunOptions(
      allowPlannerModelSelection: allowPlannerModelSelection,
      allowImplementerModelOverride: allowImplementerModelOverride,
      allowPlannerImplementerScaling: allowPlannerImplementerScaling,
      maxImplementers: maxImplementers,
      maxPremiumCost: maxPremiumCost
    )

    await telemetryProvider.info("Chain run started", metadata: [
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
      timeoutSeconds: timeoutSeconds,
      requireRagUsage: requireRagUsage,
      ragSearchAtStart: lastRagSearchAt
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
        await self.telemetryProvider.warning("Chain timeout exceeded", metadata: [
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
        await self.telemetryProvider.error("Chain run failed", metadata: [
          "runId": runId.uuidString,
          "template": template.name,
          "error": errorMessage
        ])
      } else {
        await self.telemetryProvider.info("Chain run completed", metadata: [
          "runId": runId.uuidString,
          "template": template.name,
          "results": "\(summary.results.count)",
          "mergeConflicts": "\(summary.mergeConflicts.count)"
        ])
      }

      let combinedValidationResult: ValidationResult? = {
        guard let runInfo = self.activeRunsById[runId], runInfo.requireRagUsage else {
          return summary.validationResult
        }

        let lastSearchAt = self.lastRagSearchAt ?? self.ragUsage.lastSearchAt
        let usedDuringRun = lastSearchAt != nil && lastSearchAt! >= runInfo.startedAt
        let baselineIsSame = lastSearchAt == runInfo.ragSearchAtStart

        if usedDuringRun && !baselineIsSame {
          return summary.validationResult
        }

        let reason = "RAG usage required but no rag.search recorded during the run. lastSearchAt=\(lastSearchAt?.description ?? "nil")"
        let warning = ValidationResult.warning(reasons: [reason])
        if let existing = summary.validationResult {
          return ValidationResult.combine([existing, warning])
        }
        return warning
      }()

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
          validationStatus: combinedValidationResult?.status.rawValue,
          validationReasons: combinedValidationResult?.reasons ?? [],
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

      if let validationResult = combinedValidationResult {
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
      await telemetryProvider.warning("chains.runBatch missing runs", metadata: [:])
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
      await telemetryProvider.warning("Chain cancellation requested", metadata: ["runIds": runIds.map { $0.uuidString }.joined(separator: ",")])
      return (200, makeRPCResult(id: id, result: ["cancelled": runIds.map { $0.uuidString }]))
    }

    guard let runIdString, let runId = UUID(uuidString: runIdString) else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let task = activeChainTasks[runId] else {
      return (404, makeRPCError(id: id, code: -32004, message: "Run not found"))
    }

    task.cancel()
    await telemetryProvider.warning("Chain cancellation requested", metadata: ["runId": runId.uuidString])
    return (200, makeRPCResult(id: id, result: ["cancelled": [runId.uuidString]]))
  }

  private func handleChainPause(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    await chainRunner.pause(chainId: chain.id)
    await telemetryProvider.info("Chain paused", metadata: ["runId": runId.uuidString])
    return (200, makeRPCResult(id: id, result: ["paused": runId.uuidString]))
  }

  private func handleChainResume(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    await chainRunner.resume(chainId: chain.id)
    await telemetryProvider.info("Chain resumed", metadata: ["runId": runId.uuidString])
    return (200, makeRPCResult(id: id, result: ["resumed": runId.uuidString]))
  }

  private func handleChainInstruct(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let guidance = arguments["guidance"] as? String else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing guidance"))
    }

    chain.addOperatorGuidance(guidance)
    await telemetryProvider.info("Chain guidance injected", metadata: [
      "runId": runId.uuidString,
      "guidanceLength": "\(guidance.count)"
    ])
    return (200, makeRPCResult(id: id, result: ["runId": runId.uuidString, "guidanceCount": chain.operatorGuidance.count]))
  }

  private func handleChainStep(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    await chainRunner.step(chainId: chain.id)
    await telemetryProvider.info("Chain step", metadata: ["runId": runId.uuidString])
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
      "lastError": lastError as Any,
      "sleepPreventionEnabled": sleepPreventionEnabled,
      "sleepPreventionActive": sleepPreventionAssertionId != nil
    ]
    return (200, makeRPCResult(id: id, result: status))
  }
  
  private func handleServerSleepPreventionSet(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let enabled = arguments["enabled"] as? Bool else {
      return (400, makeRPCError(id: id, code: -32602, message: "Missing enabled flag"))
    }

    sleepPreventionEnabled = enabled
    return (200, makeRPCResult(id: id, result: [
      "enabled": sleepPreventionEnabled,
      "active": sleepPreventionAssertionId != nil
    ]))
  }

  private func handleServerSleepPreventionStatus(id: Any?) -> (Int, Data) {
    return (200, makeRPCResult(id: id, result: [
      "enabled": sleepPreventionEnabled,
      "active": sleepPreventionAssertionId != nil
    ]))
  }

  private func updateSleepPrevention() {
    if sleepPreventionEnabled {
      startSleepPrevention()
    } else {
      stopSleepPrevention()
    }
  }

  private func startSleepPrevention() {
    guard sleepPreventionAssertionId == nil else { return }
    let reason = "Peel MCP server sleep prevention"
    var assertionId: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypeNoIdleSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason as CFString,
      &assertionId
    )
    if result == kIOReturnSuccess {
      sleepPreventionAssertionId = assertionId
    } else {
      Task { @MainActor in
        await telemetryProvider.warning("Failed to enable sleep prevention", metadata: ["code": "\(result)"])
      }
    }
  }

  private func stopSleepPrevention() {
    guard let assertionId = sleepPreventionAssertionId else { return }
    IOPMAssertionRelease(assertionId)
    sleepPreventionAssertionId = nil
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
      await telemetryProvider.warning("Queued chain cancelled", metadata: ["runId": runId.uuidString])
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

  private func defaultToolEnabled(_ tool: ToolDefinition) -> Bool {
    true
  }

  private func updateToolsEnabled(_ tools: [ToolDefinition], enabled: Bool) {
    for tool in tools {
      permissionsStore.setToolEnabled(tool.name, enabled: enabled)
    }
    permissionsVersion &+= 1
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
        name: "rag.skills.list",
        description: "List repo guidance skills",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"],
            "includeInactive": ["type": "boolean"],
            "limit": ["type": "integer"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      ToolDefinition(
        name: "rag.skills.add",
        description: "Add a repo guidance skill",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"],
            "title": ["type": "string"],
            "body": ["type": "string"],
            "source": ["type": "string"],
            "tags": ["type": "string"],
            "priority": ["type": "integer"],
            "isActive": ["type": "boolean"]
          ],
          "required": ["repoPath", "title", "body"]
        ],
        category: .rag,
        isMutating: true
      ),
      ToolDefinition(
        name: "rag.skills.update",
        description: "Update a repo guidance skill",
        inputSchema: [
          "type": "object",
          "properties": [
            "skillId": ["type": "string"],
            "repoPath": ["type": "string"],
            "title": ["type": "string"],
            "body": ["type": "string"],
            "source": ["type": "string"],
            "tags": ["type": "string"],
            "priority": ["type": "integer"],
            "isActive": ["type": "boolean"]
          ],
          "required": ["skillId"]
        ],
        category: .rag,
        isMutating: true
      ),
      ToolDefinition(
        name: "rag.skills.delete",
        description: "Delete a repo guidance skill",
        inputSchema: [
          "type": "object",
          "properties": [
            "skillId": ["type": "string"]
          ],
          "required": ["skillId"]
        ],
        category: .rag,
        isMutating: true
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
            "allowImplementerModelOverride": ["type": "boolean"],
            "allowPlannerImplementerScaling": ["type": "boolean"],
            "maxImplementers": ["type": "integer"],
            "maxPremiumCost": ["type": "number"],
            "priority": ["type": "integer"],
            "timeoutSeconds": ["type": "number"],
            "returnImmediately": ["type": "boolean"],
            "keepWorkspace": ["type": "boolean"],
            "requireRagUsage": ["type": "boolean"]
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
                  "allowImplementerModelOverride": ["type": "boolean"],
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
        name: "chains.instruct",
        description: "Inject operator guidance into a running chain",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "guidance": ["type": "string"]
          ],
          "required": ["runId", "guidance"]
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
        name: "vm.macos.status",
        description: "Get macOS VM readiness and status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: false
      ),
      ToolDefinition(
        name: "vm.macos.restore.download",
        description: "Download the macOS restore image",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      ToolDefinition(
        name: "vm.macos.install",
        description: "Install macOS into the VM disk",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      ToolDefinition(
        name: "vm.macos.start",
        description: "Start the macOS VM",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      ToolDefinition(
        name: "vm.macos.stop",
        description: "Stop the macOS VM",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      ToolDefinition(
        name: "vm.macos.reset",
        description: "Delete the macOS VM bundle and reset install state",
        inputSchema: [
          "type": "object",
          "properties": [
            "deleteRestoreImage": ["type": "boolean"]
          ]
        ],
        category: .vm,
        isMutating: true
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
        name: "server.sleep.prevent",
        description: "Enable or disable system sleep prevention",
        inputSchema: [
          "type": "object",
          "properties": [
            "enabled": ["type": "boolean"]
          ],
          "required": ["enabled"]
        ],
        category: .server,
        isMutating: true
      ),
      ToolDefinition(
        name: "server.sleep.prevent.status",
        description: "Get sleep prevention status",
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
            "label": ["type": "string"],
            "outputDir": ["type": "string"]
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
            "templateName": ["type": "string"],
            "allowPlannerModelSelection": ["type": "boolean"],
            "allowImplementerModelOverride": ["type": "boolean"],
            "allowPlannerImplementerScaling": ["type": "boolean"],
            "maxImplementers": ["type": "integer"],
            "maxPremiumCost": ["type": "number"],
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
        name: "parallel.reviewed",
        description: "Mark an execution as reviewed without approving",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "reviewAll": ["type": "boolean"]
          ],
          "required": ["runId"]
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
        name: "parallel.pause",
        description: "Pause a parallel run (halts new executions and pauses active chains)",
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
        name: "parallel.resume",
        description: "Resume a paused parallel run",
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
        name: "parallel.instruct",
        description: "Inject operator guidance into a parallel run or execution",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "guidance": ["type": "string"]
          ],
          "required": ["runId", "guidance"]
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

  private func makeRPCError(id: Any?, code: Int, message: String, data: [String: Any]? = nil) -> Data {
    var errorPayload: [String: Any] = ["code": code, "message": message]
    if let data {
      errorPayload["data"] = data
    }
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id as Any,
      "error": errorPayload
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
    uiAutomationProvider.recordUIActionHandled(controlId)
  }

  public func recordUIActionRequested(_ controlId: String) {
    uiAutomationProvider.recordUIActionRequested(controlId)
  }

  public func recordUIActionForegroundNeeded(_ controlId: String) {
    uiAutomationProvider.recordUIActionForegroundNeeded(controlId)
  }

  private func availableViewIds() -> [String] {
    uiAutomationProvider.availableViewIds()
  }

  private func viewTitle(for viewId: String) -> String {
    uiAutomationProvider.viewTitle(for: viewId)
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

  private func availableToolControlIds() -> [String] {
    uiAutomationProvider.availableToolControlIds()
  }

  private func availableControlIds(for viewId: String?) -> [String] {
    uiAutomationProvider.availableControlIds(for: viewId)
  }

  private func controlValues(for viewId: String?) -> [String: Any] {
    uiAutomationProvider.controlValues(for: viewId)
  }

  private func dedupeStrings(_ values: [String]?) -> [String] {
    guard let values else { return [] }
    return Array(Set(values)).sorted()
  }

  private func currentToolId() -> String? {
    uiAutomationProvider.currentToolId()
  }

  private func setCurrentToolId(_ toolId: String) {
    uiAutomationProvider.setCurrentToolId(toolId)
  }

  private func worktreeNameMapFromDefaults() -> [String: String] {
    uiAutomationProvider.worktreeNameMapFromDefaults()
  }
}
