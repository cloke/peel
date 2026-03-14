//
//  MetaToolsHandler.swift
//  Peel
//
//  Meta-Agent tools: plan and execute self-improvement loops.
//  The meta-agent reads the mission, analyzes the codebase via RAG,
//  identifies work items, and dispatches sub-chains.
//

import Foundation
import MCPCore

/// Handles meta-agent MCP tools for self-directed development.
///
/// Tools:
/// - `meta.plan` — Analyze the project and produce a prioritized task list
/// - `meta.execute` — Run the full meta-agent loop (plan → dispatch → monitor)
/// - `meta.status` — Check status of a running meta-agent loop
@MainActor
final class MetaToolsHandler: MCPToolHandler {
  let supportedTools: Set<String> = [
    "meta.plan",
    "meta.execute",
    "meta.status",
  ]

  weak var delegate: MCPToolHandlerDelegate?

  private var activeLoops: [UUID: MetaLoop] = [:]

  struct MetaLoop {
    let id: UUID
    let repoPath: String
    let startedAt: Date
    var status: MetaLoopStatus
    var runId: String?
    var tasksPlanned: Int
    var tasksCompleted: Int
    var tasksFailed: Int
  }

  enum MetaLoopStatus: String {
    case planning
    case dispatching
    case monitoring
    case paused
    case completed
    case failed
  }

  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "meta.plan":
      return handlePlan(id: id, arguments: arguments)
    case "meta.execute":
      return handleExecute(id: id, arguments: arguments)
    case "meta.status":
      return handleStatus(id: id, arguments: arguments)
    default:
      return (404, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown meta tool: \(name)"
      ))
    }
  }

  // MARK: - meta.plan

  private func handlePlan(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }

    let mission = MissionService.shared.mission(for: repoPath)
    let issueHint = arguments["issueFilter"] as? String
    let maxTasks = arguments["maxTasks"] as? Int ?? 5

    let planPrompt = buildPlanPrompt(
      repoPath: repoPath,
      mission: mission,
      issueFilter: issueHint,
      maxTasks: maxTasks
    )

    return (200, makeResult(id: id, result: [
      "prompt": planPrompt,
      "mission": mission ?? "No mission found at .peel/mission.md",
      "maxTasks": maxTasks,
      "instructions": """
        To execute this plan, call meta.execute with the same repoPath.
        Or use parallel.create directly with the tasks from this plan.
        """,
    ]))
  }

  // MARK: - meta.execute

  private func handleExecute(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }

    let maxTasks = arguments["maxTasks"] as? Int ?? 5
    let dryRun = arguments["dryRun"] as? Bool ?? false
    let templateName = arguments["templateName"] as? String ?? "Full Implementation"

    let mission = MissionService.shared.mission(for: repoPath)

    let loopId = UUID()
    var loop = MetaLoop(
      id: loopId,
      repoPath: repoPath,
      startedAt: Date(),
      status: .planning,
      tasksPlanned: 0,
      tasksCompleted: 0,
      tasksFailed: 0
    )

    activeLoops[loopId] = loop

    let planPrompt = buildPlanPrompt(
      repoPath: repoPath,
      mission: mission,
      issueFilter: arguments["issueFilter"] as? String,
      maxTasks: maxTasks
    )

    if dryRun {
      loop.status = .completed
      activeLoops[loopId] = loop
      return (200, makeResult(id: id, result: [
        "loopId": loopId.uuidString,
        "dryRun": true,
        "planPrompt": planPrompt,
        "message": "Dry run — no chains dispatched. Use dryRun: false to execute.",
      ]))
    }

    loop.status = .dispatching
    activeLoops[loopId] = loop

    return (200, makeResult(id: id, result: [
      "loopId": loopId.uuidString,
      "status": "dispatching",
      "templateName": templateName,
      "planPrompt": planPrompt,
      "instructions": """
        The meta-agent loop has been initialized. To dispatch work:
        
        1. Use the planPrompt above as context for a planner agent
        2. The planner should output tasks as JSON with title, prompt, and focusPaths
        3. Pass those tasks to parallel.create with:
           - projectPath: "\(repoPath)"
           - templateName: "\(templateName)"
           - requireReviewGate: true
        4. Call parallel.start with the resulting runId
        5. Monitor with meta.status loopId: "\(loopId.uuidString)"
        """,
    ]))
  }

  // MARK: - meta.status

  private func handleStatus(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    if let loopIdStr = arguments["loopId"] as? String,
       let loopId = UUID(uuidString: loopIdStr) {
      guard let loop = activeLoops[loopId] else {
        return (404, makeError(
          id: id,
          code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
          message: "No active loop with ID: \(loopIdStr)"
        ))
      }
      return (200, makeResult(id: id, result: [
        "loopId": loop.id.uuidString,
        "repoPath": loop.repoPath,
        "status": loop.status.rawValue,
        "tasksPlanned": loop.tasksPlanned,
        "tasksCompleted": loop.tasksCompleted,
        "tasksFailed": loop.tasksFailed,
        "runId": loop.runId ?? "",
        "elapsed": Date().timeIntervalSince(loop.startedAt),
      ]))
    }

    // List all active loops
    let loops: [[String: Any]] = activeLoops.values.map { loop in
      [
        "loopId": loop.id.uuidString,
        "repoPath": loop.repoPath,
        "status": loop.status.rawValue,
        "tasksPlanned": loop.tasksPlanned,
      ]
    }

    return (200, makeResult(id: id, result: [
      "activeLoops": loops,
      "count": loops.count,
    ]))
  }

  // MARK: - Plan Prompt Builder

  private func buildPlanPrompt(
    repoPath: String,
    mission: String?,
    issueFilter: String?,
    maxTasks: Int
  ) -> String {
    var prompt = """
      You are a Meta-Agent planner for the project at: \(repoPath)
      
      """

    if let mission {
      prompt += """
        ## Project Mission
        \(mission)
        
        """
    }

    prompt += """
      ## Your Task
      Analyze this project and identify the \(maxTasks) highest-value improvements
      that align with the mission. For each task, produce:
      
      1. **title**: Short descriptive name
      2. **prompt**: Detailed implementation instructions for a coding agent
      3. **focusPaths**: Array of file/directory paths the agent should focus on
      4. **priority**: 1 (highest) to 5 (lowest)
      5. **estimatedComplexity**: "low", "medium", or "high"
      
      ## Analysis Steps
      1. Use `rag.search` to understand the codebase structure and patterns
      2. Use `mission.get` to verify alignment with project goals
      3. Check for: dead code, force unwraps, deprecated patterns, missing tests,
         incomplete features, code quality issues
      4. Check GitHub issues with `github.issue.list` for open work items
      5. Prioritize tasks that make the project more shippable
      
      ## Output Format
      Output valid JSON array:
      ```json
      [
        {
          "title": "Fix force unwraps in NetworkService",
          "prompt": "Replace all force unwraps in Shared/Services/NetworkService.swift with proper error handling...",
          "focusPaths": ["Shared/Services/NetworkService.swift"],
          "priority": 2,
          "estimatedComplexity": "low"
        }
      ]
      ```
      
      """

    if let filter = issueFilter {
      prompt += """
        ## Issue Filter
        Focus on issues matching: \(filter)
        
        """
    }

    prompt += """
      ## Rules
      - Only suggest tasks that produce working code changes (not plans or docs)
      - Each task should be completable by a single agent in one session
      - Tasks should be independent (no dependencies between them)
      - Verify suggestions against the mission — reject anything off-mission
      - Prefer small, focused tasks over large refactors
      """

    return prompt
  }

  // MARK: - Tool Definitions

  var toolDefinitions: [[String: Any]] {
    [
      [
        "name": "meta.plan",
        "description": "Analyze the project and produce a prioritized task list aligned with the mission. Returns a planner prompt and instructions.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Path to the repository to analyze",
            ],
            "maxTasks": [
              "type": "integer",
              "description": "Maximum number of tasks to plan (default: 5)",
            ],
            "issueFilter": [
              "type": "string",
              "description": "Optional filter for GitHub issues (e.g., 'label:bug')",
            ],
          ],
          "required": ["repoPath"],
        ],
      ],
      [
        "name": "meta.execute",
        "description": "Initialize a meta-agent loop: plan work, dispatch agent chains, and monitor results. The meta-agent reads the mission, analyzes via RAG, and creates sub-tasks.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Path to the repository",
            ],
            "maxTasks": [
              "type": "integer",
              "description": "Maximum tasks to dispatch (default: 5)",
            ],
            "templateName": [
              "type": "string",
              "description": "Chain template to use for tasks (default: 'Full Implementation')",
            ],
            "dryRun": [
              "type": "boolean",
              "description": "If true, plan only — don't dispatch (default: false)",
            ],
            "issueFilter": [
              "type": "string",
              "description": "Optional filter for GitHub issues",
            ],
          ],
          "required": ["repoPath"],
        ],
      ],
      [
        "name": "meta.status",
        "description": "Check the status of a running meta-agent loop, or list all active loops.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "loopId": [
              "type": "string",
              "description": "UUID of a specific loop to check (omit to list all)",
            ],
          ],
        ],
      ],
    ]
  }
}
