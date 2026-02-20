import Foundation

// MARK: - GitHub Copilot Provider

/// Uses the GitHub Copilot API (OpenAI chat/completions format) with a Copilot session token.
/// Supports Claude, GPT, and Gemini models through your Copilot subscription.
///
/// Auth flow:
/// 1. Read Copilot OAuth token from ~/.config/github-copilot/apps.json
/// 2. Exchange via api.github.com/copilot_internal/v2/token → session token + endpoint
/// 3. Use session token against the returned endpoint (e.g. api.enterprise.githubcopilot.com)
///
/// Falls back to GitHub Models API (models.github.ai) for PAT-based auth (GPT only).
final class CopilotClient: LLMProvider, Sendable {
  private let token: String
  let model: String
  private let chatCompletionsURL: String
  private let extraHeaders: [(String, String)]

  /// Fallback endpoint for direct PAT usage (GPT models only)
  static let modelsAPIEndpoint = "https://models.github.ai/inference/chat/completions"

  /// Create a CopilotClient from a resolved session (preferred — supports all models).
  init(session: CopilotAuth.CopilotSession, model: String) {
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
  init(pat: String, model: String) {
    self.token = pat
    self.model = model
    self.chatCompletionsURL = Self.modelsAPIEndpoint
    self.extraHeaders = []
  }

  // MARK: - LLMProvider

  func stream(
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
      throw CopilotError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      var body = ""
      for try await line in bytes.lines {
        body += line
      }
      throw CopilotError.apiError(statusCode: httpResponse.statusCode, body: body)
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
              if let parsed = partial.finalize() {
                continuation.yield(.contentBlockStop(index: index))
                _ = parsed
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
      throw CopilotError.invalidURL
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

// MARK: - Copilot Auth (Token Exchange)

enum CopilotAuth {
  struct CopilotSession: Sendable {
    let token: String
    let endpoint: String
    let expiresAt: Date
  }

  /// Full auth flow: find OAuth token → exchange for session → return session.
  /// Falls back to a PAT-based session (GitHub Models API) if no Copilot login found.
  static func resolveSession(explicitKey: String? = nil) async throws -> CopilotSession {
    // 1. If explicit key is provided, try it as an OAuth token for exchange
    if let key = explicitKey, !key.isEmpty {
      if let session = try? await exchangeToken(key) {
        return session
      }
      // If exchange fails, use it as a PAT (GitHub Models API fallback)
      return CopilotSession(
        token: key,
        endpoint: CopilotClient.modelsAPIEndpoint,
        expiresAt: .distantFuture
      )
    }

    // 2. Check ~/.config/github-copilot/apps.json for Copilot OAuth token
    if let oauthToken = readCopilotOAuthToken() {
      return try await exchangeToken(oauthToken)
    }

    // 3. Fall back to gh auth token / env vars → GitHub Models API (GPT only)
    if let pat = resolveGitHubPAT() {
      Terminal.warning(
        "No Copilot login found — using GitHub Models API (GPT models only).\n"
        + "  Run 'copilot login' for Claude/Gemini model access."
      )
      return CopilotSession(
        token: pat,
        endpoint: CopilotClient.modelsAPIEndpoint,
        expiresAt: .distantFuture
      )
    }

    throw CopilotError.noToken
  }

  /// Read the Copilot CLI OAuth token from ~/.config/github-copilot/apps.json
  static func readCopilotOAuthToken() -> String? {
    let path = NSString("~/.config/github-copilot/apps.json").expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONDecoder().decode([String: CopilotApp].self, from: data),
          let app = json.values.first
    else { return nil }
    return app.oauth_token
  }

  /// Exchange a Copilot OAuth token for a session token via the internal API.
  static func exchangeToken(_ oauthToken: String) async throws -> CopilotSession {
    guard let url = URL(string: "https://api.github.com/copilot_internal/v2/token") else {
      throw CopilotError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("token \(oauthToken)", forHTTPHeaderField: "Authorization")
    request.setValue("PeelAgent/0.2.0", forHTTPHeaderField: "editor-version")
    request.setValue("copilot/1.0.0", forHTTPHeaderField: "editor-plugin-version")
    request.setValue("GithubCopilot/1.0.0", forHTTPHeaderField: "user-agent")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw CopilotError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "(empty)"
      throw CopilotError.apiError(statusCode: httpResponse.statusCode, body: body)
    }

    let tokenResponse = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
    let endpoint = tokenResponse.endpoints.api
    let expiresAt = Date(timeIntervalSince1970: TimeInterval(tokenResponse.expires_at))

    return CopilotSession(
      token: tokenResponse.token,
      endpoint: endpoint,
      expiresAt: expiresAt
    )
  }

  /// Get a GitHub PAT from GH_TOKEN, GITHUB_TOKEN, or `gh auth token`
  static func resolveGitHubPAT() -> String? {
    if let token = ProcessInfo.processInfo.environment["GH_TOKEN"], !token.isEmpty {
      return token
    }
    if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty {
      return token
    }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh", "auth", "token"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
          return token
        }
      }
    } catch {}

    return nil
  }

  /// Check if any Copilot-compatible auth is available (without exchanging)
  static func isAvailable() -> Bool {
    readCopilotOAuthToken() != nil || resolveGitHubPAT() != nil
  }

  // MARK: - Internal Types

  private struct CopilotApp: Decodable {
    let user: String?
    let oauth_token: String
    let githubAppId: String?
  }

  private struct TokenExchangeResponse: Decodable {
    let token: String
    let endpoints: Endpoints
    let expires_at: Int
    let refresh_in: Int?

    struct Endpoints: Decodable {
      let api: String
    }
  }
}

// MARK: - Legacy Helper (for auto-detection)

enum GitHubTokenHelper {
  /// Check if Copilot auth is available (apps.json or gh token)
  static func resolveToken() -> String? {
    CopilotAuth.readCopilotOAuthToken() ?? CopilotAuth.resolveGitHubPAT()
  }
}

// MARK: - Errors

enum CopilotError: Error, CustomStringConvertible {
  case invalidURL
  case invalidResponse
  case apiError(statusCode: Int, body: String)
  case noToken

  var description: String {
    switch self {
    case .invalidURL:
      return "Invalid API URL"
    case .invalidResponse:
      return "Invalid response from API"
    case .apiError(let code, let body):
      return "API error (\(code)): \(body)"
    case .noToken:
      return "No GitHub token found. Run 'gh auth login' or set GH_TOKEN/GITHUB_TOKEN"
    }
  }
}
