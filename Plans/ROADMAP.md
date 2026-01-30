---
title: Peel Roadmap
status: active
tags:
  - roadmap
  - peel
  - agent-orchestration
  - mcp
updated: 2026-01-25
last_health_check: 2026-01-25
audience:
  - ai-agent
  - developer
---

# Peel Roadmap

> **Sprint Model**: One forever sprint. Treat "days" as **hours** of focused work.
> 
> **Archived Issues**: See [Plans/Archive/CLOSED_ISSUES.md](Archive/CLOSED_ISSUES.md)

---

## Quick Stats (Jan 30, 2026)

| Metric | Count |
|--------|-------|
| **Closed** | 79 ✅ |
| **Open - Phase 2** | 5 |
| **Open - Phase 3 (Code Intelligence)** | 6 |
| **Open - Swarm/Distributed** | 21 |
| **Open - Backlog** | 23 |
| **Total Open** | 55 |

### Recent Changes
- ✅ **#174** - Structural queries COMPLETE
  - Schema v6 with `line_count`, `method_count`, `byte_size`
  - MCP tool: `rag.structural` (query files by structure)
- ✅ **#175** - Similar code detection COMPLETE
  - `findSimilarCode` with vector similarity search
  - MCP tool: `rag.similar` (find semantically similar code)
- ✅ **#176** - Dependency graph indexing COMPLETE
  - Schema v5 with `dependencies` table
  - MCP tools: `rag.dependencies`, `rag.dependents`
  - Dependency Graph UI in RAG dashboard
- ✅ **#208** - Created for dependency polish (symbol resolution)
- 🎉 **Phase 3 Layer 2** - Code Intelligence Graph COMPLETE

---

## Phase 1C: Polish & MCP Reliability

**Goal**: Make MCP chains reliable for daily use. RAG integration. UX polish.

### Track A: RAG Integration (Critical Path)

These issues build on each other - complete in order.

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#139](https://github.com/cloke/peel/issues/139) | Add diff-only mode to rag-pattern-check | 1h | None | ✅ Complete |
| 2 | [#127](https://github.com/cloke/peel/issues/127) | Add Local RAG results UX | 2h | None | 🟡 Ready |
| 3 | [#136](https://github.com/cloke/peel/issues/136) | Dogfood RAG UX: session insights | 2h | #127 | ⚪ Blocked |
| 4 | [#130](https://github.com/cloke/peel/issues/130) | Document Local RAG model acquisition | 2h | None | 🟡 Ready |
| 5 | [#132](https://github.com/cloke/peel/issues/132) | RAG loop test workflow | 2h | #127 | ✅ Complete |
| 6 | [#134](https://github.com/cloke/peel/issues/134) | Project audit tooling | 3h | #132 | ✅ Complete |
| 7 | [#141](https://github.com/cloke/peel/issues/141) | RAG Indexing Performance Optimization | 3h | None | 🟡 Ready |
| 8 | [#78](https://github.com/cloke/peel/issues/78) | Parallel runner with RAG grounding | 4h | #127 | ⚪ Blocked |
| 9 | [#87](https://github.com/cloke/peel/issues/87) | RAG feedback for CI failures | 3h | #78 | ⚪ Blocked |

**Track A Total**: ~22h

### Track B: MCP Packaging & Tools

Independent work that prepares MCP for extraction.

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#121](https://github.com/cloke/peel/issues/121) | Split MCPServerService by tool category | 4h | None | 🟡 Ready |
| 2 | [#80](https://github.com/cloke/peel/issues/80) | Extract MCP tool registry into package | 3h | #121 | ⚪ Blocked |
| 3 | [#138](https://github.com/cloke/peel/issues/138) | Document MCP tool permissions | 2h | None | ✅ Complete |
| 4 | [#85](https://github.com/cloke/peel/issues/85) | CLI: safe polling helper for MCP runs | 2h | None | ✅ Complete |
| 5 | [#140](https://github.com/cloke/peel/issues/140) | Add Prompt Rules UI in Settings | 2h | None | 🟠 Partial (UI only) |

**Track B Total**: ~13h

### Track C: UX Polish

Can be done in any order, low dependencies.

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#83](https://github.com/cloke/peel/issues/83) | Cohesive Workspaces/Worktrees navigation | 3h | None | 🟡 Ready |
| 2 | [#29](https://github.com/cloke/peel/issues/29) | Add Review with Agent button for PRs | 3h | None | 🟡 Ready |
| 3 | [#30](https://github.com/cloke/peel/issues/30) | Add merge conflict resolution UI | 4h | None | 🟡 Ready |
| 4 | [#52](https://github.com/cloke/peel/issues/52) | Fix screenshot capture vibrancy | 2h | None | ✅ Complete |
| 5 | [#64](https://github.com/cloke/peel/issues/64) | Add Homebrew activity charts | 2h | None | ⏸ Deferred |
| 6 | [#40](https://github.com/cloke/peel/issues/40) | Agent feedback loop - watch and retry | 4h | None | ⏸ Deferred |

**Track C Total**: ~18h

**Phase 1C Grand Total**: ~53h (~7 days focused work)

---

## Phase 2: Local AI Foundation

**Goal**: Run AI locally for cost/privacy. XPC isolation for safety.

**Prerequisite**: Phase 1C RAG integration complete.

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#24](https://github.com/cloke/peel/issues/24) | MLX integration | 8h | None | ✅ Complete |
| 2 | [#128](https://github.com/cloke/peel/issues/128) | Add Hugging Face reranking for RAG | 4h | #24 | 🟡 Ready |
| 3 | [#133](https://github.com/cloke/peel/issues/133) | Pre-planner using RAG | 4h | #24 | 🟡 Ready |
| 4 | [#23](https://github.com/cloke/peel/issues/23) | XPC tool broker | 6h | None | 🟡 Ready |
| 5 | [#41](https://github.com/cloke/peel/issues/41) | Budget-aware agent scheduler | 6h | #24 | 🟡 Ready |
| 6 | [#108](https://github.com/cloke/peel/issues/108) | ANE micro-services | 6h | #24 | 🟡 Ready |

**Phase 2 Total**: ~26h (~3-4 days focused work) - *MLX done!*

---

## Phase 3: Code Intelligence System (RAG/Graph)

**Goal**: Build a 3-layer Code Intelligence System that enables large refactors and cross-language reasoning.

**Tracking Issue**: [#205](https://github.com/cloke/peel/issues/205) - Code Intelligence System

**Prerequisite**: Phase 2 MLX integration complete (✅).

### Layer 1: Raw Facts (Classic RAG) ✅ COMPLETE
- ✅ AST-based chunking (Swift, Ruby, TypeScript/JS)
- ✅ MLX embeddings
- ✅ Vector search + text search
- ✅ Basic metadata extraction (imports, decorators, frameworks)
- ✅ Module path + feature tag facets

### Layer 2: Code Intelligence Graph ✅ COMPLETE

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#176](https://github.com/cloke/peel/issues/176) | Dependency graph indexing | 6h | None | ✅ **COMPLETE** |
| 2 | [#208](https://github.com/cloke/peel/issues/208) | Dependency polish (symbols, stats) | 3h | #176 | 🟡 Ready |
| 3 | [#174](https://github.com/cloke/peel/issues/174) | Structural queries (file size, methods) | 3h | #176 | ✅ **COMPLETE** |
| 4 | [#175](https://github.com/cloke/peel/issues/175) | Duplicate/similar code detection | 4h | None | ✅ **COMPLETE** |
| 5 | [#179](https://github.com/cloke/peel/issues/179) | tree-sitter-swift evaluation | 4h | None | 🟡 Ready (stretch) |

### Layer 3: Semantic Memory

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#198](https://github.com/cloke/peel/issues/198) | MLX-first code analyzer | 6h | Layer 2 | ⚪ Blocked |
| 2 | [#128](https://github.com/cloke/peel/issues/128) | HuggingFace reranking | 4h | None | 🟡 Ready |
| 3 | [#133](https://github.com/cloke/peel/issues/133) | Pre-planner using RAG | 4h | #128 | ⚪ Blocked |

### Infrastructure & Polish

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#163](https://github.com/cloke/peel/issues/163) | Qwen3 GPU crash workaround | 2h | None | 🔴 Bug (low priority) |
| 2 | [#168](https://github.com/cloke/peel/issues/168) | Nightly shared RAG index sync | 4h | Layer 2 | ⚪ Blocked |
| 3 | [#206](https://github.com/cloke/peel/issues/206) | Peel sync for RAG artifacts | 4h | #168 | ⚪ Blocked |

**Phase 3 Total**: ~41h (~5 days focused work)

### Critical Path for Phase 3

```
#176 (Dependency Graph) ✅ ──► #174 (Structural Queries) ✅ ──► #198 (MLX Analyzer)
         │                                                        │
         └──► #208 (Polish)                                       │
                                                                  │
#175 (Similar Code) ✅ ──────────────────────────────────────────┘
                                                                  │
#128 (HF Reranking) ──► #133 (Pre-planner) ──────────────────────┘
```

**Layer 2 Complete!** Next focus: #198 (MLX code analyzer) or #128 (HF reranking)

---

## Phase 3B: Isolation & Voice (Stretch)

**Goal**: VMs for full isolation. Voice/vision input.

**Note**: Deprioritized to focus on Code Intelligence. Can run in parallel if time permits.

### Track A: VM Isolation

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#106](https://github.com/cloke/peel/issues/106) | macOS VM for Xcode isolation | 8h | None | 🟡 Ready |
| 2 | [#107](https://github.com/cloke/peel/issues/107) | GPU shared cache service | 6h | #24 | 🟡 Ready |

### Track B: Voice/Vision

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#35](https://github.com/cloke/peel/issues/35) | Screen capture to Vision analysis | 6h | None | 🟡 Ready |
| 2 | [#36](https://github.com/cloke/peel/issues/36) | Voice commands via Whisper | 6h | #24 | 🟡 Ready |
| 3 | [#109](https://github.com/cloke/peel/issues/109) | Voice notifications + quick reply | 4h | #36 | ⚪ Blocked |

### Track C: Multi-Agent

| Order | # | Title | Est | Deps | Status |
|-------|---|-------|-----|------|--------|
| 1 | [#43](https://github.com/cloke/peel/issues/43) | Deterministic replay for agent runs | 6h | None | 🟡 Ready |
| 2 | [#44](https://github.com/cloke/peel/issues/44) | Multi-agent quorum for destructive actions | 4h | #43 | ⚪ Blocked |
| 3 | [#37](https://github.com/cloke/peel/issues/37) | Cross-machine distributed actors | 8h | #106 | ⚪ Blocked |

**Phase 3B Total**: ~48h (~6 days focused work)

---

## Phase 4: Distributed Task Execution (CloudKit)

**Goal**: Offload compute to other machines (Mac Studio) via CloudKit.

**Prerequisite**: Phase 3 isolation patterns established.

These issues form a logical implementation sequence:

### Stage 1: Design & Schema (do first)
| # | Title | Est |
|---|-------|-----|
| [#143](https://github.com/cloke/peel/issues/143) | CloudKit schema design | 4h |
| [#150](https://github.com/cloke/peel/issues/150) | Task types + payload spec | 3h |
| [#148](https://github.com/cloke/peel/issues/148) | Security + auth model | 4h |
| [#154](https://github.com/cloke/peel/issues/154) | CloudKit limits + cost analysis | 2h |

### Stage 2: Core Protocol
| # | Title | Est |
|---|-------|-----|
| [#144](https://github.com/cloke/peel/issues/144) | Leasing + heartbeat protocol | 4h |
| [#151](https://github.com/cloke/peel/issues/151) | Failure modes + retries | 4h |
| [#152](https://github.com/cloke/peel/issues/152) | Observability + metrics | 3h |

### Stage 3: Implementation
| # | Title | Est |
|---|-------|-----|
| [#145](https://github.com/cloke/peel/issues/145) | Peel daemon prototype (Mac Studio) | 6h |
| [#146](https://github.com/cloke/peel/issues/146) | Client submit + result sync | 4h |
| [#142](https://github.com/cloke/peel/issues/142) | Distributed task execution via CloudKit | 6h |

### Stage 4: UX & Polish
| # | Title | Est |
|---|-------|-----|
| [#147](https://github.com/cloke/peel/issues/147) | CloudKit sharing UX | 3h |
| [#153](https://github.com/cloke/peel/issues/153) | UI flows (macOS/iOS) | 4h |
| [#155](https://github.com/cloke/peel/issues/155) | Dev tooling + test harness | 4h |

### Stage 5: Production Ready
| # | Title | Est |
|---|-------|-----|
| [#156](https://github.com/cloke/peel/issues/156) | Peel packaging + background scheduling | 4h |
| [#157](https://github.com/cloke/peel/issues/157) | Entitlements + sandbox review | 3h |
| [#149](https://github.com/cloke/peel/issues/149) | LAN direct transport (optional) | 6h |

**Phase 4 Total**: ~64h (~8 days focused work)

---

## Backlog (Unscheduled)

These are valid ideas not yet prioritized. Pick from here when phases complete.

### MCP & Agent Polish
| # | Title | Category |
|---|-------|----------|
| [#90](https://github.com/cloke/peel/issues/90) | Decide how to package repo guidance skills defaults | mcp |
| [#91](https://github.com/cloke/peel/issues/91) | VS Code extension for MCP parallel batching | mcp |
| [#92](https://github.com/cloke/peel/issues/92) | Parallel run quality check run | mcp |
| [#93](https://github.com/cloke/peel/issues/93) | Guardrails for low-signal parallel runs | mcp |
| [#94](https://github.com/cloke/peel/issues/94) | Reduce plan-only responses in templates | mcp |

### Infrastructure & Refactoring
| # | Title | Category |
|---|-------|----------|
| [#99](https://github.com/cloke/peel/issues/99) | Audit target membership for macOS-only files | infra |
| [#100](https://github.com/cloke/peel/issues/100) | Refactor CopilotModel metadata mapping | infra |
| [#102](https://github.com/cloke/peel/issues/102) | Unify model family and helper flags | infra |
| [#103](https://github.com/cloke/peel/issues/103) | Extract AgentRole system prompts | infra |
| [#104](https://github.com/cloke/peel/issues/104) | Refactor AgentState UI metadata | infra |
| [#122](https://github.com/cloke/peel/issues/122) | Split WorktreeListView into separate files | infra |

### UX & Git
| # | Title | Category |
|---|-------|----------|
| [#96](https://github.com/cloke/peel/issues/96) | VM Viewer: aspect-fit scaling still clips | bug |
| [#97](https://github.com/cloke/peel/issues/97) | VM Isolation: add segmented tabs | ux |
| [#105](https://github.com/cloke/peel/issues/105) | Define iOS GitHub review flow | ux |
| [#110](https://github.com/cloke/peel/issues/110) | Refactor diff viewer for modern UI | git |
| [#111](https://github.com/cloke/peel/issues/111) | Add per-repo scratch area for artifacts | infra |
| [#112](https://github.com/cloke/peel/issues/112) | Git diff: stage/revert hunk actions | git |

### VM (Stretch)
| # | Title | Category |
|---|-------|----------|
| [#95](https://github.com/cloke/peel/issues/95) | VM Isolation: pooled preconfigured macOS VMs | infra |

---

## Recommended Work Order

For maximum efficiency, work these in parallel where possible:

### Week 1 (Now → ~8h)
**Focus: Quick wins + RAG foundation**

| Track | Issues | Hours |
|-------|--------|-------|
| RAG | #139 (diff-only), #127 (UX), #141 (perf) | 6h |
| MCP | #138 (docs), #140 (prompt UI) | 4h |

### Week 2 (~8h)
**Focus: RAG completion + MCP extraction**

| Track | Issues | Hours |
|-------|--------|-------|
| RAG | #136 (dogfood), #130 (docs), #132 (test) | 6h |
| MCP | #121 (split service), #85 (polling) | 6h |

### Week 3 (~8h)
**Focus: UX polish + parallel runner**

| Track | Issues | Hours |
|-------|--------|-------|
| UX | #83 (nav), #29 (review btn), #52 (screenshot) | 8h |
| RAG | #78 (parallel runner) | 4h |

### Week 4 (~8h)
**Focus: Complete Phase 1C**

| Track | Issues | Hours |
|-------|--------|-------|
| RAG | #134 (audit), #87 (CI feedback) | 6h |
| MCP | #80 (extract registry) | 3h |
| UX | #30 (merge UI), #64 (brew charts) | 6h |

### Week 5+ 
**Phase 2 begins** - MLX, XPC, HuggingFace integration

---

## Architecture Reference

### MCP Chain Flow
```
User Prompt
    ↓
MCPServerService (66 tools)
    ↓
Planner Agent → Task Split
    ↓
+--------+--------+--------+
| Agent1 | Agent2 | Agent3 |  (parallel worktrees)
+--------+--------+--------+
    ↓
Merge Agent → Feature Branch
    ↓
Review Gate
```

### Local RAG Flow
```
File Scanner → Chunker → Embeddings → SQLite Store
                                          ↓
                              Query → Top-K Results
                                          ↓
                              Agent Prompt Injection
```

### Distributed Tasks Flow (Phase 4)
```
Crown (MacBook)                      Peel (Mac Studio)
      │                                     │
      ├─── CKRecord (task) ────────────────►│
      │                                     ├─── Lease + Execute
      │◄───────────── CKRecord (result) ────┤
      │                                     │
      └─── Poll / Subscribe ────────────────┘
```

---

## References

- [MCP_AGENT_WORKFLOW.md](MCP_AGENT_WORKFLOW.md) - MCP usage guide
- [LOCAL_RAG_PLAN.md](LOCAL_RAG_PLAN.md) - RAG architecture
- [PII_SCRUBBER_DESIGN.md](PII_SCRUBBER_DESIGN.md) - Privacy scrubbing
- [VM_ISOLATION_PLAN.md](VM_ISOLATION_PLAN.md) - VM isolation design
- [Archive/CLOSED_ISSUES.md](Archive/CLOSED_ISSUES.md) - Completed work

---

**Last Updated**: January 25, 2026
