import XCTest
@testable import MCPCore

final class MCPCoreTests: XCTestCase {

  // MARK: - JSON-RPC Tests

  func testJSONRPCIdString() throws {
    let id = JSONRPCId.string("test-123")
    XCTAssertEqual(id, .string("test-123"))

    let data = try JSONEncoder().encode(id)
    let decoded = try JSONDecoder().decode(JSONRPCId.self, from: data)
    XCTAssertEqual(decoded, id)
  }

  func testJSONRPCIdNumber() throws {
    let id = JSONRPCId.number(42)
    XCTAssertEqual(id.anyValue as? Int, 42)

    let data = try JSONEncoder().encode(id)
    let decoded = try JSONDecoder().decode(JSONRPCId.self, from: data)
    XCTAssertEqual(decoded, id)
  }

  func testJSONRPCError() {
    let error = JSONRPCError.invalidParams("Missing required field")
    XCTAssertEqual(error.code, -32602)
    XCTAssertTrue(error.message.contains("Missing"))
  }

  // MARK: - Tool Definition Tests

  func testToolCategory() {
    XCTAssertEqual(MCPToolCategory.chains.displayName, "Chains")
    XCTAssertEqual(MCPToolCategory.rag.displayName, "Local RAG")
    XCTAssertTrue(MCPToolCategory.allCases.count > 5)
  }

  func testToolGroup() {
    XCTAssertEqual(MCPToolGroup.screenshots.displayName, "Screenshots")
    XCTAssertEqual(MCPToolGroup.mutating.displayName, "Mutating")
  }

  // MARK: - Agent Type Tests

  func testAgentRole() {
    XCTAssertEqual(MCPAgentRole.planner.displayName, "Planner")
    XCTAssertFalse(MCPAgentRole.planner.canWrite)
    XCTAssertTrue(MCPAgentRole.implementer.canWrite)
    XCTAssertFalse(MCPAgentRole.reviewer.canWrite)
  }

  func testAgentRoleFromString() {
    XCTAssertEqual(MCPAgentRole.fromString("planner"), .planner)
    XCTAssertEqual(MCPAgentRole.fromString("IMPLEMENTER"), .implementer)
    XCTAssertNil(MCPAgentRole.fromString("invalid"))
  }

  // MARK: - Model Tests

  func testCopilotModel() {
    XCTAssertEqual(MCPCopilotModel.claudeSonnet45.displayName, "Claude Sonnet 4.5")
    XCTAssertEqual(MCPCopilotModel.gpt41.premiumCost, 0)
    XCTAssertTrue(MCPCopilotModel.gpt41.isFree)
    XCTAssertFalse(MCPCopilotModel.claudeOpus45.isFree)
  }

  func testCopilotModelFamily() {
    XCTAssertTrue(MCPCopilotModel.claudeSonnet45.isClaude)
    XCTAssertTrue(MCPCopilotModel.gpt51.isGPT)
    XCTAssertTrue(MCPCopilotModel.gemini3Pro.isGemini)
  }

  // MARK: - Chain Template Tests

  func testChainTemplate() {
    let template = MCPChainTemplate(
      name: "Test Template",
      description: "A test",
      steps: [
        MCPAgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Planner"),
        MCPAgentStepTemplate(role: .implementer, model: .gpt41, name: "Implementer")
      ]
    )

    XCTAssertEqual(template.name, "Test Template")
    XCTAssertEqual(template.steps.count, 2)
    XCTAssertEqual(template.estimatedTotalCost, 1.0) // Sonnet=1.0, GPT-4.1=0
  }

  func testBuiltInTemplates() {
    let templates = MCPChainTemplate.builtInTemplates
    XCTAssertFalse(templates.isEmpty)
    XCTAssertTrue(templates.contains { $0.name == "Code Review" })
    XCTAssertTrue(templates.contains { $0.name == "Parallel Validation" })
  }

  // MARK: - DTO Tests

  func testMCPRunRecordDTO() throws {
    let record = MCPRunRecordDTO(
      chainId: "chain-123",
      templateName: "Test",
      prompt: "Fix the bug",
      success: true,
      resultCount: 3
    )

    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(MCPRunRecordDTO.self, from: data)

    XCTAssertEqual(decoded.chainId, "chain-123")
    XCTAssertEqual(decoded.templateName, "Test")
    XCTAssertTrue(decoded.success)
  }

  // MARK: - Framework Hint Tests

  func testFrameworkHint() {
    XCTAssertFalse(MCPFrameworkHint.swift.instructions.isEmpty)
    XCTAssertTrue(MCPFrameworkHint.auto.instructions.isEmpty)
  }
}
