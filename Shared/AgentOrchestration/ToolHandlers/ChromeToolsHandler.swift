//
//  ChromeToolsHandler.swift
//  Peel
//
//  MCP tool handler for Chrome browser automation in parallel UX testing.
//  Provides chrome.launch, chrome.navigate, chrome.screenshot, chrome.snapshot,
//  chrome.close, and chrome.status tools.
//
//  Each parallel agent gets its own Chrome instance + dev server via UXTestOrchestrator.
//

import Foundation
import MCPCore
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "ChromeToolsHandler")

/// Handles Chrome browser automation tools for parallel UX testing.
@MainActor
public final class ChromeToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  /// The UX test orchestrator that manages Chrome + dev server sessions
  var orchestrator: UXTestOrchestrator?

  public let supportedTools: Set<String> = [
    "chrome.launch",
    "chrome.navigate",
    "chrome.screenshot",
    "chrome.snapshot",
    "chrome.close",
    "chrome.status"
  ]

  public init() {}

  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let orchestrator else {
      return serviceNotActiveError(id: id, service: "UX Test Orchestrator",
        hint: "UX testing is not initialized. The orchestrator must be configured before using Chrome tools.")
    }

    switch name {
    case "chrome.launch":
      return await handleLaunch(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.navigate":
      return await handleNavigate(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.screenshot":
      return await handleScreenshot(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.snapshot":
      return await handleSnapshot(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.close":
      return await handleClose(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.status":
      return handleStatus(id: id, orchestrator: orchestrator)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }

  // MARK: - chrome.launch

  /// Launch a new UX test session: allocate ports, start FE dev server, launch headless Chrome.
  /// All FE dev servers share the same local Rails backend — only frontend is per-worktree.
  private func handleLaunch(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let worktreePath) = requireString("worktreePath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "worktreePath")
    }

    let sessionIdStr = optionalString("sessionId", from: arguments)
    let sessionId: UUID
    if let str = sessionIdStr, let parsed = UUID(uuidString: str) {
      sessionId = parsed
    } else {
      sessionId = UUID()
    }

    // Optional: API base URL for the shared Rails backend
    let apiBaseURL = optionalString("apiBaseURL", from: arguments) ?? "http://localhost:3000"

    do {
      let session = try await orchestrator.createSession(
        sessionId: sessionId,
        worktreePath: worktreePath
      )

      logger.info("Launched UX session \(session.id.uuidString) for \(worktreePath)")

      return (200, makeResult(id: id, result: [
        "sessionId": session.id.uuidString,
        "devServerURL": session.devServerURL,
        "devServerPort": session.devServerPort,
        "chromeDebugPort": session.chromeDebugPort,
        "apiBaseURL": apiBaseURL,
        "status": session.statusDescription,
        "message": "UX session launched. Dev server at \(session.devServerURL), Chrome ready. "
          + "All FE instances share the Rails backend at \(apiBaseURL). "
          + "Use chrome.navigate to load a page, then chrome.screenshot to verify."
      ]))
    } catch {
      logger.error("Failed to launch UX session: \(error.localizedDescription)")
      return internalError(id: id, message: "Failed to launch UX session: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.navigate

  private func handleNavigate(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let url) = requireString("url", from: arguments, id: id) else {
      return missingParamError(id: id, param: "url")
    }

    // If url is a relative path, prepend the dev server URL
    let fullURL: String
    if url.hasPrefix("/") {
      guard let session = orchestrator.sessions[sessionId] else {
        return notFoundError(id: id, what: "Session \(sessionIdStr)")
      }
      fullURL = "\(session.devServerURL)\(url)"
    } else {
      fullURL = url
    }

    do {
      let title = try await orchestrator.chromeManager.navigate(sessionId: sessionId, url: fullURL)
      return (200, makeResult(id: id, result: [
        "url": fullURL,
        "title": title,
        "message": "Navigated to \(fullURL) — page title: \(title)"
      ]))
    } catch {
      return internalError(id: id, message: "Navigation failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.screenshot

  private func handleScreenshot(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }

    let format = optionalString("format", from: arguments) ?? "png"

    do {
      let filePath = try await orchestrator.screenshot(sessionId: sessionId)
      return (200, makeResult(id: id, result: [
        "filePath": filePath,
        "format": format,
        "message": "Screenshot saved to \(filePath)"
      ]))
    } catch {
      return internalError(id: id, message: "Screenshot failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.snapshot

  private func handleSnapshot(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }

    do {
      let domTree = try await orchestrator.snapshot(sessionId: sessionId)
      return (200, makeResult(id: id, result: [
        "snapshot": domTree,
        "message": "DOM snapshot captured (\(domTree.count) chars)"
      ]))
    } catch {
      return internalError(id: id, message: "Snapshot failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.close

  private func handleClose(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }

    await orchestrator.teardownSession(sessionId: sessionId)
    return (200, makeResult(id: id, result: [
      "message": "UX session \(sessionIdStr) closed. Dev server stopped, Chrome terminated, ports released."
    ]))
  }

  // MARK: - chrome.status

  private func handleStatus(id: Any?, orchestrator: UXTestOrchestrator) -> (Int, Data) {
    let sessions = orchestrator.status()
    let activePorts = orchestrator.sessions.values.map { Int($0.devServerPort) }

    return (200, makeResult(id: id, result: [
      "activeSessions": sessions.count,
      "sessions": sessions,
      "devServerPorts": activePorts,
      "message": sessions.isEmpty
        ? "No active UX test sessions. Use chrome.launch to start one."
        : "\(sessions.count) active UX session(s)"
    ]))
  }

  // MARK: - Tool Definitions

  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "chrome.launch",
        description: """
          Launch a UX test session: starts a frontend dev server in the given worktree on a unique port \
          and launches a headless Chrome instance. All FE dev servers share the same local Rails backend. \
          Returns the session ID, dev server URL, and Chrome debug port. \
          Use chrome.navigate to load pages, chrome.screenshot to capture, chrome.snapshot for DOM tree.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "worktreePath": ["type": "string", "description": "Path to the git worktree containing the frontend project"],
            "sessionId": ["type": "string", "description": "Optional UUID for the session (auto-generated if omitted)"],
            "apiBaseURL": ["type": "string", "description": "URL of the shared Rails backend (default: http://localhost:3000)"]
          ],
          "required": ["worktreePath"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.navigate",
        description: """
          Navigate a Chrome session to a URL. If the URL starts with '/', it's treated as a path \
          relative to the session's dev server (e.g., '/dashboard' → 'http://localhost:3005/dashboard'). \
          Returns the page title after navigation.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "url": ["type": "string", "description": "URL or path to navigate to (e.g., '/dashboard' or 'http://...')"]
          ],
          "required": ["sessionId", "url"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.screenshot",
        description: """
          Capture a screenshot of the current page in a Chrome session. \
          Saves to Application Support/Peel/Screenshots/ and returns the file path. \
          Use this to visually verify UI changes after making code modifications.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "format": ["type": "string", "description": "Image format: 'png' or 'jpeg' (default: png)"]
          ],
          "required": ["sessionId"]
        ],
        category: .ui,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chrome.snapshot",
        description: """
          Get a simplified DOM tree of the current page in a Chrome session. \
          Returns a text representation of the page structure (tag names, IDs, classes, text content). \
          Useful for understanding page layout and finding elements without a screenshot.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"]
          ],
          "required": ["sessionId"]
        ],
        category: .ui,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chrome.close",
        description: """
          Close a UX test session: stops the dev server, terminates Chrome, and releases allocated ports. \
          Always close sessions when done to free resources.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session to close"]
          ],
          "required": ["sessionId"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.status",
        description: """
          Get status of all active UX test sessions. Shows session IDs, dev server ports/URLs, \
          Chrome debug ports, and readiness state. Use this to see what's running before launching new sessions.
          """,
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .ui,
        isMutating: false
      ),
    ]
  }
}
