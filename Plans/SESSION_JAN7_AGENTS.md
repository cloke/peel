# Agent Orchestration - Session Summary (Jan 7-8, 2026)

## Session Jan 8: Role Prompts & Framework Hints ✅

### Latest: Added System Prompts for Roles
Each role now has a clear system prompt injected into the conversation:

**Planner Prompt:**
```
You are a PLANNER agent. Your role is to:
- Analyze code and understand the codebase
- Create detailed plans and identify issues
- List specific files and line numbers
IMPORTANT: You must NOT make any edits. You are READ-ONLY.
```

**Implementer Prompt:**
```
You are an IMPLEMENTER agent. Your role is to:
- Execute the plan provided by the Planner
- Make precise, targeted code changes
You have FULL ACCESS to edit files.
```

**Reviewer Prompt:**
```
You are a REVIEWER agent. Your role is to:
- Review the changes made by the Implementer
- Check for bugs and code quality issues
IMPORTANT: You must NOT make any edits. You are READ-ONLY.
```

### Added Framework Hints
Agents can be configured for specific languages/frameworks:
- **Auto-detect** - Let the agent figure it out
- **Swift/SwiftUI** - iOS/macOS patterns, Swift 6, @Observable
- **Ember.js** - Octane patterns, Glimmer components
- **React** - Hooks, TypeScript
- **Python** - PEP 8, async/await
- **Rust** - Ownership, Result types
- **General** - No specific framework

### New Agent Properties
- `agent.buildPrompt(userPrompt:context:)` - Builds full prompt with role + framework + custom instructions
- `agent.frameworkHint` - Selected framework
- `agent.customInstructions` - Additional custom instructions

---

## UX Feedback & Next Steps 🎯

### 1. Agent Roles (Read-only Planner)
Current issue: Planner made edits when it should only plan.

**Solution:** Add `AgentRole` with tool restrictions:
```swift
enum AgentRole {
  case planner    // Read-only: can read files, search, but NOT write
  case implementer // Full access: can edit files, run commands
  case reviewer   // Read-only: reviews changes, suggests fixes
}
```
- Pass `--deny-tool write_file edit_file` for planners/reviewers
- Add "Auto-approve" toggle vs manual review step

### 2. Live Status/Progress (Not Just Spinner)
Show what the agent is doing:
- "Reading Agent.swift..."
- "Searching for async patterns..."
- "Editing CLIService.swift..."
- Progress bar or step indicator

**Implementation:** Parse copilot's stderr for tool usage in real-time (streaming)

### 3. Chain Templates
Pre-configured workflows users can save/load:
- **Code Review:** 1 Planner (Opus) → N Implementers → 1 Reviewer
- **Bug Fix:** 1 Analyzer → 1 Fixer → 1 Tester
- **Refactor:** 1 Planner → 3 Implementers (parallel?) → 2 Reviewers

**Template Structure:**
```swift
struct ChainTemplate {
  let name: String
  let description: String
  let steps: [AgentStepTemplate]
  // e.g., "1 planner, up to 10 implementers, 2 reviewers"
}
```

### 4. Review Loop
Allow back-and-forth between agents:
- Reviewer suggests changes
- Implementer can accept/deny
- Loop until approved or max iterations

### 5. Better UX for Creating (No Hidden + Menu)
Current: `+` menu hides options

**Ideas:**
- **Segmented control** in sidebar header: `Agents | Chains | Templates`
- **Empty state cards** when no agents: "Create Agent" / "Create Chain" buttons
- **Quick actions bar** at bottom of sidebar
- **Floating action button** (FAB) with expanded options

---

## Immediate Implementation Priority

1. ✅ **Fix + menu** → Use segmented tabs or visible buttons
2. 🔄 **Add AgentRole** → Planner (read-only), Implementer, Reviewer
3. 🔄 **Live status** → Show current tool being used
4. 📋 **Templates** → Save/load chain configurations

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