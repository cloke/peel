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
    "swarm.repos",
    // Firestore swarm tools
    "swarm.firestore.auth",
    "swarm.firestore.swarms",
    "swarm.firestore.create",
    "swarm.firestore.debug",
    "swarm.firestore.activity",
    "swarm.firestore.migrate",
    "swarm.firestore.backup",
    // Firestore worker/task management (#225)
    "swarm.firestore.workers",
    "swarm.firestore.register-worker",
    "swarm.firestore.unregister-worker",
    "swarm.firestore.submit-task",
    "swarm.firestore.tasks",
    // Firestore RAG artifact sync (#226)
    "swarm.firestore.rag.artifacts",
    "swarm.firestore.rag.push",
    "swarm.firestore.rag.pull",
    "swarm.firestore.rag.delete",
    // Firebase emulator management
    "firebase.emulator.status",
    "firebase.emulator.install",
    "firebase.emulator.start",
    "firebase.emulator.stop",
    "firebase.emulator.configure"
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
    // Firestore swarm tools
    case "swarm.firestore.auth":
      return handleFirestoreAuth(id: id)
    case "swarm.firestore.swarms":
      return await handleFirestoreSwarms(id: id)
    case "swarm.firestore.create":
      return await handleFirestoreCreate(id: id, arguments: arguments)
    case "swarm.firestore.debug":
      return await handleFirestoreDebug(id: id)
    case "swarm.firestore.activity":
      return handleFirestoreActivity(id: id, arguments: arguments)
    case "swarm.firestore.migrate":
      return await handleFirestoreMigrate(id: id)
    case "swarm.firestore.backup":
      return await handleFirestoreBackup(id: id, arguments: arguments)
    // Firestore worker/task management (#225)
    case "swarm.firestore.workers":
      return handleFirestoreWorkers(id: id, arguments: arguments)
    case "swarm.firestore.register-worker":
      return await handleFirestoreRegisterWorker(id: id, arguments: arguments)
    case "swarm.firestore.unregister-worker":
      return await handleFirestoreUnregisterWorker(id: id, arguments: arguments)
    case "swarm.firestore.submit-task":
      return await handleFirestoreSubmitTask(id: id, arguments: arguments)
    case "swarm.firestore.tasks":
      return handleFirestoreTasks(id: id, arguments: arguments)
    // Firestore RAG artifact sync (#226)
    case "swarm.firestore.rag.artifacts":
      return await handleFirestoreRAGArtifacts(id: id, arguments: arguments)
    case "swarm.firestore.rag.push":
      return await handleFirestoreRAGPush(id: id, arguments: arguments)
    case "swarm.firestore.rag.pull":
      return await handleFirestoreRAGPull(id: id, arguments: arguments)
    case "swarm.firestore.rag.delete":
      return await handleFirestoreRAGDelete(id: id, arguments: arguments)
    // Firebase emulator management
    case "firebase.emulator.status":
      return handleEmulatorStatus(id: id)
    case "firebase.emulator.install":
      return await handleEmulatorInstall(id: id, arguments: arguments)
    case "firebase.emulator.start":
      return await handleEmulatorStart(id: id, arguments: arguments)
    case "firebase.emulator.stop":
      return await handleEmulatorStop(id: id)
    case "firebase.emulator.configure":
      return handleEmulatorConfigure(id: id, arguments: arguments)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }
  
  // MARK: - Tool Definitions
  
  public static func toolDefinitions() -> [[String: Any]] {
    [
      [
        "name": "swarm.start",
        "description": "Start the distributed swarm coordinator. Role can be 'brain' (Crown: dispatches work), 'worker' (Peel: executes work), or 'hybrid' (Crown + Peel). Enable 'wan' for internet connectivity.",
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
            ],
            "wan": [
              "type": "boolean",
              "description": "Enable WAN mode to advertise public IP for internet connectivity. Requires port forwarding on router."
            ],
            "wanAddress": [
              "type": "string",
              "description": "Explicit WAN address to advertise (if not set, auto-detects public IP)"
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
      ],
      // Firestore swarm tools
      [
        "name": "swarm.firestore.auth",
        "description": "Check Firebase authentication status for Firestore swarm coordination.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.firestore.swarms",
        "description": "List all Firestore swarms the current user belongs to (for debugging).",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.firestore.create",
        "description": "Create a new Firestore swarm.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "name": [
              "type": "string",
              "description": "Name for the new swarm"
            ]
          ],
          "required": ["name"]
        ]
      ],
      [
        "name": "swarm.firestore.debug",
        "description": "Debug query: show raw Firestore swarm data and query parameters.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.firestore.activity",
        "description": "Get recent activity log entries for swarm debugging. Shows worker events, task status changes, messages, and errors.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "limit": [
              "type": "integer",
              "description": "Maximum number of entries to return (default: 50)"
            ],
            "filter": [
              "type": "string",
              "description": "Filter by event type: worker_online, worker_offline, task_submitted, task_claimed, task_completed, error, etc."
            ]
          ],
          "required": []
        ]
      ],
      [
        "name": "swarm.firestore.migrate",
        "description": "Run migration to add userId field to all member documents. Required for collection group queries to find user memberships across swarms.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.firestore.backup",
        "description": "Export all swarm data to a JSON backup file. Includes swarms, members, and invites. Backups are saved to ~/peel-backups/ by default.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "outputPath": [
              "type": "string",
              "description": "Optional custom path for backup file. Defaults to ~/peel-backups/firestore-backup-<timestamp>.json"
            ]
          ],
          "required": []
        ]
      ],
      // Firestore worker/task management (#225)
      [
        "name": "swarm.firestore.workers",
        "description": "List workers registered in a Firestore swarm. Shows status, last heartbeat, and capabilities.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to list workers from"
            ]
          ],
          "required": ["swarmId"]
        ]
      ],
      [
        "name": "swarm.firestore.register-worker",
        "description": "Register this device as a worker in a Firestore swarm. Requires contributor+ permission.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to register as a worker"
            ]
          ],
          "required": ["swarmId"]
        ]
      ],
      [
        "name": "swarm.firestore.unregister-worker",
        "description": "Unregister this device as a worker from a Firestore swarm.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to unregister from"
            ]
          ],
          "required": ["swarmId"]
        ]
      ],
      [
        "name": "swarm.firestore.submit-task",
        "description": "Submit a task to a Firestore swarm for remote execution. Requires contributor+ permission.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to submit the task to"
            ],
            "templateName": [
              "type": "string",
              "description": "Name of the chain template to execute"
            ],
            "prompt": [
              "type": "string",
              "description": "The prompt/task description"
            ],
            "workingDirectory": [
              "type": "string",
              "description": "Working directory for the task"
            ],
            "repoRemoteURL": [
              "type": "string",
              "description": "Git remote URL for the repo (optional)"
            ],
            "priority": [
              "type": "integer",
              "description": "Priority (0=low, 1=normal, 2=high, 3=critical)"
            ]
          ],
          "required": ["swarmId", "templateName", "prompt", "workingDirectory"]
        ]
      ],
      [
        "name": "swarm.firestore.tasks",
        "description": "List pending/running tasks in a Firestore swarm.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to list tasks from"
            ]
          ],
          "required": ["swarmId"]
        ]
      ],
      // RAG Artifact Sync (#226)
      [
        "name": "swarm.firestore.rag.artifacts",
        "description": "List RAG artifacts available in a Firestore swarm. Shows version, size, and upload info.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to list artifacts from"
            ]
          ],
          "required": ["swarmId"]
        ]
      ],
      [
        "name": "swarm.firestore.rag.push",
        "description": "Push local RAG artifacts to Firestore swarm for sharing with other members. Requires contributor+ role.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to push artifacts to"
            ],
            "repoPath": [
              "type": "string",
              "description": "Path to the repository whose RAG index to push"
            ]
          ],
          "required": ["swarmId", "repoPath"]
        ]
      ],
      [
        "name": "swarm.firestore.rag.pull",
        "description": "Pull RAG artifacts from Firestore swarm to local storage. Requires reader+ role.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to pull artifacts from"
            ],
            "artifactId": [
              "type": "string",
              "description": "The artifact ID (version) to pull"
            ],
            "repoPath": [
              "type": "string",
              "description": "Path to the repository to import the RAG index into"
            ]
          ],
          "required": ["swarmId", "artifactId", "repoPath"]
        ]
      ],
      [
        "name": "swarm.firestore.rag.delete",
        "description": "Delete a RAG artifact from Firestore swarm. Requires admin+ role.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID"
            ],
            "artifactId": [
              "type": "string",
              "description": "The artifact ID (version) to delete"
            ]
          ],
          "required": ["swarmId", "artifactId"]
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
    let enableWAN = arguments["wan"] as? Bool ?? false
    let explicitWANAddress = arguments["wanAddress"] as? String
    
    // Auto-register repos from arguments (if provided)
    if let repos = arguments["repos"] as? [String] {
      for repoPath in repos {
        await RepoRegistry.shared.registerRepo(at: repoPath)
      }
    }
    
    // Auto-register the app's working directory (common case)
    if let appWorkingDir = FileManager.default.currentDirectoryPath as String?,
       FileManager.default.fileExists(atPath: appWorkingDir + "/.git") {
      await RepoRegistry.shared.registerRepo(at: appWorkingDir)
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
      
      if enableWAN {
        print("Warning: WAN mode requested but not supported by SwarmCoordinator. Ignoring wan settings.")
      }
      
      // Auto-register as Firestore worker for all member swarms (WAN discovery)
      var firestoreRegistrations: [[String: Any]] = []
      let firebaseService = FirebaseService.shared
      
      // Use LAN address from current capabilities (WAN not supported here)
      let lanAddress = coordinator.capabilities.lanAddress
      let lanPort = coordinator.capabilities.lanPort
      
      if firebaseService.isSignedIn {
        let capabilities = WorkerCapabilities.current(
          lanAddress: lanAddress,
          lanPort: lanPort
        )
        for swarm in firebaseService.memberSwarms where swarm.role.canRegisterWorkers {
          // contributor+ can register as worker
          do {
            let workerId = try await firebaseService.registerWorker(
              swarmId: swarm.id,
              capabilities: capabilities
            )
            // Also start listening for other workers and messages in this swarm
            firebaseService.startWorkerListener(swarmId: swarm.id)
            firebaseService.startMessageListener(swarmId: swarm.id)
            firestoreRegistrations.append([
              "swarmId": swarm.id,
              "swarmName": swarm.swarmName,
              "workerId": workerId,
              "status": "registered",
              "wanAddress": NSNull(),
              "wanPort": NSNull(),
              "lanAddress": lanAddress as Any,
              "lanPort": lanPort.map { Int($0) } as Any
            ])
          } catch {
            firestoreRegistrations.append([
              "swarmId": swarm.id,
              "swarmName": swarm.swarmName,
              "error": error.localizedDescription
            ])
          }
        }
        
        // Auto-connect to WAN peers after registration (gives time for listeners to populate)
        if enableWAN {
          print("Warning: WAN peer auto-connect requested but unsupported by SwarmCoordinator.")
        }
      }
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "role": role.rawValue,
        "port": Int(port),
        "deviceName": coordinator.capabilities.deviceName,
        "deviceId": coordinator.capabilities.deviceId,
        "hasChainExecutor": chainRunner != nil,
        "registeredRepos": RepoRegistry.shared.registeredRepos.count,
        "firestoreWorkers": firestoreRegistrations,
        "wanEnabled": enableWAN,
        "wanAddress": NSNull(),
        "wanPort": NSNull(),
        "lanAddress": lanAddress as Any,
        "lanPort": lanPort.map { Int($0) } as Any
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
    
    // Unregister from all Firestore swarms (stops task listener + heartbeat)
    let firebaseService = FirebaseService.shared
    if firebaseService.isSignedIn {
      for swarm in firebaseService.memberSwarms {
        do {
          try await firebaseService.unregisterWorker(swarmId: swarm.id)
        } catch {
          // Best effort - log but don't fail the stop
          print("[SwarmToolsHandler] Failed to unregister from swarm \(swarm.id): \(error)")
        }
        // Also stop the worker and message listeners for this swarm
        firebaseService.stopWorkerListener(swarmId: swarm.id)
        firebaseService.stopMessageListener(swarmId: swarm.id)
      }
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
  
  // MARK: - Firestore Swarm Tools
  
  private func handleFirestoreAuth(id: Any?) -> (Int, Data) {
    let service = FirebaseService.shared
    
    return (200, makeResult(id: id, result: [
      "isConfigured": service.isConfigured,
      "isSignedIn": service.isSignedIn,
      "userId": service.currentUserId as Any,
      "email": service.currentUserEmail as Any,
      "displayName": service.currentUserDisplayName as Any,
      "memberSwarmCount": service.memberSwarms.count
    ]))
  }
  
  private func handleFirestoreSwarms(id: Any?) async -> (Int, Data) {
    let service = FirebaseService.shared
    
    guard service.isSignedIn else {
      return internalError(id: id, message: "Not signed in to Firebase. Use Sign In with Apple in Settings > Swarm.")
    }
    
    // Return current memberSwarms from the service
    let swarms = service.memberSwarms.map { swarm -> [String: Any] in
      [
        "id": swarm.id,
        "name": swarm.swarmName,
        "role": swarm.role.rawValue,
        "joinedAt": swarm.joinedAt.ISO8601Format()
      ]
    }
    
    return (200, makeResult(id: id, result: [
      "count": swarms.count,
      "swarms": swarms,
      "note": "If count is 0, swarms may exist in Firestore but failed to load. Check Firebase Console."
    ]))
  }
  
  private func handleFirestoreCreate(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let name = arguments["name"] as? String, !name.isEmpty else {
      return missingParamError(id: id, param: "name")
    }
    
    let service = FirebaseService.shared
    
    guard service.isSignedIn else {
      return internalError(id: id, message: "Not signed in to Firebase")
    }
    
    do {
      let swarmId = try await service.createSwarm(name: name)
      return (200, makeResult(id: id, result: [
        "success": true,
        "swarmId": swarmId,
        "name": name
      ]))
    } catch {
      return internalError(id: id, message: "Failed to create swarm: \(error.localizedDescription)")
    }
  }
  
  private func handleFirestoreDebug(id: Any?) -> (Int, Data) {
    let service = FirebaseService.shared
    let debugInfo = service.debugQuerySwarms()
    return (200, makeResult(id: id, result: debugInfo))
  }
  
  private func handleFirestoreMigrate(id: Any?) async -> (Int, Data) {
    let service = FirebaseService.shared
    do {
      let result = try await service.migrateMemberUserIds()
      return (200, makeResult(id: id, result: result))
    } catch {
      return internalError(id: id, message: "Migration failed: \(error.localizedDescription)")
    }
  }

  private func handleFirestoreBackup(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let service = FirebaseService.shared

    // Determine output path
    let outputPath: String
    if let customPath = arguments["outputPath"] as? String, !customPath.isEmpty {
      outputPath = (customPath as NSString).expandingTildeInPath
    } else {
      let dateFormatter = DateFormatter()
      dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
      let timestamp = dateFormatter.string(from: Date())
      let backupDir = ("~/peel-backups" as NSString).expandingTildeInPath
      outputPath = "\(backupDir)/firestore-backup-\(timestamp).json"
    }

    do {
      // Create backup directory if needed
      let dirPath = (outputPath as NSString).deletingLastPathComponent
      try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

      // Get backup data from Firebase service
      let backupData = try await service.exportSwarmData()

      // Write to file
      let jsonData = try JSONSerialization.data(withJSONObject: backupData, options: [.prettyPrinted, .sortedKeys])
      try jsonData.write(to: URL(fileURLWithPath: outputPath))

      // Build summary
      let swarms = (backupData["swarms"] as? [[String: Any]]) ?? []
      var totalMembers = 0
      var totalInvites = 0
      for swarm in swarms {
        totalMembers += (swarm["members"] as? [[String: Any]])?.count ?? 0
        totalInvites += (swarm["invites"] as? [[String: Any]])?.count ?? 0
      }

      let result: [String: Any] = [
        "success": true,
        "path": outputPath,
        "summary": [
          "swarms": swarms.count,
          "totalMembers": totalMembers,
          "totalInvites": totalInvites,
          "backupTimestamp": ISO8601DateFormatter().string(from: Date())
        ]
      ]
      return (200, makeResult(id: id, result: result))
    } catch {
      return internalError(id: id, message: "Backup failed: \(error.localizedDescription)")
    }
  }
  
  private func handleFirestoreActivity(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let service = FirebaseService.shared
    let limit = arguments["limit"] as? Int ?? 50
    let filterType = arguments["filter"] as? String
    
    var events = service.activityLog
    
    // Apply filter if specified
    if let filter = filterType, !filter.isEmpty {
      events = events.filter { $0.type.rawValue == filter }
    }
    
    // Apply limit
    events = Array(events.prefix(limit))
    
    let formatted = events.map { event -> [String: Any] in
      var entry: [String: Any] = [
        "timestamp": event.timestamp.ISO8601Format(),
        "type": event.type.rawValue,
        "emoji": event.type.emoji,
        "message": event.message
      ]
      if let details = event.details {
        entry["details"] = details
      }
      return entry
    }
    
    return (200, makeResult(id: id, result: [
      "count": formatted.count,
      "totalInLog": service.activityLog.count,
      "events": formatted
    ]))
  }
  
  // MARK: - Firestore Worker/Task Management (#225)
  
  private func handleFirestoreWorkers(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    
    let service = FirebaseService.shared
    
    // Start listening if not already
    service.startWorkerListener(swarmId: swarmId)
    
    let workers = service.swarmWorkers.map { worker -> [String: Any] in
      [
        "id": worker.id,
        "ownerId": worker.ownerId,
        "displayName": worker.displayName,
        "deviceName": worker.deviceName,
        "status": worker.status.rawValue,
        "lastHeartbeat": worker.lastHeartbeat.ISO8601Format(),
        "isStale": worker.isStale,
        "version": worker.version as Any,
        "wanAddress": worker.wanAddress as Any,
        "wanPort": worker.wanPort.map { Int($0) } as Any,
        "hasWANEndpoint": worker.hasWANEndpoint
      ]
    }
    
    return (200, makeResult(id: id, result: [
      "swarmId": swarmId,
      "count": workers.count,
      "workers": workers
    ]))
  }
  
  private func handleFirestoreRegisterWorker(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    
    let service = FirebaseService.shared
    
    guard service.isSignedIn else {
      return internalError(id: id, message: "Not signed in to Firebase")
    }
    
    do {
      let capabilities = WorkerCapabilities.current()
      let workerId = try await service.registerWorker(swarmId: swarmId, capabilities: capabilities)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "swarmId": swarmId,
        "workerId": workerId,
        "displayName": capabilities.displayName ?? capabilities.deviceName,
        "message": "Worker registered. Heartbeat every 30s. Listening for tasks."
      ]))
    } catch {
      return internalError(id: id, message: "Failed to register worker: \(error.localizedDescription)")
    }
  }
  
  private func handleFirestoreUnregisterWorker(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    
    let service = FirebaseService.shared
    
    do {
      try await service.unregisterWorker(swarmId: swarmId)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "swarmId": swarmId,
        "message": "Worker unregistered and marked offline."
      ]))
    } catch {
      return internalError(id: id, message: "Failed to unregister worker: \(error.localizedDescription)")
    }
  }
  
  private func handleFirestoreSubmitTask(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    guard let templateName = arguments["templateName"] as? String, !templateName.isEmpty else {
      return missingParamError(id: id, param: "templateName")
    }
    guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
      return missingParamError(id: id, param: "prompt")
    }
    guard let workingDirectory = arguments["workingDirectory"] as? String, !workingDirectory.isEmpty else {
      return missingParamError(id: id, param: "workingDirectory")
    }
    
    let service = FirebaseService.shared
    
    guard service.isSignedIn else {
      return internalError(id: id, message: "Not signed in to Firebase")
    }
    
    let priority = ChainPriority(rawValue: arguments["priority"] as? Int ?? 1) ?? .normal
    
    // Auto-discover remote URL from workingDirectory if not explicitly provided
    var repoRemoteURL = arguments["repoRemoteURL"] as? String
    if repoRemoteURL == nil {
      // First try cache (fast, no subprocess)
      repoRemoteURL = await RepoRegistry.shared.getCachedRemoteURL(for: workingDirectory)
      // If not cached, discover via git
      if repoRemoteURL == nil {
        repoRemoteURL = await RepoRegistry.shared.registerRepo(at: workingDirectory)
      }
    }
    
    let request = ChainRequest(
      templateName: templateName,
      prompt: prompt,
      workingDirectory: workingDirectory,
      repoRemoteURL: repoRemoteURL,
      priority: priority
    )
    
    do {
      let taskId = try await service.submitTask(swarmId: swarmId, request: request)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "swarmId": swarmId,
        "taskId": taskId,
        "templateName": templateName,
        "status": "pending",
        "message": "Task submitted. Workers will claim and execute."
      ]))
    } catch {
      return internalError(id: id, message: "Failed to submit task: \(error.localizedDescription)")
    }
  }
  
  private func handleFirestoreTasks(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    
    let service = FirebaseService.shared
    
    // Start listening if not already
    service.startPendingTaskListener(swarmId: swarmId)
    
    let tasks = service.pendingTasks.map { task -> [String: Any] in
      [
        "id": task.id,
        "templateName": task.templateName,
        "prompt": String(task.prompt.prefix(100)) + (task.prompt.count > 100 ? "..." : ""),
        "status": task.status.rawValue,
        "createdBy": task.createdBy,
        "createdAt": task.createdAt.ISO8601Format(),
        "claimedBy": task.claimedBy as Any,
        "claimedByWorker": task.claimedByWorker as Any
      ]
    }
    
    return (200, makeResult(id: id, result: [
      "swarmId": swarmId,
      "count": tasks.count,
      "tasks": tasks
    ]))
  }
  
  // MARK: - Firestore RAG Artifact Handlers (#226)
  
  private func handleFirestoreRAGArtifacts(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    
    let service = FirebaseService.shared
    
    do {
      let artifacts = try await service.listRAGArtifacts(swarmId: swarmId)
      
      let artifactData = artifacts.map { artifact -> [String: Any] in
        [
          "id": artifact.id,
          "version": artifact.version,
          "totalBytes": artifact.totalBytes,
          "formattedSize": artifact.formattedSize,
          "chunkCount": artifact.chunkCount,
          "embeddingCacheCount": artifact.embeddingCacheCount,
          "repoCount": artifact.repoCount,
          "uploadedBy": artifact.uploadedBy,
          "uploadedAt": artifact.uploadedAt.ISO8601Format()
        ]
      }
      
      return (200, makeResult(id: id, result: [
        "swarmId": swarmId,
        "count": artifacts.count,
        "artifacts": artifactData
      ]))
    } catch {
      return internalError(id: id, message: "Failed to list RAG artifacts: \(error.localizedDescription)")
    }
  }
  
  private func handleFirestoreRAGPush(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let service = FirebaseService.shared
    let ragStore = LocalRAGStore.shared
    
    do {
      // Create a bundle from the local RAG store
      guard let bundle = try await ragStore.createArtifactBundle(for: repoPath) else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "No RAG index found for repo: \(repoPath)"))
      }
      
      // Push to Firestore
      let artifactId = try await service.pushRAGArtifacts(swarmId: swarmId, bundle: bundle)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "swarmId": swarmId,
        "artifactId": artifactId,
        "version": bundle.manifest.version,
        "totalBytes": bundle.bundleSizeBytes,
        "formattedSize": ByteCountFormatter.string(fromByteCount: Int64(bundle.bundleSizeBytes), countStyle: .file),
        "repoCount": bundle.manifest.repos.count,
        "embeddingCacheCount": bundle.manifest.embeddingCacheCount
      ]))
    } catch {
      return internalError(id: id, message: "Failed to push RAG artifacts: \(error.localizedDescription)")
    }
  }
  
  private func handleFirestoreRAGPull(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    guard let artifactId = arguments["artifactId"] as? String, !artifactId.isEmpty else {
      return missingParamError(id: id, param: "artifactId")
    }
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let service = FirebaseService.shared
    let ragStore = LocalRAGStore.shared
    
    do {
      // Create a temp destination for the bundle
      let tempDir = FileManager.default.temporaryDirectory
      let bundleURL = tempDir.appendingPathComponent("rag-artifact-\(artifactId).zip")
      
      // Pull from Firestore
      let manifest = try await service.pullRAGArtifacts(
        swarmId: swarmId,
        artifactId: artifactId,
        destination: bundleURL
      )
      
      // Import into local RAG store
      let bundle = LocalRAGArtifactBundle(manifest: manifest, bundleURL: bundleURL, bundleSizeBytes: try FileManager.default.attributesOfItem(atPath: bundleURL.path)[.size] as? Int ?? 0)
      try await ragStore.importArtifactBundle(bundle, for: repoPath)
      
      // Clean up temp file
      try? FileManager.default.removeItem(at: bundleURL)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "swarmId": swarmId,
        "artifactId": artifactId,
        "version": manifest.version,
        "repoPath": repoPath,
        "repoCount": manifest.repos.count,
        "embeddingCacheCount": manifest.embeddingCacheCount
      ]))
    } catch {
      return internalError(id: id, message: "Failed to pull RAG artifacts: \(error.localizedDescription)")
    }
  }
  
  private func handleFirestoreRAGDelete(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    guard let artifactId = arguments["artifactId"] as? String, !artifactId.isEmpty else {
      return missingParamError(id: id, param: "artifactId")
    }
    
    let service = FirebaseService.shared
    
    do {
      try await service.deleteRAGArtifact(swarmId: swarmId, artifactId: artifactId)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "swarmId": swarmId,
        "artifactId": artifactId,
        "deleted": true
      ]))
    } catch {
      return internalError(id: id, message: "Failed to delete RAG artifact: \(error.localizedDescription)")
    }
  }
  
  // MARK: - Firebase Emulator Tools
  
  /// Cached emulator process reference
  private static var emulatorProcess: Process?
  
  private func handleEmulatorInstall(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    var installed: [String] = []
    var alreadyInstalled: [String] = []
    var errors: [String] = []
    
    // Determine what to install (default: all)
    let components = (arguments["components"] as? [String]) ?? ["firebase-tools", "java"]
    
    // Check brew availability
    let brewPath = findBrewPath()
    let npmPath = findExecutable("npm")
    
    // -- Java --
    if components.contains("java") {
      if findExecutable("java") != nil {
        // Verify it actually works (macOS stub returns non-zero)
        let (javaWorks, _) = runCommand("/usr/bin/java", args: ["-version"])
        if javaWorks {
          alreadyInstalled.append("java")
        } else {
          // Install Temurin JDK via brew
          if let brew = brewPath {
            let (ok, output) = runCommand(brew, args: ["install", "--cask", "temurin"])
            if ok {
              installed.append("java (temurin)")
            } else {
              errors.append("java: brew install failed — \(output)")
            }
          } else {
            errors.append("java: brew not found, install manually with: brew install --cask temurin")
          }
        }
      } else {
        if let brew = brewPath {
          let (ok, output) = runCommand(brew, args: ["install", "--cask", "temurin"])
          if ok {
            installed.append("java (temurin)")
          } else {
            errors.append("java: brew install failed — \(output)")
          }
        } else {
          errors.append("java: brew not found, install manually with: brew install --cask temurin")
        }
      }
    }
    
    // -- firebase-tools --
    if components.contains("firebase-tools") {
      if findExecutable("firebase") != nil {
        alreadyInstalled.append("firebase-tools")
      } else if let npm = npmPath {
        let (ok, output) = runCommand(npm, args: ["install", "-g", "firebase-tools"])
        if ok {
          installed.append("firebase-tools")
        } else {
          errors.append("firebase-tools: npm install failed — \(output)")
        }
      } else if let brew = brewPath {
        let (ok, output) = runCommand(brew, args: ["install", "firebase-cli"])
        if ok {
          installed.append("firebase-tools")
        } else {
          errors.append("firebase-tools: brew install failed — \(output)")
        }
      } else {
        errors.append("firebase-tools: neither npm nor brew found")
      }
    }
    
    let success = errors.isEmpty
    return (200, makeResult(id: id, result: [
      "success": success,
      "installed": installed,
      "alreadyInstalled": alreadyInstalled,
      "errors": errors,
      "hint": success
        ? "All dependencies ready. Use firebase.emulator.start to launch emulators."
        : "Some installs failed. Fix errors above and retry."
    ]))
  }
  
  // MARK: - Install Helpers
  
  private func findBrewPath() -> String? {
    let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
  }
  
  private func findExecutable(_ name: String) -> String? {
    let paths = [
      "/opt/homebrew/bin/\(name)",
      "/usr/local/bin/\(name)",
      "/usr/bin/\(name)"
    ]
    // Also check NVM paths for npm/node
    if let home = ProcessInfo.processInfo.environment["HOME"] {
      let nvmDefault = "\(home)/.nvm/versions/node" 
      if let nodeVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmDefault) {
        for version in nodeVersions.sorted().reversed() {
          let candidate = "\(nvmDefault)/\(version)/bin/\(name)"
          if FileManager.default.fileExists(atPath: candidate) {
            return candidate
          }
        }
      }
    }
    return paths.first { FileManager.default.fileExists(atPath: $0) }
  }
  
  private func runCommand(_ executable: String, args: [String]) -> (Bool, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    // Inherit PATH so brew/npm can find dependencies
    var env = ProcessInfo.processInfo.environment
    if let brew = findBrewPath() {
      let brewBin = (brew as NSString).deletingLastPathComponent
      env["PATH"] = "\(brewBin):\(env["PATH"] ?? "/usr/bin:/bin")"
    }
    process.environment = env
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return (process.terminationStatus == 0, output)
    } catch {
      return (false, error.localizedDescription)
    }
  }
  
  private func handleEmulatorStatus(id: Any?) -> (Int, Data) {
    let service = FirebaseService.shared
    
    // Check if emulator process is running
    let processRunning = Self.emulatorProcess?.isRunning == true
    
    // Check if emulators are reachable
    var firestoreReachable = false
    var authReachable = false
    let host = service.emulatorHost ?? "localhost"
    
    // Quick TCP check for Firestore (8080) and Auth (9099)
    firestoreReachable = checkPort(host: host, port: 8080)
    authReachable = checkPort(host: host, port: 9099)
    
    return (200, makeResult(id: id, result: [
      "usingEmulators": service.isUsingEmulators,
      "emulatorHost": service.emulatorHost as Any,
      "processRunning": processRunning,
      "firestoreReachable": firestoreReachable,
      "authReachable": authReachable,
      "firestorePort": 8080,
      "authPort": 9099,
      "uiPort": 4000,
      "uiURL": "http://\(host):4000",
      "configuredVia": service.isUsingEmulators 
        ? (ProcessInfo.processInfo.environment["FIREBASE_EMULATOR_HOST"] != nil ? "environment" : "userDefaults")
        : "not configured",
      "hint": service.isUsingEmulators 
        ? "Emulator mode active. Firestore UI at http://\(host):4000"
        : "Set FIREBASE_EMULATOR_HOST env var or use firebase.emulator.configure to enable."
    ]))
  }
  
  private func handleEmulatorStart(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let lan = optionalBool("lan", from: arguments, default: false)
    let seed = optionalBool("seed", from: arguments, default: false)
    
    // Check if already running
    if Self.emulatorProcess?.isRunning == true {
      return (200, makeResult(id: id, result: [
        "success": true,
        "alreadyRunning": true,
        "message": "Firebase emulators already running"
      ]))
    }
    
    // Find the script
    let scriptPath = findProjectRoot() + "/Tools/firebase-emulator.sh"
    guard FileManager.default.fileExists(atPath: scriptPath) else {
      return internalError(id: id, message: "firebase-emulator.sh not found at \(scriptPath). Run from the project directory.")
    }
    
    // Check firebase CLI is available
    let whichProcess = Process()
    whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichProcess.arguments = ["firebase"]
    let whichPipe = Pipe()
    whichProcess.standardOutput = whichPipe
    whichProcess.standardError = whichPipe
    do {
      try whichProcess.run()
      whichProcess.waitUntilExit()
      if whichProcess.terminationStatus != 0 {
        return internalError(id: id, message: "firebase-tools not installed. Run: npm install -g firebase-tools")
      }
    } catch {
      return internalError(id: id, message: "Could not check for firebase CLI: \(error.localizedDescription)")
    }
    
    // Build arguments
    var args = [scriptPath]
    if lan { args.append("--lan") }
    if seed { args.append("--seed") }
    
    // Launch emulator process in background
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", args.joined(separator: " ")]
    process.currentDirectoryURL = URL(fileURLWithPath: findProjectRoot())
    
    // Capture output
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    
    do {
      try process.run()
      Self.emulatorProcess = process
      
      // Wait a few seconds for emulators to start
      try? await Task.sleep(for: .seconds(5))
      
      let host = lan ? getLocalIP() : "localhost"
      let running = checkPort(host: host, port: 8080)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "pid": process.processIdentifier,
        "lan": lan,
        "host": host,
        "firestoreReady": running,
        "uiURL": "http://\(host):4000",
        "hint": running 
          ? "Emulators running. Configure the app with: firebase.emulator.configure host=\(host)"
          : "Emulators starting... check again in a few seconds with firebase.emulator.status"
      ]))
    } catch {
      return internalError(id: id, message: "Failed to start emulators: \(error.localizedDescription)")
    }
  }
  
  private func handleEmulatorStop(id: Any?) async -> (Int, Data) {
    if let process = Self.emulatorProcess, process.isRunning {
      process.terminate()
      // Give it a moment to shut down
      try? await Task.sleep(for: .seconds(2))
      if process.isRunning {
        process.interrupt()
      }
      Self.emulatorProcess = nil
      return (200, makeResult(id: id, result: [
        "success": true,
        "message": "Emulators stopped"
      ]))
    }
    
    // Try pkill as fallback (emulators may have been started externally)
    let pkillProcess = Process()
    pkillProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkillProcess.arguments = ["-f", "firebase.*emulators"]
    try? pkillProcess.run()
    pkillProcess.waitUntilExit()
    
    return (200, makeResult(id: id, result: [
      "success": true,
      "message": "Emulator stop signal sent (may have been started externally)"
    ]))
  }
  
  private func handleEmulatorConfigure(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let host = optionalString("host", from: arguments, default: nil)
    let enable = optionalBool("enable", from: arguments, default: true)
    
    if enable {
      let resolvedHost = host ?? "localhost"
      UserDefaults.standard.set(true, forKey: "firebase_use_emulators")
      UserDefaults.standard.set(resolvedHost, forKey: "firebase_emulator_host")
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "enabled": true,
        "host": resolvedHost,
        "message": "Emulator mode configured. Restart the app (or re-run configure()) for changes to take effect.",
        "note": "Both machines on the LAN should set the same emulator host IP.",
        "defaults": [
          "firebase_use_emulators": true,
          "firebase_emulator_host": resolvedHost
        ]
      ]))
    } else {
      UserDefaults.standard.removeObject(forKey: "firebase_use_emulators")
      UserDefaults.standard.removeObject(forKey: "firebase_emulator_host")
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "enabled": false,
        "message": "Emulator mode disabled. App will use production Firebase on next restart."
      ]))
    }
  }
  
  // MARK: - Emulator Helpers
  
  private func checkPort(host: String, port: Int) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { close(sock) }
    
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr(host)
    
    // Set a short timeout
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0
  }
  
  private func getLocalIP() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    process.arguments = ["getifaddr", "en0"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "localhost"
    } catch {
      return "localhost"
    }
  }
  
  private func findProjectRoot() -> String {
    // Try common locations
    let candidates = [
      FileManager.default.currentDirectoryPath,
      ProcessInfo.processInfo.environment["PROJECT_DIR"] ?? "",
      Self.findRepoRootFromBuildLocation() ?? ""
    ]
    for candidate in candidates {
      if FileManager.default.fileExists(atPath: candidate + "/Tools/firebase-emulator.sh") {
        return candidate
      }
    }
    // Fallback: find via bundle
    if let bundlePath = Bundle.main.bundlePath as NSString? {
      let buildDir = bundlePath.deletingLastPathComponent
      let projectDir = (buildDir as NSString).deletingLastPathComponent
      if FileManager.default.fileExists(atPath: projectDir + "/Tools/firebase-emulator.sh") {
        return projectDir
      }
    }
    return FileManager.default.currentDirectoryPath
  }
  
  /// Find the repo root from #filePath (compile-time source location)
  /// This file lives at: <repo>/Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler.swift
  private static func findRepoRootFromBuildLocation() -> String? {
    var url = URL(fileURLWithPath: #filePath)
    // Walk up: SwarmToolsHandler.swift -> ToolHandlers/ -> AgentOrchestration/ -> Shared/ -> <repo root>
    for _ in 0..<4 {
      url = url.deletingLastPathComponent()
    }
    let root = url.path
    if FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("Tools")) {
      return root
    }
    return nil
  }
}
