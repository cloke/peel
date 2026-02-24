import Foundation
import MCPCore

// MARK: - Tool Definitions
// Aggregated from all MCPToolHandler implementations.
// Only tools handled directly by MCPServerService+ServerCore are defined here.
// For handler-owned tools, see toolDefinitions in each ToolHandlers/*.swift file.

extension MCPServerService {
  var allowForegroundTools: Bool {
    config.bool(forKey: StorageKey.allowForegroundTools, default: true)
  }

  func toolDefinition(named name: String) -> ToolDefinition? {
    allToolDefinitions.first { $0.name == name }
  }

  var activeToolDefinitions: [ToolDefinition] {
    guard allowForegroundTools else {
      return allToolDefinitions.filter { !$0.requiresForeground }
    }
    return allToolDefinitions
  }

  /// All tool definitions aggregated from handlers + inline service tools.
  var allToolDefinitions: [ToolDefinition] {
    var defs = [ToolDefinition]()
    defs += uiToolsHandler.toolDefinitions
    defs += vmToolsHandler.toolDefinitions
    defs += parallelToolsHandler.toolDefinitions
    defs += swarmToolsHandler.toolDefinitions
    defs += repoToolsHandler.toolDefinitions
    defs += worktreeToolsHandler.toolDefinitions
    defs += terminalToolsHandler.toolDefinitions
    defs += gitToolsHandler.toolDefinitions
    if let rag = ragToolsHandler { defs += rag.toolDefinitions }
    if let codeEdit = codeEditToolsHandler { defs += codeEdit.toolDefinitions }
    if let chain = chainToolsHandler { defs += chain.toolDefinitions }
    if let github = githubToolsHandler { defs += github.toolDefinitions }
    #if os(macOS)
    if let chat = localChatToolsHandler { defs += chat.toolDefinitions }
    #endif
    defs += inlineServiceToolDefinitions
    return defs
  }

  // MARK: - Inline Service Tool Definitions
  // Tools handled directly in MCPServerService+ServerCore (not via MCPToolHandler).
  private var inlineServiceToolDefinitions: [ToolDefinition] {
    [
      MCPToolDefinition(
        name: "state.get",
        description: "Get current app state summary",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "state.readonly",
        description: "Background-safe, read-only state snapshot",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "state.list",
        description: "List available view IDs and tools",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "logs.mcp.path",
        description: "Get MCP log file path",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .logs,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "logs.mcp.tail",
        description: "Get last N lines of MCP log",
        inputSchema: [
          "type": "object",
          "properties": [
            "lines": ["type": "integer"]
          ]
        ],
        category: .logs,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "server.stop",
        description: "Stop the MCP server",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "server.restart",
        description: "Restart the MCP server",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "server.port.set",
        description: "Set MCP server port and restart",
        inputSchema: [
          "type": "object",
          "properties": [
            "port": ["type": "integer"],
            "autoFind": ["type": "boolean"],
            "maxAttempts": ["type": "integer"]
          ],
          "required": ["port"]
        ],
        category: .server,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "server.status",
        description: "Get MCP server status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "server.sleep.prevent",
        description: "Enable or disable system sleep prevention",
        inputSchema: [
          "type": "object",
          "properties": [
            "enabled": ["type": "boolean"]
          ],
          "required": ["enabled"]
        ],
        category: .server,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "server.sleep.prevent.status",
        description: "Get sleep prevention status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "server.lan",
        description: "Enable or disable LAN mode (accept MCP connections from network, not just localhost). WARNING: Only use on trusted networks - no authentication.",
        inputSchema: [
          "type": "object",
          "properties": [
            "enabled": ["type": "boolean", "description": "true to enable LAN mode, false to restrict to localhost only"]
          ],
          "required": ["enabled"]
        ],
        category: .server,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "app.quit",
        description: "Quit the Peel app",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .app,
        isMutating: true,
        requiresForeground: true
      ),
      MCPToolDefinition(
        name: "app.activate",
        description: "Bring the Peel app to the foreground",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .app,
        isMutating: true,
        requiresForeground: true
      ),
      MCPToolDefinition(
        name: "screenshot.capture",
        description: "Capture screenshot of current screen state",
        inputSchema: [
          "type": "object",
          "properties": [
            "label": ["type": "string"],
            "outputDir": ["type": "string"]
          ]
        ],
        category: .diagnostics,
        isMutating: false,
        requiresForeground: true
      ),
      MCPToolDefinition(
        name: "translations.validate",
        description: "Validate translation key parity and consistency",
        inputSchema: [
          "type": "object",
          "properties": [
            "root": ["type": "string"],
            "translationsPath": ["type": "string"],
            "baseLocale": ["type": "string"],
            "only": ["type": "string"],
            "summary": ["type": "boolean"],
            "toolPath": ["type": "string"],
            "useAppleAI": ["type": "boolean"],
            "redactSamples": ["type": "boolean"]
          ]
        ],
        category: .diagnostics,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "pii.scrub",
        description: "Scrub PII from a text file using the pii-scrubber CLI",
        inputSchema: [
          "type": "object",
          "properties": [
            "inputPath": ["type": "string"],
            "outputPath": ["type": "string"],
            "reportPath": ["type": "string"],
            "reportFormat": ["type": "string"],
            "configPath": ["type": "string"],
            "seed": ["type": "string"],
            "maxSamples": ["type": "integer"],
            "enableNER": ["type": "boolean"],
            "toolPath": ["type": "string"]
          ],
          "required": ["inputPath", "outputPath"]
        ],
        category: .diagnostics,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "docling.convert",
        description: "Convert a document (PDF, etc.) to Markdown using Docling",
        inputSchema: [
          "type": "object",
          "properties": [
            "inputPath": ["type": "string"],
            "outputPath": ["type": "string"],
            "pythonPath": ["type": "string", "description": "Optional path to python3"],
            "scriptPath": ["type": "string", "description": "Optional path to Tools/docling-convert.py"],
            "profile": ["type": "string", "description": "Conversion profile: high or standard"],
            "includeText": ["type": "boolean", "description": "Include markdown text in response"],
            "maxChars": ["type": "integer", "description": "Max chars to include if includeText is true"]
          ],
          "required": ["inputPath", "outputPath"]
        ],
        category: .diagnostics,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "docling.setup",
        description: "Install Docling into Peel's Application Support venv",
        inputSchema: [
          "type": "object",
          "properties": [
            "pythonPath": ["type": "string", "description": "Optional path to python3 for venv creation"]
          ]
        ],
        category: .diagnostics,
        isMutating: true
      ),
    ]
  }

  // MARK: - Tool List Helpers

  func toolList() -> [[String: Any]] {
    activeToolDefinitions.map { tool in
      [
        "name": sanitizedToolName(tool.name),
        "originalName": tool.name,
        "description": tool.description,
        "inputSchema": tool.inputSchema,
        "category": tool.category.rawValue,
        "groups": groups(for: tool).map { $0.rawValue },
        "enabled": isToolEnabled(tool.name),
        "requiresForeground": tool.requiresForeground
      ]
    }
  }

  func sanitizedToolName(_ name: String) -> String {
    let lowercased = name.lowercased()
    return lowercased.map { char in
      let isAllowed = (char >= "a" && char <= "z") || (char >= "0" && char <= "9") || char == "_" || char == "-"
      return isAllowed ? String(char) : "_"
    }.joined()
  }

  func resolveToolName(_ name: String) -> String? {
    if toolDefinition(named: name) != nil {
      return name
    }
    let match = allToolDefinitions.first { sanitizedToolName($0.name) == name }
    if let match {
      return match.name
    }
    let dotted = name.replacingOccurrences(of: "_", with: ".")
    if toolDefinition(named: dotted) != nil {
      return dotted
    }
    return nil
  }

  func groups(for tool: ToolDefinition) -> [ToolGroup] {
    var groups: [ToolGroup] = []
    if tool.name == "screenshot.capture" {
      groups.append(.screenshots)
    }
    if tool.name == "ui.navigate" || tool.name == "ui.back" || tool.name == "ui.snapshot" {
      groups.append(.uiNavigation)
    }
    if tool.isMutating {
      groups.append(.mutating)
    }
    if !tool.requiresForeground {
      groups.append(.backgroundSafe)
    }
    return groups
  }
}
