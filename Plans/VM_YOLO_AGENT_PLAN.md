# VM Yolo Agent — Sandboxed Agent Chains

**Status:** Planning  
**Phase:** 3 (VM Isolation)  
**Created:** 2026-02-20

## Summary

Run AI coding agents (copilot, claude, aider, or any CLI) **fully inside the Linux VM** with yolo-mode autonomy, while the VM can query back to Peel's RAG service on the host via HTTP. This gives "gh copilot `--yolo`" safety — the agent can do anything inside the VM (edit files, install packages, run tests) without risk to the host.

This is exposed in Peel as **Yolo Templates** — a new template category where the agent runs in the sandbox rather than on the host.

## Architecture

```
┌──────────────── HOST (macOS) ─────────────────┐
│                                                │
│  Peel MCP Server (port 8765)                   │
│  ├─ rag.search / rag.index / rag.status        │
│  ├─ VM IP allowlist (auto-scoped per chain)    │
│  └─ Tool-scoped: VM can only call rag.* tools  │
│                                                │
│  AgentChainRunner                              │
│  ├─ StepType.vmAgentic (NEW)                   │
│  │   → boots VM, installs agent, runs it       │
│  │   → streams output, captures exit code      │
│  └─ Existing .gate / .deterministic steps      │
│                                                │
│  VirtioFS shares (r/w workspace)               │
└───────────┬────────────────────────────────────┘
            │ NAT + VirtioFS
┌───────────▼────────────────────────────────────┐
│            LINUX VM (Alpine)                    │
│                                                │
│  ENV: PEEL_HOST_IP, PEEL_MCP_PORT, GH_TOKEN    │
│                                                │
│  Agent CLI (any: copilot/claude/aider/custom)  │
│  ├─ Full autonomy — yolo mode                  │
│  ├─ Reads/writes /workspace (VirtioFS)         │
│  ├─ Can install packages, run builds/tests     │
│  └─ Queries RAG via:                           │
│     curl http://$PEEL_HOST_IP:8765/rpc         │
│     -d '{"method":"tools/call","params":{      │
│       "name":"rag.search","arguments":{...}}}' │
│                                                │
│  /usr/local/bin/peel-rag (helper script)       │
│  └─ peel-rag search "how does auth work"       │
└────────────────────────────────────────────────┘
```

## Key Design Decisions

1. **Any-agent-CLI**: Generic `VMAgentConfig` with factory presets — not locked to one tool
2. **Direct MCP HTTP callback**: Agent uses curl or `peel-rag` wrapper to query host:8765 for RAG
3. **Auto VM IP allowlist**: Only the VM's IP is allowed, only during chain execution, only for `rag.*` tools
4. **Yolo template category**: User-facing concept in the template gallery — "Yolo Templates" run the agent in the VM sandbox
5. **Extended timeouts**: Agent CLIs can run for minutes; default 600s vs 30s for deterministic steps
6. **`peel-rag` helper**: Shell wrapper injected into VM that simplifies RAG queries for agents

## Implementation Issues

| # | Title | Scope | Depends On |
|---|-------|-------|------------|
| [#311](https://github.com/cloke/peel/issues/311) | VMAgentConfig model + StepType.vmAgentic | Core model changes (ChainTemplate.swift) | — |
| [#312](https://github.com/cloke/peel/issues/312) | Host IP injection + peel-rag helper | VM init script, RAG callback infrastructure | — |
| [#313](https://github.com/cloke/peel/issues/313) | VM IP allowlist + tool scoping | MCP server security (MCPServerService+ServerCore.swift) | — |
| [#314](https://github.com/cloke/peel/issues/314) | runVMAgenticStep() implementation | Core execution engine (AgentChainRunner.swift) | #311 |
| [#315](https://github.com/cloke/peel/issues/315) | VMChainExecutor integration | Wire VM boot → IP registration → agent run → teardown | #312, #313 |
| [#316](https://github.com/cloke/peel/issues/316) | Yolo template category + built-in templates | TemplateCategory.yolo, 4 new built-in templates | #311, #314 |
| [#317](https://github.com/cloke/peel/issues/317) | Agent binary management | Download/cache/verify agent CLIs for Linux VM | #314 |
| [#318](https://github.com/cloke/peel/issues/318) | vm.agent.run MCP tool | Ad-hoc VM agent invocation outside chains | #314, #315 |

### Dependency Graph

```
#311 (VMAgentConfig) ──┬──▶ #314 (runVMAgenticStep) ──┬──▶ #316 (Yolo Templates)
                       │                               ├──▶ #317 (Agent Binary Mgmt)
#312 (Host IP/peel-rag)┼──▶ #315 (VMChainExecutor) ───┤
#313 (VM IP Allowlist) ─┘                               └──▶ #318 (vm.agent.run)
```

### Suggested Order

1. **Parallel** — #311, #312, #313 (no dependencies, can be done simultaneously)
2. **Then** — #314 (needs #311)
3. **Then parallel** — #315 (needs #312, #313), #316 (needs #311, #314)
4. **Then** — #317, #318 (polish, can be done last)

## Security Model

- Agent runs in an ephemeral Alpine Linux VM — no access to host filesystem except VirtioFS shares
- VirtioFS workspace share is read-write (agent needs to edit code)
- MCP server only accepts the VM's specific IP, only during chain execution
- VM connections are tool-scoped: only `rag.*` tools are accessible (blocks `chains.*`, `vm.*`, `server.*`)
- VM is torn down after chain completes — no persistent state
- Code changes exist in a git worktree — reviewed before merging

## Dependencies

- Linux VM must be functional (✅ done — commit 1c1225a)
- NAT networking must work (✅ done)
- VirtioFS sharing must work (✅ done)
- MCP server must be running (✅ done)
- Agent CLIs must have Linux arm64 builds (copilot ✅, claude ✅, aider ✅)
