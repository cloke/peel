//
//  MCPServerService+ChainToolsDelegate.swift
//  KitchenSync
//
//  Extracted from MCPServerService.swift for maintainability.
//

import Foundation

// Note: ChainAPIError is defined in ChainErrors.swift
// Using typealias for backward compatibility within this file
private typealias ChainError = ChainAPIError

// MARK: - ChainToolsHandlerDelegate

extension MCPServerService: ChainToolsHandlerDelegate {
  
  // MARK: - Chain Lifecycle
  
  func startChain(
    prompt: String,
    repoPath: String,
    templateId: String?,
    templateName: String?,
    options: ChainToolRunOptions
  ) async throws -> ChainToolRunResult {
    // Delegate to the full-featured handleChainRun and convert the result
    var arguments: [String: Any] = [
      "prompt": prompt,
      "workingDirectory": repoPath,
      "requireRagUsage": options.requireRag
    ]
    if let templateId {
      arguments["templateId"] = templateId
    }
    if let templateName {
      arguments["templateName"] = templateName
    }
    if let maxPremiumCost = options.maxPremiumCost {
      arguments["maxPremiumCost"] = maxPremiumCost
    }
    if options.skipReview {
      arguments["enableReviewLoop"] = false
    }
    if options.dryRun || options.returnImmediately {
      arguments["returnImmediately"] = true
    }
    
    let (status, data) = await handleChainRun(id: nil, arguments: arguments)
    
    // handleChainRun returns makeToolResult, which wraps the data as:
    // { "result": { "content": [{"type":"text","text":"<json>"}], "isError": false } }
    // Parse through the MCP content envelope then look for runId.
    if status == 200,
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let outerResult = json["result"] as? [String: Any] {
      // Try MCP content envelope first
      let chainData: [String: Any]?
      if let content = outerResult["content"] as? [[String: Any]],
         let text = content.first?["text"] as? String,
         let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
        chainData = parsed
      } else {
        chainData = outerResult
      }
      if let chainData {
        let runId = chainData["runId"] as? String
          ?? (chainData["queue"] as? [String: Any])?["runId"] as? String
        if let runId {
          return ChainToolRunResult(
            chainId: runId,
            status: "started",
            message: chainData["message"] as? String ?? "Chain started"
          )
        }
      }
    }
    
    // Parse error
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let error = json["error"] as? [String: Any],
       let message = error["message"] as? String {
      throw ChainError.startFailed(message)
    }
    
    throw ChainError.startFailed("Unknown error starting chain")
  }
  
  func chainStatus(chainId: String) -> ChainToolStatus? {
    guard let runId = UUID(uuidString: chainId) else { return nil }
    
    if let runInfo = activeRunsById[runId] {
      let chain = activeRunChains[runId]
      return ChainToolStatus(
        chainId: chainId,
        status: "running",
        progress: Double(chain?.results.count ?? 0) / Double(max(chain?.agents.count ?? 1, 1)),
        currentStep: chain?.results.count ?? 0,
        totalSteps: chain?.agents.count ?? 0,
        error: nil,
        reviewGate: chain?.state.displayName.contains("review") == true ? chain?.state.displayName : nil,
        startedAt: runInfo.startedAt
      )
    }
    
    if let queuedIndex = chainQueue.firstIndex(where: { $0.id == runId }) {
      let entry = chainQueue[queuedIndex]
      return ChainToolStatus(
        chainId: chainId,
        status: "queued",
        progress: 0,
        currentStep: 0,
        totalSteps: 0,
        error: nil,
        reviewGate: nil,
        startedAt: entry.enqueuedAt
      )
    }
    
    if let completed = completedRunsById[runId] {
      return ChainToolStatus(
        chainId: chainId,
        status: "completed",
        progress: 1.0,
        currentStep: 0,
        totalSteps: 0,
        error: nil,
        reviewGate: nil,
        startedAt: completed.completedAt
      )
    }
    
    return nil
  }
  
  func listChainRuns(limit: Int?, status: String?) -> [ChainToolRunSummary] {
    var runs: [ChainToolRunSummary] = []
    
    // Add active runs
    for (runId, info) in activeRunsById {
      if status == nil || status == "running" {
        runs.append(ChainToolRunSummary(
          chainId: runId.uuidString,
          status: "running",
          prompt: info.prompt,
          startedAt: info.startedAt,
          completedAt: nil
        ))
      }
    }
    
    // Add queued runs
    for entry in chainQueue {
      if status == nil || status == "queued" {
        runs.append(ChainToolRunSummary(
          chainId: entry.id.uuidString,
          status: "queued",
          prompt: "",
          startedAt: entry.enqueuedAt,
          completedAt: nil
        ))
      }
    }
    
    // Add completed runs
    for (runId, completed) in completedRunsById {
      if status == nil || status == "completed" {
        let prompt = (completed.payload["prompt"] as? String) ?? ""
        runs.append(ChainToolRunSummary(
          chainId: runId.uuidString,
          status: "completed",
          prompt: prompt,
          startedAt: nil,
          completedAt: completed.completedAt
        ))
      }
    }

    if let dataService {
      let persistedRuns = dataService.getRecentMCPRuns(limit: max(limit ?? 100, 200))
      let knownRunIDs = Set(runs.compactMap { UUID(uuidString: $0.chainId) })

      for persisted in persistedRuns {
        guard !knownRunIDs.contains(persisted.id) else { continue }

        let persistedStatus = persisted.success ? "completed" : "failed"
        if let status, status != persistedStatus {
          continue
        }

        runs.append(ChainToolRunSummary(
          chainId: persisted.id.uuidString,
          status: persistedStatus,
          prompt: persisted.prompt,
          startedAt: persisted.createdAt,
          completedAt: persisted.createdAt
        ))
      }
    }
    
    // Sort by most recent first
    runs.sort { ($0.startedAt ?? $0.completedAt ?? Date.distantPast) > ($1.startedAt ?? $1.completedAt ?? Date.distantPast) }
    
    if let limit {
      return Array(runs.prefix(limit))
    }
    return runs
  }

  func chainRunResults(runId: String?, chainId: String?, includeOutputs: Bool) -> [[String: Any]] {
    guard let dataService else { return [] }

    func splitLines(_ value: String) -> [String] {
      value
        .split(whereSeparator: { $0.isNewline })
        .map { String($0) }
        .filter { !$0.isEmpty }
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    var runs: [MCPRunRecord] = []

    if let runId {
      if let uuid = UUID(uuidString: runId) {
        let recent = dataService.getRecentMCPRuns(limit: 5_000)
        if let found = recent.first(where: { $0.id == uuid }) {
          runs = [found]
        }
      }

      if runs.isEmpty, let found = dataService.getMCPRun(forChainId: runId) {
        runs = [found]
      }
    } else if let chainId, !chainId.isEmpty {
      if let found = dataService.getMCPRun(forChainId: chainId) {
        runs = [found]
      }
    }

    return runs.map { run in
      var runPayload: [String: Any] = [
        "runId": run.id.uuidString,
        "chainId": run.chainId,
        "templateId": run.templateId,
        "templateName": run.templateName,
        "prompt": run.prompt,
        "workingDirectory": run.workingDirectory as Any,
        "implementerBranches": splitLines(run.implementerBranches),
        "implementerWorkspacePaths": splitLines(run.implementerWorkspacePaths),
        "screenshotPaths": splitLines(run.screenshotPaths),
        "success": run.success,
        "errorMessage": run.errorMessage as Any,
        "noWorkReason": run.noWorkReason as Any,
        "mergeConflictsCount": run.mergeConflictsCount,
        "resultCount": run.resultCount,
        "validationStatus": run.validationStatus as Any,
        "validationReasons": splitLines(run.validationReasons ?? ""),
        "createdAt": formatter.string(from: run.createdAt)
      ]

      if !run.chainId.isEmpty {
        let results = dataService.getMCPRunResults(chainId: run.chainId)
        runPayload["results"] = results.map { result in
          var resultPayload: [String: Any] = [
            "agentId": result.agentId,
            "agentName": result.agentName,
            "model": result.model,
            "prompt": result.prompt,
            "premiumCost": result.premiumCost,
            "reviewVerdict": result.reviewVerdict as Any,
            "createdAt": formatter.string(from: result.createdAt)
          ]
          if includeOutputs {
            resultPayload["output"] = result.output
          }
          return resultPayload
        }
      }

      return runPayload
    }
  }
  
  func stopChain(chainId: String) async throws {
    guard let runId = UUID(uuidString: chainId) else {
      throw ChainError.invalidChainId
    }
    
    // Cancel via task if running
    if let task = activeChainTasks[runId] {
      task.cancel()
      await telemetryProvider.warning("Chain cancellation requested", metadata: ["runId": runId.uuidString])
      return
    }
    
    // Try to cancel from queue
    if cancelQueuedRunInternal(runId: runId) {
      return
    }
    
    throw ChainError.notFound
  }
  
  func pauseChain(chainId: String) async throws {
    guard let runId = UUID(uuidString: chainId),
          let chain = activeRunChains[runId] else {
      throw ChainError.notFound
    }
    await chainRunner.pause(chainId: chain.id)
  }
  
  func resumeChain(chainId: String) async throws {
    guard let runId = UUID(uuidString: chainId),
          let chain = activeRunChains[runId] else {
      throw ChainError.notFound
    }
    await chainRunner.resume(chainId: chain.id)
  }
  
  func instructChain(chainId: String, action: String, feedback: String?) async throws {
    guard let runId = UUID(uuidString: chainId),
          let chain = activeRunChains[runId] else {
      throw ChainError.notFound
    }
    
    // The instruct action adds guidance to the chain
    // Actions: "guide" adds guidance, others are no-ops for now
    if let feedback {
      chain.addOperatorGuidance(feedback)
    }
  }
  
  func stepChain(chainId: String) async throws {
    guard let runId = UUID(uuidString: chainId),
          let chain = activeRunChains[runId] else {
      throw ChainError.notFound
    }
    await chainRunner.step(chainId: chain.id)
  }
  
  // MARK: - Templates
  
  func listTemplates() -> [ChainToolTemplate] {
    agentManager.allTemplates.map { template in
      ChainToolTemplate(
        id: template.id.uuidString,
        name: template.name,
        description: template.description,
        category: nil,
        tags: nil
      )
    }
  }
  
  func getTemplate(id: String?, name: String?) -> ChainToolTemplate? {
    let templates = agentManager.allTemplates
    let template: ChainTemplate? = {
      if let id, let uuid = UUID(uuidString: id) {
        return templates.first { $0.id == uuid }
      }
      if let name {
        return templates.first { $0.name.lowercased() == name.lowercased() }
      }
      return nil
    }()
    
    guard let template else { return nil }
    return ChainToolTemplate(
      id: template.id.uuidString,
      name: template.name,
      description: template.description,
      category: nil,
      tags: nil
    )
  }
  
  // MARK: - Queue Management
  
  func queueStatus() -> ChainToolQueueStatus {
    ChainToolQueueStatus(
      running: activeChainRuns,
      queued: chainQueue.count,
      maxConcurrent: maxConcurrentChains,
      pauseNew: false  // Feature not implemented yet
    )
  }
  
  func configureQueue(maxConcurrent: Int?, pauseNew: Bool?) throws {
    if let maxConcurrent {
      guard maxConcurrent > 0 && maxConcurrent <= 10 else {
        throw ChainError.invalidConfiguration("maxConcurrent must be between 1 and 10")
      }
      maxConcurrentChains = maxConcurrent
    }
    // pauseNew feature not implemented yet - silently ignore
  }
  
  func cancelQueued(chainId: String) async throws {
    guard let runId = UUID(uuidString: chainId) else {
      throw ChainError.invalidChainId
    }
    if !cancelQueuedRunInternal(runId: runId) {
      throw ChainError.notFound
    }
  }
  
  // MARK: - Prompt Rules
  
  func getPromptRules() -> PromptRules {
    promptRules
  }
  
  func setPromptRules(_ rules: PromptRules) throws {
    promptRules = rules
  }
  
  // MARK: - Batch Operations
  
  func runBatch(prompts: [ChainToolBatchItem], templateId: String?, templateName: String?) async throws -> [ChainToolRunResult] {
    var results: [ChainToolRunResult] = []

    for item in prompts {
      do {
        let options = ChainToolRunOptions(
          maxPremiumCost: nil,
          requireRag: promptRules.requireRagByDefault,
          skipReview: false,
          dryRun: false,
          returnImmediately: true
        )
        // Per-item templateId/templateName takes precedence over batch-level defaults
        let result = try await startChain(
          prompt: item.prompt,
          repoPath: item.repoPath,
          templateId: item.templateId ?? templateId,
          templateName: item.templateName ?? templateName,
          options: options
        )
        results.append(result)
      } catch {
        results.append(ChainToolRunResult(
          chainId: "",
          status: "error",
          message: error.localizedDescription
        ))
      }
    }

    return results
  }
}
