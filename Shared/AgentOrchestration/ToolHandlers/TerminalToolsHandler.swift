//
//  TerminalToolsHandler.swift
//  KitchenSync
//
//  MCP tool handler for AI-safe terminal commands.
//  Provides shell adaptation (bash→zsh) and command safety analysis.
//

import Foundation
import MCPCore
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "TerminalToolsHandler")

/// Handles terminal tools: terminal.run, terminal.analyze, terminal.adapt
@MainActor
public final class TerminalToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?
  
  private let shellAdapter = ShellAdapter()
  private let commandSanitizer = CommandSanitizer()
  
  /// Configuration for the terminal handler
  public struct Configuration: Codable, Sendable {
    /// Whether to automatically adapt commands (default: true)
    public var autoAdapt: Bool
    /// Whether to block critical commands (default: true)
    public var blockCritical: Bool
    /// Minimum risk level to warn about (default: low)
    public var warnThreshold: CommandSanitizer.RiskLevel
    /// Default timeout in seconds (default: 30)
    public var defaultTimeout: Int
    /// Default working directory (nil = current)
    public var defaultWorkingDirectory: String?
    
    public static let `default` = Configuration(
      autoAdapt: true,
      blockCritical: true,
      warnThreshold: .low,
      defaultTimeout: 30,
      defaultWorkingDirectory: nil
    )
    
    public init(
      autoAdapt: Bool = true,
      blockCritical: Bool = true,
      warnThreshold: CommandSanitizer.RiskLevel = .low,
      defaultTimeout: Int = 30,
      defaultWorkingDirectory: String? = nil
    ) {
      self.autoAdapt = autoAdapt
      self.blockCritical = blockCritical
      self.warnThreshold = warnThreshold
      self.defaultTimeout = defaultTimeout
      self.defaultWorkingDirectory = defaultWorkingDirectory
    }
  }
  
  public var configuration = Configuration.default
  
  public let supportedTools: Set<String> = [
    "terminal.run",
    "terminal.analyze",
    "terminal.adapt"
  ]
  
  public init() {}
  
  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "terminal.run":
      return await handleRun(id: id, arguments: arguments)
    case "terminal.analyze":
      return handleAnalyze(id: id, arguments: arguments)
    case "terminal.adapt":
      return handleAdapt(id: id, arguments: arguments)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }
  
  // MARK: - terminal.run
  
  /// Run a command with automatic adaptation and safety checks
  private func handleRun(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    // Extract required command parameter
    guard case .success(let command) = requireString("command", from: arguments, id: id) else {
      return missingParamError(id: id, param: "command")
    }
    
    // Optional parameters
    let workingDirectory = optionalString("workingDirectory", from: arguments)
      ?? configuration.defaultWorkingDirectory
    let timeout = optionalInt("timeout", from: arguments, default: configuration.defaultTimeout) ?? 30
    let skipAdaptation = optionalBool("skipAdaptation", from: arguments, default: false)
    let skipSafetyCheck = optionalBool("skipSafetyCheck", from: arguments, default: false)
    
    // 1. Safety analysis (unless skipped)
    var safetyResult: CommandSanitizer.AnalysisResult?
    if !skipSafetyCheck {
      safetyResult = commandSanitizer.analyze(command)
      
      // Block critical commands
      if configuration.blockCritical && safetyResult!.shouldBlock {
        logger.warning("Blocked critical command: \(command, privacy: .public)")
        return (403, makeError(
          id: id,
          code: JSONRPCResponseBuilder.ErrorCode.blocked,
          message: "Command blocked: \(safetyResult!.warnings.first ?? "Critical risk detected")",
          data: [
            "command": command,
            "riskLevel": safetyResult!.riskLevel.rawValue,
            "risks": safetyResult!.risks.map { ["type": $0.type.rawValue, "description": $0.description] },
            "suggestions": safetyResult!.suggestions
          ]
        ))
      }
    }
    
    // 2. Shell adaptation (unless skipped)
    var adaptationResult: ShellAdapter.AdaptationResult?
    let commandToRun: String
    if !skipAdaptation && configuration.autoAdapt {
      adaptationResult = shellAdapter.adapt(command)
      commandToRun = adaptationResult!.adaptedCommand
    } else {
      commandToRun = command
    }
    
    // 3. Execute the command
    let startTime = Date()
    let (stdout, stderr, exitCode) = await executeCommand(
      commandToRun,
      workingDirectory: workingDirectory,
      timeout: timeout
    )
    let duration = Date().timeIntervalSince(startTime)
    
    // 4. Build result
    var result: [String: Any] = [
      "command": command,
      "executed_command": commandToRun,
      "stdout": stdout,
      "stderr": stderr,
      "exit_code": exitCode,
      "success": exitCode == 0,
      "duration_ms": Int(duration * 1000)
    ]
    
    // Add adaptation info
    if let adaptation = adaptationResult {
      result["was_adapted"] = adaptation.wasAdapted
      if adaptation.wasAdapted {
        result["adaptations"] = adaptation.transformations.map(\.rawValue)
        if !adaptation.warnings.isEmpty {
          result["adaptation_warnings"] = adaptation.warnings
        }
      }
    }
    
    // Add safety warnings if any
    if let safety = safetyResult, safety.riskLevel >= configuration.warnThreshold {
      result["risk_level"] = safety.riskLevel.rawValue
      result["safety_warnings"] = safety.warnings
      if !safety.suggestions.isEmpty {
        result["safety_suggestions"] = safety.suggestions
      }
    }
    
    logger.info("Executed command: \(command, privacy: .public) -> exit \(exitCode)")
    return (200, makeResult(id: id, result: result))
  }
  
  // MARK: - terminal.analyze
  
  /// Analyze a command for safety without executing
  private func handleAnalyze(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard case .success(let command) = requireString("command", from: arguments, id: id) else {
      return missingParamError(id: id, param: "command")
    }
    
    let analysis = commandSanitizer.analyze(command)
    
    var result: [String: Any] = [
      "command": command,
      "risk_level": analysis.riskLevel.rawValue,
      "should_block": analysis.shouldBlock,
      "is_safe": analysis.riskLevel == .safe
    ]
    
    if !analysis.risks.isEmpty {
      result["risks"] = analysis.risks.map { risk in
        [
          "type": risk.type.rawValue,
          "level": risk.level.rawValue,
          "description": risk.description,
          "matched": risk.matchedPattern
        ]
      }
    }
    
    if !analysis.warnings.isEmpty {
      result["warnings"] = analysis.warnings
    }
    
    if !analysis.suggestions.isEmpty {
      result["suggestions"] = analysis.suggestions
    }
    
    return (200, makeResult(id: id, result: result))
  }
  
  // MARK: - terminal.adapt
  
  /// Preview shell adaptation without executing
  private func handleAdapt(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard case .success(let command) = requireString("command", from: arguments, id: id) else {
      return missingParamError(id: id, param: "command")
    }
    
    let adaptation = shellAdapter.adapt(command)
    
    var result: [String: Any] = [
      "original_command": adaptation.originalCommand,
      "adapted_command": adaptation.adaptedCommand,
      "was_adapted": adaptation.wasAdapted
    ]
    
    if adaptation.wasAdapted {
      result["transformations"] = adaptation.transformations.map(\.rawValue)
      
      // Provide human-readable transformation descriptions
      result["transformation_details"] = adaptation.transformations.map { transform in
        descriptionFor(transform)
      }
    }
    
    if !adaptation.warnings.isEmpty {
      result["warnings"] = adaptation.warnings
    }
    
    return (200, makeResult(id: id, result: result))
  }
  
  // MARK: - Command Execution
  
  /// Execute a command and return stdout, stderr, and exit code
  private func executeCommand(
    _ command: String,
    workingDirectory: String?,
    timeout: Int
  ) async -> (stdout: String, stderr: String, exitCode: Int32) {
    
    return await withCheckedContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-c", command]
      
      if let dir = workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
      }
      
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      
      // Set up timeout
      let timeoutTask = Task {
        try? await Task.sleep(for: .seconds(timeout))
        if process.isRunning {
          process.terminate()
        }
      }
      
      do {
        try process.run()
        process.waitUntilExit()
        timeoutTask.cancel()
        
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        
        continuation.resume(returning: (stdout, stderr, process.terminationStatus))
      } catch {
        timeoutTask.cancel()
        continuation.resume(returning: ("", error.localizedDescription, -1))
      }
    }
  }
  
  // MARK: - Helpers
  
  /// Get human-readable description for a transformation type
  private func descriptionFor(_ type: ShellAdapter.TransformationType) -> String {
    switch type {
    case .echoEscape:
      return "Removed -e flag from echo (zsh interprets escapes by default)"
    case .commandSubstitution:
      return "Converted backticks to $() syntax"
    case .readCommand:
      return "Converted read -p to zsh read syntax"
    case .arrayExpansion:
      return "Converted ${arr[*]} to zsh array join syntax"
    case .heredoc:
      return "Converted heredoc to escaped quoted string"
    case .declare:
      return "Converted declare to typeset"
    case .sourceCommand:
      return "Normalized source command"
    case .functionExport:
      return "Warning: export -f is not supported in zsh"
    }
  }
}

// MARK: - Error Code Extension

extension JSONRPCResponseBuilder.ErrorCode {
  /// Command blocked due to safety concerns
  public static let blocked = -32050
}
