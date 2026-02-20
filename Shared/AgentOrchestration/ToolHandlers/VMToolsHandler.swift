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
    "vm.linux.exec"
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

    let status: [String: Any] = [
      "virtualizationAvailable": vmIsolationService.isVirtualizationAvailable,
      "linuxReady": vmIsolationService.isLinuxReady,
      "linuxRunning": vmIsolationService.runningLinuxVM != nil,
      "statusMessage": vmIsolationService.statusMessage
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
    ]
  }
}
