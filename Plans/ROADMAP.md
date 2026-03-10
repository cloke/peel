---
title: Peel Roadmap
status: active
tags:
  - roadmap
  - peel
  - agent-orchestration
  - mcp
updated: 2026-03-10
last_health_check: 2026-03-10
audience:
  - ai-agent
  - developer
---

# Peel Roadmap

> **Sprint Model**: One forever sprint. Treat "days" as **hours** of focused work.
>
> **Archived Issues**: See [Plans/Archive/CLOSED_ISSUES.md](Archive/CLOSED_ISSUES.md)

---

## Quick Stats (Mar 10, 2026)

| Metric | Count |
|--------|-------|
| **Closed** | 316 ✅ |
| **Open** | 27 |
| **Build** | ✅ Clean (0 warnings) |
| **Tests** | ✅ 99 passing |

### Open by Category

| Category | Count | Issues |
|----------|-------|--------|
| **Enterprise PR / Scale (P8)** | 5 | #347, #348, #349, #350, #351 |
| **Enterprise PR Review (P9)** | 4 | #353, #354, #355, #356 |
| **VM Isolation** | 6 | #310, #312, #313, #314, #315, #317 |
| **RAG Enhancements** | 3 | #274, #276, #277 |
| **Skills & Intelligence** | 2 | #335, #336 |
| **Swarm / Distributed** | 1 | #193 |
| **Vision & Voice** | 2 | #35, #36 |
| **PR Hardening** | 1 | #352 |
| **Xcode MCP** | 3 | #363, #364, #365 |

### Recent Completions (since Jan 25)
- ✅ **Issue triage (Mar 10)** — Closed 12 issues: premature optimization (#41, #107, #108), superseded (#23 XPC→VM, #43/#44 replay→gates, #109→#36), scope creep (#91, #205, #246, #249, #275)
- ✅ **Swarm Console inline** — Activity > Open Console replaces modal, Chat tab with Firebase messaging
- ✅ **Activity pagination** — Recent section paginated (50/page) with prev/next controls
- ✅ **Onboarding refresh** — Feature Discovery checklist updated for 2-tab layout
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

## Tier 1: Polish & Harden (do first)

**Goal**: Fix what's broken, finish what's started. Highest ROI.

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#352](https://github.com/cloke/peel/issues/352) | PR Queue Reliability + Performance Optimizations | 4h | 🟡 Ready |
| [#336](https://github.com/cloke/peel/issues/336) | Multi-framework directive detection: generalize beyond Ember | 4h | 🟡 Ready (Ember detection works, needs generalization) |
| [#335](https://github.com/cloke/peel/issues/335) | Live skill updates: download from GitHub and write to .peel/ files | 4h | 🟡 Ready (local init done, remote fetch TODO in code) |
| [#277](https://github.com/cloke/peel/issues/277) | Framework-aware orphan detection (Ember service/route/template) | 4h | 🟡 Ready (generic orphan detection exists, needs Ember awareness) |

---

## Tier 2: VM Pipeline Completion

**Goal**: Run AI coding agents inside sandboxed Linux VMs with full autonomy.

**Foundation done** — VMChainExecutor lifecycle, VirtioFS, MCP tools, templates all implemented.

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#312](https://github.com/cloke/peel/issues/312) | Host IP injection + peel-rag helper script for VM | 3h | 🟠 Partial (IP injection done, helper script missing) |
| [#313](https://github.com/cloke/peel/issues/313) | VM IP allowlist + tool scoping on MCP server | 4h | 🟡 Ready |
| [#317](https://github.com/cloke/peel/issues/317) | Agent binary management: download/cache CLIs for Linux VM | 4h | 🟡 Ready |
| [#314](https://github.com/cloke/peel/issues/314) | Implement `runVMAgenticStep()` in AgentChainRunner | 4h | 🟠 Partial (depends on #312, #313) |
| [#315](https://github.com/cloke/peel/issues/315) | VMChainExecutor: auto-register VM IP with MCP allowlist | 3h | 🟡 Ready (depends on #313) |
| [#310](https://github.com/cloke/peel/issues/310) | VM validation pipeline: isolated build/test in sandboxed VMs | 6h | 🟡 Ready (depends on #314) |

**Dependency chain**: #312 → #313 → #315, and #314 → #310

---

## Tier 3: Enterprise Job Infrastructure (P8)

**Goal**: Reliable job execution at scale with leasing, backpressure, and approval gates.

| # | Title | Est | Depends On |
|---|-------|-----|------------|
| [#347](https://github.com/cloke/peel/issues/347) | PeelJob Envelope and Lifecycle | 4h | — |
| [#348](https://github.com/cloke/peel/issues/348) | Worker Leasing + Heartbeat + Requeue | 4h | #347 |
| [#349](https://github.com/cloke/peel/issues/349) | Backpressure and Concurrency Guardrails | 4h | #347 |
| [#350](https://github.com/cloke/peel/issues/350) | Execution Modes: Single, Batch, Map-Reduce | 4h | #347 |
| [#351](https://github.com/cloke/peel/issues/351) | Approval Gate Policy Engine | 4h | #347 |

---

## Tier 4: Enterprise PR Review (P9)

**Goal**: Multi-repo PR management with agent-assisted review.

| # | Title | Est | Depends On |
|---|-------|-----|------------|
| [#353](https://github.com/cloke/peel/issues/353) | Enterprise PR Ingestion and Index | 6h | P8 complete |
| [#354](https://github.com/cloke/peel/issues/354) | Enterprise PR List UI + Filters | 4h | #353 |
| [#355](https://github.com/cloke/peel/issues/355) | Agent Assignment Orchestration (Single + Bulk) | 4h | #353 |
| [#356](https://github.com/cloke/peel/issues/356) | PR Decision Console + Governance Audit Trail | 4h | #355 |

---

## Tier 5: RAG Enhancements

**Goal**: Deep code analysis beyond structure.

| # | Title | Est | Status |
|---|-------|-----|--------|
| [#274](https://github.com/cloke/peel/issues/274) | Component API surface mapping and usage analysis | 6h | 🟡 Ready |
| [#276](https://github.com/cloke/peel/issues/276) | Cross-repo API endpoint correlation and blast radius | 6h | 🟡 Ready |

---

## Tier 6: Xcode MCP Integration

**Goal**: Xcode as an MCP tool source for agent chains.

| # | Title | Est | Depends On |
|---|-------|-----|------------|
| [#363](https://github.com/cloke/peel/issues/363) | Phase 2: Xcode MCP Basic Integration | 6h | — |
| [#364](https://github.com/cloke/peel/issues/364) | Phase 3: Xcode MCP Advanced Features | 6h | #363 |
| [#365](https://github.com/cloke/peel/issues/365) | Phase 4: Xcode MCP Production Ready | 4h | #364 |

---

## Tier 7: Future / Aspirational

| # | Title | Est | Notes |
|---|-------|-----|-------|
| [#35](https://github.com/cloke/peel/issues/35) | Screen capture to Vision analysis pipeline | 6h | Multi-modal — agent watches its own effects |
| [#36](https://github.com/cloke/peel/issues/36) | Voice commands via on-device Whisper | 6h | Local speech-to-text, no cloud |
| [#193](https://github.com/cloke/peel/issues/193) | Secure Remote Node Control | 6h | Needed for real swarm deployment |

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

**Last Updated**: March 10, 2026
