//
//  VMToolsHandler.swift
//  KitchenSync
//
//  Created as part of #161: Extract VM tools from MCPServerService.
//

import Foundation
import MCPCore

// MARK: - VM Tools Handler

/// Handles VM isolation tools for both macOS and Linux VMs
@MainActor
public final class VMToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  public let supportedTools: Set<String> = [
    // macOS VM tools
    "vm.macos.status",
    "vm.macos.restore.download",
    "vm.macos.install",
    "vm.macos.start",
    "vm.macos.stop",
    "vm.macos.reset",
    // Linux VM tools
    "vm.linux.status",
    "vm.linux.start",
    "vm.linux.stop",
    "vm.linux.exec",
    // Ad-hoc agent run
    "vm.agent.run"
  ]

  private let vmIsolationService: VMIsolationService
  private let telemetryProvider: MCPTelemetryProviding

  public init(vmIsolationService: VMIsolationService, telemetryProvider: MCPTelemetryProviding) {
    self.vmIsolationService = vmIsolationService
    self.telemetryProvider = telemetryProvider
  }

  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "vm.macos.status":
      return await handleStatus(id: id)
    case "vm.macos.restore.download":
      return await handleRestoreDownload(id: id)
    case "vm.macos.install":
      return await handleInstall(id: id)
    case "vm.macos.start":
      return await handleStart(id: id)
    case "vm.macos.stop":
      return await handleStop(id: id)
    case "vm.macos.reset":
      return await handleReset(id: id, arguments: arguments)
    case "vm.linux.status":
      return await handleLinuxStatus(id: id)
    case "vm.linux.start":
      return await handleLinuxStart(id: id, arguments: arguments)
    case "vm.linux.stop":
      return await handleLinuxStop(id: id)
    case "vm.linux.exec":
      return await handleLinuxExec(id: id, arguments: arguments)
    case "vm.agent.run":
      return await handleAgentRun(id: id, arguments: arguments)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }

  // MARK: - vm.macos.status

  private func handleStatus(id: Any?) async -> (Int, Data) {
    await vmIsolationService.initialize()

    let status: [String: Any] = [
      "virtualizationAvailable": vmIsolationService.isVirtualizationAvailable,
      "macOSReady": vmIsolationService.isMacOSReady,
      "macOSRestoreImagePath": vmIsolationService.macOSRestoreImagePath?.path as Any,
      "macOSInstalled": vmIsolationService.isMacOSVMInstalled,
      "macOSRunning": vmIsolationService.isMacOSVMRunning,
      "statusMessage": vmIsolationService.statusMessage
    ]
    return (200, makeResult(id: id, result: status))
  }

  // MARK: - vm.macos.restore.download

  private func handleRestoreDownload(id: Any?) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.downloadMacOSRestoreImage()
      return await handleStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS restore download failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: error.localizedDescription))
    }
  }

  // MARK: - vm.macos.install

  private func handleInstall(id: Any?) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.installMacOSVM()
      return await handleStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS VM install failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: error.localizedDescription))
    }
  }

  // MARK: - vm.macos.start

  private func handleStart(id: Any?) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.startMacOSVM()
      return await handleStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS VM start failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: error.localizedDescription))
    }
  }

  // MARK: - vm.macos.stop

  private func handleStop(id: Any?) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.stopMacOSVM()
      return await handleStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS VM stop failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: error.localizedDescription))
    }
  }

  // MARK: - vm.macos.reset

  private func handleReset(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let deleteRestoreImage = arguments["deleteRestoreImage"] as? Bool ?? false
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.resetMacOSVM(deleteRestoreImage: deleteRestoreImage)
      return await handleStatus(id: id)
    } catch {
      await telemetryProvider.warning("macOS VM reset failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: error.localizedDescription))
    }
  }

  // MARK: - vm.linux.status

  private func handleLinuxStatus(id: Any?) async -> (Int, Data) {
    await vmIsolationService.initialize()

    let consoleSnippet = String(vmIsolationService.consoleOutput.suffix(2000))
    let diag = vmIsolationService.consoleReaderDiagnostics()
    let status: [String: Any] = [
      "virtualizationAvailable": vmIsolationService.isVirtualizationAvailable,
      "linuxReady": vmIsolationService.isLinuxReady,
      "linuxRunning": vmIsolationService.runningLinuxVM != nil,
      "statusMessage": vmIsolationService.statusMessage,
      "consoleOutput": consoleSnippet,
      "consoleDiag": diag
    ]
    return (200, makeResult(id: id, result: status))
  }

  // MARK: - vm.linux.start

  private func handleLinuxStart(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()

      // Parse optional directory shares
      var shares: [VMDirectoryShare] = []
      if let sharesArray = arguments["directoryShares"] as? [[String: Any]] {
        for shareDict in sharesArray {
          if let hostPath = shareDict["hostPath"] as? String,
             let tag = shareDict["tag"] as? String {
            let readOnly = shareDict["readOnly"] as? Bool ?? false
            shares.append(VMDirectoryShare(hostPath: hostPath, tag: tag, readOnly: readOnly))
          }
        }
      }

      try await vmIsolationService.startLinuxVM(directoryShares: shares)
      return await handleLinuxStatus(id: id)
    } catch {
      await telemetryProvider.warning("Linux VM start failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: error.localizedDescription))
    }
  }

  // MARK: - vm.linux.stop

  private func handleLinuxStop(id: Any?) async -> (Int, Data) {
    do {
      await vmIsolationService.initialize()
      try await vmIsolationService.stopLinuxVM()
      return await handleLinuxStatus(id: id)
    } catch {
      await telemetryProvider.warning("Linux VM stop failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: error.localizedDescription))
    }
  }

  // MARK: - vm.linux.exec

  private func handleLinuxExec(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let command = arguments["command"] as? String, !command.isEmpty else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Missing required 'command' parameter"))
    }

    let timeout = arguments["timeout"] as? Double ?? 30.0

    do {
      let output = try await vmIsolationService.sendLinuxCommand(command, timeout: timeout)
      let result: [String: Any] = [
        "command": command,
        "output": output,
        "success": true
      ]
      return (200, makeResult(id: id, result: result))
    } catch {
      await telemetryProvider.warning("Linux VM exec failed", metadata: ["error": error.localizedDescription, "command": command])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: error.localizedDescription))
    }
  }

  // MARK: - vm.agent.run

  private func handleAgentRun(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Missing required 'prompt' parameter"))
    }
    guard let workspacePath = arguments["workspacePath"] as? String, !workspacePath.isEmpty else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Missing required 'workspacePath' parameter"))
    }

    let agentBinary = arguments["agentBinary"] as? String ?? "copilot"
    let installCommand = arguments["installCommand"] as? String
    let agentArgs = arguments["agentArgs"] as? [String] ?? []
    let model = arguments["model"] as? String
    let timeoutSeconds = arguments["timeoutSeconds"] as? Double ?? 600

    // Verify workspace path exists on host
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDir), isDir.boolValue else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "workspacePath does not exist or is not a directory: \(workspacePath)"))
    }

    let startTime = Date()
    await telemetryProvider.info("vm.agent.run start", metadata: [
      "agentBinary": agentBinary,
      "workspacePath": workspacePath,
      "timeoutSeconds": String(Int(timeoutSeconds))
    ])

    // 1. Boot VM with VirtioFS workspace share
    do {
      await vmIsolationService.initialize()
      let shares = [VMDirectoryShare.workspace(workspacePath)]
      try await vmIsolationService.startLinuxVM(directoryShares: shares)
    } catch {
      await telemetryProvider.warning("vm.agent.run: VM boot failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: "VM boot failed: \(error.localizedDescription)"))
    }

    // Ensure VM is cleaned up when we're done
    defer {
      Task { @MainActor in
        try? await self.vmIsolationService.stopLinuxVM()
      }
    }

    // 2. Wait for VM shell to become responsive
    do {
      try await waitForVMReady()
    } catch {
      await telemetryProvider.warning("vm.agent.run: VM not responsive", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: "VM shell not responsive: \(error.localizedDescription)"))
    }

    // 3. Mount workspace inside VM
    do {
      try await vmIsolationService.mountDirectoryShares([VMDirectoryShare.workspace(workspacePath)])
    } catch {
      await telemetryProvider.warning("vm.agent.run: Mount failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: "Failed to mount workspace: \(error.localizedDescription)"))
    }

    // 4. Install agent if needed
    do {
      let checkCmd = "which \(agentBinary) 2>/dev/null && echo AGENT_FOUND || echo AGENT_MISSING"
      let checkOutput = try await vmIsolationService.sendLinuxCommand(checkCmd, timeout: 10)
      if checkOutput.contains("AGENT_MISSING") {
        if let installCommand = installCommand, !installCommand.isEmpty {
          await telemetryProvider.info("vm.agent.run: Installing agent", metadata: ["command": installCommand])
          _ = try await vmIsolationService.sendLinuxCommand(installCommand, timeout: 120)
        } else {
          return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: "Agent binary '\(agentBinary)' not found in VM and no installCommand provided"))
        }
      }
    } catch {
      await telemetryProvider.warning("vm.agent.run: Agent install failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.vmError, message: "Agent install failed: \(error.localizedDescription)"))
    }

    // 5. Initialize git in workspace for diff tracking
    _ = try? await vmIsolationService.sendLinuxCommand(
      "cd /mnt/workspace && git rev-parse --git-dir >/dev/null 2>&1 || git init -q && git add -A && git commit -q -m 'pre-agent snapshot' --allow-empty 2>/dev/null",
      timeout: 30
    )

    // 6. Build and run the agent command
    var cmdParts: [String] = []
    cmdParts.append("cd /mnt/workspace")
    // Export environment variables for agent RAG callback
    cmdParts.append("export GH_TOKEN=${GH_TOKEN:-}")
    cmdParts.append("export PEEL_HOST_IP=$(ip route | grep default | awk '{print $3}')")
    cmdParts.append("export PEEL_MCP_PORT=8765")
    // Build the agent invocation
    var agentCmd = agentBinary
    if let model = model, !model.isEmpty {
      agentCmd += " --model \(model)"
    }
    for arg in agentArgs {
      agentCmd += " \(arg)"
    }
    // Pass prompt via stdin heredoc to avoid shell escaping issues
    let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
    agentCmd += " <<'PEEL_PROMPT_EOF'\n\(escapedPrompt)\nPEEL_PROMPT_EOF"
    cmdParts.append(agentCmd)

    let fullCommand = cmdParts.joined(separator: " && ")

    // Run with timeout
    var agentOutput = ""
    var agentExitCode: Int32 = 1
    do {
      agentOutput = try await vmIsolationService.sendLinuxCommand(fullCommand, timeout: timeoutSeconds)
      agentExitCode = vmIsolationService.lastCommandExitCode
    } catch {
      // Timeout or other error — capture partial results
      agentOutput = "Agent execution error: \(error.localizedDescription)"
      agentExitCode = 124  // conventional timeout exit code
      await telemetryProvider.warning("vm.agent.run: Agent execution failed/timed out", metadata: ["error": error.localizedDescription])
    }

    // 7. Capture git diff summary
    var diffSummary = ""
    do {
      diffSummary = try await vmIsolationService.sendLinuxCommand(
        "cd /mnt/workspace && git add -A && git diff --cached --stat 2>/dev/null || echo 'No git diff available'",
        timeout: 15
      )
    } catch {
      diffSummary = "Unable to capture diff: \(error.localizedDescription)"
    }

    let duration = Date().timeIntervalSince(startTime)
    let durationStr = String(format: "%.1fs", duration)

    await telemetryProvider.info("vm.agent.run complete", metadata: [
      "agentBinary": agentBinary,
      "exitCode": String(agentExitCode),
      "duration": durationStr
    ])

    let result: [String: Any] = [
      "agentBinary": agentBinary,
      "prompt": String(prompt.prefix(200)),
      "output": agentOutput,
      "exitCode": Int(agentExitCode),
      "diffSummary": diffSummary,
      "duration": durationStr,
      "success": agentExitCode == 0
    ]
    return (200, makeResult(id: id, result: result))
  }

  // MARK: - VM Ready Polling

  /// Poll the VM until the shell is responsive.
  private func waitForVMReady(maxAttempts: Int = 30, interval: Duration = .seconds(1)) async throws {
    for attempt in 1...maxAttempts {
      do {
        let output = try await vmIsolationService.sendLinuxCommand("echo PEEL_READY", timeout: 3)
        if output.contains("PEEL_READY") {
          return
        }
      } catch {
        if attempt % 5 == 0 {
          await telemetryProvider.info("vm.agent.run: Waiting for VM shell (attempt \(attempt)/\(maxAttempts))")
        }
      }
      try await Task.sleep(for: interval)
    }
    throw VMError.bootstrapFailed("VM shell did not become responsive after \(maxAttempts) attempts")
  }
}

// MARK: - Tool Definitions

extension VMToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      // macOS VM tools
      MCPToolDefinition(
        name: "vm.macos.status",
        description: "Get macOS VM readiness and status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "vm.macos.restore.download",
        description: "Download the macOS restore image",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "vm.macos.install",
        description: "Install macOS into the VM disk",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "vm.macos.start",
        description: "Start the macOS VM",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "vm.macos.stop",
        description: "Stop the macOS VM",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "vm.macos.reset",
        description: "Delete the macOS VM bundle and reset install state",
        inputSchema: [
          "type": "object",
          "properties": [
            "deleteRestoreImage": ["type": "boolean"]
          ]
        ],
        category: .vm,
        isMutating: true
      ),
      // Linux VM tools
      MCPToolDefinition(
        name: "vm.linux.status",
        description: "Get Linux VM readiness and running status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "vm.linux.start",
        description: "Start a Linux VM with optional VirtioFS directory shares",
        inputSchema: [
          "type": "object",
          "properties": [
            "directoryShares": [
              "type": "array",
              "description": "Directories to share between host and VM via VirtioFS",
              "items": [
                "type": "object",
                "properties": [
                  "hostPath": ["type": "string", "description": "Host directory path"],
                  "tag": ["type": "string", "description": "Mount tag inside VM"],
                  "readOnly": ["type": "boolean", "description": "Whether share is read-only"]
                ],
                "required": ["hostPath", "tag"]
              ]
            ]
          ]
        ],
        category: .vm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "vm.linux.stop",
        description: "Stop the running Linux VM",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "vm.linux.exec",
        description: "Execute a command inside the running Linux VM via console",
        inputSchema: [
          "type": "object",
          "properties": [
            "command": ["type": "string", "description": "Shell command to execute inside the Linux VM"],
            "timeout": ["type": "number", "description": "Timeout in seconds (default: 30)"]
          ],
          "required": ["command"]
        ],
        category: .vm,
        isMutating: true
      ),
      // Ad-hoc agent run
      MCPToolDefinition(
        name: "vm.agent.run",
        description: "Run a coding agent inside an isolated Linux VM with a shared workspace. Boots a VM, installs the agent if needed, runs it with the given prompt, captures output and git diff summary, then tears down the VM.",
        inputSchema: [
          "type": "object",
          "properties": [
            "prompt": ["type": "string", "description": "The task for the agent to perform"],
            "workspacePath": ["type": "string", "description": "Host path to the workspace directory to share with the VM via VirtioFS"],
            "agentBinary": ["type": "string", "description": "Which agent CLI to run (default: 'copilot'). Examples: copilot, claude, aider"],
            "installCommand": ["type": "string", "description": "Shell command to install the agent if not already present in the VM (e.g. 'pip install aider-chat')"],
            "agentArgs": [
              "type": "array",
              "description": "Additional CLI arguments to pass to the agent",
              "items": ["type": "string"]
            ],
            "model": ["type": "string", "description": "Model name to pass to the agent CLI via --model flag"],
            "timeoutSeconds": ["type": "number", "description": "Maximum runtime in seconds (default: 600)"]
          ],
          "required": ["prompt", "workspacePath"]
        ],
        category: .vm,
        isMutating: true
      ),
    ]
  }
}
