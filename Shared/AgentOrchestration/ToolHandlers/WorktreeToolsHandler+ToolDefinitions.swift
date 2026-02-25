//
//  WorktreeToolsHandler+ToolDefinitions.swift
//  Peel
//

import Foundation
import MCPCore

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
      MCPToolDefinition(
        name: "worktree.pool.status",
        description: "Returns current WorktreePool status: pool size, number of warm (pre-created) worktrees, claimed worktrees, base branch, and recycle policy.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .worktrees,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "worktree.pool.configure",
        description: "Configure the WorktreePool: set target pool size, base branch for new worktrees, or recycle policy (always/on-success/never).",
        inputSchema: [
          "type": "object",
          "properties": [
            "size": [
              "type": "integer",
              "description": "Target number of warm worktrees in the pool"
            ],
            "baseBranch": [
              "type": "string",
              "description": "Base branch for pre-warmed worktrees (e.g. origin/main)"
            ],
            "recyclePolicy": [
              "type": "string",
              "enum": ["always", "on-success", "never"],
              "description": "When to recycle a claimed worktree back to the pool"
            ]
          ],
          "required": []
        ],
        category: .worktrees,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "gate.status",
        description: "Returns GateAgent status: whether validation is active, pending validation count, and cumulative pass/fail/retry counts.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .worktrees,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "gate.history",
        description: "Returns recent GateAgent validation results. Each result includes branch name, outcome (pass/fail/retry), ISO8601 timestamp, and failure reasons.",
        inputSchema: [
          "type": "object",
          "properties": [
            "limit": [
              "type": "integer",
              "description": "Max number of results to return (default: 20)"
            ]
          ],
          "required": []
        ],
        category: .worktrees,
        isMutating: false
      ),
    ]
  }
}
