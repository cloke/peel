//
//  VMChainExecutor.swift
//  KitchenSync
//
//  Created for VM Isolated Execution — Stage 4.
//  Orchestrates booting a VM, bootstrapping toolchain, sharing workspace
//  directories, running chain steps inside the VM, and tearing down.
//

import Foundation

// MARK: - VM Chain Executor

/// Manages the full lifecycle of running an agent chain inside a VM:
///   1. Boot VM with VirtioFS shares
///   2. Mount shared directories inside guest
///   3. Bootstrap toolchain (apk add, post-install scripts)
///   4. Execute deterministic steps via console commands
///   5. Collect output and tear down
///
/// **Note:** Agentic (LLM) steps still run on the host. Only deterministic
/// and gate steps execute inside the VM. The LLM sees the shared workspace
/// on the host side and writes files that appear inside the VM via VirtioFS.
@MainActor
public final class VMChainExecutor {

  // MARK: - Types

  /// Result of executing a chain step inside a VM
  public struct VMStepResult: Sendable {
    public let stepName: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let duration: TimeInterval
  }

  /// Overall result of a VM chain execution
  public struct VMExecutionResult: Sendable {
    public let environment: ExecutionEnvironment
    public let toolchain: VMToolchain
    public let bootDuration: TimeInterval
    public let bootstrapDuration: TimeInterval
    public let stepResults: [VMStepResult]
    public let totalDuration: TimeInterval
    public let success: Bool
    public let errorMessage: String?
  }

  // MARK: - State

  public enum State: Sendable {
    case idle
    case booting
    case bootstrapping
    case running(stepName: String)
    case tearingDown
    case completed
    case failed(String)
  }

  public private(set) var state: State = .idle

  private let vmService: VMIsolationService
  private let logHandler: (@Sendable (String) -> Void)?

  // Track last-booted environment/toolchain for external lifecycle control
  private var lastBootedEnvironment: ExecutionEnvironment?
  private var lastBootedToolchain: VMToolchain?

  // MARK: - Init

  public init(vmService: VMIsolationService, logHandler: (@Sendable (String) -> Void)? = nil) {
    self.vmService = vmService
    self.logHandler = logHandler
  }

  // MARK: - Public API

  /// Execute a chain's deterministic/gate steps inside a VM.
  ///
  /// LLM-driven (agentic) steps are **not** handled here — they continue to
  /// run on the host with the shared workspace visible via VirtioFS.
  ///
  /// - Parameters:
  ///   - environment: Target execution environment (.linux or .macos)
  ///   - toolchain: Toolchain to bootstrap
  ///   - workspacePath: Host path to the agent worktree (shared as "workspace")
  ///   - extraShares: Additional directory shares (e.g. reference docs)
  ///   - commands: Ordered list of (stepName, shellCommand) to execute
  /// - Returns: Aggregated execution result
  public func execute(
    environment: ExecutionEnvironment,
    toolchain: VMToolchain,
    workspacePath: String,
    extraShares: [VMDirectoryShare] = [],
    commands: [(name: String, command: String)]
  ) async throws -> VMExecutionResult {
    let overallStart = Date()
    var stepResults: [VMStepResult] = []

    guard environment != .host else {
      throw VMError.vmCreationFailed("VMChainExecutor should not be used for host execution")
    }

    // 1. Build directory shares
    var shares = [VMDirectoryShare.workspace(workspacePath)] + extraShares
    log("Preparing \(shares.count) directory share(s) for \(environment.displayName)")

    // 2. Boot VM
    state = .booting
    let bootStart = Date()
    try await bootVM(environment: environment, shares: shares)
    let bootDuration = Date().timeIntervalSince(bootStart)
    log("VM booted in \(String(format: "%.1f", bootDuration))s")

    defer {
      // Always tear down
      state = .tearingDown
      Task { @MainActor in
        try? await self.tearDown(environment: environment)
      }
    }

    // 3. Mount shares inside the guest
    if environment == .linux {
      try await vmService.mountDirectoryShares(shares)
      log("Directory shares mounted inside Linux VM")
    }

    // 4. Bootstrap toolchain
    state = .bootstrapping
    let bootstrapStart = Date()
    try await bootstrapToolchain(toolchain, in: environment)
    let bootstrapDuration = Date().timeIntervalSince(bootstrapStart)
    log("Toolchain '\(toolchain.displayName)' bootstrapped in \(String(format: "%.1f", bootstrapDuration))s")

    // 5. Run commands
    for (name, command) in commands {
      state = .running(stepName: name)
      log("Running step '\(name)': \(command.prefix(80))...")

      let stepStart = Date()
      let result: VMStepResult

      switch environment {
      case .linux:
        let output = try await vmService.sendLinuxCommand(
          "cd /mnt/workspace 2>/dev/null || cd /workspace; \(command)",
          timeout: 300
        )
        let exitCode = vmService.lastCommandExitCode
        result = VMStepResult(
          stepName: name,
          exitCode: exitCode,
          stdout: output,
          stderr: "",
          duration: Date().timeIntervalSince(stepStart)
        )

      case .macos:
        // macOS VM execution via SSH or Apple Events (future)
        result = VMStepResult(
          stepName: name,
          exitCode: 0,
          stdout: "[macOS VM command execution not yet implemented]",
          stderr: "",
          duration: Date().timeIntervalSince(stepStart)
        )

      case .host:
        fatalError("Host execution should not reach VMChainExecutor")
      }

      stepResults.append(result)
      log("Step '\(name)' completed in \(String(format: "%.1f", result.duration))s")

      // Gate check: if command includes "gate" in name and exit code != 0, fail
      if name.lowercased().contains("gate") && result.exitCode != 0 {
        state = .failed("Gate '\(name)' failed with exit code \(result.exitCode)")
        return VMExecutionResult(
          environment: environment,
          toolchain: toolchain,
          bootDuration: bootDuration,
          bootstrapDuration: bootstrapDuration,
          stepResults: stepResults,
          totalDuration: Date().timeIntervalSince(overallStart),
          success: false,
          errorMessage: "Gate '\(name)' failed: \(result.stdout)"
        )
      }
    }

    state = .completed
    return VMExecutionResult(
      environment: environment,
      toolchain: toolchain,
      bootDuration: bootDuration,
      bootstrapDuration: bootstrapDuration,
      stepResults: stepResults,
      totalDuration: Date().timeIntervalSince(overallStart),
      success: true,
      errorMessage: nil
    )
  }

  // MARK: - Private Helpers

  private func bootVM(environment: ExecutionEnvironment, shares: [VMDirectoryShare]) async throws {
    switch environment {
    case .linux:
      try await vmService.startLinuxVM(directoryShares: shares)
      // Poll for shell readiness instead of fixed sleep
      try await waitForVMReady(maxAttempts: 30, interval: .seconds(1))

    case .macos:
      // macOS VM boot is more complex — for now use existing startMacOSVM
      // Directory shares are configured at VM creation time
      try await vmService.startMacOSVM()
      try await Task.sleep(for: .seconds(15))

    case .host:
      break
    }
  }

  private func bootstrapToolchain(_ toolchain: VMToolchain, in environment: ExecutionEnvironment) async throws {
    guard toolchain != .minimal else {
      log("Minimal toolchain — no bootstrap needed")
      return
    }

    switch environment {
    case .linux:
      try await bootstrapLinuxToolchain(toolchain)

    case .macos:
      try await bootstrapMacOSToolchain(toolchain)

    case .host:
      break
    }
  }

  /// Public lifecycle: boot VM, mount shares, and bootstrap toolchain for later per-step execution.
  public func bootVM(environment: ExecutionEnvironment, toolchain: VMToolchain, directoryShares: [VMDirectoryShare] = []) async throws {
    guard environment != .host else { return }
    state = .booting
    let bootStart = Date()
    try await bootVM(environment: environment, shares: directoryShares)
    lastBootedEnvironment = environment
    lastBootedToolchain = toolchain
    let bootDuration = Date().timeIntervalSince(bootStart)
    log("VM booted in \(String(format: "%.1f", bootDuration))s")

    // Mount shares for Linux
    if environment == .linux {
      try await vmService.mountDirectoryShares(directoryShares)
      log("Directory shares mounted inside Linux VM")
    }

    // Bootstrap toolchain if requested
    state = .bootstrapping
    let bootstrapStart = Date()
    try await bootstrapToolchain(toolchain, in: environment)
    let bootstrapDuration = Date().timeIntervalSince(bootstrapStart)
    log("Toolchain '\(toolchain.displayName)' bootstrapped in \(String(format: "%.1f", bootstrapDuration))s")
  }

  /// Public lifecycle: tear down the last-booted VM (if any)
  public func tearDown() async throws {
    guard let env = lastBootedEnvironment else { return }
    state = .tearingDown
    try await tearDown(environment: env)
    lastBootedEnvironment = nil
    lastBootedToolchain = nil
  }

  private func bootstrapLinuxToolchain(_ toolchain: VMToolchain) async throws {
    let packages = toolchain.alpinePackages
    if !packages.isEmpty {
      log("Installing packages: \(packages.joined(separator: ", "))")
      let installCmd = "cd /mnt/workspace 2>/dev/null || cd /workspace; apk update && apk add --no-cache \(packages.joined(separator: " "))"
      let output = try await vmService.sendLinuxCommand(
        installCmd,
        timeout: 120
      )
      log("Package install output: \(output.suffix(200))")
    }

    for cmd in toolchain.postInstallCommands {
      log("Running post-install: \(cmd.prefix(60))...")
      let wrapped = "cd /mnt/workspace 2>/dev/null || cd /workspace; \(cmd)"
      let output = try await vmService.sendLinuxCommand(wrapped, timeout: 180)
      log("Post-install output: \(output.suffix(200))")
    }
  }

  private func bootstrapMacOSToolchain(_ toolchain: VMToolchain) async throws {
    // macOS toolchain bootstrap via SSH or Apple Remote Events (future)
    log("macOS toolchain bootstrap not yet implemented — using pre-configured VM")
  }

  private func tearDown(environment: ExecutionEnvironment) async throws {
    switch environment {
    case .linux:
      try await vmService.stopLinuxVM()
      log("Linux VM stopped")

    case .macos:
      try await vmService.stopMacOSVM()
      log("macOS VM stopped")

    case .host:
      break
    }
    state = .idle
  }

  private func log(_ message: String) {
    let formatted = "[VMChainExecutor] \(message)"
    print(formatted)
    logHandler?(formatted)
  }

  /// Poll the VM until the shell is responsive.
  ///
  /// Sends `echo PEEL_READY` via the console and waits for a response.
  /// This replaces the old fixed `Task.sleep(for: .seconds(5))` — the
  /// actual boot time can vary from 2s to 15s depending on the host load.
  private func waitForVMReady(
    maxAttempts: Int = 30,
    interval: Duration = .seconds(1)
  ) async throws {
    log("Waiting for VM shell to become responsive...")
    for attempt in 1...maxAttempts {
      do {
        let output = try await vmService.sendLinuxCommand("echo PEEL_READY", timeout: 3)
        if output.contains("PEEL_READY") {
          log("VM shell responsive after \(attempt) attempt(s)")
          return
        }
      } catch {
        // Timeout or other error — VM shell not ready yet
        if attempt % 5 == 0 {
          log("Still waiting for VM shell (attempt \(attempt)/\(maxAttempts))...")
        }
      }
      try await Task.sleep(for: interval)
    }
    throw VMError.bootstrapFailed("VM shell did not become responsive after \(maxAttempts) attempts")
  }
}
