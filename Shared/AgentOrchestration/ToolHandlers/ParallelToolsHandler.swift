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
      "parallel.cancel"
    ]
  }

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
    default:
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown parallel tool: \(name)"
      ))
    }
  }

  // MARK: - Private Handlers

  private func handleCreate(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing name"
      ))
    }

    guard let projectPath = (arguments["projectPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !projectPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing projectPath"
      ))
    }

    guard let tasksArray = arguments["tasks"] as? [[String: Any]], !tasksArray.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or empty tasks array"
      ))
    }

    let baseBranch = (arguments["baseBranch"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
    let targetBranch = arguments["targetBranch"] as? String
    let requireReviewGate = arguments["requireReviewGate"] as? Bool ?? true
    let autoMergeOnApproval = arguments["autoMergeOnApproval"] as? Bool ?? false
    let templateName = (arguments["templateName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowPlannerModelSelection = arguments["allowPlannerModelSelection"] as? Bool
    let allowImplementerModelOverride = arguments["allowImplementerModelOverride"] as? Bool
    let allowPlannerImplementerScaling = arguments["allowPlannerImplementerScaling"] as? Bool
    let maxImplementers = arguments["maxImplementers"] as? Int
    let maxPremiumCost = arguments["maxPremiumCost"] as? Double

    // Parse tasks
    let tasks: [WorktreeTask] = tasksArray.compactMap { taskDict in
      guard let title = (taskDict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty,
            let prompt = (taskDict["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty else {
        return nil
      }
      let description = taskDict["description"] as? String ?? ""
      let focusPaths = taskDict["focusPaths"] as? [String] ?? []
      return WorktreeTask(
        title: title,
        description: description,
        prompt: prompt,
        focusPaths: focusPaths
      )
    }

    guard tasks.count == tasksArray.count else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Invalid task format - each task needs title and prompt"
      ))
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

    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: encodeParallelRun(run)))
  }

  private func handleStart(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    guard let run = runner.getRun(id: runId) else {
      await delegate?.parallelTelemetryProvider.warning("Parallel run not found", metadata: [
        "runId": runIdString,
        "knownRunCount": "\(runner.runs.count)"
      ])
      let knownRuns = runner.runs.map { encodeParallelRun($0) }
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found",
        data: [
          "runId": runIdString,
          "knownRunCount": runner.runs.count,
          "knownRuns": knownRuns,
          "hint": "Run not found. The app may have restarted or the run was removed. Use parallel.list to refresh."
        ]
      ))
    }

    await delegate?.parallelTelemetryProvider.info("Starting parallel run", metadata: ["runId": runId.uuidString])

    // Start the run in a task so we don't block
    Task {
      do {
        try await runner.startRun(run)
        await delegate?.parallelTelemetryProvider.info("Parallel run completed", metadata: [
          "runId": runId.uuidString,
          "status": run.status.displayName
        ])
      } catch {
        await delegate?.parallelTelemetryProvider.error(error, context: "Parallel run failed", metadata: [:])
      }
    }

    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
      "runId": runId.uuidString,
      "status": "starting"
    ]))
  }

  private func handleStatus(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    // First try in-memory
    if let run = runner.getRun(id: runId) {
      return (200, JSONRPCResponseBuilder.makeResult(id: id, result: encodeParallelRun(run, includeDetails: true)))
    }

    // Fall back to SwiftData snapshot
    if let snapshot = delegate?.parallelDataService?.getLatestParallelRunSnapshot(runId: runIdString) {
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
      return (200, JSONRPCResponseBuilder.makeResult(id: id, result: snapshotPayload))
    }

    return (404, JSONRPCResponseBuilder.makeError(
      id: id,
      code: JSONRPCResponseBuilder.ErrorCode.notFound,
      message: "Run not found"
    ))
  }

  private func handleList(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
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

    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
      "runs": runPayloads,
      "snapshots": snapshots,
      "totalCount": runPayloads.count
    ]))
  }

  private func handleApprove(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    guard let run = runner.getRun(id: runId) else {
      let snapshot = delegate?.parallelDataService?.getLatestParallelRunSnapshot(runId: runIdString)
      let snapshotPayload: [String: Any]? = snapshot.map { record in
        [
          "runId": record.runId,
          "name": record.name,
          "projectPath": record.projectPath,
          "status": record.status,
          "source": "snapshot"
        ]
      }
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found",
        data: [
          "runId": runIdString,
          "snapshot": snapshotPayload as Any,
          "hint": "Run not found. The app may have restarted or the run was removed. Use parallel.list to refresh."
        ]
      ))
    }

    let approveAll = arguments["approveAll"] as? Bool ?? false

    if approveAll {
      runner.approveAllPending(in: run)
      return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
        "runId": runId.uuidString,
        "approved": "all",
        "pendingReviewCount": run.pendingReviewCount
      ]))
    }

    guard let executionIdString = arguments["executionId"] as? String,
          let executionId = UUID(uuidString: executionIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing executionId (or set approveAll=true)"
      ))
    }

    guard let execution = run.executions.first(where: { $0.id == executionId }) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Execution not found"
      ))
    }

    runner.approveExecution(execution, in: run)
    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "status": execution.status.displayName
    ]))
  }

  private func handleReject(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found"
      ))
    }

    guard let executionIdString = arguments["executionId"] as? String,
          let executionId = UUID(uuidString: executionIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing executionId"
      ))
    }

    guard let execution = run.executions.first(where: { $0.id == executionId }) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Execution not found"
      ))
    }

    let reason = arguments["reason"] as? String ?? "Rejected via MCP"
    runner.rejectExecution(execution, in: run, reason: reason)

    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "status": execution.status.displayName
    ]))
  }

  private func handleReviewed(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found"
      ))
    }

    let reviewAll = arguments["reviewAll"] as? Bool ?? false

    if reviewAll {
      runner.markAllReviewed(in: run)
      return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
        "runId": runId.uuidString,
        "reviewed": "all",
        "pendingReviewCount": run.pendingReviewCount
      ]))
    }

    guard let executionIdString = arguments["executionId"] as? String,
          let executionId = UUID(uuidString: executionIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing executionId (or set reviewAll=true)"
      ))
    }

    guard let execution = run.executions.first(where: { $0.id == executionId }) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Execution not found"
      ))
    }

    runner.markReviewed(execution, in: run)
    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId.uuidString,
      "status": execution.status.displayName
    ]))
  }

  private func handleMerge(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found"
      ))
    }

    let mergeAll = arguments["mergeAll"] as? Bool ?? false

    do {
      if mergeAll {
        try await runner.mergeAllApproved(in: run)
        return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
          "runId": runId.uuidString,
          "merged": "all",
          "mergedCount": run.mergedCount
        ]))
      }

      guard let executionIdString = arguments["executionId"] as? String,
            let executionId = UUID(uuidString: executionIdString) else {
        return (400, JSONRPCResponseBuilder.makeError(
          id: id,
          code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
          message: "Missing executionId (or set mergeAll=true)"
        ))
      }

      guard let execution = run.executions.first(where: { $0.id == executionId }) else {
        return (404, JSONRPCResponseBuilder.makeError(
          id: id,
          code: JSONRPCResponseBuilder.ErrorCode.notFound,
          message: "Execution not found"
        ))
      }

      try await runner.mergeExecution(execution, in: run)
      return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
        "runId": runId.uuidString,
        "executionId": executionId.uuidString,
        "status": execution.status.displayName
      ]))
    } catch {
      await delegate?.parallelTelemetryProvider.warning("Parallel merge failed", metadata: ["error": error.localizedDescription])
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: error.localizedDescription
      ))
    }
  }

  private func handlePause(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found"
      ))
    }

    await runner.pauseRun(run)
    await delegate?.parallelTelemetryProvider.info("Parallel run paused", metadata: ["runId": runId.uuidString])
    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: ["runId": runId.uuidString, "paused": true]))
  }

  private func handleResume(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found"
      ))
    }

    await runner.resumeRun(run)
    await delegate?.parallelTelemetryProvider.info("Parallel run resumed", metadata: ["runId": runId.uuidString])
    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: ["runId": runId.uuidString, "paused": false]))
  }

  private func handleInstruct(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    guard let guidance = arguments["guidance"] as? String else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing guidance"
      ))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found"
      ))
    }

    var executionId: UUID?
    if let executionIdString = arguments["executionId"] as? String {
      executionId = UUID(uuidString: executionIdString)
    }

    runner.addGuidance(guidance, to: run, executionId: executionId)
    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
      "runId": runId.uuidString,
      "executionId": executionId?.uuidString as Any,
      "guidanceCount": run.operatorGuidance.count
    ]))
  }

  private func handleCancel(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let runner = delegate?.parallelWorktreeRunner else {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Parallel worktree runner not initialized"
      ))
    }

    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Missing or invalid runId"
      ))
    }

    guard let run = runner.getRun(id: runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.notFound,
        message: "Run not found"
      ))
    }

    await runner.cancelRun(run)

    await delegate?.parallelTelemetryProvider.info("Parallel run cancelled", metadata: ["runId": runId.uuidString])

    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: [
      "runId": runId.uuidString,
      "status": "cancelled"
    ]))
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
      "pendingReviewCount": run.pendingReviewCount,
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
      "mergeConflictCount": execution.mergeConflicts.count,
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
    if !execution.mergeConflicts.isEmpty {
      result["mergeConflicts"] = execution.mergeConflicts
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
