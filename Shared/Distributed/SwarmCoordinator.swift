// SwarmCoordinator.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// Coordinates the distributed swarm - manages workers and task dispatch.
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │  ARCHITECTURE INVARIANT — DO NOT CHANGE WITHOUT OWNER APPROVAL     │
// │                                                                     │
// │  Firestore is the SOLE coordination layer for:                      │
// │    • Task dispatch (submitTask → task queue → worker claims)        │
// │    • Worker status & heartbeats                                     │
// │    • Member management & permissions                                │
// │    • Task results & completion                                      │
// │    • Direct commands & update-workers                               │
// │    • All cross-network communication                                │
// │                                                                     │
// │  P2P TCP connections (LAN/WAN/STUN) are ONLY for:                   │
// │    • Large file transfers (RAG artifacts/embeddings)                 │
// │    • Nothing else. Zero. Nada.                                      │
// │                                                                     │
// │  If you are adding a feature that sends status, commands, tasks,    │
// │  or coordination messages: USE FIRESTORE, not P2P TCP.              │
// │  If you are transferring large binary data: USE P2P with Firestore  │
// │  relay as fallback (see OnDemandPeerTransfer.swift).                │
// │                                                                     │
// │  connectedWorkers (TCP peers) must NEVER be a prerequisite for      │
// │  task dispatch, direct commands, or worker updates.                  │
// └─────────────────────────────────────────────────────────────────────┘
//

import Foundation
import FirebaseFirestore
import Network
import SwiftData
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
  
  /// Pending direct command continuations (for awaiting results)
  private var pendingDirectCommands: [UUID: CheckedContinuation<DirectCommandResult, Never>] = [:]

  /// Pending incoming RAG artifact transfers
  private var incomingRagTransfers: [UUID: RAGIncomingTransfer] = [:]

  /// Heartbeat loop task (worker/hybrid)
  private var heartbeatTask: Task<Void, Never>?

  /// Heartbeat monitor task (brain/hybrid) - detects stale workers
  private var heartbeatMonitorTask: Task<Void, Never>?

  /// Watchdog task that detects stalled RAG transfers
  private var ragTransferWatchdogTask: Task<Void, Never>?

  /// How long to wait for a chunk before declaring a transfer stalled (seconds)
  private let ragTransferStalledThreshold: TimeInterval = 60

  /// Maximum number of automatic resume attempts per transfer
  private let ragTransferMaxRetries = 3

  /// Network path monitor for sleep/wake reconnection
  private var pathMonitor: NWPathMonitor?
  private var lastPathStatus: NWPath.Status = .satisfied

  /// WAN auto-connect task
  private var wanAutoConnectTask: Task<Void, Never>?

  /// LAN reconnect task — retries discovered-but-not-connected Bonjour peers
  private var lanReconnectTask: Task<Void, Never>?

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
  
  /// Connection manager
  private var connectionManager: PeerConnectionManager?
  
  /// Discovery service
  private var discoveryService: BonjourDiscoveryService?
  
  /// NAT traversal manager for UDP hole punching across networks
  private var natTraversalManager: NATTraversalManager?

  /// Public read-only access to NAT traversal manager (for STUN diagnostics)
  public var natTraversal: NATTraversalManager? { natTraversalManager }

  /// STUN signaling responder (answers incoming hole-punch offers via Firestore)
  private var stunSignalingResponder: STUNSignalingResponder?

  /// Firestore relay provider (serves RAG data through Firestore when direct P2P fails)
  private var firestoreRelayProvider: FirestoreRelayProvider?

  /// Whether the Firestore relay provider is currently active (for diagnostics)
  public var isRelayProviderActive: Bool { firestoreRelayProvider != nil }

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
  
  /// Pending task continuations (for async result delivery)
  private var pendingTasks: [UUID: CheckedContinuation<ChainResult, Error>] = [:]
  
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
    
    // Create connection manager
    connectionManager = PeerConnectionManager(capabilities: capabilities, port: port)
    connectionManager?.delegate = self
    try connectionManager?.start()
    
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
    // NOTE: Always-on STUN removed — STUN is now on-demand via OnDemandPeerTransfer
    startWANAutoConnect()

    // Periodically retry LAN peers that were discovered but not connected
    startLANReconnect()

    // Start the RAG sync coordinator for on-demand P2P index sharing
    RAGSyncCoordinator.shared.ragSyncDelegate = ragSyncDelegate
    RAGSyncCoordinator.shared.start()

    // Start STUN signaling responder — watches Firestore for incoming
    // hole-punch offers and writes answers so bilateral exchange works
    startSTUNSignalingResponder(port: port)

    // Start Firestore relay provider — serves RAG data through Firestore
    // when direct P2P connections (LAN/WAN/STUN) all fail
    startFirestoreRelayProvider()

    // Feed version + relay status into Firestore heartbeats
    configureFirestoreHeartbeatMetadata()

    // Start watchdog for stalled RAG transfers and clean up expired checkpoints
    startRagTransferWatchdog()
    cleanupStaleCheckpoints()
  }

  /// Stop the swarm coordinator
  public func stop() {
    isActive = false

    RAGSyncCoordinator.shared.stop()
    stunSignalingResponder?.stop()
    stunSignalingResponder = nil
    firestoreRelayProvider?.stop()
    firestoreRelayProvider = nil
    FirebaseService.shared.heartbeatMetadata = nil
    stopNetworkMonitor()
    stopWANAutoConnect()
    stopLANReconnect()
    stopRagTransferWatchdog()
    natTraversalManager?.stop()
    natTraversalManager = nil
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
    let port = connectionManager?.port ?? 8766

    // 1. Restart Bonjour discovery + advertising
    discoveryService?.stopAdvertising()
    discoveryService?.stopDiscovery()
    try? discoveryService?.startAdvertising(capabilities: capabilities, port: port)
    discoveryService?.startDiscovery()
    logger.info("Bonjour restarted after network restore")

    // 2. Restart TCP listener (connections are gone after sleep)
    connectionManager?.stop()
    connectionManager = PeerConnectionManager(capabilities: capabilities, port: port)
    connectionManager?.delegate = self
    try? connectionManager?.start()
    connectedWorkers.removeAll()
    workerStatuses.removeAll()
    logger.info("TCP listener restarted after network restore")

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
      metadata["relayProviderActive"] = self?.isRelayProviderActive ?? false
      return metadata
    }
    FirebaseService.shared.onWorkersSnapshotChanged = { [weak self] in
      self?.firestoreWorkerVersion += 1
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

  /// Check for workers with stale heartbeats and disconnect them
  private func checkWorkerHeartbeats() async {
    let now = Date()
    var staleWorkers: [String] = []

    for (peerId, status) in workerStatuses {
      let age = now.timeIntervalSince(status.lastHeartbeat)
      if age > heartbeatStaleThreshold {
        logger.warning("Worker \(peerId) heartbeat stale by \(Int(age))s, disconnecting")
        staleWorkers.append(peerId)
      }
    }

    // Disconnect stale workers - this will trigger didDisconnect and allow reconnection
    for peerId in staleWorkers {
      await connectionManager?.disconnect(from: peerId)
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
      gitCommitHash: capabilities.gitCommitHash,
      relayProviderActive: isRelayProviderActive
    )
  }

  private func sendHeartbeat() async {
    guard role == .worker || role == .hybrid else { return }
    let status = currentWorkerStatus()
    let peers = connectionManager?.getConnectedPeers() ?? []
    for peer in peers {
      try? await connectionManager?.send(.heartbeat(status: status), to: peer.id)
    }
  }
  
  // MARK: - Crown Methods
  
  /// Connect to a worker at the given address
  public func connectToWorker(address: String, port: UInt16 = 8766) async throws {
    guard isActive else {
      throw DistributedError.actorSystemNotReady
    }
    
    try await connectionManager?.connect(to: address, port: port)
  }

  /// Manually connect to a Firestore-discovered WAN worker.
  /// Tries WAN direct TCP → STUN hole-punch, promoting to a persistent peer connection on success.
  public func connectToWANWorker(_ worker: FirestoreWorker) async throws {
    guard isActive else {
      throw DistributedError.actorSystemNotReady
    }
    guard let connectionManager else {
      throw DistributedError.actorSystemNotReady
    }

    // Try WAN direct TCP first
    if let address = worker.wanAddress, let port = worker.wanPort {
      logger.info("Manual WAN connect: trying direct TCP to \(worker.displayName) at \(address):\(port)")
      do {
        try await connectionManager.connect(to: address, port: port)
        // Clear from auto-connect retry set on success
        wanConnectAttempted.removeValue(forKey: worker.id)
        logger.info("Manual WAN connect: TCP connected to \(worker.displayName) via direct WAN")
        return
      } catch {
        logger.warning("Manual WAN connect: direct TCP failed — \(error.localizedDescription)")
      }
    } else {
      logger.info("Manual WAN connect: \(worker.displayName) has no WAN endpoint (wanAddress=\(worker.wanAddress ?? "nil"), wanPort=\(worker.wanPort.map(String.init) ?? "nil"))")
    }

    // Try STUN hole-punch
    guard let swarmId = FirebaseService.shared.memberSwarms.first?.id else {
      throw DistributedError.connectionFailed(deviceId: worker.id, reason: "No swarm membership for STUN signaling")
    }

    logger.info("Manual WAN connect: trying STUN hole-punch to \(worker.displayName)")
    guard let myEndpoint = await STUNClient.discoverEndpoint(localPort: 0) else {
      throw DistributedError.connectionFailed(deviceId: worker.id, reason: "STUN endpoint discovery failed")
    }

    // Write STUN offer
    let myDeviceId = capabilities.deviceId
    let db = Firestore.firestore()
    let offerRef = db.collection("swarms/\(swarmId)/stunSignaling")
      .document("\(myDeviceId)_to_\(worker.id)")
    try await offerRef.setData([
      "fromWorkerId": myDeviceId,
      "toWorkerId": worker.id,
      "stunAddress": myEndpoint.address,
      "stunPort": Int(myEndpoint.port),
      "createdAt": FieldValue.serverTimestamp(),
      "expiresAt": Timestamp(date: Date().addingTimeInterval(60)),
    ])

    // Wait for STUN answer
    let answerRef = db.collection("swarms/\(swarmId)/stunSignaling")
      .document("\(worker.id)_to_\(myDeviceId)")
    let deadline = Date().addingTimeInterval(30)
    var peerEndpoint: (address: String, port: UInt16)?
    while Date() < deadline {
      let doc = try await answerRef.getDocument()
      if let data = doc.data(),
         let address = data["stunAddress"] as? String,
         let port = data["stunPort"] as? Int {
        try? await answerRef.delete()
        peerEndpoint = (address, UInt16(port))
        break
      }
      try await Task.sleep(for: .seconds(1))
    }

    guard let peer = peerEndpoint else {
      throw DistributedError.connectionFailed(deviceId: worker.id, reason: "STUN signaling timed out — peer may be offline")
    }

    // Send UDP hole-punch probes
    let udpEndpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(peer.address),
      port: NWEndpoint.Port(rawValue: peer.port)!
    )
    let udpConn = NWConnection(to: udpEndpoint, using: .udp)
    udpConn.start(queue: .global())
    for i in 0..<5 {
      try? await Task.sleep(for: .milliseconds(200))
      let probe = "PEEL_PUNCH_\(i)".data(using: .utf8)!
      udpConn.send(content: probe, completion: .contentProcessed { _ in })
    }
    udpConn.cancel()

    // Connect TCP through the punched hole
    try await connectionManager.connect(to: peer.address, port: peer.port)
    logger.info("Manual WAN connect: STUN hole-punch connected to \(worker.displayName)")
  }

  // MARK: - WAN Auto-Connect

  /// Check Firestore workers for WAN/STUN endpoints and auto-connect.
  /// Priority: STUN hole punch (no router config) → direct TCP.
  /// Failed attempts are retried after `wanConnectRetryInterval` (2 min).
  public func autoConnectWANPeers() {
    guard isActive else { return }

    let myDeviceId = capabilities.deviceId
    let alreadyConnected = Set(connectedWorkers.map(\.id))
    let firebaseService = FirebaseService.shared
    let now = Date()

    // Expire old attempts so we can retry
    wanConnectAttempted = wanConnectAttempted.filter { _, attemptDate in
      now.timeIntervalSince(attemptDate) < wanConnectRetryInterval
    }

    for worker in firebaseService.swarmWorkers {
      // Skip self, already-connected, recently-attempted, stale
      guard worker.id != myDeviceId,
            !alreadyConnected.contains(worker.id),
            wanConnectAttempted[worker.id] == nil,
            worker.status == .online,
            !worker.isStale else {
        continue
      }

      // Must have a WAN endpoint (STUN auto-connect removed — now on-demand)
      guard worker.hasWANEndpoint else { continue }

      wanConnectAttempted[worker.id] = now

      Task {
        // Direct TCP to WAN address (requires port forwarding / UPnP)
        if let address = worker.wanAddress,
           let port = worker.wanPort {
          logger.info("WAN auto-connect: attempting direct TCP to \(worker.displayName) at \(address):\(port)")
          do {
            try await connectionManager?.connect(to: address, port: port)
            logger.info("WAN auto-connect: TCP connected to \(worker.displayName) via direct WAN")
            // Clear from attempted on success so we don't expire and retry a working connection
            await MainActor.run { self.wanConnectAttempted.removeValue(forKey: worker.id) }
            return
          } catch {
            logger.warning("WAN auto-connect: direct TCP failed to \(worker.displayName) at \(address):\(port) — \(error.localizedDescription)")
          }
        }

        logger.info("WAN auto-connect: all P2P methods failed for \(worker.displayName) — will retry in \(Int(self.wanConnectRetryInterval))s")
      }
    }
  }

  /// Start watching for WAN-connectable workers
  func startWANAutoConnect() {
    stopWANAutoConnect()
    wanAutoConnectTask = Task { [weak self] in
      guard let self else { return }

      // NOTE: STUN discovery removed from startup — now on-demand via OnDemandPeerTransfer
      // We still auto-connect to WAN peers that have direct addresses (port forwarding/UPnP)

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

  /// Update all Firestore worker registrations with our STUN-discovered endpoint
  private func updateFirestoreWithSTUNEndpoint(_ stunResult: STUNResult) async {
    let firebaseService = FirebaseService.shared
    guard firebaseService.isSignedIn else { return }

    let workerId = capabilities.deviceId
    for swarm in firebaseService.memberSwarms where swarm.role.canRegisterWorkers {
      do {
        try await firebaseService.updateWorkerSTUNEndpoint(
          swarmId: swarm.id,
          workerId: workerId,
          stunAddress: stunResult.address,
          stunPort: stunResult.port
        )
        logger.info("Updated STUN endpoint in swarm \(swarm.swarmName): \(stunResult.address):\(stunResult.port)")
      } catch {
        logger.warning("Failed to update STUN endpoint in swarm \(swarm.swarmName): \(error.localizedDescription)")
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
              try await self.connectionManager?.connect(to: peer.endpoint)
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

  /// Start the STUN signaling responder for all member swarms.
  /// This watches Firestore for incoming STUN offers and writes answers,
  /// completing the bilateral exchange needed for NAT hole-punching.
  private func startSTUNSignalingResponder(port: UInt16) {
    let firebaseService = FirebaseService.shared
    guard firebaseService.isSignedIn else {
      logger.info("Not signed in — skipping STUN signaling responder")
      return
    }

    let swarmIds = firebaseService.memberSwarms
      .filter { $0.role.canRegisterWorkers }
      .map(\.id)

    guard !swarmIds.isEmpty else {
      logger.info("No swarms to listen for STUN offers")
      return
    }

    let responder = STUNSignalingResponder(listeningPort: port)
    responder.start(swarmIds: swarmIds, myDeviceId: capabilities.deviceId)
    stunSignalingResponder = responder
  }

  // MARK: - Firestore Relay Provider

  /// Start the Firestore relay provider for all member swarms.
  /// This watches for relay requests and serves RAG data through Firestore
  /// when direct P2P connections are impossible.
  private func startFirestoreRelayProvider() {
    let firebaseService = FirebaseService.shared
    guard firebaseService.isSignedIn else {
      logger.info("Not signed in — skipping Firestore relay provider")
      return
    }

    let swarmIds = firebaseService.memberSwarms
      .filter { $0.role.canRegisterWorkers }
      .map(\.id)

    guard !swarmIds.isEmpty else {
      logger.info("No swarms to listen for relay requests")
      return
    }

    let provider = FirestoreRelayProvider()
    provider.ragSyncDelegate = ragSyncDelegate
    provider.start(swarmIds: swarmIds, myDeviceId: capabilities.deviceId)
    firestoreRelayProvider = provider
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
    
    // Send task and wait for result using continuation
    let result: ChainResult = try await withCheckedThrowingContinuation { continuation in
      // Store continuation for when result arrives
      pendingTasks[request.id] = continuation
      
      // Send task to worker
      Task {
        do {
          try await connectionManager?.send(.taskRequest(request: request), to: worker.id)
        } catch {
          pendingTasks.removeValue(forKey: request.id)
          branchQueue.releaseBranch(taskId: request.id)
          continuation.resume(throwing: error)
        }
      }
      
      // Setup timeout
      Task {
        try? await Task.sleep(for: .seconds(Double(request.timeoutSeconds)))
        if let cont = pendingTasks.removeValue(forKey: request.id) {
          branchQueue.releaseBranch(taskId: request.id)
          cont.resume(throwing: DistributedError.taskTimeout(taskId: request.id))
        }
      }
    }
    
    return result
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
    
    guard connectedWorkers.contains(where: { $0.id == workerId }) else {
      throw DistributedError.noWorkersAvailable
    }
    
    logger.info("Dispatching task \(request.id) to specific worker \(workerId)")
    
    // Fire and forget - don't wait for result (worker will restart)
    try await connectionManager?.send(.taskRequest(request: request), to: workerId)
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
    
    guard connectedWorkers.contains(where: { $0.id == workerId }) else {
      throw DistributedError.noWorkersAvailable
    }
    
    let id = UUID()
    logger.info("Sending direct command to \(workerId): \(command)")
    
    let message = PeerMessage.directCommand(id: id, command: command, args: args, workingDirectory: workingDirectory)
    try await connectionManager?.send(message, to: workerId)
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
    
    guard connectedWorkers.contains(where: { $0.id == workerId }) else {
      throw DistributedError.noWorkersAvailable
    }
    
    let id = UUID()
    logger.info("Sending direct command (waiting): \(command) to \(workerId)")
    
    // Set up continuation to receive result
    let result: DirectCommandResult = await withCheckedContinuation { continuation in
      pendingDirectCommands[id] = continuation
      
      Task {
        let message = PeerMessage.directCommand(id: id, command: command, args: args, workingDirectory: workingDirectory)
        do {
          try await connectionManager?.send(message, to: workerId)
        } catch {
          // If send fails, resume with error result
          pendingDirectCommands.removeValue(forKey: id)
          continuation.resume(returning: DirectCommandResult(exitCode: -1, output: "", error: error.localizedDescription))
        }
      }
      
      // Set up timeout
      Task {
        try? await Task.sleep(for: timeout)
        if let cont = pendingDirectCommands.removeValue(forKey: id) {
          cont.resume(returning: DirectCommandResult(exitCode: -1, output: "", error: "Timeout waiting for command result"))
        }
      }
    }
    
    return result
  }

  // MARK: - RAG Artifact Sync

  public func updateLocalRagArtifactStatus(_ status: RAGArtifactStatus?) {
    localRagArtifactStatus = status
  }

  /// Request an on-demand RAG index pull from a Firestore worker via OnDemandPeerTransfer.
  /// This is used when no TCP-connected peers are available (WAN scenario).
  /// Only supports pull direction — push requires an established TCP connection.
  public func requestRagSyncOnDemand(
    repoIdentifier: String,
    fromWorkerId: String
  ) async throws {
    guard isActive else {
      throw DistributedError.actorSystemNotReady
    }

    let firebaseService = FirebaseService.shared
    guard let swarmId = firebaseService.memberSwarms.first?.id else {
      throw DistributedError.connectionFailed(deviceId: fromWorkerId, reason: "No swarm membership found")
    }

    try await RAGSyncCoordinator.shared.syncIndex(
      repoIdentifier: repoIdentifier,
      fromWorkerId: fromWorkerId,
      swarmId: swarmId
    )
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
      guard let worker = connectedWorkers.first(where: { $0.id == workerId }) else {
        throw DistributedError.workerNotFound(deviceId: workerId)
      }
      targetWorker = worker
    } else {
      guard let worker = SwarmPeerPreferences.defaultPeer(from: connectedWorkers) else {
        throw DistributedError.noWorkersAvailable
      }
      targetWorker = worker
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

    try await connectionManager?.send(
      .ragArtifactsRequest(id: transferId, direction: direction, repoIdentifier: repoIdentifier, transferMode: transferMode),
      to: targetWorker.id
    )

    if direction == .push {
      Task { await sendRagArtifactBundle(transferId: transferId, to: targetWorker, repoIdentifier: repoIdentifier, transferMode: transferMode) }
    }

    return transferId
  }

  private func sendRagArtifactBundle(transferId: UUID, to peer: ConnectedPeer, repoIdentifier: String? = nil, transferMode: RAGTransferMode = .full, skipChunkIndices: Set<Int> = []) async {
    let isResume = !skipChunkIndices.isEmpty
    updateRagTransfer(transferId) { state in
      state.status = .preparing
    }

    logger.info("RAG sync preparing bundle for \(peer.name) (\(peer.id))\(repoIdentifier.map { ", repo: \($0)" } ?? ""), mode: \(transferMode.rawValue)\(isResume ? ", resume (skipping \(skipChunkIndices.count) chunks)" : "")")

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
        let jsonData = try JSONEncoder().encode(overlayBundle)
        let chunkSize = 256 * 1024
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
        try await connectionManager?.send(.ragArtifactsManifest(id: transferId, manifest: manifest), to: peer.id)

        var offset = 0
        var chunkIndex = 0
        while offset < jsonData.count {
          let end = min(offset + chunkSize, jsonData.count)
          let chunkData = jsonData[offset..<end]
          if !skipChunkIndices.contains(chunkIndex) {
            let base64 = chunkData.base64EncodedString()
            try await connectionManager?.send(
              .ragArtifactsChunk(id: transferId, index: chunkIndex, total: totalChunks, data: base64),
              to: peer.id
            )
          }
          updateRagTransfer(transferId) { state in
            state.transferredBytes += chunkData.count
          }
          offset = end
          chunkIndex += 1
        }

        try await connectionManager?.send(.ragArtifactsComplete(id: transferId), to: peer.id)
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
        let jsonData = try JSONEncoder().encode(repoBundle)
        let chunkSize = 256 * 1024
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
        try await connectionManager?.send(.ragArtifactsManifest(id: transferId, manifest: manifest), to: peer.id)

        // Send in chunks
        var offset = 0
        var chunkIndex = 0
        while offset < jsonData.count {
          let end = min(offset + chunkSize, jsonData.count)
          let chunkData = jsonData[offset..<end]
          if !skipChunkIndices.contains(chunkIndex) {
            let base64 = chunkData.base64EncodedString()
            try await connectionManager?.send(
              .ragArtifactsChunk(id: transferId, index: chunkIndex, total: totalChunks, data: base64),
              to: peer.id
            )
          }
          updateRagTransfer(transferId) { state in
            state.transferredBytes += chunkData.count
          }
          offset = end
          chunkIndex += 1
        }

        try await connectionManager?.send(.ragArtifactsComplete(id: transferId), to: peer.id)
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
      let chunkSize = 256 * 1024
      let totalChunks = max(1, Int(ceil(Double(max(1, fileSize)) / Double(chunkSize))))

      logger.info("RAG sync bundle created: \(bundle.manifest.version), \(fileSize) bytes, \(totalChunks) chunks")

      updateRagTransfer(transferId) { state in
        state.status = .transferring
        state.totalBytes = fileSize
        state.manifestVersion = bundle.manifest.version
      }

      try await connectionManager?.send(.ragArtifactsManifest(id: transferId, manifest: bundle.manifest), to: peer.id)

      let handle = try FileHandle(forReadingFrom: bundle.bundleURL)
      defer { try? handle.close() }

      var chunkIndex = 0
      while true {
        let data = try handle.read(upToCount: chunkSize) ?? Data()
        if data.isEmpty { break }
        if !skipChunkIndices.contains(chunkIndex) {
          let base64 = data.base64EncodedString()
          try await connectionManager?.send(
            .ragArtifactsChunk(id: transferId, index: chunkIndex, total: totalChunks, data: base64),
            to: peer.id
          )
        }
        updateRagTransfer(transferId) { state in
          state.transferredBytes += data.count
        }
        chunkIndex += 1
      }

      try await connectionManager?.send(.ragArtifactsComplete(id: transferId), to: peer.id)
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
    incomingRagTransfers[id] = transfer
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
    transfer.receivedBytes = 0
    transfer.receivedChunks = 0
    incomingRagTransfers[id] = transfer

    if FileManager.default.fileExists(atPath: transfer.tempURL.path) {
      try? FileManager.default.removeItem(at: transfer.tempURL)
    }
    FileManager.default.createFile(atPath: transfer.tempURL.path, contents: Data())
    transfer.fileHandle = try? FileHandle(forWritingTo: transfer.tempURL)

    updateRagTransfer(id) { state in
      state.status = .transferring
      state.totalBytes = manifest.totalBytes
      state.manifestVersion = manifest.version
    }
  }

  private func handleRagArtifactsChunk(id: UUID, index: Int, total: Int, data: String) {
    guard let transfer = incomingRagTransfers[id] else { return }
    guard let decoded = Data(base64Encoded: data) else {
      updateRagTransfer(id) { state in
        state.status = .failed
        state.errorMessage = "Failed to decode artifact chunk"
        state.completedAt = Date()
      }
      Task { await sendRagArtifactError(transferId: id, to: transfer.peerId, message: "Failed to decode artifact chunk") }
      incomingRagTransfers.removeValue(forKey: id)
      return
    }
    transfer.fileHandle?.seekToEndOfFile()
    transfer.fileHandle?.write(decoded)
    transfer.receivedChunks += 1
    transfer.receivedBytes += decoded.count
    transfer.expectedChunks = total
    transfer.receivedChunkIndices.insert(index)
    transfer.lastChunkReceivedAt = Date()

    updateRagTransfer(id) { state in
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
      updateRagTransfer(id) { state in
        state.status = .failed
        state.errorMessage = "Incomplete transfer (\(transfer.receivedChunks)/\(expected) chunks)"
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
        let jsonData = try Data(contentsOf: transfer.tempURL)
        let repoBundle = try JSONDecoder().decode(RAGRepoExportBundle.self, from: jsonData)
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
        let jsonData = try Data(contentsOf: transfer.tempURL)
        let overlayBundle = try JSONDecoder().decode(RAGRepoOverlayBundle.self, from: jsonData)
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

  private func sendRagArtifactError(transferId: UUID, to peerId: String, message: String) async {
    logger.error("RAG sync error \(transferId) to \(peerId): \(message)")
    try? await connectionManager?.send(.ragArtifactsError(id: transferId, message: message), to: peerId)
  }

  private func updateRagTransfer(_ id: UUID, update: (inout RAGArtifactTransferState) -> Void) {
    guard let index = ragTransfers.firstIndex(where: { $0.id == id }) else { return }
    var state = ragTransfers[index]
    update(&state)
    ragTransfers[index] = state
  }

  private func recordRagTransfer(_ transfer: RAGArtifactTransferState) {
    ragTransfers.insert(transfer, at: 0)
    if ragTransfers.count > 50 {
      ragTransfers.removeLast()
    }
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
        await self?.checkForStalledTransfers()
      }
    }
  }

  private func stopRagTransferWatchdog() {
    ragTransferWatchdogTask?.cancel()
    ragTransferWatchdogTask = nil
  }

  private func checkForStalledTransfers() {
    let now = Date()

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
      guard elapsed >= ragTransferStalledThreshold else { continue }

      // Only act on transfers that are actively receiving
      guard let status = ragTransfers.first(where: { $0.id == id })?.status,
            status == .transferring else { continue }

      logger.warning("RAG transfer \(id) stalled (\(Int(elapsed))s since last chunk, \(transfer.receivedChunks)/\(transfer.expectedChunks ?? 0) chunks)")

      // Check if the peer is still connected
      let peerConnected = connectedWorkers.contains(where: { $0.id == transfer.peerId })

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
            try? await connectionManager?.send(
              .ragArtifactsResumeRequest(
                id: id,
                receivedChunkIndices: transfer.receivedChunkIndices,
                repoIdentifier: transfer.repoIdentifier,
                transferMode: transfer.transferMode
              ),
              to: transfer.peerId
            )
          }
        } else {
          // Exhausted retries — fail the transfer
          failTransfer(id: id, message: "Transfer stalled after \(ragTransferMaxRetries) resume attempts")
        }
      } else {
        // Peer disconnected — save checkpoint and fail with "resumable" marker
        saveCheckpoint(for: transfer)
        failTransfer(id: id, message: "Peer disconnected during transfer (checkpoint saved)")
      }
    }
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

      // Create a new transfer with a new ID to avoid collisions
      let newId = UUID()
      let peerName = cp.peerName
      let transfer = RAGArtifactTransferState(
        id: newId,
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
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("rag-artifacts-\(newId).zip")
      }
      let incoming = RAGIncomingTransfer(id: newId, peerId: peerId, direction: cp.direction, tempURL: tempURL)
      incoming.manifest = cp.manifest
      incoming.expectedChunks = cp.totalChunks
      incoming.receivedChunks = cp.receivedChunkIndices.count
      incoming.receivedBytes = cp.receivedBytes
      incoming.receivedChunkIndices = cp.receivedChunkIndices
      incoming.repoIdentifier = cp.repoIdentifier
      incoming.transferMode = cp.transferMode
      incomingRagTransfers[newId] = incoming

      // Reopen file handle for appending
      if !FileManager.default.fileExists(atPath: tempURL.path) {
        FileManager.default.createFile(atPath: tempURL.path, contents: Data())
      }
      incoming.fileHandle = try? FileHandle(forWritingTo: tempURL)
      incoming.fileHandle?.seekToEndOfFile()

      logger.info("RAG transfer resume: requesting re-send for \(newId) (was \(cp.transferId)), skipping \(cp.receivedChunkIndices.count) chunks")

      // Send resume request to the peer
      Task {
        try? await connectionManager?.send(
          .ragArtifactsResumeRequest(
            id: newId,
            receivedChunkIndices: cp.receivedChunkIndices,
            repoIdentifier: cp.repoIdentifier,
            transferMode: cp.transferMode
          ),
          to: peerId
        )
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
    let peer = connectedWorkers.first(where: { $0.id == peerId })
    let peerName = peer?.name ?? "Peer"
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

    guard let actualPeer = peer else {
      await sendRagArtifactError(transferId: id, to: peerId, message: "Peer not found for resume")
      return
    }

    // Delegate to sendRagArtifactBundle with skip set
    await sendRagArtifactBundle(
      transferId: id,
      to: actualPeer,
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
      try? await connectionManager?.send(.taskResult(result: result), to: peerId)
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
      try? await connectionManager?.send(
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
    try? await connectionManager?.send(.taskAccepted(taskId: request.id), to: peerId)
    
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
    try? await connectionManager?.send(.taskResult(result: result), to: peerId)
    
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
      try? await connectionManager?.send(
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
    
    // Resolve the command - use /bin/sh -c for shell commands to get PATH resolution
    // If command is absolute path, use it directly; otherwise use shell
    let useShell = !resolvedCommand.hasPrefix("/")
    
    let process = Process()
    if useShell {
      // Use shell to resolve command via PATH
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      // If args is empty, pass command directly to shell (it may contain pipes, etc.)
      // If args is provided, escape them and append
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
      logger.info("Executing via shell: /bin/zsh -c '\(fullCommand)' in \(effectiveWorkingDir)")
    } else {
      process.executableURL = URL(fileURLWithPath: resolvedCommand)
      process.arguments = args
      logger.info("Executing direct: \(resolvedCommand) \(args.joined(separator: " ")) in \(effectiveWorkingDir)")
    }
    process.currentDirectoryURL = URL(fileURLWithPath: effectiveWorkingDir)
    
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    
    var output = ""
    var errorOutput: String? = nil
    var exitCode: Int32 = -1
    
    do {
      try process.run()
      process.waitUntilExit()
      exitCode = process.terminationStatus
      
      let outData = stdout.fileHandleForReading.readDataToEndOfFile()
      output = String(data: outData, encoding: .utf8) ?? ""
      
      let errData = stderr.fileHandleForReading.readDataToEndOfFile()
      let errStr = String(data: errData, encoding: .utf8) ?? ""
      if !errStr.isEmpty {
        errorOutput = errStr
      }
      
    } catch {
      errorOutput = error.localizedDescription
    }
    
    // Send result back
    try? await connectionManager?.send(
      .directCommandResult(id: id, exitCode: exitCode, output: output, error: errorOutput),
      to: peerId
    )
    
    logger.info("Direct command \(id) finished with exit code \(exitCode)")
  }
}

// MARK: - PeerConnectionDelegate

extension SwarmCoordinator: PeerConnectionDelegate {
  public func connectionManager(_ manager: PeerConnectionManager, didConnect peer: ConnectedPeer) {
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
  
  public func connectionManager(_ manager: PeerConnectionManager, didDisconnect peerId: String) {
    connectedWorkers.removeAll { $0.id == peerId }
    if let existing = workerStatuses[peerId] {
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

    // Save checkpoints and fail any in-progress RAG transfers from this peer
    let affectedTransfers = incomingRagTransfers.filter { $0.value.peerId == peerId }
    for (id, transfer) in affectedTransfers {
      // Only checkpoint transfers that have actually received some data
      if transfer.receivedChunks > 0 {
        saveCheckpoint(for: transfer)
        logger.info("RAG transfer \(id) checkpointed on disconnect (\(transfer.receivedChunks)/\(transfer.expectedChunks ?? 0) chunks)")
      }
      failTransfer(id: id, message: "Peer disconnected\(transfer.receivedChunks > 0 ? " (checkpoint saved, will auto-resume on reconnect)" : "")")
    }

    delegate?.swarmCoordinator(self, didEmit: .workerDisconnected(peerId))
    logger.info("Peel disconnected: \(peerId)")
  }
  
  public func connectionManager(_ manager: PeerConnectionManager, didReceive message: PeerMessage, from peerId: String) {
    switch message {
    case .taskRequest(let request):
      Task {
        await handleTaskRequest(request, from: peerId)
      }
      
    case .taskProgress(let taskId, let progress, let message):
      logger.debug("Task \(taskId) progress: \(progress) - \(message ?? "")")
      
    case .taskResult(let result):
      // Resume the waiting continuation
      if let continuation = pendingTasks.removeValue(forKey: result.requestId) {
        continuation.resume(returning: result)
      }
      // Update counters and store result
      if result.status == .completed {
        tasksCompleted += 1
        // Mark branch as completed successfully
        branchQueue.completeBranch(taskId: result.requestId, status: .success)
        
        // Auto-create PR if enabled and branch info is available
        if autoCreatePRs, let branchName = result.branchName, let repoPath = result.repoPath {
          // Find the original prompt from outputs or use generic
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
        // Mark branch as needing review
        branchQueue.completeBranch(taskId: result.requestId, status: .needsReview)
      }
      // Store result (most recent first, capped)
      completedResults.insert(result, at: 0)
      if completedResults.count > maxStoredResults {
        completedResults.removeLast()
      }
      delegate?.swarmCoordinator(self, didEmit: .taskCompleted(result))

    case .heartbeat(let status):
      workerStatuses[peerId] = status
      Task { try? await connectionManager?.send(.heartbeatAck, to: peerId) }
      
    case .directCommand(let id, let command, let args, let workingDirectory):
      logger.info("Received directCommand: \(command) from \(peerId)")
      Task {
        await handleDirectCommand(id: id, command: command, args: args, workingDirectory: workingDirectory, from: peerId)
      }
      
    case .directCommandResult(let id, let exitCode, let output, let error):
      logger.info("Direct command \(id) completed with exit code \(exitCode)")
      if let error = error, !error.isEmpty {
        logger.warning("Direct command stderr: \(error)")
      }
      if !output.isEmpty {
        logger.debug("Direct command output: \(output.prefix(500))")
      }
      // Resume any pending continuation waiting for this result
      if let continuation = pendingDirectCommands.removeValue(forKey: id) {
        continuation.resume(returning: DirectCommandResult(exitCode: exitCode, output: output, error: error))
      }

    case .ragArtifactsRequest(let id, let direction, let repoIdentifier, let transferMode):
      let peer = connectedWorkers.first(where: { $0.id == peerId })
      let peerName = peer?.name ?? "Peer"
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
        if let peer {
          Task { await sendRagArtifactBundle(transferId: id, to: peer, repoIdentifier: repoIdentifier, transferMode: transferMode ?? .full) }
        } else {
          Task { await sendRagArtifactError(transferId: id, to: peerId, message: "Peer not found") }
        }
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
      handleRagArtifactsManifest(id: id, manifest: manifest, from: peerId)

    case .ragArtifactsChunk(let id, let index, let total, let data):
      handleRagArtifactsChunk(id: id, index: index, total: total, data: data)

    case .ragArtifactsComplete(let id):
      Task { await handleRagArtifactsComplete(id: id, from: peerId) }

    case .ragArtifactsError(let id, let message):
      updateRagTransfer(id) { state in
        state.status = .failed
        state.errorMessage = message
        state.completedAt = Date()
      }

    case .ragArtifactsAck(let id, let receivedChunks, let receivedBytes):
      logger.debug("RAG ack for \(id): \(receivedChunks) chunks, \(receivedBytes) bytes")
      // Update sender-side transfer progress tracking if needed
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
  
  public func connectionManager(_ manager: PeerConnectionManager, didFailWithError error: Error) {
    logger.error("Connection error: \(error)")
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
    
    logger.info("Discovered peer: \(peer.name), connecting via endpoint...")
    
    // Connect directly via the Bonjour endpoint — avoids the old resolvePeer()
    // which created throwaway TCP connections (spurious handshake failures on
    // the remote) and could leak continuations or lose IPv6 scope IDs.
    Task {
      do {
        try await connectionManager?.connect(to: peer.endpoint)
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

// MARK: - NATTraversalDelegate

extension SwarmCoordinator: NATTraversalDelegate {
  public func natTraversal(_ manager: NATTraversalManager, didChangeState state: NATTraversalState) {
    logger.info("NAT traversal state: \(state)")
  }

  public func natTraversal(_ manager: NATTraversalManager, shouldConnectTCP address: String, port: UInt16) {
    // This is called after a successful hole punch — try TCP through the opened NAT binding
    Task {
      do {
        try await connectionManager?.connect(to: address, port: port)
        logger.info("NAT traversal: TCP connected to \(address):\(port) via hole punch")
      } catch {
        logger.warning("NAT traversal: TCP connect failed after hole punch to \(address):\(port): \(error.localizedDescription)")
      }
    }
  }

  public func natTraversalShouldFallbackToRelay(_ manager: NATTraversalManager, peerId: String) {
    logger.info("NAT traversal: hole punch failed for peer \(peerId) — no fallback available")
  }

  // MARK: - LAN Address Discovery

  /// Get the local LAN IP address (en0) for peer-to-peer connections.
  static func getLocalLANAddress() -> String? {
    #if os(macOS)
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
    #else
    return nil  // iOS doesn't support Process
    #endif
  }
}
