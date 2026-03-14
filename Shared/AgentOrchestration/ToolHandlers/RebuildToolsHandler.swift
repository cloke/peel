//
//  RebuildToolsHandler.swift
//  Peel
//
//  MCP tools for the rebuild-and-continue pipeline.
//  Enables Peel to rebuild itself, save chain state, and resume after restart.
//
//  Tools:
//    chain.rebuild     — Run build.sh and report success/failure
//    chain.checkpoint  — Save active chain state to disk for later resume
//    chain.resume      — List or resume a previously checkpointed chain
//

import Foundation
import MCPCore

@MainActor
public final class RebuildToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  public let supportedTools: Set<String> = [
    "chain.rebuild",
    "chain.checkpoint",
    "chain.resume"
  ]

  private let checkpointService = ChainCheckpointService.shared

  public init() {}

  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "chain.rebuild":
      return await handleRebuild(id: id, arguments: arguments)
    case "chain.checkpoint":
      return handleCheckpoint(id: id, arguments: arguments)
    case "chain.resume":
      return handleResume(id: id, arguments: arguments)
    default:
      return (404, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown rebuild tool: \(name)"
      ))
    }
  }

  // MARK: - chain.rebuild

  private func handleRebuild(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let repoPath = arguments["repoPath"] as? String
    let buildScript: String
    if let repo = repoPath {
      buildScript = (repo as NSString).appendingPathComponent("Tools/build.sh")
    } else {
      // Default to the Peel repo build script
      let bundle = Bundle.main.bundlePath
      let appDir = (bundle as NSString).deletingLastPathComponent
      let projectDir = (appDir as NSString).deletingLastPathComponent
      buildScript = (projectDir as NSString).appendingPathComponent("Tools/build.sh")
    }

    guard FileManager.default.fileExists(atPath: buildScript) else {
      return (404, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Build script not found at: \(buildScript). Provide repoPath or ensure Tools/build.sh exists."
      ))
    }

    let startTime = Date()

    do {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-c", buildScript]
      if let repo = repoPath {
        process.currentDirectoryURL = URL(fileURLWithPath: repo)
      }

      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe

      try process.run()

      // Run in background to avoid blocking MainActor
      let result: (success: Bool, output: String, duration: Double) = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          process.waitUntilExit()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          let output = String(data: data, encoding: .utf8) ?? ""
          let duration = Date().timeIntervalSince(startTime)
          continuation.resume(returning: (process.terminationStatus == 0, output, duration))
        }
      }

      let body: [String: Any] = [
        "success": result.success,
        "exitCode": process.terminationStatus,
        "durationSeconds": round(result.duration * 10) / 10,
        "output": String(result.output.suffix(2000)),
        "buildScript": buildScript,
        "summary": result.success
          ? "Build succeeded in \(String(format: "%.1f", result.duration))s"
          : "Build failed (exit \(process.terminationStatus)) after \(String(format: "%.1f", result.duration))s"
      ]
      return (200, makeResult(id: id, result: body))
    } catch {
      return (500, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Failed to run build: \(error.localizedDescription)"
      ))
    }
  }

  // MARK: - chain.checkpoint

  private func handleCheckpoint(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let chainId = arguments["chainId"] as? String, !chainId.isEmpty else {
      return missingParamError(id: id, param: "chainId")
    }

    let chainName = arguments["chainName"] as? String ?? "unknown"
    let templateName = arguments["templateName"] as? String ?? "unknown"
    let prompt = arguments["prompt"] as? String ?? ""
    let workingDirectory = arguments["workingDirectory"] as? String
    let completedStepIndex = arguments["completedStepIndex"] as? Int ?? 0
    let reason = arguments["reason"] as? String ?? "manual checkpoint"
    let guidance = arguments["operatorGuidance"] as? [String] ?? []

    // Parse results if provided
    var results: [(agentName: String, model: String, output: String, premiumCost: Double)] = []
    if let resultsArray = arguments["results"] as? [[String: Any]] {
      results = resultsArray.map { r in
        (
          agentName: r["agentName"] as? String ?? "",
          model: r["model"] as? String ?? "",
          output: r["output"] as? String ?? "",
          premiumCost: r["premiumCost"] as? Double ?? 0
        )
      }
    }

    do {
      guard let uuid = UUID(uuidString: chainId) else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Invalid chainId UUID"))
      }

      let path = try checkpointService.saveCheckpoint(
        chainId: uuid,
        chainName: chainName,
        templateName: templateName,
        prompt: prompt,
        workingDirectory: workingDirectory,
        completedStepIndex: completedStepIndex,
        results: results,
        operatorGuidance: guidance,
        reason: reason
      )

      return (200, makeResult(id: id, result: [
        "success": true,
        "chainId": chainId,
        "checkpointPath": path.path,
        "completedStepIndex": completedStepIndex,
        "reason": reason,
        "hint": "Chain state saved. Use chain.resume to continue after app restart.",
      ]))
    } catch {
      return (500, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Failed to save checkpoint: \(error.localizedDescription)"
      ))
    }
  }

  // MARK: - chain.resume

  private func handleResume(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let chainId = arguments["chainId"] as? String

    if let chainId {
      // Resume a specific chain
      guard let checkpoint = checkpointService.loadCheckpoint(chainId: chainId) else {
        return (404, makeError(
          id: id,
          code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
          message: "No checkpoint found for chain \(chainId)"
        ))
      }

      return (200, makeResult(id: id, result: [
        "found": true,
        "checkpoint": checkpointToDict(checkpoint),
        "hint": "Use chains.run with the same template and prompt to continue from step \(checkpoint.completedStepIndex + 1). Pass the checkpoint results as context.",
      ]))
    } else {
      // List all checkpoints
      let checkpoints = checkpointService.listCheckpoints()
      return (200, makeResult(id: id, result: [
        "count": checkpoints.count,
        "checkpoints": checkpoints.map { checkpointToDict($0) },
      ]))
    }
  }

  private func checkpointToDict(_ cp: ChainCheckpoint) -> [String: Any] {
    [
      "chainId": cp.chainId,
      "chainName": cp.chainName,
      "templateName": cp.templateName,
      "prompt": String(cp.prompt.prefix(200)),
      "workingDirectory": cp.workingDirectory ?? "",
      "completedStepIndex": cp.completedStepIndex,
      "resultCount": cp.completedResults.count,
      "savedAt": ISO8601DateFormatter().string(from: cp.savedAt),
      "reason": cp.reason,
    ]
  }

  // MARK: - Tool Definitions

  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "chain.rebuild",
        description: "Run the project build script (Tools/build.sh) and report success/failure. Use this to verify code changes compile before continuing. Returns build output, exit code, and duration.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Absolute path to the repository root (default: Peel's own repo)"
            ]
          ],
          "required": []
        ],
        category: .terminal,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chain.checkpoint",
        description: "Save the current chain execution state to disk. Used before app rebuild/relaunch so the chain can resume from this point. Saves completed step results, operator guidance, and chain metadata.",
        inputSchema: [
          "type": "object",
          "properties": [
            "chainId": ["type": "string", "description": "UUID of the active chain"],
            "chainName": ["type": "string", "description": "Display name of the chain"],
            "templateName": ["type": "string", "description": "Template used to create the chain"],
            "prompt": ["type": "string", "description": "Original prompt that started the chain"],
            "workingDirectory": ["type": "string", "description": "Working directory for the chain"],
            "completedStepIndex": ["type": "integer", "description": "Index of the last completed step (0-based)"],
            "reason": ["type": "string", "description": "Why the checkpoint was created (e.g., 'rebuild', 'manual')"],
            "operatorGuidance": [
              "type": "array",
              "items": ["type": "string"],
              "description": "Operator guidance messages to preserve"
            ],
            "results": [
              "type": "array",
              "items": [
                "type": "object",
                "properties": [
                  "agentName": ["type": "string"],
                  "model": ["type": "string"],
                  "output": ["type": "string"],
                  "premiumCost": ["type": "number"]
                ]
              ],
              "description": "Results from completed steps to preserve"
            ]
          ],
          "required": ["chainId"]
        ],
        category: .state,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chain.resume",
        description: "List saved chain checkpoints or load a specific one for resumption. Without chainId, lists all checkpoints. With chainId, returns the full checkpoint state to resume from.",
        inputSchema: [
          "type": "object",
          "properties": [
            "chainId": [
              "type": "string",
              "description": "UUID of the chain to resume (omit to list all)"
            ]
          ],
          "required": []
        ],
        category: .state,
        isMutating: false
      ),
    ]
  }
}
