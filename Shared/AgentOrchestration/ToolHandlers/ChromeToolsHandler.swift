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
    "chrome.evaluate",
    "chrome.fill",
    "chrome.click",
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
    case "chrome.evaluate":
      return await handleEvaluate(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.fill":
      return await handleFill(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.click":
      return await handleClick(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.close":
      return await handleClose(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.status":
      return handleStatus(id: id, orchestrator: orchestrator)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }

  // MARK: - chrome.launch

  /// Launch a new UX test session: allocate ports, optionally start FE dev server, launch headless Chrome.
  private func handleLaunch(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    // worktreePath is optional when skipDevServer is true — use a temp path
    let skipDevServer = arguments["skipDevServer"] as? Bool ?? false
    let worktreePath: String
    if let wp = optionalString("worktreePath", from: arguments), !wp.isEmpty {
      worktreePath = wp
    } else if skipDevServer {
      worktreePath = NSTemporaryDirectory()
    } else {
      return missingParamError(id: id, param: "worktreePath")
    }

    let sessionIdStr = optionalString("sessionId", from: arguments)
    let sessionId: UUID
    if let str = sessionIdStr, let parsed = UUID(uuidString: str) {
      sessionId = parsed
    } else {
      sessionId = UUID()
    }

    // Optional: API base URL for the shared backend
    let apiBaseURL = optionalString("apiBaseURL", from: arguments) ?? "http://localhost:3000"

    do {
      let session = try await orchestrator.createSession(
        sessionId: sessionId,
        worktreePath: worktreePath,
        skipDevServer: skipDevServer
      )

      logger.info("Launched UX session \(session.id.uuidString) for \(worktreePath) skipDevServer:\(skipDevServer)")

      var result: [String: Any] = [
        "sessionId": session.id.uuidString,
        "chromeDebugPort": session.chromeDebugPort,
        "apiBaseURL": apiBaseURL,
        "status": session.statusDescription,
      ]

      if !skipDevServer {
        result["devServerURL"] = session.devServerURL
        result["devServerPort"] = session.devServerPort
        result["message"] = "UX session launched. Dev server at \(session.devServerURL), Chrome ready. "
          + "Use chrome.navigate to load a page, then chrome.screenshot to verify."
      } else {
        result["message"] = "UX session launched (browser only, no dev server). Chrome ready. "
          + "Use chrome.navigate with a full URL, then chrome.screenshot to verify."
      }

      return (200, makeResult(id: id, result: result))
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

  // MARK: - chrome.evaluate

  private func handleEvaluate(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let expression) = requireString("expression", from: arguments, id: id) else {
      return missingParamError(id: id, param: "expression")
    }

    let awaitPromise = arguments["awaitPromise"] as? Bool ?? false

    do {
      let result = try await orchestrator.chromeManager.evaluate(
        sessionId: sessionId,
        expression: expression,
        awaitPromise: awaitPromise
      )

      // Extract the value from the CDP response
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let resultValue = innerResult?["value"]
      let resultType = innerResult?["type"] as? String ?? "undefined"

      var response: [String: Any] = [
        "type": resultType,
        "message": "Expression evaluated successfully"
      ]
      if let resultValue {
        response["value"] = resultValue
      }

      return (200, makeResult(id: id, result: response))
    } catch {
      return internalError(id: id, message: "Evaluate failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.fill

  private func handleFill(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let selector) = requireString("selector", from: arguments, id: id) else {
      return missingParamError(id: id, param: "selector")
    }
    guard case .success(let value) = requireString("value", from: arguments, id: id) else {
      return missingParamError(id: id, param: "value")
    }

    // Escape quotes in selector and value for JS injection
    let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    let escapedValue = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")

    let js = """
      (function() {
        const el = document.querySelector('\(escapedSelector)');
        if (!el) return { success: false, error: 'Element not found: \(escapedSelector)' };
        // Focus, clear, set value, and dispatch events to trigger framework bindings
        el.focus();
        el.value = '\(escapedValue)';
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { success: true, tagName: el.tagName, type: el.type || null };
      })()
      """

    do {
      let result = try await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: js)
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let resultValue = innerResult?["value"] as? [String: Any] ?? [:]

      if resultValue["success"] as? Bool == true {
        return (200, makeResult(id: id, result: [
          "filled": true,
          "selector": selector,
          "tagName": resultValue["tagName"] ?? "unknown",
          "message": "Filled '\(selector)' with value"
        ]))
      } else {
        let error = resultValue["error"] as? String ?? "Unknown error"
        return (200, makeResult(id: id, result: [
          "filled": false,
          "error": error,
          "message": "Failed to fill: \(error)"
        ]))
      }
    } catch {
      return internalError(id: id, message: "Fill failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.click

  private func handleClick(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let selector) = requireString("selector", from: arguments, id: id) else {
      return missingParamError(id: id, param: "selector")
    }

    let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")

    let js = """
      (function() {
        const el = document.querySelector('\(escapedSelector)');
        if (!el) return { success: false, error: 'Element not found: \(escapedSelector)' };
        el.click();
        return { success: true, tagName: el.tagName, text: (el.textContent || '').trim().substring(0, 100) };
      })()
      """

    do {
      let result = try await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: js)
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let resultValue = innerResult?["value"] as? [String: Any] ?? [:]

      if resultValue["success"] as? Bool == true {
        return (200, makeResult(id: id, result: [
          "clicked": true,
          "selector": selector,
          "tagName": resultValue["tagName"] ?? "unknown",
          "text": resultValue["text"] ?? "",
          "message": "Clicked '\(selector)'"
        ]))
      } else {
        let error = resultValue["error"] as? String ?? "Unknown error"
        return (200, makeResult(id: id, result: [
          "clicked": false,
          "error": error,
          "message": "Failed to click: \(error)"
        ]))
      }
    } catch {
      return internalError(id: id, message: "Click failed: \(error.localizedDescription)")
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
          Launch a UX test session: optionally starts a frontend dev server in the given worktree on a unique port \
          and launches a headless Chrome instance. Use skipDevServer=true for browser-only mode (no dev server). \
          Returns the session ID, dev server URL (if applicable), and Chrome debug port. \
          Use chrome.navigate to load pages, chrome.screenshot to capture, chrome.snapshot for DOM tree.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "worktreePath": ["type": "string", "description": "Path to the git worktree containing the frontend project (optional when skipDevServer is true)"],
            "sessionId": ["type": "string", "description": "Optional UUID for the session (auto-generated if omitted)"],
            "apiBaseURL": ["type": "string", "description": "URL of the shared backend API (default: http://localhost:3000)"],
            "skipDevServer": ["type": "boolean", "description": "When true, only launches Chrome without starting a dev server. Useful for testing with existing servers or public URLs."]
          ]
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
        name: "chrome.evaluate",
        description: """
          Execute arbitrary JavaScript in a Chrome session and return the result. \
          Use this for complex page interactions that chrome.fill and chrome.click don't cover. \
          The expression is evaluated via Runtime.evaluate in the page context.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "expression": ["type": "string", "description": "JavaScript expression to evaluate in the page context"],
            "awaitPromise": ["type": "boolean", "description": "If true, await the result if it is a Promise (default: false)"]
          ],
          "required": ["sessionId", "expression"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.fill",
        description: """
          Fill in a form field by CSS selector. Sets the value and dispatches input/change events \
          to trigger framework data binding (Ember, React, Vue, etc.). \
          Example selectors: 'input[type=email]', '#password', 'input[name=username]'
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "selector": ["type": "string", "description": "CSS selector for the input element"],
            "value": ["type": "string", "description": "The value to fill into the field"]
          ],
          "required": ["sessionId", "selector", "value"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.click",
        description: """
          Click an element by CSS selector. Finds the first matching element and calls .click(). \
          Example selectors: 'button[type=submit]', '.login-btn', '#sign-in', 'a[href=\"/dashboard\"]'
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "selector": ["type": "string", "description": "CSS selector for the element to click"]
          ],
          "required": ["sessionId", "selector"]
        ],
        category: .ui,
        isMutating: true
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
