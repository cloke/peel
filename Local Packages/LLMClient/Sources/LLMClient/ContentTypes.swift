import Foundation

// MARK: - Messages Request (Anthropic format, used as internal canonical format)

/// Claude Messages API request — also used as the canonical internal format.
/// CopilotClient converts these to OpenAI format before sending.
public struct MessagesRequest: Encodable, Sendable {
  public let model: String
  public let max_tokens: Int
  public let system: String?
  public let messages: [Message]
  public let tools: [ToolDefinition]?
  public let stream: Bool

  public init(
    model: String,
    max_tokens: Int,
    system: String?,
    messages: [Message],
    tools: [ToolDefinition]?,
    stream: Bool
  ) {
    self.model = model
    self.max_tokens = max_tokens
    self.system = system
    self.messages = messages
    self.tools = tools
    self.stream = stream
  }

  public struct Message: Codable, Sendable {
    public let role: String
    public let content: MessageContent

    public init(role: String, content: MessageContent) {
      self.role = role
      self.content = content
    }

    public enum MessageContent: Codable, Sendable {
      case text(String)
      case blocks([ContentBlock])

      public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
          try container.encode(string)
        case .blocks(let blocks):
          try container.encode(blocks)
        }
      }

      public init(from decoder: Decoder) throws {
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

// MARK: - Content Block

/// A content block in an LLM message (text, tool use, or tool result).
public enum ContentBlock: Codable, Sendable {
  case text(String)
  case toolUse(id: String, name: String, input: [String: JSONValue])
  case toolResult(toolUseId: String, content: String, isError: Bool)

  enum CodingKeys: String, CodingKey {
    case type, text, id, name, input
    case toolUseId = "tool_use_id"
    case content, is_error
  }

  public func encode(to encoder: Encoder) throws {
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

  public init(from decoder: Decoder) throws {
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
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container,
        debugDescription: "Unknown content block type: \(type)"
      )
    }
  }
}

// MARK: - Messages Response

/// Claude Messages API response (non-streaming, also used in messageStart SSE events).
public struct MessagesResponse: Decodable, Sendable {
  public let id: String
  public let type: String
  public let role: String
  public let content: [ContentBlock]
  public let model: String
  public let stop_reason: String?
  public let usage: Usage

  public init(
    id: String,
    type: String,
    role: String,
    content: [ContentBlock],
    model: String,
    stop_reason: String?,
    usage: Usage
  ) {
    self.id = id
    self.type = type
    self.role = role
    self.content = content
    self.model = model
    self.stop_reason = stop_reason
    self.usage = usage
  }

  public struct Usage: Codable, Sendable {
    public let input_tokens: Int
    public let output_tokens: Int

    public init(input_tokens: Int, output_tokens: Int) {
      self.input_tokens = input_tokens
      self.output_tokens = output_tokens
    }
  }
}

// MARK: - Streaming Types

/// Normalized SSE stream event from any LLM provider.
/// Both Anthropic's native SSE and OpenAI's streaming format are converted to this.
public enum StreamEvent: Sendable {
  case messageStart(MessagesResponse)
  case contentBlockStart(index: Int, ContentBlock)
  case contentBlockDelta(index: Int, delta: StreamDelta)
  case contentBlockStop(index: Int)
  case messageDelta(stopReason: String?, usage: StreamUsageDelta?)
  case messageStop
  case ping
  case error(String)
}

/// Delta within a streaming content block.
public struct StreamDelta: Decodable, Sendable {
  public let type: String  // "text_delta" or "input_json_delta"
  public let text: String?
  public let partial_json: String?

  public init(type: String, text: String?, partial_json: String?) {
    self.type = type
    self.text = text
    self.partial_json = partial_json
  }
}

/// Usage delta emitted at the end of a streamed message.
public struct StreamUsageDelta: Decodable, Sendable {
  public let output_tokens: Int

  public init(output_tokens: Int) {
    self.output_tokens = output_tokens
  }
}
