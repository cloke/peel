import Foundation

// MARK: - GitHub Copilot Provider

/// Uses the GitHub Copilot API (OpenAI chat/completions format) with a Copilot session token.
/// Supports Claude, GPT, and Gemini models through your Copilot subscription.
///
/// Auth flow (handled by `CopilotAuth`):
/// 1. Read Copilot OAuth token from `~/.config/github-copilot/apps.json`
/// 2. Exchange via `api.github.com/copilot_internal/v2/token` → session token + endpoint
/// 3. Use session token against the returned endpoint
///
/// Falls back to GitHub Models API (`models.github.ai`) for PAT-based auth (GPT only).
public final class CopilotClient: LLMProvider, Sendable {
  private let token: String
  public let model: String
  private let chatCompletionsURL: String
  private let extraHeaders: [(String, String)]

  /// Create a CopilotClient from a resolved session (preferred — supports all models).
  public init(session: CopilotAuth.CopilotSession, model: String) {
    self.token = session.token
    self.model = model
    let base = session.endpoint.hasSuffix("/") ? String(session.endpoint.dropLast()) : session.endpoint
    self.chatCompletionsURL = base.hasSuffix("/chat/completions")
      ? base
      : base + "/chat/completions"
    self.extraHeaders = [
      ("editor-version", "PeelAgent/0.2.0"),
      ("copilot-integration-id", "vscode-chat"),
    ]
  }

  /// Create a CopilotClient with a raw PAT (falls back to GitHub Models API — GPT only).
  public init(pat: String, model: String) {
    self.token = pat
    self.model = model
    self.chatCompletionsURL = CopilotAuth.modelsAPIEndpoint
    self.extraHeaders = []
  }

  // MARK: - LLMProvider

  public func stream(
    messages: [MessagesRequest.Message],
    system: String?,
    tools: [ToolDefinition]?,
    maxTokens: Int
  ) async throws -> AsyncStream<StreamEvent> {
    let request = buildOpenAIRequest(
      messages: messages,
      system: system,
      tools: tools,
      maxTokens: maxTokens,
      stream: true
    )

    let httpRequest = try buildHTTPRequest(body: request)

    let (bytes, response) = try await URLSession.shared.bytes(for: httpRequest)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw CopilotClientError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      var body = ""
      for try await line in bytes.lines {
        body += line
      }
      throw CopilotClientError.apiError(statusCode: httpResponse.statusCode, body: body)
    }

    return AsyncStream { continuation in
      let task = Task {
        var sentMessageStart = false
        var currentToolCalls: [Int: PartialToolCall] = [:]

        for try await line in bytes.lines {
          guard line.hasPrefix("data: ") else { continue }
          let data = String(line.dropFirst(6))

          if data == "[DONE]" {
            // Finish any pending tool calls
            for (index, partial) in currentToolCalls.sorted(by: { $0.key < $1.key }) {
              if let _ = partial.finalize() {
                continuation.yield(.contentBlockStop(index: index))
              }
            }
            continuation.yield(.messageStop)
            continuation.finish()
            return
          }

          guard let jsonData = data.data(using: .utf8),
                let chunk = try? JSONDecoder().decode(OpenAIChatChunk.self, from: jsonData)
          else { continue }

          // Emit messageStart on first chunk (synthesize usage from the chunk)
          if !sentMessageStart {
            sentMessageStart = true
            let usage = chunk.usage ?? OpenAIChatChunk.Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
            let syntheticResponse = MessagesResponse(
              id: chunk.id,
              type: "message",
              role: "assistant",
              content: [],
              model: chunk.model ?? self.model,
              stop_reason: nil,
              usage: .init(input_tokens: usage.prompt_tokens ?? 0, output_tokens: usage.completion_tokens ?? 0)
            )
            continuation.yield(.messageStart(syntheticResponse))
          }

          guard let choice = chunk.choices?.first else {
            // Usage-only chunk at the end
            if let usage = chunk.usage {
              continuation.yield(.messageDelta(
                stopReason: nil,
                usage: StreamUsageDelta(output_tokens: usage.completion_tokens ?? 0)
              ))
            }
            continue
          }

          let delta = choice.delta

          // Handle text content
          if let content = delta?.content, !content.isEmpty {
            // First text? Emit contentBlockStart
            if currentToolCalls.isEmpty {
              continuation.yield(.contentBlockStart(index: 0, .text("")))
            }
            continuation.yield(.contentBlockDelta(
              index: 0,
              delta: StreamDelta(type: "text_delta", text: content, partial_json: nil)
            ))
          }

          // Handle tool calls
          if let toolCalls = delta?.tool_calls {
            for tc in toolCalls {
              let index = tc.index ?? currentToolCalls.count
              let adjustedIndex = index + 1 // offset by 1 since index 0 is text

              if let id = tc.id, let function = tc.function, let name = function.name {
                // New tool call starting
                let partial = PartialToolCall(id: id, name: name, argumentsJSON: "")
                currentToolCalls[index] = partial
                continuation.yield(.contentBlockStart(
                  index: adjustedIndex,
                  .toolUse(id: id, name: name, input: [:])
                ))
              }

              // Append arguments fragment
              if let args = tc.function?.arguments, !args.isEmpty {
                currentToolCalls[index]?.argumentsJSON += args
                continuation.yield(.contentBlockDelta(
                  index: adjustedIndex,
                  delta: StreamDelta(type: "input_json_delta", text: nil, partial_json: args)
                ))
              }
            }
          }

          // Handle finish reason
          if let finishReason = choice.finish_reason {
            // Close any open text block
            continuation.yield(.contentBlockStop(index: 0))

            // Close tool call blocks
            for (index, _) in currentToolCalls.sorted(by: { $0.key < $1.key }) {
              continuation.yield(.contentBlockStop(index: index + 1))
            }

            let stopReason = finishReason == "tool_calls" ? "tool_use" : finishReason
            continuation.yield(.messageDelta(stopReason: stopReason, usage: nil))
          }

          // Usage in final chunk
          if let usage = chunk.usage {
            continuation.yield(.messageDelta(
              stopReason: nil,
              usage: StreamUsageDelta(output_tokens: usage.completion_tokens ?? 0)
            ))
          }
        }

        continuation.finish()
      }

      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  // MARK: - Request Building

  private func buildOpenAIRequest(
    messages: [MessagesRequest.Message],
    system: String?,
    tools: [ToolDefinition]?,
    maxTokens: Int,
    stream: Bool
  ) -> OpenAIChatRequest {
    var openAIMessages: [OpenAIChatMessage] = []

    // System message
    if let system {
      openAIMessages.append(OpenAIChatMessage(
        role: "system",
        content: .text(system),
        tool_calls: nil,
        tool_call_id: nil
      ))
    }

    // Convert messages from our internal format to OpenAI format
    for msg in messages {
      switch msg.content {
      case .text(let text):
        openAIMessages.append(OpenAIChatMessage(
          role: msg.role,
          content: .text(text),
          tool_calls: nil,
          tool_call_id: nil
        ))

      case .blocks(let blocks):
        if msg.role == "assistant" {
          // Extract text and tool_calls from content blocks
          var textParts: [String] = []
          var toolCalls: [OpenAIToolCall] = []

          for block in blocks {
            switch block {
            case .text(let t):
              textParts.append(t)
            case .toolUse(let id, let name, let input):
              let args: String
              if let data = try? JSONEncoder().encode(input),
                 let str = String(data: data, encoding: .utf8) {
                args = str
              } else {
                args = "{}"
              }
              toolCalls.append(OpenAIToolCall(
                id: id,
                index: nil,
                type: "function",
                function: .init(name: name, arguments: args)
              ))
            default:
              break
            }
          }

          openAIMessages.append(OpenAIChatMessage(
            role: "assistant",
            content: textParts.isEmpty ? nil : .text(textParts.joined()),
            tool_calls: toolCalls.isEmpty ? nil : toolCalls,
            tool_call_id: nil
          ))

        } else if msg.role == "user" {
          // Tool results come as user messages with tool_result blocks
          for block in blocks {
            if case .toolResult(let toolUseId, let content, _) = block {
              openAIMessages.append(OpenAIChatMessage(
                role: "tool",
                content: .text(content),
                tool_calls: nil,
                tool_call_id: toolUseId
              ))
            }
          }
        }
      }
    }

    // Convert tool definitions to OpenAI format
    let openAITools = tools?.map { tool -> OpenAIToolDef in
      // Convert our ToolDefinition.InputSchema to a JSON dictionary
      var params: [String: JSONValue] = [
        "type": .string(tool.input_schema.type)
      ]

      var props: [String: JSONValue] = [:]
      for (key, prop) in tool.input_schema.properties {
        var propDict: [String: JSONValue] = [
          "type": .string(prop.type)
        ]
        if let desc = prop.description {
          propDict["description"] = .string(desc)
        }
        if let items = prop.items {
          propDict["items"] = .object(["type": .string(items.type)])
        }
        if let enumValues = prop.enum {
          propDict["enum"] = .array(enumValues.map { .string($0) })
        }
        props[key] = .object(propDict)
      }
      params["properties"] = .object(props)

      if let required = tool.input_schema.required {
        params["required"] = .array(required.map { .string($0) })
      }

      return OpenAIToolDef(
        type: "function",
        function: .init(
          name: tool.name,
          description: tool.description,
          parameters: params
        )
      )
    }

    return OpenAIChatRequest(
      model: model,
      messages: openAIMessages,
      tools: openAITools,
      max_tokens: maxTokens,
      stream: stream,
      stream_options: stream ? OpenAIStreamOptions(include_usage: true) : nil
    )
  }

  private func buildHTTPRequest<T: Encodable>(body: T) throws -> URLRequest {
    guard let url = URL(string: chatCompletionsURL) else {
      throw CopilotClientError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    for (name, value) in extraHeaders {
      request.setValue(value, forHTTPHeaderField: name)
    }

    let encoder = JSONEncoder()
    request.httpBody = try encoder.encode(body)
    return request
  }
}

// MARK: - Partial Tool Call Accumulator

private struct PartialToolCall {
  let id: String
  let name: String
  var argumentsJSON: String

  func finalize() -> (id: String, name: String, input: [String: JSONValue])? {
    let input: [String: JSONValue]
    if let data = argumentsJSON.data(using: .utf8),
       let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
      input = parsed
    } else {
      input = [:]
    }
    return (id: id, name: name, input: input)
  }
}

// MARK: - OpenAI API Types (Request)

private struct OpenAIChatRequest: Encodable {
  let model: String
  let messages: [OpenAIChatMessage]
  let tools: [OpenAIToolDef]?
  let max_tokens: Int
  let stream: Bool
  let stream_options: OpenAIStreamOptions?
}

private struct OpenAIStreamOptions: Encodable {
  let include_usage: Bool
}

struct OpenAIChatMessage: Codable, Sendable {
  let role: String
  let content: MessageContentValue?
  let tool_calls: [OpenAIToolCall]?
  let tool_call_id: String?

  enum MessageContentValue: Codable, Sendable {
    case text(String)
    case null

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .text(let s): try container.encode(s)
      case .null: try container.encodeNil()
      }
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let s = try? container.decode(String.self) {
        self = .text(s)
      } else {
        self = .null
      }
    }
  }
}

struct OpenAIToolCall: Codable, Sendable {
  let id: String?
  let index: Int?
  let type: String?
  let function: FunctionCall?

  struct FunctionCall: Codable, Sendable {
    let name: String?
    let arguments: String?
  }
}

private struct OpenAIToolDef: Encodable {
  let type: String
  let function: FunctionDef

  struct FunctionDef: Encodable {
    let name: String
    let description: String
    let parameters: [String: JSONValue]
  }
}

// MARK: - OpenAI API Types (Streaming Response)

private struct OpenAIChatChunk: Decodable {
  let id: String
  let object: String?
  let model: String?
  let choices: [ChunkChoice]?
  let usage: Usage?

  struct ChunkChoice: Decodable {
    let index: Int?
    let delta: Delta?
    let finish_reason: String?

    struct Delta: Decodable {
      let role: String?
      let content: String?
      let tool_calls: [OpenAIToolCall]?
    }
  }

  struct Usage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let total_tokens: Int?
  }
}

// MARK: - Errors

public enum CopilotClientError: Error, CustomStringConvertible, Sendable {
  case invalidURL
  case invalidResponse
  case apiError(statusCode: Int, body: String)

  public var description: String {
    switch self {
    case .invalidURL:
      return "Invalid API URL"
    case .invalidResponse:
      return "Invalid response from API"
    case .apiError(let code, let body):
      return "API error (\(code)): \(body)"
    }
  }
}
