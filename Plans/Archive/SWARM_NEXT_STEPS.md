---
title: Swarm Distributed Computing - Next Steps
status: active
created: 2026-01-28
updated: 2026-01-30
tags:
  - swarm
  - distributed
  - mcp
audience:
  - developer
  - ai-agent
---

# Swarm Distributed Computing - Next Steps

**Date:** 2026-01-28  
**Status:** Core functionality complete and validated

---

## ✅ What's Working

### Core Swarm Features

| Feature | Status | Notes |
|---------|--------|-------|
| **Crown/Peel Discovery** | ✅ Working | Bonjour/mDNS on `_peel-swarm._tcp` |
| **Peer Connection** | ✅ Working | TCP on port 8766 with length-prefixed JSON |
| **Task Dispatch** | ✅ Working | `swarm.dispatch` sends to least-busy peel |
| **Real Chain Execution** | ✅ Working | Peels execute via LLM with `DefaultChainExecutor` |
| **Direct Commands** | ✅ Working | `swarm.direct-command` returns output synchronously |
| **Peel Self-Update** | ✅ Working | `swarm.update-workers` pulls latest and rebuilds |
| **Version Sync Tracking** | ✅ Working | `gitCommitHash` in capabilities, `inSync` in status |
| **Peel Heartbeats** | ✅ Working | Periodic heartbeat with state, uptime, and task counts |
| **Task Results** | ✅ Working | `swarm.tasks` shows history with durations/outputs |
| **Task Log UI** | ✅ Working | Tasks appear in Mac Studio's task log view |

### MCP Tools Available

```
swarm.start        - Start Crown or Peel mode (roles: brain/worker)
swarm.stop         - Stop swarm participation
swarm.status       - Show role, peels, capabilities
swarm.workers      - List connected peels with status + inSync
swarm.dispatch     - Send task to peel for LLM execution
swarm.tasks        - Query task results/history
swarm.direct-command   - Execute shell command on peel (sync)
swarm.update-workers   - Trigger git pull + rebuild on peels
```

### Validated Scenarios

1. **Crown → Peel task dispatch**: Task dispatched via MCP, executed on Mac Studio, result returned
2. **Shell command execution**: `date`, `hostname`, etc. work correctly
3. **Peel self-update**: Peels pull latest code and rebuild themselves
4. **Version tracking**: Both Crown and Peel show same commit hash with `inSync: true`

---

## 🔧 Architecture Notes

### Key Files

| File | Purpose |
|------|---------|
| [SwarmCoordinator.swift](../Shared/Distributed/SwarmCoordinator.swift) | Core swarm logic, task dispatch, direct commands |
| [SwarmToolsHandler.swift](../Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler.swift) | MCP tool handlers |
| [PeerConnectionManager.swift](../Shared/Distributed/PeerConnectionManager.swift) | Network connection management |
| [DistributedTypes.swift](../Shared/Distributed/DistributedTypes.swift) | Types, capabilities, git hash detection |
| [WorkerMode.swift](../Shared/Distributed/WorkerMode.swift) | Peel-specific CLI mode logic |
| [self-update.sh](../Tools/self-update.sh) | Peel self-update script |

### Key Patterns

- **Fire-and-forget vs Sync commands**: `sendDirectCommand` for update-workers (workers restart), `sendDirectCommandAndWait` for direct-command (need output)
- **Continuation-based waiting**: `pendingDirectCommands` dictionary holds continuations for sync commands
- **Repo detection**: Multi-strategy approach works from both project builds and DerivedData
- **Shell execution**: Uses `/bin/zsh -c` for PATH resolution, absolute paths for scripts

---

## 🚀 Next Steps (Priority Order)

### 1. **Parallel Task Dispatch** 
Currently `swarm.dispatch` sends one task to one peel. Add:
- `swarm.dispatch-parallel` - Send same task to multiple peels
- `swarm.dispatch-split` - Split large task across peels

### 2. **Peel Health Monitoring (Partial ✅)**
- ✅ Periodic heartbeat with state (idle/busy), uptime, and task counts
- ⬜ Resource usage (CPU, memory, GPU utilization)
- ⬜ Auto-reconnect on peel restart
- ⬜ Crown notification when peel comes back online

### 3. **Task Queue & Scheduling**
- Queue multiple tasks for sequential execution
- Priority levels for urgent vs background tasks
- Task cancellation support

### 4. **Result Aggregation**
- For parallel tasks, combine results from multiple peels
- Voting/consensus for verification tasks
- Diff comparison for code review tasks

### 5. **Swarm UI Improvements**
- Peel status dashboard showing all peels
- Real-time task progress visualization
- Resource utilization graphs

### 6. **Error Recovery**
- Retry failed tasks on different peels
- Timeout handling with graceful degradation
- Peel blacklisting for repeated failures

---

## 🐛 Known Issues / Limitations

1. **Single task at a time per peel**: No queuing on peel side yet
2. **No persistence**: Task history lost on restart
3. **No authentication**: Peels trust any Crown on local network
4. **Mac Studio repo path**: Uses `/Users/coryloken/code/kitchen-sink` (different from Crown's `KitchenSink`)

---

## 📝 Session Notes

### Key Debugging Insights (2026-01-28)

1. **Command resolution**: `Tools/self-update.sh` fails, `./Tools/self-update.sh` works (shell needs `./` for current directory)
2. **DerivedData builds**: Don't have "build" in path, need alternate repo detection
3. **Direct command sync**: Had to add continuation-based waiting for synchronous output return

### Cleanup Done

- Removed verbose debug `print()` statements from:
  - `PeerConnectionManager.swift` (send/receive/handleMessage)
  - `SwarmCoordinator.swift` (sendDirectCommand, handleDirectCommand)
  - `MCPServerService.swift` (init logging)
- Kept operational logs in `WorkerMode.swift` (user-facing peel console)
- Converted to `logger.info()` where appropriate for proper logging

---

## 🔗 Related Plans

- [MCP_AGENT_WORKFLOW.md](MCP_AGENT_WORKFLOW.md) - How chains work
- [LOCAL_RAG_PLAN.md](LOCAL_RAG_PLAN.md) - Local AI integration
- [ROADMAP.md](ROADMAP.md) - Project roadmap

---

**Last Updated:** 2026-01-28  
**Commit:** bf5de5a (both Crown and Peel in sync)
