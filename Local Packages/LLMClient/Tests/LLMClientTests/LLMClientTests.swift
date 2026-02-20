import Foundation
import Testing
@testable import LLMClient

@Suite("JSONValue Tests")
struct JSONValueTests {
  @Test("Encode and decode string")
  func stringRoundTrip() throws {
    let value = JSONValue.string("hello")
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded.stringValue == "hello")
  }

  @Test("Encode and decode int")
  func intRoundTrip() throws {
    let value = JSONValue.int(42)
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded.intValue == 42)
  }

  @Test("Encode and decode bool")
  func boolRoundTrip() throws {
    let value = JSONValue.bool(true)
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded.boolValue == true)
  }

  @Test("Encode and decode object")
  func objectRoundTrip() throws {
    let value = JSONValue.object(["key": .string("value"), "count": .int(3)])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded.objectValue?["key"]?.stringValue == "value")
    #expect(decoded.objectValue?["count"]?.intValue == 3)
  }

  @Test("ToolDefinition encodes correctly")
  func toolDefinitionEncoding() throws {
    let tool = ToolDefinition(
      name: "test_tool",
      description: "A test tool",
      input_schema: .init(
        type: "object",
        properties: [
          "path": .init(type: "string", description: "File path"),
        ],
        required: ["path"]
      )
    )
    let data = try JSONEncoder().encode(tool)
    let json = try JSONDecoder().decode([String: JSONValue].self, from: data)
    #expect(json["name"]?.stringValue == "test_tool")
  }

  @Test("ToolResult success and error")
  func toolResultHelpers() {
    let success = ToolResult.success("ok")
    #expect(success.isError == false)
    #expect(success.content == "ok")

    let error = ToolResult.error("fail")
    #expect(error.isError == true)
    #expect(error.content == "fail")
  }

  @Test("ContentBlock text round-trip")
  func contentBlockText() throws {
    let block = ContentBlock.text("hello")
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    if case .text(let t) = decoded {
      #expect(t == "hello")
    } else {
      Issue.record("Expected text block")
    }
  }
}
