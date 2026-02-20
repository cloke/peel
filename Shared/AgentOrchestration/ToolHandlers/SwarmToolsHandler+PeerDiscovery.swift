//
//  SwarmToolsHandler+PeerDiscovery.swift
//  Peel
//
//  Handles: swarm.start, swarm.stop, swarm.status, swarm.diagnostics,
//           swarm.workers, swarm.connect, swarm.rag.sync,
//           swarm.discovered, swarm.register-repo, swarm.repos
//  Split from SwarmToolsHandler.swift as part of #301.
//

import Foundation
import MCPCore

extension SwarmToolsHandler {
  // MARK: - swarm.start
  
  func handleStart(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
        print("Note: WAN mode enabled — resolving public IP for peer-to-peer connections")
      }
      
      // Auto-register as Firestore worker for all member swarms (WAN discovery)
      var firestoreRegistrations: [[String: Any]] = []
      let firebaseService = FirebaseService.shared
      
      let lanAddress = coordinator.capabilities.lanAddress
      let lanPort = coordinator.capabilities.lanPort
      
      // Resolve WAN address for P2P connections across networks
      let wanAddress = await WANAddressResolver.resolve()
      
      if firebaseService.isSignedIn {
        let capabilities = WorkerCapabilities.current(
          lanAddress: lanAddress,
          lanPort: lanPort,
          wanAddress: wanAddress,
          wanPort: UInt16(port)
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
              "wanAddress": wanAddress as Any,
              "wanPort": Int(port),
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
        
        // Auto-connect to WAN peers after registration
        if enableWAN {
          await coordinator.startWANAutoConnect()
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
        "wanAddress": wanAddress as Any,
        "wanPort": Int(port),
        "lanAddress": lanAddress as Any,
        "lanPort": lanPort.map { Int($0) } as Any
      ]))
    } catch {
      return internalError(id: id, message: "Failed to start swarm: \(error.localizedDescription)")
    }
  }
  
  // MARK: - swarm.stop
  
  func handleStop(id: Any?) async -> (Int, Data) {
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
  
  func handleStatus(id: Any?) -> (Int, Data) {
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

  func handleDiagnostics(id: Any?) -> (Int, Data) {
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
      "localRagArtifacts": localRagPayload,
      "messageListeners": FirebaseService.shared.messageListenerDiagnostics()
    ]))
  }
  
  // MARK: - swarm.workers
  
  func handleWorkers(id: Any?) -> (Int, Data) {
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
  
  // MARK: - swarm.connect
  
  func handleConnect(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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

  func handleRagSync(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
    let repoIdentifier = optionalString("repoIdentifier", from: arguments)

    do {
      let transferId = try await coordinator.requestRagArtifactSync(direction: direction, workerId: workerId, repoIdentifier: repoIdentifier)
      return (200, makeResult(id: id, result: [
        "success": true,
        "transferId": transferId.uuidString,
        "direction": direction.rawValue,
        "workerId": workerId as Any,
        "repoIdentifier": repoIdentifier as Any
      ]))
    } catch {
      return internalError(id: id, message: error.localizedDescription)
    }
  }
  
  // MARK: - swarm.discovered
  
  func handleDiscovered(id: Any?) -> (Int, Data) {
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
  
  // MARK: - swarm.register-repo
  
  func handleRegisterRepo(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleRepos(id: Any?) -> (Int, Data) {
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
