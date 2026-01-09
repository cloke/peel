//
//  CLIService.swift
//  KitchenSync
//
//  Created on 1/7/26.
//  Modified: 1/8/26 - Added model info parsing
//

import Foundation
import TaskRunner

#if os(macOS)

/// Service for detecting and interacting with AI CLI tools
@MainActor
@Observable
public final class CLIService {
  
  // MARK: - Types
  
  public enum CLIStatus: Equatable {
    case checking
    case available(version: String?)
    case notInstalled
    case notAuthenticated
    case needsExtension  // gh installed & authed, but copilot extension missing
    case error(String)
    
    public var isAvailable: Bool {
      if case .available = self { return true }
      return false
    }
    
    /// gh CLI is installed (may or may not have extension)
    public var hasGitHubCLI: Bool {
      switch self {
      case .available, .notAuthenticated, .needsExtension: return true
      default: return false
      }
    }
    
    /// gh CLI is installed and authenticated
    public var isAuthenticated: Bool {
      switch self {
      case .available, .needsExtension: return true
      default: return false
      }
    }
  }
  
  public enum InstallStep: Equatable {
    case idle
    case installing(String)
    case complete
    case failed(String)
  }
  
  // MARK: - Properties
  
  public var copilotStatus: CLIStatus = .checking
  public var claudeStatus: CLIStatus = .checking
  public var copilotInstallStep: InstallStep = .idle
  public var installOutput: [String] = []
  
  private let executor = ProcessExecutor()
  
  // MARK: - Static
  
  public static let copilotInstallInstructions = """
  brew install copilot-cli
  copilot
  # Follow prompts to authenticate
  """
  
  public static let claudeInstallInstructions = """
  npm install -g @anthropic-ai/claude-cli
  claude auth login
  """
  
  // MARK: - Init
  
  public init() {}
  
  // MARK: - Check CLIs
  
  public func checkAllCLIs() async {
    await checkCopilot()
    await checkClaude()
  }
  
  public func checkCopilot() async {
    copilotStatus = .checking
    
    do {
      // Look for new copilot-cli (the standalone CLI, not the deprecated gh extension)
      let copilotPath = findExecutable("copilot")
      guard let copilotPath else {
        copilotStatus = .notInstalled
        return
      }
      
      // Check version (will work if authenticated)
      let versionResult = try await executor.execute(copilotPath, arguments: ["--version"], throwOnNonZeroExit: false)
      if versionResult.exitCode == 0 {
        let version = versionResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        copilotStatus = .available(version: version.isEmpty ? nil : version)
      } else {
        // CLI installed but may need authentication
        copilotStatus = .notAuthenticated
      }
      
    } catch {
      copilotStatus = .error(error.localizedDescription)
    }
  }
  
  /// Find an executable by checking common paths (since app bundle doesn't inherit shell PATH)
  private func findExecutable(_ name: String) -> String? {
    let paths = [
      "/opt/homebrew/bin/\(name)",    // Apple Silicon Homebrew
      "/usr/local/bin/\(name)",        // Intel Homebrew
      "/usr/bin/\(name)",              // System
      "/bin/\(name)"                   // Base system
    ]
    
    for path in paths {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }
    return nil
  }
  
  public func checkClaude() async {
    claudeStatus = .checking
    
    // Check common paths for claude CLI
    let claudePath = findExecutable("claude")
    guard let claudePath else {
      claudeStatus = .notInstalled
      return
    }
    
    do {
      let versionResult = try await executor.execute(claudePath, arguments: ["--version"], throwOnNonZeroExit: false)
      if versionResult.exitCode == 0 {
        let version = versionResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeStatus = .available(version: version.isEmpty ? nil : version)
      } else {
        claudeStatus = .notAuthenticated
      }
    } catch {
      claudeStatus = .error(error.localizedDescription)
    }
  }
  
  // MARK: - Installation
  
  public func installCopilotCLI() async {
    copilotInstallStep = .installing("Installing Copilot CLI...")
    installOutput.append("$ brew install copilot-cli")
    
    // Find brew in common paths
    let brewPath = findExecutable("brew") ?? "/opt/homebrew/bin/brew"
    
    do {
      let result = try await executor.execute(brewPath, arguments: ["install", "copilot-cli"], throwOnNonZeroExit: false)
      
      installOutput.append(result.stdoutString)
      if !result.stderrString.isEmpty {
        installOutput.append(result.stderrString)
      }
      
      if result.exitCode == 0 || result.stdoutString.contains("already installed") || result.stderrString.contains("already installed") {
        installOutput.append("✓ Copilot CLI ready!")
        copilotInstallStep = .complete
      } else {
        copilotInstallStep = .failed("Exit code \(result.exitCode)")
      }
    } catch {
      copilotInstallStep = .failed(error.localizedDescription)
      installOutput.append("Error: \(error.localizedDescription)")
    }
    
    await checkCopilot()
  }
  
  public func openCopilotAuth() {
    copilotInstallStep = .installing("Opening Terminal...")
    installOutput.append("Please run: copilot (then follow authentication prompts)")
    
    let script = "tell application \"Terminal\" to do script \"copilot\""
    if let appleScript = NSAppleScript(source: script) {
      var error: NSDictionary?
      appleScript.executeAndReturnError(&error)
    }
  }
  
  public func resetInstall() {
    copilotInstallStep = .idle
    installOutput = []
  }
  
  // MARK: - Running Agents
  
  /// Simple result type for process execution
  private struct ExecutionResult {
    let stdoutString: String
    let stderrString: String
    let exitCode: Int32
  }
  
  /// Response from a Copilot session including model info
  public struct CopilotResponse {
    public let content: String
    public let model: String?
    public let duration: String?
    public let tokensUsed: String?
    public let premiumRequests: String?
    
    /// Formatted stats for display
    public var statsText: String {
      var parts: [String] = []
      if let model { parts.append("Model: \(model)") }
      if let duration { parts.append("Duration: \(duration)") }
      if let tokensUsed { parts.append("Tokens: \(tokensUsed)") }
      if let premiumRequests { parts.append(premiumRequests) }
      let result = parts.joined(separator: " • ")
      // Return placeholder if nothing was parsed
      return result.isEmpty ? "Stats unavailable" : result
    }
  }
  
  /// Get GitHub token from gh CLI for passing to copilot
  private func getGitHubToken() async -> String? {
    let ghPath = findExecutable("gh") ?? "/opt/homebrew/bin/gh"
    
    do {
      let result = try await executor.execute(ghPath, arguments: ["auth", "token"], throwOnNonZeroExit: false)
      if result.exitCode == 0 {
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    } catch {
      // Ignore errors, token is optional
    }
    return nil
  }
  
  /// Run a GitHub Copilot session with the given prompt (non-interactive mode)
  /// - Parameters:
  ///   - prompt: The prompt/question to ask Copilot
  ///   - model: The model to use (e.g., claude-sonnet-4.5, gpt-5)
  ///   - role: The agent role (determines tool access)
  ///   - workingDirectory: Optional directory to run in (for repo context)
  ///   - allowAllTools: If true, auto-approve all tool usage (required for non-interactive)
  /// - Returns: CopilotResponse with content and model info
  public func runCopilotSession(
    prompt: String,
    model: CopilotModel = .claudeSonnet45,
    role: AgentRole = .implementer,
    workingDirectory: String? = nil,
    allowAllTools: Bool = true
  ) async throws -> CopilotResponse {
    guard copilotStatus.isAvailable else {
      throw CLIError.notAvailable("GitHub Copilot CLI is not available. Please complete setup first.")
    }
    
    let copilotPath = findExecutable("copilot") ?? "/opt/homebrew/bin/copilot"
    
    // Get GitHub token from gh CLI to pass to copilot
    let token = await getGitHubToken()
    
    // Use -p for non-interactive mode, --model for model selection, --allow-all-tools for auto-approval
    var arguments = ["-p", prompt, "--model", model.rawValue]
    if allowAllTools {
      arguments.append("--allow-all-tools")
    }
    
    // Apply role-based tool restrictions
    let deniedTools = role.deniedTools
    if !deniedTools.isEmpty {
      arguments.append("--deny-tool")
      arguments.append(contentsOf: deniedTools)
    }
    
    // Build environment with GH_TOKEN if available
    var environment = ProcessInfo.processInfo.environment
    if let token {
      environment["GH_TOKEN"] = token
    }
    
    let result = try await executeWithEnvironment(
      copilotPath,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment
    )
    
    if result.exitCode != 0 {
      let errorMsg = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
      throw CLIError.executionFailed("Copilot failed: \(errorMsg)")
    }
    
    // Content is in stdout, stats are in stderr - combine for parsing
    let combinedOutput = result.stdoutString + "\n" + result.stderrString
    return parseCopilotOutput(combinedOutput)
  }
  
  /// Parse copilot output to extract content and stats
  private func parseCopilotOutput(_ output: String) -> CopilotResponse {
    let lines = output.components(separatedBy: "\n")
    
    // Find where stats section starts (look for "Total usage est:")
    var contentLines: [String] = []
    var model: String?
    var duration: String?
    var tokensUsed: String?
    var premiumRequests: String?
    var inStats = false
    
    for line in lines {
      if line.contains("Total usage est:") {
        inStats = true
        // Extract premium requests count (e.g., "1 Premium request" or "3 Premium requests")
        if let match = line.range(of: "\\d+\\s+Premium\\s+request", options: .regularExpression) {
          let text = String(line[match])
          // Format nicely: "1 Premium request" -> "1 Premium"
          premiumRequests = text.replacingOccurrences(of: " request", with: "")
        }
        continue
      }
      
      if inStats {
        // Parse stats lines
        if line.contains("Total duration (API):") {
          duration = line.replacingOccurrences(of: "Total duration (API):", with: "").trimmingCharacters(in: .whitespaces)
        } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("claude") || 
                  line.trimmingCharacters(in: .whitespaces).hasPrefix("gpt") ||
                  line.trimmingCharacters(in: .whitespaces).hasPrefix("gemini") {
          // This is a model usage line like "    claude-sonnet-4.5    19.0k input, 103 output..."
          let trimmed = line.trimmingCharacters(in: .whitespaces)
          // Split on multiple spaces to separate model name from stats
          let components = trimmed.components(separatedBy: "    ").filter { !$0.isEmpty }
          if let modelName = components.first?.trimmingCharacters(in: .whitespaces) {
            model = modelName
          }
          // Extract token counts
          if let inputMatch = trimmed.range(of: "[\\d.]+k?\\s+input", options: .regularExpression) {
            let inputStr = String(trimmed[inputMatch]).replacingOccurrences(of: " input", with: "")
            if let outputMatch = trimmed.range(of: "[\\d.]+k?\\s+output", options: .regularExpression) {
              let outputStr = String(trimmed[outputMatch]).replacingOccurrences(of: " output", with: "")
              tokensUsed = "\(inputStr) in / \(outputStr) out"
            }
          }
        }
      } else {
        contentLines.append(line)
      }
    }
    
    // Remove trailing empty lines from content
    while contentLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      contentLines.removeLast()
    }
    
    let content = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    
    return CopilotResponse(
      content: content,
      model: model,
      duration: duration,
      tokensUsed: tokensUsed,
      premiumRequests: premiumRequests
    )
  }
  
  /// Execute a command with custom environment variables (runs off main actor)
  private func executeWithEnvironment(
    _ executable: String,
    arguments: [String],
    workingDirectory: String?,
    environment: [String: String]
  ) async throws -> ExecutionResult {
    // Capture parameters for the detached task
    let execPath = executable
    let args = arguments
    let workDir = workingDirectory
    let env = environment
    
    // Run process execution in a detached task to avoid blocking main actor
    return try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      
      process.executableURL = URL(fileURLWithPath: execPath)
      process.arguments = args
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      process.environment = env
      
      if let workDir {
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
      }
      
      try process.run()
      
      // Read output asynchronously
      let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
      let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
      
      process.waitUntilExit()
      
      return ExecutionResult(
        stdoutString: String(data: stdoutData, encoding: .utf8) ?? "",
        stderrString: String(data: stderrData, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus
      )
    }.value
  }
  
  /// Run a Claude CLI session with the given prompt
  /// - Parameters:
  ///   - prompt: The prompt to send to Claude
  ///   - workingDirectory: Optional directory to run in
  /// - Returns: The response from Claude
  public func runClaudeSession(prompt: String, workingDirectory: String? = nil) async throws -> String {
    guard claudeStatus.isAvailable else {
      throw CLIError.notAvailable("Claude CLI is not available. Please install it first.")
    }
    
    let claudePath = findExecutable("claude") ?? "/usr/local/bin/claude"
    
    // Claude CLI usage: claude "prompt"
    let result = try await executor.execute(
      claudePath,
      arguments: [prompt],
      workingDirectory: workingDirectory,
      throwOnNonZeroExit: false
    )
    
    if result.exitCode != 0 {
      let errorMsg = result.stderrString.isEmpty ? "Unknown error" : result.stderrString
      throw CLIError.executionFailed("Claude failed: \(errorMsg)")
    }
    
    return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum CLIError: LocalizedError {
  case notAvailable(String)
  case executionFailed(String)
  
  public var errorDescription: String? {
    switch self {
    case .notAvailable(let msg): return msg
    case .executionFailed(let msg): return msg
    }
  }
}

#else
@MainActor
@Observable
public final class CLIService {
  public enum CLIStatus: Equatable { case notInstalled; var isAvailable: Bool { false } }
  public enum InstallStep: Equatable { case idle }
  public var copilotStatus: CLIStatus = .notInstalled
  public var claudeStatus: CLIStatus = .notInstalled
  public var copilotInstallStep: InstallStep = .idle
  public var installOutput: [String] = []
  public init() {}
  public func checkAllCLIs() async {}
  public func resetInstall() {}
  public static let copilotInstallInstructions = ""
  public static let claudeInstallInstructions = ""
}
#endif
