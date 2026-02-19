//
//  SwarmToolsHandler+TaskDispatch.swift
//  Peel
//
//  Handles: swarm.dispatch, swarm.tasks, swarm.update-workers,
//           swarm.update-log, swarm.direct-command, swarm.branch-queue,
//           swarm.pr-queue, swarm.create-pr, swarm.setup-labels
//  Split from SwarmToolsHandler.swift as part of #301.
//

import Foundation
import MCPCore

extension SwarmToolsHandler {
  // MARK: - swarm.dispatch
  
  func handleDispatch(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  // MARK: - swarm.tasks
  
  func handleTasks(id: Any?, arguments: [String: Any]) -> (Int, Data) {
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
  
  func handleUpdateWorkers(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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

  func handleUpdateLog(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleDirectCommand(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleBranchQueue(id: Any?, arguments: [String: Any]) -> (Int, Data) {
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
  
  func handlePRQueue(id: Any?, arguments: [String: Any]) -> (Int, Data) {
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
  
  func handleCreatePR(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
  func handleSetupLabels(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
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
  
}
