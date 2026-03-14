//
//  SprintToolsHandler.swift
//  Peel
//
//  Continuous improvement mode ("sprint") — orchestrates the meta-agent loop:
//  Plan → Dispatch → Monitor → Review → Merge → Rebuild → Repeat
//

import Foundation
import MCPCore

/// MCP tools for continuous improvement sprints.
///
/// Tools:
/// - `sprint.start` — Begin a sprint loop on a repository
/// - `sprint.status` — Check sprint progress
/// - `sprint.stop` — Gracefully stop a running sprint
@MainActor
final class SprintToolsHandler: MCPToolHandler {
  let supportedTools: Set<String> = [
    "sprint.start",
    "sprint.status",
    "sprint.stop",
  ]

  weak var delegate: MCPToolHandlerDelegate?

  private var activeSprints: [UUID: Sprint] = [:]

  struct Sprint {
    let id: UUID
    let repoPath: String
    let startedAt: Date
    var status: SprintStatus
    var currentPhase: SprintPhase
    var iteration: Int
    var maxIterations: Int
    var tasksCompleted: Int
    var tasksFailed: Int
    var mergesCompleted: Int
    var stopRequested: Bool
    var templateName: String
    var requireReview: Bool
  }

  enum SprintStatus: String {
    case running
    case paused
    case awaitingReview
    case completed
    case stopped
    case failed
  }

  enum SprintPhase: String {
    case planning
    case dispatching
    case executing
    case reviewing
    case merging
    case rebuilding
    case idle
  }

  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "sprint.start":
      return handleStart(id: id, arguments: arguments)
    case "sprint.status":
      return handleStatus(id: id, arguments: arguments)
    case "sprint.stop":
      return handleStop(id: id, arguments: arguments)
    default:
      return (404, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown sprint tool: \(name)"
      ))
    }
  }

  // MARK: - sprint.start

  private func handleStart(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }

    // Check for existing sprint on this repo
    if let existing = activeSprints.values.first(where: {
      $0.repoPath == repoPath && $0.status == .running
    }) {
      return (409, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidRequest,
        message: "Sprint already running on \(repoPath): \(existing.id.uuidString)"
      ))
    }

    let maxIterations = arguments["maxIterations"] as? Int ?? 3
    let templateName = arguments["templateName"] as? String ?? "Full Implementation"
    let requireReview = arguments["requireReview"] as? Bool ?? true
    let maxTasksPerIteration = arguments["maxTasksPerIteration"] as? Int ?? 5

    let sprintId = UUID()
    let sprint = Sprint(
      id: sprintId,
      repoPath: repoPath,
      startedAt: Date(),
      status: .running,
      currentPhase: .planning,
      iteration: 1,
      maxIterations: maxIterations,
      tasksCompleted: 0,
      tasksFailed: 0,
      mergesCompleted: 0,
      stopRequested: false,
      templateName: templateName,
      requireReview: requireReview
    )
    activeSprints[sprintId] = sprint

    let mission = MissionService.shared.mission(for: repoPath)

    return (200, makeResult(id: id, result: [
      "sprintId": sprintId.uuidString,
      "status": "running",
      "iteration": 1,
      "maxIterations": maxIterations,
      "instructions": """
        Sprint started. Execute this loop for each iteration:
        
        ## Iteration Loop
        
        ### 1. Plan (current phase)
        Call `meta.plan` with repoPath: "\(repoPath)", maxTasks: \(maxTasksPerIteration)
        \(mission != nil ? "Mission loaded — tasks will be checked for alignment." : "⚠️ No mission found at .peel/mission.md")
        
        ### 2. Dispatch
        Take the planned tasks and call `parallel.create` with:
        - name: "Sprint \(sprintId.uuidString.prefix(8)) iteration 1"
        - projectPath: "\(repoPath)"
        - templateName: "\(templateName)"
        - requireReviewGate: \(requireReview)
        - tasks: [from meta.plan output]
        Then call `parallel.start` with the runId.
        
        ### 3. Monitor
        Poll `parallel.status` until all tasks complete.
        Update sprint: `sprint.status` sprintId: "\(sprintId.uuidString)"
        
        ### 4. Review Gate
        \(requireReview ? "Wait for human review approval before merging." : "Auto-merge if build passes.")
        If any tasks need changes, note them for next iteration.
        
        ### 5. Merge
        Approve completed tasks and merge via the review UI.
        
        ### 6. Rebuild (if code changed)
        Call `chain.rebuild` to verify the app still builds.
        
        ### 7. Next Iteration
        If iteration < \(maxIterations) and sprint not stopped, go to step 1.
        Check `sprint.status` for stopRequested flag.
        
        ## Stopping
        Call `sprint.stop` sprintId: "\(sprintId.uuidString)" to stop after current iteration.
        """,
    ]))
  }

  // MARK: - sprint.status

  private func handleStatus(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    if let sprintIdStr = arguments["sprintId"] as? String,
       let sprintId = UUID(uuidString: sprintIdStr) {
      guard var sprint = activeSprints[sprintId] else {
        return (404, makeError(
          id: id,
          code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
          message: "No sprint with ID: \(sprintIdStr)"
        ))
      }

      // Allow updating phase and iteration from caller
      if let phase = arguments["phase"] as? String,
         let newPhase = SprintPhase(rawValue: phase) {
        sprint.currentPhase = newPhase
      }
      if let iteration = arguments["iteration"] as? Int {
        sprint.iteration = iteration
      }
      if let completed = arguments["tasksCompleted"] as? Int {
        sprint.tasksCompleted = completed
      }
      if let failed = arguments["tasksFailed"] as? Int {
        sprint.tasksFailed = failed
      }
      if let merges = arguments["mergesCompleted"] as? Int {
        sprint.mergesCompleted = merges
      }
      activeSprints[sprintId] = sprint

      let shouldContinue = !sprint.stopRequested
        && sprint.iteration <= sprint.maxIterations
        && sprint.status == .running

      return (200, makeResult(id: id, result: [
        "sprintId": sprint.id.uuidString,
        "repoPath": sprint.repoPath,
        "status": sprint.status.rawValue,
        "currentPhase": sprint.currentPhase.rawValue,
        "iteration": sprint.iteration,
        "maxIterations": sprint.maxIterations,
        "tasksCompleted": sprint.tasksCompleted,
        "tasksFailed": sprint.tasksFailed,
        "mergesCompleted": sprint.mergesCompleted,
        "stopRequested": sprint.stopRequested,
        "shouldContinue": shouldContinue,
        "elapsed": Date().timeIntervalSince(sprint.startedAt),
      ]))
    }

    // List all sprints
    let sprints: [[String: Any]] = activeSprints.values.map { sprint in
      [
        "sprintId": sprint.id.uuidString,
        "repoPath": sprint.repoPath,
        "status": sprint.status.rawValue,
        "iteration": sprint.iteration,
        "tasksCompleted": sprint.tasksCompleted,
      ]
    }

    return (200, makeResult(id: id, result: [
      "sprints": sprints,
      "count": sprints.count,
    ]))
  }

  // MARK: - sprint.stop

  private func handleStop(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let sprintIdStr = arguments["sprintId"] as? String,
          let sprintId = UUID(uuidString: sprintIdStr) else {
      return missingParamError(id: id, param: "sprintId")
    }

    guard var sprint = activeSprints[sprintId] else {
      return (404, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "No sprint with ID: \(sprintIdStr)"
      ))
    }

    let immediate = arguments["immediate"] as? Bool ?? false

    if immediate {
      sprint.status = .stopped
      sprint.currentPhase = .idle
    } else {
      sprint.stopRequested = true
    }
    activeSprints[sprintId] = sprint

    return (200, makeResult(id: id, result: [
      "sprintId": sprint.id.uuidString,
      "status": sprint.status.rawValue,
      "stopRequested": sprint.stopRequested,
      "message": immediate
        ? "Sprint stopped immediately."
        : "Sprint will stop after current iteration completes.",
    ]))
  }

  // MARK: - Tool Definitions

  var toolDefinitions: [[String: Any]] {
    [
      [
        "name": "sprint.start",
        "description": "Start a continuous improvement sprint. The sprint loop: Plan → Dispatch → Monitor → Review → Merge → Rebuild → Repeat.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Path to the repository",
            ],
            "maxIterations": [
              "type": "integer",
              "description": "Maximum improvement iterations (default: 3)",
            ],
            "maxTasksPerIteration": [
              "type": "integer",
              "description": "Max tasks per iteration (default: 5)",
            ],
            "templateName": [
              "type": "string",
              "description": "Chain template for tasks (default: 'Full Implementation')",
            ],
            "requireReview": [
              "type": "boolean",
              "description": "Require human review before merging (default: true)",
            ],
          ],
          "required": ["repoPath"],
        ],
      ],
      [
        "name": "sprint.status",
        "description": "Check sprint progress. Can also update phase/iteration counters when called by the orchestrating agent.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "sprintId": [
              "type": "string",
              "description": "Sprint UUID (omit to list all)",
            ],
            "phase": [
              "type": "string",
              "description": "Update current phase (planning/dispatching/executing/reviewing/merging/rebuilding)",
            ],
            "iteration": [
              "type": "integer",
              "description": "Update current iteration number",
            ],
            "tasksCompleted": [
              "type": "integer",
              "description": "Update completed task count",
            ],
            "tasksFailed": [
              "type": "integer",
              "description": "Update failed task count",
            ],
            "mergesCompleted": [
              "type": "integer",
              "description": "Update merge count",
            ],
          ],
        ],
      ],
      [
        "name": "sprint.stop",
        "description": "Stop a running sprint. By default, stops gracefully after current iteration. Use immediate: true to stop now.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "sprintId": [
              "type": "string",
              "description": "Sprint UUID to stop",
            ],
            "immediate": [
              "type": "boolean",
              "description": "Stop immediately (default: false, waits for current iteration)",
            ],
          ],
          "required": ["sprintId"],
        ],
      ],
    ]
  }
}
