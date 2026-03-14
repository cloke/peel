//
//  ChainToolsHandler.swift
//  Peel
//
//  Created as part of #160: Extract Chain tools from MCPServerService.
//

import Foundation
import MCPCore

// MARK: - Chain Tools Handler Delegate Extension

/// Extended delegate protocol for Chain-specific functionality
@MainActor
protocol ChainToolsHandlerDelegate: MCPToolHandlerDelegate {
  // MARK: - AgentManager Access
  
  /// Start a chain run
  func startChain(
    prompt: String,
    repoPath: String,
    templateId: String?,
    templateName: String?,
    options: ChainToolRunOptions
  ) async throws -> ChainToolRunResult

  /// Get persisted run details including per-agent outputs
  func chainRunResults(runId: String?, chainId: String?, includeOutputs: Bool) -> [[String: Any]]

  /// Aggregate optimization audit findings from recent persisted runs
  func aggregateAuditFindings(limit: Int, top: Int, promptContains: String?) -> [String: Any]
  
  /// Send instruction to a chain (review/approve/reject)
  func instructChain(chainId: String, action: String, feedback: String?) async throws
  
  /// Step through a chain
  func stepChain(chainId: String) async throws
  
  // MARK: - Template Access
  
  /// List available templates
  func listTemplates() -> [ChainToolTemplate]
  
  /// Get a template by ID or name
  func getTemplate(id: String?, name: String?) -> ChainToolTemplate?
  
  // MARK: - Queue Management
  
  /// Get queue status
  func queueStatus() -> ChainToolQueueStatus
  
  /// Configure queue
  func configureQueue(maxConcurrent: Int?, pauseNew: Bool?) throws
  
  /// Cancel queued chain
  func cancelQueued(chainId: String) async throws
  
  // MARK: - Prompt Rules
  
  /// Get prompt rules
  func getPromptRules() -> MCPServerService.PromptRules
  
  /// Set prompt rules
  func setPromptRules(_ rules: MCPServerService.PromptRules) throws
  
  // MARK: - Batch Operations
  
  /// Run multiple chains in batch
  func runBatch(prompts: [ChainToolBatchItem], templateId: String?, templateName: String?) async throws -> [ChainToolRunResult]
  
  // MARK: - Logging
  
  /// Log a warning
  func logWarning(_ message: String, metadata: [String: String]) async
}

// MARK: - Chain Tools Handler

/// Handles Chain orchestration tools
@MainActor
final class ChainToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?
  
  /// Typed delegate for Chain-specific operations
  private var chainDelegate: ChainToolsHandlerDelegate? {
    delegate as? ChainToolsHandlerDelegate
  }
  
  let supportedTools: Set<String> = [
    "chains.run",
    "chains.runBatch",
    "chains.run.results",
    "chains.audit.aggregate",
    "chains.instruct",
    "chains.step",
    "chains.queue.status",
    "chains.queue.configure",
    "chains.queue.cancel",
    "chains.promptRules.get",
    "chains.promptRules.set",
    "templates.list"
  ]
  
  init() {}
  
  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let chainDelegate else {
      return notConfiguredError(id: id)
    }
    
    switch name {
    case "templates.list":
      return handleTemplatesList(id: id, delegate: chainDelegate)
    case "chains.run":
      return await handleChainRun(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.runBatch":
      return await handleChainRunBatch(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.run.results":
      return handleChainRunResults(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.audit.aggregate":
      return handleChainsAuditAggregate(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.instruct":
      return await handleChainInstruct(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.step":
      return await handleChainStep(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.queue.status":
      return handleQueueStatus(id: id, delegate: chainDelegate)
    case "chains.queue.configure":
      return handleQueueConfigure(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.queue.cancel":
      return await handleQueueCancel(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.promptRules.get":
      return handlePromptRulesGet(id: id, delegate: chainDelegate)
    case "chains.promptRules.set":
      return handlePromptRulesSet(id: id, arguments: arguments, delegate: chainDelegate)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Tool not yet extracted: \(name)"))
    }
  }
  
  // MARK: - templates.list
  
  private func handleTemplatesList(id: Any?, delegate: ChainToolsHandlerDelegate) -> (Int, Data) {
    let templates = delegate.listTemplates()
    let payload = templates.map { encodeTemplate($0) }
    return (200, makeResult(id: id, result: ["templates": payload]))
  }
  
  // MARK: - chains.run
  
  private func handleChainRun(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let prompt) = requireString("prompt", from: arguments, id: id) else {
      return missingParamError(id: id, param: "prompt")
    }
    // Accept both repoPath (preferred) and workingDirectory (PeelCLI compat)
    let repoPathValue = (arguments["repoPath"] as? String) ?? (arguments["workingDirectory"] as? String)
    guard let repoPath = repoPathValue, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let templateId = optionalString("templateId", from: arguments)
    let templateName = optionalString("templateName", from: arguments)
    
    let options = ChainToolRunOptions(
      maxPremiumCost: optionalDouble("maxPremiumCost", from: arguments),
      requireRag: optionalBool("requireRag", from: arguments, default: false),
      skipReview: optionalBool("skipReview", from: arguments, default: false),
      dryRun: optionalBool("dryRun", from: arguments, default: false),
      returnImmediately: optionalBool("returnImmediately", from: arguments, default: false),
      prNumber: arguments["prNumber"] as? Int,
      prTitle: arguments["prTitle"] as? String,
      prRepoOwner: arguments["prRepoOwner"] as? String,
      prRepoName: arguments["prRepoName"] as? String,
      prHeadRef: arguments["prHeadRef"] as? String,
      prHtmlURL: arguments["prHtmlURL"] as? String
    )
    
    do {
      let result = try await delegate.startChain(
        prompt: prompt,
        repoPath: repoPath,
        templateId: templateId,
        templateName: templateName,
        options: options
      )
      return (200, makeResult(id: id, result: encodeRunResult(result)))
    } catch {
      await delegate.logWarning("Chain run failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - chains.runBatch
  
  private func handleChainRunBatch(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) async -> (Int, Data) {
    // Accept both "items" (documented) and "runs" (PeelCLI compat) as the array key
    let itemsArray = (arguments["items"] as? [[String: Any]]) ?? (arguments["runs"] as? [[String: Any]])
    guard let itemsArray, !itemsArray.isEmpty else {
      return missingParamError(id: id, param: "items")
    }

    let batchTemplateId = optionalString("templateId", from: arguments)
    let batchTemplateName = optionalString("templateName", from: arguments)

    var items: [ChainToolBatchItem] = []
    for (index, item) in itemsArray.enumerated() {
      guard let prompt = item["prompt"] as? String else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Missing prompt in item \(index)"))
      }
      // Accept "repoPath" or "workingDirectory" as the path key
      guard let repoPath = (item["repoPath"] as? String) ?? (item["workingDirectory"] as? String), !repoPath.isEmpty else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Missing repoPath or workingDirectory in item \(index)"))
      }
      // Per-item template overrides batch-level template
      let itemTemplateId = item["templateId"] as? String
      let itemTemplateName = item["templateName"] as? String
      items.append(ChainToolBatchItem(
        prompt: prompt,
        repoPath: repoPath,
        templateId: itemTemplateId ?? batchTemplateId,
        templateName: itemTemplateName ?? batchTemplateName
      ))
    }

    let templateId = batchTemplateId
    let templateName = batchTemplateName
    
    do {
      let results = try await delegate.runBatch(prompts: items, templateId: templateId, templateName: templateName)
      let payload = results.map { encodeRunResult($0) }
      return (200, makeResult(id: id, result: ["results": payload, "count": results.count]))
    } catch {
      await delegate.logWarning("Batch run failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - chains.run.results

  private func handleChainRunResults(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) -> (Int, Data) {
    let runId = optionalString("runId", from: arguments)
    let chainId = optionalString("chainId", from: arguments)
    let includeOutputs = optionalBool("includeOutputs", from: arguments, default: true)

    guard runId != nil || chainId != nil else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "runId or chainId is required"))
    }

    let runs = delegate.chainRunResults(runId: runId, chainId: chainId, includeOutputs: includeOutputs)
    if runs.isEmpty {
      return notFoundError(id: id, what: "Run")
    }
    return (200, makeResult(id: id, result: ["runs": runs]))
  }

  // MARK: - chains.audit.aggregate

  private func handleChainsAuditAggregate(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) -> (Int, Data) {
    let limit = max(1, optionalInt("limit", from: arguments) ?? 20)
    let top = max(1, optionalInt("top", from: arguments) ?? 10)
    let promptContains = optionalString("promptContains", from: arguments)

    let payload = delegate.aggregateAuditFindings(limit: limit, top: top, promptContains: promptContains)
    return (200, makeResult(id: id, result: payload))
  }
  
  // MARK: - chains.instruct
  
  private func handleChainInstruct(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let chainId) = requireString("chainId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "chainId")
    }
    guard case .success(let action) = requireString("action", from: arguments, id: id) else {
      return missingParamError(id: id, param: "action")
    }
    
    let feedback = optionalString("feedback", from: arguments)
    
    do {
      try await delegate.instructChain(chainId: chainId, action: action, feedback: feedback)
      return (200, makeResult(id: id, result: ["status": "instructed", "chainId": chainId, "action": action]))
    } catch {
      await delegate.logWarning("Chain instruct failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - chains.step
  
  private func handleChainStep(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let chainId) = requireString("chainId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "chainId")
    }
    
    do {
      try await delegate.stepChain(chainId: chainId)
      return (200, makeResult(id: id, result: ["status": "stepped", "chainId": chainId]))
    } catch {
      await delegate.logWarning("Chain step failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - chains.queue.status
  
  private func handleQueueStatus(id: Any?, delegate: ChainToolsHandlerDelegate) -> (Int, Data) {
    let status = delegate.queueStatus()
    return (200, makeResult(id: id, result: encodeQueueStatus(status)))
  }
  
  // MARK: - chains.queue.configure
  
  private func handleQueueConfigure(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) -> (Int, Data) {
    let maxConcurrent = optionalInt("maxConcurrent", from: arguments)
    let pauseNew = arguments["pauseNew"] as? Bool
    
    do {
      try delegate.configureQueue(maxConcurrent: maxConcurrent, pauseNew: pauseNew)
      let status = delegate.queueStatus()
      return (200, makeResult(id: id, result: encodeQueueStatus(status)))
    } catch {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: error.localizedDescription))
    }
  }
  
  // MARK: - chains.queue.cancel
  
  private func handleQueueCancel(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let chainId) = requireString("chainId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "chainId")
    }
    
    do {
      try await delegate.cancelQueued(chainId: chainId)
      return (200, makeResult(id: id, result: ["status": "cancelled", "chainId": chainId]))
    } catch {
      await delegate.logWarning("Queue cancel failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - chains.promptRules.get
  
  private func handlePromptRulesGet(id: Any?, delegate: ChainToolsHandlerDelegate) -> (Int, Data) {
    let rules = delegate.getPromptRules()
    return (200, makeResult(id: id, result: encodePromptRules(rules)))
  }
  
  // MARK: - chains.promptRules.set
  
  private func handlePromptRulesSet(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) -> (Int, Data) {
    var rules = delegate.getPromptRules()
    
    if let globalPrefix = arguments["globalPrefix"] as? String {
      rules.globalPrefix = globalPrefix
    }
    if let enforcePlannerModel = arguments["enforcePlannerModel"] as? String {
      rules.enforcePlannerModel = enforcePlannerModel.isEmpty ? nil : enforcePlannerModel
    }
    if let maxPremiumCost = arguments["maxPremiumCostDefault"] as? Double {
      rules.maxPremiumCostDefault = maxPremiumCost
    }
    if let requireRag = arguments["requireRagByDefault"] as? Bool {
      rules.requireRagByDefault = requireRag
    }
    
    do {
      try delegate.setPromptRules(rules)
      return (200, makeResult(id: id, result: encodePromptRules(rules)))
    } catch {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: error.localizedDescription))
    }
  }
  
  // MARK: - Encoding Helpers
  
  private func encodeTemplate(_ template: ChainToolTemplate) -> [String: Any] {
    var dict: [String: Any] = [
      "id": template.id,
      "name": template.name,
      "description": template.description
    ]
    if let category = template.category {
      dict["category"] = category
    }
    if let tags = template.tags {
      dict["tags"] = tags
    }
    return dict
  }
  
  private func encodeRunResult(_ result: ChainToolRunResult) -> [String: Any] {
    [
      "chainId": result.chainId,
      "status": result.status,
      "message": result.message
    ]
  }
  
  private func encodeQueueStatus(_ status: ChainToolQueueStatus) -> [String: Any] {
    [
      "running": status.running,
      "queued": status.queued,
      "maxConcurrent": status.maxConcurrent,
      "pauseNew": status.pauseNew
    ]
  }
  
  private func encodePromptRules(_ rules: MCPServerService.PromptRules) -> [String: Any] {
    var dict: [String: Any] = [
      "requireRagByDefault": rules.requireRagByDefault,
      "globalPrefix": rules.globalPrefix
    ]
    if let enforcePlannerModel = rules.enforcePlannerModel {
      dict["enforcePlannerModel"] = enforcePlannerModel
    }
    if let maxPremiumCost = rules.maxPremiumCostDefault {
      dict["maxPremiumCostDefault"] = maxPremiumCost
    }
    return dict
  }
  
  // MARK: - Helper for optionalDouble
  
  private func optionalDouble(_ key: String, from arguments: [String: Any]) -> Double? {
    if let value = arguments[key] as? Double {
      return value
    }
    if let value = arguments[key] as? Int {
      return Double(value)
    }
    return nil
  }
}

// MARK: - Supporting Types

/// Options for running a chain
struct ChainToolRunOptions {
  let maxPremiumCost: Double?
  let requireRag: Bool
  let skipReview: Bool
  let dryRun: Bool
  var returnImmediately: Bool = false

  // PR review context (optional)
  var prNumber: Int?
  var prTitle: String?
  var prRepoOwner: String?
  var prRepoName: String?
  var prHeadRef: String?
  var prHtmlURL: String?
}

/// Result of starting a chain run
struct ChainToolRunResult {
  let chainId: String
  let status: String
  let message: String
}

/// Template info
struct ChainToolTemplate {
  let id: String
  let name: String
  let description: String
  let category: String?
  let tags: [String]?
}

/// Queue status
struct ChainToolQueueStatus {
  let running: Int
  let queued: Int
  let maxConcurrent: Int
  let pauseNew: Bool
}

/// Batch item for running multiple chains
struct ChainToolBatchItem {
  let prompt: String
  let repoPath: String
  /// Per-item template override (takes precedence over the batch-level templateId)
  let templateId: String?
  let templateName: String?

  init(prompt: String, repoPath: String, templateId: String? = nil, templateName: String? = nil) {
    self.prompt = prompt
    self.repoPath = repoPath
    self.templateId = templateId
    self.templateName = templateName
  }
}

// MARK: - Tool Definitions

extension ChainToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "templates.list",
        description: "List available chain templates",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .chains,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chains.run",
        description: "Run a chain template with a prompt",
        inputSchema: [
          "type": "object",
          "properties": [
            "templateId": ["type": "string"],
            "templateName": ["type": "string"],
            "chainSpec": [
              "type": "object",
              "properties": [
                "name": ["type": "string"],
                "description": ["type": "string"],
                "steps": [
                  "type": "array",
                  "items": [
                    "type": "object",
                    "properties": [
                      "role": ["type": "string"],
                      "model": ["type": "string"],
                      "name": ["type": "string"],
                      "frameworkHint": ["type": "string"],
                      "customInstructions": ["type": "string"],
                      "stepType": ["type": "string", "description": "Execution type: 'agentic' (default, LLM), 'deterministic' (shell command), or 'gate' (check command)"],
                      "command": ["type": "string", "description": "Shell command for deterministic/gate steps"],
                      "allowedTools": ["type": "array", "items": ["type": "string"], "description": "Tools explicitly allowed for this step (agentic only)"],
                      "deniedTools": ["type": "array", "items": ["type": "string"], "description": "Tools explicitly denied for this step (agentic only)"]
                    ],
                    "required": ["role", "model"]
                  ]
                ]
              ],
              "required": ["steps"]
            ],
            "prompt": ["type": "string"],
            "workingDirectory": ["type": "string"],
            "enableReviewLoop": ["type": "boolean"],
            "pauseOnReview": ["type": "boolean"],
            "enablePrePlanner": ["type": "boolean", "description": "Enable RAG-grounded pre-planner step before main planner runs"],
            "allowPlannerModelSelection": ["type": "boolean"],
            "allowImplementerModelOverride": ["type": "boolean"],
            "allowPlannerImplementerScaling": ["type": "boolean"],
            "maxImplementers": ["type": "integer"],
            "maxPremiumCost": ["type": "number"],
            "priority": ["type": "integer"],
            "timeoutSeconds": ["type": "number"],
            "returnImmediately": ["type": "boolean"],
            "keepWorkspace": ["type": "boolean"],
            "requireRagUsage": ["type": "boolean"],
            "prNumber": ["type": "integer", "description": "PR number for PR review runs"],
            "prTitle": ["type": "string", "description": "PR title for PR review runs"],
            "prRepoOwner": ["type": "string", "description": "Repository owner for PR review runs"],
            "prRepoName": ["type": "string", "description": "Repository name for PR review runs"],
            "prHeadRef": ["type": "string", "description": "PR head branch ref"],
            "prHtmlURL": ["type": "string", "description": "PR HTML URL"]
          ],
          "required": ["prompt"]
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chains.run.results",
        description: "Get persisted chain run details including per-agent results and optional outputs",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string", "description": "Run UUID from chains.run/list"],
            "chainId": ["type": "string", "description": "Chain UUID (alternate lookup key)"],
            "includeOutputs": ["type": "boolean", "description": "Include full agent output text (default: true)"]
          ]
        ],
        category: .chains,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chains.audit.aggregate",
        description: "Aggregate optimization audit findings from recent runs and return ranked top findings plus markdown",
        inputSchema: [
          "type": "object",
          "properties": [
            "limit": ["type": "integer", "description": "How many recent matching runs to analyze (default: 20)"],
            "top": ["type": "integer", "description": "How many ranked findings to return (default: 10)"],
            "promptContains": ["type": "string", "description": "Optional substring filter for run prompts"]
          ]
        ],
        category: .chains,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "workspaces.agent.list",
        description: "List agent workspaces and their status",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"]
          ]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "workspaces.agent.cleanup.status",
        description: "Get agent worktree cleanup status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chains.runBatch",
        description: "Run multiple chains (optionally in parallel)",
        inputSchema: [
          "type": "object",
          "properties": [
            "runs": [
              "type": "array",
              "items": [
                "type": "object",
                "properties": [
                  "templateId": ["type": "string"],
                  "templateName": ["type": "string"],
                  "prompt": ["type": "string"],
                  "workingDirectory": ["type": "string"],
                  "enableReviewLoop": ["type": "boolean"],
                  "pauseOnReview": ["type": "boolean"],
                  "enablePrePlanner": ["type": "boolean"],
                  "allowPlannerModelSelection": ["type": "boolean"],
                  "allowImplementerModelOverride": ["type": "boolean"],
                  "allowPlannerImplementerScaling": ["type": "boolean"],
                  "maxImplementers": ["type": "integer"],
                  "maxPremiumCost": ["type": "number"],
                  "priority": ["type": "integer"],
                  "timeoutSeconds": ["type": "number"]
                ],
                "required": ["prompt"]
              ]
            ],
            "parallel": ["type": "boolean"]
          ],
          "required": ["runs"]
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chains.instruct",
        description: "Inject operator guidance into a running chain",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "guidance": ["type": "string"]
          ],
          "required": ["runId", "guidance"]
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chains.step",
        description: "Step a paused chain to the next agent by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chains.queue.status",
        description: "Get chain queue status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .chains,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chains.queue.configure",
        description: "Configure chain queue limits",
        inputSchema: [
          "type": "object",
          "properties": [
            "maxConcurrent": ["type": "integer"],
            "maxQueued": ["type": "integer"]
          ]
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chains.queue.cancel",
        description: "Cancel a queued chain by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chains.promptRules.get",
        description: "Get current prompt rules and guardrails configuration",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .chains,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chains.promptRules.set",
        description: "Update prompt rules and guardrails. Partial updates supported.",
        inputSchema: [
          "type": "object",
          "properties": [
            "globalPrefix": ["type": "string", "description": "Text prepended to all prompts"],
            "enforcePlannerModel": ["type": "string", "description": "Model name to enforce for planner"],
            "maxPremiumCostDefault": ["type": "number", "description": "Default max premium cost"],
            "requireRagByDefault": ["type": "boolean", "description": "Require RAG usage by default"],
            "perTemplateOverrides": ["type": "object", "description": "Per-template overrides keyed by template name"]
          ]
        ],
        category: .chains,
        isMutating: true
      ),
    ]
  }
}
