---
status: in-progress
created: 2026-01-05
updated: 2026-01-05
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

This document outlines how to evolve KitchenSink (now "Kitchen Sync") into an AI Agent Orchestration app for managing multiple AI coding agents with isolated workspaces.

---

## Phase 1: Stabilize & Simplify (Week 1)

### 1.1 Fix Immediate Issues ✅ COMPLETED
- [x] Fix GitHub OAuth error handling
- [x] Add network entitlement for macOS
- [x] **Updated GitHub OAuth credentials** - Client ID: Ov23liMnGh1bRfKc0qpU, updated secret
- [x] **Fixed OAuth callback URL** - Changed to `crunchy-kitchen-sink://oauth-callback`
- [x] **Fixed macOS URL scheme handling** - Removed conflicting `/Applications/KitchenSync.app`
- [x] **Fixed iOS build issues** - Made TaskRunner macOS-only (uses Process API)
- [x] **Fixed Git package** - Conditionally includes TaskRunner only on macOS
- [x] **OAuth working on both iOS and macOS** ✅
- [ ] Add proper error UI (alerts/toasts) instead of just console logging
- [ ] Move OAuth credentials out of source code (to Keychain or environment)

**Key Learnings:**
- macOS 26 (Tahoe) requires apps handling URL schemes to be registered with Launch Services
- Conflicting app bundles in /Applications can steal URL callbacks
- For development: Run from Xcode works fine once conflicting apps are removed
- iOS OAuth worked immediately; macOS issue was environment-specific, not code

### 1.2 Modernize SwiftUI UX (NEW - See SWIFTUI_MODERNIZATION_PLAN.md)
- [ ] Audit current UI built on macOS 13 / SwiftUI 3.0
- [ ] Update to modern SwiftUI patterns (macOS 14+ / SwiftUI 5.0+)
- [ ] Leverage new SwiftUI features for better macOS/iOS parity
- [ ] See detailed UX modernization plan in separate document

### 1.2 Consolidate Package Structure

**Current (Over-engineered):**
```
Local Packages/
├── Brew/          # Homebrew UI (macOS only)
├── CrunchyCommon/ # Shared utilities
├── Git/           # Local git operations
├── Github/        # GitHub API + Models + Some Views
└── GithubUI/      # More GitHub Views (confusing split)
```

**Proposed (Simplified):**
```
Local Packages/
├── Core/              # Shared utilities, extensions, base components
├── GitOperations/     # Local git + git worktree management (key for agent isolation)
├── GitHub/            # GitHub API, Models, ALL GitHub views
└── AgentOrchestrator/ # NEW: Agent management, workspaces, messaging
```

### 1.3 Remove Unused Code
- [ ] Empty `PersonalView.swift`
- [ ] Commented-out `RootView` in `Github.swift`
- [ ] Consolidate dual `@AppStorage("github-token")` usage

---

## Phase 2: Git Worktree Foundation (Week 1-2)

### 2.1 Extend Git Package for Worktrees

The existing `Git` package already uses `TaskRunner` for shell commands. Extend it:

```swift
// GitOperations/Sources/GitOperations/Worktree.swift
public struct Worktree {
    public let path: URL
    public let branch: String
    public let head: String
    public let isLocked: Bool
    
    public static func list(in repository: URL) async throws -> [Worktree]
    public static func add(in repository: URL, path: URL, branch: String) async throws -> Worktree
    public static func remove(worktree: Worktree) async throws
    public static func prune(in repository: URL) async throws
}
```

### 2.2 Create Workspace Manager

```swift
// AgentOrchestrator/Sources/AgentOrchestrator/WorkspaceManager.swift
public class WorkspaceManager: ObservableObject {
    @Published var workspaces: [AgentWorkspace] = []
    
    /// Creates an isolated workspace for an agent using git worktree
    public func createWorkspace(
        repository: URL,
        taskName: String,
        agentId: UUID
    ) async throws -> AgentWorkspace
    
    /// Cleans up completed agent workspaces
    public func cleanupWorkspace(_ workspace: AgentWorkspace) async throws
}
```

---

## Phase 3: Agent Framework (Week 2)

### 3.1 Core Agent Types

```swift
// AgentOrchestrator/Sources/AgentOrchestrator/Models/Agent.swift
public enum AgentType {
    case claude      // claude-cli
    case copilot     // GitHub Copilot CLI
    case custom(String)
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
    public var currentTask: AgentTask?
    public var workspace: AgentWorkspace?
}
```

### 3.2 Agent Lifecycle Manager

```swift
// AgentOrchestrator/Sources/AgentOrchestrator/AgentManager.swift
public class AgentManager: ObservableObject {
    @Published var agents: [Agent] = []
    
    /// Spawns a new agent with an isolated workspace
    public func spawnAgent(
        type: AgentType,
        task: AgentTask,
        repository: URL
    ) async throws -> Agent
    
    /// Monitors agent output and state changes
    public func monitor(_ agent: Agent) -> AsyncStream<AgentEvent>
    
    /// Terminates an agent and cleans up its workspace
    public func terminate(_ agent: Agent) async throws
}
```

### 3.3 CLI Integration

```swift
// AgentOrchestrator/Sources/AgentOrchestrator/CLIBridge.swift
public protocol CLIAgent {
    var executablePath: String { get }
    func launch(in workspace: URL, with prompt: String) async throws -> Process
    func sendInput(_ input: String) async throws
    func terminate() async throws
}

public class ClaudeCLI: CLIAgent {
    public func launch(in workspace: URL, with prompt: String) async throws -> Process {
        // Launch: claude --workspace \(workspace.path) --prompt "\(prompt)"
    }
}

public class CopilotCLI: CLIAgent {
    public func launch(in workspace: URL, with prompt: String) async throws -> Process {
        // Launch: gh copilot suggest "\(prompt)" in workspace
    }
}
```

---

## Phase 4: VS Code Integration (Week 2-3)

### 4.1 VS Code Controller

```swift
// AgentOrchestrator/Sources/AgentOrchestrator/VSCodeController.swift
public class VSCodeController {
    /// Opens a workspace in a new isolated VS Code window
    public func openWorkspace(
        _ workspace: AgentWorkspace,
        agentId: UUID
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/code")
        process.arguments = [
            "-n",  // New window
            "--user-data-dir", "~/.vscode-agent-\(agentId.uuidString)",
            workspace.path.path
        ]
        try process.run()
    }
    
    /// Gets list of open VS Code windows
    public func listWindows() async throws -> [VSCodeWindow]
}
```

### 4.2 Monaco Editor Embedding (Optional Dashboard)

For a lightweight code preview in the native app:

```swift
// AgentOrchestrator/Sources/AgentOrchestrator/Views/MonacoEditorView.swift
import WebKit

struct MonacoEditorView: NSViewRepresentable {
    @Binding var content: String
    let language: String
    let readOnly: Bool
    
    func makeNSView(context: Context) -> WKWebView {
        // Load Monaco from bundle or CDN
    }
}
```

---

## Phase 5: UI Integration (Week 3)

### 5.1 New Navigation Structure

```swift
// Shared/ContentView.swift (updated)
enum CurrentTool: String, CaseIterable {
    case agents = "agents"    // NEW: Primary feature
    case brew = "brew"
    case git = "git"
    case github = "github"
}
```

### 5.2 Agent Dashboard View

```swift
// Shared/Applications/Agents_RootView.swift
struct Agents_RootView: View {
    @StateObject var agentManager = AgentManager()
    @StateObject var workspaceManager = WorkspaceManager()
    
    var body: some View {
        NavigationSplitView {
            // Sidebar: List of workspaces and agents
            AgentsSidebarView()
        } content: {
            // Agent grid showing all active agents
            AgentsGridView()
        } detail: {
            // Selected agent detail with Monaco preview
            AgentDetailView()
        }
    }
}
```

### 5.3 Agent Grid View

```swift
struct AgentsGridView: View {
    @EnvironmentObject var agentManager: AgentManager
    
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))]) {
            ForEach(agentManager.agents) { agent in
                AgentCardView(agent: agent)
            }
        }
    }
}

struct AgentCardView: View {
    let agent: Agent
    
    var body: some View {
        VStack {
            HStack {
                AgentStateIndicator(state: agent.state)
                Text(agent.name)
                Spacer()
                Menu { /* actions */ } label: { Image(systemName: "ellipsis") }
            }
            
            if let task = agent.currentTask {
                Text(task.description)
                    .font(.caption)
            }
            
            // Mini Monaco preview of current file
            if let workspace = agent.workspace {
                MonacoEditorView(
                    content: .constant(workspace.currentFileContent),
                    language: "swift",
                    readOnly: true
                )
                .frame(height: 200)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
    }
}
```

---

## Phase 6: Supervisor Agent Pattern (Week 3+)

### 6.1 Message Bus

```swift
// AgentOrchestrator/Sources/AgentOrchestrator/MessageBus.swift
public enum AgentMessage {
    case taskAssignment(AgentTask)
    case statusUpdate(AgentState)
    case question(String)
    case result(Any)
    case error(Error)
}

public class AgentMessageBus: ObservableObject {
    @Published var messages: [AgentMessage] = []
    
    public func publish(_ message: AgentMessage, from: UUID, to: UUID?)
    public func subscribe(_ agentId: UUID) -> AsyncStream<AgentMessage>
}
```

### 6.2 Supervisor Agent

```swift
public class SupervisorAgent: ObservableObject {
    @Published var workers: [Agent] = []
    let messageBus: AgentMessageBus
    
    /// Assigns a task to the best available worker
    public func assignTask(_ task: AgentTask) async throws
    
    /// Handles blocked worker - can spawn helper or escalate
    public func handleBlockedWorker(_ worker: Agent) async throws
    
    /// Coordinates multi-agent workflows
    public func orchestrate(_ workflow: AgentWorkflow) async throws
}
```

---

## File Structure After Integration

```
KitchenSink/
├── KitchenSync.entitlements
├── iOS/
├── macOS/
├── Shared/
│   ├── KitchenSyncApp.swift
│   ├── CommonToolbarItems.swift
│   ├── Applications/
│   │   ├── Agents_RootView.swift      # NEW
│   │   ├── Brew_RootView.swift
│   │   ├── Git_RootView.swift
│   │   └── Github_RootView.swift
│   └── Views/
│       ├── AgentCardView.swift         # NEW
│       ├── AgentsGridView.swift        # NEW
│       ├── AgentsSidebarView.swift     # NEW
│       ├── MonacoEditorView.swift      # NEW
│       └── SettingsView.swift
└── Local Packages/
    ├── Core/                           # Renamed from CrunchyCommon
    ├── GitOperations/                  # Extended Git package
    │   └── Sources/
    │       └── GitOperations/
    │           ├── Git.swift
    │           ├── Worktree.swift      # NEW
    │           └── ...
    ├── GitHub/                         # Merged Github + GithubUI
    └── AgentOrchestrator/              # NEW PACKAGE
        ├── Package.swift
        └── Sources/
            └── AgentOrchestrator/
                ├── AgentManager.swift
                ├── AgentMessageBus.swift
                ├── CLIBridge.swift
                ├── SupervisorAgent.swift
                ├── VSCodeController.swift
                ├── WorkspaceManager.swift
                ├── Models/
                │   ├── Agent.swift
                │   ├── AgentTask.swift
                │   └── AgentWorkspace.swift
                └── Views/
                    └── MonacoEditorView.swift
```

---

## Next Steps

1. **Test GitHub Login** - Run the app and verify OAuth works after the fixes
2. **Regenerate OAuth credentials if needed** - Check https://github.com/settings/developers
3. **Start Phase 1** - Consolidate packages, remove dead code
4. **Implement Worktree support** - Core foundation for agent isolation

---

## Technical Notes

### Git Worktree Commands Reference
```bash
# List worktrees
git worktree list

# Add new worktree
git worktree add ../agent-workspace-1 -b agent/task-123

# Remove worktree
git worktree remove ../agent-workspace-1

# Prune stale worktrees
git worktree prune
```

### VS Code Isolated Window
```bash
# Open workspace in isolated VS Code instance
code -n \
  --user-data-dir ~/.vscode-agent-1 \
  --extensions-dir ~/.vscode-agent-1/extensions \
  /path/to/worktree
```

### Claude CLI (example)
```bash
# Run claude in a specific directory
cd /path/to/worktree && claude "Implement feature X"
```
