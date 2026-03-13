// SwarmCoordinator.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// Coordinates the distributed swarm - manages workers and task dispatch.
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │  ARCHITECTURE INVARIANT — DO NOT CHANGE WITHOUT OWNER APPROVAL     │
// │                                                                     │
// │  Firestore is the SOLE coordination & signaling layer for:          │
// │    • Task dispatch (submitTask → task queue → worker claims)        │
// │    • Worker status & heartbeats                                     │
// │    • Member management & permissions                                │
// │    • Task results & completion                                      │
// │    • Direct commands & update-workers                               │
// │    • WebRTC SDP signaling (offers, answers, ICE candidates)         │
// │    • All cross-network communication                                │
// │                                                                     │
// │  P2P (TCP direct / WebRTC data channel) is ONLY for:               │
// │    • Large file transfers (RAG artifacts/embeddings)                 │
// │    • Nothing else. Zero. Nada.                                      │
// │                                                                     │
// │  🚫 NO DATA THROUGH FIRESTORE — EVER:                              │
// │    • FirestoreRelayTransfer is DEPRECATED — do NOT use as fallback  │
// │    • Transfer pipeline: TCP LAN → TCP WAN → WebRTC → FAIL          │
// │    • If P2P fails, fix P2P — don't route data through Firestore    │
// │                                                                     │
// │  If you are adding a feature that sends status, commands, tasks,    │
// │  or coordination messages: USE FIRESTORE, not P2P.                  │
// │  If you are transferring large binary data: USE P2P ONLY.           │
// │                                                                     │
// │  connectedWorkers (TCP peers) must NEVER be a prerequisite for      │
// │  task dispatch, direct commands, or worker updates.                  │
// └─────────────────────────────────────────────────────────────────────┘
//

import Foundation
import FirebaseFirestore
import Network
import SwiftData
import WebRTCTransfer
import os.log

// MARK: - Swarm Mode

/// The role of this Peel instance in the swarm
public enum SwarmRole: String, Sendable {
  case brain     // Coordinates work, dispatches tasks
  case worker    // Executes tasks, reports back
  case hybrid    // Both brain and worker
}

// MARK: - Swarm Event

/// Events emitted by the swarm coordinator
public enum SwarmEvent: Sendable {
  case workerConnected(ConnectedPeer)
  case workerDisconnected(String)
  case taskReceived(ChainRequest)
  case taskStarted(UUID)
  case taskCompleted(ChainResult)
  case taskFailed(UUID, Error)
}

// MARK: - Swarm Delegate

/// Delegate for swarm events
@MainActor
public protocol SwarmCoordinatorDelegate: AnyObject {
  func swarmCoordinator(_ coordinator: SwarmCoordinator, didEmit event: SwarmEvent)
  func swarmCoordinator(_ coordinator: SwarmCoordinator, shouldExecute request: ChainRequest) -> Bool
}

// MARK: - Swarm Coordinator

/// Main coordinator for distributed Peel swarm
@MainActor
@Observable
public final class SwarmCoordinator {
  
  /// Shared instance for app-wide access
  public static let shared = SwarmCoordinator()
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "SwarmCoordinator")

  private struct SenderTransferKey: Hashable {
    let id: UUID
    let peerId: String
  }
  
  // MARK: - Public State
  
  /// Our role in the swarm (set when starting)
  public private(set) var role: SwarmRole = .worker
  
  /// Our capabilities
  public private(set) var capabilities: WorkerCapabilities = WorkerCapabilities.current()
  
  /// Whether the swarm is active
  public private(set) var isActive = false
  
  /// Connected workers (for brain mode)
  public private(set) var connectedWorkers: [ConnectedPeer] = []

  /// Bumped each time the Firestore worker snapshot changes.
  /// SwiftUI views access this to observe `allOnDemandWorkers` changes
  /// (FirebaseService is not @Observable, so computed properties that read
  /// from it won't trigger view updates on their own).
  public private(set) var firestoreWorkerVersion: Int = 0
  
  /// Current task being executed (for worker mode)
  public private(set) var currentTask: ChainRequest?
  
  /// Tasks completed since start
  public private(set) var tasksCompleted = 0
  
  /// Tasks failed since start
  public private(set) var tasksFailed = 0
  
  /// Completed task results (most recent first, capped at 50)
  public private(set) var completedResults: [ChainResult] = []

  /// Latest status reported by workers (brain/hybrid)
  public private(set) var workerStatuses: [String: WorkerStatus] = [:]

  /// Local RAG artifact status (included in worker heartbeats)
  public private(set) var localRagArtifactStatus: RAGArtifactStatus?

  /// Recent RAG artifact transfers (for UI)
  public private(set) var ragTransfers: [RAGArtifactTransferState] = []
  
  /// Maximum number of results to keep
  private let maxStoredResults = 50
  
  /// Pending direct command waiters (for awaiting results)
  private var pendingDirectCommands: [UUID: AsyncStream<DirectCommandResult>.Continuation] = [:]

  /// Recent message trace for diagnostics (newest first)
  public private(set) var messageTrace: [(date: Date, direction: String, peerId: String, type: String, detail: String)] = []
  private let maxTraceEntries = 80

  private func traceMessage(direction: String, peerId: String, type: String, detail: String = "") {
    messageTrace.insert((date: Date(), direction: direction, peerId: peerId, type: type, detail: detail), at: 0)
    if messageTrace.count > maxTraceEntries {
      messageTrace.removeLast()
    }
  }

  /// Pending incoming RAG artifact transfers
  private var incomingRagTransfers: [UUID: RAGIncomingTransfer] = [:]

  /// Sender-side single-flight guard for RAG transfers.
  /// Prevents duplicate concurrent send pipelines for same transfer+peer.
  private var activeSenderTransfers: Set<SenderTransferKey> = []

  /// Waiters waiting for a manifest ack from the receiver before sending chunks.
  /// Keyed by transfer ID. Yields `true` when ack arrives, `false` on timeout fallback.
  private var manifestAckWaiters: [UUID: AsyncStream<Bool>.Continuation] = [:]

  /// Heartbeat loop task (worker/hybrid)
  private var heartbeatTask: Task<Void, Never>?

  /// Heartbeat monitor task (brain/hybrid) - detects stale workers
  private var heartbeatMonitorTask: Task<Void, Never>?

  /// Watchdog task that detects stalled RAG transfers
  private var ragTransferWatchdogTask: Task<Void, Never>?

  /// How long to wait for a chunk before declaring a transfer stalled (seconds)
  private let ragTransferStalledThreshold: TimeInterval = 60

  /// WAN transfers can pause while SCTP buffers drain, but long idle windows hurt reliability.
  /// Keep this higher than LAN while still recovering quickly.
  private let ragTransferStalledThresholdWAN: TimeInterval = 75

  /// How long a transfer can stay queued before watchdog retries/fails it.
  private let ragTransferQueuedThreshold: TimeInterval = 20

  /// Maximum number of automatic resume attempts per transfer
  private let ragTransferMaxRetries = 8

  /// Network path monitor for sleep/wake reconnection
  private var pathMonitor: NWPathMonitor?
  private var lastPathStatus: NWPath.Status = .satisfied

  /// WAN auto-connect task
  private var wanAutoConnectTask: Task<Void, Never>?

  /// LAN reconnect task — retries discovered-but-not-connected Bonjour peers
  private var lanReconnectTask: Task<Void, Never>?

  /// Debounced retry for persistent WebRTC session establishment after Firestore worker updates.
  private var peerSessionRefreshTask: Task<Void, Never>?

  /// Device IDs we've already attempted WAN connection to, with the time of the attempt.
  /// Entries expire after `wanConnectRetryInterval` so we retry periodically.
  private var wanConnectAttempted: [String: Date] = [:]

  /// How long before a failed WAN connection attempt can be retried
  private let wanConnectRetryInterval: TimeInterval = 120  // 2 minutes

  /// Cached WAN address resolved at start — reused on reconnect
  private var resolvedWANAddress: String?

  /// Swarm start time for uptime tracking
  private var startedAt: Date?

  /// Interval between heartbeats
  private let heartbeatInterval: Duration = .seconds(10)

  /// How long before a worker is considered stale (no heartbeat)
  private let heartbeatStaleThreshold: TimeInterval = 35  // ~3 missed heartbeats
  
  /// Result from a direct command execution
  public struct DirectCommandResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let error: String?
  }

  private final class RAGIncomingTransfer: @unchecked Sendable {
    let id: UUID
    let peerId: String
    let direction: RAGArtifactSyncDirection
    let tempURL: URL
    var manifest: RAGArtifactManifest?
    var expectedChunks: Int?
    var receivedChunks = 0
    var receivedBytes = 0
    var fileHandle: FileHandle?
    /// Track which chunk indices have been received (for resume)
    var receivedChunkIndices: Set<Int> = []
    /// Timestamp of last chunk received (for watchdog)
    var lastChunkReceivedAt: Date = Date()
    /// Number of times this transfer has been retried
    var retryCount: Int = 0
    /// The repo and mode that were originally requested (for resume)
    var repoIdentifier: String?
    var transferMode: RAGTransferMode?
    /// Inferred non-final chunk size, used to place out-of-order/resumed chunks at stable offsets.
    var chunkSizeHint: Int?

    init(id: UUID, peerId: String, direction: RAGArtifactSyncDirection, tempURL: URL) {
      self.id = id
      self.peerId = peerId
      self.direction = direction
      self.tempURL = tempURL
    }

    /// Create a checkpoint that can be persisted to disk for resume after disconnect/restart.
    func makeCheckpoint(peerName: String) -> RAGTransferCheckpoint {
      RAGTransferCheckpoint(
        transferId: id,
        peerId: peerId,
        peerName: peerName,
        direction: direction,
        repoIdentifier: repoIdentifier,
        transferMode: transferMode,
        manifest: manifest,
        receivedChunkIndices: receivedChunkIndices,
        receivedBytes: receivedBytes,
        totalBytes: manifest?.totalBytes ?? 0,
        totalChunks: expectedChunks ?? 0,
        tempFilePath: tempURL.path,
        createdAt: Date(),
        lastChunkReceivedAt: lastChunkReceivedAt
      )
    }
  }
  
  /// Discovered peers (for debugging - from Bonjour discovery)
  public var discoveredPeers: [DiscoveredPeer] {
    Array(discoveryService?.discoveredPeers.values ?? [:].values)
  }
  
  // MARK: - Repo Detection
  
  /// Detect the repo path from the running app's bundle location
  /// Works with both direct project builds (/code/repo/build/...) and DerivedData builds
  static func detectRepoPath() -> String? {
    let bundlePath = Bundle.main.bundlePath
    let components = bundlePath.components(separatedBy: "/")
    
    // Strategy 1: Look for "build" folder (standard Xcode project structure)
    if let buildIndex = components.firstIndex(of: "build") {
      let path = components.prefix(buildIndex).joined(separator: "/")
      if FileManager.default.fileExists(atPath: "\(path)/.git") {
        return path
      }
    }
    
    // Strategy 2: Look for DerivedData and search common code locations
     if components.contains("DerivedData"),
       let userIndex = components.firstIndex(of: "Users"),
       userIndex + 1 < components.count {
      let username = components[userIndex + 1]
      let homeDir = "/Users/\(username)"
      // Check common code locations
      for codeDir in ["code", "Code", "Developer", "Projects", "dev", "src", "repos", "git"] {
        let potentialPath = "\(homeDir)/\(codeDir)"
        if FileManager.default.fileExists(atPath: potentialPath) {
          // Look for Peel repo (any historical name)
          for repoName in ["peel", "Peel", "KitchenSink", "kitchen-sync", "kitchen-sink"] {
            let testPath = "\(potentialPath)/\(repoName)"
            if FileManager.default.fileExists(atPath: "\(testPath)/.git") {
              return testPath
            }
          }
        }
      }
      
      // Strategy 3: Use DerivedData path to find package references
      // The Peel.xcodeproj might reference the source via relative paths
      // Check if there's a Package.resolved or project.pbxproj we can parse
      // For now, log the bundle path to help debug
      Logger(subsystem: "com.peel.swarm", category: "SwarmCoordinator")
        .warning("detectRepoPath: Could not find repo. Bundle: \(bundlePath)")
    }
    
    return nil
  }
  
  // MARK: - Private State
  
  /// Discovery service
  private var discoveryService: BonjourDiscoveryService?
  
  /// WebRTC signaling responder (answers incoming transfer offers via Firestore)
  private var webrtcSignalingResponder: WebRTCSignalingResponder?

  /// Persistent WebRTC peer sessions (multipage data channels per peer)
  public private(set) var peerSessionManager = PeerSessionManager()

  /// Active WebRTC mcp channel listen tasks, keyed by peerId
  private var webrtcMCPListenTasks: [String: Task<Void, Never>] = [:]

  /// Active WebRTC transfer channel listen tasks, keyed by peerId
  private var webrtcTransferListenTasks: [String: Task<Void, Never>] = [:]

  /// Monotonically increasing listen-task generation per peer.
  /// Prevents stale listeners from old sessions from tearing down a newly reconnected peer.
  private var webrtcListenGeneration: [String: Int] = [:]

  /// Delegate
  public weak var delegate: SwarmCoordinatorDelegate?

  /// Delegate for RAG artifact syncing
  weak var ragSyncDelegate: RAGArtifactSyncDelegate?
  
  /// Chain executor for worker mode
  private var chainExecutor: ChainExecutorProtocol?
  
  /// Worktree manager for isolated task execution
  private var _worktreeManager: SwarmWorktreeManager?
  private var worktreeManager: SwarmWorktreeManager {
    if _worktreeManager == nil {
      _worktreeManager = SwarmWorktreeManager(modelContext: modelContext)
    }
    return _worktreeManager!
  }

  /// SwiftData context for worktree persistence. Set this before the first task is executed.
  public var modelContext: ModelContext? {
    didSet {
      _worktreeManager?.modelContext = modelContext
      branchQueue.modelContext = modelContext
      prQueue.modelContext = modelContext
    }
  }

  /// Whether to use worktrees for task isolation (default: true)
  public var useWorktreeIsolation: Bool = true
  
  /// Branch queue for tracking in-flight branches (brain/hybrid mode)
  public let branchQueue = BranchQueue()
  
  /// PR queue for creating PRs from completed tasks (brain/hybrid mode)
  public let prQueue = PRQueue()
  
  /// Whether to auto-create PRs for successful swarm tasks
  public var autoCreatePRs: Bool = false
  
  /// Pending task waiters (for async result delivery)
  private var pendingTasks: [UUID: AsyncThrowingStream<ChainResult, Error>.Continuation] = [:]
  
  // MARK: - Initialization
  
  /// Private init for singleton pattern
  private init() {
    // Set up PR queue delegate
    prQueue.delegate = self
  }
  
  /// Configure with a chain executor (for worker mode task execution)
  public func configure(chainExecutor: ChainExecutorProtocol?) {
    self.chainExecutor = chainExecutor
    // Also wire ourselves as the Firestore task execution delegate
    // so Firestore-submitted tasks route through our executor
    if chainExecutor != nil {
      FirebaseService.shared.taskExecutionDelegate = self
    }
  }
  
  /// Get debug info about active worktrees
  public func getWorktreeDebugInfo() -> [String: Any] {
    worktreeManager.getDebugInfo()
  }
  
  // MARK: - Lifecycle
  
  /// Start the swarm coordinator with the given role
  public func start(role: SwarmRole, port: UInt16 = 8766) throws {
    guard !isActive else { return }
    
    self.role = role
    self.capabilities = WorkerCapabilities.current(
      lanAddress: Self.getLocalLANAddress(),
      lanPort: port
    )
    self.startedAt = Date()
    
    // Create and start discovery
    discoveryService = BonjourDiscoveryService()
    discoveryService?.delegate = self
    
    // Start advertising ourselves
    try discoveryService?.startAdvertising(capabilities: capabilities, port: port)
    
    // Start discovering peers
    discoveryService?.startDiscovery()
    
    isActive = true
    logger.info("SwarmCoordinator started as \(self.role.rawValue)")

    if role == .worker || role == .hybrid {
      startHeartbeatLoop()
    }

    if role == .brain || role == .hybrid {
      startHeartbeatMonitor()
    }

    // Monitor network for sleep/wake reconnection
    startNetworkMonitor()
    
    // Start auto-connecting to WAN peers discovered via Firestore
    startWANAutoConnect()

    // Periodically retry LAN peers that were discovered but not connected
    startLANReconnect()

    // Start the RAG sync coordinator for on-demand P2P index sharing
    RAGSyncCoordinator.shared.ragSyncDelegate = ragSyncDelegate
    RAGSyncCoordinator.shared.start()

    // Wire WebRTC session disconnection to connectedWorkers cleanup
    peerSessionManager.onPeerDisconnected = { [weak self] peerId in
      self?.handlePeerDisconnected(peerId)
    }

    // Start WebRTC signaling responder — watches Firestore for incoming
    // WebRTC SDP offers and completes data channel setup
    startWebRTCSignalingResponder()

    // Feed version + relay status into Firestore heartbeats
    configureFirestoreHeartbeatMetadata()

    // Start watchdog for stalled RAG transfers and clean up expired checkpoints
    startRagTransferWatchdog()
    cleanupStaleCheckpoints()
  }

  /// Reinitialize Firestore-dependent subsystems (WebRTC signaling responder)
  /// that require Firebase to be signed in. Call this after Firebase auth is ready
  /// and memberSwarms have been populated — `start()` fires before Firebase is ready
  /// so these subsystems skip initialization on first pass.
  public func reinitializeFirestoreServices() {
    guard isActive else { return }
    if webrtcSignalingResponder == nil {
      logger.info("WebRTC signaling responder: reinitializing (deferred from start)")
      startWebRTCSignalingResponder()
    }

    // Establish persistent WebRTC sessions to known workers
    establishPeerSessions()
  }

  /// Initiate persistent WebRTC sessions with registered Firestore workers.
  /// Called after Firebase auth is ready and the signaling responder is active.
  private func establishPeerSessions() {
    let firebaseService = FirebaseService.shared
    guard firebaseService.isSignedIn,
      role == .brain || role == .hybrid
    else { return }

    let myId = capabilities.deviceId
    let workers = firebaseService.swarmWorkers.filter { $0.id != myId && !$0.isStale }

    guard !workers.isEmpty else {
      logger.info("No online workers to establish sessions with")
      return
    }

    for worker in workers {
      let workerId = worker.id
      // Skip if already connected or connecting
      if peerSessionManager.peerStates[workerId] == .connected
        || peerSessionManager.peerStates[workerId] == .connecting
      { continue }

      // Find a swarm this worker belongs to
      guard let swarmId = firebaseService.memberSwarms.first(where: { $0.role.canRegisterWorkers })?.id else {
        continue
      }

      Task {
        let signaling = FirestoreWebRTCSignaling(
          swarmId: swarmId,
          myDeviceId: myId,
          remoteDeviceId: workerId
        )
        signaling.purpose = "session"
        do {
          try await peerSessionManager.connectToPeer(workerId, signaling: signaling)
          await MainActor.run {
            self.startListeningOnPeerSession(workerId)
            self.registerWebRTCPeerAsConnected(workerId)
          }
          logger.notice("Persistent session established with \(workerId)")
        } catch {
          logger.warning("Failed to establish session with \(workerId): \(error)")
        }
      }
    }
  }

  /// Stop the swarm coordinator
  public func stop() {
    isActive = false

    RAGSyncCoordinator.shared.stop()
    webrtcSignalingResponder?.stop()
    webrtcSignalingResponder = nil
    for (_, task) in webrtcMCPListenTasks { task.cancel() }
    webrtcMCPListenTasks.removeAll()
    for (_, task) in webrtcTransferListenTasks { task.cancel() }
    webrtcTransferListenTasks.removeAll()
    peerSessionRefreshTask?.cancel()
    peerSessionRefreshTask = nil
    Task { await peerSessionManager.disconnectAll() }
    FirebaseService.shared.heartbeatMetadata = nil
    stopNetworkMonitor()
    stopWANAutoConnect()
    stopLANReconnect()
    stopRagTransferWatchdog()
    connectedWorkers.removeAll()
    currentTask = nil
    workerStatuses.removeAll()
    incomingRagTransfers.removeAll()
    ragTransfers.removeAll()
    startedAt = nil
    
    logger.info("SwarmCoordinator stopped")
  }

  // MARK: - Network Monitor (Sleep/Wake Reconnection)

  private func startNetworkMonitor() {
    stopNetworkMonitor()
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor [weak self] in
        self?.handleNetworkPathUpdate(path)
      }
    }
    monitor.start(queue: DispatchQueue(label: "com.peel.network-monitor"))
    pathMonitor = monitor
    lastPathStatus = .satisfied
  }

  private func stopNetworkMonitor() {
    pathMonitor?.cancel()
    pathMonitor = nil
  }

  private func handleNetworkPathUpdate(_ path: NWPath) {
    let previousStatus = lastPathStatus
    lastPathStatus = path.status

    guard isActive else { return }

    if previousStatus != .satisfied && path.status == .satisfied {
      logger.info("Network restored — reconnecting swarm")
      reconnect()
    } else if previousStatus == .satisfied && path.status != .satisfied {
      logger.info("Network lost — swarm connections will drop")
    }
  }

  /// Reconnect all swarm services after a network disruption (e.g. sleep/wake)
  private func reconnect() {
    guard isActive else { return }
    let port = capabilities.lanPort ?? 8766

    // 1. Restart Bonjour discovery + advertising
    discoveryService?.stopAdvertising()
    discoveryService?.stopDiscovery()
    try? discoveryService?.startAdvertising(capabilities: capabilities, port: port)
    discoveryService?.startDiscovery()
    logger.info("Bonjour restarted after network restore")

    // 2. Clear stale connection state (WebRTC sessions will re-establish via signaling)
    connectedWorkers.removeAll()
    workerStatuses.removeAll()
    logger.info("Connection state cleared after network restore")

    // 3. Restart heartbeats
    if role == .worker || role == .hybrid {
      startHeartbeatLoop()
    }
    if role == .brain || role == .hybrid {
      startHeartbeatMonitor()
    }

    // 4. Re-register Firestore workers and restart listeners
    let firebaseService = FirebaseService.shared
    if firebaseService.isSignedIn {
      Task {
        // Re-resolve WAN address (may have changed after sleep/wake)
        let freshWAN = await WANAddressResolver.resolve()
        if let wan = freshWAN { self.resolvedWANAddress = wan }
        let workerCaps = WorkerCapabilities.current(
          wanAddress: self.resolvedWANAddress,
          wanPort: 8766
        )
        for swarm in firebaseService.memberSwarms where swarm.role.canRegisterWorkers {
          _ = try? await firebaseService.registerWorker(swarmId: swarm.id, capabilities: workerCaps)
          // Stop then restart to force fresh listeners
          firebaseService.stopWorkerListener(swarmId: swarm.id)
          firebaseService.startWorkerListener(swarmId: swarm.id)
          firebaseService.stopMessageListener(swarmId: swarm.id)
          firebaseService.startMessageListener(swarmId: swarm.id)
        }
        logger.info("Firestore workers re-registered and listeners restarted")
        
        // 5. Restart WAN auto-connect (clears previous attempts so we retry)
        startWANAutoConnect()
        // 6. Restart LAN reconnect for discovered-but-not-connected peers
        startLANReconnect()
      }
    }

    delegate?.swarmCoordinator(self, didEmit: .workerDisconnected("network-reconnect"))
  }

  // MARK: - Heartbeats

  /// Configure a closure on FirebaseService so every Firestore heartbeat
  /// includes current git commit hash and relay provider status.
  private func configureFirestoreHeartbeatMetadata() {
    FirebaseService.shared.heartbeatMetadata = { [weak self] in
      var metadata: [String: Any] = [:]
      if let hash = self?.capabilities.gitCommitHash {
        metadata["version"] = hash
        metadata["gitCommitHash"] = hash
      }
      return metadata
    }
    FirebaseService.shared.onWorkersSnapshotChanged = { [weak self] in
      self?.firestoreWorkerVersion += 1
      self?.schedulePeerSessionRefresh()
    }
  }

  private func schedulePeerSessionRefresh(after delay: Duration = .seconds(2)) {
    peerSessionRefreshTask?.cancel()
    peerSessionRefreshTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled, self.isActive else { return }
      self.establishPeerSessions()
    }
  }

  private func startHeartbeatLoop() {
    stopHeartbeatLoop()
    heartbeatTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled && self.isActive {
        await self.sendHeartbeat()
        try? await Task.sleep(for: self.heartbeatInterval)
      }
    }
  }

  private func stopHeartbeatLoop() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  /// Start monitoring worker heartbeats for staleness (brain/hybrid mode)
  private func startHeartbeatMonitor() {
    stopHeartbeatMonitor()
    heartbeatMonitorTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled && self.isActive {
        try? await Task.sleep(for: .seconds(15))  // Check every 15s
        await self.checkWorkerHeartbeats()
      }
    }
  }

  private func stopHeartbeatMonitor() {
    heartbeatMonitorTask?.cancel()
    heartbeatMonitorTask = nil
  }

  /// Check for workers with stale heartbeats and disconnect them.
  /// Skips peers with active RAG transfers to prevent mid-transfer disconnects.
  private func checkWorkerHeartbeats() async {
    let now = Date()
    var staleWorkers: [String] = []

    // Collect peers with active transfers (incoming or outgoing, any non-terminal status)
    let activeTransferPeers = Set(
      ragTransfers
        .filter { $0.status == .queued || $0.status == .preparing || $0.status == .transferring }
        .map(\.peerId)
    )

    for (peerId, status) in workerStatuses {
      let age = now.timeIntervalSince(status.lastHeartbeat)
      if age > heartbeatStaleThreshold {
        if activeTransferPeers.contains(peerId) {
          logger.warning("Worker \(peerId) heartbeat stale by \(Int(age))s but has active RAG transfer — deferring disconnect")
          continue
        }
        logger.warning("Worker \(peerId) heartbeat stale by \(Int(age))s, disconnecting")
        staleWorkers.append(peerId)
      }
    }

    // Disconnect stale workers
    for peerId in staleWorkers {
      await peerSessionManager.disconnectPeer(peerId)
    }
  }

  private func currentWorkerStatus() -> WorkerStatus {
    let state: WorkerStatus.WorkerState = currentTask == nil ? .idle : .busy
    let uptime = Date().timeIntervalSince(startedAt ?? Date())
    return WorkerStatus(
      deviceId: capabilities.deviceId,
      state: state,
      currentTaskId: currentTask?.id,
      lastHeartbeat: Date(),
      uptimeSeconds: uptime,
      tasksCompleted: tasksCompleted,
      tasksFailed: tasksFailed,
      ragArtifacts: localRagArtifactStatus,
      gitCommitHash: capabilities.gitCommitHash
    )
  }

  private func sendHeartbeat() async {
    guard role == .worker || role == .hybrid else { return }
    let status = currentWorkerStatus()
    let webrtcPeers = peerSessionManager.connectedPeers
    for peerId in webrtcPeers {
      try? await sendMessage(.heartbeat(status: status), to: peerId)
    }
  }
  
  // MARK: - Crown Methods
  
  /// Connect to a worker via WebRTC session establishment.
  /// Uses Firestore signaling to set up a persistent WebRTC session.
  public func connectToWorker(peerId: String, swarmId: String? = nil) async throws {
    guard isActive else {
      throw DistributedError.actorSystemNotReady
    }
    
    let effectiveSwarmId = swarmId ?? FirebaseService.shared.memberSwarms.first(where: { $0.role.canRegisterWorkers })?.id ?? capabilities.deviceId
    let signaling = FirestoreWebRTCSignaling(
      swarmId: effectiveSwarmId,
      myDeviceId: capabilities.deviceId,
      remoteDeviceId: peerId
    )
    signaling.purpose = "session"
    
    try await peerSessionManager.connectToPeer(peerId, signaling: signaling)
    startListeningOnPeerSession(peerId)
    registerWebRTCPeerAsConnected(peerId)
    logger.info("WebRTC session established with \(peerId)")
  }

  /// Manually connect to a Firestore-discovered WAN worker via WebRTC.
  public func connectToWANWorker(_ worker: FirestoreWorker) async throws {
    guard isActive else {
      throw DistributedError.actorSystemNotReady
    }
    
    try await connectToWorker(peerId: worker.id)
  }

  // MARK: - WAN Auto-Connect

  /// Check Firestore workers and auto-connect via WebRTC signaling.
  /// Failed attempts are retried after `wanConnectRetryInterval` (2 min).
  public func autoConnectWANPeers() {
    guard isActive else { return }

    let myDeviceId = capabilities.deviceId
    let alreadyConnected = Set(connectedWorkers.map(\.id))
    let webrtcConnected = Set(peerSessionManager.connectedPeers)
    let firebaseService = FirebaseService.shared
    let now = Date()

    // Expire old attempts so we can retry
    wanConnectAttempted = wanConnectAttempted.filter { _, attemptDate in
      now.timeIntervalSince(attemptDate) < wanConnectRetryInterval
    }

    for worker in firebaseService.swarmWorkers {
      guard worker.id != myDeviceId,
            !alreadyConnected.contains(worker.id),
            !webrtcConnected.contains(worker.id),
            wanConnectAttempted[worker.id] == nil,
            worker.status == .online,
            !worker.isStale else {
        continue
      }

      wanConnectAttempted[worker.id] = now

      Task {
        logger.info("WAN auto-connect: attempting WebRTC session to \(worker.displayName)")
        do {
          try await self.connectToWorker(peerId: worker.id)
          logger.info("WAN auto-connect: WebRTC connected to \(worker.displayName)")
          self.wanConnectAttempted.removeValue(forKey: worker.id)
        } catch {
          logger.warning("WAN auto-connect: WebRTC failed for \(worker.displayName) — \(error.localizedDescription), will retry in \(Int(self.wanConnectRetryInterval))s")
        }
      }
    }
  }

  /// Start watching for WAN-connectable workers
  func startWANAutoConnect() {
    stopWANAutoConnect()
    wanAutoConnectTask = Task { [weak self] in
      guard let self else { return }

      // Auto-connect to WAN peers that have direct addresses (port forwarding/UPnP)

      // Initial attempt after a short delay (let listeners populate)
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self.autoConnectWANPeers()

      // Then periodically re-check (new workers may appear)
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else { return }
        self.autoConnectWANPeers()
      }
    }
  }

  private func stopWANAutoConnect() {
    wanAutoConnectTask?.cancel()
    wanAutoConnectTask = nil
    wanConnectAttempted.removeAll()
  }

  /// Store the resolved WAN address for reuse on reconnect.
  public func setResolvedWANAddress(_ address: String?) {
    resolvedWANAddress = address
  }

  // MARK: - LAN Reconnect

  /// Periodically check for Bonjour-discovered peers that aren't connected
  /// and retry the TCP connection. This handles the case where the initial
  /// connect failed (timeout, race, etc.) but the peer is still advertising.
  private func startLANReconnect() {
    stopLANReconnect()
    lanReconnectTask = Task { [weak self] in
      // Wait before first check to let initial connections settle
      try? await Task.sleep(for: .seconds(10))

      // Track consecutive failures per peer for exponential backoff
      var failureCounts: [String: Int] = [:]

      while !Task.isCancelled {
        guard let self, self.isActive else { return }

        let connectedIds = Set(self.connectedWorkers.map(\.id))
        // Also collect connected hostnames to detect ghost entries that
        // were stored under the service name before TXT record arrived
        let connectedNames = Set(self.connectedWorkers.map(\.name))
        let discovered = self.discoveryService?.discoveredPeers ?? [:]

        for (peerId, peer) in discovered {
          // Skip if already connected by ID
          guard !connectedIds.contains(peerId) else {
            failureCounts[peerId] = nil  // Reset on successful connect
            continue
          }
          // Skip ghost entries: the peer name matches a connected worker's
          // hostname but the discoveredPeers key is the service name, not the
          // hardware UUID. These get cleaned up when the next .changed event
          // delivers the TXT record.
          if connectedNames.contains(peer.name) { continue }

          // Exponential backoff: skip this cycle if not enough time has passed
          let failures = failureCounts[peerId, default: 0]
          // backoff: 0, 1, 3, 7, 15 cycles (i.e. 0s, 15s, 45s, 105s, 225s)
          // Cap at 8 cycles (~120s between retries)
          let skipCycles = min(failures > 0 ? (1 << min(failures, 3)) - 1 : 0, 8)
          if failures > 0 && failures % (skipCycles + 1) != 0 {
            failureCounts[peerId] = failures + 1
            continue
          }

          self.logger.info("LAN reconnect: retrying \(peer.name) (\(peerId)), attempt \(failures + 1)")
          Task {
            do {
              try await self.connectToWorker(peerId: peerId)
              failureCounts[peerId] = nil  // Reset on success
            } catch {
              failureCounts[peerId] = (failureCounts[peerId] ?? 0) + 1
              self.logger.warning("LAN reconnect failed for \(peer.name): \(error.localizedDescription)")
            }
          }
        }

        try? await Task.sleep(for: .seconds(15))
      }
    }
  }

  private func stopLANReconnect() {
    lanReconnectTask?.cancel()
    lanReconnectTask = nil
  }

  // MARK: - STUN Signaling Responder

  /// Start the WebRTC signaling responder for all member swarms.
  /// This watches Firestore for incoming WebRTC SDP offers and completes
  /// the signaling exchange needed for data channel transfers.
  private func startWebRTCSignalingResponder() {
    let firebaseService = FirebaseService.shared
    guard firebaseService.isSignedIn else {
      logger.info("Not signed in — skipping WebRTC signaling responder")
      return
    }

    let allSwarms = firebaseService.memberSwarms
    let eligibleSwarms = allSwarms.filter { $0.role.canRegisterWorkers }
    let swarmIds = eligibleSwarms.map(\.id)

    guard !swarmIds.isEmpty else {
      logger.info("No eligible swarms for WebRTC offers (total: \(allSwarms.count))")
      return
    }

    let responder = WebRTCSignalingResponder()
    responder.peerSessionManager = peerSessionManager
    responder.onSessionAccepted = { [weak self] peerId in
      self?.startListeningOnPeerSession(peerId)
      self?.registerWebRTCPeerAsConnected(peerId)
    }
    responder.start(swarmIds: swarmIds, myDeviceId: capabilities.deviceId)
    webrtcSignalingResponder = responder
  }

  /// Start listening for PeerMessages on a peer session's mcp channel.
  func startListeningOnPeerSession(_ peerId: String) {
    let generation = (webrtcListenGeneration[peerId] ?? 0) + 1
    webrtcListenGeneration[peerId] = generation
    webrtcMCPListenTasks[peerId]?.cancel()
    webrtcTransferListenTasks[peerId]?.cancel()

    webrtcMCPListenTasks[peerId] = makeWebRTCListenTask(
      peerId: peerId,
      generation: generation,
      label: "mcp",
      rawType: "raw-recv",
      channelProvider: { [weak self] in
        guard let self else { return nil }
        return await self.peerSessionManager.mcpChannel(for: peerId)
      }
    )

    webrtcTransferListenTasks[peerId] = makeWebRTCListenTask(
      peerId: peerId,
      generation: generation,
      label: "transfer",
      rawType: "raw-transfer-recv",
      channelProvider: { [weak self] in
        guard let self else { return nil }
        return await self.peerSessionManager.transferChannel(for: peerId)
      }
    )
  }

  private func makeWebRTCListenTask(
    peerId: String,
    generation: Int,
    label: String,
    rawType: String,
    channelProvider: @escaping @Sendable () async -> DataChannelHandle?
  ) -> Task<Void, Never> {
    Task.detached { [weak self] in
      guard let self else { return }
      let logger = await MainActor.run { self.logger }
      var msgSeq = 0
      var hasLoggedWaitingForChannel = false

      while !Task.isCancelled {
        guard let channel = await channelProvider() else {
          if !hasLoggedWaitingForChannel {
            logger.info("Waiting for WebRTC \(label, privacy: .public) channel for \(peerId, privacy: .public)")
            hasLoggedWaitingForChannel = true
          }
          try? await Task.sleep(for: .milliseconds(250))
          continue
        }

        if hasLoggedWaitingForChannel {
          logger.info("Acquired WebRTC \(label, privacy: .public) channel for \(peerId, privacy: .public)")
          hasLoggedWaitingForChannel = false
        } else {
          logger.info("Started WebRTC \(label, privacy: .public) listener for peer \(peerId, privacy: .public)")
        }

        var channelClosed = false
        while !Task.isCancelled {
          do {
            let data = try await channel.receive(timeout: .seconds(300))
            msgSeq += 1

            if msgSeq <= 5 || (msgSeq <= 120 && data.count > 100_000) {
              await MainActor.run { [weak self] in
                self?.traceMessage(
                  direction: "IN-RAW",
                  peerId: peerId,
                  type: rawType,
                  detail: "channel=\(label) seq=\(msgSeq) size=\(data.count)"
                )
              }
            }

            do {
              let message = try JSONDecoder().decode(PeerMessage.self, from: data)
              await MainActor.run { [weak self] in
                self?.handleWebRTCPeerMessage(message, from: peerId)
              }
            } catch {
              logger.error(
                "WebRTC decode error from \(peerId, privacy: .public) on \(label, privacy: .public): \(String(describing: error), privacy: .public) (data size: \(data.count) bytes)"
              )
              await MainActor.run { [weak self] in
                self?.traceMessage(
                  direction: "IN-ERR",
                  peerId: peerId,
                  type: "decode-err",
                  detail: "channel=\(label) seq=\(msgSeq) size=\(data.count) \(error)"
                )
              }
              continue
            }
          } catch is CancellationError {
            break
          } catch {
            let isFatal = !channel.isOpen
            if isFatal {
              logger.warning(
                "WebRTC \(label, privacy: .public) channel closed for \(peerId, privacy: .public): \(String(describing: error), privacy: .public)"
              )
              channelClosed = true
              break
            } else {
              logger.debug(
                "WebRTC \(label, privacy: .public) receive non-fatal: \(peerId, privacy: .public), \(String(describing: error), privacy: .public)"
              )
              continue
            }
          }
        }

        if Task.isCancelled { break }

        if channelClosed && label == "mcp" {
          Task { @MainActor [weak self] in
            guard let self else { return }
            // mcp can flap briefly while the session/transfer channel remains alive.
            try? await Task.sleep(for: .seconds(2))

            guard self.webrtcListenGeneration[peerId] == generation else {
              self.logger.info("Ignoring stale WebRTC mcp listener completion for \(peerId) (generation \(generation))")
              return
            }

            let state = self.peerSessionManager.peerStates[peerId]
            let mcp = await self.peerSessionManager.mcpChannel(for: peerId)
            let transfer = await self.peerSessionManager.transferChannel(for: peerId)
            if state == .connected && (mcp != nil || transfer != nil) {
              self.logger.info("Suppressing transient mcp disconnect for \(peerId) — session still connected")
              return
            }

            self.handlePeerDisconnected(peerId)
          }
        }

        // Channel closed or rotated: re-resolve and continue listening.
        try? await Task.sleep(for: .milliseconds(100))
      }
      logger.info("WebRTC \(label, privacy: .public) listener ended for peer \(peerId, privacy: .public)")
    }
  }

  /// Handle a PeerMessage received over WebRTC. Routes to the same logic as TCP.
  private func handleWebRTCPeerMessage(_ message: PeerMessage, from peerId: String) {
    handlePeerMessage(message, from: peerId)
  }

  // MARK: - Transport Abstraction

  /// Send a PeerMessage to a specific worker via WebRTC data channel.
  /// Prefers the dedicated transfer channel for bulk data, falling back to the MCP channel.
  private func sendMessage(_ message: PeerMessage, to workerId: String) async throws {
    let msgType = String(describing: message).prefix(60)
    let prefersTransferChannel: Bool
    switch message {
    case .ragArtifactsChunk:
      prefersTransferChannel = true
    default:
      prefersTransferChannel = false
    }
    
    func resolveChannels() async -> (primary: DataChannelHandle?, fallback: DataChannelHandle?) {
      let primary = if prefersTransferChannel {
        await peerSessionManager.transferChannel(for: workerId)
      } else {
        await peerSessionManager.mcpChannel(for: workerId)
      }
      let fallback: DataChannelHandle? = if prefersTransferChannel {
        await peerSessionManager.mcpChannel(for: workerId)
      } else {
        nil
      }
      return (primary, fallback)
    }
    
    var channels = await resolveChannels()
    if channels.primary == nil && channels.fallback == nil {
      // Session can report connected slightly before the data channel becomes readable.
      // Give a short grace period to avoid false "actor system not ready" failures.
      let state = peerSessionManager.peerStates[workerId]
      if state == .connecting || state == .connected {
        for _ in 0..<20 {
          try? await Task.sleep(for: .milliseconds(100))
          channels = await resolveChannels()
          if channels.primary != nil || channels.fallback != nil {
            break
          }
        }
      }
    }

    if prefersTransferChannel && channels.primary == nil {
      let sessionExists = peerSessionManager.sessions[workerId] != nil
      logger.warning("sendMessage: transfer channel NIL for \(workerId) (session exists: \(sessionExists)), falling to MCP")
      traceMessage(direction: "OUT-WARN", peerId: workerId, type: "transfer-nil", detail: "session=\(sessionExists) msg=\(msgType)")
    }

    if let channel = channels.primary ?? channels.fallback {
      let data = try JSONEncoder().encode(message)
      let channelLabel = prefersTransferChannel && channels.primary != nil ? "webrtc-transfer" : "webrtc"
      logger.info("sendMessage to \(workerId): using \(channelLabel) (\(msgType))")
      traceMessage(direction: "OUT", peerId: workerId, type: channelLabel, detail: String(msgType))
      try await channel.send(data)
      return
    }

    // No WebRTC channel available
    let state = peerSessionManager.peerStates[workerId]?.rawValue ?? "unknown"
    let sessionExists = peerSessionManager.sessions[workerId] != nil
    logger.error("sendMessage failed: no channel for \(workerId) (state=\(state), session=\(sessionExists)) msg=\(msgType)")
    throw DistributedError.actorSystemNotReady
  }

  /// Receive the next PeerMessage from a specific worker's WebRTC mcp channel.
  /// Returns nil if no WebRTC session is available (caller should use TCP path).
  private func receiveMessageViaWebRTC(from workerId: String, timeout: Duration = .seconds(30)) async -> PeerMessage? {
    guard let channel = await peerSessionManager.mcpChannel(for: workerId) else {
      return nil
    }
    do {
      let data = try await channel.receive(timeout: timeout)
      return try JSONDecoder().decode(PeerMessage.self, from: data)
    } catch {
      logger.warning("WebRTC receive from \(workerId) failed: \(error)")
      return nil
    }
  }

  /// Dispatch a chain to the best available worker (brain mode)
  public func dispatchChain(_ request: ChainRequest) async throws -> ChainResult {
    guard role == .brain || role == .hybrid else {
      throw DistributedError.actorSystemNotReady
    }
    
    // Find best worker
    guard let worker = selectWorker(for: request) else {
      throw DistributedError.noWorkersAvailable
    }
    
    // Reserve a branch name in the queue to prevent collisions
    let suggestedBranch = SwarmWorktreeManager.generateBranchName(
      taskId: request.id,
      prefix: "swarm",
      hint: extractPromptHintForBranch(from: request.prompt)
    )
    let reservedBranch = branchQueue.reserveBranch(
      taskId: request.id,
      preferredName: suggestedBranch,
      repoPath: request.workingDirectory,
      workerId: worker.id
    )
    
    logger.info("Dispatching task \(request.id) to worker \(worker.name) with branch \(reservedBranch)")
    
    let resultStream = AsyncThrowingStream<ChainResult, Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
      pendingTasks[request.id] = continuation
    }

    defer {
      if let waiter = pendingTasks.removeValue(forKey: request.id) {
        waiter.finish()
      }
    }

    do {
      try await sendMessage(.taskRequest(request: request), to: worker.id)
    } catch {
      branchQueue.releaseBranch(taskId: request.id)
      throw error
    }

    do {
      return try await withThrowingTaskGroup(of: ChainResult.self) { group in
        group.addTask {
          var iterator = resultStream.makeAsyncIterator()
          guard let result = try await iterator.next() else {
            throw CancellationError()
          }
          return result
        }
        group.addTask {
          try await Task.sleep(for: .seconds(Double(request.timeoutSeconds)))
          throw DistributedError.taskTimeout(taskId: request.id)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
          throw CancellationError()
        }
        return first
      }
    } catch is CancellationError {
      branchQueue.releaseBranch(taskId: request.id)
      throw CancellationError()
    } catch {
      if let distributedError = error as? DistributedError, case .taskTimeout = distributedError {
        branchQueue.releaseBranch(taskId: request.id)
      }
      throw error
    }
  }
  
  /// Extract a short hint from the prompt for branch naming
  private func extractPromptHintForBranch(from prompt: String) -> String {
    // Take first few words, truncate to 30 chars max
    let words = prompt.split(separator: " ").prefix(5).joined(separator: " ")
    return String(words.prefix(30))
  }
  
  /// Dispatch a chain to a specific worker (fire-and-forget for updates)
  public func dispatchToWorker(_ request: ChainRequest, workerId: String) async throws {
    guard role == .brain || role == .hybrid else {
      throw DistributedError.actorSystemNotReady
    }

    logger.info("Dispatching task \(request.id) to specific worker \(workerId)")
    
    // Fire and forget - don't wait for result (worker will restart)
    try await sendMessage(.taskRequest(request: request), to: workerId)
  }
  
  /// Send a direct shell command to a specific worker (no LLM involved)
  /// - Parameters:
  ///   - command: The executable path
  ///   - args: Arguments to pass
  ///   - workingDirectory: Optional working directory
  ///   - workerId: Target worker ID
  /// - Note: Fire and forget - result comes back via delegate
  public func sendDirectCommand(_ command: String, args: [String] = [], workingDirectory: String? = nil, to workerId: String) async throws {
    guard role == .brain || role == .hybrid else {
      throw DistributedError.actorSystemNotReady
    }

    let id = UUID()
    logger.info("Sending direct command to \(workerId): \(command)")
    
    let message = PeerMessage.directCommand(id: id, command: command, args: args, workingDirectory: workingDirectory)
    try await sendMessage(message, to: workerId)
  }
  
  /// Send a direct shell command and wait for result (with timeout)
  /// - Parameters:
  ///   - command: The executable path
  ///   - args: Arguments to pass
  ///   - workingDirectory: Optional working directory
  ///   - workerId: Target worker ID
  ///   - timeout: Maximum time to wait for result (default 30s)
  /// - Returns: The command result with exit code, stdout, and stderr
  public func sendDirectCommandAndWait(
    _ command: String,
    args: [String] = [],
    workingDirectory: String? = nil,
    to workerId: String,
    timeout: Duration = .seconds(30)
  ) async throws -> DirectCommandResult {
    guard role == .brain || role == .hybrid else {
      throw DistributedError.actorSystemNotReady
    }

    let id = UUID()
    logger.info("Sending direct command (waiting): \(command) to \(workerId)")
    
    let responseStream = AsyncStream<DirectCommandResult>(bufferingPolicy: .bufferingNewest(1)) { continuation in
      pendingDirectCommands[id] = continuation
    }

    defer {
      if let waiter = pendingDirectCommands.removeValue(forKey: id) {
        waiter.finish()
      }
    }

    let message = PeerMessage.directCommand(id: id, command: command, args: args, workingDirectory: workingDirectory)
    do {
      try await sendMessage(message, to: workerId)
    } catch {
      return DirectCommandResult(exitCode: -1, output: "", error: error.localizedDescription)
    }

    do {
      return try await withThrowingTaskGroup(of: DirectCommandResult.self) { group in
        group.addTask {
          var iterator = responseStream.makeAsyncIterator()
          guard let result = await iterator.next() else {
            return DirectCommandResult(exitCode: -1, output: "", error: "Cancelled")
          }
          return result
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          return DirectCommandResult(exitCode: -1, output: "", error: "Timeout waiting for command result")
        }
        defer { group.cancelAll() }
        return try await group.next() ?? DirectCommandResult(exitCode: -1, output: "", error: "No result")
      }
    } catch {
      return DirectCommandResult(exitCode: -1, output: "", error: "Cancelled")
    }
  }

  // MARK: - RAG Artifact Sync

  public func updateLocalRagArtifactStatus(_ status: RAGArtifactStatus?) {
    localRagArtifactStatus = status
  }

  /// Firestore workers that are online but not TCP-connected (available for on-demand pull).
  public var onDemandWorkers: [FirestoreWorker] {
    guard isActive else { return [] }
    let myDeviceId = capabilities.deviceId
    let connectedIds = Set(connectedWorkers.map(\.id))
    return FirebaseService.shared.swarmWorkers.filter { worker in
      worker.id != myDeviceId
        && !connectedIds.contains(worker.id)
        && worker.status == .online
        && !worker.isStale
    }
  }

  /// All Firestore workers not TCP-connected, regardless of status.
  /// UIs should show stale/offline indicators rather than hiding workers.
  public var allOnDemandWorkers: [FirestoreWorker] {
    guard isActive else { return [] }
    let myDeviceId = capabilities.deviceId
    let connectedIds = Set(connectedWorkers.map(\.id))
    return FirebaseService.shared.swarmWorkers.filter { worker in
      worker.id != myDeviceId
        && !connectedIds.contains(worker.id)
    }
  }

  public func requestRagArtifactSync(
    direction: RAGArtifactSyncDirection,
    workerId: String? = nil,
    repoIdentifier: String? = nil,
    transferMode: RAGTransferMode = .full
  ) async throws -> UUID {
    guard isActive else {
      throw DistributedError.actorSystemNotReady
    }

    let targetWorker: ConnectedPeer
    if let workerId {
      if let worker = connectedWorkers.first(where: { $0.id == workerId }) {
        targetWorker = worker
      } else if peerSessionManager.connectedPeers.contains(workerId) {
        // WebRTC-only peer — construct a ConnectedPeer from Firestore metadata
        let name = FirebaseService.shared.swarmWorkers.first(where: { $0.id == workerId })?.displayName ?? workerId
        targetWorker = ConnectedPeer(id: workerId, name: name, capabilities: .current(), isIncoming: false)
      } else {
        throw DistributedError.workerNotFound(deviceId: workerId)
      }
    } else {
      guard let worker = SwarmPeerPreferences.defaultPeer(from: connectedWorkers) else {
        throw DistributedError.noWorkersAvailable
      }
      targetWorker = worker
    }

    // Basic reliability guard: do not overlap multiple active RAG transfers for
    // the same peer. Concurrent transfers on one WebRTC session can starve each
    // other and amplify WAN stall behavior.
    if let activeTransfer = ragTransfers.first(where: { transfer in
      transfer.peerId == targetWorker.id
        && transfer.status != .complete
        && transfer.status != .failed
    }) {
      throw SwarmTransferError(
        message: "Peer \(targetWorker.name) already has active transfer \(activeTransfer.id.uuidString) (\(activeTransfer.status.rawValue)). Wait for it to finish before starting another."
      )
    }

    let transferId = UUID()
    logger.info("RAG sync requested: \(direction.rawValue) mode=\(transferMode.rawValue) to \(targetWorker.name) (\(targetWorker.id))")
    let role: RAGArtifactTransferRole = direction == .push ? .sender : .receiver
    recordRagTransfer(
      RAGArtifactTransferState(
        id: transferId,
        peerId: targetWorker.id,
        peerName: targetWorker.name,
        direction: direction,
        role: role,
        status: .queued,
        totalBytes: 0,
        transferredBytes: 0,
        startedAt: Date(),
        completedAt: nil,
        errorMessage: nil,
        manifestVersion: nil,
        repoIdentifier: repoIdentifier
      )
    )

    if direction == .pull {
      prepareIncomingRagTransfer(
        id: transferId,
        from: targetWorker.id,
        direction: direction,
        repoIdentifier: repoIdentifier,
        transferMode: transferMode
      )
    }

    let requestMessage = PeerMessage.ragArtifactsRequest(
      id: transferId,
      direction: direction,
      repoIdentifier: repoIdentifier,
      transferMode: transferMode
    )
    var requestSent = false
    do {
      try await sendMessage(requestMessage, to: targetWorker.id)
      requestSent = true
    } catch {
      // Channel state can lag right after relay start/reconnect. Try one reconnect + resend.
      if let distributedError = error as? DistributedError, case .actorSystemNotReady = distributedError {
        logger.warning("RAG sync request \(transferId): channel not ready for \(targetWorker.id), retrying after reconnect")
        do {
          try await connectToWorker(peerId: targetWorker.id)
          try await sendMessage(requestMessage, to: targetWorker.id)
          logger.info("RAG sync request \(transferId): resend succeeded after reconnect to \(targetWorker.id)")
          requestSent = true
        } catch {
          logger.error("RAG sync request \(transferId): resend failed after reconnect: \(error.localizedDescription)")
        }
      }
      if !requestSent {
        if direction == .pull {
          incomingRagTransfers[transferId]?.fileHandle?.closeFile()
          incomingRagTransfers.removeValue(forKey: transferId)
        }
        // Clean up the orphaned transfer if the message couldn't be sent
        updateRagTransfer(transferId) { state in
          state.status = .failed
          state.errorMessage = "Failed to send request: \(error.localizedDescription)"
          state.completedAt = Date()
        }
        throw error
      }
    }

    if direction == .push {
      Task { await sendRagArtifactBundle(transferId: transferId, to: targetWorker, repoIdentifier: repoIdentifier, transferMode: transferMode) }
    }

    return transferId
  }

  private func sendRagArtifactBundle(transferId: UUID, to peer: ConnectedPeer, repoIdentifier: String? = nil, transferMode: RAGTransferMode = .full, skipChunkIndices: Set<Int> = []) async {
    let isResume = !skipChunkIndices.isEmpty
    let senderKey = SenderTransferKey(id: transferId, peerId: peer.id)
    guard !activeSenderTransfers.contains(senderKey) else {
      logger.info("RAG sender already active for \(transferId) -> \(peer.id); skipping duplicate send pipeline")
      return
    }
    activeSenderTransfers.insert(senderKey)
    defer { activeSenderTransfers.remove(senderKey) }

    let hasTransferChannel = await peerSessionManager.transferChannel(for: peer.id) != nil
    let hasMCPChannel = await peerSessionManager.mcpChannel(for: peer.id) != nil
    let usesWebRTC = hasTransferChannel || hasMCPChannel
    updateRagTransfer(transferId) { state in
      state.status = .preparing
    }

    logger.info("RAG sync preparing bundle for \(peer.name) (\(peer.id))\(repoIdentifier.map { ", repo: \($0)" } ?? ""), mode: \(transferMode.rawValue)\(isResume ? ", resume (skipping \(skipChunkIndices.count) chunks)" : "")")
    logger.debug("RAG sync channels for \(peer.id): transfer=\(hasTransferChannel), mcp=\(hasMCPChannel), usesWebRTC=\(usesWebRTC)")

    guard let ragSyncDelegate else {
      logger.error("RAG sync delegate not configured — marking transfer \(transferId) as failed")
      updateRagTransfer(transferId) { state in
        state.status = .failed
        state.errorMessage = "RAG sync delegate not configured"
      }
      await sendRagArtifactError(transferId: transferId, to: peer.id, message: "RAG sync delegate not configured")
      return
    }

    do {
      // Overlay sync: embeddings + analysis only, no chunk text
      if let repoIdentifier, transferMode == .overlay {
        let overlayBundle = try await ragSyncDelegate.createRepoOverlayBundle(repoIdentifier: repoIdentifier, excludeFileHashes: [])
        guard let overlayBundle else {
          await sendRagArtifactError(transferId: transferId, to: peer.id, message: "Repo '\(repoIdentifier)' not found in RAG store for overlay sync")
          return
        }
        // Encode off main actor to avoid blocking UI
        let jsonData = try await Task.detached(priority: .userInitiated) {
          try JSONEncoder().encode(overlayBundle)
        }.value
        let chunkSize = ragChunkSize(for: peer, usesWebRTC: usesWebRTC)
        let totalChunks = max(1, Int(ceil(Double(max(1, jsonData.count)) / Double(chunkSize))))

        logger.info("RAG overlay sync bundle: \(overlayBundle.manifest.repoIdentifier), \(jsonData.count) bytes (\(overlayBundle.totalEntries) entries, \(overlayBundle.totalEmbeddings) embeddings, \(overlayBundle.totalAnalysis) analysis), \(totalChunks) chunks")

        updateRagTransfer(transferId) { state in
          state.status = .transferring
          state.totalBytes = jsonData.count
          state.manifestVersion = "overlay-v\(overlayBundle.manifest.schemaVersion)"
        }

        let manifest = RAGArtifactManifest(
          formatVersion: 1,
          version: "repo-overlay-\(overlayBundle.manifest.repoIdentifier)",
          createdAt: Date(),
          schemaVersion: overlayBundle.manifest.schemaVersion,
          totalBytes: jsonData.count,
          embeddingCacheCount: overlayBundle.totalEmbeddings,
          lastIndexedAt: nil,
          files: [RAGArtifactFileInfo(relativePath: "repo-overlay.json", sizeBytes: jsonData.count, sha256: "", modifiedAt: Date())],
          repos: []
        )
        try await sendMessage(.ragArtifactsManifest(id: transferId, manifest: manifest), to: peer.id)
        traceMessage(direction: "OUT", peerId: peer.id, type: "ragManifest-sent", detail: "id=\(transferId) bytes=\(jsonData.count) chunks=\(totalChunks)")
        if usesWebRTC {
          await waitForManifestAck(transferId: transferId)
        }

        var offset = 0
        var chunkIndex = 0
        while offset < jsonData.count {
          let end = min(offset + chunkSize, jsonData.count)
          let chunkData = jsonData[offset..<end]
          if !skipChunkIndices.contains(chunkIndex) {
            // Base64 encode off main actor
            let base64 = await Task.detached(priority: .userInitiated) {
              chunkData.base64EncodedString()
            }.value
            let sendStarted = ContinuousClock.now
            try await sendMessage(
              .ragArtifactsChunk(id: transferId, index: chunkIndex, total: totalChunks, data: base64),
              to: peer.id
            )
            let sendElapsed = ContinuousClock.now - sendStarted
            if chunkIndex == 0 || chunkIndex == totalChunks - 1 {
              traceMessage(direction: "OUT", peerId: peer.id, type: "ragChunk-sent", detail: "id=\(transferId) chunk=\(chunkIndex)/\(totalChunks) b64len=\(base64.count)")
            }
            if chunkIndex == 0 || chunkIndex == totalChunks - 1 || (chunkIndex % 128 == 0) {
              logger.debug(
                "RAG chunk send [\(transferId)] overlay chunk \(chunkIndex)/\(totalChunks) bytes=\(chunkData.count) elapsed=\(sendElapsed)"
              )
            }
            if sendElapsed > .seconds(2) {
              logger.warning(
                "RAG chunk send slow [\(transferId)] overlay chunk \(chunkIndex)/\(totalChunks) elapsed=\(sendElapsed)"
              )
            }
            // Yield between chunks to avoid overwhelming the receiver
            await Task.yield()
          }
          updateRagTransfer(transferId) { state in
            state.transferredBytes += chunkData.count
          }
          offset = end
          chunkIndex += 1
        }

        try await sendMessage(.ragArtifactsComplete(id: transferId), to: peer.id)
        updateRagTransfer(transferId) { state in
          state.status = .complete
          state.completedAt = Date()
        }
        logger.info("RAG overlay sync completed: \(transferId) to \(peer.name)")
        return
      }

      // Per-repo sync: export only the requested repo as JSON
      if let repoIdentifier {
        logger.notice("RAG sync [\(transferId)]: starting export for '\(repoIdentifier)'...")
        let exportStart = ContinuousClock.now

        let repoBundle = try await ragSyncDelegate.createRepoSyncBundle(repoIdentifier: repoIdentifier, excludeFileHashes: [])

        let exportElapsed = ContinuousClock.now - exportStart
        logger.notice("RAG sync [\(transferId)]: export completed in \(exportElapsed), bundle: \(repoBundle == nil ? "nil" : "present")")

        guard let repoBundle else {
          await sendRagArtifactError(transferId: transferId, to: peer.id, message: "Repo '\(repoIdentifier)' not found in RAG store")
          updateRagTransfer(transferId) { state in
            state.status = .failed
            state.errorMessage = "Repo '\(repoIdentifier)' not found in RAG store"
          }
          return
        }
        // Encode off main actor to avoid blocking UI
        let jsonData = try await Task.detached(priority: .userInitiated) {
          try JSONEncoder().encode(repoBundle)
        }.value
        let chunkSize = ragChunkSize(for: peer, usesWebRTC: usesWebRTC)
        let totalChunks = max(1, Int(ceil(Double(max(1, jsonData.count)) / Double(chunkSize))))

        logger.info("RAG repo sync bundle: \(repoBundle.manifest.repoIdentifier), \(jsonData.count) bytes, \(totalChunks) chunks")

        updateRagTransfer(transferId) { state in
          state.status = .transferring
          state.totalBytes = jsonData.count
          state.manifestVersion = "v\(repoBundle.manifest.schemaVersion)"
        }

        // Send as a manifest with repo info
        let manifest = RAGArtifactManifest(
          formatVersion: 1,
          version: "repo-sync-\(repoBundle.manifest.repoIdentifier)",
          createdAt: Date(),
          schemaVersion: 13,
          totalBytes: jsonData.count,
          embeddingCacheCount: 0,
          lastIndexedAt: nil,
          files: [RAGArtifactFileInfo(relativePath: "repo-bundle.json", sizeBytes: jsonData.count, sha256: "", modifiedAt: Date())],
          repos: []
        )
        try await sendMessage(.ragArtifactsManifest(id: transferId, manifest: manifest), to: peer.id)
        traceMessage(direction: "OUT", peerId: peer.id, type: "ragManifest-sent", detail: "id=\(transferId) bytes=\(jsonData.count) chunks=\(totalChunks)")
        if usesWebRTC {
          await waitForManifestAck(transferId: transferId)
        }

        // Send in chunks
        var offset = 0
        var chunkIndex = 0
        while offset < jsonData.count {
          let end = min(offset + chunkSize, jsonData.count)
          let chunkData = jsonData[offset..<end]
          if !skipChunkIndices.contains(chunkIndex) {
            // Base64 encode off main actor
            let base64 = await Task.detached(priority: .userInitiated) {
              chunkData.base64EncodedString()
            }.value
            let sendStarted = ContinuousClock.now
            try await sendMessage(
              .ragArtifactsChunk(id: transferId, index: chunkIndex, total: totalChunks, data: base64),
              to: peer.id
            )
            let sendElapsed = ContinuousClock.now - sendStarted
            if chunkIndex == 0 || chunkIndex == totalChunks - 1 {
              traceMessage(direction: "OUT", peerId: peer.id, type: "ragChunk-sent", detail: "id=\(transferId) chunk=\(chunkIndex)/\(totalChunks) b64len=\(base64.count)")
            }
            if chunkIndex == 0 || chunkIndex == totalChunks - 1 || (chunkIndex % 128 == 0) {
              logger.debug(
                "RAG chunk send [\(transferId)] repo chunk \(chunkIndex)/\(totalChunks) bytes=\(chunkData.count) elapsed=\(sendElapsed)"
              )
            }
            if sendElapsed > .seconds(2) {
              logger.warning(
                "RAG chunk send slow [\(transferId)] repo chunk \(chunkIndex)/\(totalChunks) elapsed=\(sendElapsed)"
              )
            }
            // Yield between chunks to avoid overwhelming the receiver
            await Task.yield()
          }
          updateRagTransfer(transferId) { state in
            state.transferredBytes += chunkData.count
          }
          offset = end
          chunkIndex += 1
        }

        try await sendMessage(.ragArtifactsComplete(id: transferId), to: peer.id)
        updateRagTransfer(transferId) { state in
          state.status = .complete
          state.completedAt = Date()
        }
        logger.info("RAG repo sync completed: \(transferId) to \(peer.name)")
        return
      }

      // Full DB sync (legacy path)
      let bundle = try await ragSyncDelegate.createRagArtifactBundle()
      let fileAttributes = try FileManager.default.attributesOfItem(atPath: bundle.bundleURL.path)
      let fileSize = (fileAttributes[.size] as? NSNumber)?.intValue ?? bundle.bundleSizeBytes
      let chunkSize = ragChunkSize(for: peer, usesWebRTC: usesWebRTC)
      let totalChunks = max(1, Int(ceil(Double(max(1, fileSize)) / Double(chunkSize))))

      logger.info("RAG sync bundle created: \(bundle.manifest.version), \(fileSize) bytes, \(totalChunks) chunks")

      updateRagTransfer(transferId) { state in
        state.status = .transferring
        state.totalBytes = fileSize
        state.manifestVersion = bundle.manifest.version
      }

      try await sendMessage(.ragArtifactsManifest(id: transferId, manifest: bundle.manifest), to: peer.id)
      if usesWebRTC {
        await waitForManifestAck(transferId: transferId)
      }

      let handle = try FileHandle(forReadingFrom: bundle.bundleURL)
      defer { try? handle.close() }

      var chunkIndex = 0
      while true {
        let data = try handle.read(upToCount: chunkSize) ?? Data()
        if data.isEmpty { break }
        if !skipChunkIndices.contains(chunkIndex) {
          // Base64 encode off main actor
          let base64 = await Task.detached(priority: .userInitiated) {
            data.base64EncodedString()
          }.value
          let sendStarted = ContinuousClock.now
          try await sendMessage(
            .ragArtifactsChunk(id: transferId, index: chunkIndex, total: totalChunks, data: base64),
            to: peer.id
          )
          let sendElapsed = ContinuousClock.now - sendStarted
          if chunkIndex == 0 || chunkIndex == totalChunks - 1 || (chunkIndex % 128 == 0) {
            logger.debug(
              "RAG chunk send [\(transferId)] full chunk \(chunkIndex)/\(totalChunks) bytes=\(data.count) elapsed=\(sendElapsed)"
            )
          }
          if sendElapsed > .seconds(2) {
            logger.warning(
              "RAG chunk send slow [\(transferId)] full chunk \(chunkIndex)/\(totalChunks) elapsed=\(sendElapsed)"
            )
          }
          // Yield between chunks to avoid overwhelming the receiver
          await Task.yield()
        }
        updateRagTransfer(transferId) { state in
          state.transferredBytes += data.count
        }
        chunkIndex += 1
      }

      try await sendMessage(.ragArtifactsComplete(id: transferId), to: peer.id)
      updateRagTransfer(transferId) { state in
        state.status = .complete
        state.completedAt = Date()
      }
      logger.info("RAG sync completed: \(transferId) to \(peer.name)")
    } catch {
      logger.error("RAG sync failed: \(transferId) to \(peer.name) - \(error.localizedDescription)")
      await sendRagArtifactError(transferId: transferId, to: peer.id, message: error.localizedDescription)
      updateRagTransfer(transferId) { state in
        state.status = .failed
        state.errorMessage = error.localizedDescription
        state.completedAt = Date()
      }
    }
  }

  private func prepareIncomingRagTransfer(id: UUID, from peerId: String, direction: RAGArtifactSyncDirection, repoIdentifier: String? = nil, transferMode: RAGTransferMode? = nil) {
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("rag-artifacts-\(id).zip")
    let transfer = RAGIncomingTransfer(id: id, peerId: peerId, direction: direction, tempURL: tempURL)
    transfer.repoIdentifier = repoIdentifier
    transfer.transferMode = transferMode
    if FileManager.default.fileExists(atPath: transfer.tempURL.path) {
      try? FileManager.default.removeItem(at: transfer.tempURL)
    }
    FileManager.default.createFile(atPath: transfer.tempURL.path, contents: Data())
    transfer.fileHandle = try? FileHandle(forWritingTo: transfer.tempURL)
    incomingRagTransfers[id] = transfer
  }

  /// Choose a conservative chunk size for WAN WebRTC sessions to reduce SCTP backpressure stalls.
  private func ragChunkSize(for peer: ConnectedPeer, usesWebRTC: Bool) -> Int {
    guard usesWebRTC else { return 256 * 1024 }

    // Prefer live Firestore worker topology first (LAN address often absent for WAN-only peers),
    // since ConnectedPeer capabilities can lag or be stale across reconnects.
    if let worker = FirebaseService.shared.swarmWorkers.first(where: { $0.id == peer.id }) {
      let hasLAN = worker.lanAddress != nil
      let hasWAN = worker.wanAddress != nil
      if !hasLAN && hasWAN {
        return 16 * 1024
      }
    }

    let hasLAN = peer.capabilities.lanAddress != nil
    let hasWAN = peer.capabilities.wanAddress != nil
    if !hasLAN && hasWAN {
      return 16 * 1024
    }
    return 64 * 1024
  }

  private func handleRagArtifactsManifest(id: UUID, manifest: RAGArtifactManifest, from peerId: String) {
    logger.info("RAG sync received manifest \(manifest.version) from \(peerId)")
    let transfer = incomingRagTransfers[id] ?? RAGIncomingTransfer(
      id: id,
      peerId: peerId,
      direction: .pull,
      tempURL: FileManager.default.temporaryDirectory.appendingPathComponent("rag-artifacts-\(id).zip")
    )
    transfer.manifest = manifest
    incomingRagTransfers[id] = transfer

    if transfer.fileHandle == nil {
      if FileManager.default.fileExists(atPath: transfer.tempURL.path) {
        try? FileManager.default.removeItem(at: transfer.tempURL)
      }
      FileManager.default.createFile(atPath: transfer.tempURL.path, contents: Data())
      transfer.fileHandle = try? FileHandle(forWritingTo: transfer.tempURL)
    }

    updateRagTransfer(id) { state in
      state.status = .transferring
      state.totalBytes = manifest.totalBytes
      state.manifestVersion = manifest.version
      state.transferredBytes = transfer.receivedBytes
    }

    // Ack the manifest so the sender knows we're ready for chunks.
    // This replaces the unreliable 150ms sleep that failed to prevent
    // chunk 0 from being silently dropped by the SCTP layer.
    Task {
      try? await sendMessage(.ragArtifactsAck(id: id, receivedChunks: 0, receivedBytes: 0), to: peerId)
    }
  }

  private func handleRagArtifactsChunk(id: UUID, index: Int, total: Int, data: String) {
    guard let transfer = incomingRagTransfers[id] else {
      logger.error("RAG chunk \(index)/\(total) for \(id) dropped — no transfer state (manifest not yet processed?)")
      traceMessage(direction: "IN-DROP", peerId: "?", type: "ragChunk-noState", detail: "chunk=\(index)/\(total) id=\(id)")
      return
    }
    guard let decoded = Data(base64Encoded: data) else {
      logger.error("RAG chunk \(index)/\(total) for \(id) failed base64 decode (data.count=\(data.count))")
      traceMessage(direction: "IN-ERR", peerId: transfer.peerId, type: "ragChunk-b64fail", detail: "chunk=\(index)/\(total) len=\(data.count)")
      updateRagTransfer(id) { state in
        state.status = .failed
        state.errorMessage = "Failed to decode artifact chunk"
        state.completedAt = Date()
      }
      Task { await sendRagArtifactError(transferId: id, to: transfer.peerId, message: "Failed to decode artifact chunk") }
      incomingRagTransfers.removeValue(forKey: id)
      return
    }

    if transfer.receivedChunkIndices.contains(index) {
      logger.debug("RAG chunk \(index)/\(total) for \(id) ignored — duplicate index")
      return
    }

    transfer.expectedChunks = total
    if index < max(0, total - 1), transfer.chunkSizeHint == nil {
      transfer.chunkSizeHint = decoded.count
    }

    if let handle = transfer.fileHandle {
      let byteOffset: Int
      if let chunkSizeHint = transfer.chunkSizeHint {
        byteOffset = index * chunkSizeHint
      } else if let manifestBytes = transfer.manifest?.totalBytes, total > 0 {
        let inferredChunk = Int(ceil(Double(manifestBytes) / Double(total)))
        byteOffset = index * inferredChunk
      } else {
        // Last-resort fallback when metadata is incomplete.
        byteOffset = transfer.receivedBytes
      }

      do {
        try handle.seek(toOffset: UInt64(max(0, byteOffset)))
        try handle.write(contentsOf: decoded)
      } catch {
        logger.error("RAG chunk \(index)/\(total) for \(id) write failed: \(error.localizedDescription)")
        updateRagTransfer(id) { state in
          state.status = .failed
          state.errorMessage = "Failed writing artifact chunk: \(error.localizedDescription)"
          state.completedAt = Date()
        }
        Task { await sendRagArtifactError(transferId: id, to: transfer.peerId, message: "Failed writing artifact chunk") }
        incomingRagTransfers.removeValue(forKey: id)
        return
      }
    } else {
      logger.error("RAG chunk \(index)/\(total) for \(id) dropped — missing file handle")
      return
    }

    transfer.receivedChunkIndices.insert(index)
    transfer.receivedChunks = transfer.receivedChunkIndices.count
    transfer.receivedBytes += decoded.count
    transfer.lastChunkReceivedAt = Date()
    // Any forward progress proves the sender is alive; reset retry budget so
    // intermittent WAN jitter doesn't permanently cap long transfers.
    transfer.retryCount = 0

    updateRagTransfer(id) { state in
      state.status = .transferring
      state.errorMessage = nil
      state.transferredBytes = transfer.receivedBytes
    }

    if index == 0 || transfer.receivedChunks == total {
      logger.debug("RAG sync chunk \(index + 1)/\(total) received for \(id)")
    }
  }

  private func handleRagArtifactsComplete(id: UUID, from peerId: String) async {
    guard let transfer = incomingRagTransfers[id] else { return }
    transfer.fileHandle?.closeFile()
    transfer.fileHandle = nil

    if let expected = transfer.expectedChunks, transfer.receivedChunks < expected {
      let allExpected = Set(0..<expected)
      let missing = allExpected.subtracting(transfer.receivedChunkIndices).sorted()
      logger.error("RAG transfer incomplete: \(transfer.receivedChunks)/\(expected) chunks, missing indices: \(missing)")
      updateRagTransfer(id) { state in
        state.status = .failed
        state.errorMessage = "Incomplete transfer (\(transfer.receivedChunks)/\(expected) chunks, missing: \(missing))"
        state.completedAt = Date()
      }
      await sendRagArtifactError(transferId: id, to: peerId, message: "Incomplete transfer")
      incomingRagTransfers.removeValue(forKey: id)
      return
    }

    updateRagTransfer(id) { state in
      state.status = .applying
    }

    guard let manifest = transfer.manifest, let ragSyncDelegate else {
      updateRagTransfer(id) { state in
        state.status = .failed
        state.errorMessage = "Missing manifest or delegate"
        state.completedAt = Date()
      }
      incomingRagTransfers.removeValue(forKey: id)
      return
    }

    do {
      logger.info("RAG sync applying bundle \(id) from \(peerId)")

      // Per-repo sync bundles have version "repo-sync-<repoIdentifier>"
      if manifest.version.hasPrefix("repo-sync-") {
        // Read and decode off main actor to avoid blocking UI
        let tempURL = transfer.tempURL
        let repoBundle = try await Task.detached(priority: .userInitiated) {
          let jsonData = try Data(contentsOf: tempURL)
          return try JSONDecoder().decode(RAGRepoExportBundle.self, from: jsonData)
        }.value
        // Always force-import remote embeddings — vectorSearchWithDimensionCheck
        // handles per-repo model/dimension switching at query time.
        let result = try await ragSyncDelegate.applyRepoSyncBundle(repoBundle, localRepoPath: nil, forceImportEmbeddings: true)
        if let remoteModel = result.remoteEmbeddingModel {
          logger.info("RAG repo sync: imported embeddings from remote model '\(remoteModel)' (\(result.remoteEmbeddingDimensions ?? 0)d) — \(result.embeddingsImported) vectors")
        }
        logger.info("RAG repo sync applied \(id): files \(result.filesImported), chunks \(result.chunksImported), embeddings \(result.embeddingsImported), analysisUpdated \(result.chunksAnalysisUpdated), pruned \(result.filesPruned)")

        // Build a result summary for the UI
        var summaryParts: [String] = []
        if result.filesImported > 0 { summaryParts.append("\(result.filesImported) files") }
        if result.chunksImported > 0 { summaryParts.append("\(result.chunksImported) chunks") }
        if result.embeddingsImported > 0 { summaryParts.append("\(result.embeddingsImported) embeddings") }
        if result.chunksAnalysisUpdated > 0 { summaryParts.append("\(result.chunksAnalysisUpdated) analysis synced") }
        if result.embeddingsBackfilled > 0 { summaryParts.append("\(result.embeddingsBackfilled) embeddings backfilled") }
        if result.filesPruned > 0 { summaryParts.append("\(result.filesPruned) stale files pruned") }
        if result.needsLocalReembedding { summaryParts.append("needs re-embed") }
        let summary = summaryParts.isEmpty ? "Up to date" : summaryParts.joined(separator: ", ")

        updateRagTransfer(id) { state in
          state.status = .complete
          state.completedAt = Date()
          state.resultSummary = summary
          state.remoteEmbeddingModel = result.remoteEmbeddingModel
        }
      } else if manifest.version.hasPrefix("repo-overlay-") {
        // Overlay sync: embeddings + analysis only, matched against locally-indexed chunks
        let tempURL = transfer.tempURL
        let overlayBundle = try await Task.detached(priority: .userInitiated) {
          let jsonData = try Data(contentsOf: tempURL)
          return try JSONDecoder().decode(RAGRepoOverlayBundle.self, from: jsonData)
        }.value
        let result = try await ragSyncDelegate.applyRepoOverlayBundle(overlayBundle)

        logger.info("RAG overlay sync applied \(id): \(result.filesMatched) files matched (\(result.filesUnmatched) unmatched), \(result.embeddingsApplied) embeddings applied (\(result.embeddingsReplaced) replaced), \(result.analysisApplied) analysis applied, \(result.chunksUnmatched) chunks unmatched, \(result.embeddingsSkippedModelMismatch) embeddings skipped (model mismatch)")

        if result.hadModelMismatch {
          let localDesc = result.localEmbeddingModel ?? "unknown"
          let remoteDesc = result.remoteEmbeddingModel ?? "unknown"
          logger.warning("Overlay model mismatch: local=\(localDesc), remote=\(remoteDesc) — \(result.embeddingsSkippedModelMismatch) embeddings skipped, only analysis data applied. To force local embeddings, disable swarm sync and reindex locally.")
        }

        var summaryParts: [String] = []
        if result.embeddingsApplied > 0 { summaryParts.append("\(result.embeddingsApplied) embeddings") }
        if result.analysisApplied > 0 { summaryParts.append("\(result.analysisApplied) analysis") }
        if result.filesMatched > 0 { summaryParts.append("\(result.filesMatched) files matched") }
        if result.filesUnmatched > 0 { summaryParts.append("\(result.filesUnmatched) files unmatched") }
        if result.chunksUnmatched > 0 { summaryParts.append("\(result.chunksUnmatched) chunks unmatched") }
        if result.hadModelMismatch { summaryParts.append("\(result.embeddingsSkippedModelMismatch) embeddings skipped (model mismatch)") }
        let summary = summaryParts.isEmpty ? "Up to date" : summaryParts.joined(separator: ", ")

        updateRagTransfer(id) { state in
          state.status = .complete
          state.completedAt = Date()
          state.resultSummary = summary
          state.remoteEmbeddingModel = overlayBundle.manifest.embeddingModel
        }
      } else {
        // Full DB sync (legacy path)
        try await ragSyncDelegate.applyRagArtifactBundle(
          at: transfer.tempURL,
          manifest: manifest,
          from: peerId,
          direction: transfer.direction
        )
        updateRagTransfer(id) { state in
          state.status = .complete
          state.completedAt = Date()
        }
      }
      logger.info("RAG sync applied bundle \(id) from \(peerId)")
    } catch {
      logger.error("RAG sync apply failed \(id) from \(peerId): \(error.localizedDescription)")
      updateRagTransfer(id) { state in
        state.status = .failed
        state.errorMessage = error.localizedDescription
        state.completedAt = Date()
      }
    }

    incomingRagTransfers.removeValue(forKey: id)
  }

  /// Wait for the receiver to ack the manifest (confirming it's ready for chunks).
  /// Falls back to a 500ms delay if the ack doesn't arrive within 2 seconds,
  /// which handles receivers running older code without the ack.
  ///
  /// Uses a task-group race to avoid the continuation double-resume race that
  /// existed with the previous timeout-task approach.
  private func waitForManifestAck(transferId: UUID) async {
    let ackStream = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
      manifestAckWaiters[transferId] = continuation
    }

    defer {
      if let waiter = manifestAckWaiters.removeValue(forKey: transferId) {
        waiter.finish()
      }
    }

    let gotAck = (try? await withThrowingTaskGroup(of: Bool.self) { group in
      group.addTask {
        var iterator = ackStream.makeAsyncIterator()
        return await iterator.next() ?? false
      }
      group.addTask {
        try await Task.sleep(for: .seconds(2))
        return false
      }
      defer { group.cancelAll() }
      return try await group.next() ?? false
    }) ?? false

    if gotAck {
      logger.info("Manifest ack received for \(transferId), proceeding with chunks")
    } else {
      // Receiver may be running older code without the ack, or ack was lost.
      // Apply a longer fallback delay than the old 150ms.
      try? await Task.sleep(for: .milliseconds(500))
      logger.info("Manifest ack timeout for \(transferId), proceeding with 500ms fallback delay")
    }
  }

  private func sendRagArtifactError(transferId: UUID, to peerId: String, message: String) async {
    logger.error("RAG sync error \(transferId) to \(peerId): \(message)")
    try? await sendMessage(.ragArtifactsError(id: transferId, message: message), to: peerId)
  }

  private func updateRagTransfer(_ id: UUID, update: (inout RAGArtifactTransferState) -> Void) {
    guard let index = ragTransfers.firstIndex(where: { $0.id == id }) else { return }
    var state = ragTransfers[index]
    update(&state)
    ragTransfers[index] = state
  }

  private func recordRagTransfer(_ transfer: RAGArtifactTransferState) {
    if let existingIndex = ragTransfers.firstIndex(where: { $0.id == transfer.id }) {
      ragTransfers.remove(at: existingIndex)
    }
    ragTransfers.insert(transfer, at: 0)
    if ragTransfers.count > 50 {
      ragTransfers.removeLast()
    }
  }

  /// Wait for a RAG transfer to reach a terminal state (.complete or .failed).
  public func waitForTransferCompletion(_ id: UUID, timeout: Duration = .seconds(300)) async throws -> RAGArtifactTransferState {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let state = ragTransfers.first(where: { $0.id == id }) {
        switch state.status {
        case .complete: return state
        case .failed: throw SwarmTransferError(message: state.errorMessage ?? "Transfer failed")
        default: break
        }
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    // Mark the transfer as failed so it doesn't stay orphaned in ragTransfers
    updateRagTransfer(id) { state in
      state.status = .failed
      state.errorMessage = "Transfer timed out after \(timeout)"
      state.completedAt = Date()
    }
    throw SwarmTransferError(message: "Transfer \(id) timed out after \(timeout)")
  }

  // MARK: - RAG Transfer Checkpoint Persistence

  private static var checkpointDirectory: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("Peel/rag-transfer-checkpoints")
  }

  private func saveCheckpoint(for transfer: RAGIncomingTransfer) {
    let peerName = connectedWorkers.first(where: { $0.id == transfer.peerId })?.name ?? "Peer"
    let checkpoint = transfer.makeCheckpoint(peerName: peerName)
    let dir = Self.checkpointDirectory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(checkpoint.transferId.uuidString).json")
    if let data = try? JSONEncoder().encode(checkpoint) {
      try? data.write(to: url, options: .atomic)
      logger.debug("RAG transfer checkpoint saved: \(checkpoint.transferId)")
    }
  }

  private func removeCheckpoint(for transferId: UUID) {
    let url = Self.checkpointDirectory.appendingPathComponent("\(transferId.uuidString).json")
    try? FileManager.default.removeItem(at: url)
  }

  private func loadCheckpoints() -> [RAGTransferCheckpoint] {
    let dir = Self.checkpointDirectory
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
      return []
    }
    return files.compactMap { url -> RAGTransferCheckpoint? in
      guard url.pathExtension == "json",
            let data = try? Data(contentsOf: url),
            let checkpoint = try? JSONDecoder().decode(RAGTransferCheckpoint.self, from: data) else {
        return nil
      }
      return checkpoint
    }
  }

  /// Remove expired checkpoints and temp files on app launch.
  func cleanupStaleCheckpoints() {
    let checkpoints = loadCheckpoints()
    for cp in checkpoints {
      if cp.isExpired {
        logger.info("RAG transfer checkpoint expired, cleaning up: \(cp.transferId)")
        removeCheckpoint(for: cp.transferId)
        try? FileManager.default.removeItem(atPath: cp.tempFilePath)
      }
    }
  }

  // MARK: - RAG Transfer Watchdog

  /// Start the watchdog timer that scans for stalled transfers every 15 seconds.
  private func startRagTransferWatchdog() {
    ragTransferWatchdogTask?.cancel()
    ragTransferWatchdogTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled else { break }
        self?.checkForStalledTransfers()
      }
    }
  }

  private func stopRagTransferWatchdog() {
    ragTransferWatchdogTask?.cancel()
    ragTransferWatchdogTask = nil
  }

  private func checkForStalledTransfers() {
    let now = Date()

    // Check transfers stuck in .queued (message never delivered or response never received)
    for transfer in ragTransfers {
      guard transfer.status == .queued,
            now.timeIntervalSince(transfer.startedAt) >= ragTransferQueuedThreshold else { continue }
      let elapsed = Int(now.timeIntervalSince(transfer.startedAt))
      let peerConnected =
        connectedWorkers.contains(where: { $0.id == transfer.peerId })
        || peerSessionManager.connectedPeers.contains(transfer.peerId)
        || peerSessionManager.peerStates[transfer.peerId] == .connecting

      if transfer.direction == .pull,
         transfer.role == .receiver,
         peerConnected,
         let incoming = incomingRagTransfers[transfer.id],
         incoming.retryCount < self.ragTransferMaxRetries {
        incoming.retryCount += 1
        let retryAttempt = incoming.retryCount
        logger.warning(
          "RAG transfer \(transfer.id) stuck in queued for \(elapsed)s — retrying request (\(retryAttempt)/\(self.ragTransferMaxRetries))"
        )
        updateRagTransfer(transfer.id) { state in
          state.startedAt = now
          state.errorMessage = "Queued retry \(retryAttempt)/\(self.ragTransferMaxRetries) after \(elapsed)s"
        }

        let request = PeerMessage.ragArtifactsRequest(
          id: transfer.id,
          direction: transfer.direction,
          repoIdentifier: transfer.repoIdentifier,
          transferMode: incoming.transferMode ?? .full
        )
        Task {
          do {
            try await sendMessage(request, to: transfer.peerId)
            logger.info("RAG transfer \(transfer.id): queued retry request sent to \(transfer.peerId)")
          } catch {
            if let distributedError = error as? DistributedError, case .actorSystemNotReady = distributedError {
              logger.warning(
                "RAG transfer \(transfer.id): queued retry channel not ready for \(transfer.peerId), reconnecting"
              )
              do {
                try await connectToWorker(peerId: transfer.peerId)
                try await sendMessage(request, to: transfer.peerId)
                logger.info("RAG transfer \(transfer.id): queued retry resend succeeded after reconnect")
              } catch {
                logger.error(
                  "RAG transfer \(transfer.id): queued retry resend failed after reconnect: \(error.localizedDescription)"
                )
              }
            } else {
              logger.error("RAG transfer \(transfer.id): queued retry send failed: \(error.localizedDescription)")
            }
          }
        }
        continue
      }

      logger.warning("RAG transfer \(transfer.id) stuck in queued for \(elapsed)s — marking failed")
      updateRagTransfer(transfer.id) { state in
        state.status = .failed
        state.errorMessage = "Transfer stuck in queued for \(elapsed)s — peer may be unreachable"
        state.completedAt = now
      }
      if transfer.direction == .pull {
        incomingRagTransfers[transfer.id]?.fileHandle?.closeFile()
        incomingRagTransfers.removeValue(forKey: transfer.id)
      }
    }

    // Check outgoing transfers stuck in .preparing
    for transfer in ragTransfers {
      guard transfer.status == .preparing,
            now.timeIntervalSince(transfer.startedAt) >= 120 else { continue }
      let elapsed = Int(now.timeIntervalSince(transfer.startedAt))
      logger.warning("RAG transfer \(transfer.id) stuck in preparing for \(elapsed)s — marking failed")
      updateRagTransfer(transfer.id) { state in
        state.status = .failed
        state.errorMessage = "Export stuck in preparing for \(elapsed)s"
        state.completedAt = now
      }
    }

    for (id, transfer) in incomingRagTransfers {
      let elapsed = now.timeIntervalSince(transfer.lastChunkReceivedAt)
      let stalledThreshold = ragStalledThreshold(forPeerId: transfer.peerId)
      guard elapsed >= stalledThreshold else { continue }

      // Only act on transfers that are actively receiving
      guard let status = ragTransfers.first(where: { $0.id == id })?.status,
            status == .transferring else { continue }

      logger.warning("RAG transfer \(id) stalled (\(Int(elapsed))s since last chunk, \(transfer.receivedChunks)/\(transfer.expectedChunks ?? 0) chunks)")

      // Check if the peer is still connected. The `connectedWorkers` mirror can lag
      // behind `peerSessionManager` during reconnects, so consult both.
      let peerConnected =
        connectedWorkers.contains(where: { $0.id == transfer.peerId })
        || peerSessionManager.connectedPeers.contains(transfer.peerId)
        || peerSessionManager.peerStates[transfer.peerId] == .connecting

      if peerConnected {
        // Peer is connected but sender may have crashed/stalled — mark as stalled
        updateRagTransfer(id) { state in
          state.status = .stalled
          state.errorMessage = "No data received for \(Int(elapsed))s"
        }
        // Try requesting resume from the connected peer
        if transfer.retryCount < ragTransferMaxRetries {
          transfer.retryCount += 1
          logger.info("RAG transfer \(id) requesting resume (attempt \(transfer.retryCount)/\(self.ragTransferMaxRetries))")
          Task {
            do {
              try await sendMessage(
                .ragArtifactsResumeRequest(
                  id: id,
                  receivedChunkIndices: transfer.receivedChunkIndices,
                  repoIdentifier: transfer.repoIdentifier,
                  transferMode: transfer.transferMode
                ),
                to: transfer.peerId
              )
            } catch {
              logger.error("RAG transfer \(id) resume request failed: \(error.localizedDescription)")
            }
          }
        } else {
          // Exhausted retries — fail the transfer
          failTransfer(id: id, message: "Transfer stalled after \(ragTransferMaxRetries) resume attempts")
        }
      } else {
        // Peer disconnected — checkpoint and keep transfer resumable.
        pauseTransferForReconnect(id: id, transfer: transfer, message: "Peer disconnected during transfer (checkpoint saved, waiting for reconnect)")
      }
    }
  }

  private func ragStalledThreshold(forPeerId peerId: String) -> TimeInterval {
    if let peer = connectedWorkers.first(where: { $0.id == peerId }) {
      let hasLAN = peer.capabilities.lanAddress != nil
      let hasWAN = peer.capabilities.wanAddress != nil
      if !hasLAN && hasWAN {
        return ragTransferStalledThresholdWAN
      }
      return ragTransferStalledThreshold
    }

    if let worker = FirebaseService.shared.swarmWorkers.first(where: { $0.id == peerId }) {
      let hasLAN = worker.lanAddress != nil
      let hasWAN = worker.wanAddress != nil
      if !hasLAN && hasWAN {
        return ragTransferStalledThresholdWAN
      }
    }

    return ragTransferStalledThreshold
  }

  /// Pause a transfer on disconnect so it can be resumed when the peer reconnects.
  private func pauseTransferForReconnect(id: UUID, transfer: RAGIncomingTransfer, message: String) {
    saveCheckpoint(for: transfer)
    transfer.fileHandle?.closeFile()
    transfer.fileHandle = nil
    incomingRagTransfers.removeValue(forKey: id)
    updateRagTransfer(id) { state in
      state.status = .stalled
      state.errorMessage = message
      state.completedAt = nil
    }
    logger.warning("RAG transfer \(id) paused: \(message)")
  }

  /// Fail a transfer, clean up handles, remove from incoming map.
  private func failTransfer(id: UUID, message: String) {
    if let transfer = incomingRagTransfers[id] {
      transfer.fileHandle?.closeFile()
      transfer.fileHandle = nil
    }
    updateRagTransfer(id) { state in
      state.status = .failed
      state.errorMessage = message
      state.completedAt = Date()
    }
    incomingRagTransfers.removeValue(forKey: id)
    logger.error("RAG transfer \(id) failed: \(message)")
  }

  // MARK: - RAG Transfer Resume on Reconnect

  /// Called when a peer (re)connects. Checks for saved checkpoints that can be resumed with this peer.
  private func attemptResumeTransfers(with peerId: String) {
    let checkpoints = loadCheckpoints().filter { $0.peerId == peerId && !$0.isExpired }
    guard !checkpoints.isEmpty else { return }

    logger.info("Found \(checkpoints.count) resumable RAG transfer(s) for reconnected peer \(peerId)")
    for cp in checkpoints {
      // Remove the old checkpoint — we'll create a fresh transfer
      removeCheckpoint(for: cp.transferId)

      // Reuse the original transfer ID so callers waiting on `transferId`
      // observe the resumed transfer instead of a detached new ID.
      let resumedId = cp.transferId
      let peerName = cp.peerName
      let transfer = RAGArtifactTransferState(
        id: resumedId,
        peerId: peerId,
        peerName: peerName,
        direction: cp.direction,
        role: .receiver,
        status: .transferring,
        totalBytes: cp.totalBytes,
        transferredBytes: cp.receivedBytes,
        startedAt: Date(),
        completedAt: nil,
        errorMessage: nil,
        manifestVersion: nil,
        repoIdentifier: cp.repoIdentifier,
        resultSummary: "Resuming from \(cp.receivedChunkIndices.count)/\(cp.totalChunks) chunks"
      )
      recordRagTransfer(transfer)

      // Prepare a new incoming transfer from the checkpoint
      let tempURL: URL
      if FileManager.default.fileExists(atPath: cp.tempFilePath) {
        // Reuse the existing temp file
        tempURL = URL(fileURLWithPath: cp.tempFilePath)
      } else {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("rag-artifacts-\(resumedId).zip")
      }
      let incoming = RAGIncomingTransfer(id: resumedId, peerId: peerId, direction: cp.direction, tempURL: tempURL)
      incoming.manifest = cp.manifest
      incoming.expectedChunks = cp.totalChunks
      incoming.receivedChunks = cp.receivedChunkIndices.count
      incoming.receivedBytes = cp.receivedBytes
      incoming.receivedChunkIndices = cp.receivedChunkIndices
      incoming.repoIdentifier = cp.repoIdentifier
      incoming.transferMode = cp.transferMode
      incomingRagTransfers[resumedId] = incoming

      // Reopen file handle for appending
      if !FileManager.default.fileExists(atPath: tempURL.path) {
        FileManager.default.createFile(atPath: tempURL.path, contents: Data())
      }
      incoming.fileHandle = try? FileHandle(forWritingTo: tempURL)
      incoming.fileHandle?.seekToEndOfFile()

      logger.info("RAG transfer resume: requesting re-send for \(resumedId), skipping \(cp.receivedChunkIndices.count) chunks")

      // Send resume request to the peer
      Task {
        do {
          try await sendMessage(
              .ragArtifactsResumeRequest(
                id: resumedId,
                receivedChunkIndices: cp.receivedChunkIndices,
                repoIdentifier: cp.repoIdentifier,
                transferMode: cp.transferMode
            ),
            to: peerId
          )
        } catch {
          logger.error("RAG transfer \(resumedId) resume request send failed: \(error.localizedDescription)")
        }
      }
    }
  }

  // MARK: - RAG Transfer Resume Handler (Sender Side)

  /// Handle an incoming resume request — re-send only the missing chunks.
  private func handleRagArtifactsResumeRequest(
    id: UUID,
    receivedChunkIndices: Set<Int>,
    repoIdentifier: String?,
    transferMode: RAGTransferMode?,
    from peerId: String
  ) async {
    let peer = connectedWorkers.first(where: { $0.id == peerId }) ?? makeConnectedPeerView(for: peerId, isIncoming: true)
    let peerName = peer.name
    logger.info("RAG resume request from \(peerName): \(id), has \(receivedChunkIndices.count) chunks, repo: \(repoIdentifier ?? "all"), mode: \(transferMode?.rawValue ?? "full")")

    // Record a new sender-side transfer for this resume
    let transfer = RAGArtifactTransferState(
      id: id,
      peerId: peerId,
      peerName: peerName,
      direction: .pull,
      role: .sender,
      status: .preparing,
      totalBytes: 0,
      transferredBytes: 0,
      startedAt: Date(),
      completedAt: nil,
      errorMessage: nil,
      manifestVersion: nil,
      repoIdentifier: repoIdentifier,
      resultSummary: "Resume (skipping \(receivedChunkIndices.count) chunks)"
    )
    recordRagTransfer(transfer)

    // Delegate to sendRagArtifactBundle with skip set
    await sendRagArtifactBundle(
      transferId: id,
      to: peer,
      repoIdentifier: repoIdentifier,
      transferMode: transferMode ?? .full,
      skipChunkIndices: receivedChunkIndices
    )
  }
  
  /// Select the best worker for a request
  private func selectWorker(for request: ChainRequest) -> ConnectedPeer? {
    let candidates = connectedWorkers.filter { peer in
      // Check capabilities
      if let required = request.requiredCapabilities {
        return required.isSatisfiedBy(peer.capabilities)
      }
      return true
    }

    let available = candidates.filter { peer in
      guard let status = workerStatuses[peer.id] else { return true }
      return status.state != .busy && status.state != .offline
    }

    let ranked = available.isEmpty ? candidates : available
    // Prefer workers with more resources
    return ranked.max { a, b in
      a.capabilities.gpuCores < b.capabilities.gpuCores
    }
  }
  
  // MARK: - Peel Methods
  
  /// Handle incoming task (worker mode)
  private func handleTaskRequest(_ request: ChainRequest, from peerId: String) async {
    guard role == .worker || role == .hybrid else { return }
    
    // Resolve the working directory for this machine using RepoRegistry
    let resolvedWorkingDirectory = RepoRegistry.shared.resolveWorkingDirectory(for: request)
    logger.info("Task \(request.id): resolved workingDirectory '\(request.workingDirectory)' -> '\(resolvedWorkingDirectory)'")
    
    // Check if the resolved path exists
    guard FileManager.default.fileExists(atPath: resolvedWorkingDirectory) else {
      logger.error("Task \(request.id): Working directory not found: \(resolvedWorkingDirectory)")
      let result = ChainResult(
        requestId: request.id,
        status: .failed,
        duration: 0,
        workerDeviceId: capabilities.deviceId,
        workerDeviceName: capabilities.deviceName,
        errorMessage: "Working directory not found on worker: \(resolvedWorkingDirectory). Remote URL: \(request.repoRemoteURL ?? "none"). Register this repo with the worker."
      )
      try? await sendMessage(.taskResult(result: result), to: peerId)
      completedResults.insert(result, at: 0)
      if completedResults.count > maxStoredResults {
        completedResults.removeLast()
      }
      delegate?.swarmCoordinator(self, didEmit: .taskCompleted(result))
      tasksFailed += 1
      return
    }
    
    // Check with delegate if we should execute
    if let delegate = delegate, !delegate.swarmCoordinator(self, shouldExecute: request) {
      // Reject task
      try? await sendMessage(
        .taskRejected(taskId: request.id, reason: "Peel declined"),
        to: peerId
      )
      return
    }
    
    currentTask = request
    delegate?.swarmCoordinator(self, didEmit: .taskReceived(request))
    delegate?.swarmCoordinator(self, didEmit: .taskStarted(request.id))
    await sendHeartbeat()
    
    // Accept task
    try? await sendMessage(.taskAccepted(taskId: request.id), to: peerId)
    
    // Execute
    let startTime = Date()
    var result: ChainResult
    var worktreePath: String?
    var createdBranchName: String?
    
    do {
      let outputs: [ChainOutput]
      
      if let executor = chainExecutor {
        // Create isolated worktree if enabled
        let effectiveWorkingDirectory: String
        if useWorktreeIsolation {
          let branchName = SwarmWorktreeManager.generateBranchName(
            taskId: request.id,
            prefix: "swarm",
            hint: extractPromptHint(from: request.prompt)
          )
          createdBranchName = branchName
          
          worktreePath = try await worktreeManager.createWorktree(
            taskId: request.id,
            repoPath: resolvedWorkingDirectory,
            branchName: branchName,
            baseBranch: "origin/main"
          )
          effectiveWorkingDirectory = worktreePath!
          logger.info("Created worktree for task \(request.id): path=\(effectiveWorkingDirectory), originalRepo=\(request.workingDirectory)")
        } else {
          effectiveWorkingDirectory = request.workingDirectory
        }
        
        // Create a modified request with the worktree path
        let modifiedRequest = ChainRequest(
          id: request.id,
          templateName: request.templateName,
          prompt: request.prompt,
          workingDirectory: effectiveWorkingDirectory,
          repoRemoteURL: request.repoRemoteURL,
          priority: request.priority,
          requiredCapabilities: request.requiredCapabilities,
          createdAt: request.createdAt,
          timeoutSeconds: request.timeoutSeconds
        )
        
        logger.info("Executing task \(request.id) with workingDirectory: \(modifiedRequest.workingDirectory)")
        outputs = try await executor.execute(request: modifiedRequest)
        logger.info("Task \(request.id) execution complete, checking for changes in worktree")
        
        // Commit and push any changes made by the agent
        if useWorktreeIsolation, let branchName = createdBranchName {
          let commitMessage = "[\(branchName)] Swarm task: \(request.prompt.prefix(50))"
          logger.info("Calling commitAndPushChanges for task \(request.id)")
          let didCommit = try await worktreeManager.commitAndPushChanges(
            taskId: request.id,
            commitMessage: commitMessage
          )
          if didCommit {
            logger.info("Committed and pushed changes for task \(request.id) on branch \(branchName)")
          } else {
            logger.info("No changes to commit for task \(request.id)")
          }
        }
      } else {
        // Mock execution
        logger.warning("No chain executor, returning mock result")
        try await Task.sleep(for: .seconds(2))
        outputs = [
          ChainOutput(type: .text, name: "mock", content: "Mock result for: \(request.prompt)")
        ]
      }
      
      let duration = Date().timeIntervalSince(startTime)
      result = ChainResult(
        requestId: request.id,
        status: .completed,
        outputs: outputs,
        duration: duration,
        workerDeviceId: capabilities.deviceId,
        workerDeviceName: capabilities.deviceName,
        branchName: createdBranchName,
        repoPath: useWorktreeIsolation ? request.workingDirectory : nil
      )
      tasksCompleted += 1
      
    } catch {
      let duration = Date().timeIntervalSince(startTime)
      result = ChainResult(
        requestId: request.id,
        status: .failed,
        duration: duration,
        workerDeviceId: capabilities.deviceId,
        workerDeviceName: capabilities.deviceName,
        errorMessage: error.localizedDescription,
        branchName: createdBranchName,
        repoPath: useWorktreeIsolation ? request.workingDirectory : nil
      )
      tasksFailed += 1
      delegate?.swarmCoordinator(self, didEmit: .taskFailed(request.id, error))
    }
    
    // Cleanup worktree after task completion
    // Note: We don't delete the branch - the brain will handle PR creation
    if useWorktreeIsolation && worktreePath != nil {
      do {
        try await worktreeManager.removeWorktree(taskId: request.id, force: false)
        logger.info("Cleaned up worktree for task \(request.id)")
      } catch {
        logger.warning("Failed to cleanup worktree for task \(request.id): \(error)")
      }
    }
    
    // Send result
    try? await sendMessage(.taskResult(result: result), to: peerId)
    
    // Store result locally so worker UI and swarm.tasks can query it
    completedResults.insert(result, at: 0)
    if completedResults.count > maxStoredResults {
      completedResults.removeLast()
    }
    
    currentTask = nil
    delegate?.swarmCoordinator(self, didEmit: .taskCompleted(result))
    await sendHeartbeat()
    
    logger.info("Task \(request.id) completed: \(result.status.rawValue)")
  }
  
  /// Extract a hint for branch naming from the prompt
  private func extractPromptHint(from prompt: String) -> String {
    // Take first few words, truncate to 30 chars max
    let words = prompt.split(separator: " ").prefix(5).joined(separator: " ")
    return String(words.prefix(30))
  }
  
  /// Handle direct command execution (worker mode) - no LLM involved
  private func handleDirectCommand(id: UUID, command: String, args: [String], workingDirectory: String?, from peerId: String) async {
    logger.info("handleDirectCommand: command=\(command), role=\(String(describing: self.role))")
    
    guard role == .worker || role == .hybrid else {
      logger.warning("handleDirectCommand: Not in worker mode, ignoring")
      // Send error result back
      try? await sendMessage(
        .directCommandResult(id: id, exitCode: -1, output: "", error: "Not in worker mode"),
        to: peerId
      )
      return
    }
    
    logger.info("Executing direct command: \(command) \(args.joined(separator: " "))")
    
    // Determine the working directory (repo root)
    // If none specified, try to find the Peel repo from the running app's bundle
    let effectiveWorkingDir: String
    if let dir = workingDirectory, !dir.isEmpty {
      effectiveWorkingDir = dir
      logger.info("Using provided working directory: \(dir)")
    } else if let detected = Self.detectRepoPath() {
      effectiveWorkingDir = detected
      logger.info("Auto-detected repo path: \(detected)")
    } else {
      let fallback = FileManager.default.currentDirectoryPath
      logger.warning("Could not detect repo path, using current directory: \(fallback)")
      effectiveWorkingDir = fallback
    }
    
    // If command is a relative path (like Tools/self-update.sh), make it absolute.
    // Only check the executable name (first word), not args which may contain slashes
    // (e.g. "git push -u origin feature/branch" — "git" has no slash, don't resolve).
    let resolvedCommand: String
    let commandExecutable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
    if !commandExecutable.hasPrefix("/") && commandExecutable.contains("/") {
      // Relative path - make it absolute using working dir
      resolvedCommand = "\(effectiveWorkingDir)/\(command)"
    } else {
      resolvedCommand = command
    }
    
    // Run the process off MainActor to avoid blocking the UI.
    // Commands like `curl http://127.0.0.1:8765/rpc` call back into the MCP server
    // which needs MainActor — running waitUntilExit() on MainActor would deadlock.
    let (output, errorOutput, exitCode) = await Task.detached { [resolvedCommand, effectiveWorkingDir, args] () -> (String, String?, Int32) in
      let useShell = !resolvedCommand.hasPrefix("/")
      
      let process = Process()
      if useShell {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let fullCommand: String
        if args.isEmpty {
          fullCommand = resolvedCommand
        } else {
          let escapedArgs = args.map { arg in
            arg.contains(" ") || arg.contains("\"") || arg.contains("'")
              ? "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
              : arg
          }.joined(separator: " ")
          fullCommand = "\(resolvedCommand) \(escapedArgs)"
        }
        process.arguments = ["-c", fullCommand]
      } else {
        process.executableURL = URL(fileURLWithPath: resolvedCommand)
        process.arguments = args
      }
      process.currentDirectoryURL = URL(fileURLWithPath: effectiveWorkingDir)
      
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
      
      do {
        try process.run()
        process.waitUntilExit()
        let exitCode = process.terminationStatus
        
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""
        
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        
        return (output, errStr.isEmpty ? nil : errStr, exitCode)
      } catch {
        return ("", error.localizedDescription, -1)
      }
    }.value
    
    // Send result back (hops back to MainActor for the send)
    do {
      try await sendMessage(
        .directCommandResult(id: id, exitCode: exitCode, output: output, error: errorOutput),
        to: peerId
      )
    } catch {
      logger.error("Failed to send directCommandResult id=\(id) to \(peerId): \(error)")
    }
    
    logger.info("Direct command \(id) finished with exit code \(exitCode)")
    
    // If this was a successful self-update build, restart Peel natively.
    // The script only does git pull + build; restart is handled here in Swift
    // to avoid the child-process-kills-parent reliability nightmare.
    if exitCode == 0 && command.contains("self-update") {
      logger.info("Self-update build succeeded — initiating native restart")
      await performSelfRestart()
    }
  }
  
  // MARK: - Native Self-Restart
  
  /// After a successful self-update build, spawn a fully detached restart script and exit Peel.
  /// This avoids the fundamental problem of a child shell script trying to kill its parent process.
  /// Instead: Peel writes a tiny restart script → launches it detached → exits gracefully.
  /// The restart script waits for Peel to fully exit, then launches the newly built app.
  private func performSelfRestart() async {
    let appPath = Bundle.main.bundlePath
    logger.info("performSelfRestart: app=\(appPath)")
    
    guard let repoPath = Self.detectRepoPath() else {
      logger.error("performSelfRestart: Cannot detect repo path — aborting restart")
      return
    }
    
    let tmpDir = "\(repoPath)/tmp"
    try? FileManager.default.createDirectory(
      atPath: tmpDir, withIntermediateDirectories: true, attributes: nil
    )
    let scriptPath = "\(tmpDir)/peel-restart.sh"
    
    let bundleId = Bundle.main.bundleIdentifier ?? "com.crunchy-bananas.Peel"
    let pid = ProcessInfo.processInfo.processIdentifier
    
    let script = """
    #!/bin/zsh
    # Auto-generated by Peel performSelfRestart(). Restarts app after clean exit.
    LOG_FILE="$HOME/Library/Logs/Peel/swarm-self-update.log"
    exec >> "$LOG_FILE" 2>&1
    echo ""
    echo "=== Restart script (waiting for Peel PID \(pid) to exit) ==="
    
    # Wait for the current Peel process to fully exit
    for i in {1..30}; do
      if ! kill -0 \(pid) 2>/dev/null; then
        break
      fi
      sleep 0.5
    done
    
    if kill -0 \(pid) 2>/dev/null; then
      echo "⚠️  Peel PID \(pid) still alive after 15s — force killing"
      kill -9 \(pid) 2>/dev/null || true
      sleep 1
    fi
    echo "Peel process \(pid) has exited."
    
    # Disable state restoration to prevent macOS zombie relaunch
    defaults write \(bundleId) NSQuitAlwaysKeepsWindows -bool false 2>/dev/null || true
    
    # Kill any zombie Peel processes macOS state restoration may have spawned
    sleep 1
    ZOMBIES=$(pgrep -x Peel 2>/dev/null || true)
    if [ -n "$ZOMBIES" ]; then
      echo "Killing zombie Peel processes: $ZOMBIES"
      echo "$ZOMBIES" | xargs kill -9 2>/dev/null || true
      sleep 1
    fi
    
    echo "Launching: \(appPath)"
    /usr/bin/open "\(appPath)" --args --worker
    sleep 3
    
    if pgrep -x Peel >/dev/null 2>&1; then
      echo "✅ Peel restarted (PID: $(pgrep -x Peel))"
    else
      echo "⚠️  Retry launch..."
      /usr/bin/open "\(appPath)" --args --worker
      sleep 3
      if pgrep -x Peel >/dev/null 2>&1; then
        echo "✅ Peel started on retry"
      else
        echo "❌ Failed to restart Peel"
      fi
    fi
    echo "=== Restart script complete ==="
    """
    
    do {
      try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: scriptPath
      )
    } catch {
      logger.error("performSelfRestart: Failed to write restart script: \(error)")
      return
    }
    
    // Launch restart script fully detached — no pipes, no connection to this process.
    // When Peel exits, this child gets reparented to launchd and continues running.
    let restartProcess = Process()
    restartProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
    restartProcess.arguments = [scriptPath]
    restartProcess.standardOutput = FileHandle.nullDevice
    restartProcess.standardError = FileHandle.nullDevice
    restartProcess.standardInput = FileHandle.nullDevice
    restartProcess.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    
    do {
      try restartProcess.run()
      logger.info("performSelfRestart: Restart script launched (PID: \(restartProcess.processIdentifier))")
    } catch {
      logger.error("performSelfRestart: Failed to launch restart script: \(error)")
      return
    }
    
    // Give time for the directCommandResult message to be fully transmitted
    try? await Task.sleep(for: .seconds(2))
    
    logger.info("performSelfRestart: Exiting Peel for restart.")
    exit(0)
  }
}

// MARK: - Peer Connection Lifecycle

extension SwarmCoordinator {
  /// Build a best-effort ConnectedPeer view for a worker ID.
  /// Uses Firestore metadata when available, otherwise falls back to the ID.
  private func makeConnectedPeerView(for peerId: String, isIncoming: Bool = false) -> ConnectedPeer {
    let worker = FirebaseService.shared.swarmWorkers.first(where: { $0.id == peerId })
    let caps = WorkerCapabilities(
      deviceId: peerId,
      deviceName: worker?.deviceName ?? peerId,
      displayName: worker?.displayName,
      platform: .macOS,
      gpuCores: 0,
      neuralEngineCores: 0,
      memoryGB: 0,
      storageAvailableGB: 0,
      gitCommitHash: worker?.gitCommitHash,
      lanAddress: worker?.lanAddress,
      lanPort: worker?.lanPort,
      wanAddress: worker?.wanAddress,
      wanPort: worker?.wanPort,
      stunAddress: worker?.stunAddress,
      stunPort: worker?.stunPort
    )
    return ConnectedPeer(
      id: peerId,
      name: worker?.deviceName ?? peerId,
      capabilities: caps,
      isIncoming: isIncoming
    )
  }

  /// Build a ConnectedPeer from Firestore worker data and register it.
  /// Called after a WebRTC session is successfully established (either as initiator or responder).
  private func registerWebRTCPeerAsConnected(_ peerId: String) {
    let peer = makeConnectedPeerView(for: peerId)
    handlePeerConnected(peer)
  }

  /// Handle a peer connecting (called from WebRTC session establishment).
  func handlePeerConnected(_ peer: ConnectedPeer) {
    // Check if this is a reconnection (same deviceId, possibly new capabilities)
    if let existingIndex = connectedWorkers.firstIndex(where: { $0.id == peer.id }) {
      let existing = connectedWorkers[existingIndex]
      let oldHash = existing.capabilities.gitCommitHash ?? "unknown"
      let newHash = peer.capabilities.gitCommitHash ?? "unknown"
      if oldHash != newHash {
        logger.info("Worker \(peer.name) reconnected with updated code: \(oldHash) → \(newHash)")
      } else {
        logger.info("Worker \(peer.name) reconnected (same version: \(newHash))")
      }
      connectedWorkers.remove(at: existingIndex)
    }

    connectedWorkers.append(peer)
    delegate?.swarmCoordinator(self, didEmit: .workerConnected(peer))
    logger.info("Peel connected: \(peer.name) (commit: \(peer.capabilities.gitCommitHash ?? "unknown"))")

    // Reset heartbeat timestamp on (re)connect so the monitor doesn't
    // immediately consider this worker stale from a previous connection.
    if role == .brain || role == .hybrid {
      if let existing = workerStatuses[peer.id] {
        workerStatuses[peer.id] = WorkerStatus(
          deviceId: existing.deviceId,
          state: .idle,
          currentTaskId: nil,
          lastHeartbeat: Date(),
          uptimeSeconds: 0,
          tasksCompleted: existing.tasksCompleted,
          tasksFailed: existing.tasksFailed,
          ragArtifacts: existing.ragArtifacts
        )
      } else {
        workerStatuses[peer.id] = WorkerStatus(
          deviceId: peer.id,
          state: .idle,
          currentTaskId: nil,
          lastHeartbeat: Date(),
          uptimeSeconds: 0,
          tasksCompleted: 0,
          tasksFailed: 0,
          ragArtifacts: nil
        )
      }
    }

    if role == .worker || role == .hybrid {
      Task { await sendHeartbeat() }
    }

    // Check for resumable RAG transfers from this peer
    attemptResumeTransfers(with: peer.id)
  }
  
  /// Handle a peer disconnecting (called from WebRTC session teardown).
  func handlePeerDisconnected(_ peerId: String) {
    let workerName = connectedWorkers.first(where: { $0.id == peerId })?.name ?? peerId
    connectedWorkers.removeAll { $0.id == peerId }
    if let existing = workerStatuses[peerId] {
      let heartbeatAge = Date().timeIntervalSince(existing.lastHeartbeat)
      logger.warning("Peer \(workerName) disconnected — last heartbeat \(Int(heartbeatAge))s ago, state: \(existing.state.rawValue)")
      workerStatuses[peerId] = WorkerStatus(
        deviceId: existing.deviceId,
        state: .offline,
        currentTaskId: existing.currentTaskId,
        lastHeartbeat: Date(),
        uptimeSeconds: existing.uptimeSeconds,
        tasksCompleted: existing.tasksCompleted,
        tasksFailed: existing.tasksFailed,
        ragArtifacts: existing.ragArtifacts
      )
    }

    // Save checkpoints and pause any in-progress RAG transfers from this peer
    let affectedTransfers = incomingRagTransfers.filter { $0.value.peerId == peerId }
    if !affectedTransfers.isEmpty {
      logger.error("Peer \(workerName) disconnect affects \(affectedTransfers.count) active RAG transfer(s)")
    }
    for (id, transfer) in affectedTransfers {
      logger.info("RAG transfer \(id) checkpointing on disconnect (\(transfer.receivedChunks)/\(transfer.expectedChunks ?? 0) chunks)")
      pauseTransferForReconnect(id: id, transfer: transfer, message: "Peer disconnected (checkpoint saved, will auto-resume on reconnect)")
    }

    // Also check outgoing ragTransfers (we were sending to this peer)
    let affectedOutgoing = ragTransfers.filter {
      $0.peerId == peerId && ($0.status == .queued || $0.status == .preparing || $0.status == .transferring)
    }
    if !affectedOutgoing.isEmpty {
      logger.error("Peer \(workerName) disconnect affects \(affectedOutgoing.count) outgoing RAG transfer(s)")
      for transfer in affectedOutgoing {
        updateRagTransfer(transfer.id) { state in
          state.status = .failed
          state.errorMessage = "Peer disconnected during outgoing transfer"
          state.completedAt = Date()
        }
      }
    }

    delegate?.swarmCoordinator(self, didEmit: .workerDisconnected(peerId))
    logger.info("Peel disconnected: \(workerName) (\(peerId))")
  }
}

// MARK: - Peer Message Handling (shared by WebRTC + TCP)

extension SwarmCoordinator {
  /// Unified handler for PeerMessages from any transport (WebRTC or TCP).
  func handlePeerMessage(_ message: PeerMessage, from peerId: String) {
    switch message {
    case .taskRequest(let request):
      Task {
        await handleTaskRequest(request, from: peerId)
      }
      
    case .taskProgress(let taskId, let progress, let message):
      logger.debug("Task \(taskId) progress: \(progress) - \(message ?? "")")
      
    case .taskResult(let result):
      if let waiter = pendingTasks.removeValue(forKey: result.requestId) {
        waiter.yield(result)
        waiter.finish()
      }
      if result.status == .completed {
        tasksCompleted += 1
        branchQueue.completeBranch(taskId: result.requestId, status: .success)
        
        if autoCreatePRs, let branchName = result.branchName, let repoPath = result.repoPath {
          let prompt = result.outputs.first { $0.name.contains("summary") }?.content ?? "Swarm task completed"
          let agentOutput = result.outputs.first { $0.name.contains("agent") }?.content
          prQueue.createPRFromTask(
            taskId: result.requestId,
            branchName: branchName,
            repoPath: repoPath,
            prompt: prompt,
            outputs: agentOutput
          )
        }
      } else {
        tasksFailed += 1
        branchQueue.completeBranch(taskId: result.requestId, status: .needsReview)
      }
      completedResults.insert(result, at: 0)
      if completedResults.count > maxStoredResults {
        completedResults.removeLast()
      }
      delegate?.swarmCoordinator(self, didEmit: .taskCompleted(result))

    case .heartbeat(var status):
      // Use local receive time to avoid clock-skew between machines
      // causing spurious stale-heartbeat disconnects.
      traceMessage(direction: "IN", peerId: peerId, type: "heartbeat")
      status.lastHeartbeat = Date()
      workerStatuses[peerId] = status
      Task { try? await sendMessage(.heartbeatAck, to: peerId) }
      
    case .directCommand(let id, let command, let args, let workingDirectory):
      traceMessage(direction: "IN", peerId: peerId, type: "directCommand", detail: "id=\(id) cmd=\(command)")
      logger.info("Received directCommand: \(command) from \(peerId)")
      Task {
        await handleDirectCommand(id: id, command: command, args: args, workingDirectory: workingDirectory, from: peerId)
      }
      
    case .directCommandResult(let id, let exitCode, let output, let error):
      traceMessage(direction: "IN", peerId: peerId, type: "directCommandResult", detail: "id=\(id) exit=\(exitCode)")
      logger.info("Direct command \(id) completed with exit code \(exitCode)")
      if let error = error, !error.isEmpty {
        logger.warning("Direct command stderr: \(error)")
      }
      if !output.isEmpty {
        logger.debug("Direct command output: \(output.prefix(500))")
      }
      if let waiter = pendingDirectCommands.removeValue(forKey: id) {
        waiter.yield(DirectCommandResult(exitCode: exitCode, output: output, error: error))
        waiter.finish()
      } else {
        logger.warning("No pending continuation for directCommandResult id=\(id) — already timed out or fire-and-forget?")
      }

    case .ragArtifactsRequest(let id, let direction, let repoIdentifier, let transferMode):
      let peer = connectedWorkers.first(where: { $0.id == peerId }) ?? makeConnectedPeerView(for: peerId, isIncoming: true)
      let peerName = peer.name
      traceMessage(direction: "IN", peerId: peerId, type: "ragRequest", detail: "id=\(id) dir=\(direction.rawValue) peer=\(peer.name) repo=\(repoIdentifier ?? "all")")
      if direction == .pull {
        let transfer = RAGArtifactTransferState(
          id: id,
          peerId: peerId,
          peerName: peerName,
          direction: direction,
          role: .sender,
          status: .queued,
          totalBytes: 0,
          transferredBytes: 0,
          startedAt: Date(),
          completedAt: nil,
          errorMessage: nil,
          manifestVersion: nil,
          repoIdentifier: repoIdentifier
        )
        recordRagTransfer(transfer)
        Task { await sendRagArtifactBundle(transferId: id, to: peer, repoIdentifier: repoIdentifier, transferMode: transferMode ?? .full) }
      } else {
        let transfer = RAGArtifactTransferState(
          id: id,
          peerId: peerId,
          peerName: peerName,
          direction: direction,
          role: .receiver,
          status: .queued,
          totalBytes: 0,
          transferredBytes: 0,
          startedAt: Date(),
          completedAt: nil,
          errorMessage: nil,
          manifestVersion: nil,
          repoIdentifier: repoIdentifier
        )
        recordRagTransfer(transfer)
        prepareIncomingRagTransfer(id: id, from: peerId, direction: direction, repoIdentifier: repoIdentifier, transferMode: transferMode)
      }

    case .ragArtifactsManifest(let id, let manifest):
      traceMessage(direction: "IN", peerId: peerId, type: "ragManifest", detail: "id=\(id) ver=\(manifest.version) bytes=\(manifest.totalBytes)")
      handleRagArtifactsManifest(id: id, manifest: manifest, from: peerId)

    case .ragArtifactsChunk(let id, let index, let total, let data):
      // Trace first, last, and every 25th chunk to avoid flooding trace buffer
      if index == 0 || index == total - 1 || index % 25 == 0 {
        traceMessage(direction: "IN", peerId: peerId, type: "ragChunk", detail: "id=\(id) chunk=\(index)/\(total) len=\(data.count)")
      }
      handleRagArtifactsChunk(id: id, index: index, total: total, data: data)

    case .ragArtifactsComplete(let id):
      traceMessage(direction: "IN", peerId: peerId, type: "ragComplete", detail: "id=\(id)")
      Task { await handleRagArtifactsComplete(id: id, from: peerId) }

    case .ragArtifactsError(let id, let message):
      traceMessage(direction: "IN", peerId: peerId, type: "ragError", detail: "id=\(id) msg=\(message)")
      updateRagTransfer(id) { state in
        state.status = .failed
        state.errorMessage = message
        state.completedAt = Date()
      }

    case .ragArtifactsAck(let id, let receivedChunks, let receivedBytes):
      logger.debug("RAG ack for \(id): \(receivedChunks) chunks, \(receivedBytes) bytes")
      if receivedChunks == 0, let waiter = manifestAckWaiters.removeValue(forKey: id) {
        waiter.yield(true)
        waiter.finish()
      }
      updateRagTransfer(id) { state in
        state.transferredBytes = receivedBytes
      }

    case .ragArtifactsResumeRequest(let id, let receivedChunkIndices, let repoIdentifier, let transferMode):
      Task {
        await handleRagArtifactsResumeRequest(
          id: id,
          receivedChunkIndices: receivedChunkIndices,
          repoIdentifier: repoIdentifier,
          transferMode: transferMode,
          from: peerId
        )
      }
      
    default:
      logger.debug("Received message: \(message.messageType) from \(peerId)")
    }
  }
}

// MARK: - BonjourDiscoveryDelegate

extension SwarmCoordinator: BonjourDiscoveryDelegate {
  public func discoveryService(_ service: BonjourDiscoveryService, didDiscover peer: DiscoveredPeer) {
    // Auto-connect to discovered peers regardless of role.
    // Workers need to connect to brains, and brains to workers.
    // Both sides run a TCP listener, so either can initiate.
    
    // Skip if already connected AND has recent heartbeat
    if connectedWorkers.contains(where: { $0.id == peer.id }) {
      // Check if the worker has a recent heartbeat (not stale)
      if let status = workerStatuses[peer.id] {
        let age = Date().timeIntervalSince(status.lastHeartbeat)
        if age < heartbeatStaleThreshold {
          // Connection is healthy, skip
          return
        }
        // Connection seems stale, let it try to reconnect
        logger.info("Discovered peer \(peer.name) but existing connection is stale (\(Int(age))s since heartbeat), allowing reconnect")
      } else {
        // No status yet but in connected list - might be mid-handshake, skip
        return
      }
    }
    
    logger.info("Discovered peer: \(peer.name), initiating WebRTC session...")
    
    Task {
      do {
        try await self.connectToWorker(peerId: peer.id)
      } catch {
        logger.error("Failed to connect to discovered peer \(peer.name): \(error)")
      }
    }
  }
  
  public func discoveryService(_ service: BonjourDiscoveryService, didLose peerId: String) {
    logger.info("Lost peer: \(peerId)")
  }
  
  public func discoveryService(_ service: BonjourDiscoveryService, didResolve peer: DiscoveredPeer) {
    logger.debug("Resolved peer: \(peer.name) at \(peer.resolvedAddress ?? "?")")
  }
  
  public func discoveryService(_ service: BonjourDiscoveryService, didFailWithError error: Error) {
    logger.error("Discovery error: \(error)")
  }
}

// MARK: - PRQueueDelegate

extension SwarmCoordinator: PRQueueDelegate {
  public func prQueue(
    _ queue: PRQueue,
    createPRForBranch branch: String,
    baseBranch: String,
    title: String,
    body: String,
    labels: [String],
    isDraft: Bool,
    in repoPath: String
  ) async throws -> (Int, String) {
    // Build gh pr create command
    var args = ["pr", "create", "--head", branch, "--base", baseBranch, "--title", title, "--body", body]
    for label in labels {
      args.append("--label")
      args.append(label)
    }
    if isDraft {
      args.append("--draft")
    }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh"] + args
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    
    try process.run()
    process.waitUntilExit()
    
    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
    
    if process.terminationStatus != 0 {
      throw PRQueueError.prCreationFailed(errorOutput)
    }
    
    // Parse PR URL from output (format: https://github.com/owner/repo/pull/123)
    let prURL = output.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Extract PR number from URL
    if let range = prURL.range(of: #"/pull/(\d+)"#, options: .regularExpression),
       let numberMatch = prURL[range].split(separator: "/").last,
       let prNumber = Int(numberMatch) {
      return (prNumber, prURL)
    }
    
    // Fallback: try to get PR number from gh
    let listProcess = Process()
    listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    listProcess.arguments = ["gh", "pr", "view", branch, "--json", "number", "-q", ".number"]
    listProcess.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    
    let listStdout = Pipe()
    listProcess.standardOutput = listStdout
    listProcess.standardError = FileHandle.nullDevice
    
    try listProcess.run()
    listProcess.waitUntilExit()
    
    let listOutput = String(data: listStdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if let prNumber = Int(listOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return (prNumber, prURL)
    }
    
    throw PRQueueError.prCreationFailed("Could not determine PR number")
  }
  
  public func prQueue(_ queue: PRQueue, addLabel label: String, toPR prNumber: Int, in repoPath: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh", "pr", "edit", String(prNumber), "--add-label", label]
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    
    try process.run()
    process.waitUntilExit()
  }
  
  public func prQueue(_ queue: PRQueue, addComment comment: String, toPR prNumber: Int, in repoPath: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh", "pr", "comment", String(prNumber), "--body", comment]
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    
    try process.run()
    process.waitUntilExit()
  }
  
  public func prQueue(_ queue: PRQueue, ensureLabelsExistIn repoPath: String) async throws {
    for label in PeelPRLabel.allCases {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [
        "gh", "label", "create", label.rawValue,
        "--description", label.description,
        "--color", label.color,
        "--force"
      ]
      process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      
      try process.run()
      process.waitUntilExit()
      // Continue even if label exists (--force handles this)
    }
    logger.info("Ensured all Peel labels exist in \(repoPath)")
  }
}

// MARK: - FirestoreTaskExecutionDelegate

extension SwarmCoordinator: FirestoreTaskExecutionDelegate {
  public func executeTask(_ request: ChainRequest) async -> ChainResult {
    let startTime = Date()
    
    // Resolve working directory for this machine via RepoRegistry
    let resolvedDir = RepoRegistry.shared.resolveWorkingDirectory(for: request)
    let resolvedRequest = ChainRequest(
      id: request.id,
      templateName: request.templateName,
      prompt: request.prompt,
      workingDirectory: resolvedDir,
      repoRemoteURL: request.repoRemoteURL,
      priority: request.priority,
      timeoutSeconds: request.timeoutSeconds
    )
    
    guard let executor = chainExecutor else {
      return ChainResult(
        requestId: request.id,
        status: .failed,
        duration: 0,
        workerDeviceId: WorkerCapabilities.current().deviceId,
        workerDeviceName: WorkerCapabilities.current().deviceName,
        errorMessage: "No chain executor configured in SwarmCoordinator"
      )
    }
    
    do {
      let outputs = try await executor.execute(request: resolvedRequest)
      let duration = Date().timeIntervalSince(startTime)
      return ChainResult(
        requestId: request.id,
        status: .completed,
        outputs: outputs,
        duration: duration,
        workerDeviceId: WorkerCapabilities.current().deviceId,
        workerDeviceName: WorkerCapabilities.current().deviceName
      )
    } catch {
      let duration = Date().timeIntervalSince(startTime)
      return ChainResult(
        requestId: request.id,
        status: .failed,
        duration: duration,
        workerDeviceId: WorkerCapabilities.current().deviceId,
        workerDeviceName: WorkerCapabilities.current().deviceName,
        errorMessage: error.localizedDescription
      )
    }
  }
}

// MARK: - LAN Address Discovery

extension SwarmCoordinator {
  /// Get the local LAN IP address (en0) for peer-to-peer connections.
  static func getLocalLANAddress() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    process.arguments = ["getifaddr", "en0"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let address = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (address?.isEmpty == false) ? address : nil
    } catch {
      return nil
    }
  }
}

// MARK: - Error Types

struct SwarmTransferError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
