//
//  GitToolsHandler.swift
//  Peel
//
//  MCP tool handler for native git operations (Issue #290 — avoid shell escaping).
//  All arguments are passed directly to Process as an array, bypassing the shell.
//  Commit messages and other user content are never shell-interpreted.
//

import Foundation
import MCPCore
#if os(macOS)
import Git
#endif

// MARK: - GitToolsHandler

/// Handles git.* MCP tools using the Git package's Process-based executor.
/// Because arguments flow as [String] → Process, the shell is never involved
/// and commit messages containing quotes, backticks, or special characters
/// work without any escaping.
@MainActor
final class GitToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?

  let supportedTools: Set<String> = [
    "git.status",
    "git.add",
    "git.commit",
    "git.push",
    "git.log",
  ]

  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "git.status":  return await handleStatus(id: id, arguments: arguments)
    case "git.add":     return await handleAdd(id: id, arguments: arguments)
    case "git.commit":  return await handleCommit(id: id, arguments: arguments)
    case "git.push":    return await handlePush(id: id, arguments: arguments)
    case "git.log":     return await handleLog(id: id, arguments: arguments)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
                             message: "Unknown git tool: \(name)"))
    }
  }

  // MARK: - Private helpers

#if os(macOS)
  /// Build a Git.Model.Repository from the required `path` argument.
  private func repoFromArguments(_ arguments: [String: Any], id: Any?) -> Result<Git.Model.Repository, ParamError> {
    switch requireString("path", from: arguments, id: id) {
    case .failure(let err): return .failure(err)
    case .success(let path):
      let name = (path as NSString).lastPathComponent
      return .success(Git.Model.Repository(name: name, path: path))
    }
  }
#endif

  // MARK: - git.status

  private func handleStatus(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
#if os(macOS)
    switch repoFromArguments(arguments, id: id) {
    case .failure(let err): return err.response
    case .success(let repo):
      let short = optionalBool("short", from: arguments, default: true)
      let args: [String] = short ? ["status", "--short"] : ["status"]
      do {
        let lines = try await Git.Commands.simple(arguments: args, in: repo)
        return (200, makeResult(id: id, result: [
          "output": lines.joined(separator: "\n"),
          "lines": lines,
          "clean": lines.isEmpty
        ]))
      } catch {
        return internalError(id: id, message: "git status failed: \(error.localizedDescription)")
      }
    }
#else
    return internalError(id: id, message: "git.status is only supported on macOS")
#endif
  }

  // MARK: - git.add

  private func handleAdd(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
#if os(macOS)
    switch repoFromArguments(arguments, id: id) {
    case .failure(let err): return err.response
    case .success(let repo):
      let files: [String] = (arguments["files"] as? [String]) ?? ["."]
      do {
        let lines = try await Git.Commands.simple(arguments: ["add"] + files, in: repo)
        return (200, makeResult(id: id, result: [
          "output": lines.joined(separator: "\n"),
          "staged": files
        ]))
      } catch {
        return internalError(id: id, message: "git add failed: \(error.localizedDescription)")
      }
    }
#else
    return internalError(id: id, message: "git.add is only supported on macOS")
#endif
  }

  // MARK: - git.commit

  private func handleCommit(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
#if os(macOS)
    switch repoFromArguments(arguments, id: id) {
    case .failure(let err): return err.response
    case .success(let repo):
      switch requireString("message", from: arguments, id: id) {
      case .failure(let err): return err.response
      case .success(let message):
        let addAll = optionalBool("addAll", from: arguments, default: false)
        // Build the argument list — message is a plain Swift String passed directly
        // to Process, so quotes/backticks/dollar signs are never shell-interpreted.
        var args = ["commit"]
        if addAll { args.append("-a") }
        args += ["-m", message]
        do {
          let lines = try await Git.Commands.simple(arguments: args, in: repo)
          return (200, makeResult(id: id, result: [
            "output": lines.joined(separator: "\n"),
            "message": message
          ]))
        } catch {
          return internalError(id: id, message: "git commit failed: \(error.localizedDescription)")
        }
      }
    }
#else
    return internalError(id: id, message: "git.commit is only supported on macOS")
#endif
  }

  // MARK: - git.push

  private func handlePush(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
#if os(macOS)
    switch repoFromArguments(arguments, id: id) {
    case .failure(let err): return err.response
    case .success(let repo):
      let remote = optionalString("remote", from: arguments, default: "origin") ?? "origin"
      let branch = optionalString("branch", from: arguments)
      var args = ["push", remote]
      if let branch { args.append(branch) }
      do {
        let lines = try await Git.Commands.simple(arguments: args, in: repo)
        return (200, makeResult(id: id, result: [
          "output": lines.joined(separator: "\n"),
          "remote": remote
        ]))
      } catch {
        return internalError(id: id, message: "git push failed: \(error.localizedDescription)")
      }
    }
#else
    return internalError(id: id, message: "git.push is only supported on macOS")
#endif
  }

  // MARK: - git.log

  private func handleLog(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
#if os(macOS)
    switch repoFromArguments(arguments, id: id) {
    case .failure(let err): return err.response
    case .success(let repo):
      let limit = optionalInt("limit", from: arguments, default: 10) ?? 10
      let format = optionalString("format", from: arguments, default: "oneline") ?? "oneline"
      let args = ["log", "--\(format)", "-n", "\(limit)"]
      do {
        let lines = try await Git.Commands.simple(arguments: args, in: repo)
        return (200, makeResult(id: id, result: [
          "output": lines.joined(separator: "\n"),
          "lines": lines,
          "limit": limit
        ]))
      } catch {
        return internalError(id: id, message: "git log failed: \(error.localizedDescription)")
      }
    }
#else
    return internalError(id: id, message: "git.log is only supported on macOS")
#endif
  }
}

// MARK: - Tool Definitions

extension GitToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "git.status",
        description: "Show git working tree status. Returns clean/dirty indicator plus the status lines.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "short": ["type": "boolean", "description": "Use --short format (default: true)"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "git.add",
        description: "Stage files for commit. Defaults to staging everything ('.'). Pass a 'files' array to stage specific paths.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "files": ["type": "array", "items": ["type": "string"], "description": "Paths to stage (default: [\".\"])"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "git.commit",
        description: """
          Create a git commit. The message is passed directly to the git Process argument list — \
          no shell involved, so quotes, backticks, and special characters never need escaping.
          Set addAll=true to automatically stage all tracked-file changes before committing.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "message": ["type": "string", "description": "Commit message (no escaping needed)"],
            "addAll": ["type": "boolean", "description": "Stage all tracked changes first (-a flag, default: false)"]
          ],
          "required": ["path", "message"]
        ],
        category: .terminal,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "git.push",
        description: "Push commits to a remote. Defaults to 'origin'. Omit 'branch' to push the current branch.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "remote": ["type": "string", "description": "Remote name (default: 'origin')"],
            "branch": ["type": "string", "description": "Branch name (default: current branch)"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "git.log",
        description: "Show recent commit history.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "limit": ["type": "integer", "description": "Number of commits (default: 10)"],
            "format": ["type": "string", "description": "Log format: 'oneline', 'short', 'medium' (default: 'oneline')"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: false
      ),
    ]
  }
}
