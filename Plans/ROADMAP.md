---
title: Peel Roadmap
status: active
tags:
  - roadmap
  - peel
  - agent-orchestration
  - mcp
updated: 2026-01-18
audience:
  - ai-agent
  - developer
github_issues:
  - number: 8
    status: open
    title: Create PII scrubber CLI tool
  - number: 13
    status: open
    title: Add validation pipeline for MCP runs
  - number: 16
    status: open
    title: MCP activity log + cleanup actions
  - number: 17
    status: open
    title: Planner gating - skip implementers when no work needed
  - number: 18
    status: open
    title: Show planner prompt in MCP Run detail view
  - number: 19
    status: open
    title: Clarify Assign Task button behavior
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
| **Session Tracking** | Premium cost tracking, session summary export |
| **Settings/Preferences** | MCP toggle, port config, status display |

### 🟡 In Progress (Phase 1C)

| Area | Open Issue | Gap |
|------|------------|-----|
| **MCP Validation** | [#13](https://github.com/cloke/peel/issues/13) | Correctness checks for chain runs |
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

### MCP Validation Pipeline ([#13](https://github.com/cloke/peel/issues/13))
Automated correctness checks for chain execution results.

### MCP Activity Log + Cleanup ([#16](https://github.com/cloke/peel/issues/16))
- Persist MCP run history (SwiftData)
- Display in MCP Activity dashboard
- Cleanup actions for worktrees/branches

### Untracked Phase 1C Items
- [ ] Planner gating: skip implementers when "no work" ([#17](https://github.com/cloke/peel/issues/17))
- [ ] Show planner prompt in Chain Activity / MCP Run detail ([#18](https://github.com/cloke/peel/issues/18))
- [ ] Clarify Assign Task behavior ([#19](https://github.com/cloke/peel/issues/19))

---

## Phase 2: Local AI Foundation

| Feature | Issue | Description |
|---------|-------|-------------|
| PII Scrubber | [#8](https://github.com/cloke/peel/issues/8) | CLI tool to strip sensitive data before sending to AI |
| XPC Tool Broker | TBD | Sandboxed tool execution via XPC |
| MLX Integration | TBD | Local model inference for code tasks |

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
