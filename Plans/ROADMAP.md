---
title: Peel Roadmap
status: active
tags:
  - roadmap
  - peel
  - agent-orchestration
  - mcp
updated: 2026-01-25
last_health_check: 2026-01-23
audience:
  - ai-agent
  - developer
---

# Peel Roadmap

> **Sprint Model**: One forever sprint. Treat "days" as hours of focused work.

---

## Quick Stats (Jan 25, 2026)

| Phase | Status | Issues |
|-------|--------|--------|
| 1C: Polish | 🔄 Active | ~19 |
| 2: Local AI | 📋 Next | ~5 |
| 3: Isolation | 📋 Future | ~8 |
| Backlog | 📋 Unscheduled | ~24 |

**Recently Completed (Jan 25 session):**
- #84 MCP prompt rules + guardrails (chains.promptRules.get/set tools)
- #135 Relaunch storms fix (lock file mechanism)
- #88 Hung execution detection (already implemented, verified)
- #125 RAG pattern index (already existed)
- #126 RAG-based pattern check (PeelCLI rag-pattern-check)
- #129 Use RAG index for checks (integrated)
- #113 Git sidebar jitter fix
- #89 parallel.status 404s fix (snapshot fallback)
- #137 RAG toggle in UI
- #131 MCP tool preset onboarding
- #124 PeelUI button styles
- #123 AsyncContentView adoption verified

---

## Implementation Queue (Prioritized)

### 🔥 Priority 1: Bugs & Stability (do first)

All bugs resolved! ✅

### 🎯 Priority 2: MCP + RAG Integration (main track)

| # | Issue | Est | Dependencies |
|---|-------|-----|--------------|
| 1 | [#78](https://github.com/cloke/peel/issues/78) Parallel runner with RAG grounding | 4h | None |
| 2 | [#87](https://github.com/cloke/peel/issues/87) RAG feedback for CI failures | 3h | #78 |
| 3 | [#139](https://github.com/cloke/peel/issues/139) Diff-only pattern check | 1h | None |

### 🛠️ Priority 3: MCP Packaging (prep for reuse)

| # | Issue | Est | Dependencies |
|---|-------|-----|--------------|
| 5 | [#79](https://github.com/cloke/peel/issues/79) MCP tool permissions interface | 3h | None |
| 6 | [#80](https://github.com/cloke/peel/issues/80) Extract tool registry | 3h | #79 |
| 7 | [#121](https://github.com/cloke/peel/issues/121) Split MCPServerService | 4h | Helps #80 |

### 📊 Priority 4: UX Polish

| # | Issue | Est | Dependencies |
|---|-------|-----|--------------|
| 8 | [#127](https://github.com/cloke/peel/issues/127) Local RAG results UX | 2h | None |
| 9 | [#136](https://github.com/cloke/peel/issues/136) RAG session insights | 2h | #127 |
| 10 | [#138](https://github.com/cloke/peel/issues/138) Document MCP permissions | 2h | #79 |
| 11 | [#83](https://github.com/cloke/peel/issues/83) Workspaces/Worktrees nav | 3h | None |
| 20 | [#29](https://github.com/cloke/peel/issues/29) Review with Agent button | 3h | None |
| 21 | [#30](https://github.com/cloke/peel/issues/30) Merge conflict UI | 4h | None |

### 🔮 Priority 5: Phase 2 - Local AI Foundation

| # | Issue | Est | Dependencies |
|---|-------|-----|--------------|
| 22 | [#74](https://github.com/cloke/peel/issues/74) Core ML embedding provider | 4h | None |
| 23 | [#23](https://github.com/cloke/peel/issues/23) XPC tool broker | 6h | #79 |
| 24 | [#24](https://github.com/cloke/peel/issues/24) MLX integration | 8h | None |
| 25 | [#133](https://github.com/cloke/peel/issues/133) Pre-planner with HF RAG | 4h | #128 |
| 26 | [#128](https://github.com/cloke/peel/issues/128) HF model analysis for RAG | 4h | #24 |
| 27 | [#41](https://github.com/cloke/peel/issues/41) Budget-aware scheduler | 6h | #24 |
| 28 | [#108](https://github.com/cloke/peel/issues/108) ANE micro-services | 6h | #24 |

### 🌐 Priority 6: Phase 3 - Full Isolation

| # | Issue | Est | Dependencies |
|---|-------|-----|--------------|
| 29 | [#106](https://github.com/cloke/peel/issues/106) macOS VM isolation | 8h | None |
| 30 | [#107](https://github.com/cloke/peel/issues/107) GPU shared cache | 6h | #24 |
| 31 | [#35](https://github.com/cloke/peel/issues/35) Vision pipeline | 6h | None |
| 32 | [#36](https://github.com/cloke/peel/issues/36) Voice commands (Whisper) | 6h | #24 |
| 33 | [#109](https://github.com/cloke/peel/issues/109) Voice notifications | 4h | #36 |
| 34 | [#37](https://github.com/cloke/peel/issues/37) Distributed actors | 8h | #106 |
| 35 | [#43](https://github.com/cloke/peel/issues/43) Deterministic replay | 6h | None |
| 36 | [#44](https://github.com/cloke/peel/issues/44) Multi-agent quorum | 4h | #43 |

---

## Phase Definitions

### Phase 1C: Polish & MCP Reliability
**Goal**: Make MCP chains reliable for daily use. RAG integration. UX polish.

**Labels**: `phase-1c`

**Key Outcomes**:
- MCP chains don't hang or produce stale UI
- RAG provides relevant code context to agents
- Tool permissions are clear and configurable

### Phase 2: Local AI Foundation
**Goal**: Run AI locally for cost/privacy. XPC isolation for safety.

**Labels**: `phase-2`

**Key Outcomes**:
- MLX models run locally
- XPC broker isolates dangerous operations
- Budget scheduler manages resources

### Phase 3: Full Isolation & Scale
**Goal**: VMs for full isolation. Multi-machine scale. Voice/vision.

**Labels**: `phase-3`

**Key Outcomes**:
- macOS VMs for Xcode isolation
- Distributed actors across machines
- Voice commands for hands-free operation

---

## Backlog (Unscheduled)

These issues are valid but not prioritized for current phases:

| Issue | Title | Category |
|-------|-------|----------|
| [#40](https://github.com/cloke/peel/issues/40) | Agent feedback loop | agent |
| [#52](https://github.com/cloke/peel/issues/52) | Screenshot vibrancy | ux |
| [#64](https://github.com/cloke/peel/issues/64) | Homebrew charts | ux |
| [#85](https://github.com/cloke/peel/issues/85) | CLI polling helper | mcp |
| [#86](https://github.com/cloke/peel/issues/86) | MCP rejected count | mcp |
| [#90](https://github.com/cloke/peel/issues/90) | Repo guidance defaults | mcp |
| [#91](https://github.com/cloke/peel/issues/91) | VS Code MCP extension | mcp |
| [#92](https://github.com/cloke/peel/issues/92) | Parallel quality check | mcp |
| [#93](https://github.com/cloke/peel/issues/93) | Low-signal guardrails | agent |
| [#94](https://github.com/cloke/peel/issues/94) | Reduce plan-only responses | agent |
| [#95](https://github.com/cloke/peel/issues/95) | Pooled macOS VMs | infra |
| [#96](https://github.com/cloke/peel/issues/96) | VM viewer scaling | bug |
| [#97](https://github.com/cloke/peel/issues/97) | VM section tabs | ux |
| [#99](https://github.com/cloke/peel/issues/99) | Target membership audit | infra |
| [#100](https://github.com/cloke/peel/issues/100) | CopilotModel metadata | infra |
| [#102](https://github.com/cloke/peel/issues/102) | Model family flags | infra |
| [#103](https://github.com/cloke/peel/issues/103) | AgentRole prompts | agent |
| [#104](https://github.com/cloke/peel/issues/104) | AgentState metadata | agent |
| [#105](https://github.com/cloke/peel/issues/105) | iOS GitHub flow | ux |
| [#110](https://github.com/cloke/peel/issues/110) | Diff viewer refresh | git |
| [#111](https://github.com/cloke/peel/issues/111) | Per-repo scratch area | infra |
| [#112](https://github.com/cloke/peel/issues/112) | Stage/revert hunks | git |
| [#122](https://github.com/cloke/peel/issues/122) | Split WorktreeListView | infra |
| [#123](https://github.com/cloke/peel/issues/123) | Adopt AsyncContentView | ux |
| [#124](https://github.com/cloke/peel/issues/124) | PeelUI button styles | ux |
| [#130](https://github.com/cloke/peel/issues/130) | RAG model docs | documentation |
| [#132](https://github.com/cloke/peel/issues/132) | RAG loop test workflow | rag |
| [#134](https://github.com/cloke/peel/issues/134) | Project audit tooling | rag |

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

---

## References

- [MCP_AGENT_WORKFLOW.md](MCP_AGENT_WORKFLOW.md) - MCP usage guide
- [LOCAL_RAG_PLAN.md](LOCAL_RAG_PLAN.md) - RAG architecture
- [PII_SCRUBBER_DESIGN.md](PII_SCRUBBER_DESIGN.md) - Privacy scrubbing
- [VM_ISOLATION_PLAN.md](VM_ISOLATION_PLAN.md) - VM isolation design

---

**Last Updated**: January 25, 2026
