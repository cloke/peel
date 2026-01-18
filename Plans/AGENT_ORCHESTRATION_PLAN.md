# Agent Orchestration Plan

**Updated:** January 18, 2026  
**Status:** ✅ Core Complete  
**Priority:** Maintenance

---

## Current State

- ✅ Basic Agents_RootView.swift with NavigationSplitView
- ✅ Agent models (Agent, AgentTask, AgentWorkspace)
- ✅ AgentManager for state management
- ✅ WorkspaceManager (uses Git.Worktree)
- ✅ CLISetupSheet with installation wizard UI
- ✅ Tool switcher integration (Agents tab)
- ✅ CLI tool detection (gh, claude-cli, cursor)
- ✅ CLI state persistence (#3 closed)
- ✅ Streaming output to UI
- ✅ Agent state transitions (idle → working → complete)
- ✅ Parallel agent execution with TaskGroup (#5 closed)
- ✅ Merge Agent for combining worktree results (#6 closed)
- ✅ Planner structured JSON output (#7 closed)
- ✅ MCP server for external agent access (#11, #12 closed)

---

## Remaining / Future

### Worktree Integration (Nice to Have)
- [x] Auto-create worktree when spawning agent
- [x] Track worktree ↔ agent relationship
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
