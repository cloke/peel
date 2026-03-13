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
  ///
  /// **Progressive discovery order** — tools are ordered by how frequently
  /// external agents (VS Code Copilot, CLI) need them. Many MCP clients
  /// only read the first page of tools/list and never follow `nextCursor`,
  /// so the most useful tools must appear first.
  ///
  /// Tier 1 (page 1): Inline meta-tools, RAG search, git, terminal, code edit
  /// Tier 2 (page 2): Chains, GitHub, repo, parallel, PR review
  /// Tier 3 (page 3+): Swarm, VM, chrome automation, UI, chat
  var allToolDefinitions: [ToolDefinition] {
    var defs = [ToolDefinition]()

    // --- Tier 1: Tools agents use constantly ---
    defs += inlineServiceToolDefinitions            // tools.search, state.*, screenshot, pii, etc. (~21)
    if let rag = ragToolsHandler { defs += rag.toolDefinitions }  // rag.search, rag.index, rag.skills, etc. (~47)
    defs += gitToolsHandler.toolDefinitions         // git.status, git.diff, git.log, etc. (~5)
    defs += terminalToolsHandler.toolDefinitions    // terminal.run, terminal.output (~3)
    if let codeEdit = codeEditToolsHandler { defs += codeEdit.toolDefinitions }  // code.edit.* (~3)
    defs += codeQualityToolsHandler.toolDefinitions // lint, format (~2)

    // --- Tier 2: Orchestration and project tools ---
    if let chain = chainToolsHandler { defs += chain.toolDefinitions }    // chains.run, chains.status, etc. (~19)
    if let github = githubToolsHandler { defs += github.toolDefinitions } // github.pr.*, github.issue.* (~11)
    defs += repoToolsHandler.toolDefinitions        // repo.* (~7)
    defs += worktreeToolsHandler.toolDefinitions    // worktree.* (~8)
    defs += parallelToolsHandler.toolDefinitions    // parallel.* (~16)
    defs += runToolsHandler.toolDefinitions         // runs.* (~4)
    defs += repoProfileToolsHandler.toolDefinitions // repo.profile.* (~3)
    defs += schedulingToolsHandler.toolDefinitions  // scheduling.* (~6)

    // --- Tier 3: Specialized / infrastructure ---
    defs += swarmToolsHandler.toolDefinitions       // swarm.* (~39)
    defs += vmToolsHandler.toolDefinitions          // vm.* (~11)
    defs += chromeToolsHandler.toolDefinitions      // chrome.* (~16)
    defs += uiToolsHandler.toolDefinitions          // ui.navigate, ui.tap, etc. (~7)
    if let chat = localChatToolsHandler { defs += chat.toolDefinitions }  // chat.* (~3)

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
        name: "tools.search",
        description: "Search all available MCP tools by keyword. Returns matching tools across all pages. Use this to discover tools instead of paginating through tools/list.",
        inputSchema: [
          "type": "object",
          "properties": [
            "query": ["type": "string", "description": "Keyword to search for in tool names and descriptions (case-insensitive)"],
            "category": ["type": "string", "description": "Optional: filter by category (ui, state, diagnostics, swarm, rag, chains, parallel, git, etc.)"]
          ]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "tools.categories",
        description: "List all tool categories with tool counts and example tool names. Use for orientation before searching.",
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
        name: "app.daemon.status",
        description: "Get daemon mode status: background mode, login item, and settings",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .app,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "app.daemon.configure",
        description: "Configure daemon mode settings: runInBackground and startAtLogin",
        inputSchema: [
          "type": "object",
          "properties": [
            "runInBackground": ["type": "boolean", "description": "Keep MCP server running when window is closed"],
            "startAtLogin": ["type": "boolean", "description": "Launch Peel automatically at login"]
          ]
        ],
        category: .app,
        isMutating: true
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

      // MARK: Chain Learnings
      MCPToolDefinition(
        name: "learnings.list",
        description: "List chain learnings (orchestration-level lessons from previous agent runs). Filters by repo path, category, or active status.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter by repository path"],
            "repoRemoteURL": ["type": "string", "description": "Filter by repo remote URL (fallback match)"],
            "category": ["type": "string", "description": "Filter by category (e.g. execution, planning, gate, verification)"],
            "activeOnly": ["type": "boolean", "description": "Only return active learnings (default: true)"],
            "limit": ["type": "integer", "description": "Max results (default: 20)"]
          ]
        ],
        category: .chains,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "learnings.add",
        description: "Add a chain learning (orchestration-level lesson). Auto-deduplicates against existing learnings.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Repository path this learning applies to, or '*' for global"],
            "repoRemoteURL": ["type": "string", "description": "Repo remote URL for cross-machine matching"],
            "category": ["type": "string", "description": "Category: execution, planning, gate, verification, configuration"],
            "summary": ["type": "string", "description": "Short summary of the learning"],
            "detail": ["type": "string", "description": "Detailed explanation"],
            "source": ["type": "string", "description": "Source: manual, auto, or agent (default: manual)"],
            "chainTemplateName": ["type": "string", "description": "Chain template this learning relates to"],
            "confidenceScore": ["type": "number", "description": "Confidence 0.0-1.0 (default: 0.5)"]
          ],
          "required": ["repoPath", "category", "summary"]
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "learnings.rate",
        description: "Rate a chain learning as helpful or unhelpful. Adjusts confidence score; unhelpful learnings are auto-deactivated after 3 strikes.",
        inputSchema: [
          "type": "object",
          "properties": [
            "id": ["type": "string", "description": "Learning UUID"],
            "helpful": ["type": "boolean", "description": "true = helpful, false = unhelpful"]
          ],
          "required": ["id", "helpful"]
        ],
        category: .chains,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "learnings.delete",
        description: "Delete a chain learning by ID.",
        inputSchema: [
          "type": "object",
          "properties": [
            "id": ["type": "string", "description": "Learning UUID"]
          ],
          "required": ["id"]
        ],
        category: .chains,
        isMutating: true
      ),
    ]
  }

  // MARK: - Tool List Helpers

  /// Page size for tools/list pagination. Sized to fit all Tier 1 tools
  /// (meta + RAG + git + terminal + code edit + quality ≈ 81) on page 1.
  /// VS Code / Copilot may silently drop tools beyond ~128 entries per page.
  private static let toolPageSize = 96

  /// Build a paginated tools/list response dictionary.
  /// If `cursor` is nil the first page is returned.
  /// The cursor is a simple base-10 offset string.
  func paginatedToolList(cursor: String? = nil) -> [String: Any] {
    let allTools = toolList()
    let offset = cursor.flatMap { Int($0) } ?? 0
    let safeOffset = min(max(offset, 0), allTools.count)
    let end = min(safeOffset + Self.toolPageSize, allTools.count)
    let page = Array(allTools[safeOffset..<end])

    var result: [String: Any] = ["tools": page]
    if end < allTools.count {
      result["nextCursor"] = String(end)
    }
    return result
  }

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
    // agentRuns.* → parallel.* alias (user-facing rename, tools keep parallel.* internally)
    if name.hasPrefix("agentRuns.") {
      let canonical = "parallel." + name.dropFirst("agentRuns.".count)
      return resolveToolName(canonical)
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
