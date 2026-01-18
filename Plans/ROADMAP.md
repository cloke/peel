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
- [ ] Merge Agent implementation ([#6](https://github.com/cloke/peel/issues/6))
- [x] Planner structured output format ([#7](https://github.com/cloke/peel/issues/7))

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
