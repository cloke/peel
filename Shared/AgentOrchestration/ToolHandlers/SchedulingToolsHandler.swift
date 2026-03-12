//
//  SchedulingToolsHandler.swift
//  Peel
//
//  MCP tool handler for scheduled chain management (#369).
//

import Foundation
import MCPCore

// MARK: - Scheduling Tools Handler

@MainActor
final class SchedulingToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?

  /// Direct reference to the scheduler service (not via delegate pattern).
  var scheduler: ChainSchedulerService?

  let supportedTools: Set<String> = [
    "scheduling.list",
    "scheduling.create",
    "scheduling.update",
    "scheduling.delete",
    "scheduling.history",
    "scheduling.status",
  ]

  init() {}

  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let scheduler else {
      return notConfiguredError(id: id)
    }

    switch name {
    case "scheduling.list":
      return handleList(id: id, scheduler: scheduler)
    case "scheduling.create":
      return handleCreate(id: id, arguments: arguments, scheduler: scheduler)
    case "scheduling.update":
      return handleUpdate(id: id, arguments: arguments, scheduler: scheduler)
    case "scheduling.delete":
      return handleDelete(id: id, arguments: arguments, scheduler: scheduler)
    case "scheduling.history":
      return handleHistory(id: id, arguments: arguments, scheduler: scheduler)
    case "scheduling.status":
      return handleStatus(id: id, scheduler: scheduler)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool: \(name)"))
    }
  }

  // MARK: - scheduling.list

  private func handleList(id: Any?, scheduler: ChainSchedulerService) -> (Int, Data) {
    let schedules = scheduler.listSchedules()
    let payload: [[String: Any]] = schedules.map { encodeSchedule($0) }
    return (200, makeResult(id: id, result: ["schedules": payload, "count": schedules.count]))
  }

  // MARK: - scheduling.create

  private func handleCreate(id: Any?, arguments: [String: Any], scheduler: ChainSchedulerService) -> (Int, Data) {
    guard let name = arguments["name"] as? String, !name.isEmpty else {
      return missingParamError(id: id, param: "name")
    }
    guard let templateId = arguments["templateId"] as? String, !templateId.isEmpty else {
      return missingParamError(id: id, param: "templateId")
    }
    guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
      return missingParamError(id: id, param: "prompt")
    }
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }

    let templateName = arguments["templateName"] as? String ?? ""
    let scheduleTypeStr = arguments["scheduleType"] as? String ?? "interval"
    let scheduleType = ScheduleType(rawValue: scheduleTypeStr) ?? .interval
    let intervalSeconds = arguments["intervalSeconds"] as? Int ?? 3600
    let timeOfDayHour = arguments["timeOfDayHour"] as? Int ?? 2
    let timeOfDayMinute = arguments["timeOfDayMinute"] as? Int ?? 0
    let skipOnBattery = arguments["skipOnBattery"] as? Bool ?? true
    let skipOnLowPower = arguments["skipOnLowPower"] as? Bool ?? true

    do {
      let schedule = try scheduler.createSchedule(
        name: name,
        templateId: templateId,
        templateName: templateName,
        prompt: prompt,
        repoPath: repoPath,
        scheduleType: scheduleType,
        intervalSeconds: intervalSeconds,
        timeOfDayHour: timeOfDayHour,
        timeOfDayMinute: timeOfDayMinute,
        skipOnBattery: skipOnBattery,
        skipOnLowPower: skipOnLowPower
      )
      return (200, makeResult(id: id, result: [
        "message": "Schedule created",
        "schedule": encodeSchedule(schedule),
      ]))
    } catch {
      return internalError(id: id, message: error.localizedDescription)
    }
  }

  // MARK: - scheduling.update

  private func handleUpdate(id: Any?, arguments: [String: Any], scheduler: ChainSchedulerService) -> (Int, Data) {
    guard let idStr = arguments["id"] as? String, let scheduleId = UUID(uuidString: idStr) else {
      return missingParamError(id: id, param: "id")
    }

    do {
      let schedule = try scheduler.updateSchedule(
        id: scheduleId,
        name: arguments["name"] as? String,
        isEnabled: arguments["isEnabled"] as? Bool,
        prompt: arguments["prompt"] as? String,
        intervalSeconds: arguments["intervalSeconds"] as? Int,
        timeOfDayHour: arguments["timeOfDayHour"] as? Int,
        timeOfDayMinute: arguments["timeOfDayMinute"] as? Int,
        skipOnBattery: arguments["skipOnBattery"] as? Bool,
        skipOnLowPower: arguments["skipOnLowPower"] as? Bool
      )
      return (200, makeResult(id: id, result: [
        "message": "Schedule updated",
        "schedule": encodeSchedule(schedule),
      ]))
    } catch {
      if case SchedulerError.notFound = error {
        return notFoundError(id: id, what: "Schedule")
      }
      return internalError(id: id, message: error.localizedDescription)
    }
  }

  // MARK: - scheduling.delete

  private func handleDelete(id: Any?, arguments: [String: Any], scheduler: ChainSchedulerService) -> (Int, Data) {
    guard let idStr = arguments["id"] as? String, let scheduleId = UUID(uuidString: idStr) else {
      return missingParamError(id: id, param: "id")
    }

    do {
      try scheduler.deleteSchedule(id: scheduleId)
      return (200, makeResult(id: id, result: ["message": "Schedule deleted"]))
    } catch {
      if case SchedulerError.notFound = error {
        return notFoundError(id: id, what: "Schedule")
      }
      return internalError(id: id, message: error.localizedDescription)
    }
  }

  // MARK: - scheduling.history

  private func handleHistory(id: Any?, arguments: [String: Any], scheduler: ChainSchedulerService) -> (Int, Data) {
    let scheduleId: UUID?
    if let idStr = arguments["scheduleId"] as? String {
      scheduleId = UUID(uuidString: idStr)
    } else {
      scheduleId = nil
    }
    let limit = arguments["limit"] as? Int ?? 50

    let runs = scheduler.listRunHistory(scheduleId: scheduleId, limit: limit)
    let payload: [[String: Any]] = runs.map { run in
      var entry: [String: Any] = [
        "id": run.id.uuidString,
        "scheduleId": run.scheduleId.uuidString,
        "templateName": run.templateName,
        "succeeded": run.succeeded,
        "startedAt": ISO8601DateFormatter().string(from: run.startedAt),
      ]
      if !run.chainRunId.isEmpty { entry["chainRunId"] = run.chainRunId }
      if let error = run.errorMessage { entry["error"] = error }
      if let skip = run.skipReason { entry["skipReason"] = skip }
      if let completed = run.completedAt { entry["completedAt"] = ISO8601DateFormatter().string(from: completed) }
      if let summary = run.resultSummary { entry["resultSummary"] = summary }
      return entry
    }
    return (200, makeResult(id: id, result: ["runs": payload, "count": runs.count]))
  }

  // MARK: - scheduling.status

  private func handleStatus(id: Any?, scheduler: ChainSchedulerService) -> (Int, Data) {
    let result: [String: Any] = [
      "isActive": scheduler.isActive,
      "isChecking": scheduler.isChecking,
      "activeScheduleCount": scheduler.activeScheduleCount,
      "checkIntervalSeconds": scheduler.checkIntervalSeconds,
    ]
    return (200, makeResult(id: id, result: result))
  }

  // MARK: - Encoding

  private func encodeSchedule(_ schedule: ScheduledChain) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    var entry: [String: Any] = [
      "id": schedule.id.uuidString,
      "name": schedule.name,
      "templateId": schedule.templateId,
      "templateName": schedule.templateName,
      "prompt": String(schedule.prompt.prefix(200)),
      "repoPath": schedule.repoPath,
      "scheduleType": schedule.scheduleTypeRaw,
      "isEnabled": schedule.isEnabled,
      "skipOnBattery": schedule.skipOnBattery,
      "skipOnLowPower": schedule.skipOnLowPower,
      "totalRuns": schedule.totalRuns,
      "successfulRuns": schedule.successfulRuns,
      "lastRunSucceeded": schedule.lastRunSucceeded,
      "createdAt": formatter.string(from: schedule.createdAt),
    ]

    if schedule.scheduleType == .interval {
      entry["intervalSeconds"] = schedule.intervalSeconds
    } else {
      entry["timeOfDayHour"] = schedule.timeOfDayHour
      entry["timeOfDayMinute"] = schedule.timeOfDayMinute
    }
    if let lastRun = schedule.lastRunAt { entry["lastRunAt"] = formatter.string(from: lastRun) }
    if let chainId = schedule.lastRunChainId { entry["lastRunChainId"] = chainId }
    if let error = schedule.lastRunError { entry["lastRunError"] = error }
    return entry
  }

  // MARK: - Tool Definitions

  var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "scheduling.list",
        description: "List all scheduled chains. Returns schedule definitions with status.",
        inputSchema: ["type": "object", "properties": [:]],
        category: .chains,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "scheduling.create",
        description: "Create a new scheduled chain. Runs a chain template on a recurring schedule.",
        inputSchema: [
          "type": "object",
          "properties": [
            "name": ["type": "string", "description": "Human-readable schedule name (e.g. 'Nightly Code Review')"],
            "templateId": ["type": "string", "description": "Chain template UUID to run"],
            "templateName": ["type": "string", "description": "Template name (informational)"],
            "prompt": ["type": "string", "description": "Prompt to pass to the chain"],
            "repoPath": ["type": "string", "description": "Repository path the chain targets"],
            "scheduleType": ["type": "string", "enum": ["interval", "timeOfDay"], "description": "Schedule type (default: interval)"],
            "intervalSeconds": ["type": "integer", "description": "For interval: seconds between runs (default: 3600)"],
            "timeOfDayHour": ["type": "integer", "description": "For timeOfDay: hour 0-23 (default: 2)"],
            "timeOfDayMinute": ["type": "integer", "description": "For timeOfDay: minute 0-59 (default: 0)"],
            "skipOnBattery": ["type": "boolean", "description": "Skip when on battery (default: true)"],
            "skipOnLowPower": ["type": "boolean", "description": "Skip in Low Power Mode (default: true)"],
          ],
          "required": ["name", "templateId", "prompt", "repoPath"],
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "scheduling.update",
        description: "Update an existing schedule. Pass only the fields you want to change.",
        inputSchema: [
          "type": "object",
          "properties": [
            "id": ["type": "string", "description": "Schedule UUID to update"],
            "name": ["type": "string", "description": "New name"],
            "isEnabled": ["type": "boolean", "description": "Enable or disable the schedule"],
            "prompt": ["type": "string", "description": "New prompt"],
            "intervalSeconds": ["type": "integer", "description": "New interval (seconds)"],
            "timeOfDayHour": ["type": "integer", "description": "New hour (0-23)"],
            "timeOfDayMinute": ["type": "integer", "description": "New minute (0-59)"],
            "skipOnBattery": ["type": "boolean", "description": "Skip when on battery"],
            "skipOnLowPower": ["type": "boolean", "description": "Skip in Low Power Mode"],
          ],
          "required": ["id"],
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "scheduling.delete",
        description: "Delete a schedule by ID.",
        inputSchema: [
          "type": "object",
          "properties": [
            "id": ["type": "string", "description": "Schedule UUID to delete"],
          ],
          "required": ["id"],
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "scheduling.history",
        description: "View run history for a schedule (or all schedules). Shows past executions with success/failure status.",
        inputSchema: [
          "type": "object",
          "properties": [
            "scheduleId": ["type": "string", "description": "Filter by schedule UUID (optional, shows all if omitted)"],
            "limit": ["type": "integer", "description": "Max entries to return (default: 50)"],
          ],
        ],
        category: .chains,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "scheduling.status",
        description: "Get scheduler service status: active, checking, schedule count.",
        inputSchema: ["type": "object", "properties": [:]],
        category: .chains,
        isMutating: false
      ),
    ]
  }
}
