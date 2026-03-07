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
    static let ragInterruptedIndexingPaths = "localrag.resume.indexingPaths"
    static let ragInterruptedAnalysisPaths = "localrag.resume.analysisPaths"
  }

  // Tool types from MCPCore
  public typealias ToolCategory = MCPToolCategory
  public typealias ToolGroup = MCPToolGroup
  public typealias ToolDefinition = MCPToolDefinition

  public enum RAGSearchMode: String, CaseIterable, Codable {
    case text
    case vector
    /// Runs both text and vector search then merges results via Reciprocal Rank Fusion.
    case hybrid
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
    public let embeddingCount: Int
    public let repoIdentifier: String?
    public let parentRepoId: String?
    /// The embedding model used for this repo's vectors (e.g. "nomic-embed-text-v1.5").
    /// May differ from the local model if embeddings were synced from a peer.
    public let embeddingModel: String?
    /// The actual dimensions of stored embeddings (derived from blob size).
    public let embeddingDimensions: Int?

    public init(id: String, name: String, rootPath: String, lastIndexedAt: Date?, fileCount: Int, chunkCount: Int, embeddingCount: Int = 0, repoIdentifier: String? = nil, parentRepoId: String? = nil, embeddingModel: String? = nil, embeddingDimensions: Int? = nil) {
      self.id = id
      self.name = name
      self.rootPath = rootPath
      self.lastIndexedAt = lastIndexedAt
      self.fileCount = fileCount
      self.chunkCount = chunkCount
      self.embeddingCount = embeddingCount
      self.repoIdentifier = repoIdentifier
      self.parentRepoId = parentRepoId
      self.embeddingModel = embeddingModel
      self.embeddingDimensions = embeddingDimensions
    }

    /// True when this repo has chunks but no embeddings (e.g. synced from a peer with a different model).
    public var needsEmbedding: Bool { chunkCount > 0 && embeddingCount == 0 }
    /// True when some but not all chunks have embeddings.
    public var hasPartialEmbeddings: Bool { embeddingCount > 0 && embeddingCount < chunkCount }
    /// True when embeddings exist but come from a different model than the local one.
    public var hasSyncedEmbeddings: Bool {
      embeddingCount > 0 && embeddingModel != nil
    }
    /// Inferred model name from dimensions when sync metadata isn't available.
    public var inferredEmbeddingModel: String? {
      if let embeddingModel { return embeddingModel }
      guard let dims = embeddingDimensions, embeddingCount > 0 else { return nil }
      switch dims {
      case 1024: return "qwen (1024d)"
      case 768: return "nomic (768d)"
      case 384: return "MiniLM (384d)"
      default: return "unknown (\(dims)d)"
      }
    }
    /// True when stored embeddings have different dimensions than the local model.
    public var hasDimensionMismatch: Bool {
      // Can't compare without knowing current local dims in this model.
      // Caller performs mismatch checks against live ragStatus instead.
      return false // placeholder, checked externally
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

  public var isRunning: Bool = false
  public var lastError: String?
  public var activeRequests: Int = 0
  public var lastRequestMethod: String?
  public var lastRequestAt: Date?
  public var lastBlockedTool: String?
  public var lastBlockedToolAt: Date?
  public var lastToolRequiresForeground: Bool?
  public var lastToolRequiresForegroundAt: Date?
  public var lastUIActionHandled: String? { uiAutomationProvider.lastUIActionHandled }
  public var lastUIActionHandledAt: Date? { uiAutomationProvider.lastUIActionHandledAt }
  public var recentUIActions: [UIActionRecord] { uiAutomationProvider.recentUIActions }
  public var isAppActive: Bool {
    NSApp.isActive
  }

  public var isAppFrontmost: Bool {
    NSApp.keyWindow?.isKeyWindow ?? false
  }
  public var isCleaningAgentWorkspaces: Bool = false
  public var lastCleanupAt: Date?
  public var lastCleanupSummary: String?
  public var lastCleanupError: String?
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

  func saveRagUsageStats() {
    guard let data = try? JSONEncoder().encode(ragUsage) else { return }
    config.set(data, forKey: StorageKey.ragUsageStats)
  }

  func saveRagSessionEvents() {
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

  var ragStatus: LocalRAGStore.Status?
  var ragStats: LocalRAGStore.Stats?
  var ragUsage = RAGUsageStats()

  // MARK: - Interrupted operation resume

  /// Repo paths that were mid-index when the app last quit. Persisted so we can resume on launch.
  var interruptedIndexingPaths: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: StorageKey.ragInterruptedIndexingPaths) ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: StorageKey.ragInterruptedIndexingPaths) }
  }

  /// Repo paths that were mid-analysis when the app last quit. Persisted so cards can auto-resume.
  var interruptedAnalysisPaths: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: StorageKey.ragInterruptedAnalysisPaths) ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: StorageKey.ragInterruptedAnalysisPaths) }
  }

  func markIndexingStarted(path: String) {
    var paths = interruptedIndexingPaths
    paths.insert(path)
    interruptedIndexingPaths = paths
  }

  func markIndexingStopped(path: String) {
    var paths = interruptedIndexingPaths
    paths.remove(path)
    interruptedIndexingPaths = paths
  }

  func markAnalysisStarted(repoPath: String) {
    var paths = interruptedAnalysisPaths
    paths.insert(repoPath)
    interruptedAnalysisPaths = paths
  }

  func markAnalysisStopped(repoPath: String) {
    var paths = interruptedAnalysisPaths
    paths.remove(repoPath)
    interruptedAnalysisPaths = paths
  }

  /// Called on launch to resume any indexing or analysis that was interrupted by app quit.
  func resumeInterruptedRAGOperations() async {
    let indexPaths = interruptedIndexingPaths
    guard !indexPaths.isEmpty || !interruptedAnalysisPaths.isEmpty else { return }

    if !indexPaths.isEmpty {
      print("[RAG Resume] Resuming indexing for \(indexPaths.count) repo(s): \(indexPaths)")
      for path in indexPaths {
        guard FileManager.default.fileExists(atPath: path) else {
          markIndexingStopped(path: path)
          continue
        }
        do {
          try await indexRagRepo(path: path)
        } catch {
          print("[RAG Resume] Indexing failed for \(path): \(error)")
          // Clear the interrupted marker so we don't retry on every launch
          // (prevents crash loops if the embedding model can't load)
          markIndexingStopped(path: path)
        }
      }
    }

    // Analysis paths are consumed by RAGRepositoryCardView.onAppear — no action needed here,
    // but log so it's visible in the console.
    let analysisPaths = interruptedAnalysisPaths
    if !analysisPaths.isEmpty {
      print("[RAG Resume] \(analysisPaths.count) repo(s) will auto-resume analysis when their cards appear: \(analysisPaths)")
    }
  }
  var ragSessionEvents: [RAGSessionEvent] = []
  var ragQueryHints: [RAGQueryHint] = []
  var ragRepos: [RAGRepoInfo] = []
  /// Tracks the embedding model used for each repo (by repoIdentifier) when synced from a peer.
  /// Populated from import results; persists across refreshes.
  var ragSyncedEmbeddingModels: [String: String] = [:]
  var ragIndexingPath: String?
  var ragIndexProgress: LocalRAGIndexProgress?
  var ragIndexingTask: Task<LocalRAGIndexReport, Error>?
  var lastRagIndexReport: LocalRAGIndexReport?
  var lastRagIndexAt: Date?
  var lastRagRefreshAt: Date?
  var lastRagError: String?
  var ragArtifactStatus: RAGArtifactStatus?
  var ragArtifactSyncError: String?
  var lastRagSearchQuery: String?
  var lastRagSearchMode: RAGSearchMode?
  var lastRagSearchRepoPath: String?
  var lastRagSearchLimit: Int?
  var lastRagSearchAt: Date?
  var lastRagSearchResults: [LocalRAGSearchResult] = []
  
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
  let screenshotService = ScreenshotService()
  let translationValidatorService = TranslationValidatorService()
  let piiScrubberService = PIIScrubberService()
  let doclingService = DoclingService()
  let vmIsolationService: VMIsolationService
  @ObservationIgnored private var cachedLocalRagStore: LocalRAGStore?
  var localRagStore: LocalRAGStore {
    get {
      if let cachedLocalRagStore {
        return cachedLocalRagStore
      }
      let store = makeDefaultRAGStore()
      cachedLocalRagStore = store
      return store
    }
    set {
      cachedLocalRagStore = newValue
    }
  }
  var parallelWorktreeRunner: ParallelWorktreeRunner?

  // MARK: - Tool Handlers (extracted from this file for maintainability)

  var uiToolsHandler: UIToolsHandler
  var vmToolsHandler: VMToolsHandler
  var parallelToolsHandler: ParallelToolsHandler
  var ragToolsHandler: RAGToolsHandler?
  var codeEditToolsHandler: CodeEditToolsHandler?
  var chainToolsHandler: ChainToolsHandler?
  var swarmToolsHandler: SwarmToolsHandler
  var repoToolsHandler: RepoToolsHandler
  var worktreeToolsHandler: WorktreeToolsHandler
  var githubToolsHandler: GitHubToolsHandler?
  var terminalToolsHandler: TerminalToolsHandler
  var gitToolsHandler: GitToolsHandler
  var codeQualityToolsHandler: CodeQualityToolsHandler
  var chromeToolsHandler: ChromeToolsHandler
  var repoProfileToolsHandler: RepoProfileToolsHandler
  var repoProfileService: RepoProfileService
  var prReviewQueue = PRReviewQueue()
  var prReviewToolsHandler: PRReviewToolsHandler
  var uxTestOrchestrator: UXTestOrchestrator?
  #if os(macOS)
  var localChatToolsHandler: LocalChatToolsHandler?
  var chatSession = SharedChatSession()
  #endif

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

  let listenerQueue = DispatchQueue(label: "MCPServer.Listener")
  var listener: NWListener?
  var connections: [UUID: NWConnection] = [:]
  var connectionStates: [UUID: ConnectionState] = [:]
  var sleepPreventionAssertionId: IOPMAssertionID?
  let permissionsStore: MCPToolPermissionsProviding
  let config: MCPServerConfigProviding
  public var permissionsVersion: Int = 0

  struct ConnectionState {
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
    self.gitToolsHandler = GitToolsHandler()
    self.codeQualityToolsHandler = CodeQualityToolsHandler()
    self.chromeToolsHandler = ChromeToolsHandler()
    self.repoProfileToolsHandler = RepoProfileToolsHandler()
    self.repoProfileService = RepoProfileService()
    self.prReviewToolsHandler = PRReviewToolsHandler()
    #if os(macOS)
    self.localChatToolsHandler = LocalChatToolsHandler()
    #endif

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
      telemetryProvider: resolvedTelemetry,
      vmIsolationService: vmIsolationService
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

    // Initialize UX test orchestrator for Chrome-based parallel UX testing
    let orchestrator = UXTestOrchestrator()
    self.uxTestOrchestrator = orchestrator
    self.chromeToolsHandler.orchestrator = orchestrator
    self.parallelWorktreeRunner?.setUXTestOrchestrator(orchestrator)
    self.parallelWorktreeRunner?.setRepoProfileService(repoProfileService)

    wireToolHandlerDelegates()

    #if os(macOS)
    self.localChatToolsHandler?.chatSession = self.chatSession
    #endif

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

  private func wireToolHandlerDelegates() {
    uiToolsHandler.delegate = self
    parallelToolsHandler.delegate = self
    ragToolsHandler?.delegate = self
    codeEditToolsHandler?.delegate = self
    chainToolsHandler?.delegate = self
    swarmToolsHandler.delegate = self
    repoToolsHandler.delegate = self
    worktreeToolsHandler.delegate = self
    githubToolsHandler?.delegate = self
    terminalToolsHandler.delegate = self
    codeQualityToolsHandler.delegate = self
    chromeToolsHandler.delegate = self
    repoProfileToolsHandler.delegate = self
    repoProfileToolsHandler.profileService = repoProfileService
    prReviewToolsHandler.delegate = self
    prReviewToolsHandler.prReviewQueue = prReviewQueue
    #if os(macOS)
    localChatToolsHandler?.delegate = self
    localChatToolsHandler?.mcpServer = self
    #endif
    SwarmCoordinator.shared.ragSyncDelegate = self
    RAGSyncCoordinator.shared.ragSyncDelegate = self
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
      localChatToolsHandler?.dataService = dataService
    }
    if prReviewQueue.modelContext == nil {
      prReviewQueue.modelContext = modelContext
    }
  }

  public func refreshRagSummary() async {
    do {
      let status = await localRagStore.status()
      let stats = try await localRagStore.stats()
      let repos = try await localRagStore.listRepos()
      ragStatus = status
      ragStats = stats
      let embeddingCounts = await localRagStore.embeddingCountsByRepo()
      let embeddingDims = await localRagStore.embeddingDimensionsByRepo()

      // Build a lookup: embedding dimensions → known model name.
      // This lets us infer the model for repos where embedding_model is NULL
      // but we have sibling repos with the same dimensions and a known model.
      var modelByDims: [Int: String] = [:]
      for repo in repos {
        if let model = repo.embeddingModel, !model.isEmpty,
           let dims = repo.embeddingDimensions ?? embeddingDims[repo.id] {
          modelByDims[dims] = model
        }
      }

      ragRepos = repos.map { repo in
        // Prefer the embedding model stored in the DB (written during indexing or sync import).
        // Fall back to in-memory ragSyncedEmbeddingModels dict for backwards compatibility
        // (populated during this session's sync operations, lost on restart).
        // Final fallback: infer model from embedding dimensions using sibling repos.
        let dbModel = repo.embeddingModel
        let syncedModelFallback: String? = {
          if dbModel != nil { return nil } // DB has it, no need for fallback
          if let identifier = repo.repoIdentifier, let model = ragSyncedEmbeddingModels[identifier] {
            return model
          }
          return ragSyncedEmbeddingModels[repo.id]
        }()
        let effectiveDims = repo.embeddingDimensions ?? embeddingDims[repo.id]
        let dimsInferredModel: String? = {
          if dbModel != nil || syncedModelFallback != nil { return nil }
          guard let dims = effectiveDims else { return nil }
          return modelByDims[dims]
        }()
        let effectiveModel = dbModel ?? syncedModelFallback ?? dimsInferredModel
        return RAGRepoInfo(
          id: repo.id,
          name: repo.name,
          rootPath: repo.rootPath,
          lastIndexedAt: repo.lastIndexedAt,
          fileCount: repo.fileCount,
          chunkCount: repo.chunkCount,
          embeddingCount: embeddingCounts[repo.id] ?? 0,
          repoIdentifier: repo.repoIdentifier,
          parentRepoId: repo.parentRepoId,
          embeddingModel: effectiveModel,
          embeddingDimensions: effectiveDims
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

  func scheduleAppQuit() {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      NSApp.terminate(nil)
    }
  }

  func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
  }

  func templateList() -> [[String: Any]] {
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

  func summarizeResults(_ results: [AgentChainResult]) -> [[String: Any]] {
    let formatter = Formatter.iso8601
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

  func parseChainSpec(_ spec: [String: Any]) -> ChainTemplate? {
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

      // Parse step type (defaults to .agentic for backward compatibility)
      let stepTypeValue = (step["stepType"] as? String) ?? "agentic"
      let stepType = StepType(rawValue: stepTypeValue) ?? .agentic

      // Parse command for deterministic/gate steps
      let command = step["command"] as? String

      // Parse per-step tool scoping
      let allowedTools = step["allowedTools"] as? [String]
      let deniedTools = step["deniedTools"] as? [String]

      return AgentStepTemplate(
        role: role,
        model: model,
        name: stepName?.isEmpty == false ? stepName! : role.displayName,
        frameworkHint: frameworkHint,
        customInstructions: customInstructions,
        stepType: stepType,
        command: command,
        allowedTools: allowedTools,
        deniedTools: deniedTools
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

  func sendHTTPResponse(status: Int, body: Data, on connection: NWConnection) {
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

  func viewTitle(for viewId: String) -> String {
    uiAutomationProvider.viewTitle(for: viewId)
  }


  func dedupeStrings(_ values: [String]?) -> [String] {
    guard let values else { return [] }
    return Array(Set(values)).sorted()
  }
}

