import Foundation
import MCPCore

/// Protocol for parallel tools dependencies
@MainActor
protocol ParallelToolsHandlerDelegate: AnyObject {
  var parallelWorktreeRunner: ParallelWorktreeRunner? { get }
  var parallelDataService: DataService? { get }
  var parallelTelemetryProvider: MCPTelemetryProviding { get }
}

/// Handles parallel.* MCP tools for parallel worktree execution.
/// Note: Does not conform to MCPToolHandler because it has different
/// delegate requirements (ParallelToolsHandlerDelegate vs MCPToolHandlerDelegate).
@MainActor
final class ParallelToolsHandler {
  weak var delegate: ParallelToolsHandlerDelegate?

  var supportedTools: Set<String> {
    [
      "parallel.create",
      "parallel.start",
      "parallel.status",
      "parallel.list",
      "parallel.approve",
      "parallel.reject",
      "parallel.reviewed",
      "parallel.merge",
      "parallel.pause",
      "parallel.resume",
      "parallel.instruct",
      "parallel.cancel",
      "parallel.diff",
      "parallel.retry",
      "parallel.append"
    ]
  }

  // MARK: - Helper Methods (reduces boilerplate)

  private func toolResult(id: Any?, result: [String: Any]) -> Data {
    JSONRPCResponseBuilder.makeToolResult(id: id, result: result)
  }

  private func rpcError(id: Any?, code: Int, message: String, data: [String: Any]? = nil) -> Data {
    JSONRPCResponseBuilder.makeError(id: id, code: code, message: message, data: data)
  }

  private func runnerNotInitializedError(id: Any?) -> (Int, Data) {
    (500, rpcError(
      id: id,
      code: JSONRPCResponseBuilder.ErrorCode.internalError,
      message: "Parallel worktree runner not initialized"
    ))
  }

  private func missingParamError(id: Any?, param: String) -> (Int, Data) {
    (400, rpcError(
      id: id,
      code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
      message: "Missing \(param)"
    ))
  }

  private func invalidParamError(id: Any?, param: String, reason: String? = nil) -> (Int, Data) {
    (400, rpcError(
      id: id,
      code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
      message: reason ?? "Invalid \(param)"
    ))
  }

  private func runNotFoundError(id: Any?, runId: String, runner: ParallelWorktreeRunner) -> (Int, Data) {
    let knownRuns = runner.runs.map { encodeParallelRun($0) }
    return (404, rpcError(
      id: id,
      code: JSONRPCResponseBuilder.ErrorCode.notFound,
      message: "Run not found",
      data: [
        "runId": runId,
        "knownRunCount": runner.runs.count,
        "knownRuns": knownRuns,
        "hint": "Run not found. The app may have restarted or the run was removed. Use parallel.list to refresh."
      ]
    ))
  }

  // Helper type for Result-based validation with (Int, Data) error responses
  private enum ValidationResult<T> {
    case success(T)
    case failure(Int, Data)
    
    var value: T? {
      if case .success(let v) = self { return v }
      return nil
    }
    
    var errorResponse: (Int, Data)? {
      if case .failure(let code, let data) = self { return (code, data) }
      return nil
    }
  }

  private func getRunner(id: Any?) -> ValidationResult<ParallelWorktreeRunner> {
    guard let runner = delegate?.parallelWorktreeRunner else {
      let error = runnerNotInitializedError(id: id)
      return .failure(error.0, error.1)
    }
    return .success(runner)
  }

  private func getString(_ key: String, from arguments: [String: Any], id: Any?) -> ValidationResult<String> {
    guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
      let error = missingParamError(id: id, param: key)
      return .failure(error.0, error.1)
    }
    return .success(value)
  }

  private func getUUID(_ key: String, from arguments: [String: Any], id: Any?) -> ValidationResult<UUID> {
    guard let stringValue = arguments[key] as? String,
          let uuid = UUID(uuidString: stringValue) else {
      let error = missingParamError(id: id, param: key)
      return .failure(error.0, error.1)
    }
    return .success(uuid)
  }

  private func getRun(
    runId: UUID,
    from runner: ParallelWorktreeRunner,
    id: Any?
  ) -> ValidationResult<ParallelWorktreeRun> {
    guard let run = runner.getRun(id: runId) else {
      let error = runNotFoundError(id: id, runId: runId.uuidString, runner: runner)
      return .failure(error.0, error.1)
    }
    return .success(run)
  }

  private func getExecution(
    executionId: UUID,
    from run: ParallelWorktreeRun,
    id: Any?
  ) -> ValidationResult<ParallelWorktreeExecution> {
    guard let execution = run.executions.first(where: { $0.id == executionId }) else {
      let error = (404, rpcError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Execution not found"
      ))
      return .failure(error.0, error.1)
    }
    return .success(execution)
  }

  private func optionalString(_ key: String, from arguments: [String: Any], default defaultValue: String? = nil) -> String? {
    guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
      return defaultValue
    }
    return value
  }

  private func optionalBool(_ key: String, from arguments: [String: Any], default defaultValue: Bool) -> Bool {
    (arguments[key] as? Bool) ?? defaultValue
  }

  private func optionalUUID(_ key: String, from arguments: [String: Any]) -> UUID? {
    guard let stringValue = arguments[key] as? String else { return nil }
    return UUID(uuidString: stringValue)
  }

  // MARK: - Main Handler

  func handle(
    name: String,
    id: Any?,
    arguments: [String: Any]
  ) async -> (Int, Data) {
    switch name {
    case "parallel.create":
      return await handleCreate(id: id, arguments: arguments)
    case "parallel.start":
      return await handleStart(id: id, arguments: arguments)
    case "parallel.status":
      return handleStatus(id: id, arguments: arguments)
    case "parallel.list":
      return handleList(id: id, arguments: arguments)
    case "parallel.approve":
      return handleApprove(id: id, arguments: arguments)
    case "parallel.reject":
      return handleReject(id: id, arguments: arguments)
    case "parallel.reviewed":
      return handleReviewed(id: id, arguments: arguments)
    case "parallel.merge":
      return await handleMerge(id: id, arguments: arguments)
    case "parallel.pause":
      return await handlePause(id: id, arguments: arguments)
    case "parallel.resume":
      return await handleResume(id: id, arguments: arguments)
    case "parallel.instruct":
      return handleInstruct(id: id, arguments: arguments)
    case "parallel.cancel":
      return await handleCancel(id: id, arguments: arguments)
    case "parallel.diff":
      return await handleDiff(id: id, arguments: arguments)
    case "parallel.retry":
      return await handleRetry(id: id, arguments: arguments)
    case "parallel.append":
      return await handleAppend(id: id, arguments: arguments)
    default:
      return (400, rpcError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown parallel tool: \(name)"
      ))
    }
  }

  // MARK: - Private Handlers

  private func handleCreate(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let name) = getString("name", from: arguments, id: id) else {
      return missingParamError(id: id, param: "name")
    }

    guard case .success(let projectPath) = getString("projectPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "projectPath")
    }

    guard let tasksArray = arguments["tasks"] as? [[String: Any]], !tasksArray.isEmpty else {
      return missingParamError(id: id, param: "tasks")
    }

    let baseBranch = optionalString("baseBranch", from: arguments, default: "HEAD") ?? "HEAD"
    let targetBranch = arguments["targetBranch"] as? String
    let requireReviewGate = optionalBool("requireReviewGate", from: arguments, default: true)
    let autoMergeOnApproval = optionalBool("autoMergeOnApproval", from: arguments, default: false)
    let templateName = optionalString("templateName", from: arguments)
    let allowPlannerModelSelection = arguments["allowPlannerModelSelection"] as? Bool
    let allowImplementerModelOverride = arguments["allowImplementerModelOverride"] as? Bool
    let allowPlannerImplementerScaling = arguments["allowPlannerImplementerScaling"] as? Bool
    let maxImplementers = arguments["maxImplementers"] as? Int
    let maxPremiumCost = arguments["maxPremiumCost"] as? Double

    // Parse tasks — first pass creates stable IDs; second pass resolves dependsOn indices
    var tasks: [WorktreeTask] = tasksArray.compactMap { taskDict in
      guard let title = (taskDict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty,
            let prompt = (taskDict["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty else {
        return nil
      }
      let description = taskDict["description"] as? String ?? ""
      let focusPaths = taskDict["focusPaths"] as? [String] ?? []
      return WorktreeTask(title: title, description: description, prompt: prompt, focusPaths: focusPaths)
    }

    guard tasks.count == tasksArray.count else {
      return invalidParamError(id: id, param: "tasks", reason: "Invalid task format - each task needs title and prompt")
    }

    // Resolve dependsOn indices → stable task UUIDs
    for (idx, taskDict) in tasksArray.enumerated() {
      if let depIndices = taskDict["dependsOn"] as? [Int] {
        tasks[idx].dependsOn = depIndices.compactMap { depIdx -> UUID? in
          guard depIdx >= 0, depIdx < tasks.count, depIdx != idx else { return nil }
          return tasks[depIdx].id
        }
      }
    }
    // Detect circular dependencies (DFS)
    let taskIds = Set(tasks.map { $0.id })
    var visited = Set<UUID>(); var stack = Set<UUID>()
    func hasCycle(_ id: UUID) -> Bool {
      guard taskIds.contains(id) else { return false }
      if stack.contains(id) { return true }
      if visited.contains(id) { return false }
      stack.insert(id)
      if let t = tasks.first(where: { $0.id == id }) {
        for dep in t.dependsOn where hasCycle(dep) { return true }
      }
      stack.remove(id); visited.insert(id); return false
    }
    if tasks.contains(where: { hasCycle($0.id) }) {
      return invalidParamError(id: id, param: "tasks", reason: "Circular dependency detected in dependsOn")
    }

    let hasRunOptions = allowPlannerModelSelection != nil
      || allowImplementerModelOverride != nil
      || allowPlannerImplementerScaling != nil
      || maxImplementers != nil
      || maxPremiumCost != nil
    let runOptions = hasRunOptions
      ? AgentChainRunner.ChainRunOptions(
        allowPlannerModelSelection: allowPlannerModelSelection ?? false,
        allowImplementerModelOverride: allowImplementerModelOverride ?? false,
        allowPlannerImplementerScaling: allowPlannerImplementerScaling ?? false,
        maxImplementers: maxImplementers,
        maxPremiumCost: maxPremiumCost
      )
      : nil

    let run = runner.createRun(
      name: name,
      projectPath: projectPath,
      tasks: tasks,
      baseBranch: baseBranch,
      targetBranch: targetBranch,
      requireReviewGate: requireReviewGate,
      autoMergeOnApproval: autoMergeOnApproval,
      templateName: templateName,
      runOptions: runOptions
    )

    await delegate?.parallelTelemetryProvider.info("Parallel run created", metadata: [
      "runId": run.id.uuidString,
      "name": name,
      "taskCount": "\(tasks.count)"
    ])

    return (200, toolResult(id: id, result: encodeParallelRun(run)))
  }

  private func handleStart(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    guard let run = runner.getRun(id: runId) else {
      await delegate?.parallelTelemetryProvider.warning("Parallel run not found", metadata: [
        "runId": runId.uuidString,
        "knownRunCount": "\(runner.runs.count)"
      ])
      return runNotFoundError(id: id, runId: runId.uuidString, runner: runner)
    }

    await delegate?.parallelTelemetryProvider.info("Starting parallel run", metadata: ["runId": runId.uuidString])

    // Start the run in a task so we don't block
    _ = AsyncHandler.launch(
      operation: {
        try await runner.startRun(run)
        await self.delegate?.parallelTelemetryProvider.info("Parallel run completed", metadata: [
          "runId": runId.uuidString,
          "status": run.status.displayName
        ])
      },
      onError: { error in
        await self.delegate?.parallelTelemetryProvider.error(error, context: "Parallel run failed", metadata: [:])
      }
    )

    return (200, toolResult(id: id, result: [
      "runId": runId.uuidString,
      "status": "starting"
    ]))
  }

  private func handleStatus(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    // First try in-memory
    if let run = runner.getRun(id: runId) {
      return (200, toolResult(id: id, result: encodeParallelRun(run, includeDetails: true)))
    }

    // Fall back to SwiftData snapshot
    if let snapshot = delegate?.parallelDataService?.getLatestParallelRunSnapshot(runId: runId.uuidString) {
      let snapshotPayload: [String: Any] = [
        "runId": snapshot.runId,
        "name": snapshot.name,
        "projectPath": snapshot.projectPath,
        "baseBranch": snapshot.baseBranch,
        "targetBranch": snapshot.targetBranch as Any,
        "templateName": snapshot.templateName as Any,
        "status": snapshot.status,
        "progress": snapshot.progress,
        "executionCount": snapshot.executionCount,
        "pendingReviewCount": snapshot.pendingReviewCount,
        "readyToMergeCount": snapshot.readyToMergeCount,
        "mergedCount": snapshot.mergedCount,
        "rejectedCount": snapshot.rejectedCount,
        "failedCount": snapshot.failedCount,
        "hungCount": snapshot.hungCount,
        "requireReviewGate": snapshot.requireReviewGate,
        "autoMergeOnApproval": snapshot.autoMergeOnApproval,
        "guidanceCount": snapshot.operatorGuidanceCount,
        "createdAt": snapshot.createdAt.iso8601,
        "updatedAt": snapshot.updatedAt.iso8601,
        "lastUpdatedAt": snapshot.lastUpdatedAt?.iso8601 as Any,
        "executions": snapshot.executionsJSON,
        "source": "snapshot"
      ]
      return (200, toolResult(id: id, result: snapshotPayload))
    }

    return (404, rpcError(
      id: id,
      code: JSONRPCResponseBuilder.ErrorCode.notFound,
      message: "Run not found"
    ))
  }

  private func handleList(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, rpcError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    let includeCompleted = arguments["includeCompleted"] as? Bool ?? true
    let includeDetails = arguments["includeDetails"] as? Bool ?? false

    var runs = runner.runs
    if !includeCompleted {
      runs = runs.filter { run in
        switch run.status {
        case .completed, .cancelled, .failed:
          return false
        default:
          return true
        }
      }
    }

    let runPayloads = runs.map { encodeParallelRun($0, includeDetails: includeDetails) }

    // Also include recent snapshots if no in-memory runs
    var snapshots: [[String: Any]] = []
    if runPayloads.isEmpty, let dataService = delegate?.parallelDataService {
      let recentSnapshots = dataService.getRecentParallelRunSnapshots(limit: 10)
      snapshots = recentSnapshots.map { record in
        [
          "runId": record.runId,
          "name": record.name,
          "projectPath": record.projectPath,
          "baseBranch": record.baseBranch,
          "targetBranch": record.targetBranch as Any,
          "templateName": record.templateName as Any,
          "status": record.status,
          "progress": record.progress,
          "executionCount": record.executionCount,
          "pendingReviewCount": record.pendingReviewCount,
          "readyToMergeCount": record.readyToMergeCount,
          "mergedCount": record.mergedCount,
          "rejectedCount": record.rejectedCount,
          "failedCount": record.failedCount,
          "hungCount": record.hungCount,
          "requireReviewGate": record.requireReviewGate,
          "autoMergeOnApproval": record.autoMergeOnApproval,
          "guidanceCount": record.operatorGuidanceCount,
          "createdAt": record.createdAt.iso8601,
          "updatedAt": record.updatedAt.iso8601,
          "lastUpdatedAt": record.lastUpdatedAt?.iso8601 as Any,
          "source": "snapshot"
        ]
      }
    }

    return (200, toolResult(id: id, result: [
      "runs": runPayloads,
      "snapshots": snapshots,
      "totalCount": runPayloads.count
    ]))
  }

  private func handleApprove(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else {
      let snapshot = delegate?.parallelDataService?.getLatestParallelRunSnapshot(runId: runId.uuidString)
      let snapshotPayload: [String: Any]? = snapshot.map { record in
        [
          "runId": record.runId,
          "name": record.name,
          "projectPath": record.projectPath,
          "status": record.status,
          "source": "snapshot"
        ]
      }
      return (404, rpcError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found",
        data: [
          "runId": runId.uuidString,
          "snapshot": snapshotPayload as Any,
          "hint": "Run not found. The app may have restarted or the run was removed. Use parallel.list to refresh."
        ]
      ))
    }

    let approveAll = optionalBool("approveAll", from: arguments, default: false)

    if approveAll {
      runner.approveAllPending(in: run)
      return (200, toolResult(id: id, result: [
        "runId": runId.uuidString,
        "approved": "all",
        "pendingReviewCount": run.pendingReviewCount
      ]))
    }

    guard case .success(let executionId) = getUUID("executionId", from: arguments, id: id) else {
      return invalidParamError(id: id, param: "executionId", reason: "Missing executionId (or set approveAll=true)")
    }

    guard case .success(let execution) = getExecution(executionId: executionId, from: run, id: id) else {
      return (404, rpcError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Execution not found"
      ))
    }

    runner.approveExecution(execution, in: run)
    return (200, toolResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "status": execution.status.displayName
    ]))
  }

  private func handleReject(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else {
      return runNotFoundError(id: id, runId: runId.uuidString, runner: runner)
    }

    guard case .success(let executionId) = getUUID("executionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "executionId")
    }

    guard case .success(let execution) = getExecution(executionId: executionId, from: run, id: id) else {
      return (404, rpcError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Execution not found"
      ))
    }

    let reason = optionalString("reason", from: arguments, default: "Rejected via MCP") ?? "Rejected via MCP"
    runner.rejectExecution(execution, in: run, reason: reason)

    return (200, toolResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "status": execution.status.displayName
    ]))
  }

  private func handleReviewed(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else {
      return runNotFoundError(id: id, runId: runId.uuidString, runner: runner)
    }

    let reviewAll = optionalBool("reviewAll", from: arguments, default: false)

    if reviewAll {
      runner.markAllReviewed(in: run)
      return (200, toolResult(id: id, result: [
        "runId": runId.uuidString,
        "reviewed": "all",
        "pendingReviewCount": run.pendingReviewCount
      ]))
    }

    guard case .success(let executionId) = getUUID("executionId", from: arguments, id: id) else {
      return invalidParamError(id: id, param: "executionId", reason: "Missing executionId (or set reviewAll=true)")
    }

    guard case .success(let execution) = getExecution(executionId: executionId, from: run, id: id) else {
      return (404, rpcError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Execution not found"
      ))
    }

    runner.markReviewed(execution, in: run)
    return (200, toolResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "status": execution.status.displayName
    ]))
  }

  private func handleMerge(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else {
      return runNotFoundError(id: id, runId: runId.uuidString, runner: runner)
    }

    let mergeAll = optionalBool("mergeAll", from: arguments, default: false)

    do {
      if mergeAll {
        try await runner.mergeAllApproved(in: run)
        return (200, toolResult(id: id, result: [
          "runId": runId.uuidString,
          "merged": "all",
          "mergedCount": run.mergedCount
        ]))
      }

      guard case .success(let executionId) = getUUID("executionId", from: arguments, id: id) else {
        return invalidParamError(id: id, param: "executionId", reason: "Missing executionId (or set mergeAll=true)")
      }

      guard case .success(let execution) = getExecution(executionId: executionId, from: run, id: id) else {
        return (404, rpcError(
          id: id,
          code: JSONRPCResponseBuilder.ErrorCode.notFound,
          message: "Execution not found"
        ))
      }

      try await runner.mergeExecution(execution, in: run)
      return (200, toolResult(id: id, result: [
        "runId": runId.uuidString,
        "executionId": executionId.uuidString,
        "status": execution.status.displayName
      ]))
    } catch {
      await delegate?.parallelTelemetryProvider.warning("Parallel merge failed", metadata: ["error": error.localizedDescription])
      return (500, rpcError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: error.localizedDescription
      ))
    }
  }

  private func handlePause(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else {
      return runNotFoundError(id: id, runId: runId.uuidString, runner: runner)
    }

    await runner.pauseRun(run)
    await delegate?.parallelTelemetryProvider.info("Parallel run paused", metadata: ["runId": runId.uuidString])
    return (200, toolResult(id: id, result: ["runId": runId.uuidString, "paused": true]))
  }

  private func handleResume(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else {
      return runNotFoundError(id: id, runId: runId.uuidString, runner: runner)
    }

    await runner.resumeRun(run)
    await delegate?.parallelTelemetryProvider.info("Parallel run resumed", metadata: ["runId": runId.uuidString])
    return (200, toolResult(id: id, result: ["runId": runId.uuidString, "paused": false]))
  }

  private func handleInstruct(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    guard case .success(let guidance) = getString("guidance", from: arguments, id: id) else {
      return missingParamError(id: id, param: "guidance")
    }

    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else {
      return runNotFoundError(id: id, runId: runId.uuidString, runner: runner)
    }

    let executionId = optionalUUID("executionId", from: arguments)

    runner.addGuidance(guidance, to: run, executionId: executionId)
    return (200, toolResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId?.uuidString as Any,
      "guidanceCount": run.operatorGuidance.count
    ]))
  }

  private func handleCancel(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else {
      return runnerNotInitializedError(id: id)
    }

    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "runId")
    }

    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else {
      return runNotFoundError(id: id, runId: runId.uuidString, runner: runner)
    }

    await runner.cancelRun(run)

    await delegate?.parallelTelemetryProvider.info("Parallel run cancelled", metadata: ["runId": runId.uuidString])

    return (200, toolResult(id: id, result: [
      "runId": runId.uuidString,
      "status": "cancelled"
    ]))
  }

  // MARK: - New Tool Handlers (#295 – #298)

  private func handleDiff(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else { return runnerNotInitializedError(id: id) }
    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else { return missingParamError(id: id, param: "runId") }
    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else { return runNotFoundError(id: id, runId: runId.uuidString, runner: runner) }
    guard case .success(let executionId) = getUUID("executionId", from: arguments, id: id) else { return missingParamError(id: id, param: "executionId") }
    guard case .success(let execution) = getExecution(executionId: executionId, from: run, id: id) else {
      return (404, rpcError(id: id, code: JSONRPCResponseBuilder.ErrorCode.notFound, message: "Execution not found"))
    }
    let maxLines = arguments["maxLines"] as? Int
    let diff = await runner.diffExecution(execution, in: run, maxLines: maxLines)
    let truncated = maxLines.map { diff.components(separatedBy: "\n").count >= $0 } ?? false
    return (200, toolResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "branchName": execution.branchName as Any,
      "diff": diff,
      "truncated": truncated
    ]))
  }

  private func handleRetry(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else { return runnerNotInitializedError(id: id) }
    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else { return missingParamError(id: id, param: "runId") }
    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else { return runNotFoundError(id: id, runId: runId.uuidString, runner: runner) }
    guard case .success(let executionId) = getUUID("executionId", from: arguments, id: id) else { return missingParamError(id: id, param: "executionId") }
    guard case .success(let execution) = getExecution(executionId: executionId, from: run, id: id) else {
      return (404, rpcError(id: id, code: JSONRPCResponseBuilder.ErrorCode.notFound, message: "Execution not found"))
    }
    let amendedPrompt = optionalString("amendedPrompt", from: arguments)
    let guidance = optionalString("guidance", from: arguments)
    do {
      try await runner.retryExecution(execution, in: run, amendedPrompt: amendedPrompt, guidance: guidance)
      await delegate?.parallelTelemetryProvider.info("Parallel execution retried", metadata: ["runId": runId.uuidString, "executionId": executionId.uuidString])
      return (200, toolResult(id: id, result: [
        "runId": runId.uuidString,
        "executionId": executionId.uuidString,
        "status": execution.status.displayName
      ]))
    } catch {
      return (400, rpcError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: error.localizedDescription))
    }
  }

  private func handleAppend(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let runner) = getRunner(id: id) else { return runnerNotInitializedError(id: id) }
    guard case .success(let runId) = getUUID("runId", from: arguments, id: id) else { return missingParamError(id: id, param: "runId") }
    guard case .success(let run) = getRun(runId: runId, from: runner, id: id) else { return runNotFoundError(id: id, runId: runId.uuidString, runner: runner) }
    guard let tasksArray = arguments["tasks"] as? [[String: Any]], !tasksArray.isEmpty else { return missingParamError(id: id, param: "tasks") }
    let newTasks: [WorktreeTask] = tasksArray.compactMap { taskDict in
      guard let title = (taskDict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
            let prompt = (taskDict["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return nil }
      return WorktreeTask(title: title, description: taskDict["description"] as? String ?? "", prompt: prompt, focusPaths: taskDict["focusPaths"] as? [String] ?? [])
    }
    guard newTasks.count == tasksArray.count else {
      return invalidParamError(id: id, param: "tasks", reason: "Invalid task format — each task needs title and prompt")
    }
    // Resolve dependsOn indices → stable task UUIDs (relative to new batch)
    var resolvedTasks = newTasks
    for (idx, taskDict) in tasksArray.enumerated() {
      if let depIndices = taskDict["dependsOn"] as? [Int] {
        resolvedTasks[idx].dependsOn = depIndices.compactMap { depIdx -> UUID? in
          guard depIdx >= 0, depIdx < resolvedTasks.count, depIdx != idx else { return nil }
          return resolvedTasks[depIdx].id
        }
      }
    }
    // Detect circular dependencies within the new batch (DFS)
    var visited2 = Set<UUID>(); var stack2 = Set<UUID>()
    func hasCycleAppend(_ taskId: UUID) -> Bool {
      if stack2.contains(taskId) { return true }
      if visited2.contains(taskId) { return false }
      stack2.insert(taskId)
      if let t = resolvedTasks.first(where: { $0.id == taskId }) {
        for dep in t.dependsOn where hasCycleAppend(dep) { return true }
      }
      stack2.remove(taskId); visited2.insert(taskId); return false
    }
    if resolvedTasks.contains(where: { hasCycleAppend($0.id) }) {
      return invalidParamError(id: id, param: "tasks", reason: "Circular dependency detected in dependsOn")
    }
    do {
      try runner.appendTasks(resolvedTasks, to: run)
      await delegate?.parallelTelemetryProvider.info("Tasks appended to parallel run", metadata: ["runId": runId.uuidString, "count": "\(newTasks.count)"])
      return (200, toolResult(id: id, result: [
        "runId": runId.uuidString,
        "addedCount": newTasks.count,
        "totalExecutionCount": run.executions.count,
        "status": run.status.displayName
      ]))
    } catch {
      return (400, rpcError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: error.localizedDescription))
    }
  }

  // MARK: - Encoding Helpers

  private func encodeParallelRun(_ run: ParallelWorktreeRun, includeDetails: Bool = false) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    var result: [String: Any] = [
      "id": run.id.uuidString,
      "name": run.name,
      "projectPath": run.projectPath,
      "baseBranch": run.baseBranch,
      "status": run.status.displayName,
      "progress": run.progress,
      "executionCount": run.executions.count,
      "activeCount": run.activeCount,
      "pendingReviewCount": run.pendingReviewCount,
      "reviewedCount": run.reviewedCount,
      "readyToMergeCount": run.readyToMergeCount,
      "mergedCount": run.mergedCount,
      "rejectedCount": run.rejectedCount,
      "failedCount": run.failedCount,
      "hungCount": run.hungExecutionCount,
      "isPaused": run.isPaused,
      "guidanceCount": run.operatorGuidance.count,
      "requireReviewGate": run.requireReviewGate,
      "autoMergeOnApproval": run.autoMergeOnApproval,
      "createdAt": formatter.string(from: run.createdAt)
    ]

    if let targetBranch = run.targetBranch {
      result["targetBranch"] = targetBranch
    }
    if let templateName = run.templateName {
      result["templateName"] = templateName
    }
    if let runOptions = run.runOptions {
      result["allowPlannerModelSelection"] = runOptions.allowPlannerModelSelection
      result["allowImplementerModelOverride"] = runOptions.allowImplementerModelOverride
      result["allowPlannerImplementerScaling"] = runOptions.allowPlannerImplementerScaling
      if let maxImplementers = runOptions.maxImplementers {
        result["maxImplementers"] = maxImplementers
      }
      if let maxPremiumCost = runOptions.maxPremiumCost {
        result["maxPremiumCost"] = maxPremiumCost
      }
    }
    if let startedAt = run.startedAt {
      result["startedAt"] = formatter.string(from: startedAt)
    }
    if let completedAt = run.completedAt {
      result["completedAt"] = formatter.string(from: completedAt)
    }
    if let lastUpdatedAt = run.lastUpdatedAt {
      result["lastUpdatedAt"] = formatter.string(from: lastUpdatedAt)
    }

    if case .failed(let reason) = run.status {
      result["failureReason"] = reason
    }

    if includeDetails {
      result["executions"] = run.executions.map { encodeExecution($0) }
    }

    return result
  }

  private func encodeExecution(_ execution: ParallelWorktreeExecution) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    var result: [String: Any] = [
      "id": execution.id.uuidString,
      "taskTitle": execution.task.title,
      "taskDescription": execution.task.description,
      "status": execution.status.displayName,
      "filesChanged": execution.filesChanged,
      "insertions": execution.insertions,
      "deletions": execution.deletions,
      "ragSnippetCount": execution.ragSnippets.count,
      "mergeConflictCount": execution.conflictFiles.count,
      "guidanceCount": execution.operatorGuidance.count
    ]

    if let worktreePath = execution.worktreePath {
      result["worktreePath"] = worktreePath
    }
    if let branchName = execution.branchName {
      result["branchName"] = branchName
    }
    if let startedAt = execution.startedAt {
      result["startedAt"] = formatter.string(from: startedAt)
    }
    if let completedAt = execution.completedAt {
      result["completedAt"] = formatter.string(from: completedAt)
    }
    if let duration = execution.duration {
      result["durationSeconds"] = duration
    }
    if !execution.conflictFiles.isEmpty {
      result["mergeConflicts"] = execution.conflictFiles.map { $0.filePath }
    }
    if !execution.output.isEmpty {
      result["output"] = execution.output
    }
    if let diffSummary = execution.diffSummary, !diffSummary.isEmpty {
      result["diffSummary"] = diffSummary
    }
    switch execution.status {
    case .failed(let reason):
      result["failureReason"] = reason
    case .rejected(let reason):
      result["rejectionReason"] = reason
    default:
      break
    }

    return result
  }
}

// MARK: - Tool Definitions

extension ParallelToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "parallel.create",
        description: "Create a new parallel worktree run with multiple tasks",
        inputSchema: [
          "type": "object",
          "properties": [
            "name": ["type": "string"],
            "projectPath": ["type": "string"],
            "baseBranch": ["type": "string"],
            "targetBranch": ["type": "string"],
            "requireReviewGate": ["type": "boolean"],
            "autoMergeOnApproval": ["type": "boolean"],
            "templateName": ["type": "string"],
            "allowPlannerModelSelection": ["type": "boolean"],
            "allowImplementerModelOverride": ["type": "boolean"],
            "allowPlannerImplementerScaling": ["type": "boolean"],
            "maxImplementers": ["type": "integer"],
            "maxPremiumCost": ["type": "number"],
            "tasks": [
              "type": "array",
              "items": [
                "type": "object",
                "properties": [
                  "title": ["type": "string"],
                  "description": ["type": "string"],
                  "prompt": ["type": "string"],
                  "focusPaths": [
                    "type": "array",
                    "items": ["type": "string"]
                  ],
                  "dependsOn": [
                    "type": "array",
                    "items": ["type": "integer"],
                    "description": "0-based indices of other tasks in this batch that must be merged before this task starts"
                  ]
                ],
                "required": ["title", "prompt"]
              ]
            ]
          ],
          "required": ["name", "projectPath", "tasks"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.start",
        description: "Start a pending parallel worktree run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.status",
        description: "Get status of a parallel worktree run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "parallel.list",
        description: "List all parallel worktree runs",
        inputSchema: [
          "type": "object",
          "properties": [
            "includeCompleted": ["type": "boolean"]
          ]
        ],
        category: .parallelWorktrees,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "parallel.approve",
        description: "Approve an execution in a parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "approveAll": ["type": "boolean"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.reject",
        description: "Reject an execution in a parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "reason": ["type": "string"]
          ],
          "required": ["runId", "executionId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.reviewed",
        description: "Mark an execution as reviewed without approving",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "reviewAll": ["type": "boolean"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.merge",
        description: "Merge approved executions in a parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "mergeAll": ["type": "boolean"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.pause",
        description: "Pause a parallel run (halts new executions and pauses active chains)",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.resume",
        description: "Resume a paused parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.instruct",
        description: "Inject operator guidance into a parallel run or execution",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "guidance": ["type": "string"]
          ],
          "required": ["runId", "guidance"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.cancel",
        description: "Cancel a parallel worktree run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.diff",
        description: "Return the unified git diff for an execution's branch vs the run's base branch. Use this to review actual code changes before approving or rejecting.",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "maxLines": ["type": "integer", "description": "Truncate diff output at this many lines"]
          ],
          "required": ["runId", "executionId"]
        ],
        category: .parallelWorktrees,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "parallel.retry",
        description: "Re-queue a failed, rejected, reviewed, or cancelled execution, optionally with an amended prompt and/or additional guidance.",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "amendedPrompt": ["type": "string", "description": "Replace the task prompt for this retry"],
            "guidance": ["type": "string", "description": "Additional operator guidance to inject"]
          ],
          "required": ["runId", "executionId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "parallel.append",
        description: "Add new tasks to an in-flight parallel run (running or awaiting review). Throws if the run is completed, cancelled, or failed.",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "tasks": [
              "type": "array",
              "items": [
                "type": "object",
                "properties": [
                  "title": ["type": "string"],
                  "prompt": ["type": "string"],
                  "description": ["type": "string"],
                  "focusPaths": ["type": "array", "items": ["type": "string"]],
                  "dependsOn": [
                    "type": "array",
                    "items": ["type": "integer"],
                    "description": "0-based indices of other tasks in this append batch that must be merged before this task starts"
                  ]
                ],
                "required": ["title", "prompt"]
              ]
            ]
          ],
          "required": ["runId", "tasks"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
    ]
  }
}
