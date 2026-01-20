---
title: Peel Roadmap
status: active
tags:
  - roadmap
  - peel
  - agent-orchestration
  - mcp
updated: 2026-01-20
audience:
  - ai-agent
  - developer
github_issues:
  - number: 8
    status: closed
    title: Create PII scrubber CLI tool
  - number: 76
    status: open
    title: PII scrubber enhancements (NER, rules, audit UX)
  - number: 16
    status: closed
    title: MCP activity log + cleanup actions
  - number: 21
    status: closed
    title: MCP screenshot capture tool
  - number: 22
    status: open
    title: MCP automation framework package
  - number: 23
    status: open
    title: XPC tool broker
  - number: 24
    status: open
    title: MLX integration
  - number: 25
    status: closed
    title: Dynamic chain scaling and model selection
  - number: 26
    status: closed
    title: Automate MCP test plan validation
  - number: 27
    status: closed
    title: Fix Alpine Linux VM boot to full OS
  - number: 28
    status: closed
    title: Improve empty states in Agents UI
  - number: 29
    status: open
    title: Add Review with Agent button for PRs
  - number: 30
    status: open
    title: Add merge conflict resolution UI
  - number: 31
    status: open
    title: PII scrubber design document
  - number: 32
    status: closed
    title: Prevent system sleep during MCP chain
  - number: 33
    status: closed
    title: Add MCP run timeline visualization
  - number: 34
    status: closed
    title: Optional auto-cleanup worktrees
  - number: 35
    status: open
    title: Screen capture to Vision analysis
  - number: 36
    status: open
    title: Voice commands via on-device Whisper
  - number: 37
    status: open
    title: Cross-machine distributed actors
  - number: 38
    status: open
    title: iOS feature parity audit
  - number: 39
    status: open
    title: Add chain templates gallery
  - number: 40
    status: open
    title: Agent feedback loop - watch and retry
  - number: 41
    status: open
    title: Budget-aware agent scheduler
  - number: 42
    status: open
    title: Local RAG for codebase context
  - number: 72
    status: closed
    title: Local RAG v1 SQLite store
  - number: 73
    status: closed
    title: Local RAG v1 repo scan + chunking
  - number: 74
    status: open
    title: Local RAG v1 embedding provider (Core ML)
  - number: 75
    status: closed
    title: Local RAG v1 query API + MCP hook
  - number: 43
    status: open
    title: Deterministic replay for agent runs
  - number: 44
    status: open
    title: Multi-agent quorum for destructive actions
  - number: 54
    status: open
    title: VM bootstrap for GitHub auth + repo provisioning
  - number: 55
    status: closed
    title: Translation parity validator (tio-front-end baseline)
  - number: 56
    status: closed
    title: Translation validator: discover locales and parse YAML
  - number: 57
    status: closed
    title: Translation validator: parity + placeholder checks
  - number: 58
    status: closed
    title: Translation validator: suggestions view (read-only)
  - number: 66
    status: closed
    title: MCP UI automation tools + permissions
  - number: 68
    status: closed
    title: MCP tool grouping toggles
code_locations:
  - file: Shared/AgentOrchestration/AgentManager.swift
    lines: 260-500
    description: AgentChainRunner and parallel execution
  - file: Shared/AgentOrchestration/MCPTemplateExecutor.swift
    description: MCP chain template execution
  - file: Shared/Views/SettingsView.swift
    description: MCP server toggle and settings
  - file: Shared/Services/LocalRAGStore.swift
    description: Local RAG SQLite store, file scanner, chunker
  - file: Shared/Services/LocalRAGEmbeddings.swift
    description: Embedding providers (system, hash, Core ML scaffold)
  - file: Shared/Applications/Agents/LocalRAGDashboardView.swift
    description: Local RAG dashboard UI
  - file: Shared/Applications/Agents/PIIScrubberView.swift
    description: PII scrubber UI
  - file: Tools/PeelSkills/Sources/PIIScrubber/PIIScrubber.swift
    description: PII scrubber CLI tool
related_docs:
  - AGENT_ORCHESTRATION_PLAN.md
  - PARALLEL_AGENTS_PLAN.md
  - LOCAL_RAG_PLAN.md
  - MCP_AGENT_WORKFLOW.md
---

# Peel Roadmap

---

## Current State Summary

### ✅ Complete

| Area | Details |
|------|---------|
| **SwiftUI Modernization** | All 3 packages (Git, Brew, GitHub) use @Observable, @MainActor, Swift 6 |
| **SwiftData + iCloud** | CloudKit-compatible models, TrackedWorktree persistence working |
| **Agent Orchestration** | NavigationSplitView, chain templates, role-based agents, parallel execution |
| **CLI Integration** | Tool detection, streaming output, model selection, state persistence |
| **MCP Server** | JSON-RPC server, templates.list, chains.run, server control |
| **Parallel Agents** | TaskGroup execution, merge agent, planner structured output |
| **MCP Validation** | Automated correctness checks for chain execution results |
| **Session Tracking** | Premium cost tracking, session summary export |
| **Settings/Preferences** | MCP toggle, port config, status display |
| **MCP Activity Log** | #16 - Persist/display run history, cleanup actions |
| **Screenshot Capture** | #21 - ScreenCaptureKit integration for chain runs |
| **Dynamic Scaling** | #25 - Cost caps and model selection |
| **Translation Validator** | #55–#58 - CLI + MCP + UI suggestions + Apple on-device checks |
| **PII Scrubber (Baseline)** | #8 - CLI + MCP + UI for deterministic scrubbing |
| **MCP UI Automation** | #66 - Tool registry, permissions, UI actions |
| **MCP Tool Grouping** | #68 - Grouped toggles for tool categories |
| **Local RAG (Core)** | #72-75 - SQLite store, scanning, embeddings, search |

### 📋 Phase 1C Polish (Closed)

| Issue | Title | Status |
|-------|-------|--------|
| [#26](https://github.com/cloke/peel/issues/26) | Automate MCP test plan | ✅ Closed |
| [#27](https://github.com/cloke/peel/issues/27) | Fix Alpine VM boot | ✅ Closed |
| [#28](https://github.com/cloke/peel/issues/28) | Agents UI polish | ✅ Closed |
| [#32](https://github.com/cloke/peel/issues/32) | Sleep prevention | ✅ Closed |
| [#33](https://github.com/cloke/peel/issues/33) | MCP run timeline | ✅ Closed |
| [#66](https://github.com/cloke/peel/issues/66) | MCP UI automation | ✅ Closed |
| [#68](https://github.com/cloke/peel/issues/68) | Tool grouping toggles | ✅ Closed |

### 📋 Phase 1C Polish (Open)

| Issue | Title | Notes |
|-------|-------|-------|
| [#67](https://github.com/cloke/peel/issues/67) | Headless MCP/CLI feasibility | CLI pathway + module split |

### 📋 Agent Features (Open)

| Issue | Title | Notes |
|-------|-------|-------|
| [#29](https://github.com/cloke/peel/issues/29) | PR Review with Agent | GitHub integration |
| [#30](https://github.com/cloke/peel/issues/30) | Conflict resolution UI | Merge conflicts |
| [#34](https://github.com/cloke/peel/issues/34) | Auto-cleanup worktrees | Optional setting |
| [#39](https://github.com/cloke/peel/issues/39) | Templates gallery | Built-in templates |
| [#40](https://github.com/cloke/peel/issues/40) | Feedback loop | Watch and retry |

---

## Phase 2: Local AI Foundation

### ✅ Completed

| Issue | Title | Status |
|-------|-------|--------|
| [#8](https://github.com/cloke/peel/issues/8) | PII Scrubber CLI | ✅ Closed |
| [#72](https://github.com/cloke/peel/issues/72) | Local RAG: SQLite store | ✅ Closed |
| [#73](https://github.com/cloke/peel/issues/73) | Local RAG: Repo scan + chunking | ✅ Closed |
| [#75](https://github.com/cloke/peel/issues/75) | Local RAG: Query API + MCP | ✅ Closed |

### 🔄 In Progress

| Issue | Title | Notes |
|-------|-------|-------|
| [#76](https://github.com/cloke/peel/issues/76) | PII Scrubber Enhancements | NER done, audit UI remaining |
| [#42](https://github.com/cloke/peel/issues/42) | Local RAG | Core done, enhancements open |
| [#74](https://github.com/cloke/peel/issues/74) | Local RAG: Embedding provider | System embeddings working, Core ML blocked |

### 📋 Open

| Issue | Title | Description |
|-------|-------|-------------|
| [#31](https://github.com/cloke/peel/issues/31) | PII Design Doc | Architecture first |
| [#22](https://github.com/cloke/peel/issues/22) | MCP Automation Package | Reusable framework |
| [#23](https://github.com/cloke/peel/issues/23) | XPC Tool Broker | Sandboxed execution |
| [#24](https://github.com/cloke/peel/issues/24) | MLX Integration | Local inference |
| [#41](https://github.com/cloke/peel/issues/41) | Budget Scheduler | Resource allocation |

---

## Phase 3: Full Isolation & Scale

| Issue | Title | Description |
|-------|-------|-------------|
| [#35](https://github.com/cloke/peel/issues/35) | Vision Pipeline | Screen capture → analysis |
| [#36](https://github.com/cloke/peel/issues/36) | Voice Commands | On-device Whisper |
| [#37](https://github.com/cloke/peel/issues/37) | Distributed Actors | Multi-Mac scale |
| [#54](https://github.com/cloke/peel/issues/54) | VM bootstrap auth | GitHub auth + repo provisioning |
| - | macOS VM | Full Xcode isolation |
| - | GPU Shared Cache | MLX caching service |

---

## Safety & Reliability

| Issue | Title | Description |
|-------|-------|-------------|
| [#43](https://github.com/cloke/peel/issues/43) | Deterministic Replay | Audit trail |
| [#44](https://github.com/cloke/peel/issues/44) | Multi-Agent Quorum | Safety consensus |

---

## Documentation

| Issue | Title | Description |
|-------|-------|-------------|
| [#38](https://github.com/cloke/peel/issues/38) | iOS Feature Audit | Platform parity |

---

## Active Work: Phase 1C

### Phase 1C Status (January 20, 2026)

**Completed:**
- [x] #8 PII scrubber baseline (CLI + MCP + UI)
- [x] #16 MCP Activity Log + Cleanup
- [x] #17 Planner gating: skip implementers when "no work"
- [x] #18 Show planner prompt in Chain Activity / MCP Run detail
- [x] #19 Clarify Assign Task behavior
- [x] #21 MCP screenshot capture tool
- [x] #25 Dynamic chain scaling + model selection

**In Progress:**
- [ ] #76 PII scrubber enhancements (NER, rules, audit UX)
  - [x] Config rules (YAML/JSON) + COPY parsing
  - [x] NER detection (names/orgs/places)
  - [ ] Audit report UI + export
  - [ ] Config validation error surfacing

**Open Polish Items:**
- [ ] #26 Automate MCP test plan validation
- [ ] #27 Fix Alpine VM boot to full OS
- [ ] #28 Improve empty states in Agents UI
- [ ] #32 Prevent system sleep during chain execution
- [ ] #33 Add MCP run timeline visualization

**Recent Progress:**
- Added `chains.stop` MCP endpoint to cancel active chain runs
- Enforced `workingDirectory` for `chains.run` to prevent whole-disk scans
- Added parallel chain helper script (`Tools/run-chains-parallel.sh`)
- Screenshot capture with ScreenCaptureKit integration
- Cost caps and planner-driven model selection
- PII scrubber enhancements: config rules, COPY parsing, NER, MCP `pii.scrub` support

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
- [Sessions/HEALTH_CHECK_2026-01-19.md](../Sessions/HEALTH_CHECK_2026-01-19.md) - Full health audit
