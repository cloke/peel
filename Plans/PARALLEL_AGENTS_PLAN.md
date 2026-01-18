# Parallel Agents with Worktrees

**Updated:** January 18, 2026  
**Status:** Future Feature  
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

1. **Planner output format** - structured JSON with branch name + tasks
2. **Parallel worktree creation** - one per implementer
3. **TaskGroup execution** - run agents in parallel
4. **Merge Agent** - analyze diffs, merge, handle conflicts
5. **Conflict resolution UI** - show conflicts, let user choose

---

## Prerequisites

- [ ] Basic agent execution working (AGENT_ORCHESTRATION_PLAN)
- [ ] Unified worktree model (CONSOLIDATION_PLAN)
- [ ] TrackedWorktree persistence
