import Foundation

// MARK: - LLM Provider Protocol

/// Abstraction over different LLM API backends (Anthropic, GitHub Copilot/OpenAI, etc.)
/// Both providers normalize to the same ContentBlock/StreamEvent types used by AgentSession.
protocol LLMProvider: Sendable {
  /// The model name being used
  var model: String { get }

  /// Send a streaming request, returning an AsyncStream of events
  /// Both Anthropic and OpenAI SSE streams are normalized to the same StreamEvent type.
  func stream(
    messages: [MessagesRequest.Message],
    system: String?,
    tools: [ToolDefinition]?,
    maxTokens: Int
  ) async throws -> AsyncStream<StreamEvent>
}

extension LLMProvider {
  func stream(
    messages: [MessagesRequest.Message],
    system: String? = nil,
    tools: [ToolDefinition]? = nil,
    maxTokens: Int = 8192
  ) async throws -> AsyncStream<StreamEvent> {
    try await stream(messages: messages, system: system, tools: tools, maxTokens: maxTokens)
  }
}

// MARK: - Provider Selection

enum ProviderKind: String, CaseIterable {
  case copilot   // GitHub Models API (OpenAI-compatible) — default
  case anthropic // Anthropic Messages API (Claude direct)

  var displayName: String {
    switch self {
    case .copilot: return "GitHub Copilot"
    case .anthropic: return "Anthropic"
    }
  }
}
