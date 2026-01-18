# Agent Orchestration Plan

**Updated:** January 18, 2026  
**Status:** In Progress  
**Priority:** High

---

## Current State

- ✅ Basic Agents_RootView.swift with NavigationSplitView
- ✅ Agent models (Agent, AgentTask, AgentWorkspace)
- ✅ AgentManager for state management
- ✅ WorkspaceManager stub (uses Git.Worktree)
- ✅ CLISetupSheet with installation wizard UI
- ✅ Tool switcher integration (Agents tab)

---

## Blocked / In Progress

### CLI Integration
- CLIService needs: detect installed tools (gh, claude-cli)
- Installation wizard doesn't update state after install completes
- Wire up actual CLI execution to agents

---

## Next Steps

### 1. Complete CLIService
- [ ] Add detection methods for `gh`, `claude-cli`, `cursor`
- [ ] Installation status persistence
- [ ] Update UI when tools are detected

### 2. Agent Execution
- [ ] Wire CLIService to actually run agent commands
- [ ] Stream output to UI
- [ ] Handle agent state transitions (idle → working → complete)

### 3. Worktree Integration
- [ ] Auto-create worktree when spawning agent
- [ ] Track worktree ↔ agent relationship
- [ ] Cleanup worktree when agent completes (optional)

### 4. PR Review Integration
- [ ] "Review with Agent" button on PR detail
- [ ] Creates worktree + spawns agent with PR context
- [ ] Agent can read diff, suggest changes

---

## CLI Tools to Support

| Tool | Detection | Purpose |
|------|-----------|---------|
| `gh` | `which gh` | GitHub CLI, Copilot extensions |
| `gh copilot` | `gh extension list` | AI code suggestions |
| `claude` | `which claude` | Claude CLI agent |
| `cursor` | Check `/Applications` | Cursor editor with AI |

---

## Architecture

```
User Task
    ↓
AgentManager.spawn()
    ↓
WorkspaceManager.createWorkspace() → Git.Worktree
    ↓
CLIService.execute() → streams output
    ↓
Agent completes → cleanup optional
```
