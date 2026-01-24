---
title: MCP Agent Workflow
status: active
created: 2026-01-18
updated: 2026-01-24
tags: [mcp, agent-orchestration, api]
audience: [ai-agents, developers]
code_locations:
  - path: Shared/AgentOrchestration/AgentManager.swift
    description: MCPServerService implementation
  - path: Tools/build-and-launch.sh
    description: Build and launch script with MCP flags
  - path: Tools/PeelCLI/
    description: CLI wrapper for MCP commands
related_docs:
  - Plans/MCP_TEST_PLAN.md
  - Plans/AGENT_ORCHESTRATION_PLAN.md
  - Docs/guides/MCP_AGENT_WORKFLOW.md
---

# MCP Agent Workflow

**Created:** January 18, 2026  
**Status:** Active

---

## Overview

Peel includes an MCP (Model Context Protocol) server that allows external AI agents to:
- List available chain templates
- Run agent chains (planner → parallel implementers → merge → review)
- Query results and session history
- Stop the server or quit the app

The recommended workflow is **agent builds the app, launches it, then connects** to the MCP server.

Peel can act as the **planner/reviewer/model picker**, with external agents using MCP to execute
parallel work asynchronously. This keeps chain structure and cost controls inside the app while
allowing concurrent execution via MCP.

---

## Why Build-Then-Launch?

The MCP server runs inside the Peel app. This creates a chicken-and-egg problem:
- Agent can't use MCP until the app is running
- App needs to be built before it can run

**Solution:** A shell script that builds, configures, and launches the app with MCP enabled.

---

## Quick Start

### For AI Agents

```bash
# Build and launch Peel with MCP server enabled
./Tools/build-and-launch.sh --wait-for-server

# Now MCP is available
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  http://127.0.0.1:8765/rpc

### Parallel Chain Runs (Async)

Use the helper script to dispatch multiple chains concurrently:

```bash
./Tools/run-chains-parallel.sh \
  --prompt "Task A" \
  --prompt "Task B" \
  --template-name "MCP Harness" \
  --working-directory /path/to/repo \
  --max-concurrent 2
```
```

### Script Options

| Option | Description |
|--------|-------------|
| `--port PORT` | MCP server port (default: 8765) |
| `--wait-for-server` | Block until MCP server responds |
| `--skip-build` | Launch existing build without rebuilding |
| `--help` | Show help |

---

## MCP Endpoints

### List Tools
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  http://127.0.0.1:8765/rpc
```

**Response:** List of available MCP tools (templates.list, chains.run, etc.)

### List Templates
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"templates.list","arguments":{}}}' \
  http://127.0.0.1:8765/rpc
```

**Response:** Available chain templates (MCP Harness, etc.)

### Run Chain
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"tools/call",
    "params":{
      "name":"chains.run",
      "arguments":{
        "templateName":"MCP Harness",
        "prompt":"Add a dark mode toggle to SettingsView",
        "workingDirectory":"/path/to/git/repo",
        "enableReviewLoop":true,
        "allowPlannerModelSelection":true,
        "allowPlannerImplementerScaling":true,
        "maxImplementers":3,
        "maxPremiumCost":1.0
      }
    }
  }' \
  http://127.0.0.1:8765/rpc
```

**Response:** Chain execution results (planner output, implementer outputs, merge status, review verdict)

Note: The planner can propose model mix and implementer count when these options are enabled. Cost
caps will downgrade implementer models to meet the limit when possible. For dynamic chains using
`chainSpec`, the caller still defines the step count and model selection; validators enforce a hard
max of 8 steps.

### Stop Server
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"server.stop","arguments":{}}}' \
  http://127.0.0.1:8765/rpc
```

### Quit App
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"app.quit","arguments":{}}}' \
  http://127.0.0.1:8765/rpc
```

---

## PeelCLI Alternative

Instead of raw curl, use the CLI wrapper:

```bash
# After building PeelCLI
peel-mcp tools-list
peel-mcp templates-list
peel-mcp chains-run --prompt "Add dark mode" --template-name "MCP Harness" --working-directory /path/to/repo
peel-mcp server-stop
peel-mcp app-quit
```

---

## Agent Integration Example

Here's how an external AI agent (like Claude Code or GitHub Copilot) would use this:

```python
import subprocess
import requests
import time

# Step 1: Build and launch Peel
subprocess.run([
    "./Tools/build-and-launch.sh", 
    "--wait-for-server"
], check=True)

# Step 2: Use MCP to run a chain
response = requests.post(
    "http://127.0.0.1:8765/rpc",
    json={
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "chains.run",
            "arguments": {
                "templateName": "MCP Harness",
                "prompt": "Implement feature X",
                "workingDirectory": "/path/to/repo",
                "enableReviewLoop": True
            }
        }
    }
)

result = response.json()
print(result["result"])

# Step 3: Clean up
requests.post("http://127.0.0.1:8765/rpc", json={
    "jsonrpc": "2.0", "id": 2,
    "method": "tools/call",
    "params": {"name": "app.quit", "arguments": {}}
})
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    External Agent                            │
│  (Claude Code, GitHub Copilot, custom script)               │
└─────────────────┬───────────────────────────────────────────┘
                  │ 1. Build & Launch
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                 build-and-launch.sh                          │
│  - xcodebuild -scheme "Peel (macOS)"                        │
│  - defaults write ... mcp.server.enabled true               │
│  - open Peel.app                                            │
│  - Wait for MCP server (optional)                           │
└─────────────────┬───────────────────────────────────────────┘
                  │ 2. App starts with MCP enabled
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                    Peel.app                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              MCPServerService                         │  │
│  │  - Listens on localhost:8765                         │  │
│  │  - JSON-RPC 2.0 over HTTP                            │  │
│  │  - Tools: templates.list, chains.run, etc.           │  │
│  └──────────────────────┬───────────────────────────────┘  │
│                         │                                   │
│  ┌──────────────────────▼───────────────────────────────┐  │
│  │           AgentChainRunner                            │  │
│  │  - Planner → Parallel Implementers → Merge → Review  │  │
│  │  - Creates git worktrees for isolation               │  │
│  │  - Tracks session costs                              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                  │
                  │ 3. Agent sends requests
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                    External Agent                            │
│  - POST /rpc with tools/call chains.run                     │
│  - Receive structured results                               │
│  - POST app.quit when done                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

### Build Fails
- Ensure Xcode is installed and command line tools are configured
- Check that `Peel.xcodeproj` exists in the project root
- Run `xcodebuild -list` to verify the scheme name

### MCP Server Not Responding
- Check if Peel is running: `pgrep -x Peel`
- Check port is correct: `lsof -i :8765`
- Verify MCP is enabled in Settings → MCP Server

### Connection Refused
- MCP server is localhost-only by default
- Ensure you're connecting to `127.0.0.1`, not external IP

---

## Related Files

- [Tools/build-and-launch.sh](../Tools/build-and-launch.sh) - Build and launch script
- [Tools/PeelCLI/](../Tools/PeelCLI/) - CLI wrapper for MCP
- [Shared/AgentOrchestration/AgentManager.swift](../Shared/AgentOrchestration/AgentManager.swift) - MCPServerService implementation
- [Plans/MCP_TEST_PLAN.md](MCP_TEST_PLAN.md) - Test cases

---

## Open Issues

- [#13](https://github.com/cloke/peel/issues/13) - Add validation pipeline for MCP runs
