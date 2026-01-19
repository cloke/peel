---
title: Peel Roadmap
status: active
tags:
  - roadmap
  - peel
  - agent-orchestration
  - mcp
updated: 2026-01-19
audience:
  - ai-agent
  - developer
github_issues:
  - number: 8
    status: open
    title: Create PII scrubber CLI tool
  - number: 13
    status: closed
    title: Add validation pipeline for MCP runs
  - number: 16
    status: open
    title: MCP activity log + cleanup actions
  - number: 17
    status: closed
    title: Planner gating - skip implementers when no work needed
  - number: 18
    status: closed
    title: Show planner prompt in MCP Run detail view
  - number: 19
    status: closed
    title: Clarify Assign Task button behavior
  - number: 21
    status: open
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
    status: open
    title: Dynamic chain scaling and model selection
code_locations:
  - file: Shared/AgentOrchestration/AgentManager.swift
    lines: 260-500
    description: AgentChainRunner and parallel execution
  - file: Shared/AgentOrchestration/MCPTemplateExecutor.swift
    description: MCP chain template execution
  - file: Shared/Views/SettingsView.swift
    description: MCP server toggle and settings
related_docs:
  - AGENT_ORCHESTRATION_PLAN.md
  - PARALLEL_AGENTS_PLAN.md
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

### 🟡 In Progress (Phase 1C)

| Area | Open Issue | Gap |
|------|------------|-----|
| **MCP Activity Log** | [#16](https://github.com/cloke/peel/issues/16) | Persist/display run history, cleanup actions |

### 📋 Future

| Feature | Phase | Notes |
|---------|-------|-------|
| PII Scrubber | 2 | [#8](https://github.com/cloke/peel/issues/8) - High value standalone tool |
| XPC Tool Brokers | 2 | Isolated tool execution |
| MLX Integration | 2 | Local inference |
| macOS VM | 3 | Full Xcode isolation |
| Vision/Screen Capture | 3 | Multimodal agent input |

---

## Active Work: Phase 1C

### MCP Activity Log + Cleanup ([#16](https://github.com/cloke/peel/issues/16))
- Persist MCP run history (SwiftData)
- Display in MCP Activity dashboard
- Cleanup actions for worktrees/branches

**Recent progress:**
- Added `chains.stop` MCP endpoint to cancel active chain runs
- Enforced `workingDirectory` for `chains.run` to prevent whole-disk scans
- Added streaming diagnostics for missing usage marker and cancellation logging
- Added parallel chain helper script for async MCP runs (`Tools/run-chains-parallel.sh`)

**Scope (v1):**
- Persist run metadata: chain id, template name, timestamps, status/error, validation summary
- Persist per-agent results for a run (planner/implementers/merge/review)
- MCP Activity list shows recent runs and survives relaunch
- Run detail view shows outputs and validation (prompt tracked under #18)
- Cleanup action removes agent worktrees + branches created by MCP runs
- Safety: confirmation dialog, error surfacing, and non-blocking cleanup
- Retention cap (e.g., last 100 runs) to bound SwiftData growth

**Implementation plan (start):**
1. SwiftData models for run + result records (Shared/SwiftDataModels.swift)
2. DataService helpers: record run, record result, fetch recent, cleanup (Shared/PeelApp.swift)
3. Chain runner hooks: persist run + results on completion (Shared/AgentOrchestration/AgentManager.swift)
4. MCP Activity UI: list + detail binding to SwiftData queries (Shared/Applications/Agents_RootView.swift)
5. Cleanup action: call WorkspaceManager to remove worktrees/branches, surface status/errors in UI
6. Verification: MCP test plan cases 8–9, plus manual relaunch check

### Untracked Phase 1C Items
- [x] Planner gating: skip implementers when "no work" ([#17](https://github.com/cloke/peel/issues/17))
- [x] Show planner prompt in Chain Activity / MCP Run detail ([#18](https://github.com/cloke/peel/issues/18))
- [x] Clarify Assign Task behavior ([#19](https://github.com/cloke/peel/issues/19))
- [ ] MCP screenshot capture tool (enable tighter build/run/inspect loop) ([#21](https://github.com/cloke/peel/issues/21))
- [ ] Dynamic chain scaling + model selection for cost caps ([#25](https://github.com/cloke/peel/issues/25))

**Proposed next targets (Phase 1C):**
1. Verify #16 via MCP test plan cases 8–9
2. Dynamic chain scaling + model selection for cost caps ([#25](https://github.com/cloke/peel/issues/25))
3. MCP screenshot capture tool — optional if we want a tighter automation loop

### Next Steps (Tomorrow)
- [ ] Run MCP test plan cases 8–9 and log results
- [ ] Smoke-test `chains.stop` (cancel single run + cancel all)
- [ ] Validate `chains.run` rejects missing `workingDirectory`
- [x] Investigate on-device prompt optimization (CoreML/ANE learns from MCP logs to refine + compress prompts, per project/language)
- [x] Quick scan of MCP logs for missing-usage marker warnings (2026-01-19)

---

## Phase 2: Local AI Foundation

| Feature | Issue | Description |
|---------|-------|-------------|
| PII Scrubber | [#8](https://github.com/cloke/peel/issues/8) | CLI tool to strip sensitive data before sending to AI |
| MCP Automation Framework | [#22](https://github.com/cloke/peel/issues/22) | Extract MCP server + automation tools into reusable package |
| XPC Tool Broker | [#23](https://github.com/cloke/peel/issues/23) | Sandboxed tool execution via XPC |
| MLX Integration | [#24](https://github.com/cloke/peel/issues/24) | Local model inference for code tasks |

---

## Phase 3: Full Isolation & Scale

| Feature | Description |
|---------|-------------|
| macOS VM | Full Xcode environment isolation |
| VM Task Pipeline | Route tasks to appropriate isolation tier |
| GPU Shared Cache | MLX model caching service |
| ANE Micro-services | Hardware-accelerated inference |

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
