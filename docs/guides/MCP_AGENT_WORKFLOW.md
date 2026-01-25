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

Peel can also act as the **planner/reviewer/model picker**, while the external agent (me) uses MCP
to execute parallel work asynchronously. This lets the app orchestrate chain structure and cost
controls, while MCP runs proceed in parallel.

---

## Dogfooding MCP Workflow (Primary)

Use this flow when Peel is expected to build features via MCP and you validate them.

1. **Build + launch Peel with MCP**
  - Use the build-and-launch script and wait for the server.
2. **Run a chain with a planner + implementers + reviewer**
  - Require the planner to use Local RAG before task breakdown.
  - Reviewer validates code quality and RAG relevance.
3. **Validate results**
  - Confirm code changes align with plan and project patterns.
  - Run RAG pattern checks after edits.
4. **Record feedback**
  - Note when RAG was right/wrong and what snippets misled the plan.

---

## Safety Rules (Non-Negotiable)

- **Never use blanket checkout** (e.g., `git checkout -- .` or multi-file checkout without confirmation).
- If unexpected files are modified, **assume an agent forgot to commit** and **do not discard work**.
- Prefer **stash-first** when uncertain: stash changes (including untracked), then investigate.
- Always verify agent workspaces and MCP run history before discarding anything.

---

## Recovery Playbook (When Changes Appear Unexpected)

1. **Stop and inspect**
  - Check `git status` and identify which files were touched.
2. **Stash safely**
  - Use a stash that includes untracked files.
3. **Inspect MCP artifacts**
  - List agent workspaces and MCP run history to understand provenance.
4. **Decide**
  - Either restore the changes (apply stash) or move them into a targeted commit.

---

## RAG UX Validation Checklist

Use this checklist for dogfooding:

- **Planner uses RAG** at least once per chain.
- **RAG snippets are relevant** (target: ≥2 out of 3 prompts).
- **Reviewer notes false positives** and whether the plan should have ignored them.
- **UX surfaces** in Peel show the latest RAG status, query, and snippet list.


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

### Parallel Chain Runs (Async)

Use the helper script to fire multiple chains concurrently (useful for parallel implementers or
multiple independent tasks):

```bash
./Tools/run-chains-parallel.sh \
  --prompt "Task A" \
  --prompt "Task B" \
  --template-name "MCP Harness" \
  --working-directory /path/to/repo \
  --max-concurrent 2
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

Note: The planner can propose model mix and implementer count when these options are enabled. Cost
caps will downgrade implementer models to meet the limit when possible.

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

#### Chain Limits & Planner Constraints
The caller defines the step count and model selection in `chainSpec`. Planners cannot currently
auto-spawn additional implementers, and validators enforce a hard limit of 8 steps.

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

**Response:** Chain execution results (planner output, implementer outputs, merge status, review verdict)

Note: The planner can propose model mix and implementer count when these options are enabled. Cost
caps will downgrade implementer models to meet the limit when possible.

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
