//
//  VSCodeService.swift
//  KitchenSync
//
//  Created by Copilot on 1/7/26.
//

import Foundation
import AppKit
import Git

/// Service for integrating with VS Code
public actor VSCodeService {
  public static let shared = VSCodeService()
  
  private init() {}

  public enum ConfigTarget: Sendable {
    case user
    case workspace(path: String)
  }
  
  /// Find the VS Code executable
  public func findVSCode() -> String? {
    VSCodeLauncher.findExecutable()
  }
  
  /// Check if VS Code is installed
  public var isInstalled: Bool {
    findVSCode() != nil
  }
  
  /// Open a folder in VS Code
  /// - Parameters:
  ///   - path: Path to open
  ///   - newWindow: Open in a new window (default: true)
  ///   - wait: Wait for VS Code to close before returning
  public func open(
    path: String,
    newWindow: Bool = true,
    wait: Bool = false
  ) async throws {
    try await open(paths: [path], newWindow: newWindow, wait: wait)
  }
  
  /// Open multiple paths in VS Code
  /// - Parameters:
  ///   - paths: Paths to open
  ///   - newWindow: Open in a new window (default: true)
  ///   - wait: Wait for VS Code to close before returning
  public func open(
    paths: [String],
    newWindow: Bool = true,
    wait: Bool = false
  ) async throws {
    guard let vscodePath = findVSCode() else {
      throw VSCodeError.notInstalled
    }
    let validPaths = paths.filter { !$0.isEmpty }
    guard !validPaths.isEmpty else { return }
    var arguments = [String]()
    if newWindow {
      arguments.append("-n")
    }
    if wait {
      arguments.append("-w")
    }
    arguments.append(contentsOf: validPaths)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: vscodePath)
    process.arguments = arguments
    try process.run()
    if wait {
      process.waitUntilExit()
    }
  }
  
  /// Open a folder in VS Code with isolated user data
  /// This is useful for AI agents that need separate VS Code settings
  /// - Parameters:
  ///   - path: Path to open
  ///   - isolationId: Unique identifier for the isolated environment
  public func openIsolated(
    path: String,
    isolationId: String
  ) async throws {
    guard let vscodePath = findVSCode() else {
      throw VSCodeError.notInstalled
    }
    
    let userDataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("vscode-isolated-\(isolationId)")
      .path
    
    let arguments = [
      "-n",
      "--user-data-dir", userDataDir,
      path
    ]
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: vscodePath)
    process.arguments = arguments
    
    try process.run()
  }
  
  /// Open a specific file in VS Code
  /// - Parameters:
  ///   - file: File path to open
  ///   - line: Optional line number to jump to
  ///   - column: Optional column number
  public func openFile(
    _ file: String,
    line: Int? = nil,
    column: Int? = nil
  ) async throws {
    guard let vscodePath = findVSCode() else {
      throw VSCodeError.notInstalled
    }
    
    var target = file
    if let line = line {
      target += ":\(line)"
      if let column = column {
        target += ":\(column)"
      }
    }
    
    let arguments = ["-g", target]
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: vscodePath)
    process.arguments = arguments
    
    try process.run()
  }
  
  /// Open a diff between two files in VS Code
  public func openDiff(
    leftFile: String,
    rightFile: String
  ) async throws {
    guard let vscodePath = findVSCode() else {
      throw VSCodeError.notInstalled
    }
    
    let arguments = ["-d", leftFile, rightFile]
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: vscodePath)
    process.arguments = arguments
    
    try process.run()
  }

  /// Install MCP server configuration into VS Code settings
  /// - Parameters:
  ///   - serverName: Name of the MCP server entry
  ///   - serverURL: URL for the MCP server (e.g. http://127.0.0.1:8765/rpc)
  ///   - scope: User or workspace settings scope
  /// - Returns: Path to the settings file written
  public func installMCPConfig(
    serverName: String,
    serverURL: String,
    scope: ConfigTarget
  ) throws -> String {
    let settingsURL = try settingsURL(for: scope)
    let settingsDir = settingsURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)

    var settings = try readSettings(from: settingsURL)
    var mcpServers = settings["mcp.servers"] as? [String: Any] ?? [:]
    mcpServers[serverName] = [
      "type": "http",
      "url": serverURL
    ]
    settings["mcp.servers"] = mcpServers

    try writeSettings(settings, to: settingsURL)
    return settingsURL.path
  }

  private func settingsURL(for scope: ConfigTarget) throws -> URL {
    switch scope {
    case .user:
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
      return appSupport
        .appendingPathComponent("Code", isDirectory: true)
        .appendingPathComponent("User", isDirectory: true)
        .appendingPathComponent("settings.json")
    case .workspace(let path):
      guard FileManager.default.fileExists(atPath: path) else {
        throw VSCodeError.invalidWorkspacePath(path)
      }
      return URL(fileURLWithPath: path)
        .appendingPathComponent(".vscode", isDirectory: true)
        .appendingPathComponent("settings.json")
    }
  }

  private func readSettings(from url: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    guard !data.isEmpty else { return [:] }
    let json = try JSONSerialization.jsonObject(with: data, options: [])
    return json as? [String: Any] ?? [:]
  }

  private func writeSettings(_ settings: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: [.atomic])
  }
}

public enum VSCodeError: LocalizedError {
  case notInstalled
  case failedToLaunch(String)
  case invalidWorkspacePath(String)
  
  public var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "VS Code is not installed. Please install it from https://code.visualstudio.com"
    case .failedToLaunch(let reason):
      return "Failed to launch VS Code: \(reason)"
    case .invalidWorkspacePath(let path):
      return "Invalid workspace path: \(path)"
    }
  }
}