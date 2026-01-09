# Agent Orchestration - Session Summary (Jan 7-8, 2026)

## Session Jan 8: Complete! ✅

### 1. CLI Detection Fix ✅
**Problem:** App bundles don't inherit shell PATH, so `which gh` failed.

**Fix:** Added `findExecutable()` helper that checks common paths directly:
- `/opt/homebrew/bin/` (Apple Silicon Homebrew)
- `/usr/local/bin/` (Intel Homebrew)  
- `/usr/bin/` and `/bin/`

### 2. Migrated to New Copilot CLI ✅
**Discovery:** The old `gh-copilot` extension has been deprecated!

**Migration:**
- Old: `gh extension install github/gh-copilot` → `gh copilot suggest`
- New: `brew install copilot-cli` → `copilot -p "prompt"`

**Updated CLIService to:**
- Install via `brew install copilot-cli`
- Auth via `copilot` (interactive first-run)
- Run via `copilot -p "prompt" --allow-all-tools` (non-interactive)

### 3. Authentication Fix ✅
**Problem:** Copilot CLI couldn't find auth when launched from app bundle.

**Fix:** Get token from `gh auth token` and pass as `GH_TOKEN` environment variable.

### 4. Model Info Display ✅
**Problem:** Stats weren't showing - content goes to stdout but stats go to stderr!

**Fix:** Combine stdout + stderr before parsing:
```swift
let combinedOutput = result.stdoutString + "\n" + result.stderrString
return parseCopilotOutput(combinedOutput)
```

**Now displays:**
- Model name (e.g., `claude-sonnet-4.5`)
- Duration
- Token usage (input/output)
- Premium requests count

### 5. Async Execution Fix ✅
**Problem:** Beach ball and ViewBridge crash when running copilot.

**Fix:** Use `Task.detached(priority: .userInitiated)` instead of `DispatchQueue` for proper Swift concurrency off the main actor.

### 6. Model Selection ✅
- Added `CopilotModel` enum with all available models
- Model picker in AgentDetailView and NewAgentSheet
- Shows premium cost per model (e.g., Opus = 3×, others = 1×)
- Pass `--model <selected>` to copilot CLI

### 7. UX Improvements ✅
- CLI Status rows in sidebar are now clickable (opens setup sheet)
- Simplified setup wizard (2 steps instead of 3)
- Progress indicator while running
- Model shown in sidebar and agent header

---

## Commits
- `b5f7b74` - Initial agent orchestration with Copilot CLI
- `19e0884` - Update session notes

---

## Next Steps (Priority Order)

### 1. Multi-Agent Coordination 🎯 (Next)
Allow two agents to work on related tasks:
- Agent A: Research/planning (e.g., Opus for complex reasoning)
- Agent B: Implementation (e.g., Codex for code generation)
- Pass output from Agent A as context to Agent B
- Sequential execution with shared context
- **Requires:** Working directory support first

### 2. Working Directory Context (Required for Multi-Agent)
Run copilot in a specific repo directory for better context:
- Add `workingDirectory` property to Agent
- Select repository/folder from UI
- Pass `workingDirectory` to `runCopilotSession`
- Agent understands project structure and can run tools

### 3. Session Cost Tracking (Future Enhancement) 💰
Track total premium requests used across a session:
- Add `totalPremiumUsed: Int` to AgentManager or a new SessionTracker
- Accumulate costs from each `CopilotResponse.premiumRequests`
- Display running total in UI (e.g., "Session: 7 Premium used")
- Optional: Show breakdown by model

### 4. Streaming Output (Nice to Have)
Show response as it generates instead of waiting:
- Use `AsyncStream` to yield lines as they arrive
- Update UI progressively

### 5. Git Worktree Integration (Complex)
Create isolated branches for agent work:
- `WorkspaceManager.createWorkspace()` creates worktree
- Agent works in isolated branch
- Review changes before merge

---

## How to Test

1. **Open the app** - Go to Agents tab (robot icon in toolbar)
2. **Check CLI Status** - Sidebar should show "Copilot - Ready" (green)
3. **Select an agent** - Click "Copilot Helper" in sidebar
4. **Assign a task:**
   - Click "Assign Task" button
   - Title: "Test prompt"
   - Prompt: "What is 2+2?"
   - Click "Assign"
5. **Run the task** - Click "Run with Copilot" button
6. **See output** - Response + model info pill appears

---

## Current State

**Working:**
- ✅ Copilot CLI detection (`copilot --version`)
- ✅ Copilot CLI authentication (via device flow)
- ✅ Non-interactive prompt execution (`copilot -p "..." -s --allow-all-tools`)
- ✅ Task assignment UI
- ✅ Run button with output display
- ✅ CLI setup wizard

**Not Yet Implemented:**
- ❌ Claude CLI integration (need to test `claude` command)
- ❌ Working directory context (run in repo folder)
- ❌ Streaming output (currently waits for full response)
- ❌ Git worktree integration for isolated workspaces
- ❌ Multiple concurrent agents

---

## Files Modified Today

1. `Shared/AgentOrchestration/CLIService.swift`
   - Added `findExecutable()` for PATH-independent executable lookup
   - Migrated from `gh copilot` to new `copilot-cli`
   - Added `runCopilotSession()` and `runClaudeSession()`
   - Simplified installation flow (2 steps)

2. `Shared/Applications/Agents_RootView.swift`
   - Added Run button and output display to AgentDetailView
   - Made CLI Status rows clickable
   - Updated CopilotInstallSteps for new CLI

---

## Session Jan 7: Initial Setup

### 1. Basic Agents UI Created ✅
- Created `Agents_RootView.swift` with:
  - NavigationSplitView with sidebar showing agents
  - Agent detail view with task assignment
  - Sample agents (Claude Assistant, Copilot Helper, Feature Builder)
  - Tool switcher integration (Agents tab in toolbar)

### 2. CLI Detection Service Created ✅
- Created `CLIService.swift` for detecting CLI tools
- Shows CLI status in sidebar
- Installation wizard with step-by-step flow

### 3. Supporting Files Created
- `AgentModels.swift` - Agent, AgentTask, AgentType, AgentState
- `AgentManager.swift` - Agent lifecycle management
- `WorkspaceManager.swift` - Git worktree integration (stub)

---

## Architecture Decisions

1. **Hybrid Diff Approach:** Show diffs in-app for reviewing, VS Code for editing
2. **Use TaskRunner Package:** Don't duplicate ProcessExecutor, use existing package
3. **CLI-based Agents:** Use `copilot` and `claude` CLI tools rather than direct API
4. **Dogfooding:** Plan to use agent orchestration to build agent orchestration features