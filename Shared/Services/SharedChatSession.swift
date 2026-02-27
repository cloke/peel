//
//  SharedChatSession.swift
//  Peel
//
//  Shared observable chat session that bridges MCP tool calls and the LocalChatView UI.
//  Both the MCP handler and the UI read/write to this single session, ensuring
//  all messages (from either source) appear in the conversation and the UI reflects
//  MCP-initiated chats in real time.
//
//  Created on 2/26/26.
//

#if os(macOS)
import Foundation
import SwiftUI

// MARK: - Shared Chat Session

@MainActor
@Observable
final class SharedChatSession {

  // MARK: - Observable State

  var messages: [ChatMessage] = []
  var isGenerating = false
  var currentStreamText = ""
  var tokensPerSecond: Double = 0
  var isLoadingModel = false
  var error: String?
  var ragSnippetCount = 0
  var useRAG = true
  var useToolCalling = true
  var activeSkillCount = 0
  var activeToolRound = 0

  // Model configuration
  var selectedTier: MLXEditorModelTier = .auto
  var selectedRepoPath: String?

  // MARK: - Internal State

  private(set) var chatService: MLXChatService?
  private var generationTask: Task<Void, Never>?

  /// Tracks whether the service was created with the current tier
  private var serviceTier: MLXEditorModelTier?

  enum Source: String, Sendable {
    case ui
    case mcp
  }

  // MARK: - Computed Properties

  var modelStatusText: String {
    if isLoadingModel { return "Loading model..." }
    if let service = chatService {
      var status = "\(service.modelName) (\(service.tier.rawValue)) ready"
      if activeSkillCount > 0 {
        status += " · \(activeSkillCount) skill\(activeSkillCount == 1 ? "" : "s")"
      }
      return status
    }
    let rec = MLXEditorModelConfig.recommendedModel()
    return "Will load: \(rec.name) (\(rec.huggingFaceId))"
  }

  var isModelLoaded: Bool { chatService != nil }

  // MARK: - Context Building

  func buildContext(dataService: DataService?, repoPath: String? = nil) -> ChatContext {
    let effectiveRepoPath = repoPath ?? selectedRepoPath
    guard let dataService, let repoPath = effectiveRepoPath else { return .empty }

    var context = ChatContext()

    // Auto-seed Ember skills if needed
    let seededCount = DefaultSkillsService.autoSeedEmberSkillsIfNeeded(
      context: dataService.modelContext,
      repoPath: repoPath
    )
    if seededCount > 0 {
      print("[SharedChat] Auto-seeded \(seededCount) Ember skills for \(repoPath)")
    }

    let repoRemoteURL = RepoRegistry.shared.getCachedRemoteURL(for: repoPath)
    if let (skillsBlock, skills) = dataService.repoGuidanceSkillsBlock(
      repoPath: repoPath,
      repoRemoteURL: repoRemoteURL
    ) {
      context.skills = skillsBlock
      activeSkillCount = skills.count
      dataService.markRepoGuidanceSkillsApplied(skills)
    } else {
      activeSkillCount = 0
    }

    let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
    context.repoInfo = "Repository: \(repoName)\nPath: \(repoPath)"
    return context
  }

  // MARK: - Model Management

  func switchModel(to tier: MLXEditorModelTier) {
    guard tier != selectedTier || chatService == nil else { return }
    selectedTier = tier
    let oldService = chatService
    chatService = nil
    serviceTier = nil
    if let oldService {
      Task { await oldService.unload() }
    }
  }

  func setRepo(_ repoPath: String?, dataService: DataService?) {
    selectedRepoPath = repoPath
    let context = buildContext(dataService: dataService)
    if let service = chatService {
      Task { await service.updateContext(context) }
    }
  }

  func unloadModel() {
    // Cancel any in-flight generation first
    generationTask?.cancel()
    generationTask = nil

    // Reset all generation state so future send() calls aren't blocked
    isGenerating = false
    isLoadingModel = false
    currentStreamText = ""
    activeToolRound = 0

    Task {
      await chatService?.unload()
      chatService = nil
      serviceTier = nil
    }
  }

  // MARK: - RAG Context Retrieval

  func fetchRAGContext(query: String, mcpServer: MCPServerService?) async -> String? {
    guard useRAG, let mcpServer, let repoPath = selectedRepoPath else { return nil }

    do {
      let results = try await mcpServer.runRagSearch(
        query: query,
        mode: .hybrid,
        repoPath: repoPath,
        limit: 5,
        matchAll: false,
        recordHints: false
      )

      guard !results.isEmpty else { return nil }
      ragSnippetCount = results.count

      let formatted = results.map { result in
        let header = "### \(result.filePath)" +
          (result.constructName != nil ? " — \(result.constructName!)" : "") +
          " (L\(result.startLine)-\(result.endLine))"
        let snippet = result.snippet
          .split(separator: "\n")
          .prefix(30)
          .joined(separator: "\n")
        return "\(header)\n```\n\(snippet)\n```"
      }

      return formatted.joined(separator: "\n\n")
    } catch {
      print("[SharedChat] RAG search failed: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Send Message

  /// Send a message through the shared chat service.
  /// Both MCP and UI callers use this. Updates all observable state in real time.
  /// When tool calling is enabled, the model can invoke rag_search, dispatch_chain,
  /// and chain_status tools — executing them and feeding results back automatically.
  ///
  /// - Parameters:
  ///   - text: The user message to send.
  ///   - dataService: DataService for skills/context. May be nil for MCP calls that build their own context.
  ///   - mcpServer: MCPServerService for RAG search and chain dispatch. May be nil if tools are not needed.
  ///   - context: Pre-built context (MCP handler builds its own). If nil, auto-built from dataService.
  ///   - ragContext: Pre-fetched RAG context. If nil and useRAG is true, auto-fetched.
  ///   - tier: Override tier for this call. If nil, uses selectedTier.
  ///   - clearHistory: Clear conversation history before sending.
  ///   - source: Who initiated this message (ui or mcp).
  /// - Returns: The full response, token count, and elapsed seconds.
  @discardableResult
  func send(
    _ text: String,
    dataService: DataService?,
    mcpServer: MCPServerService?,
    context: ChatContext? = nil,
    ragContext: String? = nil,
    tier: MLXEditorModelTier? = nil,
    clearHistory: Bool = false,
    source: Source = .ui
  ) async throws -> (response: String, tokens: Int, elapsed: Double) {
    guard !isGenerating else {
      throw SharedChatError.alreadyGenerating
    }

    let requestedTier = tier ?? selectedTier

    // Append user message to observable list
    messages.append(ChatMessage(role: .user, content: text))
    isGenerating = true
    error = nil
    currentStreamText = ""
    tokensPerSecond = 0
    ragSnippetCount = 0
    activeToolRound = 0

    do {
      // Create or reconfigure service
      let needsNewService = chatService == nil || requestedTier != serviceTier
      if needsNewService {
        if let old = chatService {
          print("[SharedChat] Unloading previous model (was \(serviceTier?.rawValue ?? "nil"), now \(requestedTier.rawValue))")
          await old.unload()
        }
        isLoadingModel = true
        let ctx = context ?? buildContext(dataService: dataService)
        let toolsActive = useToolCalling && mcpServer != nil
        let newService = MLXChatService(tier: requestedTier, context: ctx, toolsEnabled: toolsActive)
        chatService = newService
        serviceTier = requestedTier
        selectedTier = requestedTier

        var loadingMsg = "Loading **\(newService.modelName)** (\(newService.huggingFaceId))..."
        if activeSkillCount > 0 {
          loadingMsg += " with \(activeSkillCount) skill\(activeSkillCount == 1 ? "" : "s")"
        }
        if toolsActive {
          loadingMsg += " · tools enabled"
        }
        if source == .mcp {
          loadingMsg += " (via MCP)"
        }
        messages.append(ChatMessage(role: .system, content: loadingMsg))
      } else if let service = chatService {
        if let context {
          await service.updateContext(context)
        }
        // Update tool-use instructions in system prompt
        await service.setToolsEnabled(useToolCalling && mcpServer != nil)
        if clearHistory {
          await service.clearHistory()
          print("[SharedChat] Cleared conversation history")
        }
      }

      guard let service = chatService else {
        isGenerating = false
        isLoadingModel = false
        throw SharedChatError.serviceCreationFailed
      }

      // Fetch RAG context if not provided and RAG is enabled
      let finalRAGContext: String?
      if let ragContext {
        finalRAGContext = ragContext
      } else {
        finalRAGContext = await fetchRAGContext(query: text, mcpServer: mcpServer)
      }

      // Build tool specs if tool calling is enabled and we have an MCP server
      let toolSpecs: [[String: any Sendable]]? = (useToolCalling && mcpServer != nil)
        ? Self.chatToolSpecs
        : nil

      let startTime = Date()
      var totalTokenCount = 0
      var finalResponse = ""

      // Initial generation
      var events = try await service.sendMessage(text, ragContext: finalRAGContext, tools: toolSpecs)
      isLoadingModel = false

      // Update loading message to ready
      if let idx = messages.lastIndex(where: { $0.role == .system }) {
        var readyMsg = "**\(service.modelName)** (\(service.huggingFaceId)) ready"
        if activeSkillCount > 0 {
          readyMsg += " · \(activeSkillCount) skill\(activeSkillCount == 1 ? "" : "s") loaded"
        }
        if useToolCalling && toolSpecs != nil {
          readyMsg += " · tools enabled"
        }
        if source == .mcp {
          readyMsg += " · via MCP"
        }
        messages[idx] = ChatMessage(role: .system, content: readyMsg)
      }

      // Tool call loop — model can invoke tools up to maxToolRounds times,
      // then a final generation without tools forces a text-only summary.
      let maxToolRounds = 3
      let hardCap = maxToolRounds + 2 // safety: absolute max iterations
      var toolRound = 0
      var iteration = 0
      var forcedTextOnly = false // true after synthesis prompt sent

      toolLoop: while iteration < hardCap {
        iteration += 1
        var accumulatedText = ""
        var detectedToolCall: ChatToolCall?

        for await event in events {
          switch event {
          case .text(let chunk):
            accumulatedText += chunk
            currentStreamText += chunk
            totalTokenCount += 1
            if totalTokenCount % 10 == 0 {
              let elapsed = Date().timeIntervalSince(startTime)
              if elapsed > 0 {
                tokensPerSecond = Double(totalTokenCount) / elapsed
              }
            }
          case .toolCall(let call):
            if forcedTextOnly {
              // Model hallucinated a tool call after synthesis prompt — ignore it
              print("[SharedChat] Ignoring hallucinated tool call after synthesis: \(call.name)")
            } else {
              detectedToolCall = call
              print("[SharedChat] Tool call detected (round \(toolRound + 1)): \(call.name)(\(call.arguments))")
            }
          }
        }

        guard let toolCall = detectedToolCall else {
          // No tool call — generation is complete
          finalResponse = currentStreamText
          break toolLoop
        }

        // Save the text before the tool call as a partial message
        if !accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          messages.append(ChatMessage(role: .assistant, content: accumulatedText))
        }

        // Show tool call in UI
        activeToolRound = toolRound + 1
        messages.append(ChatMessage(role: .toolCall, content: toolCall.displaySummary))

        // Execute the tool
        let toolResult = await executeTool(toolCall, mcpServer: mcpServer)

        // Show abbreviated result in UI
        let displayResult = toolResult.count > 500
          ? String(toolResult.prefix(500)) + "... (\(toolResult.count) chars)"
          : toolResult
        messages.append(ChatMessage(role: .toolResult, content: displayResult))

        // Record in service conversation history and continue
        await service.recordToolCallAndResult(
          assistantText: accumulatedText,
          toolCallMarker: toolCall.asToolCallMarker(),
          toolResult: toolResult
        )

        toolRound += 1
        currentStreamText = ""

        if toolRound >= maxToolRounds {
          // Max tool rounds reached — final generation with synthesis instruction
          // Disable tool instructions in system prompt so model focuses on answering
          await service.setToolsEnabled(false)
          forcedTextOnly = true
          print("[SharedChat] Tool round \(toolRound)/\(maxToolRounds) — forcing final text-only response")
          events = try await service.continueWithInstruction(
            "You have completed your tool calls. Now synthesize the information from the results above into a clear, concise answer to the original question. Do not call any more tools — just provide your analysis and answer directly.",
            tools: nil
          )
          // Loop back to consume the final no-tools generation
        } else {
          events = try await service.continueAfterTool(tools: toolSpecs)
        }
      }

      let elapsed = Date().timeIntervalSince(startTime)
      if elapsed > 0 {
        tokensPerSecond = Double(totalTokenCount) / elapsed
      }

      // Re-enable tools for future calls if they were disabled for final generation
      if toolRound >= maxToolRounds {
        await service.setToolsEnabled(useToolCalling && mcpServer != nil)
      }

      // Strip any stray <tool_call>...</tool_call> XML from the final response
      finalResponse = Self.stripToolCallXML(finalResponse)

      if finalResponse.isEmpty && toolRound > 0 {
        // Model used all tool rounds but never produced a final text response.
        // Use the accumulated tool results summary as a fallback.
        finalResponse = "[Used \(toolRound) tool call\(toolRound == 1 ? "" : "s") but model did not produce a final summary. Check the tool results above.]"
        print("[SharedChat] Warning: empty final response after \(toolRound) tool rounds")
      }

      if !finalResponse.isEmpty {
        messages.append(ChatMessage(role: .assistant, content: finalResponse))
      }
      currentStreamText = ""
      isGenerating = false
      activeToolRound = 0

      return (response: finalResponse, tokens: totalTokenCount, elapsed: elapsed)

    } catch {
      self.error = error.localizedDescription
      isGenerating = false
      isLoadingModel = false
      currentStreamText = ""
      activeToolRound = 0
      throw error
    }
  }

  // MARK: - Fire-and-Forget Send (for UI callers)

  /// Non-throwing version that wraps send() in a Task, suitable for button actions.
  func sendFromUI(
    _ text: String,
    dataService: DataService?,
    mcpServer: MCPServerService?
  ) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isGenerating else { return }

    generationTask = Task {
      do {
        try await send(
          trimmed,
          dataService: dataService,
          mcpServer: mcpServer,
          source: .ui
        )
      } catch is CancellationError {
        // Expected when user stops generation
      } catch {
        // Error already set in send()
        print("[SharedChat] Send error: \(error.localizedDescription)")
      }
    }
  }

  func stop() {
    generationTask?.cancel()
    generationTask = nil
    if !currentStreamText.isEmpty {
      messages.append(ChatMessage(role: .assistant, content: currentStreamText + " [stopped]"))
      currentStreamText = ""
    }
    isGenerating = false
  }

  func clearChat() {
    messages.removeAll()
    currentStreamText = ""
    error = nil
    ragSnippetCount = 0
    activeToolRound = 0
    Task { await chatService?.clearHistory() }
  }

  // MARK: - Tool Schemas

  /// OpenAI-style function specs for the tools available to the local chat model.
  /// These are passed to the model via UserInput.tools so it knows what it can call.
  static let chatToolSpecs: [[String: any Sendable]] = [
    [
      "type": "function",
      "function": [
        "name": "rag_search",
        "description": "Search the local code index for relevant code snippets. Use this to investigate code, find implementations, understand architecture, or answer questions about the codebase before making recommendations.",
        "parameters": [
          "type": "object",
          "properties": [
            "query": [
              "type": "string",
              "description": "Natural language search query describing what code you are looking for",
            ] as [String: any Sendable],
            "mode": [
              "type": "string",
              "enum": ["vector", "text", "hybrid"],
              "description": "Search mode: 'vector' for semantic/conceptual search, 'text' for exact keyword match, 'hybrid' for both combined. Default: hybrid",
            ] as [String: any Sendable],
          ] as [String: any Sendable],
          "required": ["query"],
        ] as [String: any Sendable],
      ] as [String: any Sendable],
    ] as [String: any Sendable],
    [
      "type": "function",
      "function": [
        "name": "dispatch_chain",
        "description": "Dispatch a coding task to a cloud agent chain running in an isolated git worktree. Use this for implementation tasks that require real code changes — refactoring, adding features, fixing bugs. The chain handles planning, implementation, and review automatically. Returns immediately with a chain ID for tracking.",
        "parameters": [
          "type": "object",
          "properties": [
            "prompt": [
              "type": "string",
              "description": "Detailed prompt describing the implementation task. Be specific about what to change and why.",
            ] as [String: any Sendable],
            "repoPath": [
              "type": "string",
              "description": "Absolute path to the repository to work in",
            ] as [String: any Sendable],
            "templateName": [
              "type": "string",
              "description": "Optional chain template name (e.g. 'Quick Fix', 'Feature Implementation'). Omit to use the default.",
            ] as [String: any Sendable],
          ] as [String: any Sendable],
          "required": ["prompt", "repoPath"],
        ] as [String: any Sendable],
      ] as [String: any Sendable],
    ] as [String: any Sendable],
    [
      "type": "function",
      "function": [
        "name": "chain_status",
        "description": "Check the status of a previously dispatched chain. Returns whether it is running, completed, failed, or waiting for review, along with progress details.",
        "parameters": [
          "type": "object",
          "properties": [
            "chainId": [
              "type": "string",
              "description": "The chain UUID returned by dispatch_chain",
            ] as [String: any Sendable],
          ] as [String: any Sendable],
          "required": ["chainId"],
        ] as [String: any Sendable],
      ] as [String: any Sendable],
    ] as [String: any Sendable],
  ]

  // MARK: - Response Cleanup

  /// Strip any <tool_call>...</tool_call> and <think>...</think> XML from a response string.
  /// The model may hallucinate tool calls even when tools are disabled,
  /// and thinking blocks should not appear in the final visible response.
  private static func stripToolCallXML(_ text: String) -> String {
    var result = text
    // Remove complete tool call blocks
    while let startRange = result.range(of: "<tool_call>") {
      if let endRange = result.range(of: "</tool_call>", range: startRange.upperBound..<result.endIndex) {
        result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
      } else {
        // Incomplete tool call — remove from start tag to end
        result.removeSubrange(startRange.lowerBound..<result.endIndex)
      }
    }
    // Remove thinking blocks
    while let startRange = result.range(of: "<think>") {
      if let endRange = result.range(of: "</think>", range: startRange.upperBound..<result.endIndex) {
        result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
      } else {
        result.removeSubrange(startRange.lowerBound..<result.endIndex)
      }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Tool Execution

  /// Execute a tool call from the model and return the result as a JSON string.
  private func executeTool(_ toolCall: ChatToolCall, mcpServer: MCPServerService?) async -> String {
    print("[SharedChat] Executing tool: \(toolCall.name) with args: \(toolCall.arguments)")

    switch toolCall.name {
    case "rag_search":
      return await executeRagSearch(toolCall.arguments, mcpServer: mcpServer)
    case "dispatch_chain":
      return await executeDispatchChain(toolCall.arguments, mcpServer: mcpServer)
    case "chain_status":
      return await executeChainStatus(toolCall.arguments, mcpServer: mcpServer)
    default:
      return "{\"error\": \"Unknown tool: \(toolCall.name)\"}"
    }
  }

  /// Execute rag_search tool — search the local code index
  private func executeRagSearch(_ args: [String: String], mcpServer: MCPServerService?) async -> String {
    guard let mcpServer else {
      return "{\"error\": \"MCP server not available for RAG search\"}"
    }
    guard let query = args["query"], !query.isEmpty else {
      return "{\"error\": \"Missing required parameter: query\"}"
    }

    let modeStr = args["mode"] ?? "hybrid"
    let mode: MCPServerService.RAGSearchMode = switch modeStr {
    case "vector": .vector
    case "text": .text
    default: .hybrid
    }

    let repoPath = selectedRepoPath

    do {
      let results = try await mcpServer.runRagSearch(
        query: query,
        mode: mode,
        repoPath: repoPath,
        limit: 5,
        matchAll: false,
        recordHints: false
      )

      guard !results.isEmpty else {
        return "{\"results\": [], \"count\": 0, \"message\": \"No results found for query: \(query)\"}"
      }

      ragSnippetCount = results.count

      // Format as structured JSON for the model
      let formatted = results.map { result -> [String: Any] in
        let snippet = result.snippet
          .split(separator: "\n")
          .prefix(30)
          .joined(separator: "\n")
        var entry: [String: Any] = [
          "filePath": result.filePath,
          "startLine": result.startLine,
          "endLine": result.endLine,
          "snippet": snippet,
        ]
        if let name = result.constructName {
          entry["constructName"] = name
        }
        return entry
      }

      let payload: [String: Any] = [
        "results": formatted,
        "count": results.count,
        "query": query,
        "mode": modeStr,
      ]

      if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
         let json = String(data: data, encoding: .utf8) {
        return json
      }
      return "{\"results\": [], \"error\": \"Failed to serialize results\"}"

    } catch {
      return "{\"error\": \"RAG search failed: \(error.localizedDescription)\"}"
    }
  }

  /// Execute dispatch_chain tool — start a chain in a worktree
  private func executeDispatchChain(_ args: [String: String], mcpServer: MCPServerService?) async -> String {
    guard let mcpServer else {
      return "{\"error\": \"MCP server not available for chain dispatch\"}"
    }
    guard let prompt = args["prompt"], !prompt.isEmpty else {
      return "{\"error\": \"Missing required parameter: prompt\"}"
    }
    guard let repoPath = args["repoPath"], !repoPath.isEmpty else {
      return "{\"error\": \"Missing required parameter: repoPath\"}"
    }

    let templateName = args["templateName"]

    do {
      // Use the chain tools handler delegate to start a chain with returnImmediately
      let result = try await mcpServer.startChain(
        prompt: prompt,
        repoPath: repoPath,
        templateId: nil,
        templateName: templateName,
        options: ChainToolRunOptions(
          maxPremiumCost: nil,
          requireRag: false,
          skipReview: false,
          dryRun: false,
          returnImmediately: true
        )
      )

      let payload: [String: Any] = [
        "chainId": result.chainId,
        "status": result.status,
        "message": result.message,
      ]

      if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
         let json = String(data: data, encoding: .utf8) {
        return json
      }
      return "{\"chainId\": \"\(result.chainId)\", \"status\": \"\(result.status)\"}"

    } catch {
      return "{\"error\": \"Chain dispatch failed: \(error.localizedDescription)\"}"
    }
  }

  /// Execute chain_status tool — check status of a dispatched chain
  private func executeChainStatus(_ args: [String: String], mcpServer: MCPServerService?) async -> String {
    guard let mcpServer else {
      return "{\"error\": \"MCP server not available\"}"
    }
    guard let chainId = args["chainId"], !chainId.isEmpty else {
      return "{\"error\": \"Missing required parameter: chainId\"}"
    }

    guard let status = mcpServer.chainStatus(chainId: chainId) else {
      return "{\"error\": \"Chain not found: \(chainId)\"}"
    }

    var payload: [String: Any] = [
      "chainId": status.chainId,
      "status": status.status,
      "progress": status.progress,
      "currentStep": status.currentStep,
      "totalSteps": status.totalSteps,
    ]
    if let error = status.error {
      payload["error"] = error
    }
    if let reviewGate = status.reviewGate {
      payload["reviewGate"] = reviewGate
    }
    if let startedAt = status.startedAt {
      payload["startedAt"] = ISO8601DateFormatter().string(from: startedAt)
    }

    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
      return json
    }
    return "{\"chainId\": \"\(chainId)\", \"status\": \"\(status.status)\"}"
  }
}

// MARK: - Errors

enum SharedChatError: LocalizedError {
  case alreadyGenerating
  case serviceCreationFailed

  var errorDescription: String? {
    switch self {
    case .alreadyGenerating: return "A message is already being generated"
    case .serviceCreationFailed: return "Failed to create chat service"
    }
  }
}

#endif
