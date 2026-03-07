//
//  MCPRAGToolsTests.swift
//  Peel
//
//  Integration tests for RAG-related MCP tools
//

import XCTest
@testable import Peel

#if os(macOS)

@MainActor
final class MCPRAGToolsTests: XCTestCase {

  var mcpServer: MCPServerService?

  override func setUp() async throws {
    try await super.setUp()
    mcpServer = nil
  }

  private func server() -> MCPServerService {
    if let mcpServer {
      return mcpServer
    }
    let created = MCPServerService(config: MCPFileConfig())
    mcpServer = created
    return created
  }

  // MARK: - Tool Availability Tests

  /// Test that rag.analyze tool is registered
  func testRAGAnalyzeToolExists() {
    let allTools = server().allToolDefinitions

    let ragAnalyzeTool = allTools.first { $0.name == "rag.analyze" }
    XCTAssertNotNil(ragAnalyzeTool, "rag.analyze tool should be registered")

    if let tool = ragAnalyzeTool {
      XCTAssertTrue(
        tool.description.lowercased().contains("analy"),
        "Tool description should mention analysis"
      )
      if let schema = tool.inputSchema as? [String: Any],
        let properties = schema["properties"] as? [String: Any]
      {
        XCTAssertNotNil(properties["limit"], "Should have limit parameter")
      }
    }
  }

  /// Test that rag.analyze.status tool is registered
  func testRAGAnalyzeStatusToolExists() {
    let statusTool = server().allToolDefinitions.first { $0.name == "rag.analyze.status" }
    XCTAssertNotNil(statusTool, "rag.analyze.status tool should be registered")
  }

  /// Test that rag.index tool is registered
  func testRAGIndexToolExists() {
    let indexTool = server().allToolDefinitions.first { $0.name == "rag.index" }
    XCTAssertNotNil(indexTool, "rag.index tool should be registered")

    if let tool = indexTool {
      XCTAssertTrue(
        tool.description.lowercased().contains("index"),
        "Tool description should mention indexing"
      )
    }
  }

  /// Test that rag.search tool is registered
  func testRAGSearchToolExists() {
    let searchTool = server().allToolDefinitions.first { $0.name == "rag.search" }
    XCTAssertNotNil(searchTool, "rag.search tool should be registered")
  }

  /// Test that repos.delete tool is registered
  /// Regression: Tool was added to fix database cleanup
  func testReposDeleteToolExists() {
    let deleteTool = server().allToolDefinitions.first { $0.name == "repos.delete" }
    XCTAssertNotNil(deleteTool, "repos.delete tool should be registered")

    if let tool = deleteTool {
      XCTAssertTrue(tool.isMutating, "repos.delete should be marked as mutating")
      XCTAssertEqual(tool.category, .state, "repos.delete should be in state category")
    }
  }

  /// Test that swarm.reindex tool is registered
  func testSwarmReindexToolExists() {
    let reindexTool = server().allToolDefinitions.first { $0.name == "swarm.reindex" }
    XCTAssertNotNil(reindexTool, "swarm.reindex tool should be registered")

    if let tool = reindexTool {
      XCTAssertTrue(tool.isMutating, "swarm.reindex should be mutating")
    }
  }

  // MARK: - Parameter Validation Tests

  /// Test that rag.analyze has expected parameters in its schema
  func testRAGAnalyzeParameterSchema() {
    let ragAnalyzeTool = server().allToolDefinitions.first { $0.name == "rag.analyze" }

    guard let tool = ragAnalyzeTool,
      let schema = tool.inputSchema as? [String: Any],
      let properties = schema["properties"] as? [String: Any]
    else {
      XCTFail("Tool should have valid schema with properties")
      return
    }

    XCTAssertNotNil(properties["repoPath"], "Should have repoPath parameter")
    XCTAssertNotNil(properties["limit"], "Should have limit parameter")
  }

  /// Test that rag.search has expected parameters
  func testRAGSearchParameterSchema() {
    let searchTool = server().allToolDefinitions.first { $0.name == "rag.search" }

    guard let tool = searchTool,
      let schema = tool.inputSchema as? [String: Any],
      let properties = schema["properties"] as? [String: Any]
    else {
      XCTFail("rag.search should have valid schema with properties")
      return
    }

    XCTAssertNotNil(properties["query"], "Should have query parameter")
    XCTAssertNotNil(properties["mode"], "Should have mode parameter")
  }

  /// Test that rag.orphans exposes filtering parameters for actionable audits
  func testRAGOrphansParameterSchema() {
    let orphansTool = server().allToolDefinitions.first { $0.name == "rag.orphans" }

    guard let tool = orphansTool,
      let schema = tool.inputSchema as? [String: Any],
      let properties = schema["properties"] as? [String: Any]
    else {
      XCTFail("rag.orphans should have valid schema with properties")
      return
    }

    XCTAssertNotNil(properties["repoPath"], "Should have repoPath parameter")
    XCTAssertNotNil(properties["includeNonCode"], "Should have includeNonCode parameter")
    XCTAssertNotNil(properties["respectBaseline"], "Should have respectBaseline parameter")
    XCTAssertNotNil(properties["baselinePath"], "Should have baselinePath parameter")
  }

  /// Test repos.delete parameter schema
  func testReposDeleteParameterSchema() {
    let deleteTool = server().allToolDefinitions.first { $0.name == "repos.delete" }

    guard let tool = deleteTool,
      let schema = tool.inputSchema as? [String: Any],
      let properties = schema["properties"] as? [String: Any]
    else {
      XCTFail("repos.delete should have valid schema with properties")
      return
    }

    // Should accept either repoId or localPath
    XCTAssertNotNil(properties["repoId"], "Should have repoId parameter")
    XCTAssertNotNil(properties["localPath"], "Should have localPath parameter")
  }

  /// Test swarm.reindex parameter schema
  func testSwarmReindexParameterSchema() {
    let reindexTool = server().allToolDefinitions.first { $0.name == "swarm.reindex" }

    guard let tool = reindexTool,
      let schema = tool.inputSchema as? [String: Any],
      let properties = schema["properties"] as? [String: Any],
      let required = schema["required"] as? [String]
    else {
      XCTFail("swarm.reindex should have valid schema with properties")
      return
    }

    XCTAssertNotNil(properties["repoPath"], "Should have repoPath parameter")
    XCTAssertNotNil(properties["workerId"], "Should have workerId parameter")
    XCTAssertNotNil(properties["pullFirst"], "Should have pullFirst parameter")
    XCTAssertNotNil(properties["forceReindex"], "Should have forceReindex parameter")
    XCTAssertNotNil(properties["allowWorkspace"], "Should have allowWorkspace parameter")
    XCTAssertNotNil(properties["excludeSubrepos"], "Should have excludeSubrepos parameter")
    XCTAssertTrue(required.contains("repoPath"), "repoPath should be required")
  }
  // MARK: - Tool Categories

  /// Test that RAG tools are properly categorized
  func testRAGToolsCategorization() {
    let allTools = server().allToolDefinitions
    let ragTools = allTools.filter { $0.name.hasPrefix("rag.") }

    XCTAssertFalse(ragTools.isEmpty, "Should have RAG tools")

    for tool in ragTools {
      XCTAssertEqual(
        tool.category, .rag,
        "\(tool.name) should be in rag category"
      )
    }
  }

  /// Test that repos tools are in state category
  func testReposToolsCategorization() {
    let allTools = server().allToolDefinitions
    let reposTools = allTools.filter { $0.name.hasPrefix("repos.") }

    XCTAssertFalse(reposTools.isEmpty, "Should have repos tools")

    for tool in reposTools {
      XCTAssertEqual(
        tool.category, .state,
        "\(tool.name) should be in state category"
      )
    }
  }

  // MARK: - Tool Completeness

  /// Test that all expected RAG tools are present
  func testAllExpectedRAGToolsPresent() {
    let expectedTools = [
      "rag.index",
      "rag.search",
      "rag.analyze",
      "rag.analyze.status",
      "rag.status",
    ]

    let allTools = server().allToolDefinitions
    let toolNames = Set(allTools.map { $0.name })

    for expected in expectedTools {
      XCTAssertTrue(
        toolNames.contains(expected),
        "Expected tool '\(expected)' should be registered"
      )
    }
  }

  /// Test that all expected repo tools are present
  func testAllExpectedRepoToolsPresent() {
    let expectedTools = [
      "repos.list",
      "repos.resolve",
      "repos.delete",
    ]

    let allTools = server().allToolDefinitions
    let toolNames = Set(allTools.map { $0.name })

    for expected in expectedTools {
      XCTAssertTrue(
        toolNames.contains(expected),
        "Expected tool '\(expected)' should be registered"
      )
    }
  }
}

#endif
