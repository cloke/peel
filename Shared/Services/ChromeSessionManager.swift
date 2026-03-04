//
//  ChromeSessionManager.swift
//  Peel
//
//  Manages headless Chrome instances for parallel UX testing.
//  Each session gets its own Chrome process with a unique debug port,
//  communicating via Chrome DevTools Protocol (CDP) over WebSocket.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "ChromeSessionManager")

/// Manages Chrome browser sessions for parallel UX testing.
/// Each session is a separate Chrome process with its own user data dir and debug port.
@MainActor
@Observable
final class ChromeSessionManager {

  // MARK: - Types

  /// A running Chrome session
  struct Session: Identifiable, Sendable {
    let id: UUID
    let debugPort: UInt16
    let userDataDir: String
    let pid: Int32
    var currentURL: String?
    var isConnected: Bool = false
  }

  /// CDP response for page target info
  private struct CDPTarget: Codable {
    let id: String
    let type: String
    let title: String
    let url: String
    let webSocketDebuggerUrl: String?
  }

  // MARK: - Properties

  /// Active Chrome sessions, keyed by session ID
  private(set) var sessions: [UUID: Session] = [:]

  /// Chrome application path
  private let chromePath: String

  /// Base directory for Chrome user data directories
  private let userDataBaseDir: String

  init(
    chromePath: String = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    userDataBaseDir: String? = nil
  ) {
    self.chromePath = chromePath
    if let baseDir = userDataBaseDir {
      self.userDataBaseDir = baseDir
    } else {
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      self.userDataBaseDir = appSupport.appendingPathComponent("Peel/ChromeSessions").path
    }
  }

  // MARK: - Session Management

  /// Launch a new headless Chrome instance.
  /// - Parameters:
  ///   - sessionId: Unique session identifier
  ///   - debugPort: Chrome remote debugging port
  /// - Returns: The created session
  @discardableResult
  func launch(sessionId: UUID, debugPort: UInt16) async throws -> Session {
    // Verify Chrome exists
    guard FileManager.default.fileExists(atPath: chromePath) else {
      throw ChromeSessionError.chromeNotFound(chromePath)
    }

    // Create unique user data directory
    let userDataDir = "\(userDataBaseDir)/session-\(sessionId.uuidString)"
    try FileManager.default.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)

    // Launch Chrome with unique profile and debug port
    let process = Process()
    process.executableURL = URL(fileURLWithPath: chromePath)
    process.arguments = [
      "--remote-debugging-port=\(debugPort)",
      "--user-data-dir=\(userDataDir)",
      "--headless=new",
      "--disable-gpu",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--disable-popup-blocking",
      "--window-size=1280,800"
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    let pid = process.processIdentifier
    logger.info("Launched Chrome session \(sessionId.uuidString) on port \(debugPort), PID \(pid)")

    // Wait for Chrome to be ready (poll for debug endpoint)
    let maxWait = 10 // seconds
    var ready = false
    for _ in 0..<(maxWait * 4) {
      try await Task.sleep(for: .milliseconds(250))
      if await isDebugEndpointReady(port: debugPort) {
        ready = true
        break
      }
    }

    guard ready else {
      process.terminate()
      throw ChromeSessionError.launchTimeout(debugPort)
    }

    let session = Session(
      id: sessionId,
      debugPort: debugPort,
      userDataDir: userDataDir,
      pid: pid,
      isConnected: true
    )
    sessions[sessionId] = session
    return session
  }

  /// Navigate a Chrome session to a URL.
  /// - Parameters:
  ///   - sessionId: The session to navigate
  ///   - url: The URL to load
  /// - Returns: The current page title after navigation
  func navigate(sessionId: UUID, url: String) async throws -> String {
    guard var session = sessions[sessionId] else {
      throw ChromeSessionError.sessionNotFound(sessionId)
    }

    // Get the first page target
    let target = try await getPageTarget(port: session.debugPort)

    // Send Page.navigate via CDP
    _ = try await sendCDPCommand(
      port: session.debugPort,
      targetId: target.id,
      method: "Page.navigate",
      params: ["url": url]
    )

    // Wait for page to load
    try await Task.sleep(for: .seconds(2))

    // Get page title
    let titleResult = try await sendCDPCommand(
      port: session.debugPort,
      targetId: target.id,
      method: "Runtime.evaluate",
      params: ["expression": "document.title"]
    )

    session.currentURL = url
    sessions[sessionId] = session

    let title = extractStringResult(from: titleResult) ?? url
    logger.info("Navigated session \(sessionId.uuidString) to \(url) — title: \(title)")
    return title
  }

  /// Take a screenshot of a Chrome session.
  /// - Parameters:
  ///   - sessionId: The session to capture
  ///   - format: Image format ("png" or "jpeg")
  /// - Returns: Path to the saved screenshot file
  func screenshot(sessionId: UUID, format: String = "png") async throws -> String {
    guard let session = sessions[sessionId] else {
      throw ChromeSessionError.sessionNotFound(sessionId)
    }

    let target = try await getPageTarget(port: session.debugPort)

    let result = try await sendCDPCommand(
      port: session.debugPort,
      targetId: target.id,
      method: "Page.captureScreenshot",
      params: ["format": format]
    )

    // Extract base64 data from response
    guard let resultDict = result["result"] as? [String: Any],
          let base64Data = resultDict["data"] as? String,
          let imageData = Data(base64Encoded: base64Data) else {
      throw ChromeSessionError.screenshotFailed("Failed to decode screenshot data")
    }

    // Save to tmp directory
    let screenshotDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!.appendingPathComponent("Peel/Screenshots").path
    try FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)

    let filename = "chrome-\(sessionId.uuidString)-\(Int(Date().timeIntervalSince1970)).\(format)"
    let filePath = "\(screenshotDir)/\(filename)"
    try imageData.write(to: URL(fileURLWithPath: filePath))

    logger.info("Screenshot saved: \(filePath)")
    return filePath
  }

  /// Get a DOM snapshot/accessibility tree from a Chrome session.
  /// - Parameter sessionId: The session to snapshot
  /// - Returns: Simplified DOM tree as text
  func snapshot(sessionId: UUID) async throws -> String {
    guard let session = sessions[sessionId] else {
      throw ChromeSessionError.sessionNotFound(sessionId)
    }

    let target = try await getPageTarget(port: session.debugPort)

    // Get the page's HTML structure (simplified)
    let result = try await sendCDPCommand(
      port: session.debugPort,
      targetId: target.id,
      method: "Runtime.evaluate",
      params: [
        "expression": """
          (function() {
            function walk(el, depth) {
              if (depth > 6) return '';
              const tag = el.tagName?.toLowerCase() || '';
              if (['script','style','link','meta','noscript'].includes(tag)) return '';
              const indent = '  '.repeat(depth);
              let text = el.textContent?.trim().substring(0, 80) || '';
              const id = el.id ? '#' + el.id : '';
              const cls = el.className && typeof el.className === 'string'
                ? '.' + el.className.split(' ').slice(0,2).join('.') : '';
              let line = tag ? indent + '<' + tag + id + cls + '>' : '';
              if (text && el.children.length === 0) line += ' ' + text;
              let result = line ? line + '\\n' : '';
              for (const child of el.children) {
                result += walk(child, depth + 1);
              }
              return result;
            }
            return walk(document.body, 0);
          })()
          """,
        "returnByValue": true
      ]
    )

    return extractStringResult(from: result) ?? "(empty snapshot)"
  }

  /// Close a Chrome session and clean up.
  func close(sessionId: UUID) async {
    guard let session = sessions[sessionId] else { return }

    // Kill the Chrome process
    let killProcess = Process()
    killProcess.executableURL = URL(fileURLWithPath: "/bin/kill")
    killProcess.arguments = ["\(session.pid)"]
    killProcess.standardOutput = FileHandle.nullDevice
    killProcess.standardError = FileHandle.nullDevice
    try? killProcess.run()
    killProcess.waitUntilExit()

    // Clean up user data directory
    try? FileManager.default.removeItem(atPath: session.userDataDir)

    sessions.removeValue(forKey: sessionId)
    logger.info("Closed Chrome session \(sessionId.uuidString)")
  }

  /// Close all sessions.
  func closeAll() async {
    for sessionId in sessions.keys {
      await close(sessionId: sessionId)
    }
  }

  /// Get status of all sessions.
  func status() -> [[String: Any]] {
    sessions.values.map { session in
      [
        "sessionId": session.id.uuidString,
        "debugPort": session.debugPort,
        "pid": session.pid,
        "currentURL": session.currentURL ?? "(none)",
        "isConnected": session.isConnected
      ] as [String: Any]
    }
  }

  // MARK: - CDP Communication

  /// Check if the Chrome debug endpoint is ready.
  private nonisolated func isDebugEndpointReady(port: UInt16) async -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else { return false }
    do {
      let (_, response) = try await URLSession.shared.data(from: url)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }

  /// Get the first page target from Chrome.
  private nonisolated func getPageTarget(port: UInt16) async throws -> CDPTarget {
    guard let url = URL(string: "http://127.0.0.1:\(port)/json") else {
      throw ChromeSessionError.cdpError("Invalid debug URL")
    }

    let (data, _) = try await URLSession.shared.data(from: url)
    let targets = try JSONDecoder().decode([CDPTarget].self, from: data)

    guard let pageTarget = targets.first(where: { $0.type == "page" }) else {
      throw ChromeSessionError.cdpError("No page target found")
    }

    return pageTarget
  }

  /// Send a CDP command via HTTP (using /json/protocol endpoint).
  /// For simplicity in the PoC, we use the HTTP endpoint rather than WebSocket.
  private nonisolated func sendCDPCommand(
    port: UInt16,
    targetId: String,
    method: String,
    params: [String: Any] = [:]
  ) async throws -> [String: Any] {
    // Use the HTTP endpoint for CDP commands
    guard let url = URL(string: "http://127.0.0.1:\(port)/json") else {
      throw ChromeSessionError.cdpError("Invalid CDP URL")
    }

    // Get WebSocket URL for the target
    let (targetData, _) = try await URLSession.shared.data(from: url)
    let targets = try JSONDecoder().decode([CDPTarget].self, from: targetData)
    guard let target = targets.first(where: { $0.id == targetId }),
          let wsURLString = target.webSocketDebuggerUrl,
          let wsURL = URL(string: wsURLString) else {
      throw ChromeSessionError.cdpError("No WebSocket URL for target \(targetId)")
    }

    // Use URLSessionWebSocketTask for CDP communication
    let wsTask = URLSession.shared.webSocketTask(with: wsURL)
    wsTask.resume()

    defer {
      wsTask.cancel(with: .normalClosure, reason: nil)
    }

    // Build CDP message
    let messageId = Int.random(in: 1...999999)
    var message: [String: Any] = [
      "id": messageId,
      "method": method
    ]
    if !params.isEmpty {
      message["params"] = params
    }

    let messageData = try JSONSerialization.data(withJSONObject: message)
    let messageString = String(data: messageData, encoding: .utf8)!

    try await wsTask.send(.string(messageString))

    // Read response (with timeout)
    let responseMessage = try await withTimeout(seconds: 15) {
      try await wsTask.receive()
    }

    switch responseMessage {
    case .string(let text):
      guard let data = text.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ChromeSessionError.cdpError("Invalid CDP response")
      }
      return json
    case .data(let data):
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ChromeSessionError.cdpError("Invalid CDP response data")
      }
      return json
    @unknown default:
      throw ChromeSessionError.cdpError("Unknown WebSocket message type")
    }
  }

  /// Extract a string result from a CDP Runtime.evaluate response.
  private nonisolated func extractStringResult(from response: [String: Any]) -> String? {
    guard let result = response["result"] as? [String: Any],
          let innerResult = result["result"] as? [String: Any],
          let value = innerResult["value"] as? String else {
      return nil
    }
    return value
  }

  /// Run an async operation with a timeout.
  private nonisolated func withTimeout<T: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw ChromeSessionError.cdpError("CDP command timed out after \(seconds)s")
      }
      guard let result = try await group.next() else {
        throw ChromeSessionError.cdpError("No result from CDP")
      }
      group.cancelAll()
      return result
    }
  }
}

// MARK: - Errors

enum ChromeSessionError: LocalizedError {
  case chromeNotFound(String)
  case launchTimeout(UInt16)
  case sessionNotFound(UUID)
  case screenshotFailed(String)
  case cdpError(String)

  var errorDescription: String? {
    switch self {
    case .chromeNotFound(let path):
      return "Chrome not found at \(path)"
    case .launchTimeout(let port):
      return "Chrome failed to start on port \(port) within timeout"
    case .sessionNotFound(let id):
      return "No Chrome session found for \(id.uuidString)"
    case .screenshotFailed(let msg):
      return "Screenshot failed: \(msg)"
    case .cdpError(let msg):
      return "CDP error: \(msg)"
    }
  }
}
