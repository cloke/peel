import Foundation
import OSLog

/// Error types for Xcode MCP operations
enum XcodeMCPError: LocalizedError {
  case xcodeNotRunning
  case mcpbridgeNotFound
  case communicationFailed(String)
  case invalidResponse(String)
  case timeout
  case xcodeProcessError(Int32)

  var errorDescription: String? {
    switch self {
    case .xcodeNotRunning:
      return "Xcode is not running. Please open Xcode and try again."
    case .mcpbridgeNotFound:
      return "mcpbridge not found. Ensure Xcode 26.3+ is installed."
    case .communicationFailed(let reason):
      return "Failed to communicate with Xcode MCP: \(reason)"
    case .invalidResponse(let reason):
      return "Invalid response from Xcode MCP: \(reason)"
    case .timeout:
      return "Xcode MCP request timed out. Xcode may be busy."
    case .xcodeProcessError(let code):
      return "Xcode process error: \(code)"
    }
  }
}

/// Manages communication with Xcode's mcpbridge via STDIO.
/// Runs on the main actor alongside the tool handler to avoid Sendable issues
/// with `[String: Any]` dictionaries crossing actor boundaries.
@MainActor
final class XcodeMCPAdapter {
  private static let logger = Logger(subsystem: "com.peel.xcode-mcp", category: "adapter")

  // MARK: - Properties

  private var mcpProcess: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var requestID: Int = 1

  // Configuration
  private let timeout: TimeInterval
  private let debugEnabled: Bool

  // MARK: - Initialization

  init(timeout: TimeInterval = 10.0, debugEnabled: Bool = false) {
    self.timeout = timeout
    self.debugEnabled = debugEnabled
  }

  // MARK: - Public Methods

  /// Verify mcpbridge is available on the system.
  func verifyBridge() throws {
    Self.logger.info("Verifying mcpbridge availability")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["xcrun", "mcpbridge", "--help"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw XcodeMCPError.mcpbridgeNotFound
    }

    Self.logger.debug("mcpbridge found and accessible")
  }

  /// Call a specific Xcode MCP tool.
  func callTool(
    method: String = "tools/call",
    toolName: String,
    arguments: [String: Any]
  ) async throws -> [String: Any] {
    var params: [String: Any] = [
      "name": toolName
    ]

    if !arguments.isEmpty {
      params["arguments"] = arguments
    }

    let currentID = requestID
    requestID += 1

    let request: [String: Any] = [
      "jsonrpc": "2.0",
      "id": currentID,
      "method": method,
      "params": params
    ]

    return try await callMCP(request: request)
  }

  /// Gracefully shutdown the mcpbridge subprocess.
  func shutdown() {
    Self.logger.info("Shutting down XcodeMCPAdapter")

    if let process = mcpProcess, process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }

    mcpProcess = nil
    inputPipe = nil
    outputPipe = nil
  }

  // MARK: - Private Methods

  /// Check if Xcode is currently running.
  private func isXcodeAvailable() -> Bool {
    let process = Process()
    process.launchPath = "/bin/sh"
    process.arguments = ["-c", "pgrep -x Xcode"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      Self.logger.warning("Failed to check if Xcode is running: \(error)")
      return false
    }
  }

  /// Send JSON-RPC request to mcpbridge and receive response.
  private func callMCP(request: [String: Any]) async throws -> [String: Any] {
    try ensureProcessRunning()

    guard let inputPipe = inputPipe, let outputPipe = outputPipe else {
      throw XcodeMCPError.communicationFailed("Pipes not initialized")
    }

    let requestData = try JSONSerialization.data(withJSONObject: request)
    guard let requestJSON = String(data: requestData, encoding: .utf8) else {
      throw XcodeMCPError.invalidResponse("Failed to serialize request")
    }

    if debugEnabled {
      Self.logger.debug("Sending: \(requestJSON)")
    }

    guard let requestBytes = (requestJSON + "\n").data(using: .utf8) else {
      throw XcodeMCPError.invalidResponse("Failed to encode request")
    }

    inputPipe.fileHandleForWriting.write(requestBytes)

    let startTime = Date()
    var responseData = Data()

    while Date().timeIntervalSince(startTime) < timeout {
      let available = outputPipe.fileHandleForReading.availableData
      if !available.isEmpty {
        responseData.append(available)

        if let responseString = String(data: responseData, encoding: .utf8),
           responseString.contains("\n") {
          let lines = responseString.split(separator: "\n", omittingEmptySubsequences: true)
          if let lastLine = lines.last,
             let jsonData = lastLine.data(using: .utf8),
             let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

            if debugEnabled {
              Self.logger.debug("Received: \(String(describing: json))")
            }

            return json
          }
        }
      }

      try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }

    throw XcodeMCPError.timeout
  }

  /// Ensure mcpbridge subprocess is running.
  private func ensureProcessRunning() throws {
    if let process = mcpProcess, process.isRunning {
      return
    }

    guard isXcodeAvailable() else {
      throw XcodeMCPError.xcodeNotRunning
    }

    try startProcess()
  }

  /// Start the mcpbridge process.
  private func startProcess() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["xcrun", "mcpbridge"]

    let newInput = Pipe()
    let newOutput = Pipe()

    process.standardInput = newInput
    process.standardOutput = newOutput
    process.standardError = FileHandle.nullDevice

    try process.run()

    self.mcpProcess = process
    self.inputPipe = newInput
    self.outputPipe = newOutput

    Self.logger.info("mcpbridge process started (PID: \(process.processIdentifier))")
  }
}
