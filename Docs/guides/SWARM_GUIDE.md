# Distributed Swarm Guide

**Created:** February 19, 2026
**Status:** Active

---

## Overview

Peel's Distributed Swarm lets you scale AI agent execution across multiple Mac devices. It supports two coordination modes:

- **Bonjour LAN** — Auto-discovery on your local network, zero configuration
- **Firestore WAN** — Coordination across different networks via Firebase/Firestore

### Naming (Banana Theme)

| Term | Role |
|------|------|
| **Crown** | The leader that coordinates tasks and queues |
| **Tree** | A powerful node for heavy workloads |
| **Peel** | A regular worker node that executes tasks |
| **Sprout** | An idle Peel that auto-requests work |
| **Bunch** | The full swarm of connected devices |

---

## Bonjour LAN Mode

For devices on the same local network. Zero configuration required.

### Starting the Swarm

**From the UI:**
1. Navigate to the **Swarm** tab (top navigation)
2. Click **Start** to begin the coordinator
3. Other Peel instances on the network auto-discover and connect

**Via MCP:**
```bash
# Start swarm coordinator
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.start","arguments":{}}}'

# Check status
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.status","arguments":{}}}'

# View discovered peers
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.discovered","arguments":{}}}'
```

### Dispatching Tasks

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"swarm.dispatch",
      "arguments":{
        "prompt":"Implement dark mode toggle",
        "repoPath":"/path/to/repo"
      }
    }
  }'
```

### Registering Repositories

Workers need to know which repos they can execute tasks for:

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.register-repo","arguments":{"repoPath":"/path/to/repo"}}}'
```

### Worker Management

```bash
# List connected workers
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.workers","arguments":{}}}'

# Send command to specific worker
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.direct-command","arguments":{"workerId":"...","command":"..."}}}'

# Push configuration to all workers
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.update-workers","arguments":{}}}'
```

### Task & Branch Queues

```bash
# View task results
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.tasks","arguments":{}}}'

# Manage branch queue
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.branch-queue","arguments":{}}}'

# Manage PR queue
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.pr-queue","arguments":{}}}'

# Create PR from swarm work
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.create-pr","arguments":{}}}'
```

---

## Firestore WAN Mode

For devices across different networks. Uses Firebase/Firestore as the coordination layer.

### Prerequisites

1. Firebase project configured (see `GoogleService-Info.plist`)
2. Firestore security rules deployed (`firestore.rules`)
3. Network connectivity to Firebase

### Authentication

```bash
# Check auth status
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.auth","arguments":{}}}'
```

In the UI, the Swarm tab shows an auth view if you're not signed in.

### Creating a Swarm

```bash
# Create a new swarm
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.create","arguments":{"name":"My Dev Swarm"}}}'

# List your swarms
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.swarms","arguments":{}}}'
```

### Joining a Swarm

Share an invite link (generated from the Swarm Management UI) or use QR codes. The UI provides a "Copy Invite Link" button.

### Worker Registration

```bash
# Register as a worker
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.register-worker","arguments":{"swarmId":"..."}}}'

# List workers in swarm
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.workers","arguments":{"swarmId":"..."}}}'

# Unregister
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.unregister-worker","arguments":{"swarmId":"...","workerId":"..."}}}'
```

### Submitting Tasks

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"swarm.firestore.submit-task",
      "arguments":{
        "swarmId":"...",
        "prompt":"Fix the login form validation",
        "repoPath":"/path/to/repo"
      }
    }
  }'
```

### Monitoring

```bash
# List tasks
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.tasks","arguments":{"swarmId":"..."}}}'

# View activity log
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.activity","arguments":{"swarmId":"..."}}}'

# Debug connection
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.debug","arguments":{}}}'
```

---

## RAG Artifact Sync

Share RAG indices between swarm members. Two transfer modes are available:

### Full Sync (default)
Transfers complete repo data (chunks + embeddings + analysis). Use for first-time sync or when the receiver hasn't indexed the repo locally.

```bash
# Push local RAG to swarm
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.rag.sync","arguments":{"direction":"push","mode":"full"}}}'

# Pull RAG from swarm
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.rag.sync","arguments":{"direction":"pull","mode":"full"}}}'
```

### Overlay Sync
Transfers only embeddings + AI analysis (no chunk text), matched against locally-indexed chunks by file content hash + line range. ~100x smaller than full sync.

Use when both machines have the same code indexed locally and you want to pull pre-computed embeddings and analysis from a more powerful peer.

```bash
# Pull overlay from swarm
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.rag.sync","arguments":{"repoIdentifier":"github.com/org/repo","direction":"pull","mode":"overlay"}}}'
```

### Auto-Sync After Pull
When a tracked remote repo completes a scheduled pull + reindex, Peel automatically requests an overlay sync from connected swarm peers. This keeps analysis data fresh without re-running expensive LLM analysis locally.

### Model Mismatch Guard
When the local repo already has embeddings from a different model (e.g. Qwen3 1024d from the Mac Studio), overlay sync **skips embedding writes** and only applies analysis data. This prevents downgrading higher-quality embeddings.

The mismatch is logged as a warning and surfaced in the transfer summary. To force local embeddings instead:
1. Disconnect from swarm: `swarm.stop`
2. Reindex locally: `rag.index` with `forceReindex: true`
3. Reconnect: `swarm.start`

### Legacy Firestore Sync

```bash
# List shared artifacts
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.rag.artifacts","arguments":{}}}'

# Delete an artifact
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.firestore.rag.delete","arguments":{"artifactId":"..."}}}'
```

---

## Swarm Configuration

### Auto-Start

Swarm can be configured to auto-start on app launch (enabled by default). Toggle in Settings.

### Worktree Tracking

Swarm-created worktrees are tracked in SwiftData with `source: "swarm"` and show disk sizes in the UI.

---

## Troubleshooting

### Workers Not Connecting (Bonjour)
1. Verify both devices are on the same network
2. Check firewall — Bonjour requires mDNS (port 5353)
3. Run `swarm.diagnostics` for detailed info
4. Try manually connecting: `swarm.connect` with the peer's address

### Workers Not Connecting (Firestore)
1. Verify both devices are signed in: `swarm.firestore.auth`
2. Check both are in the same swarm: `swarm.firestore.swarms`
3. Debug connection: `swarm.firestore.debug`
4. Verify Firebase configuration in `GoogleService-Info.plist`

### Tasks Not Executing
1. Check worker has the repo registered: `swarm.repos`
2. Verify worker has available CLI tools (Copilot/Claude)
3. Check worker is not at capacity
4. View task status in the Swarm Management UI

---

## Related Docs

- [PRODUCT_MANUAL.md](../PRODUCT_MANUAL.md) — Full MCP API reference
- [MCP_AGENT_WORKFLOW.md](MCP_AGENT_WORKFLOW.md) — Chain execution workflow
- [LOCAL_RAG_GUIDE.md](LOCAL_RAG_GUIDE.md) — Local RAG for swarm grounding
