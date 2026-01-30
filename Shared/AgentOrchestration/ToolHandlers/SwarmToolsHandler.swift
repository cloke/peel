//
//  SwarmToolsHandler.swift
//  Peel
//
//  Created by Copilot on 2026-01-27.
//  MCP tools for distributed swarm control.

import Foundation
import MCPCore

// MARK: - Swarm Tools Handler

/// Handles swarm/distributed coordination tools: swarm.start, swarm.stop, swarm.status, swarm.workers
@MainActor
public final class SwarmToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?
  
  /// Chain runner for executing tasks (needed for worker mode)
  private let chainRunner: AgentChainRunner?
  
  /// Agent manager for finding chain templates and creating chains
  private let agentManager: AgentManager?
  
  public let supportedTools: Set<String> = [
    "swarm.start",
    "swarm.stop",
    "swarm.status",
    "swarm.diagnostics",
    "swarm.rag.sync",
    "swarm.workers",
    "swarm.dispatch",
    "swarm.connect",
    "swarm.discovered",
    "swarm.tasks",
    "swarm.update-workers",
    "swarm.update-log",
    "swarm.direct-command",
    "swarm.branch-queue",
    "swarm.pr-queue",
    "swarm.create-pr",
    "swarm.setup-labels",
    "swarm.register-repo",
    "swarm.repos"
  ]
  
  public init(chainRunner: AgentChainRunner? = nil, agentManager: AgentManager? = nil) {
    self.chainRunner = chainRunner
    self.agentManager = agentManager
  }
  
  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "swarm.start":
      return await handleStart(id: id, arguments: arguments)
    case "swarm.stop":
      return await handleStop(id: id)
    case "swarm.status":
      return handleStatus(id: id)
    case "swarm.diagnostics":
      return handleDiagnostics(id: id)
    case "swarm.rag.sync":
      return await handleRagSync(id: id, arguments: arguments)
    case "swarm.workers":
      return handleWorkers(id: id)
    case "swarm.dispatch":
      return await handleDispatch(id: id, arguments: arguments)
    case "swarm.connect":
      return await handleConnect(id: id, arguments: arguments)
    case "swarm.discovered":
      return handleDiscovered(id: id)
    case "swarm.tasks":
      return handleTasks(id: id, arguments: arguments)
    case "swarm.update-workers":
      return await handleUpdateWorkers(id: id, arguments: arguments)
    case "swarm.update-log":
      return await handleUpdateLog(id: id, arguments: arguments)
    case "swarm.direct-command":
      return await handleDirectCommand(id: id, arguments: arguments)
    case "swarm.branch-queue":
      return handleBranchQueue(id: id, arguments: arguments)
    case "swarm.pr-queue":
      return handlePRQueue(id: id, arguments: arguments)
    case "swarm.create-pr":
      return await handleCreatePR(id: id, arguments: arguments)
    case "swarm.setup-labels":
      return await handleSetupLabels(id: id, arguments: arguments)
    case "swarm.register-repo":
      return await handleRegisterRepo(id: id, arguments: arguments)
    case "swarm.repos":
      return handleRepos(id: id)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }
  
  // MARK: - Tool Definitions
  
  public static func toolDefinitions() -> [[String: Any]] {
    [
      [
        "name": "swarm.start",
        "description": "Start the distributed swarm coordinator. Role can be 'brain' (Crown: dispatches work), 'worker' (Peel: executes work), or 'hybrid' (Crown + Peel).",
        "inputSchema": [
          "type": "object",
          "properties": [
            "role": [
              "type": "string",
              "enum": ["brain", "worker", "hybrid"],
              "description": "The role for this Peel instance in the swarm"
            ],
            "port": [
              "type": "integer",
              "description": "Port to listen on (default: 8766)"
            ]
          ],
          "required": ["role"]
        ]
      ],
      [
        "name": "swarm.stop",
        "description": "Stop the distributed swarm coordinator and disconnect from all peers.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.status",
        "description": "Get the current swarm status including role, active state, and statistics.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.diagnostics",
        "description": "Dev diagnostics snapshot: peers, discovery, and RAG artifact sync status.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.rag.sync",
        "description": "Request a Local RAG artifact sync to or from a peel. Direction is 'push' or 'pull'.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "direction": [
              "type": "string",
              "enum": ["push", "pull"],
              "description": "Sync direction: push sends artifacts to the peel, pull fetches from it"
            ],
            "workerId": [
              "type": "string",
              "description": "Optional worker device ID (defaults to first connected peel)"
            ]
          ],
          "required": ["direction"]
        ]
      ],
      [
        "name": "swarm.workers",
        "description": "List all connected peels/trees with their capabilities.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.dispatch",
        "description": "Dispatch a task to the swarm for execution by a peel.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "prompt": [
              "type": "string",
              "description": "The prompt/task to execute"
            ],
            "templateId": [
              "type": "string",
              "description": "Optional template ID to use"
            ],
            "priority": [
              "type": "string",
              "enum": ["low", "normal", "high", "critical"],
              "description": "Task priority (default: normal)"
            ]
          ],
          "required": ["prompt"]
        ]
      ],
      [
        "name": "swarm.connect",
        "description": "Manually connect to a peer at a specific address. Use for debugging or when auto-discovery fails.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "address": [
              "type": "string",
              "description": "IP address or hostname of the peer"
            ],
            "port": [
              "type": "integer",
              "description": "Port number (default: 8766)"
            ]
          ],
          "required": ["address"]
        ]
      ],
      [
        "name": "swarm.discovered",
        "description": "List peers discovered via Bonjour (not yet connected).",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.tasks",
        "description": "Get completed task results. Returns recent task outputs from the swarm.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "taskId": [
              "type": "string",
              "description": "Optional: Get results for a specific task ID"
            ],
            "limit": [
              "type": "integer",
              "description": "Maximum number of results to return (default: 10)"
            ]
          ],
          "required": []
        ]
      ],
      [
        "name": "swarm.update-workers",
        "description": "Trigger all connected peels/trees to pull latest code, rebuild, and restart. Nodes will disconnect briefly during restart.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "force": [
              "type": "boolean",
              "description": "Force rebuild even if no new commits (default: false)"
            ]
          ],
          "required": []
        ]
      ],
      [
        "name": "swarm.update-log",
        "description": "Fetch the latest lines from the peel self-update log.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "lines": [
              "type": "integer",
              "description": "Number of log lines to return (default: 200, max: 500)"
            ],
            "workerId": [
              "type": "string",
              "description": "Specific peel ID to target (optional, defaults to first available)"
            ]
          ],
          "required": []
        ]
      ],
      [
        "name": "swarm.branch-queue",
        "description": "View the branch queue status showing in-flight branches being worked on and completed branches ready for PR.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.pr-queue",
        "description": "View the PR queue status showing pending operations and created PRs with their labels.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.create-pr",
        "description": "Manually create a PR for a completed swarm task. Use when auto-PR is disabled or you want to create a PR for a specific task.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "taskId": [
              "type": "string",
              "description": "The task ID to create a PR for (must be in completed branches)"
            ],
            "title": [
              "type": "string",
              "description": "Optional custom PR title (defaults to task prompt)"
            ]
          ],
          "required": ["taskId"]
        ]
      ],
      [
        "name": "swarm.setup-labels",
        "description": "Ensure all Peel PR labels exist in a repository. Creates peel:created, peel:approved, peel:needs-review, peel:needs-help, peel:conflict, and peel:merged labels with proper colors.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Path to the git repository"
            ]
          ],
          "required": ["repoPath"]
        ]
      ],
      [
        "name": "swarm.register-repo",
        "description": "Register a local repository path with the swarm. This maps the repo's git remote URL to the local path, enabling distributed tasks to work across machines with different folder structures.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "path": [
              "type": "string",
              "description": "The local path to the git repository"
            ],
            "remoteURL": [
              "type": "string",
              "description": "Optional: Explicit remote URL (if not provided, will be auto-detected from the git repo)"
            ]
          ],
          "required": ["path"]
        ]
      ],
      [
        "name": "swarm.repos",
        "description": "List all registered repositories and their remote URL mappings.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ]
    ]
  }
  
  // MARK: - Shared Coordinator Access
  
  private var coordinator: SwarmCoordinator {
    SwarmCoordinator.shared
  }
  
  // MARK: - swarm.start
  
  private func handleStart(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let roleStr = arguments["role"] as? String,
          let role = SwarmRole(rawValue: roleStr) else {
      return missingParamError(id: id, param: "role")
    }
    
    let port = UInt16(arguments["port"] as? Int ?? 8766)
    
    // Auto-register repos from arguments (if provided)
    if let repos = arguments["repos"] as? [String] {
      for repoPath in repos {
        await RepoRegistry.shared.registerRepo(at: repoPath)
      }
    }
    
    // Stop existing coordinator if running
    if coordinator.isActive {
      coordinator.stop()
    }
    
    // Configure chain executor for worker/hybrid roles
    if role == .worker || role == .hybrid {
      if let chainRunner = chainRunner, let agentManager = agentManager {
        let executor = DefaultChainExecutor(chainRunner: chainRunner, agentManager: agentManager)
        coordinator.configure(chainExecutor: executor)
      } else {
        // No executor available - log warning but allow start (will return mock results)
        print("Warning: Starting swarm without chain executor - tasks will return mock results")
      }
    }
    
    do {
      try coordinator.start(role: role, port: port)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "role": role.rawValue,
        "port": Int(port),
        "deviceName": coordinator.capabilities.deviceName,
        "deviceId": coordinator.capabilities.deviceId,
        "hasChainExecutor": chainRunner != nil,
        "registeredRepos": RepoRegistry.shared.registeredRepos.count
      ]))
    } catch {
      return internalError(id: id, message: "Failed to start swarm: \(error.localizedDescription)")
    }
  }
  
  // MARK: - swarm.stop
  
  private func handleStop(id: Any?) async -> (Int, Data) {
    guard coordinator.isActive else {
      return (200, makeResult(id: id, result: [
        "success": true,
        "message": "Swarm was not running"
      ]))
    }
    
    coordinator.stop()
    
    return (200, makeResult(id: id, result: [
      "success": true,
      "message": "Swarm stopped"
    ]))
  }
  
  // MARK: - swarm.status
  
  private func handleStatus(id: Any?) -> (Int, Data) {
    // Get branch/PR queue stats even when inactive (may have residual state)
    let branchStats = coordinator.branchQueue.getStats()
    let prPendingCount = coordinator.prQueue.pendingCount
    let createdPRCount = coordinator.prQueue.getAllPRs().count
    
    guard coordinator.isActive else {
      return (200, makeResult(id: id, result: [
        "active": false,
        "role": NSNull(),
        "workerCount": 0,
        "tasksCompleted": 0,
        "tasksFailed": 0,
        "branchQueue": [
          "inFlightCount": branchStats.inFlightCount,
          "completedCount": branchStats.completedCount,
          "readyForPRCount": branchStats.readyForPRCount,
          "needingReviewCount": branchStats.needingReviewCount
        ],
        "prQueue": [
          "pendingOperations": prPendingCount,
          "createdPRs": createdPRCount
        ]
      ]))
    }
    
    return (200, makeResult(id: id, result: [
      "active": coordinator.isActive,
      "role": coordinator.role.rawValue,
      "workerCount": coordinator.connectedWorkers.count,
      "tasksCompleted": coordinator.tasksCompleted,
      "tasksFailed": coordinator.tasksFailed,
      "currentTask": coordinator.currentTask?.id.uuidString as Any,
      "gitCommitHash": coordinator.capabilities.gitCommitHash as Any,
      "worktreeDebug": coordinator.getWorktreeDebugInfo(),
      "capabilities": [
        "deviceName": coordinator.capabilities.deviceName,
        "deviceId": coordinator.capabilities.deviceId,
        "gpuCores": coordinator.capabilities.gpuCores,
        "neuralEngineCores": coordinator.capabilities.neuralEngineCores,
        "memoryGB": coordinator.capabilities.memoryGB,
        "gitCommitHash": coordinator.capabilities.gitCommitHash as Any
      ],
      "branchQueue": [
        "inFlightCount": branchStats.inFlightCount,
        "completedCount": branchStats.completedCount,
        "readyForPRCount": branchStats.readyForPRCount,
        "needingReviewCount": branchStats.needingReviewCount
      ],
      "prQueue": [
        "pendingOperations": prPendingCount,
        "createdPRs": createdPRCount,
        "autoCreatePRs": coordinator.autoCreatePRs
      ]
    ]))
  }

  // MARK: - swarm.diagnostics

  private func handleDiagnostics(id: Any?) -> (Int, Data) {
    let formatter = ISO8601DateFormatter()
    let peers = coordinator.connectedWorkers.map { peer in
      let status = coordinator.workerStatuses[peer.id]
      let rag = status?.ragArtifacts
      return [
        "id": peer.id,
        "name": peer.name,
        "gitCommitHash": peer.capabilities.gitCommitHash as Any,
        "status": [
          "state": status?.state.rawValue ?? "unknown",
          "currentTaskId": status?.currentTaskId?.uuidString as Any,
          "lastHeartbeat": status.map { formatter.string(from: $0.lastHeartbeat) } as Any,
          "uptimeSeconds": status?.uptimeSeconds as Any,
          "tasksCompleted": status?.tasksCompleted as Any,
          "tasksFailed": status?.tasksFailed as Any
        ],
        "ragArtifacts": [
          "manifestVersion": rag?.manifestVersion as Any,
          "totalBytes": rag?.totalBytes as Any,
          "lastSyncedAt": rag?.lastSyncedAt.map { formatter.string(from: $0) } as Any,
          "lastSyncDirection": rag?.lastSyncDirection?.rawValue as Any,
          "repoCount": rag?.repoCount as Any,
          "lastIndexedAt": rag?.lastIndexedAt.map { formatter.string(from: $0) } as Any,
          "staleReason": rag?.staleReason as Any
        ],
        "capabilities": [
          "deviceId": peer.capabilities.deviceId,
          "deviceName": peer.capabilities.deviceName,
          "platform": peer.capabilities.platform.rawValue,
          "gpuCores": peer.capabilities.gpuCores,
          "neuralEngineCores": peer.capabilities.neuralEngineCores,
          "memoryGB": peer.capabilities.memoryGB,
          "storageAvailableGB": peer.capabilities.storageAvailableGB,
          "embeddingModel": peer.capabilities.embeddingModel as Any,
          "indexedRepos": peer.capabilities.indexedRepos
        ]
      ] as [String: Any]
    }

    let discovered = coordinator.discoveredPeers.map { peer in
      [
        "id": peer.id,
        "name": peer.name,
        "isResolved": peer.isResolved,
        "resolvedAddress": peer.resolvedAddress as Any,
        "resolvedPort": peer.resolvedPort as Any
      ] as [String: Any]
    }

    let transfers = coordinator.ragTransfers.prefix(10).map { transfer in
      [
        "id": transfer.id.uuidString,
        "peerId": transfer.peerId,
        "peerName": transfer.peerName,
        "direction": transfer.direction.rawValue,
        "role": transfer.role.rawValue,
        "status": transfer.status.rawValue,
        "totalBytes": transfer.totalBytes,
        "transferredBytes": transfer.transferredBytes,
        "startedAt": formatter.string(from: transfer.startedAt),
        "completedAt": transfer.completedAt.map { formatter.string(from: $0) } as Any,
        "errorMessage": transfer.errorMessage as Any,
        "manifestVersion": transfer.manifestVersion as Any
      ] as [String: Any]
    }

    let localRag = coordinator.localRagArtifactStatus
    let localRagPayload: [String: Any] = [
      "manifestVersion": localRag?.manifestVersion as Any,
      "totalBytes": localRag?.totalBytes as Any,
      "lastSyncedAt": localRag?.lastSyncedAt.map { formatter.string(from: $0) } as Any,
      "lastSyncDirection": localRag?.lastSyncDirection?.rawValue as Any,
      "repoCount": localRag?.repoCount as Any,
      "lastIndexedAt": localRag?.lastIndexedAt.map { formatter.string(from: $0) } as Any,
      "staleReason": localRag?.staleReason as Any
    ]

    return (200, makeResult(id: id, result: [
      "active": coordinator.isActive,
      "role": coordinator.role.rawValue,
      "device": [
        "deviceName": coordinator.capabilities.deviceName,
        "deviceId": coordinator.capabilities.deviceId,
        "gitCommitHash": coordinator.capabilities.gitCommitHash as Any
      ],
      "peers": peers,
      "discovered": discovered,
      "ragTransfers": transfers,
      "localRagArtifacts": localRagPayload
    ]))
  }
  
  // MARK: - swarm.workers
  
  private func handleWorkers(id: Any?) -> (Int, Data) {
    guard coordinator.isActive else {
      return (200, makeResult(id: id, result: [
        "workers": []
      ]))
    }
    
    // Get brain's commit hash for comparison
    let brainCommitHash = coordinator.capabilities.gitCommitHash
    let formatter = ISO8601DateFormatter()
    
    let workers = coordinator.connectedWorkers.map { peer in
      let workerHash = peer.capabilities.gitCommitHash
      let inSync = brainCommitHash != nil && workerHash == brainCommitHash
      let status = coordinator.workerStatuses[peer.id]
      let statusPayload: [String: Any] = [
        "state": status?.state.rawValue ?? "unknown",
        "currentTaskId": status?.currentTaskId?.uuidString as Any,
        "lastHeartbeat": status.map { formatter.string(from: $0.lastHeartbeat) } as Any,
        "uptimeSeconds": status?.uptimeSeconds as Any,
        "tasksCompleted": status?.tasksCompleted as Any,
        "tasksFailed": status?.tasksFailed as Any
      ]
      return [
        "id": peer.id,
        "name": peer.name,
        "gitCommitHash": workerHash as Any,
        "inSync": inSync,
        "status": statusPayload,
        "capabilities": [
          "deviceId": peer.capabilities.deviceId,
          "deviceName": peer.capabilities.deviceName,
          "platform": peer.capabilities.platform.rawValue,
          "gpuCores": peer.capabilities.gpuCores,
          "neuralEngineCores": peer.capabilities.neuralEngineCores,
          "memoryGB": peer.capabilities.memoryGB,
          "storageAvailableGB": peer.capabilities.storageAvailableGB,
          "embeddingModel": peer.capabilities.embeddingModel as Any,
          "indexedRepos": peer.capabilities.indexedRepos,
          "gitCommitHash": workerHash as Any
        ]
      ] as [String: Any]
    }
    
    let outOfSyncCount = workers.filter { ($0["inSync"] as? Bool) == false }.count
    
    return (200, makeResult(id: id, result: [
      "workers": workers,
      "count": workers.count,
      "brainCommitHash": brainCommitHash as Any,
      "outOfSyncCount": outOfSyncCount
    ]))
  }
  
  // MARK: - swarm.dispatch
  
  private func handleDispatch(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return serviceNotActiveError(id: id, service: "Swarm", hint: "Call swarm.start with role 'brain', 'worker', or 'hybrid' first")
    }
    
    guard coordinator.role == .brain || coordinator.role == .hybrid else {
      return internalError(id: id, message: "Only brain or hybrid roles can dispatch tasks")
    }
    
    guard case .success(let prompt) = requireString("prompt", from: arguments, id: id) else {
      return missingParamError(id: id, param: "prompt")
    }
    
    guard case .success(let workingDirectory) = requireString("workingDirectory", from: arguments, id: id) else {
      return missingParamError(id: id, param: "workingDirectory")
    }
    
    let templateName = optionalString("templateName", from: arguments) ?? "default"
    let priorityInt = optionalInt("priority", from: arguments, default: 1) ?? 1
    let priority = ChainPriority(rawValue: priorityInt) ?? .normal
    
    // Get the remote URL for this repo (stable identifier across machines)
    let repoRemoteURL = await RepoRegistry.shared.registerRepo(at: workingDirectory)
    
    // Create request with both path (for local) and remote URL (for remote workers)
    let request = ChainRequest(
      templateName: templateName,
      prompt: prompt,
      workingDirectory: workingDirectory,
      repoRemoteURL: repoRemoteURL,
      priority: priority
    )
    
    // Check if we have workers
    guard !coordinator.connectedWorkers.isEmpty else {
      return internalError(id: id, message: "No workers connected to dispatch to")
    }
    
    // Dispatch (fire and forget for now - result comes via delegate)
    do {
      _ = try await coordinator.dispatchChain(request)
      // This will timeout since we don't have proper result handling yet
    } catch let error as DistributedError {
      if case .taskTimeout = error {
        // Expected for now - task was dispatched but we don't wait for result
        return (200, makeResult(id: id, result: [
          "success": true,
          "taskId": request.id.uuidString,
          "message": "Task dispatched (async execution)"
        ]))
      }
      return internalError(id: id, message: error.localizedDescription)
    } catch {
      return internalError(id: id, message: error.localizedDescription)
    }
    
    return (200, makeResult(id: id, result: [
      "success": true,
      "taskId": request.id.uuidString,
      "message": "Task dispatched"
    ]))
  }
  
  // MARK: - swarm.connect
  
  private func handleConnect(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return serviceNotActiveError(id: id, service: "Swarm", hint: "Call swarm.start with role 'brain', 'worker', or 'hybrid' first")
    }
    
    guard case .success(let address) = requireString("address", from: arguments, id: id) else {
      return missingParamError(id: id, param: "address")
    }
    
    let port = UInt16(arguments["port"] as? Int ?? 8766)
    
    do {
      try await coordinator.connectToWorker(address: address, port: port)
      return (200, makeResult(id: id, result: [
        "success": true,
        "message": "Connection initiated to \(address):\(port)"
      ]))
    } catch {
      return internalError(id: id, message: "Failed to connect: \(error.localizedDescription)")
    }
  }

  // MARK: - swarm.rag.sync

  private func handleRagSync(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return serviceNotActiveError(id: id, service: "Swarm", hint: "Call swarm.start with role 'brain', 'worker', or 'hybrid' first")
    }

    guard coordinator.role == .brain || coordinator.role == .hybrid else {
      return internalError(id: id, message: "Only brain or hybrid roles can request RAG sync")
    }

    guard case .success(let directionRaw) = requireString("direction", from: arguments, id: id),
          let direction = RAGArtifactSyncDirection(rawValue: directionRaw) else {
      return missingParamError(id: id, param: "direction")
    }

    let workerId = optionalString("workerId", from: arguments)

    do {
      let transferId = try await coordinator.requestRagArtifactSync(direction: direction, workerId: workerId)
      return (200, makeResult(id: id, result: [
        "success": true,
        "transferId": transferId.uuidString,
        "direction": direction.rawValue,
        "workerId": workerId as Any
      ]))
    } catch {
      return internalError(id: id, message: error.localizedDescription)
    }
  }
  
  // MARK: - swarm.discovered
  
  private func handleDiscovered(id: Any?) -> (Int, Data) {
    guard coordinator.isActive else {
      return (200, makeResult(id: id, result: [
        "discovered": [],
        "count": 0
      ]))
    }
    
    let discovered = coordinator.discoveredPeers.map { peer in
      [
        "id": peer.id,
        "name": peer.name,
        "displayName": peer.displayName,
        "isResolved": peer.isResolved,
        "resolvedAddress": peer.resolvedAddress as Any,
        "resolvedPort": peer.resolvedPort.map { Int($0) } as Any
      ] as [String: Any]
    }
    
    return (200, makeResult(id: id, result: [
      "discovered": discovered,
      "count": discovered.count
    ]))
  }
  
  // MARK: - swarm.tasks
  
  private func handleTasks(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let limit = arguments["limit"] as? Int ?? 10
    let taskId = arguments["taskId"] as? String
    
    let results = coordinator.completedResults
    
    // Filter by task ID if specified
    let filtered: [ChainResult]
    if let taskId = taskId, let uuid = UUID(uuidString: taskId) {
      filtered = results.filter { $0.requestId == uuid }
    } else {
      filtered = Array(results.prefix(limit))
    }
    
    // Convert to JSON-friendly format
    let tasks = filtered.map { result -> [String: Any] in
      var task: [String: Any] = [
        "taskId": result.requestId.uuidString,
        "status": result.status.rawValue,
        "duration": result.duration,
        "workerDeviceId": result.workerDeviceId,
        "workerDeviceName": result.workerDeviceName
      ]
      
      if let error = result.errorMessage {
        task["error"] = error
      }
      
      // Include branch info if worktree isolation was used
      if let branchName = result.branchName {
        task["branchName"] = branchName
      }
      if let repoPath = result.repoPath {
        task["repoPath"] = repoPath
      }
      
      // Include output content (truncated for large outputs)
      let outputs = result.outputs.map { output -> [String: Any] in
        var out: [String: Any] = [
          "name": output.name,
          "type": output.type.rawValue
        ]
        if let content = output.content {
          // Truncate large content for API response
          let maxLen = 2000
          if content.count > maxLen {
            out["content"] = String(content.prefix(maxLen)) + "... (truncated, \(content.count) total chars)"
            out["truncated"] = true
          } else {
            out["content"] = content
          }
        }
        return out
      }
      task["outputs"] = outputs
      
      return task
    }
    
    return (200, makeResult(id: id, result: [
      "tasks": tasks,
      "count": tasks.count,
      "totalCompleted": coordinator.tasksCompleted,
      "totalFailed": coordinator.tasksFailed
    ]))
  }
  
  // MARK: - swarm.update-workers
  
  private func handleUpdateWorkers(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return serviceNotActiveError(id: id, service: "Swarm", hint: "Call swarm.start with role 'brain' or 'hybrid' first")
    }
    
    guard coordinator.role == .brain || coordinator.role == .hybrid else {
      return internalError(id: id, message: "Only brain can trigger worker updates")
    }
    
    let workers = coordinator.connectedWorkers
    guard !workers.isEmpty else {
      return (200, makeResult(id: id, result: [
        "success": false,
        "message": "No workers connected",
        "workersUpdated": 0
      ]))
    }
    
    let force = (arguments["force"] as? Bool) ?? false
    
    // Use direct command execution - no LLM involved
    // Run the self-update script on each worker
    // Workers need to find their own repo path - we send the command, they detect their local path
    
    // Dispatch direct command to each worker
    var dispatched: [[String: Any]] = []
    
    for worker in workers {
      do {
        // Build the command - use absolute path style since workers auto-detect repo
        let scriptArgs = force ? [] : ["--skip-build-if-current"]
        
        // Run self-update script - worker will detect its own repo working dir
        // Using sendDirectCommandAndWait with longer timeout since build takes time
        let result = try await coordinator.sendDirectCommandAndWait(
          "./Tools/self-update.sh",
          args: scriptArgs,
          workingDirectory: nil,  // Worker auto-detects
          to: worker.id,
          timeout: .seconds(300)  // 5 min timeout for pull + build
        )
        
        dispatched.append([
          "workerId": worker.id,
          "workerName": worker.displayName,
          "status": result.exitCode == 0 ? "success" : "failed",
          "exitCode": result.exitCode,
          "output": String(result.output.suffix(500)),  // Last 500 chars
          "error": result.error as Any
        ])
      } catch {
        dispatched.append([
          "workerId": worker.id,
          "workerName": worker.displayName,
          "status": "failed",
          "error": error.localizedDescription
        ])
      }
    }
    
    let succeeded = dispatched.filter { ($0["status"] as? String) == "success" }.count
    let failed = dispatched.count - succeeded
    
    return (200, makeResult(id: id, result: [
      "success": failed == 0,
      "message": failed == 0 
        ? "All workers updated successfully. They will restart shortly."
        : "\(succeeded) workers updated, \(failed) failed. Check 'workers' for details.",
      "workersUpdated": succeeded,
      "workersFailed": failed,
      "workers": dispatched
    ]))
  }

  // MARK: - swarm.update-log

  private func handleUpdateLog(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return serviceNotActiveError(id: id, service: "Swarm", hint: "Call swarm.start with role 'brain' or 'hybrid' first")
    }
    
    guard coordinator.role == .brain || coordinator.role == .hybrid else {
      return internalError(id: id, message: "Only brain can fetch worker logs")
    }
    
    let lines = min(max(arguments["lines"] as? Int ?? 200, 1), 500)
    let workerId = arguments["workerId"] as? String
    
    let targetWorker: ConnectedPeer
    if let workerId = workerId {
      guard let worker = coordinator.connectedWorkers.first(where: { $0.id == workerId }) else {
        return internalError(id: id, message: "Peel not found: \(workerId)")
      }
      targetWorker = worker
    } else {
      guard let worker = coordinator.connectedWorkers.first else {
        return internalError(id: id, message: "No workers connected")
      }
      targetWorker = worker
    }
    
    let logPath = "$HOME/Library/Logs/Peel/swarm-self-update.log"
    let command = "/bin/zsh"
    let args = ["-lc", "if [ -f \"\(logPath)\" ]; then tail -n \(lines) \"\(logPath)\"; else echo 'Log not found: \(logPath)'; fi"]
    
    do {
      let result = try await coordinator.sendDirectCommandAndWait(command, args: args, workingDirectory: nil, to: targetWorker.id)
      return (200, makeResult(id: id, result: [
        "success": result.exitCode == 0,
        "exitCode": result.exitCode,
        "output": result.output.trimmingCharacters(in: .whitespacesAndNewlines),
        "error": result.error as Any,
        "workerId": targetWorker.id,
        "workerName": targetWorker.displayName,
        "lines": lines
      ]))
    } catch {
      return internalError(id: id, message: "Failed to fetch update log: \(error.localizedDescription)")
    }
  }
  
  // MARK: - swarm.direct-command (for testing)
  
  private func handleDirectCommand(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return serviceNotActiveError(id: id, service: "Swarm", hint: "Call swarm.start with role 'brain' or 'hybrid' first")
    }
    
    guard coordinator.role == .brain || coordinator.role == .hybrid else {
      return internalError(id: id, message: "Only brain can send direct commands")
    }
    
    guard let command = arguments["command"] as? String else {
      return internalError(id: id, message: "Missing 'command' argument")
    }
    
    let args = arguments["args"] as? [String] ?? []
    let workingDirectory = arguments["workingDirectory"] as? String
    let workerId = arguments["workerId"] as? String
    
    // If no specific worker, send to first available
    let targetWorker: ConnectedPeer
    if let workerId = workerId {
      guard let worker = coordinator.connectedWorkers.first(where: { $0.id == workerId }) else {
        return internalError(id: id, message: "Peel not found: \(workerId)")
      }
      targetWorker = worker
    } else {
      guard let worker = coordinator.connectedWorkers.first else {
        return internalError(id: id, message: "No workers connected")
      }
      targetWorker = worker
    }
    
    do {
      let result = try await coordinator.sendDirectCommandAndWait(command, args: args, workingDirectory: workingDirectory, to: targetWorker.id)
      return (200, makeResult(id: id, result: [
        "success": result.exitCode == 0,
        "exitCode": result.exitCode,
        "output": result.output.trimmingCharacters(in: .whitespacesAndNewlines),
        "error": result.error as Any,
        "workerId": targetWorker.id,
        "workerName": targetWorker.displayName,
        "command": command,
        "args": args
      ]))
    } catch {
      return internalError(id: id, message: "Failed to send command: \(error.localizedDescription)")
    }
  }
  
  // MARK: - swarm.branch-queue
  
  private func handleBranchQueue(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let stats = coordinator.branchQueue.getStats()
    let inFlight = coordinator.branchQueue.getAllInFlight().map { reservation -> [String: Any] in
      [
        "taskId": reservation.taskId.uuidString,
        "branchName": reservation.branchName,
        "repoPath": reservation.repoPath,
        "workerId": reservation.workerId,
        "createdAt": ISO8601DateFormatter().string(from: reservation.createdAt)
      ]
    }
    
    let completed = coordinator.branchQueue.getAllCompleted().map { branch -> [String: Any] in
      [
        "taskId": branch.taskId.uuidString,
        "branchName": branch.branchName,
        "repoPath": branch.repoPath,
        "workerId": branch.workerId,
        "completedAt": ISO8601DateFormatter().string(from: branch.completedAt),
        "status": branch.status.rawValue
      ]
    }
    
    return (200, makeResult(id: id, result: [
      "stats": [
        "inFlightCount": stats.inFlightCount,
        "completedCount": stats.completedCount,
        "readyForPRCount": stats.readyForPRCount,
        "needingReviewCount": stats.needingReviewCount
      ],
      "inFlight": inFlight,
      "completed": completed
    ]))
  }
  
  // MARK: - swarm.pr-queue
  
  private func handlePRQueue(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let prs = coordinator.prQueue.getAllPRs().map { pr -> [String: Any] in
      [
        "taskId": pr.taskId.uuidString,
        "prNumber": pr.prNumber,
        "prURL": pr.prURL,
        "branchName": pr.branchName,
        "repoPath": pr.repoPath,
        "createdAt": ISO8601DateFormatter().string(from: pr.createdAt),
        "labels": pr.labels.map(\.rawValue),
        "status": pr.status.rawValue
      ]
    }
    
    return (200, makeResult(id: id, result: [
      "pendingOperations": coordinator.prQueue.pendingCount,
      "autoCreatePRs": coordinator.autoCreatePRs,
      "prs": prs
    ]))
  }
  
  // MARK: - swarm.create-pr
  
  private func handleCreatePR(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let taskIdStr = arguments["taskId"] as? String,
          let taskId = UUID(uuidString: taskIdStr) else {
      return internalError(id: id, message: "Missing or invalid 'taskId'")
    }
    
    // Get the completed branch info
    guard let completed = coordinator.branchQueue.getCompleted(taskId: taskId) else {
      return internalError(id: id, message: "No completed branch found for task \(taskIdStr)")
    }
    
    // Find the task result for prompt/outputs
    guard let result = coordinator.completedResults.first(where: { $0.requestId == taskId }) else {
      return internalError(id: id, message: "No task result found for \(taskIdStr)")
    }
    
    let prompt = arguments["title"] as? String ?? result.outputs.first?.content ?? "Swarm task"
    let agentOutput = result.outputs.first { $0.name.contains("agent") }?.content
    
    coordinator.prQueue.createPRFromTask(
      taskId: taskId,
      branchName: completed.branchName,
      repoPath: completed.repoPath,
      prompt: prompt,
      outputs: agentOutput
    )
    
    return (200, makeResult(id: id, result: [
      "success": true,
      "message": "PR creation queued",
      "taskId": taskIdStr,
      "branchName": completed.branchName
    ]))
  }
  
  // MARK: - swarm.setup-labels
  
  private func handleSetupLabels(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    // Check if path exists
    guard FileManager.default.fileExists(atPath: repoPath) else {
      return internalError(id: id, message: "Path does not exist: \(repoPath)")
    }
    
    do {
      try await coordinator.prQueue.ensureLabelsExist(in: repoPath)
      
      let labels = PeelPRLabel.allCases.map { [
        "name": $0.rawValue,
        "description": $0.description,
        "color": $0.color
      ] }
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "message": "Created \(labels.count) Peel labels in repo",
        "repoPath": repoPath,
        "labels": labels
      ]))
    } catch {
      return internalError(id: id, message: "Failed to setup labels: \(error.localizedDescription)")
    }
  }
  
  // MARK: - swarm.register-repo
  
  private func handleRegisterRepo(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let path) = requireString("path", from: arguments, id: id) else {
      return missingParamError(id: id, param: "path")
    }
    
    // Check if path exists
    guard FileManager.default.fileExists(atPath: path) else {
      return internalError(id: id, message: "Path does not exist: \(path)")
    }
    
    // If explicit remoteURL provided, use it
    if let remoteURL = optionalString("remoteURL", from: arguments) {
      RepoRegistry.shared.registerRepo(remoteURL: remoteURL, localPath: path)
      return (200, makeResult(id: id, result: [
        "success": true,
        "remoteURL": RepoRegistry.shared.normalizeRemoteURL(remoteURL),
        "localPath": path
      ]))
    }
    
    // Auto-detect remote URL
    if let remoteURL = await RepoRegistry.shared.registerRepo(at: path) {
      return (200, makeResult(id: id, result: [
        "success": true,
        "remoteURL": remoteURL,
        "localPath": path
      ]))
    } else {
      return internalError(id: id, message: "Could not detect git remote URL for \(path). Is this a git repository?")
    }
  }
  
  // MARK: - swarm.repos
  
  private func handleRepos(id: Any?) -> (Int, Data) {
    let repos = RepoRegistry.shared.registeredRepos
    
    return (200, makeResult(id: id, result: [
      "count": repos.count,
      "repos": repos.map { [
        "remoteURL": $0.remoteURL,
        "localPath": $0.localPath
      ] }
    ]))
  }
}
