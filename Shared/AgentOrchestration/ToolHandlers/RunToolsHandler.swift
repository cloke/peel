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
}

@MainActor
final class RunToolsHandler {
  weak var delegate: RunToolsHandlerDelegate?

  let supportedTools: Set<String> = [
    "runs.list",
    "runs.status",
    "runs.pause",
    "runs.resume",
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
    ]
  }
}
