# Peel Roadmap

**Created:** January 18, 2026  
**Last Updated:** January 18, 2026

---

## Current State Summary

### ✅ Complete & Working

| Area | Status | Details |
|------|--------|---------|
| **SwiftUI Modernization** | ✅ 100% | All 3 packages (Git, Brew, GitHub) use @Observable, @MainActor, Swift 6 |
| **SwiftData + iCloud** | ✅ Working | CloudKit-compatible models in `Shared/SwiftDataModels.swift` |
| **Agent Orchestration UI** | ✅ Solid | Full NavigationSplitView, chain templates, role-based agents |
| **CLI Integration** | ✅ Working | Copilot CLI detection, streaming output, model selection |
| **Chain Execution** | ✅ Functional | Sequential agent execution with context passing, review loops |
| **Session Tracking** | ✅ Working | Premium cost tracking, session summary export |
| **Linux VM** | ✅ Boots | Gets to command line (needs polish) |

### 🟡 Partially Complete

| Area | Current State | Gap |
|------|--------------|-----|
| **Worktree Unification** | Services exist separately | Agent worktrees don't appear in Workspaces tab |
| **TrackedWorktree** | SwiftData model exists | Never used - no persistence |
| **macOS VM** | Architecture defined | Not working yet |
| **Parallel Agents** | Models exist | Only sequential execution |

### 📋 Planned

| Feature | Location | Notes |
|---------|----------|-------|
| XPC Tool Brokers | Phase 2 | Needs design |
| MCP Test Harness | Phase 1C | Templates, validation, MCP server |
| MLX Integration | Phase 2 | Local inference |
| PII Scrubber | Phase 2 | High value standalone |
| Vision/Screen Capture | Phase 3 | Multimodal |

---

## Phased Roadmap

### Phase 1A: Polish What Works
**Timeline:** 1-2 weeks

- [x] Wire TrackedWorktree to Workspaces ([#1](https://github.com/cloke/peel/issues/1))
- [ ] Complete WorkspaceDashboardService cleanup ([#4](https://github.com/cloke/peel/issues/4))
- [x] Fix CLI state persistence ([#3](https://github.com/cloke/peel/issues/3))
- [x] Unify worktree visibility across tabs ([#2](https://github.com/cloke/peel/issues/2))

### Phase 1B: True Parallel Agents
**Timeline:** 2-3 weeks

- [x] TaskGroup-based parallel execution ([#5](https://github.com/cloke/peel/issues/5))
- [x] Merge Agent implementation ([#6](https://github.com/cloke/peel/issues/6))
- [x] Planner structured output format ([#7](https://github.com/cloke/peel/issues/7))

### Phase 1C: MCP Test Harness & Templates
**Timeline:** 1-2 weeks

- [ ] MCP server for test harness ([#11](https://github.com/cloke/peel/issues/11))
- [ ] Template: planner + parallel implementers + merge + review ([#12](https://github.com/cloke/peel/issues/12))
- [ ] Validation pipeline for correctness checks ([#13](https://github.com/cloke/peel/issues/13))
- [ ] MCP activity log + cleanup actions ([#16](https://github.com/cloke/peel/issues/16))
- [ ] MCP control CLI (query, stop server, quit app)
- [ ] Planner gating: skip implementers when planner decides “no work” (record decision + reason)
- [ ] Show planner prompt in Chain Activity / MCP Run detail
- [ ] Clarify Assign Task behavior (disable while chain running or label as “Spawn Agent”)

#### Proposed Next: Two Worktree Chains (Phase 1C)

**Chain A: MCP Test Harness Server (Issue #11)**

- **Goal:** Stand up the MCP test harness server and expose a basic command surface.
- **Worktree A (Implementer 1):** MCP server scaffolding, routes, and lifecycle wiring.
- **Worktree B (Implementer 2):** CLI surface and API contract (request/response models).
- **Merge:** Reconcile server endpoints with CLI commands; ensure command help text aligns.
- **Review:** Validate server can start, respond to a health check, and cleanly stop.

**Chain B: MCP Activity Log + Cleanup (Issue #16)**

- **Goal:** Persist and display MCP activity, plus add cleanup actions.
- **Worktree A (Implementer 1):** SwiftData model + persistence plumbing.
- **Worktree B (Implementer 2):** UI + action wiring (log list, clear/archive actions).
- **Merge:** Connect log writes to UI reads; add cleanup triggers.
- **Review:** Verify log entries appear, updates stream, and cleanup clears state.

### Phase 2: Local AI Foundation
**Timeline:** 3-4 weeks

- [ ] PII Scrubber tool ([#8](https://github.com/cloke/peel/issues/8))
- [ ] XPC Tool Broker architecture (TBD)
- [ ] Basic MLX integration (TBD)

### Phase 3: Full Isolation & Scale
**Timeline:** Future

- [ ] Polish Linux VM experience ([#9](https://github.com/cloke/peel/issues/9))
- [ ] macOS VM support (TBD)
- [ ] VM task execution pipeline (TBD)
- [ ] GPU shared cache service
- [ ] ANE micro-services

---

## Architecture: Parallel Agents

```
Planner → splits task → creates branches
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

**Key Components:**
- `AgentChain` - orchestrates the flow
- `WorkspaceManager` - creates worktrees via `Git.Worktree`
- `CLIService` - executes agents with streaming
- `TaskGroup` - Swift's parallel execution primitive

---

## Architecture: VM Isolation

```
┌─────────────────────────────────────────────────┐
│              Host (Peel App)                     │
│  ┌─────────────┐  ┌─────────────┐               │
│  │ AgentManager │──│ VMIsolation │               │
│  └─────────────┘  │   Service   │               │
│                   └──────┬──────┘               │
│                          │                      │
│  Execution Tiers:                               │
│  ┌──────────────────────────────────────────┐  │
│  │ 1. Host     │ 2. Linux VM │ 3. macOS VM  │  │
│  │ (trusted,   │ (light,     │ (full iso,   │  │
│  │  ANE/GPU)   │  fast)      │  Xcode)      │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

---

## GitHub Issues Index

### High Priority (Phase 1A)
- [#1](https://github.com/cloke/peel/issues/1) - Wire TrackedWorktree SwiftData model
- [#2](https://github.com/cloke/peel/issues/2) - Unify worktree visibility across tabs
- [#3](https://github.com/cloke/peel/issues/3) - Persist CLI tool detection status
- [#4](https://github.com/cloke/peel/issues/4) - Delete duplicate parseWorktreeList

### Phase 1B (Parallel Agents)
- [#5](https://github.com/cloke/peel/issues/5) - Implement parallel agent execution with TaskGroup
- [#6](https://github.com/cloke/peel/issues/6) - Create Merge Agent for combining worktree results
- [#7](https://github.com/cloke/peel/issues/7) - Add structured JSON output for Planner agent

### Phase 2 (Local AI)
- [#8](https://github.com/cloke/peel/issues/8) - Create PII scrubber CLI tool
- [#11](https://github.com/cloke/peel/issues/11) - MCP test harness server
- [#12](https://github.com/cloke/peel/issues/12) - MCP chain template (planner → parallel → merge → review)
- [#13](https://github.com/cloke/peel/issues/13) - MCP validation pipeline
- [#16](https://github.com/cloke/peel/issues/16) - MCP activity log + cleanup actions
- MCP Activity: dedicated run detail panel (prompt/output/validation)
- MCP Activity: show agent live status timeline per run
- MCP: prevent sleep while chain is running (optional toggle)
- XPC Tool Broker architecture (TBD)
- MLX integration (TBD)

### Phase 3 (VM)
- [#9](https://github.com/cloke/peel/issues/9) - Polish Linux VM experience
- macOS VM support (TBD)

---

## References

- [AGENT_ORCHESTRATION_PLAN.md](AGENT_ORCHESTRATION_PLAN.md)
- [PARALLEL_AGENTS_PLAN.md](PARALLEL_AGENTS_PLAN.md)
- [VM_ISOLATION_PLAN.md](VM_ISOLATION_PLAN.md)
- [CONSOLIDATION_PLAN.md](CONSOLIDATION_PLAN.md)
- [apple-agent-big-ideas.md](apple-agent-big-ideas.md)
