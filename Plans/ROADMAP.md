---
title: Peel Roadmap
status: active
tags:
  - roadmap
  - peel
  - agent-orchestration
  - mcp
updated: 2026-01-24
last_health_check: 2026-01-23
audience:
  - ai-agent
  - developer
github_issues:
  - number: 22
    status: open
    title: MCP automation framework package
  - number: 23
    status: open
    title: XPC tool broker
  - number: 24
    status: open
    title: MLX integration
  - number: 29
    status: open
    title: Add Review with Agent button for PRs
  - number: 30
    status: open
    title: Add merge conflict resolution UI
  - number: 35
    status: open
    title: Screen capture to Vision analysis
  - number: 36
    status: open
    title: Voice commands via on-device Whisper
  - number: 37
    status: open
    title: Cross-machine distributed actors
  - number: 40
    status: open
    title: Agent feedback loop - watch and retry
  - number: 41
    status: open
    title: Budget-aware agent scheduler
  - number: 43
    status: open
    title: Deterministic replay for agent runs
  - number: 44
    status: open
    title: Multi-agent quorum for destructive actions
  - number: 52
    status: open
    title: Fix screenshot capture to preserve sidebar/vibrancy
  - number: 74
    status: open
    title: Local RAG v1 embedding provider (Core ML)
  - number: 78
    status: open
    title: Parallel worktree runner with Local RAG grounding
  - number: 79
    status: open
    title: Refactor MCP tool permissions for package-ready interface
  - number: 80
    status: open
    title: Extract MCP tool registry into package
  - number: 83
    status: open
    title: Cohesive Workspaces/Worktrees navigation
  - number: 84
    status: open
    title: MCP prompt rules + planner selection guardrails
  - number: 85
    status: open
    title: CLI: add safe polling helper for MCP runs
  - number: 86
    status: open
    title: MCP run status: add rejected count
  - number: 87
    status: open
    title: RAG feedback loop for CI failures on MCP-generated PRs
  - number: 88
    status: open
    title: Detect and surface hung MCP executions
  - number: 89
    status: open
    title: parallel.status 404s while UI shows active run
  - number: 106
    status: open
    title: VM Isolation: macOS VM for Xcode isolation
  - number: 107
    status: open
    title: GPU shared cache service
  - number: 108
    status: open
    title: ANE micro-services for fast local agent tasks
  - number: 109
    status: open
    title: Voice notifications + quick reply commands
code_locations:
  - file: Shared/AgentOrchestration/AgentManager.swift
    lines: 260-500
    description: AgentChainRunner and parallel execution (reduced to ~4K lines)
  - file: Shared/AgentOrchestration/MCPTemplateExecutor.swift
    description: MCP chain template execution
  - file: Shared/Views/SettingsView.swift
    description: MCP server toggle and settings
  - file: Shared/Services/LocalRAGStore.swift
    description: Local RAG SQLite store, file scanner, chunker
  - file: Shared/Services/LocalRAGEmbeddings.swift
    description: Embedding providers (system w/ text sanitization, hash, Core ML scaffold)
  - file: Shared/Services/TranslationValidatorService.swift
    description: Translation validation service (extracted from AgentManager)
  - file: Shared/Services/PIIScrubberService.swift
    description: PII scrubber service (extracted from AgentManager)
  - file: Shared/Applications/Agents/LocalRAGDashboardView.swift
    description: Local RAG dashboard UI
  - file: Shared/Applications/Agents/PIIScrubberView.swift
    description: PII scrubber UI with audit report display/export
  - file: Tools/PeelSkills/Sources/PIIScrubber/PIIScrubber.swift
    description: PII scrubber CLI tool
related_docs:
  - AGENT_ORCHESTRATION_PLAN.md
  - PARALLEL_AGENTS_PLAN.md
  - LOCAL_RAG_PLAN.md
  - MCP_AGENT_WORKFLOW.md
  - PII_SCRUBBER_DESIGN.md
  - Docs/guides/AGENTS_UX_AUDIT.md
  - Docs/guides/MCP_HEADLESS_FEASIBILITY.md
  - Docs/guides/IOS_FEATURE_MATRIX.md
  - Docs/guides/VM_BOOTSTRAP_GITHUB_AUTH.md
---

# Peel Roadmap

---

## Phase 1C: Polish (Open)

### 📋 Agent Features

| Issue | Title | Notes |
|-------|-------|-------|
| [#29](https://github.com/cloke/peel/issues/29) | Review with Agent button | PR review entry point |
| [#30](https://github.com/cloke/peel/issues/30) | Conflict resolution UI | Merge conflicts |
| [#40](https://github.com/cloke/peel/issues/40) | Feedback loop | Watch and retry |
| [#83](https://github.com/cloke/peel/issues/83) | Cohesive Workspaces/Worktrees navigation | Unify navigation paths |

### 📋 Parallel Agents

| Issue | Title | Notes |
|-------|-------|-------|
| [#78](https://github.com/cloke/peel/issues/78) | Parallel worktree runner with Local RAG grounding | Context-aware parallel runs |

### 📋 MCP Packaging

| Issue | Title | Notes |
|-------|-------|-------|
| [#22](https://github.com/cloke/peel/issues/22) | MCP automation framework package | Reusable framework |
| [#79](https://github.com/cloke/peel/issues/79) | Refactor MCP tool permissions | Package-ready interface |
| [#80](https://github.com/cloke/peel/issues/80) | Extract MCP tool registry | Package separation |

### 📋 MCP Reliability

| Issue | Title | Notes |
|-------|-------|-------|
| [#84](https://github.com/cloke/peel/issues/84) | MCP prompt rules + planner guardrails | Safety defaults |
| [#85](https://github.com/cloke/peel/issues/85) | CLI safe polling helper | Avoid stale polling |
| [#86](https://github.com/cloke/peel/issues/86) | MCP run status: rejected count | Status completeness |
| [#87](https://github.com/cloke/peel/issues/87) | RAG feedback loop for CI failures | Retry + guidance feedback |
| [#88](https://github.com/cloke/peel/issues/88) | Detect hung MCP executions | Hung detection + logs |
| [#89](https://github.com/cloke/peel/issues/89) | parallel.status 404s | Recovery + UI warning |

---

## Phase 2: Local AI Foundation

### 🔄 In Progress

| Issue | Title | Notes |
|-------|-------|-------|
| [#74](https://github.com/cloke/peel/issues/74) | Local RAG: Embedding provider | System embeddings working (w/ crash fix), Core ML blocked |

### 📋 Open

| Issue | Title | Description |
|-------|-------|-------------|
| [#23](https://github.com/cloke/peel/issues/23) | XPC Tool Broker | Sandboxed execution |
| [#24](https://github.com/cloke/peel/issues/24) | MLX Integration | Local inference |
| [#41](https://github.com/cloke/peel/issues/41) | Budget Scheduler | Resource allocation |
| [#108](https://github.com/cloke/peel/issues/108) | ANE micro-services | Fast on-device tasks |

---

## Phase 3: Full Isolation & Scale

| Issue | Title | Description |
|-------|-------|-------------|
| [#35](https://github.com/cloke/peel/issues/35) | Vision Pipeline | Screen capture → analysis |
| [#36](https://github.com/cloke/peel/issues/36) | Voice Commands | On-device Whisper |
| [#109](https://github.com/cloke/peel/issues/109) | Voice notifications + quick replies | Task completion + commands |
| [#37](https://github.com/cloke/peel/issues/37) | Distributed Actors | Multi-Mac scale |
| [#106](https://github.com/cloke/peel/issues/106) | macOS VM isolation | Full Xcode isolation |
| [#107](https://github.com/cloke/peel/issues/107) | GPU shared cache service | MLX caching service |

---

## Safety & Reliability

| Issue | Title | Description |
|-------|-------|-------------|
| [#43](https://github.com/cloke/peel/issues/43) | Deterministic Replay | Audit trail |
| [#44](https://github.com/cloke/peel/issues/44) | Multi-Agent Quorum | Safety consensus |

---

## Architecture: Parallel Agents

```
Planner -> splits task -> creates branches
    |
+------------+------------+------------+
| Agent 1    | Agent 2    | Agent 3    |
| Worktree A | Worktree B | Worktree C |
+-----+------+-----+------+-----+------+
      +------------+------------+
                   v
            Merge Agent
                   |
            Feature Branch
```

---

## References

- [AGENT_ORCHESTRATION_PLAN.md](AGENT_ORCHESTRATION_PLAN.md)
- [PARALLEL_AGENTS_PLAN.md](PARALLEL_AGENTS_PLAN.md)
- [VM_ISOLATION_PLAN.md](VM_ISOLATION_PLAN.md)
- [MCP_AGENT_WORKFLOW.md](MCP_AGENT_WORKFLOW.md)
- [LOCAL_RAG_PLAN.md](LOCAL_RAG_PLAN.md)
- [HEALTH_CHECK_ACTION_PLAN_2026-01-20.md](HEALTH_CHECK_ACTION_PLAN_2026-01-20.md) - Latest action plan
- [Sessions/HEALTH_CHECK_2026-01-19.md](../Sessions/HEALTH_CHECK_2026-01-19.md) - Full health audit

---

## Issue Queues (Pick a Track)

### Track A: Local RAG (1 issue)
```
74
```
- #74 Local RAG v1: Embedding provider (Core ML)

### Track B: Agent UX (4 issues)
```
29,30,40,83
```
- #29 Review with Agent button for PRs
- #30 Add merge conflict resolution UI
- #40 Agent feedback loop - watch and retry
- #83 Cohesive Workspaces/Worktrees navigation

### Track C: Charts & Analytics (1 issue)
```
64
```
- #64 Add Homebrew activity charts

### Track D: MCP Packaging & Parallel (4 issues)
```
22,78,79,80
```
- #22 MCP automation framework package
- #78 Parallel worktree runner with Local RAG grounding
- #79 Refactor MCP tool permissions for package-ready interface
- #80 Extract MCP tool registry into package

### Track E: Local AI Foundation (4 issues)
```
23,24,41,108
```
- #23 XPC tool broker
- #24 MLX integration
- #41 Budget-aware agent scheduler
- #108 ANE micro-services

### Track F: Polish & Cleanup (1 issue)
```
52
```
- #52 Fix screenshot capture to preserve sidebar/vibrancy

### Track G: Phase 3 / Future (8 issues)
```
35,36,109,37,106,107,43,44
```
- #35 Screen capture to Vision analysis pipeline
- #36 Voice commands via on-device Whisper
- #109 Voice notifications + quick replies
- #37 Cross-machine distributed actors
- #106 macOS VM isolation
- #107 GPU shared cache service
- #43 Deterministic replay for agent runs
- #44 Multi-agent quorum for destructive actions

### Track H: MCP Reliability (6 issues)
```
84,85,86,87,88,89
```
- #84 MCP prompt rules + planner guardrails
- #85 CLI safe polling helper
- #86 MCP run status: rejected count
- #87 RAG feedback loop for CI failures on MCP-generated PRs
- #88 Detect hung MCP executions
- #89 parallel.status 404s while UI shows active run
