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
    // Pass through PR context
    if let prNumber = options.prNumber {
      arguments["prNumber"] = prNumber
    }
    if let prTitle = options.prTitle {
      arguments["prTitle"] = prTitle
    }
    if let prRepoOwner = options.prRepoOwner {
      arguments["prRepoOwner"] = prRepoOwner
    }
    if let prRepoName = options.prRepoName {
      arguments["prRepoName"] = prRepoName
    }
    if let prHeadRef = options.prHeadRef {
      arguments["prHeadRef"] = prHeadRef
    }
    if let prHtmlURL = options.prHtmlURL {
      arguments["prHtmlURL"] = prHtmlURL
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

  func chainRunResults(runId: String?, chainId: String?, includeOutputs: Bool) -> [[String: Any]] {
    let dataService = self.dataService

    func splitLines(_ value: String) -> [String] {
      value
        .split(whereSeparator: { $0.isNewline })
        .map { String($0) }
        .filter { !$0.isEmpty }
    }

    let formatter = Formatter.iso8601

    var runs: [MCPRunRecord] = []

    if let dataService {
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
        } else if let uuid = UUID(uuidString: chainId) {
          let recent = dataService.getRecentMCPRuns(limit: 5_000)
          if let found = recent.first(where: { $0.id == uuid }) {
            runs = [found]
          }
        }
      }
    }

    // If no persisted MCPRunRecord found, check parallel-routed runs
    if runs.isEmpty, let runner = parallelWorktreeRunner {
      let lookupId: UUID? = {
        if let runId { return UUID(uuidString: runId) }
        if let chainId { return UUID(uuidString: chainId) }
        return nil
      }()
      if let lookupId,
         let parallelRun = runner.findRunBySourceChainRunId(lookupId) ?? runner.runs.first(where: { $0.id == lookupId }) {
        let payload = parallelRunToResultPayload(parallelRun, sourceRunId: lookupId, includeOutputs: includeOutputs, formatter: formatter)
        return [payload]
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

      if let dataService, !run.chainId.isEmpty {
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

  /// Synthesize a results payload from a parallel-routed run (no MCPRunRecord persisted).
  private func parallelRunToResultPayload(
    _ run: ParallelWorktreeRun,
    sourceRunId: UUID,
    includeOutputs: Bool,
    formatter: ISO8601DateFormatter
  ) -> [String: Any] {
    let execution = run.executions.first
    let isSuccess: Bool = {
      switch run.status {
      case .completed, .awaitingReview: return true
      default: return false
      }
    }()

    var payload: [String: Any] = [
      "runId": sourceRunId.uuidString,
      "chainId": run.id.uuidString,
      "templateName": run.templateName ?? "Unknown",
      "prompt": execution?.task.prompt ?? "",
      "workingDirectory": run.projectPath,
      "implementerBranches": [execution?.branchName].compactMap { $0 },
      "implementerWorkspacePaths": [execution?.worktreePath].compactMap { $0 },
      "success": isSuccess,
      "errorMessage": {
        if case .failed(let msg) = run.status { return msg as Any }
        return NSNull()
      }(),
      "status": run.status.displayName(kind: run.kind, prContext: run.prContext),
      "filesChanged": execution?.filesChanged ?? 0,
      "insertions": execution?.insertions ?? 0,
      "deletions": execution?.deletions ?? 0,
      "diffSummary": execution?.diffSummary as Any,
      "createdAt": formatter.string(from: run.createdAt)
    ]

    // Synthesize step results from chain step summaries
    if let execution {
      payload["results"] = execution.chainStepResults.map { step in
        var resultPayload: [String: Any] = [
          "agentId": step.id.uuidString,
          "agentName": step.stepName,
          "model": step.model,
          "prompt": "",
          "premiumCost": step.premiumCost,
          "reviewVerdict": step.reviewVerdict as Any
        ]
        if includeOutputs {
          resultPayload["output"] = step.outputPreview
        }
        return resultPayload
      }
      if execution.chainStepResults.isEmpty, includeOutputs, !execution.output.isEmpty {
        payload["results"] = [[
          "agentName": "Implementer",
          "model": "unknown",
          "output": execution.output,
          "premiumCost": 0
        ] as [String: Any]]
      }
    }

    return payload
  }

  func aggregateAuditFindings(limit: Int, top: Int, promptContains: String?) -> [String: Any] {
    guard let dataService else {
      return [
        "runsAnalyzed": 0,
        "parsedFindings": 0,
        "dedupedFindings": 0,
        "topFindings": [],
        "markdown": "No data service available."
      ]
    }

    struct Finding {
      let title: String
      let area: String
      let impact: String
      let effort: String
      let confidence: Double
      let files: [String]
      let recommendation: String
      let score: Double
    }

    let runFetchLimit = max(limit * 25, 400)
    let recentRuns = dataService.getRecentMCPRuns(limit: runFetchLimit)
    let normalizedPromptFilter = promptContains?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let defaultNeedles = ["optimization audit #", "global pass"]

    let filteredRuns = recentRuns.filter { run in
      let prompt = run.prompt.lowercased()
      if let normalizedPromptFilter, !normalizedPromptFilter.isEmpty {
        return prompt.contains(normalizedPromptFilter)
      }
      return defaultNeedles.contains { prompt.contains($0) }
    }

    let selectedRuns = Array(filteredRuns.prefix(max(1, limit)))
    var allFindings: [Finding] = []

    for run in selectedRuns {
      guard !run.chainId.isEmpty else { continue }
      let runResults = dataService.getMCPRunResults(chainId: run.chainId)
      for result in runResults {
        guard let outputJSON = extractFirstJSONObject(from: result.output),
              let findingObjects = outputJSON["findings"] as? [[String: Any]] else {
          continue
        }

        let area = normalizeArea(outputJSON["area"] as? String, promptFallback: run.prompt)

        for findingObject in findingObjects {
          let title = ((findingObject["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? (findingObject["title"] as? String ?? "")
            : "Untitled finding"
          let impact = normalizeBucket(findingObject["impact"], defaultValue: "med")
          let effort = normalizeBucket(findingObject["effort"], defaultValue: "med")
          let confidence = normalizeConfidence(findingObject["confidence"])
          let files = normalizeFiles(findingObject["files"])
          let recommendation = (findingObject["recommendation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

          let impactWeight: [String: Double] = ["low": 1, "med": 2, "medium": 2, "high": 3]
          let effortWeight: [String: Double] = ["low": 1, "med": 2, "medium": 2, "high": 3]
          let score = (impactWeight[impact] ?? 2) * 2 + (4 - (effortWeight[effort] ?? 2)) + confidence

          allFindings.append(Finding(
            title: title,
            area: area,
            impact: impact,
            effort: effort,
            confidence: confidence,
            files: files,
            recommendation: recommendation,
            score: score
          ))
        }
      }
    }

    var deduped: [String: Finding] = [:]
    for finding in allFindings {
      let key = "\(finding.title.lowercased())|\(finding.files.prefix(3).joined(separator: "|"))"
      if let existing = deduped[key], existing.score >= finding.score {
        continue
      }
      deduped[key] = finding
    }

    let ranked = deduped.values.sorted { $0.score > $1.score }
    let topFindings = Array(ranked.prefix(max(1, top)))

    let topPayload: [[String: Any]] = topFindings.map { finding in
      [
        "title": finding.title,
        "area": finding.area,
        "impact": finding.impact,
        "effort": finding.effort,
        "confidence": finding.confidence,
        "files": finding.files,
        "recommendation": finding.recommendation,
        "score": finding.score
      ]
    }

    var lines: [String] = []
    lines.append("Automated aggregation update (20 free-agent optimization audit)")
    lines.append("")
    lines.append("- Runs analyzed: \(selectedRuns.count)")
    lines.append("- Parsed findings: \(allFindings.count)")
    lines.append("- Deduped findings: \(ranked.count)")
    lines.append("")
    lines.append("## Top \(topFindings.count) Opportunities (ranked)")

    for (index, finding) in topFindings.enumerated() {
      let confidenceText = String(format: "%.2f", finding.confidence)
      lines.append("\(index + 1). **\(finding.title)**")
      lines.append("   - Area: \(finding.area)")
      lines.append("   - Impact/Effort/Confidence: \(finding.impact)/\(finding.effort)/\(confidenceText)")
      lines.append("   - Files: \(finding.files.isEmpty ? "n/a" : finding.files.prefix(4).joined(separator: ", "))")
      if !finding.recommendation.isEmpty {
        lines.append("   - Recommendation: \(String(finding.recommendation.prefix(220)))")
      }
    }

    lines.append("")
    lines.append("## Next Actions")
    lines.append("- Review top findings and mark accepted items.")
    lines.append("- Create one implementation issue per accepted finding and link each back to tracker issue.")

    return [
      "runsAnalyzed": selectedRuns.count,
      "parsedFindings": allFindings.count,
      "dedupedFindings": ranked.count,
      "topFindings": topPayload,
      "markdown": lines.joined(separator: "\n")
    ]
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

private extension MCPServerService {
  func extractFirstJSONObject(from text: String) -> [String: Any]? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    var depth = 0
    var current = start

    while current < text.endIndex {
      let character = text[current]
      if character == "{" {
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0 {
          let candidate = String(text[start...current])
          guard let data = candidate.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
          }
          return json
        }
      }
      current = text.index(after: current)
    }

    return nil
  }

  func normalizeBucket(_ value: Any?, defaultValue: String) -> String {
    guard let text = value as? String else { return defaultValue }
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "medium" { return "med" }
    if ["low", "med", "high"].contains(normalized) { return normalized }
    return defaultValue
  }

  func normalizeConfidence(_ value: Any?) -> Double {
    if let number = value as? Double { return min(max(number, 0), 1) }
    if let number = value as? NSNumber { return min(max(number.doubleValue, 0), 1) }
    if let text = value as? String, let number = Double(text) { return min(max(number, 0), 1) }
    return 0.5
  }

  func normalizeFiles(_ value: Any?) -> [String] {
    guard let rawFiles = value as? [Any] else { return [] }
    return rawFiles.compactMap { item in
      if let text = item as? String {
        if let parsed = parseJSONObjectString(text), let normalized = extractPathPatterns(from: parsed), !normalized.isEmpty {
          return normalized.joined(separator: ", ")
        }
        return text
      }
      if let object = item as? [String: Any],
         let normalized = extractPathPatterns(from: object), !normalized.isEmpty {
        return normalized.joined(separator: ", ")
      }
      if let object = item as? [String: Any],
         let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
         let text = String(data: data, encoding: .utf8) {
        return text
      }
      return nil
    }
  }

  func normalizeArea(_ area: String?, promptFallback: String) -> String {
    if let area {
      let normalized = area.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty {
        let firstLine = normalized.split(separator: "\n").first.map(String.init) ?? normalized
        if !firstLine.lowercased().contains("always follow best practices") {
          return firstLine
        }
      }
    }

    if let startRange = promptFallback.range(of: "Optimization audit #") {
      let suffix = String(promptFallback[startRange.lowerBound...])
      let line = suffix.split(separator: "\n").first.map(String.init) ?? suffix
      return String(line.prefix(120))
    }

    return String(promptFallback.prefix(120))
  }

  func parseJSONObjectString(_ value: String) -> [String: Any]? {
    guard let data = value.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return json
  }

  func extractPathPatterns(from object: [String: Any]) -> [String]? {
    if let patterns = object["path_patterns"] as? [String], !patterns.isEmpty {
      return patterns
    }
    return nil
  }
}
