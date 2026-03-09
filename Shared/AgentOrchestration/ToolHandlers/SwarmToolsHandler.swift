//
//  SwarmToolsHandler.swift
//  Peel
//
//  Thin coordinator for swarm/distributed MCP tools. Dispatches to:
//    SwarmToolsHandler+PeerDiscovery.swift  — start, stop, status, workers, connect
//    SwarmToolsHandler+TaskDispatch.swift   — dispatch, tasks, update, queues, PRs
//    SwarmToolsHandler+Firestore.swift      — Firestore CRUD tools
//    SwarmToolsHandler+Firebase.swift       — Firebase emulator tools
//    SwarmToolsHandler+ToolDefinitions.swift — tool definitions
//

import Foundation
import MCPCore

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
  let chainRunner: AgentChainRunner?
  
  /// Agent manager for finding chain templates and creating chains
  let agentManager: AgentManager?
  
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
    "swarm.reindex",
    "swarm.update-log",
    "swarm.direct-command",
    "swarm.branch-queue",
    "swarm.pr-queue",
    "swarm.create-pr",
    "swarm.setup-labels",
    "swarm.register-repo",
    "swarm.repos",
    "swarm.stun-test",
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
    "firebase.emulator.configure",
    // On-demand P2P RAG index sharing
    "swarm.rag-versions",
    "swarm.rag-availability",
    "swarm.rag-sync-index"
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
    case "swarm.stun-test":
      return await handleStunTest(id: id, arguments: arguments)
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
    case "swarm.reindex":
      return await handleReindex(id: id, arguments: arguments)
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
      return handleFirestoreDebug(id: id)
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
    // On-demand P2P RAG index sharing
    case "swarm.rag-versions":
      return handleRagVersions(id: id)
    case "swarm.rag-availability":
      return handleRagAvailability(id: id, arguments: arguments)
    case "swarm.rag-sync-index":
      return await handleRagSyncIndex(id: id, arguments: arguments)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }
  // MARK: - Shared Coordinator Access
  
  var coordinator: SwarmCoordinator {
    SwarmCoordinator.shared
  }
  
}
