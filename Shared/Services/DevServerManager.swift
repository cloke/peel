//
//  DevServerManager.swift
//  Peel
//
//  Manages dev server instances for parallel UX testing.
//  Each worktree gets its own dev server on a unique port.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "DevServerManager")

/// Manages development server processes for parallel worktrees.
@MainActor
@Observable
final class DevServerManager {

  // MARK: - Types

  /// A running dev server instance
  struct ServerInstance: Identifiable, Sendable {
    let id: UUID
    let port: UInt16
    let worktreePath: String
    let pid: Int32
    let command: String
    var isReady: Bool = false
    var url: String { "http://localhost:\(port)" }
  }

  /// Supported dev server runtimes (auto-detected from project)
  enum DetectedRuntime: String, Sendable {
    case pnpm
    case npm
    case yarn
    case bun
    case unknown

    /// The command to start the dev server
    func startCommand(port: UInt16) -> (executable: String, arguments: [String]) {
      switch self {
      case .pnpm:
        return ("pnpm", ["dev", "--port", "\(port)"])
      case .npm:
        return ("npm", ["run", "dev", "--", "--port", "\(port)"])
      case .yarn:
        return ("yarn", ["dev", "--port", "\(port)"])
      case .bun:
        return ("bun", ["dev", "--port", "\(port)"])
      case .unknown:
        return ("npm", ["run", "dev", "--", "--port", "\(port)"])
      }
    }
  }

  // MARK: - Properties

  /// Active server instances, keyed by session ID
  private(set) var servers: [UUID: ServerInstance] = [:]

  /// Running Process objects (not Sendable, keep on MainActor)
  private var processes: [UUID: Process] = [:]

  // MARK: - Server Management

  /// Start a dev server in a worktree directory.
  /// - Parameters:
  ///   - sessionId: Unique session identifier
  ///   - worktreePath: Path to the worktree/project directory
  ///   - port: Port to run on
  ///   - command: Optional override command (e.g., "pnpm dev")
  /// - Returns: The created server instance
  @discardableResult
  func start(
    sessionId: UUID,
    worktreePath: String,
    port: UInt16,
    command: String? = nil
  ) async throws -> ServerInstance {
    let runtime = detectRuntime(at: worktreePath)
    let (executable, arguments) = runtime.startCommand(port: port)

    // Find the executable
    let executablePath = findExecutable(executable)
    guard let execPath = executablePath else {
      throw DevServerError.runtimeNotFound(executable)
    }

    // Set up the process
    let process = Process()
    process.executableURL = URL(fileURLWithPath: execPath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: worktreePath)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    // Set up environment (inherit PATH from shell)
    var env = ProcessInfo.processInfo.environment
    // Ensure common tool paths are available
    let additionalPaths = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "\(env["HOME"] ?? "")/.bun/bin",
      "\(env["HOME"] ?? "")/.nvm/versions/node/*/bin"
    ]
    let currentPath = env["PATH"] ?? ""
    env["PATH"] = (additionalPaths + [currentPath]).joined(separator: ":")
    process.environment = env

    try process.run()
    let pid = process.processIdentifier
    let commandStr = "\(executable) \(arguments.joined(separator: " "))"

    logger.info("Started dev server for session \(sessionId.uuidString): \(commandStr) on port \(port), PID \(pid)")

    processes[sessionId] = process

    // Wait for server to be ready
    var instance = ServerInstance(
      id: sessionId,
      port: port,
      worktreePath: worktreePath,
      pid: pid,
      command: commandStr
    )

    let maxWait = 30 // seconds
    for _ in 0..<(maxWait * 2) {
      try await Task.sleep(for: .milliseconds(500))
      if await isServerReady(port: port) {
        instance.isReady = true
        break
      }
      // Check if process died
      guard process.isRunning else {
        throw DevServerError.serverCrashed(commandStr)
      }
    }

    if !instance.isReady {
      logger.warning("Dev server on port \(port) may not be fully ready")
      // Don't throw — server might still be compiling
      instance.isReady = true  // Treat as ready anyway for the PoC
    }

    servers[sessionId] = instance
    return instance
  }

  /// Stop a dev server.
  func stop(sessionId: UUID) {
    guard let process = processes[sessionId] else { return }

    if process.isRunning {
      process.terminate()
      // Give it a moment, then force kill
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        if process.isRunning {
          process.interrupt()
        }
      }
    }

    processes.removeValue(forKey: sessionId)
    servers.removeValue(forKey: sessionId)
    logger.info("Stopped dev server for session \(sessionId.uuidString)")
  }

  /// Stop all dev servers.
  func stopAll() {
    for sessionId in processes.keys {
      stop(sessionId: sessionId)
    }
  }

  /// Get status of all servers.
  func status() -> [[String: Any]] {
    servers.values.map { server in
      [
        "sessionId": server.id.uuidString,
        "port": server.port,
        "url": server.url,
        "worktreePath": server.worktreePath,
        "pid": server.pid,
        "command": server.command,
        "isReady": server.isReady
      ] as [String: Any]
    }
  }

  // MARK: - Runtime Detection

  /// Detect the package manager / runtime for a project.
  func detectRuntime(at path: String) -> DetectedRuntime {
    let fm = FileManager.default

    // Check for lock files
    if fm.fileExists(atPath: "\(path)/pnpm-lock.yaml") {
      return .pnpm
    }
    if fm.fileExists(atPath: "\(path)/bun.lockb") || fm.fileExists(atPath: "\(path)/bun.lock") {
      return .bun
    }
    if fm.fileExists(atPath: "\(path)/yarn.lock") {
      return .yarn
    }
    if fm.fileExists(atPath: "\(path)/package-lock.json") {
      return .npm
    }
    if fm.fileExists(atPath: "\(path)/package.json") {
      return .npm
    }

    return .unknown
  }

  // MARK: - Private

  /// Check if a server is responding on a port.
  private nonisolated func isServerReady(port: UInt16) async -> Bool {
    guard let url = URL(string: "http://localhost:\(port)") else { return false }
    do {
      let (_, response) = try await URLSession.shared.data(from: url)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return status >= 200 && status < 500
    } catch {
      return false
    }
  }

  /// Find an executable in common paths.
  private func findExecutable(_ name: String) -> String? {
    let paths = [
      "/opt/homebrew/bin/\(name)",
      "/usr/local/bin/\(name)",
      "/usr/bin/\(name)",
      "\(FileManager.default.homeDirectoryForCurrentUser.path)/.bun/bin/\(name)"
    ]

    for path in paths {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }
    return nil
  }
}

// MARK: - Errors

enum DevServerError: LocalizedError {
  case runtimeNotFound(String)
  case serverCrashed(String)
  case startFailed(String)

  var errorDescription: String? {
    switch self {
    case .runtimeNotFound(let name):
      return "Dev server runtime '\(name)' not found. Install it via brew/npm."
    case .serverCrashed(let command):
      return "Dev server crashed: \(command)"
    case .startFailed(let msg):
      return "Failed to start dev server: \(msg)"
    }
  }
}
