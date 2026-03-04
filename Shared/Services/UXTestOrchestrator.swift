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
    var devServerReady: Bool = false
    var chromeReady: Bool = false
    var devServerURL: String { "http://localhost:\(devServerPort)" }

    var isFullyReady: Bool { devServerReady && chromeReady }

    var statusDescription: String {
      var parts: [String] = []
      parts.append("devServer: \(devServerReady ? "ready" : "starting") (:\(devServerPort))")
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

  /// Create a full UX test session: allocate ports, start dev server, launch Chrome.
  /// - Parameters:
  ///   - sessionId: Unique session ID (use execution ID from parallel runner)
  ///   - worktreePath: Path to the git worktree
  ///   - devServerCommand: Optional override for dev server start command
  /// - Returns: The created UX session
  @discardableResult
  func createSession(
    sessionId: UUID,
    worktreePath: String,
    devServerCommand: String? = nil
  ) async throws -> UXSession {
    // 1. Allocate ports
    let ports = try await portAllocator.allocate(for: sessionId)

    var session = UXSession(
      id: sessionId,
      worktreePath: worktreePath,
      devServerPort: ports.devPort,
      chromeDebugPort: ports.chromePort
    )

    logger.info("Creating UX session \(sessionId.uuidString) — dev:\(ports.devPort) chrome:\(ports.chromePort)")

    // 2. Start dev server
    do {
      let serverInstance = try await devServerManager.start(
        sessionId: sessionId,
        worktreePath: worktreePath,
        port: ports.devPort,
        command: devServerCommand
      )
      session.devServerReady = serverInstance.isReady
    } catch {
      logger.error("Failed to start dev server: \(error.localizedDescription)")
      await teardownSession(sessionId: sessionId)
      throw error
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
  func buildPromptContext(for sessionId: UUID) -> String? {
    guard let session = sessions[sessionId] else { return nil }

    return """
    ## UX Testing Environment

    You have a dedicated dev server and headless Chrome browser for this task.

    - **Dev Server URL:** \(session.devServerURL)
    - **Chrome Session ID:** \(session.id.uuidString)

    ### Available Browser Tools

    Use these MCP tools to interact with the browser:

    1. `chrome.navigate` — Navigate to a URL
       - `sessionId`: "\(session.id.uuidString)"
       - `url`: The URL to load (e.g., "\(session.devServerURL)/dashboard")

    2. `chrome.screenshot` — Capture a screenshot of the current page
       - `sessionId`: "\(session.id.uuidString)"
       - Returns: path to the saved screenshot file

    3. `chrome.snapshot` — Get a simplified DOM tree of the current page
       - `sessionId`: "\(session.id.uuidString)"
       - Returns: text representation of the page structure

    ### Workflow
    1. Make your code changes in the worktree
    2. Navigate to the relevant page: `chrome.navigate` with url "\(session.devServerURL)/your-page"
    3. Take a screenshot to verify: `chrome.screenshot`
    4. If needed, get DOM structure: `chrome.snapshot`
    5. Fix any visual issues and re-verify
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
