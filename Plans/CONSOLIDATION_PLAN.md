# Code Consolidation Plan

**Updated:** January 18, 2026  
**Status:** Ready for implementation  
**Goal:** Reduce code duplication and unify worktree/workspace visibility

---

## Next Steps (Prioritized)

### 1. WorkspaceDashboardService Cleanup
**Location:** `Shared/Services/WorkspaceDashboardService.swift`

- [ ] Delete duplicate `parseWorktreeList()` (lines 314-371) - use `Git.Commands.Worktree.list()` instead
- [ ] Replace `runGit()` helper with `Git.Commands.simple()`
- [ ] Delete `WorktreeInfo` model - use `Git.Worktree` directly

### 2. Unify Worktree Visibility
All worktrees should appear in the Workspaces tab with source tags:

| Source | Currently Visible In | Should Also Show In |
|--------|---------------------|---------------------|
| Manual (Git package) | Git Tab | Workspaces Tab |
| PR Review (ReviewLocallyService) | Nowhere | Workspaces Tab |
| Agent (WorkspaceManager) | Agents Tab | Workspaces Tab |

**Implementation:**
- Add `source` field to worktree display: `manual`, `agent`, `pr-review`
- Workspaces tab loads all worktrees via `Git.Commands.Worktree.list()`
- Filter/group UI by source

### 3. Connect TrackedWorktree SwiftData Model
`TrackedWorktree` exists in `PeelApp.swift` but is **unused**. Wire it up to:
- Track worktree metadata (purpose, linked PR, creation date)
- Persist source information (agent, PR review, manual)
- Survive app restarts

### 4. Error Type Consolidation
Three duplicate error types exist:

| Location | Type |
|----------|------|
| `WorkspaceDashboardService.swift` | `WorktreeError` |
| `WorkspaceManager.swift` | `WorkspaceError` |
| `WorktreeService.swift` | `WorktreeError` |

**Fix:** Create single `Shared/Services/WorktreeErrors.swift`

### 5. Merge Agent Workspace Services
`WorkspaceManager` and `WorktreeService` both manage worktrees for agents:
- Merge into single `AgentWorkspaceService`
- Use `Git.Worktree` as base model
- `AgentWorkspace` becomes a thin wrapper adding agent-specific metadata

---

## Feature Visibility Matrix (Current → Goal)

**Current:**
| Worktree Source | Git Tab | Workspaces Tab | Agents Tab |
|-----------------|---------|----------------|------------|
| Manual | ✅ | ❌ | ❌ |
| PR Review | ❌ | ❌ | ❌ |
| Agent | ❌ | ❌ | ✅ |

**Goal:**
| Worktree Source | Git Tab | Workspaces Tab | Agents Tab |
|-----------------|---------|----------------|------------|
| Manual | ✅ | ✅ (tagged) | ❌ |
| PR Review | ❌ | ✅ (tagged) | ❌ |
| Agent | ❌ | ✅ (tagged) | ✅ |

---

## Implementation Order

1. **WorkspaceDashboardService cleanup** (safe, localized)
2. **Error consolidation** (safe, reduces confusion)
3. **TrackedWorktree wiring** (enables persistence)
4. **Unified visibility** (requires above steps)
5. **Agent service merge** (larger refactor)
