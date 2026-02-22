//
//  SwarmToolsHandler+Firestore.swift
//  Peel
//
//  Handles: swarm.firestore.* tools — auth, swarms, create, debug, activity,
//           migrate, backup, workers, register-worker, unregister-worker,
//           submit-task, tasks, rag.artifacts, rag.push, rag.pull, rag.delete
//  Split from SwarmToolsHandler.swift as part of #301.
//

import Foundation
import MCPCore

extension SwarmToolsHandler {
  // MARK: - Firestore Swarm Tools
  
  func handleFirestoreAuth(id: Any?) -> (Int, Data) {
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
  
  func handleFirestoreSwarms(id: Any?) async -> (Int, Data) {
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
  
  func handleFirestoreCreate(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleFirestoreDebug(id: Any?) -> (Int, Data) {
    let service = FirebaseService.shared
    let debugInfo = service.debugQuerySwarms()
    return (200, makeResult(id: id, result: debugInfo))
  }
  
  func handleFirestoreMigrate(id: Any?) async -> (Int, Data) {
    let service = FirebaseService.shared
    do {
      let result = try await service.migrateMemberUserIds()
      return (200, makeResult(id: id, result: result))
    } catch {
      return internalError(id: id, message: "Migration failed: \(error.localizedDescription)")
    }
  }

  func handleFirestoreBackup(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleFirestoreActivity(id: Any?, arguments: [String: Any]) -> (Int, Data) {
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
  
  func handleFirestoreWorkers(id: Any?, arguments: [String: Any]) -> (Int, Data) {
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
  
  func handleFirestoreRegisterWorker(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleFirestoreUnregisterWorker(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleFirestoreSubmitTask(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleFirestoreTasks(id: Any?, arguments: [String: Any]) -> (Int, Data) {
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
  
  func handleFirestoreRAGArtifacts(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleFirestoreRAGPush(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let forceFullDB = (arguments["fullDB"] as? Bool) ?? false
    let service = FirebaseService.shared
    let ragStore = LocalRAGStore.shared
    
    do {
      // Auto-detect repoIdentifier from argument, RepoRegistry cache, or git remote
      var repoIdentifier = optionalString("repoIdentifier", from: arguments)
      if repoIdentifier == nil && !forceFullDB {
        // Try cached lookup first (fast, no git process)
        if let cached = await RepoRegistry.shared.getCachedRemoteURL(for: repoPath) {
          repoIdentifier = await RepoRegistry.shared.normalizeRemoteURL(cached)
        } else {
          // Discover from git remote (runs git process)
          repoIdentifier = await RepoRegistry.shared.registerRepo(at: repoPath)
        }
      }

      // Per-repo sync (default, safe path)
      if let repoIdentifier, !forceFullDB {
        guard let repoBundle = try await ragStore.exportRepo(identifier: repoIdentifier) else {
          return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "No RAG index found for repo identifier: \(repoIdentifier). Ensure the repo is indexed and has a repo_identifier set."))
        }
        let jsonData = try JSONEncoder().encode(repoBundle)
        let artifactId = try await service.pushRAGRepoBundle(swarmId: swarmId, repoIdentifier: repoIdentifier, data: jsonData)
        return (200, makeResult(id: id, result: [
          "success": true,
          "swarmId": swarmId,
          "artifactId": artifactId,
          "repoIdentifier": repoIdentifier,
          "totalBytes": jsonData.count,
          "formattedSize": ByteCountFormatter.string(fromByteCount: Int64(jsonData.count), countStyle: .file),
          "fileCount": repoBundle.files.count,
          "chunkCount": repoBundle.files.flatMap(\.chunks).count,
          "mode": "per-repo"
        ]))
      }

      // Full DB sync (legacy path — requires explicit fullDB: true)
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
        "embeddingCacheCount": bundle.manifest.embeddingCacheCount,
        "mode": "full-db",
        "warning": "Full-DB sync replaces the ENTIRE database on the pull side, including all repos and embeddings. Consider using per-repo sync instead."
      ]))
    } catch {
      return internalError(id: id, message: "Failed to push RAG artifacts: \(error.localizedDescription)")
    }
  }
  
  func handleFirestoreRAGPull(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let swarmId = arguments["swarmId"] as? String, !swarmId.isEmpty else {
      return missingParamError(id: id, param: "swarmId")
    }
    guard let artifactId = arguments["artifactId"] as? String, !artifactId.isEmpty else {
      return missingParamError(id: id, param: "artifactId")
    }
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let forceFullDB = (arguments["fullDB"] as? Bool) ?? false
    let forceEmbeddings = (arguments["forceEmbeddings"] as? Bool) ?? true  // Default true: import remote embeddings
    let service = FirebaseService.shared
    let ragStore = LocalRAGStore.shared
    
    do {
      // Auto-detect repoIdentifier from argument, RepoRegistry cache, or git remote
      var repoIdentifier = optionalString("repoIdentifier", from: arguments)
      if repoIdentifier == nil && !forceFullDB {
        if let cached = await RepoRegistry.shared.getCachedRemoteURL(for: repoPath) {
          repoIdentifier = await RepoRegistry.shared.normalizeRemoteURL(cached)
        } else {
          repoIdentifier = await RepoRegistry.shared.registerRepo(at: repoPath)
        }
      }

      // Per-repo sync (default, safe path): pull JSON bundle, decode, and merge
      if let repoIdentifier, !forceFullDB {
        let jsonData = try await service.pullRAGRepoBundle(swarmId: swarmId, artifactId: artifactId)
        let repoBundle = try JSONDecoder().decode(RAGRepoExportBundle.self, from: jsonData)
        let result = try await ragStore.importRepoBundle(repoBundle, localRepoPath: repoPath, forceImportEmbeddings: forceEmbeddings)
        var resultDict: [String: Any] = [
          "success": true,
          "swarmId": swarmId,
          "artifactId": artifactId,
          "repoIdentifier": repoIdentifier,
          "repoPath": repoPath,
          "filesImported": result.filesImported,
          "filesSkipped": result.filesSkipped,
          "chunksImported": result.chunksImported,
          "embeddingsImported": result.embeddingsImported,
          "chunksAnalysisUpdated": result.chunksAnalysisUpdated,
          "embeddingsBackfilled": result.embeddingsBackfilled,
          "mode": "per-repo"
        ]
        if result.needsLocalReembedding {
          resultDict["needsReembedding"] = true
          resultDict["embeddingsSkipped"] = result.embeddingsSkippedModelMismatch
          resultDict["remoteEmbeddingModel"] = result.remoteEmbeddingModel ?? "unknown"
        }
        return (200, makeResult(id: id, result: resultDict))
      }

      // Full DB sync (legacy path — requires explicit fullDB: true)
      let tempDir = FileManager.default.temporaryDirectory
      let bundleURL = tempDir.appendingPathComponent("rag-artifact-\(artifactId).zip")
      
      let manifest = try await service.pullRAGArtifacts(
        swarmId: swarmId,
        artifactId: artifactId,
        destination: bundleURL
      )
      
      let bundle = LocalRAGArtifactBundle(manifest: manifest, bundleURL: bundleURL, bundleSizeBytes: try FileManager.default.attributesOfItem(atPath: bundleURL.path)[.size] as? Int ?? 0)
      try await ragStore.importArtifactBundle(bundle, for: repoPath)
      
      try? FileManager.default.removeItem(at: bundleURL)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "swarmId": swarmId,
        "artifactId": artifactId,
        "version": manifest.version,
        "repoPath": repoPath,
        "repoCount": manifest.repos.count,
        "embeddingCacheCount": manifest.embeddingCacheCount,
        "mode": "full-db",
        "warning": "Full-DB sync replaced the ENTIRE local database, including all repos and embeddings. All previously indexed repos may need re-indexing with the local model."
      ]))
    } catch {
      return internalError(id: id, message: "Failed to pull RAG artifacts: \(error.localizedDescription)")
    }
  }
  
  func handleFirestoreRAGDelete(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
}
