//
//  MissionToolsHandler.swift
//  Peel
//
//  MCP tool handler for reading and checking project mission statements.
//  Tools: mission.get, mission.check
//

import Foundation
import MCPCore

@MainActor
public final class MissionToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  public let supportedTools: Set<String> = [
    "mission.get",
    "mission.check"
  ]

  public init() {}

  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "mission.get":
      return handleGet(id: id, arguments: arguments)
    case "mission.check":
      return handleCheck(id: id, arguments: arguments)
    default:
      return (404, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown mission tool: \(name)"
      ))
    }
  }

  // MARK: - mission.get

  private func handleGet(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }

    let mission = MissionService.shared.mission(for: repoPath)

    return (200, makeResult(id: id, result: [
      "found": mission != nil,
      "content": mission ?? "",
      "path": (repoPath as NSString).appendingPathComponent(".peel/mission.md"),
      "hint": mission == nil
        ? "No mission statement found. Create .peel/mission.md to define project goals."
        : ""
    ]))
  }

  // MARK: - mission.check

  /// Lets an agent ask "does this task align with the project mission?"
  private func handleCheck(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }
    guard let taskDescription = arguments["taskDescription"] as? String, !taskDescription.isEmpty else {
      return missingParamError(id: id, param: "taskDescription")
    }

    guard let mission = MissionService.shared.mission(for: repoPath) else {
      return (200, makeResult(id: id, result: [
        "aligned": true,
        "confidence": "unknown",
        "reason": "No mission statement found at .peel/mission.md — cannot evaluate alignment. Proceeding by default.",
      ]))
    }

    // Provide the mission and task to the caller for self-evaluation.
    // The agent itself performs the alignment check with full LLM reasoning.
    return (200, makeResult(id: id, result: [
      "mission": mission,
      "taskDescription": taskDescription,
      "instruction": "Evaluate whether this task aligns with the project mission above. Consider: Does it serve the core loop? Does it match the priorities? Is it explicitly out of scope? Respond with your assessment and proceed only if aligned.",
    ]))
  }

  // MARK: - Tool Definitions

  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "mission.get",
        description: "Get the project mission statement from .peel/mission.md. Returns the mission content that defines project goals, priorities, and what work is in/out of scope. Agents should read this before planning work.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Absolute path to the repository root"
            ]
          ],
          "required": ["repoPath"]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "mission.check",
        description: "Check whether a proposed task aligns with the project mission. Returns the mission statement and evaluation instructions. Use before starting work to ensure alignment.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Absolute path to the repository root"
            ],
            "taskDescription": [
              "type": "string",
              "description": "Brief description of the task to check alignment for"
            ]
          ],
          "required": ["repoPath", "taskDescription"]
        ],
        category: .state,
        isMutating: false
      ),
    ]
  }
}
