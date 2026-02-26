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
  var activeSkillCount = 0

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
  ///
  /// - Parameters:
  ///   - text: The user message to send.
  ///   - dataService: DataService for skills/context. May be nil for MCP calls that build their own context.
  ///   - mcpServer: MCPServerService for RAG search. May be nil if RAG is not needed.
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
        let newService = MLXChatService(tier: requestedTier, context: ctx)
        chatService = newService
        serviceTier = requestedTier
        selectedTier = requestedTier

        var loadingMsg = "Loading **\(newService.modelName)** (\(newService.huggingFaceId))..."
        if activeSkillCount > 0 {
          loadingMsg += " with \(activeSkillCount) skill\(activeSkillCount == 1 ? "" : "s")"
        }
        if source == .mcp {
          loadingMsg += " (via MCP)"
        }
        messages.append(ChatMessage(role: .system, content: loadingMsg))
      } else if let service = chatService {
        if let context {
          await service.updateContext(context)
        }
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

      let startTime = Date()
      var tokenCount = 0

      let stream = try await service.sendMessage(text, ragContext: finalRAGContext)
      isLoadingModel = false

      // Update loading message to ready
      if let idx = messages.lastIndex(where: { $0.role == .system }) {
        var readyMsg = "**\(service.modelName)** (\(service.huggingFaceId)) ready"
        if activeSkillCount > 0 {
          readyMsg += " · \(activeSkillCount) skill\(activeSkillCount == 1 ? "" : "s") loaded"
        }
        if source == .mcp {
          readyMsg += " · via MCP"
        }
        messages[idx] = ChatMessage(role: .system, content: readyMsg)
      }

      for await chunk in stream {
        currentStreamText += chunk
        tokenCount += 1
        if tokenCount % 10 == 0 {
          let elapsed = Date().timeIntervalSince(startTime)
          if elapsed > 0 {
            tokensPerSecond = Double(tokenCount) / elapsed
          }
        }
      }

      let elapsed = Date().timeIntervalSince(startTime)
      if elapsed > 0 {
        tokensPerSecond = Double(tokenCount) / elapsed
      }

      let response = currentStreamText
      if !response.isEmpty {
        messages.append(ChatMessage(role: .assistant, content: response))
      }
      currentStreamText = ""
      isGenerating = false

      return (response: response, tokens: tokenCount, elapsed: elapsed)

    } catch {
      self.error = error.localizedDescription
      isGenerating = false
      isLoadingModel = false
      currentStreamText = ""
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
    Task { await chatService?.clearHistory() }
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
