---
status: in-progress
created: 2026-01-05
updated: 2026-01-07
priority: high
tags:
  - tooling
  - ai-agents
  - developer-experience
  - architecture
estimated-effort: 3 weeks
---

# AI Agent Orchestration Integration Plan

## Overview

Evolve Kitchen Sync into an AI Agent Orchestration app for managing multiple AI coding agents with isolated workspaces.

---

## Progress Summary

### ✅ Completed Prerequisites
- [x] Git worktree commands (list, add, remove, prune)
- [x] Worktree UI in Git sidebar
- [x] VS Code integration (open worktrees)
- [x] PR → Worktree flow (Review Locally)
- [x] SwiftData persistence with iCloud sync
- [x] Package consolidation (CrunchyCommon deleted, GithubUI merged)
- [x] OAuth credentials in Keychain

### 🟡 In Progress
- [ ] AgentOrchestrator package (Phase 3)

### 📋 Remaining Work
- Phase 3: Agent Framework
- Phase 4: VS Code isolated instances
- Phase 5: Agent Dashboard UI
- Phase 6: Supervisor pattern (optional)

---

## Phase 1: Stabilize & Simplify ✅ COMPLETE

All items completed in previous sessions.

---

## Phase 2: Git Worktree Foundation ✅ COMPLETE

Implemented in `Local Packages/Git/Sources/Git/Commands/Worktree.swift`:
- `Commands.Worktree.list(on:)` 
- `Commands.Worktree.add(path:branch:on:)`
- `Commands.Worktree.addWithNewBranch(path:newBranch:startPoint:on:)`
- `Commands.Worktree.remove(path:force:on:)`
- `Commands.Worktree.lock/unlock/prune`

UI in `WorktreeListView.swift` and `CreateWorktreeView.swift`.

---

## Phase 3: Agent Framework 🟡 NEXT

### 3.1 Create AgentOrchestrator Package

```
Local Packages/AgentOrchestrator/
├── Package.swift
└── Sources/AgentOrchestrator/
    ├── Models/
    │   ├── Agent.swift
    │   ├── AgentTask.swift
    │   └── AgentWorkspace.swift
    ├── Services/
    │   ├── AgentManager.swift
    │   ├── WorkspaceManager.swift
    │   └── CLIBridge.swift
    └── Views/
        └── (later)
```

### 3.2 Core Types

```swift
public enum AgentType {
  case claude      // Claude CLI
  case copilot     // GitHub Copilot CLI
  case cursor      // Cursor AI
  case custom(command: String)
}

public enum AgentState {
  case idle
  case planning
  case working
  case blocked(reason: String)
  case testing
  case complete
  case failed(Error)
}

public struct Agent: Identifiable {
  public let id: UUID
  public let name: String
  public let type: AgentType
  public var state: AgentState
  public var workspace: AgentWorkspace?
  public var task: AgentTask?
}

public struct AgentWorkspace: Identifiable {
  public let id: UUID
  public let worktreePath: String
  public let repositoryPath: String
  public let branch: String
  public let createdAt: Date
  public var agentId: UUID?
}

public struct AgentTask: Identifiable {
  public let id: UUID
  public let description: String
  public let prompt: String
  public var status: TaskStatus
  public var createdAt: Date
  public var completedAt: Date?
}
```

### 3.3 Workspace Manager

```swift
@MainActor
@Observable
public final class WorkspaceManager {
  private let gitRepository: Model.Repository
  
  /// Creates an isolated workspace for an agent
  public func createWorkspace(
    for task: AgentTask,
    baseBranch: String = "main"
  ) async throws -> AgentWorkspace
  
  /// Lists all agent workspaces
  public func listWorkspaces() async throws -> [AgentWorkspace]
  
  /// Cleans up a workspace
  public func removeWorkspace(_ workspace: AgentWorkspace) async throws
}
```

### 3.4 CLI Bridge

```swift
public protocol CLIAgent {
  var name: String { get }
  var executablePath: String { get }
  func isInstalled() async -> Bool
  func launch(in workspace: URL, prompt: String) async throws -> Process
}

public struct ClaudeCLI: CLIAgent {
  public let name = "Claude"
  public let executablePath = "/usr/local/bin/claude"
  // ...
}

public struct CopilotCLI: CLIAgent {
  public let name = "GitHub Copilot"
  public let executablePath = "/usr/local/bin/gh"
  // Uses: gh copilot suggest
}
```

---

## Phase 4: VS Code Isolated Instances

Each agent gets its own VS Code instance with isolated settings:

```swift
public struct VSCodeIsolatedLauncher {
  /// Opens VS Code with isolated user data for this agent
  public func launch(
    workspace: AgentWorkspace,
    agentId: UUID
  ) async throws {
    // code -n \
    //   --user-data-dir ~/.kitchen-sync/agents/{agentId}/vscode \
    //   --extensions-dir ~/.kitchen-sync/agents/{agentId}/extensions \
    //   {workspace.worktreePath}
  }
}
```

---

## Phase 5: Agent Dashboard UI

### Navigation Addition
```swift
enum CurrentTool: String {
  case agents = "agents"  // NEW - Primary feature
  case github = "github"
  case git = "git"
  case brew = "brew"
}
```

### Agent Dashboard
- Grid of active agents with state indicators
- Create new agent workflow
- Agent detail view with output log
- Workspace browser

---

## Phase 6: Supervisor Pattern (Future)

Multi-agent coordination with message passing. Defer until single-agent works well.

---

## Implementation Order

1. **Create AgentOrchestrator package** with basic models
2. **WorkspaceManager** using existing Git.Worktree commands
3. **CLIBridge** with Claude CLI support
4. **AgentManager** to tie it together
5. **Basic UI** - agent list, create agent, view status
6. **VS Code isolated launch**
7. **Polish and iterate**

---

## Technical Notes

### Claude CLI
```bash
# Check if installed
which claude

# Run in directory with prompt
cd /path/to/worktree && claude "Implement feature X"

# Or with workspace flag if supported
claude --workspace /path/to/worktree "Implement feature X"
```

### Isolated VS Code
```bash
code -n \
  --user-data-dir ~/.kitchen-sync/agents/abc123/vscode \
  --extensions-dir ~/.kitchen-sync/agents/abc123/extensions \
  /path/to/worktree
```

### Agent Workspace Naming
```
~/code/myproject/                    # Main repo
~/code/myproject-agent-abc123/       # Agent worktree
~/code/myproject-agent-def456/       # Another agent worktree
```

---

**Last Updated:** January 7, 2026
