import Foundation

// MARK: - Tool Definition (LLM Function Calling)

/// Tool definition for LLM function calling (JSON Schema format).
/// Used by both Anthropic and OpenAI/Copilot APIs.
///
/// Note: This is different from MCPCore's `MCPToolDefinition` which describes
/// MCP server tools. This type defines the JSON Schema passed to LLM APIs
/// for function calling.
public struct ToolDefinition: Encodable, Sendable {
  public let name: String
  public let description: String
  public let input_schema: InputSchema

  public init(name: String, description: String, input_schema: InputSchema) {
    self.name = name
    self.description = description
    self.input_schema = input_schema
  }

  public struct InputSchema: Encodable, Sendable {
    public let type: String
    public let properties: [String: Property]
    public let required: [String]?

    public init(type: String, properties: [String: Property], required: [String]?) {
      self.type = type
      self.properties = properties
      self.required = required
    }

    public struct Property: Encodable, Sendable {
      public let type: String
      public let description: String?
      public let items: Items?
      public let `enum`: [String]?

      public init(type: String, description: String? = nil, items: Items? = nil, enum: [String]? = nil) {
        self.type = type
        self.description = description
        self.items = items
        self.enum = `enum`
      }

      enum CodingKeys: String, CodingKey {
        case type, description, items
        case `enum`
      }

      public struct Items: Encodable, Sendable {
        public let type: String

        public init(type: String) {
          self.type = type
        }
      }
    }
  }
}

// MARK: - Tool Result

/// Result of executing a tool call.
public struct ToolResult: Sendable {
  public let content: String
  public let isError: Bool

  public init(content: String, isError: Bool) {
    self.content = content
    self.isError = isError
  }

  public static func success(_ content: String) -> ToolResult {
    ToolResult(content: content, isError: false)
  }

  public static func error(_ message: String) -> ToolResult {
    ToolResult(content: message, isError: true)
  }
}
