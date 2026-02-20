import Foundation

// MARK: - API Types

/// Claude Messages API request
struct MessagesRequest: Encodable {
  let model: String
  let max_tokens: Int
  let system: String?
  let messages: [Message]
  let tools: [ToolDefinition]?
  let stream: Bool

  struct Message: Codable, Sendable {
    let role: String
    let content: MessageContent

    enum MessageContent: Codable, Sendable {
      case text(String)
      case blocks([ContentBlock])

      func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
          try container.encode(string)
        case .blocks(let blocks):
          try container.encode(blocks)
        }
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
          self = .text(text)
        } else {
          let blocks = try container.decode([ContentBlock].self)
          self = .blocks(blocks)
        }
      }
    }
  }
}

/// A content block in a message
enum ContentBlock: Codable, Sendable {
  case text(String)
  case toolUse(id: String, name: String, input: [String: JSONValue])
  case toolResult(toolUseId: String, content: String, isError: Bool)

  enum CodingKeys: String, CodingKey {
    case type, text, id, name, input
    case toolUseId = "tool_use_id"
    case content, is_error
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .toolUse(let id, let name, let input):
      try container.encode("tool_use", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(name, forKey: .name)
      try container.encode(input, forKey: .input)
    case .toolResult(let toolUseId, let content, let isError):
      try container.encode("tool_result", forKey: .type)
      try container.encode(toolUseId, forKey: .toolUseId)
      try container.encode(content, forKey: .content)
      if isError {
        try container.encode(true, forKey: .is_error)
      }
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "text":
      let text = try container.decode(String.self, forKey: .text)
      self = .text(text)
    case "tool_use":
      let id = try container.decode(String.self, forKey: .id)
      let name = try container.decode(String.self, forKey: .name)
      let input = try container.decode([String: JSONValue].self, forKey: .input)
      self = .toolUse(id: id, name: name, input: input)
    case "tool_result":
      let toolUseId = try container.decode(String.self, forKey: .toolUseId)
      let content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
      let isError = try container.decodeIfPresent(Bool.self, forKey: .is_error) ?? false
      self = .toolResult(toolUseId: toolUseId, content: content, isError: isError)
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content block type: \(type)")
    }
  }
}

/// JSON value type for flexible encoding/decoding
enum JSONValue: Codable, Sendable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null
  case array([JSONValue])
  case object([String: JSONValue])

  var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  var intValue: Int? {
    if case .int(let i) = self { return i }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case .object(let o) = self { return o }
    return nil
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let s): try container.encode(s)
    case .int(let i): try container.encode(i)
    case .double(let d): try container.encode(d)
    case .bool(let b): try container.encode(b)
    case .null: try container.encodeNil()
    case .array(let a): try container.encode(a)
    case .object(let o): try container.encode(o)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let b = try? container.decode(Bool.self) {
      self = .bool(b)
    } else if let i = try? container.decode(Int.self) {
      self = .int(i)
    } else if let d = try? container.decode(Double.self) {
      self = .double(d)
    } else if let s = try? container.decode(String.self) {
      self = .string(s)
    } else if let a = try? container.decode([JSONValue].self) {
      self = .array(a)
    } else if let o = try? container.decode([String: JSONValue].self) {
      self = .object(o)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
    }
  }
}

/// Tool definition for Claude API
struct ToolDefinition: Encodable {
  let name: String
  let description: String
  let input_schema: InputSchema

  struct InputSchema: Encodable {
    let type: String
    let properties: [String: Property]
    let required: [String]?

    struct Property: Encodable {
      let type: String
      let description: String?
      let items: Items?
      let `enum`: [String]?

      enum CodingKeys: String, CodingKey {
        case type, description, items
        case `enum`
      }

      struct Items: Encodable {
        let type: String
      }
    }
  }
}

/// Claude Messages API response (non-streaming)
struct MessagesResponse: Decodable {
  let id: String
  let type: String
  let role: String
  let content: [ContentBlock]
  let model: String
  let stop_reason: String?
  let usage: Usage

  struct Usage: Decodable {
    let input_tokens: Int
    let output_tokens: Int
  }
}

// MARK: - Streaming types

enum StreamEvent: Sendable {
  case messageStart(MessagesResponse)
  case contentBlockStart(index: Int, ContentBlock)
  case contentBlockDelta(index: Int, delta: StreamDelta)
  case contentBlockStop(index: Int)
  case messageDelta(stopReason: String?, usage: StreamUsageDelta?)
  case messageStop
  case ping
  case error(String)
}

struct StreamDelta: Decodable, Sendable {
  let type: String  // "text_delta" or "input_json_delta"
  let text: String?
  let partial_json: String?
}

struct StreamUsageDelta: Decodable, Sendable {
  let output_tokens: Int
}

// MARK: - Claude Client (Anthropic API)

final class ClaudeClient: LLMProvider, Sendable {
  private let apiKey: String
  let model: String
  private let baseURL = "https://api.anthropic.com/v1/messages"

  init(apiKey: String, model: String) {
    self.apiKey = apiKey
    self.model = model
  }

  /// Send a streaming request, returns an AsyncStream of events
  func stream(
    messages: [MessagesRequest.Message],
    system: String? = nil,
    tools: [ToolDefinition]? = nil,
    maxTokens: Int = 8192
  ) async throws -> AsyncStream<StreamEvent> {
    let request = MessagesRequest(
      model: model,
      max_tokens: maxTokens,
      system: system,
      messages: messages,
      tools: tools,
      stream: true
    )

    let httpRequest = try buildRequest(body: request)

    let (bytes, response) = try await URLSession.shared.bytes(for: httpRequest)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ClaudeError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      var body = ""
      for try await line in bytes.lines {
        body += line
      }
      throw ClaudeError.apiError(statusCode: httpResponse.statusCode, body: body)
    }

    return AsyncStream { continuation in
      let task = Task {
        var currentEvent = ""
        var currentData = ""

        for try await line in bytes.lines {
          if line.hasPrefix("event: ") {
            currentEvent = String(line.dropFirst(7))
            currentData = ""
          } else if line.hasPrefix("data: ") {
            currentData += String(line.dropFirst(6))
          } else if line.isEmpty && !currentEvent.isEmpty {
            // End of SSE event — parse it
            if let event = parseSSEEvent(type: currentEvent, data: currentData) {
              continuation.yield(event)
              if case .messageStop = event {
                continuation.finish()
                return
              }
            }
            currentEvent = ""
            currentData = ""
          }
        }
        continuation.finish()
      }

      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  // MARK: - Private

  private func buildRequest<T: Encodable>(body: T) throws -> URLRequest {
    guard let url = URL(string: baseURL) else {
      throw ClaudeError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    let encoder = JSONEncoder()
    request.httpBody = try encoder.encode(body)
    return request
  }
}

private func parseSSEEvent(type: String, data: String) -> StreamEvent? {
  guard let jsonData = data.data(using: .utf8) else { return nil }

  switch type {
  case "message_start":
    guard let wrapper = try? JSONDecoder().decode(MessageStartWrapper.self, from: jsonData) else { return nil }
    return .messageStart(wrapper.message)

  case "content_block_start":
    guard let wrapper = try? JSONDecoder().decode(ContentBlockStartWrapper.self, from: jsonData) else { return nil }
    return .contentBlockStart(index: wrapper.index, wrapper.content_block)

  case "content_block_delta":
    guard let wrapper = try? JSONDecoder().decode(ContentBlockDeltaWrapper.self, from: jsonData) else { return nil }
    return .contentBlockDelta(index: wrapper.index, delta: wrapper.delta)

  case "content_block_stop":
    guard let wrapper = try? JSONDecoder().decode(ContentBlockStopWrapper.self, from: jsonData) else { return nil }
    return .contentBlockStop(index: wrapper.index)

  case "message_delta":
    guard let wrapper = try? JSONDecoder().decode(MessageDeltaWrapper.self, from: jsonData) else { return nil }
    return .messageDelta(stopReason: wrapper.delta.stop_reason, usage: wrapper.usage)

  case "message_stop":
    return .messageStop

  case "ping":
    return .ping

  case "error":
    let errorMsg = String(data: jsonData, encoding: .utf8) ?? "unknown"
    return .error(errorMsg)

  default:
    return nil
  }
}

// MARK: - SSE wrapper types

private struct MessageStartWrapper: Decodable {
  let message: MessagesResponse
}

private struct ContentBlockStartWrapper: Decodable {
  let index: Int
  let content_block: ContentBlock
}

private struct ContentBlockDeltaWrapper: Decodable {
  let index: Int
  let delta: StreamDelta
}

private struct ContentBlockStopWrapper: Decodable {
  let index: Int
}

private struct MessageDeltaWrapper: Decodable {
  struct Delta: Decodable {
    let stop_reason: String?
  }
  let delta: Delta
  let usage: StreamUsageDelta?
}

// MARK: - Errors

enum ClaudeError: Error, CustomStringConvertible {
  case invalidURL
  case invalidResponse
  case apiError(statusCode: Int, body: String)

  var description: String {
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
