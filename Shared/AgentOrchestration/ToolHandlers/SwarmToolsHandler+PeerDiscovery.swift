//
//  SwarmToolsHandler+PeerDiscovery.swift
//  Peel
//
//  Handles: swarm.start, swarm.stop, swarm.status, swarm.diagnostics,
//           swarm.workers, swarm.connect, swarm.rag.sync,
//           swarm.discovered, swarm.register-repo, swarm.repos
//  Split from SwarmToolsHandler.swift as part of #301.
//
//  NOTE: "peers" in diagnostics = TCP-connected (for file transfers only).
//  "firestoreWorkers" = all registered workers (the source of truth for
//  task dispatch and coordination). See SwarmCoordinator.swift header.
//

import Foundation
import os.log
import MCPCore
import WebRTCTransfer

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
      
      // Resolve WAN address for P2P connections across networks (explicit override wins)
      let wanAddress: String?
      if let explicitWANAddress {
        wanAddress = explicitWANAddress
      } else {
        wanAddress = await WANAddressResolver.resolve()
      }
      coordinator.setResolvedWANAddress(wanAddress)
      
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
          coordinator.startWANAutoConnect()
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
    let formatter = Formatter.iso8601
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
          "tasksFailed": status?.tasksFailed as Any,
          "gitCommitHash": status?.gitCommitHash as Any
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
        "gitCommitHash": coordinator.capabilities.gitCommitHash as Any,
      ],
      "peers": peers,
      "discovered": discovered,
      "firestoreWorkers": {
        let tcpPeerIds = Set(coordinator.connectedWorkers.map(\.id))
        return FirebaseService.shared.swarmWorkers.map { w in
          [
            "id": w.id,
            "displayName": w.displayName,
            "deviceName": w.deviceName,
            "status": w.status.rawValue,
            "isOffline": w.isStale,
            "lastHeartbeat": formatter.string(from: w.lastHeartbeat),
            "version": w.version as Any,
            "gitCommitHash": w.gitCommitHash as Any,
            "wanAddress": w.wanAddress as Any,
            "wanPort": w.wanPort.map { Int($0) } as Any,
            "lanAddress": w.lanAddress as Any,
            "lanPort": w.lanPort.map { Int($0) } as Any,
            "tcpConnected": tcpPeerIds.contains(w.id)
          ] as [String: Any]
        }
      }(),
      "ragTransfers": transfers,
      "onDemandSyncs": {
        let syncCoord = RAGSyncCoordinator.shared
        let active = syncCoord.activeTransfers.map { t in
          [
            "id": t.id.uuidString,
            "peerName": t.peerName,
            "repo": t.repoIdentifier as Any,
            "status": t.status.rawValue,
            "transferredBytes": t.transferredBytes,
            "totalBytes": t.totalBytes,
            "error": t.errorMessage as Any,
          ] as [String: Any]
        }
        let history = syncCoord.syncHistory.suffix(5).map { h in
          [
            "repo": h.repoIdentifier,
            "from": h.fromWorkerName,
            "method": h.connectionMethod,
            "bytes": h.bytesTransferred,
            "duration": h.duration,
            "success": h.success,
            "error": h.errorMessage as Any,
            "timestamp": formatter.string(from: h.timestamp),
          ] as [String: Any]
        }
        return [
          "activeCount": active.count,
          "active": active,
          "recentHistory": history,
        ] as [String: Any]
      }(),
      "localRagArtifacts": localRagPayload,
      "webrtcSessions": {
        let psm = coordinator.peerSessionManager
        return psm.peerStates.map { (peerId, state) in
          [
            "peerId": peerId,
            "state": String(describing: state),
            "rttMs": psm.peerRTT[peerId] as Any
          ] as [String: Any]
        }
      }(),
      "messageTrace": coordinator.messageTrace.prefix(20).map { entry in
        [
          "time": Formatter.iso8601.string(from: entry.date),
          "dir": entry.direction,
          "peer": String(entry.peerId.prefix(8)),
          "type": entry.type,
          "detail": entry.detail
        ] as [String: Any]
      },
      "messageListeners": FirebaseService.shared.messageListenerDiagnostics(),
      "workerListeners": {
        let diag = FirebaseService.shared.workerListenerDiagnostics
        return [
          "activeSwarmIds": diag.activeSwarmIds,
          "workerCountsBySwarm": diag.workerCounts,
          "totalWorkers": diag.totalWorkers,
          "isSignedIn": FirebaseService.shared.isSignedIn,
          "memberSwarmCount": FirebaseService.shared.memberSwarms.count,
          "memberSwarms": FirebaseService.shared.memberSwarms.map { ["id": $0.id, "name": $0.swarmName, "role": $0.role.rawValue] }
        ] as [String: Any]
      }()
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
    let formatter = Formatter.iso8601
    
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
    let modeRaw = optionalString("mode", from: arguments) ?? "full"
    let transferMode = RAGTransferMode(rawValue: modeRaw) ?? .full

    do {
      let transferId = try await coordinator.requestRagArtifactSync(direction: direction, workerId: workerId, repoIdentifier: repoIdentifier, transferMode: transferMode)
      return (200, makeResult(id: id, result: [
        "success": true,
        "transferId": transferId.uuidString,
        "direction": direction.rawValue,
        "mode": transferMode.rawValue,
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

  // MARK: - swarm.p2p-logs (deprecated)

  func handleP2PLogs(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    return (200, makeResult(id: id, result: [
      "deprecated": true,
      "message": "P2P connection logs have been replaced by WebRTC session diagnostics. Use swarm.diagnostics instead.",
    ]))
  }

  // MARK: - swarm.request-logs (deprecated)

  func handleRequestLogs(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    return (200, makeResult(id: id, result: [
      "deprecated": true,
      "message": "Remote log requests have been replaced by WebRTC session diagnostics. Use swarm.diagnostics instead.",
    ]))
  }

  /// Resolve a worker ID from either a name or direct ID
  private func resolveWorkerId(name: String?, id: String?) -> String? {
    if let id, !id.isEmpty { return id }
    guard let name, !name.isEmpty else { return nil }
    let lowered = name.lowercased()
    return FirebaseService.shared.swarmWorkers
      .first(where: { $0.displayName.lowercased() == lowered || $0.deviceName.lowercased() == lowered })?
      .workerId
  }

  // MARK: - swarm.webrtc-ping

  func handleWebRTCPing(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return serviceNotActiveError(id: id, service: "Swarm", hint: "Call swarm.start first")
    }

    // Resolve target worker
    let targetWorkerName = arguments["targetWorkerName"] as? String
    let targetWorkerId = arguments["targetWorkerId"] as? String

    guard let workerId = resolveWorkerId(name: targetWorkerName, id: targetWorkerId) else {
      return missingParamError(id: id, param: "targetWorkerName or targetWorkerId")
    }

    // Find swarm ID
    guard let swarmId = FirebaseService.shared.memberSwarms.first(where: { $0.role.canRegisterWorkers })?.id else {
      return internalError(id: id, message: "No active swarm found")
    }

    let timeout = arguments["timeout"] as? Int ?? 30
    let workerDisplay = targetWorkerName ?? workerId

    // Create signaling channel with purpose=ping
    let signaling = FirestoreWebRTCSignaling(
      swarmId: swarmId,
      myDeviceId: coordinator.capabilities.deviceId,
      remoteDeviceId: workerId
    )
    signaling.purpose = "ping"

    do {
      let result = try await WebRTCPeerTransfer.ping(
        signaling: signaling,
        timeout: .seconds(timeout)
      )

      let timing: [String: Any] = [
        "signalingMs": round(result.signalingMs * 10) / 10,
        "iceNegotiationMs": round(result.iceNegotiationMs * 10) / 10,
        "roundTripMs": round(result.roundTripMs * 10) / 10,
        "totalMs": round(result.totalMs * 10) / 10,
      ]
      let summary = String(
        format: "WebRTC ping to %@: signaling=%.0fms ice=%.0fms rtt=%.1fms total=%.0fms",
        workerDisplay, result.signalingMs, result.iceNegotiationMs, result.roundTripMs, result.totalMs
      )
      let body: [String: Any] = [
        "success": true,
        "target": workerDisplay,
        "targetWorkerId": workerId,
        "timing": timing,
        "summary": summary,
      ]
      return (200, makeResult(id: id, result: body))
    } catch {
      let body: [String: Any] = [
        "success": false,
        "target": workerDisplay,
        "targetWorkerId": workerId,
        "error": String(describing: error),
        "hint": "Ensure the target worker is running Peel with swarm active. Check swarm.diagnostics to verify the worker is registered.",
      ]
      return (200, makeResult(id: id, result: body))
    }
  }

  // MARK: - swarm.stun-test (deprecated)

  func handleStunTest(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    return (200, makeResult(id: id, result: [
      "deprecated": true,
      "message": "STUN test is no longer needed. NAT traversal is now handled automatically by WebRTC ICE. Use swarm.webrtc-ping to test connectivity.",
    ]))
  }

  // MARK: - swarm.rag-versions (on-demand P2P)

  func handleRagVersions(id: Any?) -> (Int, Data) {
    let syncCoordinator = RAGSyncCoordinator.shared
    let remoteRepos = syncCoordinator.listRemoteRepos()

    if remoteRepos.isEmpty {
      return (200, makeResult(id: id, result: [
        "available": false,
        "message": "No remote RAG index versions found. Ensure swarm peers have published their indexes (run rag.index on a peer).",
        "repos": [] as [[String: Any]],
      ]))
    }

    let repoEntries: [[String: Any]] = remoteRepos.map { repo in
      var entry: [String: Any] = [
        "repoIdentifier": repo.repoIdentifier,
        "repoName": repo.repoName,
        "version": repo.bestVersion.version,
        "chunkCount": repo.bestVersion.chunkCount,
        "embeddingModel": repo.bestVersion.embeddingModel,
        "workerId": repo.bestVersion.workerId,
        "workerName": repo.bestVersion.workerName,
        "sourceCount": repo.sourceCount,
        "isUpdateAvailable": repo.isUpdateAvailable,
      ]
      entry["updatedAt"] = ISO8601DateFormatter().string(from: repo.bestVersion.lastIndexedAt)
      return entry
    }

    return (200, makeResult(id: id, result: [
      "available": true,
      "count": repoEntries.count,
      "repos": repoEntries,
    ]))
  }

  // MARK: - swarm.rag-availability

  func handleRagAvailability(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let syncCoordinator = RAGSyncCoordinator.shared
    let repoFilter = (arguments["repoIdentifier"] as? String)
      .map { RepoRegistry.shared.normalizeRemoteURL($0) }

    let connectedPeers: [[String: Any]] = coordinator.connectedWorkers.map { peer in
      let status = coordinator.workerStatuses[peer.id]
      return [
        "workerId": peer.id,
        "workerName": peer.displayName,
        "gitCommitHash": peer.capabilities.gitCommitHash as Any,
        "state": status?.state.rawValue as Any,
        "lastHeartbeat": status.map { Formatter.iso8601.string(from: $0.lastHeartbeat) } as Any,
      ]
    }

    let remoteVersions: [[String: Any]] = syncCoordinator.remoteVersions
      .sorted { $0.key < $1.key }
      .flatMap { repoIdentifier, workers in
        workers.values
          .sorted { lhs, rhs in
            if lhs.repoIdentifier == rhs.repoIdentifier {
              return lhs.workerName < rhs.workerName
            }
            return lhs.repoIdentifier < rhs.repoIdentifier
          }
          .filter { repoFilter == nil || $0.repoIdentifier == repoFilter }
          .map { version in
            [
              "repoIdentifier": version.repoIdentifier,
              "repoName": version.repoName,
              "workerId": version.workerId,
              "workerName": version.workerName,
              "version": version.version,
              "chunkCount": version.chunkCount,
              "embeddingModel": version.embeddingModel,
              "updatedAt": Formatter.iso8601.string(from: version.lastIndexedAt),
            ]
          }
      }

    let availableUpdates: [[String: Any]] = syncCoordinator.availableUpdates
      .filter { repoFilter == nil || RepoRegistry.shared.normalizeRemoteURL($0.source.repoIdentifier) == repoFilter }
      .map { availability in
        [
          "swarmId": availability.swarmId,
          "repoIdentifier": availability.source.repoIdentifier,
          "repoName": availability.source.repoName,
          "workerId": availability.source.workerId,
          "workerName": availability.source.workerName,
          "remoteVersion": availability.source.version,
          "localVersion": availability.localVersion as Any,
          "localChunkCount": availability.localChunkCount as Any,
          "remoteChunkCount": availability.source.chunkCount,
          "updatedAt": Formatter.iso8601.string(from: availability.source.lastIndexedAt),
        ]
      }

    let firestoreWorkers: [[String: Any]] = FirebaseService.shared.swarmWorkers
      .sorted { $0.displayName < $1.displayName }
      .map { worker in
        [
          "workerId": worker.id,
          "workerName": worker.displayName,
          "status": worker.status.rawValue,
          "isOffline": worker.isStale,
          "lastHeartbeat": Formatter.iso8601.string(from: worker.lastHeartbeat),
        ]
      }

    return (200, makeResult(id: id, result: [
      "repoIdentifierFilter": repoFilter as Any,
      "connectedPeerCount": connectedPeers.count,
      "remoteVersionCount": remoteVersions.count,
      "availableUpdateCount": availableUpdates.count,
      "connectedPeers": connectedPeers,
      "remoteVersions": remoteVersions,
      "availableUpdates": availableUpdates,
      "firestoreWorkers": firestoreWorkers,
    ]))
  }

  // MARK: - swarm.rag-sync-index (on-demand P2P)

  func handleRagSyncIndex(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let repoIdentifier = arguments["repoIdentifier"] as? String else {
      return missingParamError(id: id, param: "repoIdentifier")
    }

    // Resolve worker: explicit workerId > targetWorkerName/worker lookup > nil (auto-pick)
    var fromWorkerId = arguments["workerId"] as? String
    let targetName = (arguments["targetWorkerName"] as? String) ?? (arguments["worker"] as? String)
    if fromWorkerId == nil, let targetName, !targetName.isEmpty {
      let match = FirebaseService.shared.swarmWorkers.first(where: {
        $0.displayName.localizedCaseInsensitiveCompare(targetName) == .orderedSame
      })
      if let match {
        fromWorkerId = match.id
      } else {
        return (200, makeResult(id: id, result: [
          "success": false,
          "repoIdentifier": repoIdentifier,
          "error": "Worker '\(targetName)' not found. Available workers: \(FirebaseService.shared.swarmWorkers.map(\.displayName).joined(separator: ", "))",
        ]))
      }
    }

    // Resolve swarmId: explicit argument > active worker listener swarm > first member swarm > error
    let resolvedSwarmId: String
    if let explicit = arguments["swarmId"] as? String, !explicit.isEmpty {
      resolvedSwarmId = explicit
    } else {
      let firebase = FirebaseService.shared
      let activeSwarmIds = firebase.workerListenerDiagnostics.activeSwarmIds
      if let firstActive = activeSwarmIds.first, !firstActive.isEmpty {
        resolvedSwarmId = firstActive
      } else if let firstMember = firebase.memberSwarms.first(where: { $0.role.canRegisterWorkers }) {
        resolvedSwarmId = firstMember.id
      } else {
        return (200, makeResult(id: id, result: [
          "success": false,
          "repoIdentifier": repoIdentifier,
          "error": "No swarmId provided and no active swarm. Start a swarm first with swarm.start.",
        ]))
      }
    }

    let syncCoordinator = RAGSyncCoordinator.shared

    // Validate delegate is configured before starting background work
    guard syncCoordinator.ragSyncDelegate != nil else {
      return (200, makeResult(id: id, result: [
        "success": false,
        "repoIdentifier": repoIdentifier,
        "error": "RAG sync delegate not configured — MCPServerService may not be initialized.",
      ]))
    }

    // Fire-and-forget: start the sync in the background and return immediately.
    // P2P transfers can take minutes (300-600s internal timeouts). Blocking the
    // MCP response would make the server appear hung.
    // Callers can poll progress via swarm.diagnostics (ragTransfers) or
    // swarm.rag-availability.
    let swarmId = resolvedSwarmId
    Task {
      do {
        if let workerId = fromWorkerId {
          try await syncCoordinator.syncIndex(
            repoIdentifier: repoIdentifier,
            fromWorkerId: workerId,
            swarmId: swarmId
          )
        } else {
          try await syncCoordinator.syncIndex(repoIdentifier: repoIdentifier)
        }
      } catch {
        Logger(subsystem: "com.peel.swarm", category: "RAGSync")
          .error("Background sync failed for \(repoIdentifier): \(error)")
      }
    }

    return (200, makeResult(id: id, result: [
      "success": true,
      "repoIdentifier": repoIdentifier,
      "swarmId": resolvedSwarmId,
      "message": "RAG sync started in background. Monitor progress with swarm.diagnostics (check ragTransfers) or swarm.rag-availability.",
      "async": true,
    ]))
  }

}
