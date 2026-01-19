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
  private let mcpLog = MCPLogService.shared
  private let statusCacheTTL: TimeInterval = 12 * 60 * 60
  private let statusEncoder = JSONEncoder()
  private let statusDecoder = JSONDecoder()
  
  private enum CacheKey {
    static let copilotStatus = "CLIService.copilotStatus"
    static let claudeStatus = "CLIService.claudeStatus"
    static let lastCheckedAt = "CLIService.lastCheckedAt"
  }
  
  private struct PersistedCLIStatus: Codable {
    let kind: String
    let version: String?
    let message: String?
    let updatedAt: Date
  }
  
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
  
  public init() {
    loadCachedStatuses()
  }
  
  // MARK: - Check CLIs
  
  public func checkAllCLIs(force: Bool = false) async {
    if !force, applyCachedStatusesIfFresh() {
      return
    }
    await checkCopilot()
    await checkClaude()
  }
  
  public func checkCopilot() async {
    setCopilotStatus(.checking, persist: false)
    defer { updateLastCheckedAt() }
    
    do {
      // Look for new copilot-cli (the standalone CLI, not the deprecated gh extension)
      let copilotPath = findExecutable("copilot")
      guard let copilotPath else {
        setCopilotStatus(.notInstalled)
        return
      }
      
      // Check version (will work if authenticated)
      let versionResult = try await executor.execute(copilotPath, arguments: ["--version"], throwOnNonZeroExit: false)
      if versionResult.exitCode == 0 {
        let version = versionResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        setCopilotStatus(.available(version: version.isEmpty ? nil : version))
      } else {
        // CLI installed but may need authentication
        setCopilotStatus(.notAuthenticated)
      }
      
    } catch {
      setCopilotStatus(.error(error.localizedDescription))
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
    setClaudeStatus(.checking, persist: false)
    defer { updateLastCheckedAt() }
    
    // Check common paths for claude CLI
    let claudePath = findExecutable("claude")
    guard let claudePath else {
      setClaudeStatus(.notInstalled)
      return
    }
    
    do {
      let versionResult = try await executor.execute(claudePath, arguments: ["--version"], throwOnNonZeroExit: false)
      if versionResult.exitCode == 0 {
        let version = versionResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        setClaudeStatus(.available(version: version.isEmpty ? nil : version))
      } else {
        setClaudeStatus(.notAuthenticated)
      }
    } catch {
      setClaudeStatus(.error(error.localizedDescription))
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

  // MARK: - Status Persistence

  private func setCopilotStatus(_ status: CLIStatus, persist: Bool = true) {
    copilotStatus = status
    if persist {
      persistStatus(status, key: CacheKey.copilotStatus)
    }
  }

  private func setClaudeStatus(_ status: CLIStatus, persist: Bool = true) {
    claudeStatus = status
    if persist {
      persistStatus(status, key: CacheKey.claudeStatus)
    }
  }

  private func applyCachedStatusesIfFresh() -> Bool {
    guard cacheIsFresh() else { return false }
    loadCachedStatuses()
    return copilotStatus != .checking || claudeStatus != .checking
  }

  private func cacheIsFresh() -> Bool {
    guard let lastChecked = UserDefaults.standard.object(forKey: CacheKey.lastCheckedAt) as? Date else {
      return false
    }
    return Date().timeIntervalSince(lastChecked) < statusCacheTTL
  }

  private func updateLastCheckedAt() {
    UserDefaults.standard.set(Date(), forKey: CacheKey.lastCheckedAt)
  }

  private func loadCachedStatuses() {
    if let persisted = loadPersistedStatus(for: CacheKey.copilotStatus) {
      copilotStatus = status(from: persisted)
    }
    if let persisted = loadPersistedStatus(for: CacheKey.claudeStatus) {
      claudeStatus = status(from: persisted)
    }
  }

  private func persistStatus(_ status: CLIStatus, key: String) {
    if case .checking = status { return }
    let persisted = PersistedCLIStatus(
      kind: statusKind(status),
      version: statusVersion(status),
      message: statusMessage(status),
      updatedAt: Date()
    )
    if let data = try? statusEncoder.encode(persisted) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  private func loadPersistedStatus(for key: String) -> PersistedCLIStatus? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? statusDecoder.decode(PersistedCLIStatus.self, from: data)
  }

  private func status(from persisted: PersistedCLIStatus) -> CLIStatus {
    switch persisted.kind {
    case "available": return .available(version: persisted.version)
    case "notInstalled": return .notInstalled
    case "notAuthenticated": return .notAuthenticated
    case "needsExtension": return .needsExtension
    case "error": return .error(persisted.message ?? "Unknown error")
    default: return .notInstalled
    }
  }

  private func statusKind(_ status: CLIStatus) -> String {
    switch status {
    case .available: return "available"
    case .notInstalled: return "notInstalled"
    case .notAuthenticated: return "notAuthenticated"
    case .needsExtension: return "needsExtension"
    case .error: return "error"
    case .checking: return "checking"
    }
  }

  private func statusVersion(_ status: CLIStatus) -> String? {
    if case .available(let version) = status { return version }
    return nil
  }

  private func statusMessage(_ status: CLIStatus) -> String? {
    if case .error(let message) = status { return message }
    return nil
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
  
  /// Callback for streaming output from copilot
  public typealias StreamCallback = @MainActor (String) -> Void
  
  /// Run a GitHub Copilot session with the given prompt (non-interactive mode)
  /// - Parameters:
  ///   - prompt: The prompt/question to ask Copilot
  ///   - model: The model to use (e.g., claude-sonnet-4.5, gpt-5)
  ///   - role: The agent role (determines tool access)
  ///   - workingDirectory: Optional directory to run in (for repo context)
  ///   - allowAllTools: If true, auto-approve all tool usage (required for non-interactive)
  ///   - onOutput: Optional callback for streaming output lines
  /// - Returns: CopilotResponse with content and model info
  public func runCopilotSession(
    prompt: String,
    model: CopilotModel = .claudeSonnet45,
    role: AgentRole = .implementer,
    workingDirectory: String? = nil,
    allowAllTools: Bool = true,
    onOutput: StreamCallback? = nil
  ) async throws -> CopilotResponse {
    guard copilotStatus.isAvailable else {
      throw CLIError.notAvailable("GitHub Copilot CLI is not available. Please complete setup first.")
    }
    
    let copilotPath = findExecutable("copilot") ?? "/opt/homebrew/bin/copilot"
    
    // Get GitHub token from gh CLI to pass to copilot
    let token = await getGitHubToken()
    
    // Use -p for non-interactive mode, --model for model selection, --allow-all-tools for auto-approval
    var arguments = ["-p", prompt, "--model", model.rawValue, "--stream", "on"]
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
    
    let result: ExecutionResult
    if let onOutput {
      // Use streaming execution
      result = try await executeWithStreaming(
        copilotPath,
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        modelName: model.displayName,
        roleName: role.displayName,
        onOutput: onOutput
      )
    } else {
      // Use non-streaming execution
      result = try await executeWithEnvironment(
        copilotPath,
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: environment
      )
    }
    
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
  
  /// Execute a command with streaming output using readabilityHandler for immediate updates
  private func executeWithStreaming(
    _ executable: String,
    arguments: [String],
    workingDirectory: String?,
    environment: [String: String],
    modelName: String,
    roleName: String,
    onOutput: @escaping StreamCallback
  ) async throws -> ExecutionResult {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.environment = environment
    
    if let workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }
    
    // Use an actor to safely accumulate data across callbacks
    let completionSignal = CompletionSignal()
    let accumulator = StreamAccumulator(
      onOutput: onOutput,
      onCompletionDetected: { await completionSignal.markCompleted() }
    )

    // Terminate the process if we see Copilot's final stats marker but the process hangs
    Task {
      await completionSignal.waitForCompletion()
      try? await Task.sleep(for: .seconds(1))
      if process.isRunning {
        process.terminate()
      }
    }
    
    // Set up readability handlers for immediate streaming
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty {
        Task {
          await accumulator.appendStdout(data)
        }
      }
    }
    
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty {
        Task {
          await accumulator.appendStderr(data)
        }
      }
    }
    
    return try await withTaskCancellationHandler {
      // Start the process
      try process.run()
      
      // Wait for process to complete
      await withCheckedContinuation { continuation in
        process.terminationHandler = { _ in
          // Clean up handlers
          stdoutPipe.fileHandleForReading.readabilityHandler = nil
          stderrPipe.fileHandleForReading.readabilityHandler = nil
          continuation.resume()
        }
      }
      
      // Give a moment for final callbacks to process
      try? await Task.sleep(for: .milliseconds(100))
      
      // Process any remaining buffered content
      await accumulator.flushRemainingBuffers()
      
      // Get final accumulated data + diagnostics
      let (stdoutData, stderrData) = await accumulator.getFinalData()
      let diagnostics = await accumulator.getDiagnostics()
      if !diagnostics.completionDetected {
        await mcpLog.warning("Copilot stream completed without stats marker", metadata: [
          "model": modelName,
          "role": roleName,
          "workingDirectory": workingDirectory ?? "",
          "exitCode": "\(process.terminationStatus)",
          "stderrTail": diagnostics.stderrTail
        ])
      }
      
      return ExecutionResult(
        stdoutString: String(data: stdoutData, encoding: .utf8) ?? "",
        stderrString: String(data: stderrData, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus
      )
    } onCancel: {
      if process.isRunning {
        process.terminate()
      }
      Task { @MainActor in
        await mcpLog.warning("Copilot stream cancelled", metadata: [
          "model": modelName,
          "role": roleName,
          "workingDirectory": workingDirectory ?? ""
        ])
      }
    }
  }
  
  /// Actor to safely accumulate streaming data across callbacks
  /// Actor to safely accumulate streaming data across callbacks
  private actor StreamAccumulator {
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private let onOutput: StreamCallback
    private let onCompletionDetected: @Sendable () async -> Void
    private var completionMarked = false
    private var stderrTail: [String] = []
    
    init(onOutput: @escaping StreamCallback, onCompletionDetected: @escaping @Sendable () async -> Void) {
      self.onOutput = onOutput
      self.onCompletionDetected = onCompletionDetected
    }
    
    func appendStdout(_ data: Data) async {
      stdoutData.append(data)
      if let str = String(data: data, encoding: .utf8) {
        stdoutBuffer += str
        await processStdoutBuffer()
      }
    }
    
    func appendStderr(_ data: Data) async {
      stderrData.append(data)
      if let str = String(data: data, encoding: .utf8) {
        stderrBuffer += str
        await processStderrBuffer()
      }
    }
    
    private func processStdoutBuffer() async {
      while let newlineRange = stdoutBuffer.range(of: "\n") {
        let line = String(stdoutBuffer[..<newlineRange.lowerBound])
        stdoutBuffer = String(stdoutBuffer[newlineRange.upperBound...])
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          await onOutput(trimmed)
        }
      }
    }
    
    private func processStderrBuffer() async {
      while let newlineRange = stderrBuffer.range(of: "\n") {
        let line = String(stderrBuffer[..<newlineRange.lowerBound])
        stderrBuffer = String(stderrBuffer[newlineRange.upperBound...])
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          await onOutput(trimmed)
          appendStderrTail(trimmed)
        }
        if trimmed.contains("Total usage est:") {
          await markCompletionIfNeeded()
        }
      }
    }
    
    func flushRemainingBuffers() async {
      if !stdoutBuffer.isEmpty {
        let trimmed = stdoutBuffer.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          await onOutput(trimmed)
        }
        stdoutBuffer = ""
      }
      if !stderrBuffer.isEmpty {
        let trimmed = stderrBuffer.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          await onOutput(trimmed)
          appendStderrTail(trimmed)
        }
        if trimmed.contains("Total usage est:") {
          await markCompletionIfNeeded()
        }
        stderrBuffer = ""
      }
    }

    private func markCompletionIfNeeded() async {
      guard !completionMarked else { return }
      completionMarked = true
      await onCompletionDetected()
    }

    private func appendStderrTail(_ line: String) {
      stderrTail.append(line)
      if stderrTail.count > 5 {
        stderrTail.removeFirst(stderrTail.count - 5)
      }
    }

    func getDiagnostics() -> (completionDetected: Bool, stderrTail: String) {
      let tail = stderrTail.joined(separator: " | ")
      return (completionMarked, tail)
    }
    
    func getFinalData() -> (Data, Data) {
      return (stdoutData, stderrData)
    }
  }

  private actor CompletionSignal {
    private var completed = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func markCompleted() {
      guard !completed else { return }
      completed = true
      continuations.forEach { $0.resume() }
      continuations.removeAll()
    }

    func waitForCompletion() async {
      if completed {
        return
      }
      await withCheckedContinuation { continuation in
        continuations.append(continuation)
      }
    }
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
  public func checkAllCLIs(force: Bool = false) async {}
  public func resetInstall() {}
  public static let copilotInstallInstructions = ""
  public static let claudeInstallInstructions = ""
}
#endif
