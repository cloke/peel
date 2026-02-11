//
//  MCPServerService.swift
//  KitchenSync
//
//  Extracted from AgentManager.swift on 1/24/26.
//

import AppKit
import Foundation
import Git
import Github
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
  let logger = Logger(subsystem: "com.peel.mcp", category: "MCPServerService")
  let telemetryProvider: MCPTelemetryProviding
  enum StorageKey {
    static let enabled = "mcp.server.enabled"
    static let port = "mcp.server.port"
    static let maxConcurrentChains = "mcp.server.maxConcurrentChains"
    static let maxQueuedChains = "mcp.server.maxQueuedChains"
    static let autoCleanupWorkspaces = "mcp.server.autoCleanupWorkspaces"
    static let sleepPreventionEnabled = "mcp.server.sleepPreventionEnabled"
    static let lanModeEnabled = "mcp.server.lanModeEnabled"
    static let allowAllTools = "mcp.server.allowAllTools"
    static let allowForegroundTools = "mcp.server.allowForegroundTools"
    static let localRagEnabled = "localrag.enabled"
    static let localRagRepoPath = "localrag.repoPath"
    static let localRagQuery = "localrag.query"
    static let localRagSearchMode = "localrag.searchMode"
    static let localRagSearchLimit = "localrag.searchLimit"
    static let ragUsageStats = "localrag.usageStats"
    static let ragSessionEvents = "localrag.sessionEvents"
  }

  // Tool types from MCPCore
  public typealias ToolCategory = MCPToolCategory
  public typealias ToolGroup = MCPToolGroup
  public typealias ToolDefinition = MCPToolDefinition

  public enum RAGSearchMode: String, CaseIterable, Codable {
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

  public struct RAGUsageStats: Codable {
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
    public var sessionStartedAt: Date?
    
    // AI Analysis tracking
    public var analysisRuns: Int = 0
    public var chunksAnalyzedTotal: Int = 0
    public var totalAnalysisTimeSeconds: Double = 0
    public var lastAnalysisAt: Date?

    public init() {
      self.sessionStartedAt = Date()
    }

    /// False positive rate: irrelevant / (helpful + irrelevant)
    public var falsePositiveRate: Double? {
      let total = helpfulCount + irrelevantCount
      guard total > 0 else { return nil }
      return Double(irrelevantCount) / Double(total)
    }

    /// Helpfulness rate: helpful / (helpful + irrelevant)
    public var helpfulnessRate: Double? {
      let total = helpfulCount + irrelevantCount
      guard total > 0 else { return nil }
      return Double(helpfulCount) / Double(total)
    }
  }

  public struct RAGSessionEvent: Identifiable, Codable {
    public enum Kind: String, CaseIterable, Codable {
      case search
      case index
      case copy
      case open
      case helpful
      case irrelevant
      case skillAdded
      case skillUpdated
      case skillDeleted
      case lessonAdded
      case lessonUpdated
      case lessonDeleted
      case lessonApplied
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

  public struct RAGQueryHint: Identifiable, Codable {
    public let id: UUID
    public let query: String
    public let repoPath: String?
    public let mode: RAGSearchMode
    public var resultCount: Int
    public var useCount: Int
    public var lastUsedAt: Date

    public init(query: String, repoPath: String?, mode: RAGSearchMode, resultCount: Int, useCount: Int = 1, lastUsedAt: Date = Date()) {
      self.id = UUID()
      self.query = query
      self.repoPath = repoPath
      self.mode = mode
      self.resultCount = resultCount
      self.useCount = useCount
      self.lastUsedAt = lastUsedAt
    }

    var key: String {
      let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let repo = repoPath?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
      return "\(normalized)|\(repo)|\(mode.rawValue)"
    }
  }

  /// Repository info for RAG dashboard display
  public struct RAGRepoInfo: Identifiable {
    public let id: String
    public let name: String
    public let rootPath: String
    public let lastIndexedAt: Date?
    public let fileCount: Int
    public let chunkCount: Int
    public let repoIdentifier: String?

    public init(id: String, name: String, rootPath: String, lastIndexedAt: Date?, fileCount: Int, chunkCount: Int, repoIdentifier: String? = nil) {
      self.id = id
      self.name = name
      self.rootPath = rootPath
      self.lastIndexedAt = lastIndexedAt
      self.fileCount = fileCount
      self.chunkCount = chunkCount
      self.repoIdentifier = repoIdentifier
    }
  }

  // MARK: - RAG Analysis State (per repo)
  
  /// Observable state for a single repo's analysis - stored in MCPServerService to persist across view navigation
  @Observable
  @MainActor
  public final class RAGRepoAnalysisState {
    public let repoId: String
    public let repoPath: String
    
    public var analyzedCount: Int = 0
    public var unanalyzedCount: Int = 0
    public var isAnalyzing: Bool = false
    public var isPaused: Bool = false
    public var analyzeError: String?
    public var analysisStartTime: Date?
    public var chunksPerSecond: Double = 0
    public var sessionChunksAnalyzed: Int = 0
    public var analyzeTask: Task<Void, Never>?
    public var batchProgress: (current: Int, total: Int)?
    
    public var totalChunks: Int { analyzedCount + unanalyzedCount }
    public var progress: Double { totalChunks > 0 ? Double(analyzedCount) / Double(totalChunks) : 0 }
    public var isComplete: Bool { totalChunks > 0 && unanalyzedCount == 0 }
    
    public init(repoId: String, repoPath: String) {
      self.repoId = repoId
      self.repoPath = repoPath
    }
  }

  public var isEnabled: Bool {
    didSet {
      config.set(isEnabled, forKey: StorageKey.enabled)
      if isEnabled {
        start()
      } else {
        stop()
      }
    }
  }

  public var port: Int {
    didSet {
      config.set(port, forKey: StorageKey.port)
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
      config.set(maxConcurrentChains, forKey: StorageKey.maxConcurrentChains)
    }
  }

  public var maxQueuedChains: Int {
    didSet {
      if maxQueuedChains < 0 {
        maxQueuedChains = 0
      }
      config.set(maxQueuedChains, forKey: StorageKey.maxQueuedChains)
    }
  }

  public var autoCleanupWorkspaces: Bool {
    didSet {
      config.set(autoCleanupWorkspaces, forKey: StorageKey.autoCleanupWorkspaces)
    }
  }
  
  public var sleepPreventionEnabled: Bool {
    didSet {
      config.set(sleepPreventionEnabled, forKey: StorageKey.sleepPreventionEnabled)
      updateSleepPrevention()
    }
  }

  /// When enabled, MCP server accepts connections from LAN (not just localhost).
  /// WARNING: Only enable on trusted networks. No authentication is performed.
  public var lanModeEnabled: Bool {
    didSet {
      config.set(lanModeEnabled, forKey: StorageKey.lanModeEnabled)
      // Restart server if running to apply change
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
  public var localRagEnabled: Bool = true {
    didSet { config.set(localRagEnabled, forKey: StorageKey.localRagEnabled) }
  }
  public var localRagRepoPath: String = "" {
    didSet { config.set(localRagRepoPath, forKey: StorageKey.localRagRepoPath) }
  }
  public var localRagQuery: String = "" {
    didSet { config.set(localRagQuery, forKey: StorageKey.localRagQuery) }
  }
  public var localRagSearchMode: RAGSearchMode = .text {
    didSet { config.set(localRagSearchMode.rawValue, forKey: StorageKey.localRagSearchMode) }
  }
  public var localRagSearchLimit: Int = 5 {
    didSet { config.set(localRagSearchLimit, forKey: StorageKey.localRagSearchLimit) }
  }

  // MARK: - Prompt Rules & Guardrails

  /// Rules that are automatically prepended to prompts during chain execution
  public struct PromptRules: Codable, Sendable {
    public var globalPrefix: String
    public var enforcePlannerModel: String?
    public var maxPremiumCostDefault: Double?
    public var requireRagByDefault: Bool
    public var perTemplateOverrides: [String: TemplateOverride]

    public struct TemplateOverride: Codable, Sendable {
      public var promptPrefix: String?
      public var enforcePlannerModel: String?
      public var maxPremiumCost: Double?
      public var requireRag: Bool?
    }

    public init(
      globalPrefix: String = "",
      enforcePlannerModel: String? = nil,
      maxPremiumCostDefault: Double? = nil,
      requireRagByDefault: Bool = false,
      perTemplateOverrides: [String: TemplateOverride] = [:]
    ) {
      self.globalPrefix = globalPrefix
      self.enforcePlannerModel = enforcePlannerModel
      self.maxPremiumCostDefault = maxPremiumCostDefault
      self.requireRagByDefault = requireRagByDefault
      self.perTemplateOverrides = perTemplateOverrides
    }

    public static let `default` = PromptRules()
  }

  public var promptRules: PromptRules {
    didSet { savePromptRules() }
  }

  /// Apply prompt rules to a prompt and options before chain execution
  public func applyPromptRules(
    prompt: String,
    templateName: String?,
    options: AgentChainRunner.ChainRunOptions?
  ) -> (prompt: String, options: AgentChainRunner.ChainRunOptions) {
    var finalPrompt = prompt
    var finalOptions = options ?? AgentChainRunner.ChainRunOptions()

    // Apply global prefix
    if !promptRules.globalPrefix.isEmpty {
      finalPrompt = promptRules.globalPrefix + "\n\n" + finalPrompt
    }

    // Apply template-specific overrides
    if let templateName, let override = promptRules.perTemplateOverrides[templateName] {
      if let prefix = override.promptPrefix, !prefix.isEmpty {
        finalPrompt = prefix + "\n\n" + finalPrompt
      }
      if let enforcedModel = override.enforcePlannerModel {
        // Log that we're enforcing a planner model
        Task { await telemetryProvider.info("Enforcing planner model from template override", metadata: [
          "templateName": templateName,
          "enforcedModel": enforcedModel
        ]) }
      }
      if let maxCost = override.maxPremiumCost {
        finalOptions = AgentChainRunner.ChainRunOptions(
          allowPlannerModelSelection: finalOptions.allowPlannerModelSelection,
          allowImplementerModelOverride: finalOptions.allowImplementerModelOverride,
          allowPlannerImplementerScaling: finalOptions.allowPlannerImplementerScaling,
          maxImplementers: finalOptions.maxImplementers,
          maxPremiumCost: maxCost
        )
      }
    }

    // Apply global defaults if not overridden
    if let maxCost = promptRules.maxPremiumCostDefault, finalOptions.maxPremiumCost == nil {
      finalOptions = AgentChainRunner.ChainRunOptions(
        allowPlannerModelSelection: finalOptions.allowPlannerModelSelection,
        allowImplementerModelOverride: finalOptions.allowImplementerModelOverride,
        allowPlannerImplementerScaling: finalOptions.allowPlannerImplementerScaling,
        maxImplementers: finalOptions.maxImplementers,
        maxPremiumCost: maxCost
      )
    }

    return (finalPrompt, finalOptions)
  }

  private func loadPromptRules() -> PromptRules {
    guard let data = config.data(forKey: "mcp.server.promptRules"),
          let rules = try? JSONDecoder().decode(PromptRules.self, from: data) else {
      return .default
    }
    return rules
  }

  private func savePromptRules() {
    guard let data = try? JSONEncoder().encode(promptRules) else { return }
    config.set(data, forKey: "mcp.server.promptRules")
  }

  private func saveRagUsageStats() {
    guard let data = try? JSONEncoder().encode(ragUsage) else { return }
    config.set(data, forKey: StorageKey.ragUsageStats)
  }

  private func saveRagSessionEvents() {
    // Keep only last 50 events to avoid unbounded growth
    let eventsToSave = Array(ragSessionEvents.suffix(50))
    guard let data = try? JSONEncoder().encode(eventsToSave) else { return }
    config.set(data, forKey: StorageKey.ragSessionEvents)
  }

  /// Clears persisted RAG session data (for starting fresh)
  public func clearRagSessionData() {
    ragUsage = RAGUsageStats()
    ragSessionEvents = []
    ragQueryHints = []
    saveRagUsageStats()
    saveRagSessionEvents()
  }

  private(set) var ragStatus: LocalRAGStore.Status?
  private(set) var ragStats: LocalRAGStore.Stats?
  private(set) var ragUsage = RAGUsageStats()
  private(set) var ragSessionEvents: [RAGSessionEvent] = []
  private(set) var ragQueryHints: [RAGQueryHint] = []
  private(set) var ragRepos: [RAGRepoInfo] = []
  var ragIndexingPath: String?
  var ragIndexProgress: LocalRAGIndexProgress?
  private(set) var ragIndexingTask: Task<LocalRAGIndexReport, Error>?
  var lastRagIndexReport: LocalRAGIndexReport?
  var lastRagIndexAt: Date?
  private(set) var lastRagRefreshAt: Date?
  private(set) var lastRagError: String?
  private(set) var ragArtifactStatus: RAGArtifactStatus?
  var ragArtifactSyncError: String?
  private(set) var lastRagSearchQuery: String?
  private(set) var lastRagSearchMode: RAGSearchMode?
  private(set) var lastRagSearchRepoPath: String?
  private(set) var lastRagSearchLimit: Int?
  private(set) var lastRagSearchAt: Date?
  private(set) var lastRagSearchResults: [LocalRAGSearchResult] = []
  
  /// Per-repo analysis state (keyed by repo ID) - persists across view navigation
  public var repoAnalysisStates: [String: RAGRepoAnalysisState] = [:]
  
  /// Get or create analysis state for a repo
  public func analysisState(for repoId: String, repoPath: String) -> RAGRepoAnalysisState {
    if let existing = repoAnalysisStates[repoId] {
      return existing
    }
    let state = RAGRepoAnalysisState(repoId: repoId, repoPath: repoPath)
    repoAnalysisStates[repoId] = state
    return state
  }

  public let agentManager: AgentManager
  public let cliService: CLIService
  public let sessionTracker: SessionTracker
  let chainRunner: AgentChainRunner
  let uiAutomationProvider: MCPUIAutomationProviding
  var dataService: DataService?
  private let screenshotService = ScreenshotService()
  let translationValidatorService = TranslationValidatorService()
  let piiScrubberService = PIIScrubberService()
  let doclingService = DoclingService()
  private let vmIsolationService: VMIsolationService
  var localRagStore = LocalRAGStore()
  private(set) var parallelWorktreeRunner: ParallelWorktreeRunner?

  // MARK: - Tool Handlers (extracted from this file for maintainability)

  private var uiToolsHandler: UIToolsHandler
  private var vmToolsHandler: VMToolsHandler
  private var parallelToolsHandler: ParallelToolsHandler
  private var ragToolsHandler: RAGToolsHandler?
  private var codeEditToolsHandler: CodeEditToolsHandler?
  private var chainToolsHandler: ChainToolsHandler?
  private var swarmToolsHandler: SwarmToolsHandler
  private var repoToolsHandler: RepoToolsHandler
  private var worktreeToolsHandler: WorktreeToolsHandler
  private var githubToolsHandler: GitHubToolsHandler?
  private var terminalToolsHandler: TerminalToolsHandler

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

  struct ChainQueueEntry {
    let id: UUID
    let enqueuedAt: Date
    let priority: Int
    let continuation: CheckedContinuation<Bool, Never>
  }

  var activeChainRuns: Int = 0
  var activeChainRunIds: Set<UUID> = []
  var activeChainTasks: [UUID: Task<AgentChainRunner.RunSummary, Never>] = [:]
  var activeChainTimeouts: [UUID: Task<Void, Never>] = [:]
  var activeRunsById: [UUID: ActiveRunInfo] = [:]
  var activeRunChains: [UUID: AgentChain] = [:]
  var chainQueue: [ChainQueueEntry] = []
  var completedRunsById: [UUID: (completedAt: Date, payload: [String: Any])] = [:]

  private let listenerQueue = DispatchQueue(label: "MCPServer.Listener")
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]
  private var connectionStates: [UUID: ConnectionState] = [:]
  private var sleepPreventionAssertionId: IOPMAssertionID?
  private let permissionsStore: MCPToolPermissionsProviding
  let config: MCPServerConfigProviding
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
    config: MCPServerConfigProviding = MCPUserDefaultsConfig(),
    vmIsolationService: VMIsolationService = VMIsolationService()
  ) {
    // Initialize tool handlers first (before self is fully initialized)
    self.uiToolsHandler = UIToolsHandler()
    self.vmToolsHandler = VMToolsHandler(vmIsolationService: vmIsolationService, telemetryProvider: telemetryProvider ?? MCPTelemetryAdapter(sessionTracker: sessionTracker))
    self.parallelToolsHandler = ParallelToolsHandler()
    self.ragToolsHandler = RAGToolsHandler()
    #if os(macOS)
    self.codeEditToolsHandler = CodeEditToolsHandler()
    #endif
    self.chainToolsHandler = ChainToolsHandler()
    self.repoToolsHandler = RepoToolsHandler()
    self.worktreeToolsHandler = WorktreeToolsHandler()
    self.githubToolsHandler = GitHubToolsHandler()
    self.terminalToolsHandler = TerminalToolsHandler()

    self.agentManager = agentManager
    self.sessionTracker = sessionTracker
    let resolvedTelemetry = telemetryProvider ?? MCPTelemetryAdapter(sessionTracker: sessionTracker)
    self.telemetryProvider = resolvedTelemetry
    let resolvedCLIService = cliService ?? CLIService(telemetryProvider: resolvedTelemetry)
    self.cliService = resolvedCLIService
    self.uiAutomationProvider = uiAutomationProvider
    self.permissionsStore = permissionsStore
    self.config = config
    self.vmIsolationService = vmIsolationService
    self.chainRunner = AgentChainRunner(
      agentManager: agentManager,
      cliService: resolvedCLIService,
      telemetryProvider: resolvedTelemetry
    )
    
    // Initialize SwarmToolsHandler with chainRunner and agentManager for distributed execution
    self.swarmToolsHandler = SwarmToolsHandler(
      chainRunner: self.chainRunner,
      agentManager: agentManager
    )
    
    self.isEnabled = config.bool(forKey: StorageKey.enabled, default: false)
    self.port = config.integer(forKey: StorageKey.port, default: 0)
    self.maxConcurrentChains = config.integer(forKey: StorageKey.maxConcurrentChains, default: 0)
    self.maxQueuedChains = config.integer(forKey: StorageKey.maxQueuedChains, default: 0)
    self.autoCleanupWorkspaces = config.bool(forKey: StorageKey.autoCleanupWorkspaces, default: false)
    self.sleepPreventionEnabled = config.bool(forKey: StorageKey.sleepPreventionEnabled, default: false)
    self.lanModeEnabled = config.bool(forKey: StorageKey.lanModeEnabled, default: false)
    // Default RAG enabled to true if not explicitly set
    if !config.objectExists(forKey: StorageKey.localRagEnabled) {
      self.localRagEnabled = true
    } else {
      self.localRagEnabled = config.bool(forKey: StorageKey.localRagEnabled, default: true)
    }
    self.localRagRepoPath = config.string(forKey: StorageKey.localRagRepoPath, default: "")
    self.localRagQuery = config.string(forKey: StorageKey.localRagQuery, default: "")
    let storedMode = config.string(forKey: StorageKey.localRagSearchMode, default: RAGSearchMode.text.rawValue)
    self.localRagSearchMode = RAGSearchMode(rawValue: storedMode) ?? .text
    let storedLimit = config.integer(forKey: StorageKey.localRagSearchLimit, default: 0)
    self.localRagSearchLimit = storedLimit == 0 ? 5 : storedLimit
    // Initialize prompt rules from UserDefaults
    if let data = config.data(forKey: "mcp.server.promptRules"),
       let rules = try? JSONDecoder().decode(PromptRules.self, from: data) {
      self.promptRules = rules
    } else {
      self.promptRules = .default
    }
    // Load persisted RAG usage stats
    if let data = config.data(forKey: StorageKey.ragUsageStats),
       let stats = try? JSONDecoder().decode(RAGUsageStats.self, from: data) {
      self.ragUsage = stats
    }
    // Load persisted RAG session events (limit to last 50)
    if let data = config.data(forKey: StorageKey.ragSessionEvents),
       let events = try? JSONDecoder().decode([RAGSessionEvent].self, from: data) {
      self.ragSessionEvents = Array(events.suffix(50))
    }
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

    // Wire up tool handler delegates (must be after self is fully initialized)
    self.uiToolsHandler.delegate = self
    self.parallelToolsHandler.delegate = self
    self.ragToolsHandler?.delegate = self
    self.codeEditToolsHandler?.delegate = self
    self.chainToolsHandler?.delegate = self
    self.swarmToolsHandler.delegate = self
    self.repoToolsHandler.delegate = self
    self.worktreeToolsHandler.delegate = self
    self.githubToolsHandler?.delegate = self
    self.terminalToolsHandler.delegate = self
    SwarmCoordinator.shared.ragSyncDelegate = self

    // If running in worker mode, inject the chain executor into the already-running SwarmCoordinator
    // This enables workers to actually execute chains instead of returning mock results
    let isWorkerMode = WorkerMode.shared.shouldRunInWorkerMode
    let swarmRole = SwarmCoordinator.shared.role
    if isWorkerMode || swarmRole == .worker || swarmRole == .hybrid {
      let executor = DefaultChainExecutor(chainRunner: chainRunner, agentManager: agentManager)
      SwarmCoordinator.shared.configure(chainExecutor: executor)
      logger.info("SwarmCoordinator configured with chain executor for worker mode")
    }

    updateSleepPrevention()

    if isEnabled {
      start()
    }

    Task { await refreshRagArtifactStatus() }
  }
  
  /// Configure the SwarmCoordinator with a chain executor for worker mode
  /// Called by SwarmStatusView when starting as worker/hybrid from UI
  public func configureSwarmExecutor() {
    let executor = DefaultChainExecutor(chainRunner: chainRunner, agentManager: agentManager)
    SwarmCoordinator.shared.configure(chainExecutor: executor)
    logger.info("SwarmCoordinator configured with chain executor via UI")
  }

  public var toolCategories: [ToolCategory] {
    ToolCategory.allCases.filter { category in
      activeToolDefinitions.contains { $0.category == category }
    }
  }

  public var toolGroups: [ToolGroup] {
    ToolGroup.allCases.filter { group in
      activeToolDefinitions.contains { !groups(for: $0).filter { $0 == group }.isEmpty }
    }
  }

  public var uiControlDocs: [ViewControlDoc] {
    uiAutomationProvider.uiControlDocs
  }

  public func tools(in category: ToolCategory) -> [ToolDefinition] {
    activeToolDefinitions
      .filter { $0.category == category }
      .sorted { $0.name < $1.name }
  }

  public func toolCount(in category: ToolCategory) -> Int {
    tools(in: category).count
  }

  public func tools(in group: ToolGroup) -> [ToolDefinition] {
    activeToolDefinitions
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
    activeToolDefinitions.filter { $0.requiresForeground }.count
  }

  public var backgroundToolCount: Int {
    activeToolDefinitions.filter { !$0.requiresForeground }.count
  }

  public var totalToolCount: Int {
    activeToolDefinitions.count
  }

  public var enabledToolCount: Int {
    activeToolDefinitions.filter { isToolEnabled($0.name) }.count
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
    updateToolsEnabled(activeToolDefinitions, enabled: enabled)
  }

  public func isToolEnabled(_ name: String) -> Bool {
    guard let tool = toolDefinition(named: name) else { return false }
    if tool.requiresForeground && !allowForegroundTools {
      return false
    }
    if name.hasPrefix("ui."), allowForegroundTools {
      return true
    }
    if config.bool(forKey: StorageKey.allowAllTools, default: false) {
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
      let repos = try await localRagStore.listRepos()
      ragStatus = status
      ragStats = stats
      ragRepos = repos.map { repo in
        RAGRepoInfo(
          id: repo.id,
          name: repo.name,
          rootPath: repo.rootPath,
          lastIndexedAt: repo.lastIndexedAt,
          fileCount: repo.fileCount,
          chunkCount: repo.chunkCount,
          repoIdentifier: repo.repoIdentifier
        )
      }
      lastRagError = nil
      lastRagRefreshAt = Date()
    } catch {
      ragStatus = await localRagStore.status()
      ragStats = nil
      ragRepos = []
      lastRagError = error.localizedDescription
      lastRagRefreshAt = Date()
    }
    await refreshRagArtifactStatus()
  }

  // MARK: - Dependency Graph

  func listRagReposForGraph() async throws -> [(name: String, path: String)] {
    let repos = try await localRagStore.listRepos()
    return repos.map { (name: $0.name, path: $0.rootPath) }
  }

  func buildFullDependencyGraph(repoPath: String) async throws -> FullGraphData {
    let fileSummaries = try await localRagStore.getFileSummaries(for: repoPath)
    let edges = try await localRagStore.getDependencyEdges(for: repoPath)

    var moduleStats: [String: GraphNodeStats] = [:]
    var submoduleStats: [String: GraphNodeStats] = [:]
    var fileIndex: [String: LocalRAGFileSummary] = [:]

    for file in fileSummaries {
      let normalized = normalizedPath(file.path)
      fileIndex[normalized] = file

      let moduleId = moduleKey(for: normalized, modulePath: file.modulePath)
      let submoduleInfo = submoduleKey(for: normalized, modulePath: file.modulePath)

      var moduleBucket = moduleStats[moduleId, default: GraphNodeStats()]
      moduleBucket.fileCount += 1
      addLanguage(file.language, to: &moduleBucket.languages)
      moduleStats[moduleId] = moduleBucket

      var submoduleBucket = submoduleStats[submoduleInfo.key, default: GraphNodeStats()]
      submoduleBucket.fileCount += 1
      addLanguage(file.language, to: &submoduleBucket.languages)
      submoduleBucket.module = submoduleInfo.module
      submoduleStats[submoduleInfo.key] = submoduleBucket
    }

    var resolvedDependencies = 0
    var inferredDependencies = 0
    var moduleLinks: [LinkKey: LinkBucket] = [:]
    var submoduleLinks: [LinkKey: LinkBucket] = [:]

    for edge in edges {
      let sourcePath = normalizedPath(edge.sourceFile)
      let sourceFile = fileIndex[sourcePath]
      let sourceModule = moduleKey(for: sourcePath, modulePath: sourceFile?.modulePath)
      let sourceSubmodule = submoduleKey(for: sourcePath, modulePath: sourceFile?.modulePath).key

      let targetPath = edge.targetFile.map { normalizedPath($0) } ?? normalizedPath(edge.targetPath)
      let targetFile = edge.targetFile.flatMap { fileIndex[normalizedPath($0)] }
      let targetModule = moduleKey(for: targetPath, modulePath: targetFile?.modulePath)
      let targetSubmodule = submoduleKey(for: targetPath, modulePath: targetFile?.modulePath).key

      if edge.targetFile == nil {
        inferredDependencies += 1
      } else {
        resolvedDependencies += 1
      }

      if !sourceModule.isEmpty, !targetModule.isEmpty, sourceModule != targetModule {
        let key = LinkKey(source: sourceModule, target: targetModule)
        moduleLinks[key, default: LinkBucket()].add(type: edge.dependencyType.rawValue)
      }

      if !sourceSubmodule.isEmpty, !targetSubmodule.isEmpty, sourceSubmodule != targetSubmodule {
        let key = LinkKey(source: sourceSubmodule, target: targetSubmodule)
        submoduleLinks[key, default: LinkBucket()].add(type: edge.dependencyType.rawValue)
      }

      if moduleStats[targetModule] == nil {
        moduleStats[targetModule] = GraphNodeStats()
      }
      if submoduleStats[targetSubmodule] == nil {
        var bucket = GraphNodeStats()
        bucket.module = submoduleKey(for: targetPath, modulePath: targetFile?.modulePath).module
        submoduleStats[targetSubmodule] = bucket
      }
    }

    let moduleNodes = moduleStats.map { entry in
      GraphNode(
        id: entry.key,
        label: entry.key,
        fileCount: entry.value.fileCount,
        topLanguage: topLanguage(from: entry.value.languages),
        languages: entry.value.languages.isEmpty ? nil : entry.value.languages,
        module: entry.key
      )
    }
    .sorted { $0.id < $1.id }

    let submoduleNodes = submoduleStats.map { entry in
      GraphNode(
        id: entry.key,
        label: entry.key,
        fileCount: entry.value.fileCount,
        topLanguage: topLanguage(from: entry.value.languages),
        languages: entry.value.languages.isEmpty ? nil : entry.value.languages,
        module: entry.value.module
      )
    }
    .sorted { $0.id < $1.id }

    let moduleLinksOutput = moduleLinks.map { entry in
      GraphLink(source: entry.key.source, target: entry.key.target, weight: entry.value.weight, types: entry.value.types)
    }
    .sorted { $0.source < $1.source }

    let submoduleLinksOutput = submoduleLinks.map { entry in
      GraphLink(source: entry.key.source, target: entry.key.target, weight: entry.value.weight, types: entry.value.types)
    }
    .sorted { $0.source < $1.source }

    let stats = GraphStats(
      totalFiles: fileSummaries.count,
      totalDependencies: edges.count,
      resolvedDependencies: resolvedDependencies,
      inferredDependencies: inferredDependencies,
      totalModules: moduleNodes.count
    )

    return FullGraphData(
      repo: repoPath,
      stats: stats,
      moduleGraph: GraphLevel(nodes: moduleNodes, links: moduleLinksOutput),
      submoduleGraph: GraphLevel(nodes: submoduleNodes, links: submoduleLinksOutput),
      fileGraph: nil
    )
  }

  private struct GraphNodeStats {
    var fileCount: Int = 0
    var languages: [String: Int] = [:]
    var module: String? = nil
  }

  private struct LinkBucket {
    var weight: Int = 0
    var types: [String: Int] = [:]

    mutating func add(type: String) {
      weight += 1
      types[type, default: 0] += 1
    }
  }

  private struct LinkKey: Hashable {
    let source: String
    let target: String
  }

  private func normalizedPath(_ path: String) -> String {
    var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("./") {
      trimmed = String(trimmed.dropFirst(2))
    }
    return trimmed
  }

  private func moduleKey(for path: String, modulePath: String?) -> String {
    let basePath = normalizedPath(modulePath?.isEmpty == false ? modulePath! : path)
    let components = basePath.split(separator: "/")
    return components.first.map(String.init) ?? basePath
  }

  private func submoduleKey(for path: String, modulePath: String?) -> (key: String, module: String) {
    let basePath = normalizedPath(modulePath?.isEmpty == false ? modulePath! : path)
    let components = basePath.split(separator: "/")
    let module = components.first.map(String.init) ?? basePath
    if components.count >= 2 {
      return ("\(components[0])/\(components[1])", module)
    }
    return (module, module)
  }

  private func addLanguage(_ language: String?, to counts: inout [String: Int]) {
    guard let language, !language.isEmpty else { return }
    counts[language, default: 0] += 1
  }

  private func topLanguage(from counts: [String: Int]) -> String? {
    counts.max { $0.value < $1.value }?.key
  }

  func indexPolicyRepository(path: String) async throws -> LocalRAGIndexReport {
    try await localRagStore.indexRepository(path: path)
  }

  private func refreshRagArtifactStatus() async {
    guard let status = ragStatus else {
      ragArtifactStatus = nil
      SwarmCoordinator.shared.updateLocalRagArtifactStatus(nil)
      return
    }

    let stats = try? await localRagStore.stats()
    let repos = (try? await localRagStore.listRepos()) ?? []
    let manifest = await LocalRAGArtifacts.buildManifest(status: status, stats: stats, repos: repos)
    let lastSyncedAt = ragArtifactStatus?.lastSyncedAt
    let lastSyncDirection = ragArtifactStatus?.lastSyncDirection
    await updateRagArtifactStatus(from: manifest, lastSyncedAt: lastSyncedAt, direction: lastSyncDirection)
  }

  func updateRagArtifactStatus(
    from manifest: RAGArtifactManifest,
    lastSyncedAt: Date?,
    direction: RAGArtifactSyncDirection?
  ) async {
    let staleInfo = await LocalRAGArtifacts.stalenessInfo(for: manifest)
    let status = RAGArtifactStatus(
      manifestVersion: manifest.version,
      totalBytes: manifest.totalBytes,
      lastSyncedAt: lastSyncedAt,
      lastSyncDirection: direction,
      repoCount: manifest.repos.count,
      lastIndexedAt: manifest.lastIndexedAt,
      staleReason: staleInfo.1
    )
    ragArtifactStatus = status
    SwarmCoordinator.shared.updateLocalRagArtifactStatus(status)
  }

  /// Delete a repository from the RAG index
  public func deleteRagRepo(repoId: String) async throws -> Int {
    let deleted = try await localRagStore.deleteRepo(repoId: repoId)
    await refreshRagSummary()
    return deleted
  }
  
  /// Index a repository (called from UI)
  func indexRagRepo(
    path: String,
    forceReindex: Bool = false,
    allowWorkspace: Bool = false,
    excludeSubrepos: Bool = true
  ) async throws {
    ragIndexingPath = path
    ragIndexProgress = nil
    
    let task = Task {
      let report = try await localRagStore.indexRepository(
        path: path,
        forceReindex: forceReindex,
        allowWorkspace: allowWorkspace,
        excludeSubrepos: excludeSubrepos
      ) { [weak self] progress in
        Task { @MainActor in
          self?.ragIndexProgress = progress
        }
      }
      return report
    }
    ragIndexingTask = task
    
    do {
      let report = try await task.value
      ragIndexingTask = nil
      ragIndexingPath = nil
      ragIndexProgress = .complete(report: report)
      lastRagIndexReport = report
      lastRagIndexAt = Date()
      await refreshRagSummary()
    } catch is CancellationError {
      ragIndexingTask = nil
      ragIndexingPath = nil
      ragIndexProgress = nil
      // Indexing was cancelled - not an error
    } catch {
      ragIndexingTask = nil
      ragIndexingPath = nil
      ragIndexProgress = nil
      throw error
    }
  }
  
  /// Cancel any in-progress indexing
  func cancelRagIndexing() {
    ragIndexingTask?.cancel()
    ragIndexingTask = nil
    ragIndexingPath = nil
    ragIndexProgress = nil
  }

  func listRepoGuidanceSkills(
    repoPath: String? = nil,
    repoRemoteURL: String? = nil,
    includeInactive: Bool = false,
    limit: Int? = nil
  ) -> [RepoGuidanceSkill] {
    dataService?.listRepoGuidanceSkills(
      repoPath: repoPath,
      repoRemoteURL: repoRemoteURL,
      includeInactive: includeInactive,
      limit: limit
    ) ?? []
  }

  @discardableResult
  func addRepoGuidanceSkill(
    repoPath: String,
    repoRemoteURL: String? = nil,
    repoName: String? = nil,
    title: String,
    body: String,
    source: String = "manual",
    tags: String = "",
    priority: Int = 0,
    isActive: Bool = true
  ) -> RepoGuidanceSkill? {
    let created = dataService?.addRepoGuidanceSkill(
      repoPath: repoPath,
      repoRemoteURL: repoRemoteURL,
      repoName: repoName,
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
      saveRagUsageStats()
    }
    return created
  }

  @discardableResult
  func updateRepoGuidanceSkill(
    id: UUID,
    repoPath: String? = nil,
    repoRemoteURL: String? = nil,
    repoName: String? = nil,
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
      repoRemoteURL: repoRemoteURL,
      repoName: repoName,
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
      saveRagUsageStats()
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
      saveRagUsageStats()
    }
    return deleted
  }
  
  // MARK: - Learning Loop (#210)
  
  func listLessons(repoPath: String, includeInactive: Bool, limit: Int?) async throws -> [LocalRAGLesson] {
    try await localRagStore.listLessons(repoPath: repoPath, includeInactive: includeInactive, limit: limit)
  }
  
  func addLesson(
    repoPath: String,
    filePattern: String?,
    errorSignature: String?,
    fixDescription: String,
    fixCode: String?,
    source: String
  ) async throws -> LocalRAGLesson {
    let lesson = try await localRagStore.addLesson(
      repoPath: repoPath,
      filePattern: filePattern,
      errorSignature: errorSignature,
      fixDescription: fixDescription,
      fixCode: fixCode,
      source: source
    )
    appendRagEvent(
      kind: .lessonAdded,
      title: "Lesson added",
      detail: fixDescription
    )
    return lesson
  }
  
  func queryLessons(
    repoPath: String,
    filePattern: String?,
    errorSignature: String?,
    limit: Int
  ) async throws -> [LocalRAGLesson] {
    try await localRagStore.queryLessons(
      repoPath: repoPath,
      filePattern: filePattern,
      errorSignature: errorSignature,
      limit: limit
    )
  }
  
  func updateLesson(
    id: String,
    fixDescription: String?,
    fixCode: String?,
    confidence: Float?,
    isActive: Bool?
  ) async throws -> LocalRAGLesson? {
    if let updated = try await localRagStore.updateLesson(
      id: id,
      fixDescription: fixDescription,
      fixCode: fixCode,
      confidence: confidence,
      isActive: isActive
    ) {
      appendRagEvent(
        kind: .lessonUpdated,
        title: "Lesson updated",
        detail: updated.fixDescription
      )
      return updated
    }
    return nil
  }
  
  func deleteLesson(id: String) async throws -> Bool {
    let deleted = try await localRagStore.deleteLesson(id: id)
    if deleted {
      appendRagEvent(
        kind: .lessonDeleted,
        title: "Lesson deleted",
        detail: id
      )
    }
    return deleted
  }
  
  func recordLessonApplied(id: String, success: Bool) async throws {
    if success {
      // Increase confidence and occurrence count
      try await localRagStore.recordLessonUsed(id: id)
      appendRagEvent(
        kind: .lessonApplied,
        title: "Lesson applied",
        detail: "Confidence increased for lesson \(id.prefix(8))..."
      )
    } else {
      // Decrease confidence for unsuccessful application
      if let lesson = try await localRagStore.getLesson(id: id) {
        let newConfidence = max(0.1, lesson.confidence - 0.1)
        _ = try await localRagStore.updateLesson(id: id, confidence: newConfidence)
        appendRagEvent(
          kind: .lessonApplied,
          title: "Lesson not helpful",
          detail: "Confidence decreased for lesson \(id.prefix(8))..."
        )
      }
    }
  }

  func clearMCPRunHistory() {
    dataService?.clearMCPRunHistory()
    sessionTracker.resetSession()
  }

  private func buildRepoGuidance(repoPath: String) async -> String? {
    var sections: [String] = []
    if let dataService {
      // Auto-seed Ember skills if this is an Ember project (Issue #263)
      let seededCount = await MainActor.run {
        DefaultSkillsService.autoSeedEmberSkillsIfNeeded(context: dataService.modelContext, repoPath: repoPath)
      }
      if seededCount > 0 {
        await telemetryProvider.info("Auto-seeded Ember skills", metadata: [
          "repoPath": repoPath,
          "skillsAdded": "\(seededCount)"
        ])
      }

      let repoRemoteURL = await RepoRegistry.shared.registerRepo(at: repoPath)
      if let (skillsBlock, skills) = dataService.repoGuidanceSkillsBlock(
        repoPath: repoPath,
        repoRemoteURL: repoRemoteURL
      ) {
        sections.append(skillsBlock)
        dataService.markRepoGuidanceSkillsApplied(skills)
      }
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

  func applyRagEmbeddingSettings() async {
    localRagStore = LocalRAGStore()
    parallelWorktreeRunner?.setRAGStore(localRagStore)
    ragIndexingPath = nil
    ragIndexProgress = nil
    ragStatus = await localRagStore.status()
    ragStats = try? await localRagStore.stats()
    lastRagError = nil
    lastRagRefreshAt = Date()
    await refreshRagSummary()
  }

  func indexRag(repoPath: String) async throws -> LocalRAGIndexReport {
    let report = try await localRagStore.indexRepository(
      path: repoPath,
      allowWorkspace: false,
      excludeSubrepos: true,
      progress: nil
    )
    ragStatus = await localRagStore.status()
    ragStats = try await localRagStore.stats()
    ragUsage.indexRuns += 1
    ragUsage.lastIndexAt = Date()
    lastRagIndexReport = report
    lastRagIndexAt = Date()
    let skipInfo = report.filesSkipped > 0 ? " (\(report.filesSkipped) unchanged)" : ""
    appendRagEvent(
      kind: .index,
      title: "Indexed \(report.filesIndexed) files\(skipInfo) · \(report.chunksIndexed) chunks",
      detail: report.repoPath
    )
    lastRagError = nil
    lastRagRefreshAt = Date()
    saveRagUsageStats()
    return report
  }

  func searchRag(
    query: String,
    mode: RAGSearchMode,
    repoPath: String? = nil,
    limit: Int = 10,
    matchAll: Bool = true
  ) async throws -> [LocalRAGSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let results = try await runRagSearch(
      query: trimmedQuery,
      mode: mode,
      repoPath: repoPath,
      limit: limit,
      matchAll: matchAll,
      recordHints: true
    )
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
    if !results.isEmpty {
      await refreshRagQueryHints(query: trimmedQuery, repoPath: repoPath, mode: mode, resultCount: results.count)
    }
    appendRagEvent(
      kind: .search,
      title: "Search · \(results.count) results",
      detail: trimmedQuery
    )
    lastRagSearchQuery = trimmedQuery
    lastRagSearchMode = mode
    lastRagSearchRepoPath = repoPath
    lastRagSearchLimit = limit
    lastRagSearchAt = Date()
    lastRagSearchResults = results
    lastRagError = nil
    saveRagUsageStats()
    return results
  }

  func ragQueryHints(limit: Int? = 10) -> [RAGQueryHint] {
    let hints = ragQueryHints.sorted { $0.lastUsedAt > $1.lastUsedAt }
    guard let limit, limit > 0 else { return hints }
    return Array(hints.prefix(limit))
  }

  func refreshRagQueryHints() async {
    await refreshRagQueryHints(query: nil, repoPath: nil, mode: nil, resultCount: nil)
  }

  func runRagSearch(
    query: String,
    mode: RAGSearchMode,
    repoPath: String?,
    limit: Int,
    matchAll: Bool,
    recordHints: Bool,
    modulePath: String? = nil
  ) async throws -> [LocalRAGSearchResult] {
    let results: [LocalRAGSearchResult]
    switch mode {
    case .vector:
      results = try await localRagStore.searchVector(query: query, repoPath: repoPath, limit: limit, modulePath: modulePath)
    case .text:
      results = try await localRagStore.search(query: query, repoPath: repoPath, limit: limit, matchAll: matchAll, modulePath: modulePath)
    }
    if recordHints, !results.isEmpty {
      do {
        try await localRagStore.recordQueryHint(
          query: query,
          repoPath: repoPath,
          mode: mode.rawValue,
          resultCount: results.count
        )
      } catch {
        await telemetryProvider.warning("RAG query hint insert failed", metadata: ["error": error.localizedDescription])
      }
    }
    return results
  }

  private func refreshRagQueryHints(query: String?, repoPath: String?, mode: RAGSearchMode?, resultCount: Int?) async {
    do {
      if let query, let mode, let resultCount {
        try await localRagStore.recordQueryHint(query: query, repoPath: repoPath, mode: mode.rawValue, resultCount: resultCount)
      }
      let hints = try await localRagStore.fetchQueryHints(limit: 25)
      ragQueryHints = hints.map {
        RAGQueryHint(
          query: $0.query,
          repoPath: $0.repoPath,
          mode: RAGSearchMode(rawValue: $0.mode) ?? .text,
          resultCount: $0.resultCount,
          useCount: $0.useCount,
          lastUsedAt: $0.lastUsedAt
        )
      }
    } catch {
      await telemetryProvider.warning("RAG query hints refresh failed", metadata: ["error": error.localizedDescription])
    }
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
    saveRagUsageStats()
  }
  
  /// Records AI analysis session completion for persistent tracking
  func recordAnalysisSession(chunksAnalyzed: Int, durationSeconds: Double) {
    ragUsage.analysisRuns += 1
    ragUsage.chunksAnalyzedTotal += chunksAnalyzed
    ragUsage.totalAnalysisTimeSeconds += durationSeconds
    ragUsage.lastAnalysisAt = Date()
    appendRagEvent(
      kind: .index,  // Reuse index kind for analysis
      title: "AI analysis completed",
      detail: "\(chunksAnalyzed) chunks in \(formatDuration(durationSeconds))"
    )
    saveRagUsageStats()
  }
  
  private func formatDuration(_ seconds: Double) -> String {
    if seconds < 60 {
      return "\(Int(seconds))s"
    } else if seconds < 3600 {
      let mins = Int(seconds / 60)
      let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
      return "\(mins)m \(secs)s"
    } else {
      let hours = Int(seconds / 3600)
      let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
      return "\(hours)h \(mins)m"
    }
  }

  private func appendRagEvent(kind: RAGSessionEvent.Kind, title: String, detail: String?) {
    let event = RAGSessionEvent(timestamp: Date(), title: title, detail: detail, kind: kind)
    ragSessionEvents.insert(event, at: 0)
    if ragSessionEvents.count > 50 {
      ragSessionEvents.removeLast(ragSessionEvents.count - 50)
    }
    saveRagSessionEvents()
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
    public var enablePrePlanner: Bool? = nil  // Issue #133
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
    if let enablePrePlanner = overrides.enablePrePlanner {
      arguments["enablePrePlanner"] = enablePrePlanner
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
    // In LAN mode, accept all connections; otherwise only localhost
    guard lanModeEnabled || isLocalConnection(connection) else {
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
      let (_, responseBody) = await handleRPC(body: request.body)
      // JSON-RPC spec: Always return HTTP 200 for valid JSON-RPC responses.
      // Error information is in the JSON body, not the HTTP status.
      // Using HTTP 4xx/5xx causes VS Code MCP client to kill the connection.
      sendHTTPResponse(status: 200, body: responseBody, on: connection)
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
        return (400, JSONRPCResponseBuilder.makeError(id: nil, code: -32600, message: "Invalid Request"))
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
      case "initialize", "mcp/initialize":
        let result: [String: Any] = [
          "protocolVersion": "2024-11-05",
          "serverInfo": ["name": "Peel MCP Server", "version": "0.1"],
          "capabilities": ["tools": [:]]
        ]
        statusCode = 200
        return (200, JSONRPCResponseBuilder.makeResult(id: id, result: result))

      case "initialized", "notifications/initialized":
        statusCode = 200
        return (200, Data())

      // Handle common MCP notifications (no response expected)
      case "notifications/cancelled", "cancelled",
           "notifications/progress", "progress",
           "notifications/message", "message",
           "$/cancelRequest", "$/progress":
        // Notifications don't require a response
        statusCode = 200
        return (200, Data())

      case "tools/list":
        statusCode = 200
        return (200, JSONRPCResponseBuilder.makeResult(id: id, result: ["tools": toolList()]))

      case "tools/call":
        let result = await handleToolCall(id: id, params: params)
        statusCode = result.0
        return result

      default:
        await telemetryProvider.warning("RPC method not found", metadata: ["method": method, "hasId": String(describing: id != nil)])
        // For notifications (id=null), just acknowledge - don't error
        if id == nil {
          statusCode = 200
          return (200, Data())
        }
        statusCode = 400
        return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32601, message: "Method not found"))
      }
    } catch {
      await telemetryProvider.error(error, context: "RPC handling failed", metadata: [:])
      statusCode = 500
      return (500, JSONRPCResponseBuilder.makeError(id: nil, code: -32603, message: error.localizedDescription))
    }
  }

  private func handleToolCall(id: Any?, params: [String: Any]?) async -> (Int, Data) {
    guard let params, let name = params["name"] as? String else {
      await telemetryProvider.warning("Invalid tool call params", metadata: [:])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Invalid params"))
    }

    guard let resolvedName = resolveToolName(name),
          let tool = toolDefinition(named: resolvedName) else {
      await telemetryProvider.warning("Unknown tool", metadata: ["name": name])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32601, message: "Unknown tool"))
    }

    if tool.requiresForeground && !allowForegroundTools {
      await telemetryProvider.warning("Foreground tool disabled", metadata: ["name": resolvedName])
      lastBlockedTool = resolvedName
      lastBlockedToolAt = Date()
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32010, message: "Tool disabled in headless mode"))
    }

    lastToolRequiresForeground = tool.requiresForeground
    lastToolRequiresForegroundAt = Date()

    if tool.requiresForeground && !NSApp.isActive {
      await telemetryProvider.warning("Foreground tool called while app inactive", metadata: ["name": tool.name])
      recordUIActionForegroundNeeded(tool.name)
    }

    if !isToolEnabled(resolvedName) {
      await telemetryProvider.warning("Tool disabled", metadata: ["name": resolvedName, "category": tool.category.rawValue])
      lastBlockedTool = resolvedName
      lastBlockedToolAt = Date()
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32010, message: "Tool disabled"))
    }

    let arguments = params["arguments"] as? [String: Any] ?? [:]

    // Delegate to extracted tool handlers first
    if uiToolsHandler.supportedTools.contains(resolvedName) {
      return await uiToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if vmToolsHandler.supportedTools.contains(resolvedName) {
      return await vmToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if parallelToolsHandler.supportedTools.contains(resolvedName) {
      return await parallelToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if ragToolsHandler?.supportedTools.contains(resolvedName) == true {
      return await ragToolsHandler!.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if codeEditToolsHandler?.supportedTools.contains(resolvedName) == true {
      return await codeEditToolsHandler!.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if chainToolsHandler?.supportedTools.contains(resolvedName) == true {
      return await chainToolsHandler!.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if swarmToolsHandler.supportedTools.contains(resolvedName) {
      return await swarmToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if repoToolsHandler.supportedTools.contains(resolvedName) {
      return await repoToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if worktreeToolsHandler.supportedTools.contains(resolvedName) {
      return await worktreeToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if githubToolsHandler?.supportedTools.contains(resolvedName) == true {
      return await githubToolsHandler!.handle(name: resolvedName, id: id, arguments: arguments)
    }
    if terminalToolsHandler.supportedTools.contains(resolvedName) {
      return await terminalToolsHandler.handle(name: resolvedName, id: id, arguments: arguments)
    }

    // Fall through to inline handlers (to be extracted in future)
    switch resolvedName {
    // UI tools are now handled by UIToolsHandler above

    case "state.get":
      return handleStateGet(id: id)

    case "state.readonly":
      return handleStateGet(id: id)

    case "state.list":
      return handleStateList(id: id)

    // RAG tools are now handled by RAGToolsHandler above
    // Chain tools are now handled by ChainToolsHandler above

    case "workspaces.agent.list":
      return handleAgentWorkspacesList(id: id, arguments: arguments)

    case "workspaces.agent.cleanup.status":
      return handleAgentWorkspacesCleanupStatus(id: id)

    case "logs.mcp.path":
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["path": await telemetryProvider.logPath()]))

    case "logs.mcp.tail":
      let lines = arguments["lines"] as? Int ?? 200
      let text = await telemetryProvider.tail(lines: lines)
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["text": text]))

    // VM tools are now handled by VMToolsHandler above

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

    case "server.lan":
      return handleServerLanModeSet(id: id, arguments: arguments)

    case "server.stop":
      stop()
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["status": "stopped"]))

    case "app.quit":
      scheduleAppQuit()
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["status": "quitting"]))

    case "app.activate":
      activateApp()
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["status": "activated"]))

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
        return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["path": url.path]))
      } catch {
        await telemetryProvider.warning("Screenshot tool failed", metadata: ["error": error.localizedDescription])
        return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
      }

    case "translations.validate":
      return await handleTranslationsValidate(id: id, arguments: arguments)

    case "docling.convert":
      return await handleDoclingConvert(id: id, arguments: arguments)

    case "docling.setup":
      return await handleDoclingSetup(id: id, arguments: arguments)

    case "pii.scrub":
      return await handlePIIScrub(id: id, arguments: arguments)

    // Parallel tools are now handled by ParallelToolsHandler

    default:
      await telemetryProvider.warning("Unknown tool", metadata: ["name": name])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32601, message: "Unknown tool"))
    }
  }

  // UI tool handlers moved to UIToolsHandler.swift (#158)

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
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: state))
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
    let toolForegroundByName = Dictionary(uniqueKeysWithValues: activeToolDefinitions.map { tool in
      (tool.name, tool.requiresForeground)
    })
    let toolGroupsByName = Dictionary(uniqueKeysWithValues: activeToolDefinitions.map { tool in
      (tool.name, groups(for: tool).map { $0.rawValue })
    })
    let state: [String: Any] = [
      "views": availableViewIds(),
      "tools": activeToolDefinitions.map { $0.name },
      "controls": controls,
      "controlsByView": controlsByView,
      "controlValuesByView": controlValuesByView,
      "toolRequiresForeground": toolForegroundByName,
      "toolGroups": toolGroupsByName,
      "toolGroupList": toolGroups.map { $0.rawValue },
      "currentViewId": currentViewId as Any
    ]
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: state))
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
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing root"))
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
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
        "report": encodeJSON(report),
        "summary": encodeJSON(summary)
      ]))
    } catch {
      await telemetryProvider.warning("Translation validation failed", metadata: ["error": error.localizedDescription])
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  // VM tool handlers moved to VMToolsHandler.swift (#161)

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
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing inputPath"))
    }
    guard let outputPath, !outputPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing outputPath"))
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
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: payload))
    } catch {
      await telemetryProvider.warning("PII scrubber failed", metadata: ["error": error.localizedDescription])
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleDoclingConvert(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let inputPath = (arguments["inputPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let outputPath = (arguments["outputPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let pythonPath = (arguments["pythonPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let scriptPath = (arguments["scriptPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let profile = (arguments["profile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let includeText = arguments["includeText"] as? Bool ?? false
    let maxChars = arguments["maxChars"] as? Int ?? 20000

    guard let inputPath, !inputPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing inputPath"))
    }
    guard let outputPath, !outputPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing outputPath"))
    }

    let options = DoclingService.Options(
      inputPath: inputPath,
      outputPath: outputPath,
      pythonPath: pythonPath,
      scriptPath: scriptPath,
      profile: profile
    )

    do {
      let result = try await doclingService.runConvert(options: options)
      var payload: [String: Any] = [
        "inputPath": result.inputPath,
        "outputPath": result.outputPath,
        "bytesWritten": result.bytesWritten,
        "pythonPath": result.pythonPath,
        "scriptPath": result.scriptPath
      ]
      if let profile, !profile.isEmpty {
        payload["profile"] = profile
      }
      if includeText {
        let maxLength = max(1, maxChars)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: result.outputPath)),
           let text = String(data: data, encoding: .utf8) {
          payload["text"] = String(text.prefix(maxLength))
          payload["textTruncated"] = text.count > maxLength
        }
      }
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: payload))
    } catch {
      await telemetryProvider.warning("Docling conversion failed", metadata: ["error": error.localizedDescription])
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  private func handleDoclingSetup(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let pythonPath = (arguments["pythonPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      let result = try await doclingService.ensureDoclingInstalled(pythonPath: pythonPath)
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
        "pythonPath": result.pythonPath,
        "log": result.log
      ]))
    } catch {
      await telemetryProvider.warning("Docling setup failed", metadata: ["error": error.localizedDescription])
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: error.localizedDescription))
    }
  }

  // Parallel tool handlers moved to ParallelToolsHandler.swift (#162)
  // RAG tool handlers moved to RAGToolsHandler.swift

  private func encodeJSON<T: Encodable>(_ value: T) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object
  }

  // MARK: - Chain Handler Methods (Internal)
  // Note: These methods are kept for internal use by rerun() and handleChainRunBatch().
  // MCP routing goes through ChainToolsHandler; these are internal helpers.

  private func handleChainRunStatus(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing or invalid runId"))
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
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
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
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
    }

    if let completed = completedRunsById[runId] {
      let result: [String: Any] = [
        "runId": runIdString,
        "status": "completed",
        "completedAt": formatter.string(from: completed.completedAt),
        "result": completed.payload
      ]
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
    }

    return (404, JSONRPCResponseBuilder.makeError(id: id, code: -32004, message: "Run not found"))
  }

  private func handleChainRunList(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let dataService else {
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: "Run history unavailable"))
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
        return (404, JSONRPCResponseBuilder.makeError(id: id, code: -32004, message: "Run not found"))
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

    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["runs": payload]))
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

    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["workspaces": workspaces]))
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

    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
  }

  func handleChainRun(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let rawPrompt = arguments["prompt"] as? String else {
      await telemetryProvider.warning("chains.run missing prompt", metadata: [:])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing prompt"))
    }

    let runId = UUID()
    if activeChainRuns >= maxConcurrentChains, chainQueue.count >= maxQueuedChains {
      await telemetryProvider.warning("Chain queue full", metadata: ["runId": runId.uuidString])
      return (429, JSONRPCResponseBuilder.makeError(id: id, code: -32000, message: "Chain queue is full"))
    }

    let templateId = arguments["templateId"] as? String
    let templateName = arguments["templateName"] as? String
    let chainSpec = arguments["chainSpec"] as? [String: Any]
    let workingDirectory = arguments["workingDirectory"] as? String
    let enableReviewLoop = arguments["enableReviewLoop"] as? Bool
    let pauseOnReview = arguments["pauseOnReview"] as? Bool
    let enablePrePlanner = arguments["enablePrePlanner"] as? Bool  // Issue #133
    let allowPlannerModelSelection = arguments["allowPlannerModelSelection"] as? Bool ?? false
    let allowImplementerModelOverride = arguments["allowImplementerModelOverride"] as? Bool ?? false
    let allowPlannerImplementerScaling = arguments["allowPlannerImplementerScaling"] as? Bool ?? false
    let maxImplementers = arguments["maxImplementers"] as? Int
    let maxPremiumCost = arguments["maxPremiumCost"] as? Double
    let priority = arguments["priority"] as? Int ?? 0
    let timeoutSeconds = arguments["timeoutSeconds"] as? Double
    let returnImmediately = arguments["returnImmediately"] as? Bool ?? false
    let keepWorkspace = arguments["keepWorkspace"] as? Bool ?? false
    let requireRagUsage = arguments["requireRagUsage"] as? Bool ?? promptRules.requireRagByDefault

    let (enqueuedAt, wasCancelled, queuePosition) = await acquireChainRunSlot(runId: runId, priority: priority)
    if wasCancelled {
      await telemetryProvider.warning("Queued chain cancelled", metadata: ["runId": runId.uuidString])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32005, message: "Queued run cancelled"))
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
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: message))
    }

    var chainWorkspace: AgentWorkspace?
    var chainWorkingDirectory = workingDirectory ?? agentManager.lastUsedWorkingDirectory
    if chainWorkingDirectory == nil {
      await telemetryProvider.warning("chains.run missing workingDirectory", metadata: ["runId": runId.uuidString])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing workingDirectory"))
    }
    if let workingDirectory = chainWorkingDirectory {
      let repoURL = URL(fileURLWithPath: workingDirectory)
      let repository = Model.Repository(name: repoURL.lastPathComponent, path: workingDirectory)
      let task = AgentTask(
        title: "MCP Chain: \(template.name)",
        prompt: rawPrompt,
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
    if let enablePrePlanner {
      chain.enablePrePlanner = enablePrePlanner
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

    // Apply prompt rules and guardrails
    let initialOptions = AgentChainRunner.ChainRunOptions(
      allowPlannerModelSelection: allowPlannerModelSelection,
      allowImplementerModelOverride: allowImplementerModelOverride,
      allowPlannerImplementerScaling: allowPlannerImplementerScaling,
      maxImplementers: maxImplementers,
      maxPremiumCost: maxPremiumCost
    )
    let (prompt, runOptions) = applyPromptRules(
      prompt: rawPrompt,
      templateName: template.name,
      options: initialOptions
    )

    await telemetryProvider.info("Chain run started", metadata: [
      "runId": runId.uuidString,
      "template": template.name,
      "workingDirectory": chainWorkingDirectory ?? "",
      "queued": enqueuedAt == nil ? "false" : "true",
      "promptRulesApplied": !promptRules.globalPrefix.isEmpty || promptRules.perTemplateOverrides[template.name] != nil ? "true" : "false"
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
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
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

    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
  }

  private func handleChainRunBatch(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runs = arguments["runs"] as? [[String: Any]], !runs.isEmpty else {
      await telemetryProvider.warning("chains.runBatch missing runs", metadata: [:])
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing runs"))
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
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: response))
  }

  private func handleChainStop(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let runIdString = arguments["runId"] as? String
    let cancelAll = arguments["all"] as? Bool ?? false

    if cancelAll {
      let runIds = Array(activeChainTasks.keys)
      runIds.forEach { activeChainTasks[$0]?.cancel() }
      await telemetryProvider.warning("Chain cancellation requested", metadata: ["runIds": runIds.map { $0.uuidString }.joined(separator: ",")])
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["cancelled": runIds.map { $0.uuidString }]))
    }

    guard let runIdString, let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let task = activeChainTasks[runId] else {
      return (404, JSONRPCResponseBuilder.makeError(id: id, code: -32004, message: "Run not found"))
    }

    task.cancel()
    await telemetryProvider.warning("Chain cancellation requested", metadata: ["runId": runId.uuidString])
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["cancelled": [runId.uuidString]]))
  }

  private func handleChainPause(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    await chainRunner.pause(chainId: chain.id)
    await telemetryProvider.info("Chain paused", metadata: ["runId": runId.uuidString])
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["paused": runId.uuidString]))
  }

  private func handleChainResume(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    await chainRunner.resume(chainId: chain.id)
    await telemetryProvider.info("Chain resumed", metadata: ["runId": runId.uuidString])
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["resumed": runId.uuidString]))
  }

  private func handleChainInstruct(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    guard let guidance = arguments["guidance"] as? String else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing guidance"))
    }

    chain.addOperatorGuidance(guidance)
    await telemetryProvider.info("Chain guidance injected", metadata: [
      "runId": runId.uuidString,
      "guidanceLength": "\(guidance.count)"
    ])
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["runId": runId.uuidString, "guidanceCount": chain.operatorGuidance.count]))
  }

  private func handleChainStep(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString),
          let chain = activeRunChains[runId] else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    await chainRunner.step(chainId: chain.id)
    await telemetryProvider.info("Chain step", metadata: ["runId": runId.uuidString])
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["step": runId.uuidString]))
  }

  private func handleServerRestart(id: Any?) async -> (Int, Data) {
    stop()
    start()
    await waitForServerStart()

    if isRunning {
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["running": true, "port": port]))
    }

    return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32001, message: lastError ?? "Failed to restart server"))
  }

  private func handleServerPortSet(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let requestedPort = arguments["port"] as? Int else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing port"))
    }

    let autoFind = arguments["autoFind"] as? Bool ?? false
    let maxAttempts = arguments["maxAttempts"] as? Int ?? 25

    let targetPort: Int
    if autoFind, !canBind(port: requestedPort) {
      guard let available = findAvailablePort(startingAt: requestedPort, maxAttempts: maxAttempts) else {
        return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32002, message: "No available port found"))
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
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["running": true, "port": port]))
    }

    return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32003, message: lastError ?? "Failed to bind to port"))
  }

  private func handleServerStatus(id: Any?) -> (Int, Data) {
    let status: [String: Any] = [
      "enabled": isEnabled,
      "running": isRunning,
      "port": port,
      "lastError": lastError as Any,
      "sleepPreventionEnabled": sleepPreventionEnabled,
      "sleepPreventionActive": sleepPreventionAssertionId != nil,
      "lanModeEnabled": lanModeEnabled
    ]
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: status))
  }
  
  private func handleServerLanModeSet(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let enabled = arguments["enabled"] as? Bool else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing enabled flag"))
    }

    lanModeEnabled = enabled
    var result: [String: Any] = ["lanModeEnabled": lanModeEnabled]
    if enabled {
      result["warning"] = "LAN mode enabled - MCP server accepts connections from any device on the network. Only use on trusted networks."
    }
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
  }

  private func handleServerSleepPreventionSet(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let enabled = arguments["enabled"] as? Bool else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing enabled flag"))
    }

    sleepPreventionEnabled = enabled
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
      "enabled": sleepPreventionEnabled,
      "active": sleepPreventionAssertionId != nil
    ]))
  }

  private func handleServerSleepPreventionStatus(id: Any?) -> (Int, Data) {
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
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

  private func queueStatusDict() -> [String: Any] {
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

  func cancelQueuedRunInternal(runId: UUID) -> Bool {
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
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: queueStatusDict()))
  }

  private func handleQueueCancel(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Missing or invalid runId"))
    }

    if cancelQueuedRunInternal(runId: runId) {
      await telemetryProvider.warning("Queued chain cancelled", metadata: ["runId": runId.uuidString])
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["cancelled": runId.uuidString]))
    }

    return (404, JSONRPCResponseBuilder.makeError(id: id, code: -32004, message: "Queued run not found"))
  }

  // MARK: - Prompt Rules Handlers

  private func handlePromptRulesGet(id: Any?) -> (Int, Data) {
    var overrides: [String: [String: Any]] = [:]
    for (templateName, override) in promptRules.perTemplateOverrides {
      var dict: [String: Any] = [:]
      if let prefix = override.promptPrefix { dict["promptPrefix"] = prefix }
      if let model = override.enforcePlannerModel { dict["enforcePlannerModel"] = model }
      if let cost = override.maxPremiumCost { dict["maxPremiumCost"] = cost }
      if let rag = override.requireRag { dict["requireRag"] = rag }
      overrides[templateName] = dict
    }

    let result: [String: Any] = [
      "globalPrefix": promptRules.globalPrefix,
      "enforcePlannerModel": promptRules.enforcePlannerModel as Any,
      "maxPremiumCostDefault": promptRules.maxPremiumCostDefault as Any,
      "requireRagByDefault": promptRules.requireRagByDefault,
      "perTemplateOverrides": overrides
    ]
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
  }

  private func handlePromptRulesSet(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    var rules = promptRules

    if let globalPrefix = arguments["globalPrefix"] as? String {
      rules.globalPrefix = globalPrefix
    }
    if let enforcePlannerModel = arguments["enforcePlannerModel"] as? String {
      rules.enforcePlannerModel = enforcePlannerModel.isEmpty ? nil : enforcePlannerModel
    }
    if let maxPremiumCostDefault = arguments["maxPremiumCostDefault"] as? Double {
      rules.maxPremiumCostDefault = maxPremiumCostDefault
    }
    if let requireRagByDefault = arguments["requireRagByDefault"] as? Bool {
      rules.requireRagByDefault = requireRagByDefault
    }
    if let overrides = arguments["perTemplateOverrides"] as? [String: [String: Any]] {
      for (templateName, overrideDict) in overrides {
        var override = rules.perTemplateOverrides[templateName] ?? PromptRules.TemplateOverride()
        if let prefix = overrideDict["promptPrefix"] as? String {
          override.promptPrefix = prefix.isEmpty ? nil : prefix
        }
        if let model = overrideDict["enforcePlannerModel"] as? String {
          override.enforcePlannerModel = model.isEmpty ? nil : model
        }
        if let cost = overrideDict["maxPremiumCost"] as? Double {
          override.maxPremiumCost = cost
        }
        if let rag = overrideDict["requireRag"] as? Bool {
          override.requireRag = rag
        }
        rules.perTemplateOverrides[templateName] = override
      }
    }

    promptRules = rules
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: ["updated": true]))
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

  private func viewTitle(for viewId: String) -> String {
    uiAutomationProvider.viewTitle(for: viewId)
  }


  private func dedupeStrings(_ values: [String]?) -> [String] {
    guard let values else { return [] }
    return Array(Set(values)).sorted()
  }
}

