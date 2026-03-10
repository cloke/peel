import Foundation
import MCPCore
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "XcodeToolHandler")

/// Handler for Xcode MCP tools.
/// Exposes Xcode's code intelligence, diagnostics, and refactoring capabilities
/// to Peel agents via the MCP protocol.
@MainActor
public final class XcodeToolHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  private let adapter: XcodeMCPAdapter

  init(adapter: XcodeMCPAdapter) {
    self.adapter = adapter
  }

  // MARK: - MCPToolHandler Conformance

  public var supportedTools: Set<String> {
    Set(Self.allTools)
  }

  public var toolDefinitions: [MCPToolDefinition] {
    Self.allTools.map { toolName in
      MCPToolDefinition(
        name: toolName,
        description: Self.toolDescription(for: toolName),
        inputSchema: Self.inputSchema(for: toolName),
        category: .codeEdit,
        isMutating: Self.isMutating(toolName)
      )
    }
  }

  public func handle(
    name: String,
    id: Any?,
    arguments: [String: Any]
  ) async -> (Int, Data) {
    logger.debug("XcodeToolHandler: Handling tool \(name)")

    do {
      let result = try await handleTool(name: name, arguments: arguments)
      return makeResult(id: id, content: result)
    } catch let error as XcodeToolError {
      logger.error("XcodeToolHandler error: \(error.localizedDescription)")
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32603, message: error.localizedDescription))
    } catch {
      logger.error("XcodeToolHandler unexpected error: \(error)")
      return (500, JSONRPCResponseBuilder.makeError(id: id, code: -32603, message: error.localizedDescription))
    }
  }

  // MARK: - Routing

  private func handleTool(
    name: String,
    arguments: [String: Any]
  ) async throws -> [String: Any] {
    let parts = name.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: true)

    guard parts.count >= 3 else {
      throw XcodeToolError.invalidToolName(name)
    }

    let category = String(parts[1])

    switch category {
    case "symbols":
      return try await handleSymbolsTool(name: name, arguments: arguments)
    case "diagnostics":
      return try await handleDiagnosticsTool(name: name, arguments: arguments)
    case "project":
      return try await passthrough(name: name, arguments: arguments)
    case "refactor":
      return try await handleRefactoringTool(name: name, arguments: arguments)
    case "build", "test":
      return try await passthrough(name: name, arguments: arguments)
    default:
      throw XcodeToolError.unknownCategory(category)
    }
  }

  // MARK: - Symbol Tools

  private func handleSymbolsTool(
    name: String,
    arguments: [String: Any]
  ) async throws -> [String: Any] {
    let operation = name.split(separator: ".").last.map(String.init) ?? ""

    switch operation {
    case "lookup":
      guard let symbol = arguments["symbol"] as? String else {
        throw XcodeToolError.missingParameter("symbol")
      }
      var args: [String: Any] = ["symbol": symbol]
      if let file = arguments["file"] as? String { args["file"] = file }
      return try await adapter.callTool(toolName: name, arguments: args)

    case "references":
      guard let symbol = arguments["symbol"] as? String else {
        throw XcodeToolError.missingParameter("symbol")
      }
      return try await adapter.callTool(toolName: name, arguments: ["symbol": symbol])

    case "rename":
      guard let oldName = arguments["oldName"] as? String,
            let newName = arguments["newName"] as? String else {
        throw XcodeToolError.missingParameters(["oldName", "newName"])
      }
      return try await adapter.callTool(toolName: name, arguments: ["oldName": oldName, "newName": newName])

    default:
      return try await passthrough(name: name, arguments: arguments)
    }
  }

  // MARK: - Diagnostics Tools

  private func handleDiagnosticsTool(
    name: String,
    arguments: [String: Any]
  ) async throws -> [String: Any] {
    let operation = name.split(separator: ".").last.map(String.init) ?? ""

    switch operation {
    case "get":
      var params: [String: Any] = [:]
      if let file = arguments["file"] as? String { params["file"] = file }
      if let cat = arguments["category"] as? String { params["category"] = cat }
      return try await adapter.callTool(toolName: name, arguments: params)

    default:
      return try await passthrough(name: name, arguments: arguments)
    }
  }

  // MARK: - Refactoring Tools

  private func handleRefactoringTool(
    name: String,
    arguments: [String: Any]
  ) async throws -> [String: Any] {
    let operation = name.split(separator: ".").last.map(String.init) ?? ""

    switch operation {
    case "autoFix":
      guard let issueId = arguments["issueId"] as? String else {
        throw XcodeToolError.missingParameter("issueId")
      }
      return try await adapter.callTool(toolName: name, arguments: ["issueId": issueId])

    case "formatCode":
      guard let files = arguments["files"] as? [String] else {
        throw XcodeToolError.missingParameter("files")
      }
      return try await adapter.callTool(toolName: name, arguments: ["files": files])

    default:
      return try await passthrough(name: name, arguments: arguments)
    }
  }

  // MARK: - Helpers

  private func passthrough(name: String, arguments: [String: Any]) async throws -> [String: Any] {
    try await adapter.callTool(toolName: name, arguments: arguments)
  }

  private func makeResult(id: Any?, content: [String: Any]) -> (Int, Data) {
    (200, makeResult(id: id, result: content))
  }

  // MARK: - Tool Catalog

  static let allTools: [String] = [
    // Symbols & Code Intelligence
    "xcode.symbols.lookup",
    "xcode.symbols.references",
    "xcode.symbols.typeInfo",
    "xcode.symbols.documentation",
    "xcode.symbols.rename",
    "xcode.symbols.hierarchy",
    "xcode.symbols.conformances",
    "xcode.symbols.usage",
    "xcode.symbols.definitionLocation",
    "xcode.symbols.completion",
    "xcode.symbols.quickHelp",
    "xcode.symbols.breadcrumbs",
    "xcode.symbols.interfaces",
    "xcode.symbols.callGraph",

    // Diagnostics & Analysis
    "xcode.diagnostics.get",
    "xcode.diagnostics.forFile",
    "xcode.diagnostics.forRange",
    "xcode.diagnostics.concurrency",
    "xcode.diagnostics.memorySafety",
    "xcode.diagnostics.performance",
    "xcode.diagnostics.security",
    "xcode.diagnostics.accessibility",
    "xcode.diagnostics.localization",
    "xcode.diagnostics.api",
    "xcode.diagnostics.deprecated",
    "xcode.diagnostics.warnings",

    // Project Information
    "xcode.project.getInfo",
    "xcode.project.getTargets",
    "xcode.project.getSchemes",
    "xcode.project.getDependencies",
    "xcode.project.getFrameworks",
    "xcode.project.getFiles",
    "xcode.project.getFilesByType",
    "xcode.project.getBuildSettings",
    "xcode.project.getDeploymentTarget",
    "xcode.project.getConventions",
    "xcode.project.getLocalization",

    // Refactoring & Fixes
    "xcode.refactor.extractMethod",
    "xcode.refactor.extractVariable",
    "xcode.refactor.moveToFile",
    "xcode.refactor.autoFix",
    "xcode.refactor.formatCode",
    "xcode.refactor.modernizeSwift",
    "xcode.refactor.addImports",
    "xcode.refactor.changeSignature",
    "xcode.refactor.inlineFunction",
    "xcode.refactor.extractProtocol",

    // Build & Validation
    "xcode.build.validate",
    "xcode.build.compile",
    "xcode.build.getErrors",
    "xcode.build.getWarnings",
    "xcode.build.analyze",
    "xcode.test.run",
    "xcode.test.coverage",
    "xcode.test.getResults",
  ]

  static func toolDescription(for toolName: String) -> String {
    switch toolName {
    case "xcode.symbols.lookup": return "Find symbol definition and location"
    case "xcode.symbols.references": return "Find all references to a symbol"
    case "xcode.symbols.typeInfo": return "Get type information for a symbol"
    case "xcode.symbols.documentation": return "Get documentation for a symbol"
    case "xcode.symbols.rename": return "Rename a symbol across the project (type-safe)"
    case "xcode.symbols.hierarchy": return "Get inheritance/protocol hierarchy"
    case "xcode.symbols.conformances": return "Get protocol conformances"
    case "xcode.symbols.usage": return "Get all usage locations for a symbol"
    case "xcode.symbols.definitionLocation": return "Get exact definition location"
    case "xcode.symbols.completion": return "Get code completion suggestions"
    case "xcode.symbols.quickHelp": return "Get quick help text for a symbol"
    case "xcode.symbols.breadcrumbs": return "Get breadcrumb path to a symbol"
    case "xcode.symbols.interfaces": return "Get all public interfaces in a module"
    case "xcode.symbols.callGraph": return "Get call graph for a function"

    case "xcode.diagnostics.get": return "Get compilation diagnostics"
    case "xcode.diagnostics.forFile": return "Get diagnostics for a specific file"
    case "xcode.diagnostics.forRange": return "Get diagnostics for a code range"
    case "xcode.diagnostics.concurrency": return "Get Swift 6 concurrency issues"
    case "xcode.diagnostics.memorySafety": return "Get memory safety warnings"
    case "xcode.diagnostics.performance": return "Get performance warnings"
    case "xcode.diagnostics.security": return "Get security issues"
    case "xcode.diagnostics.accessibility": return "Get accessibility issues"
    case "xcode.diagnostics.localization": return "Get localization issues"
    case "xcode.diagnostics.api": return "Get API availability issues"
    case "xcode.diagnostics.deprecated": return "Get deprecated API usage"
    case "xcode.diagnostics.warnings": return "Get all warnings"

    case "xcode.project.getInfo": return "Get project information and metadata"
    case "xcode.project.getTargets": return "List all build targets"
    case "xcode.project.getSchemes": return "List all build schemes"
    case "xcode.project.getDependencies": return "Get package dependencies"
    case "xcode.project.getFrameworks": return "Get linked frameworks"
    case "xcode.project.getFiles": return "List files in project"
    case "xcode.project.getFilesByType": return "Get files of specific type"
    case "xcode.project.getBuildSettings": return "Get build configuration settings"
    case "xcode.project.getDeploymentTarget": return "Get deployment target versions"
    case "xcode.project.getConventions": return "Get project coding conventions"
    case "xcode.project.getLocalization": return "Get localization settings"

    case "xcode.refactor.extractMethod": return "Extract code into a new method"
    case "xcode.refactor.extractVariable": return "Extract expression into a variable"
    case "xcode.refactor.moveToFile": return "Move symbol to different file"
    case "xcode.refactor.autoFix": return "Apply automatic fix for a diagnostic"
    case "xcode.refactor.formatCode": return "Format code according to style guide"
    case "xcode.refactor.modernizeSwift": return "Modernize code to current Swift version"
    case "xcode.refactor.addImports": return "Automatically add needed imports"
    case "xcode.refactor.changeSignature": return "Change function/method signature"
    case "xcode.refactor.inlineFunction": return "Inline function calls"
    case "xcode.refactor.extractProtocol": return "Extract protocol from type"

    case "xcode.build.validate": return "Check if code will compile without building"
    case "xcode.build.compile": return "Compile the current scheme"
    case "xcode.build.getErrors": return "Get build errors"
    case "xcode.build.getWarnings": return "Get build warnings"
    case "xcode.build.analyze": return "Run static analyzer"
    case "xcode.test.run": return "Run tests"
    case "xcode.test.coverage": return "Get code coverage information"
    case "xcode.test.getResults": return "Get test results"

    default: return "Xcode MCP tool"
    }
  }

  static func inputSchema(for toolName: String) -> [String: Any] {
    switch toolName {
    case "xcode.symbols.lookup":
      return [
        "type": "object",
        "properties": [
          "symbol": ["type": "string", "description": "The symbol name to look up"],
          "file": ["type": "string", "description": "Optional file to scope the search"]
        ],
        "required": ["symbol"]
      ]
    case "xcode.symbols.references":
      return [
        "type": "object",
        "properties": [
          "symbol": ["type": "string", "description": "The symbol to find references for"]
        ],
        "required": ["symbol"]
      ]
    case "xcode.symbols.rename":
      return [
        "type": "object",
        "properties": [
          "oldName": ["type": "string", "description": "Current symbol name"],
          "newName": ["type": "string", "description": "New symbol name"]
        ],
        "required": ["oldName", "newName"]
      ]
    case "xcode.diagnostics.get":
      return [
        "type": "object",
        "properties": [
          "file": ["type": "string", "description": "Optional file to filter diagnostics"],
          "category": ["type": "string", "description": "Optional category filter"]
        ]
      ]
    case "xcode.diagnostics.forFile":
      return [
        "type": "object",
        "properties": [
          "file": ["type": "string", "description": "File path to get diagnostics for"]
        ],
        "required": ["file"]
      ]
    case "xcode.refactor.autoFix":
      return [
        "type": "object",
        "properties": [
          "issueId": ["type": "string", "description": "The diagnostic issue ID to auto-fix"]
        ],
        "required": ["issueId"]
      ]
    case "xcode.refactor.formatCode":
      return [
        "type": "object",
        "properties": [
          "files": ["type": "array", "description": "Files to format", "items": ["type": "string"]]
        ],
        "required": ["files"]
      ]
    case "xcode.build.validate":
      return [
        "type": "object",
        "properties": [
          "files": ["type": "array", "description": "Optional list of files to validate", "items": ["type": "string"]]
        ]
      ]
    case "xcode.test.run":
      return [
        "type": "object",
        "properties": [
          "pattern": ["type": "string", "description": "Optional test name pattern to filter"]
        ]
      ]
    default:
      return ["type": "object", "properties": [:] as [String: Any]]
    }
  }

  static func isMutating(_ toolName: String) -> Bool {
    let mutating: Set<String> = [
      "xcode.symbols.rename",
      "xcode.refactor.extractMethod",
      "xcode.refactor.extractVariable",
      "xcode.refactor.moveToFile",
      "xcode.refactor.autoFix",
      "xcode.refactor.formatCode",
      "xcode.refactor.modernizeSwift",
      "xcode.refactor.addImports",
      "xcode.refactor.changeSignature",
      "xcode.refactor.inlineFunction",
      "xcode.refactor.extractProtocol",
      "xcode.build.compile",
      "xcode.test.run",
    ]
    return mutating.contains(toolName)
  }
}

// MARK: - Error Types

enum XcodeToolError: LocalizedError {
  case invalidToolName(String)
  case unknownCategory(String)
  case missingParameter(String)
  case missingParameters([String])
  case callFailed(String)
  case xcodeNotAvailable

  var errorDescription: String? {
    switch self {
    case .invalidToolName(let name):
      return "Invalid Xcode tool name: \(name)"
    case .unknownCategory(let category):
      return "Unknown tool category: \(category)"
    case .missingParameter(let param):
      return "Missing required parameter: \(param)"
    case .missingParameters(let params):
      return "Missing required parameters: \(params.joined(separator: ", "))"
    case .callFailed(let reason):
      return "Xcode tool call failed: \(reason)"
    case .xcodeNotAvailable:
      return "Xcode is not available. Ensure Xcode 26.3+ is installed and running."
    }
  }
}
