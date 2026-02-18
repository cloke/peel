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
  
  /// Get the status of a chain run
  func chainStatus(chainId: String) -> ChainToolStatus?
  
  /// List all chain runs
  func listChainRuns(limit: Int?, status: String?) -> [ChainToolRunSummary]
  
  /// Stop a chain run
  func stopChain(chainId: String) async throws
  
  /// Pause a chain run
  func pauseChain(chainId: String) async throws
  
  /// Resume a paused chain run
  func resumeChain(chainId: String) async throws
  
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
    "chains.run.status",
    "chains.run.list",
    "chains.stop",
    "chains.pause",
    "chains.resume",
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
    case "chains.run.status":
      return handleChainRunStatus(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.run.list":
      return handleChainRunList(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.stop":
      return await handleChainStop(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.pause":
      return await handleChainPause(id: id, arguments: arguments, delegate: chainDelegate)
    case "chains.resume":
      return await handleChainResume(id: id, arguments: arguments, delegate: chainDelegate)
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
      dryRun: optionalBool("dryRun", from: arguments, default: false)
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
    guard let itemsArray = arguments["items"] as? [[String: Any]], !itemsArray.isEmpty else {
      return missingParamError(id: id, param: "items")
    }
    
    let templateId = optionalString("templateId", from: arguments)
    let templateName = optionalString("templateName", from: arguments)
    
    var items: [ChainToolBatchItem] = []
    for (index, item) in itemsArray.enumerated() {
      guard let prompt = item["prompt"] as? String else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Missing prompt in item \(index)"))
      }
      guard let repoPath = item["repoPath"] as? String else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Missing repoPath in item \(index)"))
      }
      items.append(ChainToolBatchItem(prompt: prompt, repoPath: repoPath))
    }
    
    do {
      let results = try await delegate.runBatch(prompts: items, templateId: templateId, templateName: templateName)
      let payload = results.map { encodeRunResult($0) }
      return (200, makeResult(id: id, result: ["results": payload]))
    } catch {
      await delegate.logWarning("Batch run failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - chains.run.status
  
  private func handleChainRunStatus(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let chainId) = requireString("chainId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "chainId")
    }
    
    guard let status = delegate.chainStatus(chainId: chainId) else {
      return notFoundError(id: id, what: "Chain")
    }
    
    return (200, makeResult(id: id, result: encodeStatus(status)))
  }
  
  // MARK: - chains.run.list
  
  private func handleChainRunList(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) -> (Int, Data) {
    let limit = optionalInt("limit", from: arguments)
    let statusFilter = optionalString("status", from: arguments)
    
    let runs = delegate.listChainRuns(limit: limit, status: statusFilter)
    let payload = runs.map { encodeSummary($0) }
    return (200, makeResult(id: id, result: ["runs": payload]))
  }
  
  // MARK: - chains.stop
  
  private func handleChainStop(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let chainId) = requireString("chainId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "chainId")
    }
    
    do {
      try await delegate.stopChain(chainId: chainId)
      return (200, makeResult(id: id, result: ["status": "stopped", "chainId": chainId]))
    } catch {
      await delegate.logWarning("Chain stop failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - chains.pause
  
  private func handleChainPause(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let chainId) = requireString("chainId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "chainId")
    }
    
    do {
      try await delegate.pauseChain(chainId: chainId)
      return (200, makeResult(id: id, result: ["status": "paused", "chainId": chainId]))
    } catch {
      await delegate.logWarning("Chain pause failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - chains.resume
  
  private func handleChainResume(id: Any?, arguments: [String: Any], delegate: ChainToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let chainId) = requireString("chainId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "chainId")
    }
    
    do {
      try await delegate.resumeChain(chainId: chainId)
      return (200, makeResult(id: id, result: ["status": "resumed", "chainId": chainId]))
    } catch {
      await delegate.logWarning("Chain resume failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
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
  
  private func encodeStatus(_ status: ChainToolStatus) -> [String: Any] {
    var dict: [String: Any] = [
      "chainId": status.chainId,
      "status": status.status,
      "progress": status.progress,
      "currentStep": status.currentStep,
      "totalSteps": status.totalSteps
    ]
    if let error = status.error {
      dict["error"] = error
    }
    if let reviewGate = status.reviewGate {
      dict["reviewGate"] = reviewGate
    }
    if let startedAt = status.startedAt {
      dict["startedAt"] = ISO8601DateFormatter().string(from: startedAt)
    }
    return dict
  }
  
  private func encodeSummary(_ summary: ChainToolRunSummary) -> [String: Any] {
    var dict: [String: Any] = [
      "chainId": summary.chainId,
      "status": summary.status,
      "prompt": summary.prompt
    ]
    if let startedAt = summary.startedAt {
      dict["startedAt"] = ISO8601DateFormatter().string(from: startedAt)
    }
    if let completedAt = summary.completedAt {
      dict["completedAt"] = ISO8601DateFormatter().string(from: completedAt)
    }
    return dict
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
}

/// Result of starting a chain run
struct ChainToolRunResult {
  let chainId: String
  let status: String
  let message: String
}

/// Status of a chain run
struct ChainToolStatus {
  let chainId: String
  let status: String
  let progress: Double
  let currentStep: Int
  let totalSteps: Int
  let error: String?
  let reviewGate: String?
  let startedAt: Date?
}

/// Summary of a chain run for listing
struct ChainToolRunSummary {
  let chainId: String
  let status: String
  let prompt: String
  let startedAt: Date?
  let completedAt: Date?
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
}
