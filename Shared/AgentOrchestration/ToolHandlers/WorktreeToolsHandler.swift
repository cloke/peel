//
//  WorktreeToolsHandler.swift
//  Peel
//
//  Created as part of #213: Worktree Dashboard - Global view of all worktrees.
//  MCP tools for worktree management and visibility.
//

import Foundation
import MCPCore
#if os(macOS)
import Git
#endif

// MARK: - Worktree Tools Handler Delegate Extension

/// Extended delegate protocol for worktree-specific functionality
@MainActor
protocol WorktreeToolsHandlerDelegate: MCPToolHandlerDelegate {
  /// Get the base directory for swarm worktrees
  func worktreeBaseDir() -> String

  /// List all worktrees from registered repositories
  func listAllWorktrees() async throws -> [WorktreeToolInfo]

  /// Remove a worktree by path
  func removeWorktree(path: String, force: Bool) async throws

  /// Create a new worktree
  func createWorktree(repoPath: String, branchName: String, baseBranch: String) async throws -> String

  /// Get disk size for a directory
  func diskSize(for path: String) -> Int64?

  /// Get current WorktreePool status
  func worktreePoolStatus() async -> WorktreePoolStatus

  /// Configure the WorktreePool
  func configureWorktreePool(size: Int?, baseBranch: String?, recyclePolicy: String?) async throws

  /// Get current GateAgent status
  func gateAgentStatus() async -> GateAgentStatus

  /// Get recent GateAgent validation results
  func gateAgentHistory(limit: Int) async -> [GateValidationResult]
}

// MARK: - Worktree Tool Types

struct WorktreePoolStatus: Sendable {
  let poolSize: Int
  let warmCount: Int
  let claimedCount: Int
  let baseBranch: String
  let recyclePolicy: String
}

struct GateAgentStatus: Sendable {
  let pendingValidations: Int
  let passCount: Int
  let failCount: Int
  let retryCount: Int
  let isActive: Bool
}

struct GateValidationResult: Sendable {
  let branchName: String
  let outcome: String  // "pass", "fail", "retry"
  let timestamp: Date
  let reasons: [String]
}

/// Information about a worktree for MCP tool responses
struct WorktreeToolInfo: Sendable {
  let path: String
  let head: String
  let branch: String?
  let repoPath: String
  let isMain: Bool
  let isDetached: Bool
  let isLocked: Bool
  let lockReason: String?
  let isPrunable: Bool
  let pruneReason: String?
  let diskSizeBytes: Int64?
  let createdAt: Date?

  var displayName: String {
    if let branch = branch {
      if branch.hasPrefix("refs/heads/") {
        return String(branch.dropFirst("refs/heads/".count))
      }
      return branch
    } else if isDetached {
      return "detached @ \(String(head.prefix(7)))"
    } else {
      return URL(fileURLWithPath: path).lastPathComponent
    }
  }

  func toDictionary() -> [String: Any] {
    var dict: [String: Any] = [
      "path": path,
      "head": String(head.prefix(12)),
      "displayName": displayName,
      "repoPath": repoPath,
      "isMain": isMain,
      "isDetached": isDetached,
      "isLocked": isLocked,
      "isPrunable": isPrunable
    ]
    if let branch = branch {
      dict["branch"] = branch
    }
    if let lockReason = lockReason {
      dict["lockReason"] = lockReason
    }
    if let pruneReason = pruneReason {
      dict["pruneReason"] = pruneReason
    }
    if let diskSizeBytes = diskSizeBytes {
      dict["diskSizeBytes"] = diskSizeBytes
      dict["diskSizeFormatted"] = formatBytes(diskSizeBytes)
    }
    if let createdAt = createdAt {
      dict["createdAt"] = ISO8601DateFormatter().string(from: createdAt)
    }
    return dict
  }

  private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

// MARK: - Worktree Tools Handler

/// Handles worktree management tools: worktree.list, worktree.cleanup, etc.
@MainActor
public final class WorktreeToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  /// Typed delegate for worktree-specific operations
  private var worktreeDelegate: WorktreeToolsHandlerDelegate? {
    delegate as? WorktreeToolsHandlerDelegate
  }

  public let supportedTools: Set<String> = [
    "worktree.list",
    "worktree.remove",
    "worktree.stats",
    "worktree.create",
    "worktree.pool.status",
    "worktree.pool.configure",
    "gate.status",
    "gate.history"
  ]

  public init() {}

  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "worktree.list":
      return await handleList(id: id, arguments: arguments)
    case "worktree.remove":
      return await handleRemove(id: id, arguments: arguments)
    case "worktree.stats":
      return await handleStats(id: id, arguments: arguments)
    case "worktree.create":
      return await handleCreate(id: id, arguments: arguments)
    case "worktree.pool.status":
      return await handlePoolStatus(id: id, arguments: arguments)
    case "worktree.pool.configure":
      return await handlePoolConfigure(id: id, arguments: arguments)
    case "gate.status":
      return await handleGateStatus(id: id, arguments: arguments)
    case "gate.history":
      return await handleGateHistory(id: id, arguments: arguments)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }

  // MARK: - worktree.list

  /// List all worktrees across registered repositories and the peel-worktrees directory
  private func handleList(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    #if os(macOS)
    guard let worktreeDelegate else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Worktree delegate not configured"))
    }

    do {
      let schema: [ToolArgSchemaField] = [
        .optional("includeMain", .bool, default: false),
        .optional("repoPath", .string)
      ]
      let parsedResult = parseArguments(arguments, schema: schema, id: id)
      guard case .success(let parsed) = parsedResult else {
        if case .failure(let error) = parsedResult {
          return error.response
        }
        return invalidParamError(id: id, param: "arguments")
      }
      let includeMain = parsed.bool("includeMain") ?? false
      let repoPath = parsed.string("repoPath")

      var allWorktrees = try await worktreeDelegate.listAllWorktrees()

      // Filter to specific repo if requested
      if let repoPath = repoPath {
        allWorktrees = allWorktrees.filter { $0.repoPath == repoPath }
      }

      // Optionally filter out main worktrees
      if !includeMain {
        allWorktrees = allWorktrees.filter { !$0.isMain }
      }

      // Calculate totals
      let totalDiskBytes = allWorktrees.compactMap { $0.diskSizeBytes }.reduce(0, +)
      let prunableCount = allWorktrees.filter { $0.isPrunable }.count

      return (200, makeResult(id: id, result: [
        "worktrees": allWorktrees.map { $0.toDictionary() },
        "count": allWorktrees.count,
        "prunableCount": prunableCount,
        "totalDiskBytes": totalDiskBytes,
        "totalDiskFormatted": totalDiskBytes.formattedBytes
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Failed to list worktrees: \(error.localizedDescription)"))
    }
    #else
    return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "worktree.list is only available on macOS"))
    #endif
  }

  // MARK: - worktree.remove

  /// Remove a worktree by path
  private func handleRemove(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    #if os(macOS)
    guard let worktreeDelegate else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Worktree delegate not configured"))
    }

    let schema: [ToolArgSchemaField] = [
      .required("path", .string),
      .optional("force", .bool, default: false)
    ]
    let parsedResult = parseArguments(arguments, schema: schema, id: id)
    guard case .success(let parsed) = parsedResult else {
      if case .failure(let error) = parsedResult {
        return error.response
      }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let path = parsed.string("path") else {
      return missingParamError(id: id, param: "path")
    }
    let force = parsed.bool("force") ?? false

    do {
      try await worktreeDelegate.removeWorktree(path: path, force: force)
      return (200, makeResult(id: id, result: [
        "success": true,
        "path": path,
        "message": "Worktree removed successfully"
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Failed to remove worktree: \(error.localizedDescription)"))
    }
    #else
    return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "worktree.remove is only available on macOS"))
    #endif
  }

  // MARK: - worktree.stats

  /// Get aggregate statistics about worktrees
  private func handleStats(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    #if os(macOS)
    guard let worktreeDelegate else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Worktree delegate not configured"))
    }

    do {
      let allWorktrees = try await worktreeDelegate.listAllWorktrees()
      let nonMainWorktrees = allWorktrees.filter { !$0.isMain }

      // Group by repo
      var byRepo: [String: Int] = [:]
      for wt in nonMainWorktrees {
        byRepo[wt.repoPath, default: 0] += 1
      }

      // Calculate stats
      let totalDiskBytes = nonMainWorktrees.compactMap { $0.diskSizeBytes }.reduce(0, +)
      let prunableCount = nonMainWorktrees.filter { $0.isPrunable }.count
      let lockedCount = nonMainWorktrees.filter { $0.isLocked }.count
      let detachedCount = nonMainWorktrees.filter { $0.isDetached }.count

      return (200, makeResult(id: id, result: [
        "totalWorktrees": nonMainWorktrees.count,
        "totalMainWorktrees": allWorktrees.filter { $0.isMain }.count,
        "prunableCount": prunableCount,
        "lockedCount": lockedCount,
        "detachedCount": detachedCount,
        "totalDiskBytes": totalDiskBytes,
        "totalDiskFormatted": totalDiskBytes.formattedBytes,
        "byRepository": byRepo.map { ["repoPath": $0.key, "worktreeCount": $0.value] },
        "baseDir": worktreeDelegate.worktreeBaseDir()
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Failed to get worktree stats: \(error.localizedDescription)"))
    }
    #else
    return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "worktree.stats is only available on macOS"))
    #endif
  }

  // MARK: - worktree.create

  /// Create a new worktree for ad-hoc work, PR review, or experiments
  private func handleCreate(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    #if os(macOS)
    guard let worktreeDelegate else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Worktree delegate not configured"))
    }

    let schema: [ToolArgSchemaField] = [
      .required("repoPath", .string),
      .required("branchName", .string),
      .optional("baseBranch", .string, default: "origin/main")
    ]
    let parsedResult = parseArguments(arguments, schema: schema, id: id)
    guard case .success(let parsed) = parsedResult else {
      if case .failure(let error) = parsedResult {
        return error.response
      }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let repoPath = parsed.string("repoPath") else {
      return missingParamError(id: id, param: "repoPath")
    }
    guard let branchName = parsed.string("branchName") else {
      return missingParamError(id: id, param: "branchName")
    }
    let baseBranch = parsed.string("baseBranch") ?? "origin/main"

    // Sanitize branch name
    let sanitizedBranch = sanitizeBranchName(branchName)
    if sanitizedBranch.isEmpty {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Invalid branch name after sanitization"))
    }

    do {
      let worktreePath = try await worktreeDelegate.createWorktree(
        repoPath: repoPath,
        branchName: sanitizedBranch,
        baseBranch: baseBranch
      )

      return (200, makeResult(id: id, result: [
        "success": true,
        "worktreePath": worktreePath,
        "branchName": sanitizedBranch,
        "baseBranch": baseBranch,
        "repoPath": repoPath
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Failed to create worktree: \(error.localizedDescription)"))
    }
    #else
    return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "worktree.create is only available on macOS"))
    #endif
  }

  /// Sanitize a branch name for git
  private func sanitizeBranchName(_ name: String) -> String {
    var sanitized = name.lowercased()
    // Replace spaces and underscores with dashes
    sanitized = sanitized.replacingOccurrences(of: " ", with: "-")
    sanitized = sanitized.replacingOccurrences(of: "_", with: "-")
    // Remove characters not allowed in branch names
    sanitized = sanitized.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "/" }
    // Remove leading/trailing dashes
    sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    // Collapse multiple dashes
    while sanitized.contains("--") {
      sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
    }
    return sanitized
  }

  // MARK: - worktree.pool.status

  private func handlePoolStatus(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let worktreeDelegate else {
      return notConfiguredError(id: id)
    }
    let status = await worktreeDelegate.worktreePoolStatus()
    return (200, makeResult(id: id, result: [
      "poolSize": status.poolSize,
      "warmCount": status.warmCount,
      "claimedCount": status.claimedCount,
      "baseBranch": status.baseBranch,
      "recyclePolicy": status.recyclePolicy
    ]))
  }

  // MARK: - worktree.pool.configure

  private func handlePoolConfigure(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let worktreeDelegate else {
      return notConfiguredError(id: id)
    }
    let size = arguments["size"] as? Int
    let baseBranch = arguments["baseBranch"] as? String
    let recyclePolicy = arguments["recyclePolicy"] as? String

    if let recyclePolicy, !["always", "on-success", "never"].contains(recyclePolicy) {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "recyclePolicy must be one of: always, on-success, never"))
    }

    do {
      try await worktreeDelegate.configureWorktreePool(size: size, baseBranch: baseBranch, recyclePolicy: recyclePolicy)
      return (200, makeResult(id: id, result: [
        "success": true,
        "message": "Pool configuration updated"
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Failed to configure pool: \(error.localizedDescription)"))
    }
  }

  // MARK: - gate.status

  private func handleGateStatus(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let worktreeDelegate else {
      return notConfiguredError(id: id)
    }
    let status = await worktreeDelegate.gateAgentStatus()
    return (200, makeResult(id: id, result: [
      "isActive": status.isActive,
      "pendingValidations": status.pendingValidations,
      "passCount": status.passCount,
      "failCount": status.failCount,
      "retryCount": status.retryCount
    ]))
  }

  // MARK: - gate.history

  private func handleGateHistory(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let worktreeDelegate else {
      return notConfiguredError(id: id)
    }
    let limit = arguments["limit"] as? Int ?? 20
    let results = await worktreeDelegate.gateAgentHistory(limit: limit)
    let iso = ISO8601DateFormatter()
    let items: [[String: Any]] = results.map { r in
      ["branchName": r.branchName, "outcome": r.outcome, "timestamp": iso.string(from: r.timestamp), "reasons": r.reasons]
    }
    return (200, makeResult(id: id, result: ["results": items, "count": items.count]))
  }

  private func notConfiguredError(id: Any?) -> (Int, Data) {
    (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Worktree delegate not configured"))
  }
}

