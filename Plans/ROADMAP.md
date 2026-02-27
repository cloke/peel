---
title: Peel Roadmap
status: active
tags:
  - roadmap
  - peel
  - agent-orchestration
  - mcp
updated: 2026-02-26
last_health_check: 2026-02-26
audience:
  - ai-agent
  - developer
---

# Peel Roadmap

> **Sprint Model**: One forever sprint. Treat "days" as **hours** of focused work.
>
> **Archived Issues**: See [Plans/Archive/CLOSED_ISSUES.md](Archive/CLOSED_ISSUES.md)

---

## Quick Stats (Feb 26, 2026)

| Metric | Count |
|--------|-------|
| **Closed** | 304 ✅ |
| **Open** | 27 |
| **Build** | ✅ Clean (0 warnings) |
| **Tests** | ✅ 77/77 passing |

### Open by Category

| Category | Count | Issues |
|----------|-------|--------|
| **VM Isolation** | 6 | #310, #312, #313, #314, #315, #317 |
| **RAG Enhancements** | 5 | #249, #274, #275, #276, #277 |
| **Skills & Intelligence** | 3 | #205, #335, #336 |
| **Swarm / Distributed** | 2 | #193, #338 |
| **Vision & Voice** | 4 | #35, #36, #109, #246 |
| **Agent Infrastructure** | 4 | #23, #41, #43, #44 |
| **Hardware / Performance** | 2 | #107, #108 |
| **MCP & Tooling** | 1 | #91 |

### Recent Completions (since Jan 25)
- ✅ **Phase 1C** — All tracks complete (RAG, MCP, UX polish)
- ✅ **Phase 2** — MLX, HF reranking, pre-planner, MCP packaging all done
- ✅ **Phase 3 Layers 1-2** — RAG + Code Intelligence Graph complete
- ✅ **Parallel worktrees** — Full pipeline: pool, gate agent, merge, validation (#299, #308, #309)
- ✅ **VM foundation** — VMAgentConfig, StepType.vmAgentic, vm.agent.run (#311, #318)
- ✅ **Skills system** — .peel/ directory bootstrap, repo-local directives (#333, #334)
- ✅ **Local chat** — RAG-augmented chat, MLX tool calling, Ember skills injection
- ✅ **Swarm reliability** — Worker commit/push fixes, RAG WAN sync, alert bug fixes (#337, #339, #345)
- ✅ **Code quality** — 15+ cleanup issues: force unwraps, Combine→TimelineView, duplicate code (#320-#331, #340-#344)

---

## Active Work: VM Yolo Agent

**Goal**: Run AI coding agents (Copilot, Claude) inside sandboxed Linux VMs with full autonomy.

**Foundation done** — VMChainExecutor lifecycle, VirtioFS, MCP tools, templates all implemented.

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#312](https://github.com/cloke/peel/issues/312) | Host IP injection + peel-rag helper script for VM | 3h | 🟠 Partial (IP injection done, helper script missing) |
| [#313](https://github.com/cloke/peel/issues/313) | VM IP allowlist + tool scoping on MCP server | 4h | 🟡 Ready |
| [#314](https://github.com/cloke/peel/issues/314) | Implement `runVMAgenticStep()` in AgentChainRunner | 4h | 🟠 Partial (case routes exist, VM-specific logic missing) |
| [#315](https://github.com/cloke/peel/issues/315) | VMChainExecutor: auto-register VM IP with MCP allowlist | 3h | 🟡 Ready (depends on #313) |
| [#317](https://github.com/cloke/peel/issues/317) | Agent binary management: download/cache CLIs for Linux VM | 4h | 🟡 Ready |
| [#310](https://github.com/cloke/peel/issues/310) | VM validation pipeline: isolated build/test in sandboxed VMs | 6h | 🟡 Ready (depends on #314) |

**Dependency chain**: #312 → #313 → #315, and #314 → #310

---

## Active Work: Skills & Framework Intelligence

**Goal**: Generalize the Ember-specific skills system to support any framework.

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#336](https://github.com/cloke/peel/issues/336) | Multi-framework directive detection: generalize beyond Ember | 4h | 🟡 Ready (Ember detection works, needs generalization) |
| [#335](https://github.com/cloke/peel/issues/335) | Live skill updates: download from GitHub and write to .peel/ files | 4h | 🟡 Ready (local init done, remote fetch TODO in code) |
| [#205](https://github.com/cloke/peel/issues/205) | Code Intelligence System: Beyond RAG to Persistent Understanding | — | 📋 Tracking issue (Layers 1-2 done, Layer 3 future) |

---

## RAG Enhancements

**Goal**: Extend RAG analysis beyond code structure into framework-specific intelligence.

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#277](https://github.com/cloke/peel/issues/277) | Framework-aware orphan detection (Ember service/route/template) | 4h | 🟡 Ready (generic orphan detection exists, needs Ember awareness) |
| [#274](https://github.com/cloke/peel/issues/274) | Component API surface mapping and usage analysis | 6h | 🟡 Ready |
| [#276](https://github.com/cloke/peel/issues/276) | Cross-repo API endpoint correlation and blast radius | 6h | 🟡 Ready |
| [#275](https://github.com/cloke/peel/issues/275) | Tailwind CSS consistency lint and deprecation detection | 4h | 🟡 Ready |
| [#249](https://github.com/cloke/peel/issues/249) | CSS redundancy detection for frontend projects | 4h | 🟡 Ready |

---

## Swarm & Distributed

**Goal**: Reliable multi-machine agent orchestration.

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#338](https://github.com/cloke/peel/issues/338) | Swarm worker UI does not display task execution logs | 3h | 🔴 Bug (LAN view has logs, Firestore view doesn't) |
| [#193](https://github.com/cloke/peel/issues/193) | Secure Remote Node Control | 6h | 🟡 Ready (basic auth exists, needs security hardening) |

---

## Vision, Voice & Perception

**Goal**: Multi-modal input — screen capture analysis, voice commands, document parsing.

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#35](https://github.com/cloke/peel/issues/35) | Screen capture to Vision analysis pipeline | 6h | 🟡 Ready |
| [#36](https://github.com/cloke/peel/issues/36) | Voice commands via on-device Whisper | 6h | 🟡 Ready |
| [#109](https://github.com/cloke/peel/issues/109) | Voice notifications + quick reply commands | 4h | ⚪ Blocked (depends on #36) |
| [#246](https://github.com/cloke/peel/issues/246) | Native document parsing with Heron layout model + Vision OCR | 6h | 🟡 Ready |

---

## Agent Infrastructure

**Goal**: Safety, cost control, and reliability for autonomous agents.

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#23](https://github.com/cloke/peel/issues/23) | XPC tool broker | 6h | 🟡 Ready |
| [#41](https://github.com/cloke/peel/issues/41) | Budget-aware agent scheduler | 6h | 🟡 Ready |
| [#43](https://github.com/cloke/peel/issues/43) | Deterministic replay for agent runs | 6h | 🟡 Ready |
| [#44](https://github.com/cloke/peel/issues/44) | Multi-agent quorum for destructive actions | 4h | ⚪ Blocked (depends on #43) |

---

## Hardware & Performance

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#107](https://github.com/cloke/peel/issues/107) | GPU shared cache service | 6h | 🟡 Ready |
| [#108](https://github.com/cloke/peel/issues/108) | ANE micro-services for fast local agent tasks | 6h | 🟡 Ready |

---

## MCP & Tooling

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#91](https://github.com/cloke/peel/issues/91) | VS Code extension for MCP tool discovery | 4h | 🟡 Ready — Would help agents discover and use Peel MCP tools more easily vs relying on copilot-instructions.md |

---

## Architecture Reference

### MCP Chain Flow
```
User Prompt
    ↓
MCPServerService (~70 tools)
    ↓
Planner Agent → Task Split
    ↓
+--------+--------+--------+
| Agent1 | Agent2 | Agent3 |  (parallel worktrees)
+--------+--------+--------+
    ↓
Gate Agent → Automated Review
    ↓
Merge Agent → Feature Branch
```

### Local RAG Flow
```
File Scanner → AST Chunker → MLX Embeddings → SQLite Store
                                                   ↓
                                       Query → Top-K Results
                                                   ↓
                                       Agent Prompt Injection
```

### Swarm Flow
```
Brain (MacBook)                    Worker (Mac Studio)
      │                                     │
      ├── P2P/LAN ─────────────────────────►│
      │   (Bonjour + TCP)                   ├── Execute Chain
      │                                     │
      ├── Firestore (WAN fallback) ────────►│
      │                                     │
      │◄──────────── Results ───────────────┤
```

---

## References

- [MCP_AGENT_WORKFLOW.md](guides/MCP_AGENT_WORKFLOW.md) - MCP usage guide
- [LOCAL_RAG_PLAN.md](LOCAL_RAG_PLAN.md) - RAG architecture
- [PII_SCRUBBER_DESIGN.md](PII_SCRUBBER_DESIGN.md) - Privacy scrubbing
- [VM_ISOLATED_EXECUTION_PLAN.md](VM_ISOLATED_EXECUTION_PLAN.md) - VM isolation design
- [VM_YOLO_AGENT_PLAN.md](VM_YOLO_AGENT_PLAN.md) - VM agent execution
- [FIRESTORE_SWARM_DESIGN.md](FIRESTORE_SWARM_DESIGN.md) - Distributed swarm
- [Archive/CLOSED_ISSUES.md](Archive/CLOSED_ISSUES.md) - Completed work

---

**Last Updated**: February 26, 2026
