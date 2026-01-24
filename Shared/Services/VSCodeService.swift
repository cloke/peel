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
}

public enum VSCodeError: LocalizedError {
  case notInstalled
  case failedToLaunch(String)
  
  public var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "VS Code is not installed. Please install it from https://code.visualstudio.com"
    case .failedToLaunch(let reason):
      return "Failed to launch VS Code: \(reason)"
    }
  }
}