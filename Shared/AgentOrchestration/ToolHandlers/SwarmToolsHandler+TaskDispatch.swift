//
//  SwarmToolsHandler+TaskDispatch.swift
//  Peel
//
//  Handles: swarm.dispatch, swarm.tasks, swarm.update-workers, swarm.reindex,
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
    
    // Self-update intentionally kills and restarts the Peel worker process, so waiting
    // for a final direct-command result will always race the restart and report a timeout.
    var dispatched: [[String: Any]] = []
    
    for worker in workers {
      do {
        let scriptArgs = force ? [] : ["--skip-build"]

        try await coordinator.sendDirectCommand(
          "./Tools/self-update.sh",
          args: scriptArgs,
          workingDirectory: nil,
          to: worker.id
        )

        dispatched.append([
          "workerId": worker.id,
          "workerName": worker.displayName,
          "status": "dispatched",
          "message": "Update command sent. Worker should disconnect briefly while restarting.",
          "args": scriptArgs
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
    
    let dispatchedCount = dispatched.filter { ($0["status"] as? String) == "dispatched" }.count
    let failed = dispatched.count - dispatchedCount
    
    return (200, makeResult(id: id, result: [
      "success": failed == 0,
      "message": failed == 0 
        ? "Update commands dispatched to all workers. They should disconnect briefly while restarting."
        : "Dispatched to \(dispatchedCount) workers, \(failed) failed before dispatch. Check 'workers' for details.",
      "workersUpdated": dispatchedCount,
      "workersFailed": failed,
      "awaitedResults": false,
      "workers": dispatched
    ]))
  }

  // MARK: - swarm.reindex

  func handleReindex(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return serviceNotActiveError(id: id, service: "Swarm", hint: "Call swarm.start with role 'brain' or 'hybrid' first")
    }

    guard coordinator.role == .brain || coordinator.role == .hybrid else {
      return internalError(id: id, message: "Only brain or hybrid can trigger remote reindex")
    }

    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }

    let pullFirst = optionalBool("pullFirst", from: arguments, default: true)
    let forceReindex = optionalBool("forceReindex", from: arguments, default: false)
    let allowWorkspace = optionalBool("allowWorkspace", from: arguments, default: false)
    let excludeSubrepos = optionalBool("excludeSubrepos", from: arguments, default: true)
    let workerId = optionalString("workerId", from: arguments)

    let targetWorkers: [ConnectedPeer]
    if let workerId {
      guard let worker = coordinator.connectedWorkers.first(where: { $0.id == workerId }) else {
        return internalError(id: id, message: "Worker not found: \(workerId)")
      }
      targetWorkers = [worker]
    } else {
      targetWorkers = coordinator.connectedWorkers
    }

    guard !targetWorkers.isEmpty else {
      return (200, makeResult(id: id, result: [
        "success": false,
        "message": "No workers connected",
        "workersSucceeded": 0,
        "workersFailed": 0,
        "workers": []
      ]))
    }

    var workerResults: [[String: Any]] = []

    for worker in targetWorkers {
      let script = buildRemoteReindexScript(
        repoPath: repoPath,
        pullFirst: pullFirst,
        forceReindex: forceReindex,
        allowWorkspace: allowWorkspace,
        excludeSubrepos: excludeSubrepos
      )

      do {
        let commandResult = try await coordinator.sendDirectCommandAndWait(
          "/bin/zsh",
          args: ["-lc", script],
          workingDirectory: nil,
          to: worker.id,
          timeout: .seconds(420)
        )

        workerResults.append([
          "workerId": worker.id,
          "workerName": worker.displayName,
          "status": commandResult.exitCode == 0 ? "success" : "failed",
          "exitCode": commandResult.exitCode,
          "output": String(commandResult.output.suffix(1200)),
          "error": commandResult.error as Any,
        ])
      } catch {
        workerResults.append([
          "workerId": worker.id,
          "workerName": worker.displayName,
          "status": "failed",
          "error": error.localizedDescription,
        ])
      }
    }

    let succeeded = workerResults.filter { ($0["status"] as? String) == "success" }.count
    let failed = workerResults.count - succeeded

    return (200, makeResult(id: id, result: [
      "success": failed == 0,
      "message": failed == 0
        ? "Remote reindex completed on all targeted workers"
        : "\(succeeded) workers succeeded, \(failed) failed",
      "repoPath": repoPath,
      "pullFirst": pullFirst,
      "forceReindex": forceReindex,
      "allowWorkspace": allowWorkspace,
      "excludeSubrepos": excludeSubrepos,
      "workersSucceeded": succeeded,
      "workersFailed": failed,
      "workers": workerResults
    ]))
  }

  private func buildRemoteReindexScript(
    repoPath: String,
    pullFirst: Bool,
    forceReindex: Bool,
    allowWorkspace: Bool,
    excludeSubrepos: Bool
  ) -> String {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": 1,
      "method": "tools/call",
      "params": [
        "name": "rag.index",
        "arguments": [
          "repoPath": repoPath,
          "forceReindex": forceReindex,
          "allowWorkspace": allowWorkspace,
          "excludeSubrepos": excludeSubrepos
        ]
      ]
    ]

    let payloadData = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"

    var lines: [String] = [
      "set -e",
      "REPO_PATH=\(shellSingleQuote(repoPath))",
    ]

    if pullFirst {
      lines.append("echo '[swarm.reindex] Pulling latest in '$REPO_PATH")
      lines.append("git -C \"$REPO_PATH\" pull --ff-only || git -C \"$REPO_PATH\" pull")
    }

    lines.append("echo '[swarm.reindex] Calling rag.index for '$REPO_PATH")
    lines.append("PAYLOAD=\(shellSingleQuote(payloadJSON))")
    lines.append("RESPONSE=$(curl -sS -X POST http://127.0.0.1:8765/rpc -H 'Content-Type: application/json' -d \"$PAYLOAD\")")
    lines.append("echo \"$RESPONSE\"")
    lines.append("if echo \"$RESPONSE\" | grep -q '\"error\"'; then")
    lines.append("  echo '[swarm.reindex] rag.index returned error' >&2")
    lines.append("  exit 2")
    lines.append("fi")

    return lines.joined(separator: "\n")
  }

  private func shellSingleQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
    let awaitResult = (arguments["awaitResult"] as? Bool) ?? true
    
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
      if !awaitResult {
        try await coordinator.sendDirectCommand(command, args: args, workingDirectory: workingDirectory, to: targetWorker.id)
        return (200, makeResult(id: id, result: [
          "success": true,
          "dispatched": true,
          "awaitedResult": false,
          "workerId": targetWorker.id,
          "workerName": targetWorker.displayName,
          "command": command,
          "args": args
        ]))
      }

      let result = try await coordinator.sendDirectCommandAndWait(command, args: args, workingDirectory: workingDirectory, to: targetWorker.id)
      return (200, makeResult(id: id, result: [
        "success": result.exitCode == 0,
        "dispatched": true,
        "awaitedResult": true,
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
        "createdAt": Formatter.iso8601.string(from: reservation.createdAt)
      ]
    }
    
    let completed = coordinator.branchQueue.getAllCompleted().map { branch -> [String: Any] in
      [
        "taskId": branch.taskId.uuidString,
        "branchName": branch.branchName,
        "repoPath": branch.repoPath,
        "workerId": branch.workerId,
        "completedAt": Formatter.iso8601.string(from: branch.completedAt),
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
        "createdAt": Formatter.iso8601.string(from: pr.createdAt),
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
