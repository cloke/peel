# Parallel Agents with Worktrees

**Updated:** January 18, 2026  
**Status:** ✅ Core Implementation Complete (Issues #5-7 closed)  
**Depends On:** Agent Orchestration (basic), Consolidation (worktree unification)

---

## Vision

Multiple AI agents work in parallel using separate git worktrees, then a Merge Agent combines their work.

```
Planner → splits task → creates branch
    ↓
┌────────────┬────────────┬────────────┐
│ Agent 1    │ Agent 2    │ Agent 3    │
│ Worktree A │ Worktree B │ Worktree C │
└─────┬──────┴─────┬──────┴─────┬──────┘
      └────────────┼────────────┘
                   ▼
            Merge Agent
                   ↓
            Feature Branch
```

---

## Agent Roles

| Role | Responsibility |
|------|----------------|
| **Planner** | Analyze task, create branch, split into sub-tasks |
| **Implementer** | Execute sub-task in isolated worktree |
| **Merger** | Combine worktrees, resolve conflicts |
| **Reviewer** | (Optional) Review merged result |

---

## Model Selection (Planner decides)

| Complexity | Example | Model |
|------------|---------|-------|
| Trivial | Add modifier, rename | GPT 4.1 / Haiku |
| Simple | Add property, small function | Sonnet |
| Medium | New view, multi-file change | Sonnet |
| Complex | Architecture change | Opus |

---

## Implementation Steps

1. ✅ **Planner output format** - structured JSON with branch name + tasks (#7)
2. ✅ **Parallel worktree creation** - one per implementer
3. ✅ **TaskGroup execution** - run agents in parallel (#5)
4. ✅ **Merge Agent** - analyze diffs, merge, handle conflicts (#6)
5. 🔜 **Conflict resolution UI** - show conflicts, let user choose (future)

---

## Prerequisites

- [x] Basic agent execution working (AGENT_ORCHESTRATION_PLAN)
- [x] Unified worktree model (CONSOLIDATION_PLAN)
- [x] TrackedWorktree persistence
