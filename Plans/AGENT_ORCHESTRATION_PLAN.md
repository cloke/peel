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
- [ ] AgentOrchestration folder in Shared (Phase 3)

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

### 3.1 Create AgentOrchestration in Shared (NOT a package)

Keep it in the main app since it's tightly coupled to SwiftData, Git, and GitHub:

```
Shared/
├── AgentOrchestration/
│   ├── Models/
│   │   ├── Agent.swift
│   │   ├── AgentTask.swift
│   │   └── AgentWorkspace.swift
│   ├── Services/
│   │   ├── AgentManager.swift
│   │   ├── WorkspaceManager.swift
│   │   └── CLIBridge.swift
│   └── Views/
│       ├── AgentDashboardView.swift
│       └── AgentCardView.swift
```

**Why not a package:**
- Tightly coupled to SwiftData models in main app
- Uses Git package + GitHub package + VS Code service
- Not reusable in other apps without heavy modification
- Avoid package overhead - we just consolidated from 5 → 3

### 3.2 Core Models

```swift
// Shared/AgentOrchestration/Models/Agent.swift

public enum AgentType: String, Codable {
  case claude      // Claude CLI
  case copilot     // GitHub Copilot CLI  
  case cursor      // Cursor AI
  case custom      // Custom command
}

public enum AgentState: Equatable {
  case idle
  case planning
  case working
  case blocked(reason: String)
  case complete
  case failed(String)
}

@MainActor
@Observable
public final class Agent: Identifiable {
  public let id: UUID
  public var name: String
  public let type: AgentType
  public var state: AgentState = .idle
  public var workspace: AgentWorkspace?
  public var task: AgentTask?
  public let createdAt: Date
  
  public init(name: String, type: AgentType) {
    self.id = UUID()
    self.name = name
    self.type = type
    self.createdAt = Date()
  }
}
```

```swift
// Shared/AgentOrchestration/Models/AgentWorkspace.swift

public struct AgentWorkspace: Identifiable, Equatable {
  public let id: UUID
  public let worktreePath: String
  public let repositoryPath: String
  public let branch: String
  public let createdAt: Date
  public var agentId: UUID?
  
  public init(worktreePath: String, repositoryPath: String, branch: String) {
    self.id = UUID()
    self.worktreePath = worktreePath
    self.repositoryPath = repositoryPath
    self.branch = branch
    self.createdAt = Date()
  }
}
```

```swift
// Shared/AgentOrchestration/Models/AgentTask.swift

public enum TaskStatus: String, Codable {
  case pending
  case inProgress
  case complete
  case failed
}

public struct AgentTask: Identifiable {
  public let id: UUID
  public var title: String
  public var prompt: String
  public var status: TaskStatus = .pending
  public let createdAt: Date
  public var completedAt: Date?
  
  public init(title: String, prompt: String) {
    self.id = UUID()
    self.title = title
    self.prompt = prompt
    self.createdAt = Date()
  }
}
```

### 3.3 Workspace Manager

Uses existing Git.Worktree commands:

```swift
// Shared/AgentOrchestration/Services/WorkspaceManager.swift

@MainActor
@Observable
public final class WorkspaceManager {
  private var workspaces: [AgentWorkspace] = []
  
  /// Creates an isolated worktree for an agent
  public func createWorkspace(
    for repository: Git.Model.Repository,
    taskName: String,
    baseBranch: String = "main"
  ) async throws -> AgentWorkspace {
    let branchName = "agent/\(taskName.slugified)-\(UUID().uuidString.prefix(8))"
    let worktreePath = // sibling to repo
    
    try await Commands.Worktree.addWithNewBranch(
      path: worktreePath,
      newBranch: branchName,
      startPoint: baseBranch,
      on: repository
    )
    
    let workspace = AgentWorkspace(
      worktreePath: worktreePath,
      repositoryPath: repository.path,
      branch: branchName
    )
    workspaces.append(workspace)
    return workspace
  }
  
  /// Removes a workspace and its worktree
  public func removeWorkspace(_ workspace: AgentWorkspace) async throws {
    // Use Commands.Worktree.remove
  }
}
```

### 3.4 CLI Bridge

```swift
// Shared/AgentOrchestration/Services/CLIBridge.swift

public protocol CLIAgentProtocol {
  var name: String { get }
  var command: String { get }
  func isInstalled() async -> Bool
  func launch(in workspacePath: String, prompt: String) async throws -> Process
}

public struct ClaudeCLI: CLIAgentProtocol {
  public let name = "Claude"
  public let command = "claude"
  
  public func isInstalled() async -> Bool {
    FileManager.default.fileExists(atPath: "/usr/local/bin/claude") ||
    FileManager.default.fileExists(atPath: "/opt/homebrew/bin/claude")
  }
  
  public func launch(in workspacePath: String, prompt: String) async throws -> Process {
    let process = Process()
    process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
    process.arguments = [prompt]
    try process.run()
    return process
  }
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

1. **Create AgentOrchestration folder in Shared** with basic models
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
