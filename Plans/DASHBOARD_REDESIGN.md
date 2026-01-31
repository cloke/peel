---
title: Dashboard Redesign - Unified Work View
status: draft
created: 2026-01-30
updated: 2026-01-30
tags:
  - ux
  - navigation
  - design
audience:
  - developer
  - ai-agent
---

# Dashboard Redesign: Unified Work View

**Status:** Draft  
**Created:** January 30, 2026  
**Related:** Session/2026-01-30-worktree-next-steps.md

---

## Problem Statement

The current navigation is siloed:
- **Git tab** - Repos, branches, commits
- **GitHub tab** - PRs, issues
- **Agents tab** - Chains, RAG, swarm, parallel worktrees, templates...

This creates confusion:
1. "Parallel worktrees" are just chains running in worktrees - why separate from worktrees?
2. The "Agents" tab is becoming a junk drawer
3. Related concepts are scattered (worktrees in Git vs Agents)
4. No unified view of "what's happening right now"

---

## Core Insight

**The unit of work is a repository + task, not a feature category.**

When you're working, you care about:
- What's running right now?
- What repos am I working on?
- What branches/worktrees exist?
- What agents/workers are available?

You don't care about "RAG" vs "Chains" vs "Swarm" - those are implementation details.

---

## Proposed Structure

### Option A: Activity-Centric Dashboard

```
┌─────────────────────────────────────────────────────────┐
│  🏠 Dashboard                                           │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ACTIVE WORK                                            │
│  ───────────                                            │
│  🔄 Chain: "Add user auth" (tio-api, 45%)               │
│  🔄 Chain: "Fix search bug" (KitchenSink, 12%)          │
│  🔍 Indexing: KitchenSink (87% complete)                │
│                                                         │
│  REPOSITORIES                    WORKERS                │
│  ────────────                    ───────                │
│  📁 KitchenSink                  💻 MacBook (local)     │
│     main ✓                       🖥️ Mac Studio (idle)   │
│     ├─ worktree: fix-auth                               │
│     └─ worktree: pr-review-42                           │
│                                                         │
│  📁 tio-api                                             │
│     dev-1234 ✓                                          │
│     └─ worktree: staging-test                           │
│                                                         │
│  QUICK ACTIONS                                          │
│  [Run Chain] [New Worktree] [Search Code]               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Option B: Repo-Centric View

Each repo gets its own "workspace card":

```
┌─────────────────────────────────────────────────────────┐
│  📁 KitchenSink                              [⚙️] [📂]   │
├─────────────────────────────────────────────────────────┤
│  Branch: main (3 ahead, 2 behind)                       │
│                                                         │
│  Worktrees:                                             │
│    fix-auth (2 days old, 45MB)        [Open] [Delete]   │
│    pr-review-42 (stale)               [Open] [Delete]   │
│                                                         │
│  Active:                                                │
│    🔄 Chain "Add logging" (67%)                         │
│                                                         │
│  RAG: 4,521 chunks, last indexed 2h ago   [Re-index]    │
└─────────────────────────────────────────────────────────┘
```

### Option C: Keep Tabs but Add Dashboard

Keep Git/GitHub/Agents tabs, but add a "Dashboard" or "Overview" as default:

- Dashboard shows active work across all domains
- Individual tabs for deep-dives
- Less disruptive to existing users

---

## What To Consolidate

### "Parallel Worktrees" → Just "Worktrees" or "Tasks"
- It's chains running in worktrees
- Remove the artificial distinction
- Show in dashboard under active work

### "Local RAG" → Part of Repo Context
- RAG status is per-repo
- Show indexing status in repo cards
- Search is global but scoped to selected repos

### "Swarm" → "Workers" Panel
- Just a list of available workers
- Shows in sidebar or panel
- Not a separate "tab"

### "Chain Templates" → "New Task" Dialog
- Templates are a way to create work
- Not a thing to browse separately

---

## Migration Path

### Phase 1: Add Dashboard (non-breaking)
- New "Dashboard" tab as default view
- Shows: active chains, worktrees, workers, quick stats
- Existing tabs unchanged

### Phase 2: Consolidate Agents Tab
- Move chain execution into Dashboard
- Move RAG into repo context
- Swarm becomes "Workers" panel
- Agents tab → "Settings/Advanced"

### Phase 3: Simplify Git/GitHub
- Git becomes repo management
- GitHub becomes PR/issue tracking
- Both integrate with dashboard for active work

---

## Open Questions

1. **Do we keep tabs at all?** Or go full dashboard with drill-downs?
2. **Where does "search" live?** Global search bar? Per-repo?
3. **How to handle multiple repos?** Cards? List? Tree?
4. **Mobile (iOS)?** Dashboard needs to work on small screens

---

## Quick Wins Toward This Vision

Without full redesign, we can:

1. **Add worktree section to current dashboard**
   - Shows all worktrees in one list
   - Already have MCP tools, just need UI

2. **Add "Active Work" banner/section**
   - Shows running chains prominently
   - Link to detailed view

3. **Show workers in sidebar**
   - Always visible when swarm is active
   - Not hidden in a tab

4. **Repo-aware quick actions**
   - "New worktree for {repo}" 
   - "Index {repo}" 
   - Context-sensitive

---

## Related Issues

- #213: Worktree Dashboard (proposed)
- #214: Auto-cleanup worktrees (proposed)  
- #215: Worktree health monitoring (proposed)

---

## Next Steps

1. [ ] Prototype dashboard view (alongside existing tabs)
2. [ ] Add worktree list to existing Agents dashboard
3. [ ] Move "workers" to persistent sidebar element
4. [ ] Gather feedback on Option A vs B vs C
