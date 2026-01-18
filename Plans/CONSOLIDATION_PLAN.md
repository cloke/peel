---
title: Code Consolidation Plan
status: in-progress
created: 2025-12-20
updated: 2026-01-18
tags: [refactoring, worktrees, code-quality]
audience: [developers]
code_locations:
  - path: Shared/Services/WorkspaceDashboardService.swift
    description: Dashboard service (cleanup done)
  - path: Shared/SwiftDataModels.swift
    description: TrackedWorktree model
  - path: Shared/Services/WorktreeErrors.swift
    description: Consolidated error types
related_docs:
  - Plans/AGENT_ORCHESTRATION_PLAN.md
  - Plans/PARALLEL_AGENTS_PLAN.md
---

# Code Consolidation Plan

**Updated:** January 18, 2026  
**Status:** Ready for implementation  
**Goal:** Reduce code duplication and unify worktree/workspace visibility

---

## Next Steps (Prioritized)

### 1. WorkspaceDashboardService Cleanup ✅
**Location:** `Shared/Services/WorkspaceDashboardService.swift`

- [x] Delete duplicate `parseWorktreeList()` - now uses `Git.Commands.Worktree.list()`
- [x] Replace `runGit()` helper with `Git.Commands.simple()`
- [x] Delete `WorktreeInfo` model - uses `Git.Worktree` directly

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

### 4. Error Type Consolidation ✅
Consolidated into `Shared/Services/WorktreeErrors.swift`

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
