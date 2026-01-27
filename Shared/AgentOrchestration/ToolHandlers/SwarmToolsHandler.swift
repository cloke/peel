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
    "swarm.workers",
    "swarm.dispatch",
    "swarm.connect",
    "swarm.discovered"
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
    case "swarm.workers":
      return handleWorkers(id: id)
    case "swarm.dispatch":
      return await handleDispatch(id: id, arguments: arguments)
    case "swarm.connect":
      return await handleConnect(id: id, arguments: arguments)
    case "swarm.discovered":
      return handleDiscovered(id: id)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }
  
  // MARK: - Tool Definitions
  
  public static func toolDefinitions() -> [[String: Any]] {
    [
      [
        "name": "swarm.start",
        "description": "Start the distributed swarm coordinator. Role can be 'brain' (dispatch work), 'worker' (execute work), or 'hybrid' (both).",
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
        "name": "swarm.workers",
        "description": "List all connected workers with their capabilities.",
        "inputSchema": [
          "type": "object",
          "properties": [:],
          "required": []
        ]
      ],
      [
        "name": "swarm.dispatch",
        "description": "Dispatch a task to the swarm for execution by a worker.",
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
        "hasChainExecutor": chainRunner != nil
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
    guard coordinator.isActive else {
      return (200, makeResult(id: id, result: [
        "active": false,
        "role": NSNull(),
        "workerCount": 0,
        "tasksCompleted": 0,
        "tasksFailed": 0
      ]))
    }
    
    return (200, makeResult(id: id, result: [
      "active": coordinator.isActive,
      "role": coordinator.role.rawValue,
      "workerCount": coordinator.connectedWorkers.count,
      "tasksCompleted": coordinator.tasksCompleted,
      "tasksFailed": coordinator.tasksFailed,
      "currentTask": coordinator.currentTask?.id.uuidString as Any,
      "capabilities": [
        "deviceName": coordinator.capabilities.deviceName,
        "deviceId": coordinator.capabilities.deviceId,
        "gpuCores": coordinator.capabilities.gpuCores,
        "neuralEngineCores": coordinator.capabilities.neuralEngineCores,
        "memoryGB": coordinator.capabilities.memoryGB
      ]
    ]))
  }
  
  // MARK: - swarm.workers
  
  private func handleWorkers(id: Any?) -> (Int, Data) {
    guard coordinator.isActive else {
      return (200, makeResult(id: id, result: [
        "workers": []
      ]))
    }
    
    let workers = coordinator.connectedWorkers.map { peer in
      [
        "id": peer.id,
        "name": peer.name,
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
    
    return (200, makeResult(id: id, result: [
      "workers": workers,
      "count": workers.count
    ]))
  }
  
  // MARK: - swarm.dispatch
  
  private func handleDispatch(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return internalError(id: id, message: "Swarm not running. Call swarm.start first.")
    }
    
    guard coordinator.role == .brain || coordinator.role == .hybrid else {
      return internalError(id: id, message: "Only brain or hybrid roles can dispatch tasks")
    }
    
    guard case .success(let prompt) = requireString("prompt", from: arguments, id: id) else {
      return missingParamError(id: id, param: "prompt")
    }
    
    let templateId = optionalString("templateId", from: arguments)
    let templateName = optionalString("templateName", from: arguments) ?? "default"
    let workingDirectory = optionalString("workingDirectory", from: arguments) ?? FileManager.default.currentDirectoryPath
    let priorityInt = optionalInt("priority", from: arguments, default: 1) ?? 1
    let priority = ChainPriority(rawValue: priorityInt) ?? .normal
    
    // Create request
    let request = ChainRequest(
      templateName: templateName,
      prompt: prompt,
      workingDirectory: workingDirectory,
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
      return internalError(id: id, message: "Swarm not running. Call swarm.start first.")
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
}
