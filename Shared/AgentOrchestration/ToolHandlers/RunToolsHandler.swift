//
//  RunToolsHandler.swift
//  Peel
//
//  Unified MCP tool handler for runs.* tools.
//  Provides a single surface for listing, reviewing, pausing, and resuming runs
//  regardless of kind (PR review, code change, investigation, idea).
//

import Foundation
import MCPCore

@MainActor
protocol RunToolsHandlerDelegate: AnyObject {
  var runManager: RunManager? { get }
  var managerOrchestrator: ManagerOrchestrator? { get }
}

@MainActor
final class RunToolsHandler {
  weak var delegate: RunToolsHandlerDelegate?

  let supportedTools: Set<String> = [
    "runs.list",
    "runs.status",
    "runs.pause",
    "runs.resume",
    "runs.cancel",
    "runs.createManager",
    "runs.spawnChild",
    "runs.children",
    "runs.startManager",
  ]

  func handle(
    name: String,
    id: Any?,
    arguments: [String: Any]
  ) async -> (Int, Data) {
    guard let mgr = delegate?.runManager else {
      return (503, JSONRPCResponseBuilder.makeError(
        id: id, code: -32001, message: "RunManager not available"
      ))
    }

    switch name {
    case "runs.list":
      return handleList(id: id, arguments: arguments, mgr: mgr)
    case "runs.status":
      return handleStatus(id: id, arguments: arguments, mgr: mgr)
    case "runs.pause":
      return handlePause(id: id, arguments: arguments, mgr: mgr)
    case "runs.resume":
      return await handleResume(id: id, arguments: arguments, mgr: mgr)
    case "runs.cancel":
      return await handleCancel(id: id, arguments: arguments, mgr: mgr)
    case "runs.createManager":
      return handleCreateManager(id: id, arguments: arguments, mgr: mgr)
    case "runs.spawnChild":
      return handleSpawnChild(id: id, arguments: arguments, mgr: mgr)
    case "runs.children":
      return handleChildren(id: id, arguments: arguments, mgr: mgr)
    case "runs.startManager":
      return await handleStartManager(id: id, arguments: arguments, mgr: mgr)
    default:
      return (400, JSONRPCResponseBuilder.makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown runs tool: \(name)"
      ))
    }
  }

  // MARK: - runs.list

  private func handleList(id: Any?, arguments: [String: Any], mgr: RunManager) -> (Int, Data) {
    let kindFilter = arguments["kind"] as? String
    let statusFilter = arguments["status"] as? String
    let limit = arguments["limit"] as? Int ?? 50

    var filtered = mgr.runs

    if let kindFilter, let kind = RunKind(rawValue: kindFilter) {
      filtered = filtered.filter { $0.kind == kind }
    }

    if let statusFilter {
      filtered = filtered.filter { $0.status.displayName.lowercased() == statusFilter.lowercased() }
    }

    filtered.sort { a, b in
      func priority(_ run: ParallelWorktreeRun) -> Int {
        switch run.status {
        case .awaitingReview: return 0
        case .running: return 1
        case .pending: return 2
        case .merging: return 3
        default: return 4
        }
      }
      let pa = priority(a), pb = priority(b)
      if pa != pb { return pa < pb }
      return a.createdAt > b.createdAt
    }

    let capped = Array(filtered.prefix(limit))

    let result: [String: Any] = [
      "count": capped.count,
      "totalActive": mgr.runs.count,
      "runs": capped.map { mgr.runSummary($0) },
    ]
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
  }

  // MARK: - runs.status

  private func handleStatus(id: Any?, arguments: [String: Any], mgr: RunManager) -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or invalid runId"
      ))
    }

    let run = mgr.findRun(id: runId) ?? mgr.findRunBySourceChainRunId(runId)
    guard let run else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id, code: -32004, message: "Run not found"
      ))
    }

    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: mgr.runSummary(run)))
  }

  // MARK: - runs.pause

  private func handlePause(id: Any?, arguments: [String: Any], mgr: RunManager) -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or invalid runId"
      ))
    }

    guard let run = mgr.findRun(id: runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id, code: -32004, message: "Run not found"
      ))
    }

    mgr.pauseRun(run)
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
      "runId": run.id.uuidString,
      "status": "paused",
      "message": "Run paused. Use runs.resume to continue.",
    ]))
  }

  // MARK: - runs.resume

  private func handleResume(id: Any?, arguments: [String: Any], mgr: RunManager) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or invalid runId"
      ))
    }

    guard let run = mgr.findRun(id: runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id, code: -32004, message: "Run not found"
      ))
    }

    do {
      try await mgr.resumeRun(run)
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
        "runId": run.id.uuidString,
        "status": run.status.displayName,
        "message": "Run resumed.",
      ]))
    } catch {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id, code: -32000, message: "Failed to resume: \(error.localizedDescription)"
      ))
    }
  }

  // MARK: - runs.cancel

  private func handleCancel(id: Any?, arguments: [String: Any], mgr: RunManager) async -> (Int, Data) {
    guard let runIdString = arguments["runId"] as? String,
          let runId = UUID(uuidString: runIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or invalid runId"
      ))
    }

    guard let run = mgr.findRun(id: runId) ?? mgr.findRunBySourceChainRunId(runId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id, code: -32004, message: "Run not found"
      ))
    }

    await mgr.stopRun(run)
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
      "runId": run.id.uuidString,
      "status": "cancelled",
      "message": "Run cancelled.",
    ]))
  }

  // MARK: - runs.createManager

  private func handleCreateManager(id: Any?, arguments: [String: Any], mgr: RunManager) -> (Int, Data) {
    guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or empty 'prompt'"
      ))
    }
    guard let projectPath = arguments["projectPath"] as? String, !projectPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or empty 'projectPath'"
      ))
    }

    let name = arguments["name"] as? String ?? "Manager: \(String(prompt.prefix(60)))"
    let baseBranch = arguments["baseBranch"] as? String ?? "HEAD"

    let run = mgr.createManagerRun(
      name: name,
      prompt: prompt,
      projectPath: projectPath,
      baseBranch: baseBranch
    )

    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
      "runId": run.id.uuidString,
      "name": run.name,
      "kind": run.kind.rawValue,
      "status": run.status.displayName,
      "message": "Manager run created. Use runs.spawnChild to add child tasks.",
    ]))
  }

  // MARK: - runs.spawnChild

  private func handleSpawnChild(id: Any?, arguments: [String: Any], mgr: RunManager) -> (Int, Data) {
    guard let parentIdString = arguments["parentRunId"] as? String,
          let parentRunId = UUID(uuidString: parentIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or invalid 'parentRunId'"
      ))
    }
    guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or empty 'prompt'"
      ))
    }

    guard let parentRun = mgr.findRun(id: parentRunId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id, code: -32004, message: "Parent run not found"
      ))
    }
    guard parentRun.kind == .managerRun else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Parent run is not a manager run (kind: \(parentRun.kind.rawValue))"
      ))
    }

    let projectPath = arguments["projectPath"] as? String ?? parentRun.projectPath
    let templateName = arguments["templateName"] as? String
    let baseBranch = arguments["baseBranch"] as? String ?? parentRun.baseBranch

    let child = mgr.spawnChildRun(
      parentRunId: parentRunId,
      prompt: prompt,
      projectPath: projectPath,
      templateName: templateName,
      baseBranch: baseBranch
    )

    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
      "childRunId": child.id.uuidString,
      "parentRunId": parentRunId.uuidString,
      "status": child.status.displayName,
      "message": "Child run spawned and started.",
    ]))
  }

  // MARK: - runs.children

  private func handleChildren(id: Any?, arguments: [String: Any], mgr: RunManager) -> (Int, Data) {
    guard let parentIdString = arguments["parentRunId"] as? String,
          let parentRunId = UUID(uuidString: parentIdString) else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or invalid 'parentRunId'"
      ))
    }

    guard let parentRun = mgr.findRun(id: parentRunId) else {
      return (404, JSONRPCResponseBuilder.makeError(
        id: id, code: -32004, message: "Parent run not found"
      ))
    }

    let children = mgr.childRuns(of: parentRunId)
    let stats = mgr.childRunStats(of: parentRunId)

    let result: [String: Any] = [
      "parentRunId": parentRunId.uuidString,
      "parentName": parentRun.name,
      "stats": [
        "total": stats.total,
        "running": stats.running,
        "completed": stats.completed,
        "failed": stats.failed,
        "needsReview": stats.needsReview,
      ],
      "children": children.map { mgr.runSummary($0) },
    ]
    return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: result))
  }

  // MARK: - runs.startManager

  private func handleStartManager(id: Any?, arguments: [String: Any], mgr: RunManager) async -> (Int, Data) {
    guard let orchestrator = delegate?.managerOrchestrator else {
      return (503, JSONRPCResponseBuilder.makeError(
        id: id, code: -32001, message: "ManagerOrchestrator not available"
      ))
    }
    guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or empty 'prompt'"
      ))
    }
    guard let projectPath = arguments["projectPath"] as? String, !projectPath.isEmpty else {
      return (400, JSONRPCResponseBuilder.makeError(
        id: id, code: -32602, message: "Missing or empty 'projectPath'"
      ))
    }

    let baseBranch = arguments["baseBranch"] as? String ?? "HEAD"

    do {
      let run = try await orchestrator.startManagerRun(
        prompt: prompt,
        projectPath: projectPath,
        baseBranch: baseBranch
      )

      let stats = mgr.childRunStats(of: run.id)
      return (200, JSONRPCResponseBuilder.makeToolResult(id: id, result: [
        "runId": run.id.uuidString,
        "name": run.name,
        "status": run.status.displayName,
        "childCount": stats.total,
        "message": "Manager run started with \(stats.total) child tasks. Use runs.children to monitor progress.",
      ]))
    } catch {
      return (500, JSONRPCResponseBuilder.makeError(
        id: id, code: -32000, message: "Manager run failed: \(error.localizedDescription)"
      ))
    }
  }

  // MARK: - Tool Definitions

  var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "runs.list",
        description: "List all runs (code changes, PR reviews, ideas). Returns unified view of all agent work.",
        inputSchema: [
          "type": "object",
          "properties": [
            "kind": [
              "type": "string",
              "enum": RunKind.allCases.map { $0.rawValue },
              "description": "Filter by run kind",
            ],
            "status": [
              "type": "string",
              "description": "Filter by status (e.g. 'Running', 'Awaiting Review', 'Completed')",
            ],
            "limit": [
              "type": "integer",
              "description": "Max runs to return (default 50)",
            ],
          ],
        ],
        category: .agentRuns,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "runs.status",
        description: "Get detailed status of a specific run by ID.",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": [
              "type": "string",
              "description": "Run UUID (either the run ID or the source chain run ID)",
            ],
          ],
          "required": ["runId"],
        ],
        category: .agentRuns,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "runs.pause",
        description: "Pause a run. The run keeps its state but won't make progress until resumed.",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": [
              "type": "string",
              "description": "Run UUID to pause",
            ],
          ],
          "required": ["runId"],
        ],
        category: .agentRuns,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "runs.resume",
        description: "Resume a paused run.",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": [
              "type": "string",
              "description": "Run UUID to resume",
            ],
          ],
          "required": ["runId"],
        ],
        category: .agentRuns,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "runs.cancel",
        description: "Cancel a running or paused run.",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": [
              "type": "string",
              "description": "Run UUID to cancel (either the run ID or the source chain run ID)",
            ],
          ],
          "required": ["runId"],
        ],
        category: .agentRuns,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "runs.createManager",
        description: "Create a manager run that supervises child runs. Use runs.spawnChild to add tasks after creation.",
        inputSchema: [
          "type": "object",
          "properties": [
            "prompt": [
              "type": "string",
              "description": "The high-level goal or idea to decompose into child tasks",
            ],
            "projectPath": [
              "type": "string",
              "description": "Absolute path to the project repository",
            ],
            "name": [
              "type": "string",
              "description": "Optional display name for the manager run",
            ],
            "baseBranch": [
              "type": "string",
              "description": "Base branch for child runs (default: HEAD)",
            ],
          ],
          "required": ["prompt", "projectPath"],
        ],
        category: .agentRuns,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "runs.spawnChild",
        description: "Spawn a child run under a manager run. The child starts immediately in its own worktree.",
        inputSchema: [
          "type": "object",
          "properties": [
            "parentRunId": [
              "type": "string",
              "description": "UUID of the parent manager run",
            ],
            "prompt": [
              "type": "string",
              "description": "Task prompt for the child run",
            ],
            "projectPath": [
              "type": "string",
              "description": "Project path (defaults to parent's project path)",
            ],
            "templateName": [
              "type": "string",
              "description": "Optional chain template name for the child",
            ],
            "baseBranch": [
              "type": "string",
              "description": "Base branch (defaults to parent's base branch)",
            ],
          ],
          "required": ["parentRunId", "prompt"],
        ],
        category: .agentRuns,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "runs.children",
        description: "List child runs of a manager run with aggregated stats (running, completed, failed, needs review).",
        inputSchema: [
          "type": "object",
          "properties": [
            "parentRunId": [
              "type": "string",
              "description": "UUID of the parent manager run",
            ],
          ],
          "required": ["parentRunId"],
        ],
        category: .agentRuns,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "runs.startManager",
        description: "Decompose a high-level goal into sub-tasks via LLM, create a manager run, and spawn child runs automatically. Returns immediately while children execute in parallel.",
        inputSchema: [
          "type": "object",
          "properties": [
            "prompt": [
              "type": "string",
              "description": "The high-level goal to decompose and execute",
            ],
            "projectPath": [
              "type": "string",
              "description": "Absolute path to the project repository",
            ],
            "baseBranch": [
              "type": "string",
              "description": "Base branch for child runs (default: HEAD)",
            ],
          ],
          "required": ["prompt", "projectPath"],
        ],
        category: .agentRuns,
        isMutating: true
      ),
    ]
  }
}
