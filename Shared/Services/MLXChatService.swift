//
//  MLXChatService.swift
//  Peel
//
//  Simple chat service wrapping MLX LLM models for interactive conversation.
//  Shares model tiers with MLXCodeEditor but uses a conversational system prompt.
//
//  Created on 2/10/26.
//

#if os(macOS)
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Chat Message

struct ChatMessage: Identifiable, Sendable {
  let id: UUID
  let role: Role
  let content: String
  let timestamp: Date

  enum Role: String, Sendable {
    case user
    case assistant
    case system
    case toolCall     // Model requested a tool call
    case toolResult   // Result from executing a tool
  }

  init(role: Role, content: String) {
    self.id = UUID()
    self.role = role
    self.content = content
    self.timestamp = Date()
  }
}

// MARK: - Chat Stream Events

/// Events emitted by the chat service during generation.
/// Supports both regular text streaming and tool call detection.
enum ChatStreamEvent: Sendable {
  /// A text chunk from the model
  case text(String)
  /// The model requested a tool call
  case toolCall(ChatToolCall)
}

/// Represents a tool call detected in the model's generation output.
struct ChatToolCall: Sendable {
  let name: String
  let arguments: [String: String]

  /// Reconstruct the tool call in XML function format for conversation history.
  /// This format matches what Qwen3 Coder models expect when replaying tool call history.
  /// Format: <tool_call><function=name><parameter=key>value</parameter></function></tool_call>
  func asToolCallMarker() -> String {
    var marker = "\n<tool_call>\n<function=\(name)>\n"
    for (key, value) in arguments.sorted(by: { $0.key < $1.key }) {
      marker += "<parameter=\(key)>\n\(value)\n</parameter>\n"
    }
    marker += "</function>\n</tool_call>"
    return marker
  }

  /// Human-readable summary for display in the UI
  var displaySummary: String {
    let argsList = arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    return "\(name)(\(argsList))"
  }
}

// MARK: - Chat Context

/// Extensible context container for injecting knowledge into chat sessions.
/// Modeled after Copilot's approach — skills, files, instructions, etc. can be
/// composed and injected into the system prompt without the service knowing the details.
struct ChatContext: Sendable {
  /// Repo-scoped skills (ember best practices, project conventions, etc.)
  var skills: String?

  /// Custom instructions from the user (like Copilot's .github/copilot-instructions.md)
  var instructions: String?

  /// File context — contents or summaries of referenced files
  var fileContext: String?

  /// RAG-retrieved context — code snippets fetched via vector search for the current query
  var ragContext: String?

  /// Repo metadata (name, path, tech stack)
  var repoInfo: String?

  /// Whether any context is present
  var isEmpty: Bool {
    skills == nil && instructions == nil && fileContext == nil && ragContext == nil && repoInfo == nil
  }

  /// Combine all context blocks into one prompt section.
  /// Instructions come first (directive rules), then project context, then skills (reference).
  func buildPromptSection() -> String? {
    var sections: [String] = []

    if let instructions {
      sections.append("## Critical Rules\n\n\(instructions)")
    }
    if let repoInfo {
      sections.append("## Project Context\n\n\(repoInfo)")
    }
    if let skills {
      sections.append(skills) // Already formatted as "## Repo Skills\n\n..."
    }
    if let ragContext {
      sections.append("## Relevant Code (from local RAG index)\n\n\(ragContext)")
    }
    if let fileContext {
      sections.append("## Referenced Files\n\n\(fileContext)")
    }

    guard !sections.isEmpty else { return nil }
    return sections.joined(separator: "\n\n---\n\n")
  }

  static let empty = ChatContext()
}

// MARK: - Chat Service Actor

/// Interactive chat service using local MLX LLM models.
/// Maintains conversation history and streams token-by-token responses.
actor MLXChatService {
  private var modelContainer: ModelContainer?
  private let config: MLXEditorModelConfig
  private var isLoaded = false
  private var conversationHistory: [Chat.Message] = []
  private var context: ChatContext
  private var toolsEnabled = false

  nonisolated let modelName: String
  nonisolated let tier: MLXEditorModelTier
  nonisolated let huggingFaceId: String

  private static func buildSystemMessage(config: MLXEditorModelConfig, context: ChatContext = .empty, toolsEnabled: Bool = false) -> String {
    var prompt = """
    You are \(config.name), a local coding assistant running on the user's Mac via MLX.
    Model: \(config.name) (\(config.huggingFaceId)), \(config.tier.rawValue) tier.
    You have expertise in Swift, SwiftUI, Python, Rust, and general software engineering.
    Keep responses concise and practical. Use code blocks with language tags when showing code.
    You can help with: code review, debugging, architecture advice, refactoring suggestions,
    explaining concepts, and general programming questions.
    """

    if toolsEnabled {
      prompt += """
      \n
      IMPORTANT: You have tools available. When the user asks about code, repositories,
      or wants something implemented, you MUST use your tools to take action. Do NOT just
      describe what you would do — actually call the function.

      - Use rag_search to find and read code before answering questions about a codebase.
      - Use dispatch_chain to send implementation tasks to an agent in a git worktree.
      - Use chain_status to check progress of dispatched chains.

      Always search first, then answer based on what you find. Never say "I would search"
      or "I will look" — instead, call the tool immediately.
      """
    }

    if let contextSection = context.buildPromptSection() {
      prompt += "\n\n" + contextSection
    }

    return prompt
  }

  init(tier: MLXEditorModelTier = .auto, context: ChatContext = .empty, toolsEnabled: Bool = false) {
    let config: MLXEditorModelConfig
    if tier == .auto {
      config = MLXEditorModelConfig.recommendedModel()
    } else {
      config = MLXEditorModelConfig.model(for: tier) ?? MLXEditorModelConfig.recommendedModel()
    }
    self.config = config
    self.context = context
    self.toolsEnabled = toolsEnabled
    self.modelName = config.name
    self.tier = config.tier
    self.huggingFaceId = config.huggingFaceId
    self.conversationHistory = [.system(Self.buildSystemMessage(config: config, context: context, toolsEnabled: toolsEnabled))]
    let skillCount = context.skills != nil ? " +skills" : ""
    let toolFlag = toolsEnabled ? " +tools" : ""
    print("[MLXChat] Init: \(config.name) (\(config.huggingFaceId)), tier=\(config.tier.rawValue)\(skillCount)\(toolFlag)")
  }

  // MARK: - Model Loading

  private func ensureLoaded() async throws {
    guard !isLoaded else { return }
    print("[MLXChat] Loading model: \(config.huggingFaceId)")
    // Qwen3 Coder models use XML function format for tool calls, not JSON.
    // The model's chat_template.jinja outputs <function=name><parameter=key>value</parameter></function>
    let toolFormat: ToolCallFormat? = config.huggingFaceId.contains("Qwen3-Coder") ? .xmlFunction : nil
    let modelConfig = ModelConfiguration(id: config.huggingFaceId, toolCallFormat: toolFormat)
    modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig) { progress in
      let percent = Int(progress.fractionCompleted * 100)
      if percent % 10 == 0 {
        print("[MLXChat] Loading: \(percent)%")
      }
    }
    isLoaded = true
    print("[MLXChat] Model ready: \(config.name)")
  }

  // MARK: - Chat

  /// Send a message with optional RAG context and tool definitions.
  /// The RAG context is set before generation and cleared after, so it only applies to this message.
  /// When tools are provided, the model may generate tool calls instead of (or alongside) text.
  func sendMessage(_ text: String, ragContext: String? = nil, tools: [[String: any Sendable]]? = nil) async throws -> AsyncStream<ChatStreamEvent> {
    // Temporarily inject RAG context for this message
    if let ragContext {
      var augmented = self.context
      augmented.ragContext = ragContext
      if !conversationHistory.isEmpty {
        conversationHistory[0] = .system(Self.buildSystemMessage(config: config, context: augmented))
      }
    }

    // Add user message to history
    conversationHistory.append(.user(text))

    return try await generateFromHistory(tools: tools)
  }

  /// Record a tool call exchange in the conversation history.
  /// Call this after receiving a `.toolCall` event and executing the tool.
  ///
  /// - Parameters:
  ///   - assistantText: The text the model generated before the tool call
  ///   - toolCallMarker: The reconstructed tool call marker (from ChatToolCall.asToolCallMarker())
  ///   - toolResult: The JSON result from executing the tool
  func recordToolCallAndResult(assistantText: String, toolCallMarker: String, toolResult: String) {
    // The last history entry is the assistant message from generateFromHistory.
    // Replace it with the clean text + tool call marker (removing raw XML/thinking).
    if let lastIdx = conversationHistory.indices.last,
       conversationHistory[lastIdx].role == .assistant {
      conversationHistory[lastIdx] = .assistant(assistantText + toolCallMarker)
    } else {
      // Fallback: if no assistant message found, append one
      conversationHistory.append(.assistant(assistantText + toolCallMarker))
    }
    // Add tool result as the next message
    conversationHistory.append(.tool(toolResult))
  }

  /// Continue generation after a tool call has been processed.
  /// Call this after `recordToolCallAndResult` to get the model's next response.
  func continueAfterTool(tools: [[String: any Sendable]]? = nil) async throws -> AsyncStream<ChatStreamEvent> {
    return try await generateFromHistory(tools: tools)
  }

  /// Add a user instruction to the conversation history and generate.
  /// Used for synthesis prompts after max tool rounds — the instruction appears in
  /// the model's context but not in the UI message list.
  func continueWithInstruction(_ instruction: String, tools: [[String: any Sendable]]? = nil) async throws -> AsyncStream<ChatStreamEvent> {
    conversationHistory.append(.user(instruction))
    return try await generateFromHistory(tools: tools)
  }

  /// Core generation method — builds input from conversation history and streams results.
  private func generateFromHistory(tools: [[String: any Sendable]]? = nil) async throws -> AsyncStream<ChatStreamEvent> {
    try await ensureLoaded()

    guard let container = modelContainer else {
      throw MLXChatError.modelNotLoaded
    }

    // Build fresh messages array for the model
    let messages: [Chat.Message] = Array(conversationHistory)
    nonisolated(unsafe) let input = UserInput(chat: messages, tools: tools)

    let parameters = GenerateParameters(
      maxTokens: config.maxTokens,
      temperature: config.tier == .xlarge ? 1.0 : 0.7,
      topP: config.tier == .xlarge ? 0.95 : 0.9
    )

    let lmInput = try await container.prepare(input: input)
    let stream = try await container.generate(input: lmInput, parameters: parameters)

    // Capture tools value for use in the detached Task
    // Always use tool-aware streaming — the model may generate <tool_call> XML
    // even when no tools are provided (e.g. after max tool rounds).
    // The tool-aware path intercepts these as .toolCall events instead of raw text.
    return AsyncStream { continuation in
      Task {
        var fullResponse = ""

        // Tool-aware streaming: the framework's XMLFunctionParser fails on
        // multi-line content (Swift regex '.' doesn't match newlines), so we
        // detect <tool_call>...</tool_call> boundaries ourselves.
        var textBuffer = ""
        var isInToolCall = false
        var toolCallContent = ""

        for await generation in stream {
          switch generation {
          case .chunk(let text):
            fullResponse += text
            textBuffer += text

            // Process buffer looking for tool call tag boundaries
            var didWork = true
            while didWork && !textBuffer.isEmpty {
              didWork = false
              if isInToolCall {
                if let endRange = textBuffer.range(of: "</tool_call>") {
                  toolCallContent += String(textBuffer[..<endRange.lowerBound])
                  if let tc = Self.parseXMLToolCall(toolCallContent) {
                    print("[MLXChat] Tool call detected: \(tc.name)(\(tc.arguments.keys.sorted().joined(separator: ", ")))")
                    continuation.yield(.toolCall(tc))
                  } else {
                    // Parse failed — yield the raw content as text
                    continuation.yield(.text("<tool_call>" + toolCallContent + "</tool_call>"))
                  }
                  textBuffer = String(textBuffer[endRange.upperBound...])
                  toolCallContent = ""
                  isInToolCall = false
                  didWork = true
                } else {
                  // Still collecting tool call content
                  toolCallContent += textBuffer
                  textBuffer = ""
                }
              } else {
                if let startRange = textBuffer.range(of: "<tool_call>") {
                  // Yield any text before the tag
                  let prefix = String(textBuffer[..<startRange.lowerBound])
                  if !prefix.isEmpty {
                    continuation.yield(.text(prefix))
                  }
                  textBuffer = String(textBuffer[startRange.upperBound...])
                  isInToolCall = true
                  didWork = true
                } else {
                  // Yield text that can't be a partial <tool_call> tag
                  let safe = Self.safeTextPrefix(textBuffer, beforeTag: "<tool_call>")
                  if !safe.isEmpty {
                    continuation.yield(.text(safe))
                    textBuffer = String(textBuffer.dropFirst(safe.count))
                  }
                  // Remaining text might be a partial tag — hold it
                  break
                }
              }
            }

          case .toolCall(let toolCall):
            // Framework detected a tool call (unlikely with xmlFunction but handle it)
            let args = toolCall.function.arguments.reduce(into: [String: String]()) { result, pair in
              result[pair.key] = "\(pair.value)"
            }
            continuation.yield(.toolCall(ChatToolCall(name: toolCall.function.name, arguments: args)))
          case .info:
            break
          }
        }

        // Flush anything remaining in the buffer
        if isInToolCall && !toolCallContent.isEmpty {
          continuation.yield(.text(toolCallContent))
        }
        if !textBuffer.isEmpty {
          continuation.yield(.text(textBuffer))
        }

        // Add assistant response to history on the actor
        await self.appendAssistantMessage(fullResponse)
        // Restore system prompt without per-turn RAG context
        await self.restoreBaseSystemPrompt()
        continuation.finish()
      }
    }
  }

  // MARK: - Tool Call Parsing

  /// Parse XML function-format tool call content (the text between <tool_call> and </tool_call>).
  /// Handles multi-line content that the framework's XMLFunctionParser fails on.
  ///
  /// Expected format:
  /// ```
  /// <function=rag_search>
  /// <parameter=query>
  /// optimization opportunities
  /// </parameter>
  /// </function>
  /// ```
  private static func parseXMLToolCall(_ content: String) -> ChatToolCall? {
    // Extract function name: <function=name>
    guard let nameMatch = content.range(of: #"<function=([^>]+)>"#, options: .regularExpression) else {
      return nil
    }
    let matchStr = String(content[nameMatch])
    let funcName = String(matchStr.dropFirst("<function=".count).dropLast(">".count))
    guard !funcName.isEmpty else { return nil }

    // Extract parameters using NSRegularExpression with .dotMatchesLineSeparators
    // so we can match multi-line parameter values
    var arguments = [String: String]()
    guard let pattern = try? NSRegularExpression(
      pattern: #"<parameter=([^>]+)>([\s\S]*?)</parameter>"#,
      options: [.dotMatchesLineSeparators]
    ) else { return nil }

    let nsContent = content as NSString
    let matches = pattern.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
    for match in matches {
      let paramName = nsContent.substring(with: match.range(at: 1))
      var paramValue = nsContent.substring(with: match.range(at: 2))
      // Trim leading/trailing newlines (matching Python mlx-lm behavior)
      if paramValue.hasPrefix("\n") { paramValue = String(paramValue.dropFirst()) }
      if paramValue.hasSuffix("\n") { paramValue = String(paramValue.dropLast()) }
      arguments[paramName] = paramValue
    }

    return ChatToolCall(name: funcName, arguments: arguments)
  }

  /// Return the prefix of `text` that is safe to yield — i.e. text that can't be
  /// the beginning of a partial `<tool_call>` tag at the end of the buffer.
  private static func safeTextPrefix(_ text: String, beforeTag tag: String) -> String {
    for i in stride(from: min(text.count, tag.count), through: 1, by: -1) {
      if text.hasSuffix(String(tag.prefix(i))) {
        return String(text.dropLast(i))
      }
    }
    return text
  }

  // MARK: - Conversation Management

  /// Restore the system prompt to the base context (without per-turn RAG)
  private func restoreBaseSystemPrompt() {
    if !conversationHistory.isEmpty {
      conversationHistory[0] = .system(Self.buildSystemMessage(config: config, context: context, toolsEnabled: toolsEnabled))
    }
  }

  private func appendAssistantMessage(_ text: String) {
    conversationHistory.append(.assistant(text))
  }

  /// Update context (skills, instructions, etc.) and rebuild system prompt
  func updateContext(_ newContext: ChatContext) {
    self.context = newContext
    // Rebuild system message as first entry in history
    if !conversationHistory.isEmpty {
      conversationHistory[0] = .system(Self.buildSystemMessage(config: config, context: newContext, toolsEnabled: toolsEnabled))
    }
    let skillCount = newContext.skills != nil ? " +skills" : ""
    print("[MLXChat] Context updated\(skillCount)")
  }

  /// Enable or disable tool-use instructions in the system prompt
  func setToolsEnabled(_ enabled: Bool) {
    guard enabled != toolsEnabled else { return }
    toolsEnabled = enabled
    if !conversationHistory.isEmpty {
      conversationHistory[0] = .system(Self.buildSystemMessage(config: config, context: context, toolsEnabled: toolsEnabled))
    }
    print("[MLXChat] Tools \(enabled ? "enabled" : "disabled")")
  }

  /// Clear conversation history (keep system prompt)
  func clearHistory() {
    conversationHistory = [.system(Self.buildSystemMessage(config: config, context: context, toolsEnabled: toolsEnabled))]
  }

  /// Unload model to free memory
  func unload() {
    modelContainer = nil
    isLoaded = false
    conversationHistory = [.system(Self.buildSystemMessage(config: config, context: context, toolsEnabled: toolsEnabled))]
    print("[MLXChat] Model unloaded")
  }

  func getIsLoaded() -> Bool { isLoaded }
  func getHistoryCount() -> Int { conversationHistory.count - 1 } // minus system prompt
  func getContext() -> ChatContext { context }
}

// MARK: - Errors

enum MLXChatError: LocalizedError {
  case modelNotLoaded

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded: return "Chat model not loaded"
    }
  }
}

#endif
