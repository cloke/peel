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

### Template Schema

External MCP templates should follow the MCPTemplate JSON schema (minimal):

- id: optional UUID (generated if omitted)
- name: string (required)
- description: string
- steps: array of step objects (required)

Step object fields:
- role: "planner" | "implementer" | "reviewer" (required)
- model: Copilot model id string (e.g. "gpt-4.1") (required)
- name: friendly name for the agent (optional)
- frameworkHint: optional framework hint (e.g. "swiftui")
- customInstructions: optional freeform instructions for the agent

Validators in Peel enforce a maximum of 8 steps and basic role/model presence.



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

### Create Template
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"tools/call",
    "params":{
      "name":"templates.create",
      "arguments":{
        "name":"My Template",
        "description":"Planner + 2 implementers + reviewer",
        "steps":[
          {"role":"planner","model":"gpt-4.1","name":"Planner"},
          {"role":"implementer","model":"gpt-5-mini","name":"Impl A"},
          {"role":"implementer","model":"gpt-4.1","name":"Impl B"},
          {"role":"reviewer","model":"gpt-4.1","name":"Reviewer"}
        ]
      }
    }
  }' \
  http://127.0.0.1:8765/rpc
```

### Validate Template
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"tools/call",
    "params":{
      "name":"templates.validate",
      "arguments":{
        "name":"My Template",
        "steps":[
          {"role":"planner","model":"gpt-4.1"}
        ]
      }
    }
  }' \
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
        "enableReviewLoop":true
      }
    }
  }' \
  http://127.0.0.1:8765/rpc
```

### Planner-Defined Chains (Dynamic)
You can skip predefined templates and provide a `chainSpec` in the `chains.run` call. Each step
includes a role and model, with optional name, framework hint, and custom instructions.

Example (JSON body excerpt):
```json
{
  "templateName": "(optional)",
  "chainName": "Dynamic Chain",
  "prompt": "...",
  "workingDirectory": "/path/to/repo",
  "chainSpec": [
    {"role": "planner", "model": "gpt-4.1", "name": "Planner"},
    {"role": "implementer", "model": "gpt-5-mini", "name": "Impl A"},
    {"role": "implementer", "model": "gpt-4.1", "name": "Impl B"},
    {"role": "reviewer", "model": "gpt-4.1", "name": "Reviewer"}
  ]
}
```

Notes:
- Max 8 steps.
- `role` must be one of `planner`, `implementer`, `reviewer`.
- `model` can be a Copilot model id (e.g. `gpt-4.1`, `claude-sonnet-4.5`).

### Review Pause + Reviewer Override
You can pause when a reviewer requests changes and optionally swap the reviewer model:

```json
{
  "enableReviewLoop": true,
  "pauseOnReview": true,
  "reviewerModel": "gpt-4.1"
}
```

### Merge Implementer Workspaces (Debug)
If a chain run failed after parallel implementers (e.g., dirty working tree), you can trigger the
merge step directly using the chain id returned from `chains.run`. Chain ids are persisted in the
MCP run log, so you can merge after relaunch.

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"tools/call",
    "params":{
      "name":"chains.merge",
      "arguments":{
        "chainId":"<CHAIN_ID>"
      }
    }
  }' \
  http://127.0.0.1:8765/rpc
```

### Planner-Defined Chains (Dynamic)

Templates are predefined, but you can allow a Planner to output a chain spec (JSON) that the app
can turn into a runtime chain. This enables the Planner to pick roles/models/parallelism based on
task scope while still respecting guardrails (approved models, max steps, cost caps).

**Recommendation:** keep templates as defaults and add an opt-in flag for dynamic chains.
When enabled, the Planner should output a chain spec that the app validates before execution.

**Response:** Chain execution results (planner output, implementer outputs, merge status, review verdict)

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

- [Tools/build-and-launch.sh](../../Tools/build-and-launch.sh) - Build and launch script
- [Tools/PeelCLI/](../../Tools/PeelCLI/) - CLI wrapper for MCP
- [Shared/AgentOrchestration/AgentManager.swift](../../Shared/AgentOrchestration/AgentManager.swift) - MCPServerService implementation
- [MCP_TEST_PLAN.md](MCP_TEST_PLAN.md) - Test cases

---

## Open Issues

- [#13](https://github.com/cloke/peel/issues/13) - Add validation pipeline for MCP runs
- [#16](https://github.com/cloke/peel/issues/16) - MCP activity log + cleanup actions
