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
}

// MARK: - Worktree Tool Types

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
    "worktree.create"
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
}

// MARK: - Tool Definitions

extension WorktreeToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "worktree.list",
        description: "List all git worktrees across registered repositories and the peel-worktrees directory. Returns path, branch, disk size, and status for each worktree.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Optional: Filter to worktrees for a specific repository path"
            ],
            "includeMain": [
              "type": "boolean",
              "description": "Include main worktrees (the original repo checkouts). Default: false"
            ]
          ],
          "required": []
        ],
        category: .worktrees,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "worktree.remove",
        description: "Remove a git worktree by path. Use force=true if the worktree has uncommitted changes.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": [
              "type": "string",
              "description": "The absolute path to the worktree to remove"
            ],
            "force": [
              "type": "boolean",
              "description": "Force removal even if worktree is dirty. Default: false"
            ]
          ],
          "required": ["path"]
        ],
        category: .worktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "worktree.stats",
        description: "Get aggregate statistics about all worktrees: total count, disk usage, prunable count, grouped by repository.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .worktrees,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "worktree.create",
        description: "Create a new git worktree for ad-hoc work, PR review, or experiments. The worktree will be created in ~/peel-worktrees/ with the specified branch.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Path to the git repository"
            ],
            "branchName": [
              "type": "string",
              "description": "Name for the new branch (will be sanitized)"
            ],
            "baseBranch": [
              "type": "string",
              "description": "Base branch to create from (default: origin/main)"
            ]
          ],
          "required": ["repoPath", "branchName"]
        ],
        category: .worktrees,
        isMutating: true
      ),
    ]
  }
}
