//
//  UXTestOrchestrator.swift
//  Peel
//
//  Orchestrates parallel UX testing sessions.
//  Ties together: worktree creation, dev server, Chrome browser, and agent execution.
//  Each parallel task gets its own isolated environment with unique ports.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "UXTestOrchestrator")

/// Orchestrates full UX test sessions: worktree + dev server + Chrome browser.
/// Integrates with ParallelWorktreeRunner to provide browser context to each agent.
@MainActor
@Observable
final class UXTestOrchestrator {

  // MARK: - Types

  /// A complete UX test session with all components
  struct UXSession: Identifiable, Sendable {
    let id: UUID
    let worktreePath: String
    let devServerPort: UInt16
    let chromeDebugPort: UInt16
    /// External app URL (e.g., "http://localhost:4250") — overrides the allocated port URL.
    var externalURL: String?
    var devServerReady: Bool = false
    var chromeReady: Bool = false
    var devServerURL: String { externalURL ?? "http://localhost:\(devServerPort)" }

    var isFullyReady: Bool { devServerReady && chromeReady }

    var statusDescription: String {
      var parts: [String] = []
      if let ext = externalURL {
        parts.append("devServer: external (\(ext))")
      } else {
        parts.append("devServer: \(devServerReady ? "ready" : "starting") (:\(devServerPort))")
      }
      parts.append("chrome: \(chromeReady ? "ready" : "starting") (debug:\(chromeDebugPort))")
      return parts.joined(separator: ", ")
    }
  }

  // MARK: - Properties

  let portAllocator: PortAllocator
  let chromeManager: ChromeSessionManager
  let devServerManager: DevServerManager

  /// Active UX sessions, keyed by session ID (typically execution ID)
  private(set) var sessions: [UUID: UXSession] = [:]

  init(
    portAllocator: PortAllocator = PortAllocator(),
    chromeManager: ChromeSessionManager = ChromeSessionManager(),
    devServerManager: DevServerManager = DevServerManager()
  ) {
    self.portAllocator = portAllocator
    self.chromeManager = chromeManager
    self.devServerManager = devServerManager
  }

  // MARK: - Session Lifecycle

  /// Create a full UX test session: allocate ports, optionally start dev server, launch Chrome.
  /// - Parameters:
  ///   - sessionId: Unique session ID (use execution ID from parallel runner)
  ///   - worktreePath: Path to the git worktree
  ///   - devServerCommand: Optional override for dev server start command
  ///   - skipDevServer: When true, only launches Chrome without a dev server (useful for testing or static sites)
  ///   - apiBaseURL: External app URL (e.g., "http://localhost:4250"). When set, skipDevServer is implicitly true.
  ///   - installDependencies: When true, install node_modules before starting the dev server (symlinks from main repo if possible).
  ///   - devServerPath: Sub-directory within the worktree where the dev server should start (for monorepos).
  /// - Returns: The created UX session
  @discardableResult
  func createSession(
    sessionId: UUID,
    worktreePath: String,
    devServerCommand: String? = nil,
    skipDevServer: Bool = false,
    apiBaseURL: String? = nil,
    installDependencies: Bool = false,
    devServerPath: String? = nil
  ) async throws -> UXSession {
    let effectiveSkipDevServer = skipDevServer || (apiBaseURL != nil)

    // Resolve the actual directory where the dev server runs
    let serverDir: String
    if let subDir = devServerPath {
      serverDir = "\(worktreePath)/\(subDir)"
    } else {
      serverDir = worktreePath
    }

    // 1. Allocate ports
    let ports = try await portAllocator.allocate(for: sessionId)

    var session = UXSession(
      id: sessionId,
      worktreePath: worktreePath,
      devServerPort: ports.devPort,
      chromeDebugPort: ports.chromePort,
      externalURL: apiBaseURL
    )

    logger.info("Creating UX session \(sessionId.uuidString) — dev:\(ports.devPort) chrome:\(ports.chromePort) skipDevServer:\(effectiveSkipDevServer) apiBaseURL:\(apiBaseURL ?? "none") installDeps:\(installDependencies) serverDir:\(serverDir)")

    // 2. Install dependencies if requested (before starting dev server)
    if installDependencies && !effectiveSkipDevServer {
      // For monorepos, install at the worktree root (pnpm install) which sets up all packages
      do {
        try await devServerManager.installDependencies(worktreePath: worktreePath)
      } catch {
        logger.error("Failed to install dependencies: \(error.localizedDescription)")
        await teardownSession(sessionId: sessionId)
        throw error
      }
    }

    // 3. Start dev server (unless skipped or using external URL)
    if !effectiveSkipDevServer {
      do {
        let serverInstance = try await devServerManager.start(
          sessionId: sessionId,
          worktreePath: serverDir,
          port: ports.devPort,
          command: devServerCommand
        )
        session.devServerReady = serverInstance.isReady
      } catch {
        logger.error("Failed to start dev server: \(error.localizedDescription)")
        await teardownSession(sessionId: sessionId)
        throw error
      }
    } else {
      session.devServerReady = true // Mark as ready since we're skipping
    }

    // 3. Launch headless Chrome
    do {
      _ = try await chromeManager.launch(sessionId: sessionId, debugPort: ports.chromePort)
      session.chromeReady = true
    } catch {
      logger.error("Failed to launch Chrome: \(error.localizedDescription)")
      await teardownSession(sessionId: sessionId)
      throw error
    }

    sessions[sessionId] = session
    logger.info("UX session \(sessionId.uuidString) fully ready")
    return session
  }

  /// Navigate a session's Chrome instance to its dev server.
  /// - Parameters:
  ///   - sessionId: The session ID
  ///   - path: Optional URL path (e.g., "/dashboard")
  /// - Returns: The page title after navigation
  func navigateToDevServer(sessionId: UUID, path: String = "/") async throws -> String {
    guard let session = sessions[sessionId] else {
      throw UXTestError.sessionNotFound(sessionId)
    }

    let url = "\(session.devServerURL)\(path)"
    return try await chromeManager.navigate(sessionId: sessionId, url: url)
  }

  /// Take a screenshot of a session's browser.
  func screenshot(sessionId: UUID) async throws -> String {
    guard sessions[sessionId] != nil else {
      throw UXTestError.sessionNotFound(sessionId)
    }
    return try await chromeManager.screenshot(sessionId: sessionId)
  }

  /// Get a DOM snapshot from a session's browser.
  func snapshot(sessionId: UUID) async throws -> String {
    guard sessions[sessionId] != nil else {
      throw UXTestError.sessionNotFound(sessionId)
    }
    return try await chromeManager.snapshot(sessionId: sessionId)
  }

  /// Tear down a UX session: stop dev server, close Chrome, release ports.
  func teardownSession(sessionId: UUID) async {
    devServerManager.stop(sessionId: sessionId)
    await chromeManager.close(sessionId: sessionId)
    await portAllocator.release(for: sessionId)
    sessions.removeValue(forKey: sessionId)
    logger.info("Tore down UX session \(sessionId.uuidString)")
  }

  /// Tear down all sessions.
  func teardownAll() async {
    for sessionId in sessions.keys {
      await teardownSession(sessionId: sessionId)
    }
  }

  /// Get status of all UX sessions.
  func status() -> [[String: Any]] {
    sessions.values.map { session in
      [
        "sessionId": session.id.uuidString,
        "worktreePath": session.worktreePath,
        "devServerPort": session.devServerPort,
        "devServerURL": session.devServerURL,
        "devServerReady": session.devServerReady,
        "chromeDebugPort": session.chromeDebugPort,
        "chromeReady": session.chromeReady,
        "isFullyReady": session.isFullyReady,
        "status": session.statusDescription
      ] as [String: Any]
    }
  }

  // MARK: - Prompt Injection

  /// Build the UX context block to inject into an agent's prompt.
  /// This tells the agent about its dev server URL and available Chrome tools.
  /// Tools are invoked via curl to the MCP server since the agent runs in a Copilot CLI session.
  func buildPromptContext(for sessionId: UUID) -> String? {
    guard let session = sessions[sessionId] else { return nil }

    let sid = session.id.uuidString
    let mcpURL = "http://127.0.0.1:8765/rpc"

    return """
    ## UX Testing Environment

    You have a dedicated headless Chrome browser for this task.
    The app under test is already running externally.

    - **App URL:** \(session.devServerURL)
    - **Chrome Session ID:** \(sid)
    - **MCP Server:** \(mcpURL)

    ### How to Use Browser Tools

    Browser tools are accessed via `curl` to the MCP server. Each call is a JSON-RPC request.

    **Helper function** — Run this FIRST to set up a reusable shell function:

    ```bash
    mcp_call() {
      local tool="$1"
      local args="$2"
      curl -s \(mcpURL) -H 'Content-Type: application/json' \\
        -d "{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":1,\\\"method\\\":\\\"tools/call\\\",\\\"params\\\":{\\\"name\\\":\\\"$tool\\\",\\\"arguments\\\":$args}}"
    }
    ```

    ### Available Tools & Examples

    **1. Navigate to a URL:**
    ```bash
    mcp_call "chrome.navigate" '{"sessionId":"\(sid)","url":"\(session.devServerURL)"}'
    ```

    **2. Get page DOM structure (use this to find CSS selectors):**
    ```bash
    mcp_call "chrome.snapshot" '{"sessionId":"\(sid)"}'
    ```

    **3. Fill a form field by CSS selector:**
    ```bash
    mcp_call "chrome.fill" '{"sessionId":"\(sid)","selector":"input[type=email]","value":"user@example.com"}'
    ```

    **4. Click an element by CSS selector:**
    ```bash
    mcp_call "chrome.click" '{"sessionId":"\(sid)","selector":"button[type=submit]"}'
    ```

    **5. Wait for an element to appear (use instead of sleep!):**
    ```bash
    mcp_call "chrome.wait" '{"sessionId":"\(sid)","selector":".dashboard","timeout":5000}'
    ```

    **6. Select a dropdown option:**
    ```bash
    mcp_call "chrome.select" '{"sessionId":"\(sid)","selector":"select[name=country]","value":"US"}'
    ```

    **7. Check/uncheck a checkbox:**
    ```bash
    mcp_call "chrome.check" '{"sessionId":"\(sid)","selector":"#agree-terms","checked":true}'
    ```

    **8. Take a screenshot (returns file path):**
    ```bash
    mcp_call "chrome.screenshot" '{"sessionId":"\(sid)"}'
    ```

    **9. Run JavaScript in the page:**
    ```bash
    mcp_call "chrome.evaluate" '{"sessionId":"\(sid)","expression":"document.title"}'
    ```

    ### Workflow

    1. Define the `mcp_call` helper function
    2. Navigate to the app: `mcp_call "chrome.navigate" '{"sessionId":"\(sid)","url":"\(session.devServerURL)"}'`
    3. Get the page structure: `mcp_call "chrome.snapshot" '{"sessionId":"\(sid)"}'`
    4. If login is required: use `chrome.fill` for each field + `chrome.click` for submit
    5. Wait for navigation: `mcp_call "chrome.wait" '{"sessionId":"\(sid)","selector":".dashboard"}'`
    6. Take a screenshot to verify: `mcp_call "chrome.screenshot" '{"sessionId":"\(sid)"}'`
    7. Use `chrome.snapshot` to inspect results if screenshot is unclear

    ### Important Notes

    - Always use the session ID `\(sid)` — this is YOUR dedicated Chrome instance
    - **Use `chrome.wait` instead of `sleep`** after clicks/navigation — it's more reliable
    - The `chrome.snapshot` result shows a simplified DOM — use it to find CSS selectors
    - Screenshots return the saved file path in the response
    - If a selector doesn't match, the error includes the current URL — use `chrome.snapshot` to find the correct selector
    - Use `chrome.select` for `<select>` dropdowns and `chrome.check` for checkboxes/radios
    """
  }
}

// MARK: - Errors

enum UXTestError: LocalizedError {
  case sessionNotFound(UUID)
  case setupFailed(String)

  var errorDescription: String? {
    switch self {
    case .sessionNotFound(let id):
      return "No UX test session found for \(id.uuidString)"
    case .setupFailed(let msg):
      return "UX test setup failed: \(msg)"
    }
  }
}
