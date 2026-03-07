# MCP Agent Workflow

**Created:** January 18, 2026  
**Updated:** February 20, 2026  
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

## MCP Tool Permissions

Peel uses a tool permissions system that controls which MCP tools are available to agents.

### How Permissions Work

1. **Default State**: All tools are enabled by default.
2. **Storage**: Permissions are persisted in UserDefaults under `mcp.server.toolPermissions`.
3. **Granularity**: Individual tools can be enabled/disabled by name.

### Verifying Tool Availability

Before running a chain, verify that required tools are available:

```bash
# List all available tools
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  http://127.0.0.1:8765/rpc
```

The response includes only **enabled** tools. If a tool you need is missing, it may be disabled.

### RAG Tool Verification

To verify RAG tools are available and working:

```bash
# Check RAG status (database, provider, model)
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.status","arguments":{}}}' \
  http://127.0.0.1:8765/rpc

# Full UI status (includes search history, skills, errors)
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.ui.status","arguments":{}}}' \
  http://127.0.0.1:8765/rpc
```

### Tool Categories

| Category | Tools (examples) | Purpose |
|----------|-------|--------|
| **Chains** | `chains.run`, `chains.runBatch`, `chains.stop`, `chains.pause`, `chains.resume`, `chains.instruct`, `chains.step`, `chains.queue.*`, `chains.promptRules.*` | Agent chain execution |
| **Parallel** | `parallel.create`, `parallel.start`, `parallel.approve`, `parallel.reject`, `parallel.merge`, `parallel.diff`, `parallel.retry`, `parallel.append` | Parallel worktree execution |
| **RAG** | `rag.search`, `rag.index`, `rag.status`, `rag.repos.*`, `rag.skills.*`, `rag.lessons.*`, `rag.model.*`, `rag.dependencies`, `rag.dependents`, `rag.duplicates`, `rag.hotspots`, `rag.analyze` | Local code search & intelligence |
| **Swarm** | `swarm.start`, `swarm.dispatch`, `swarm.workers`, `swarm.firestore.*` | Distributed execution (LAN + WAN) |
| **Code** | `code.edit`, `code.edit.status`, `code.edit.unload` | Local MLX code editing |
| **Terminal** | `terminal.run`, `terminal.analyze`, `terminal.adapt` | Shell command execution |
| **Templates** | `templates.list` | Chain template management |
| **Worktree** | `worktree.create`, `worktree.list`, `worktree.remove`, `worktree.stats` | Git worktree management |
| **UI** | `ui.tap`, `ui.navigate`, `ui.snapshot`, `ui.setText`, `ui.toggle`, `ui.select`, `ui.back` | UI automation |
| **Server** | `server.status`, `server.restart`, `server.stop`, `server.lan`, `server.port.set`, `server.sleep.prevent` | Server lifecycle |
| **App** | `app.activate`, `app.quit`, `screenshot.capture` | App lifecycle |
| **Repos** | `repos.list`, `repos.delete`, `repos.resolve` | Repository tracking |
| **Docling** | `docling.convert`, `docling.setup` | Document import |
| **PII** | `pii.scrub` | PII removal |

See [PRODUCT_MANUAL.md](../PRODUCT_MANUAL.md#mcp-api-reference) for the complete API reference (120+ tools).

### Prompt Rule Enforcement

Chain prompts can specify requirements via `promptRules`, but these are **advisory warnings**, not hard blocks:

| Rule | Effect |
|------|--------|
| `requireRagUsage: true` | Warns if planner doesn't call any `rag.*` tools |
| `maxPremiumCost: 0.5` | Warns if estimated cost exceeds threshold |
| `globalPrefix: "..."` | Prepends text to all agent prompts |

These rules don't prevent tool calls—they surface warnings in the chain result for review.

### Verification Checklist

Before running an agent chain:

- [ ] **Tools listed**: `tools/list` shows expected tools
- [ ] **RAG status**: `rag.status` returns `exists: true`
- [ ] **Repos indexed**: `rag.repos.list` shows the target repository
- [ ] **Template available**: `templates.list` includes your template

If a tool appears missing:
1. Check the tools list response for the tool name
2. Tools may be disabled via Settings → MCP → Tool Permissions
3. Some tools require initialization (e.g., `rag.init` before search)

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
- **stepType**: "agentic" | "deterministic" | "gate" (default: "agentic")
- **command**: shell command to run (required for deterministic/gate steps)
- **allowedTools**: array of tool names explicitly allowed (agentic only)
- **deniedTools**: array of tool names explicitly denied (merged with role defaults; agentic only)

Validators in Peel enforce a maximum of 8 steps and basic role/model presence.

### Step Types (Blueprint Formalization)

Chain steps now support three execution modes, allowing chains to mix LLM-driven work with
deterministic shell commands and quality gates:

| Step Type | Execution | LLM Cost | Use Case |
|-----------|-----------|----------|----------|
| `agentic` (default) | LLM agent via Copilot/Claude CLI | Yes | Planning, implementation, review |
| `deterministic` | Shell command (`/bin/zsh`) | None | Git setup, formatting, commits |
| `gate` | Shell command — exit 0 passes, non-zero halts chain | None | Build checks, lint, tests |

**Deterministic steps** run a shell command and fail the chain if the command exits non-zero.
They're ideal for scripted setup (e.g., `git checkout -b feature/...`) or post-processing
(e.g., `swift format ...`, `git add -A && git commit`).

**Gate steps** also run a shell command, but their semantics are pass/fail:
- Exit code 0 → gate passed, chain continues
- Non-zero exit → gate failed, chain stops with a `GateResult.failed` status

Gates are perfect for build verification (`xcodebuild build`), test suites, or lint checks
between implementation and review phases.

**Tool restrictions** (agentic steps only):
- `allowedTools` — whitelist of tools the agent can use (overrides role defaults)
- `deniedTools` — additional tools to deny for this step (merged with role defaults)

Example template mixing all three types:
```json
{
  "name": "Guarded Implementation",
  "steps": [
    {"role": "implementer", "model": "gpt-4.1-mini", "name": "Setup",
     "stepType": "deterministic",
     "command": "cd $WORKSPACE && git checkout -b feature/task"},
    {"role": "planner", "model": "claude-sonnet-4", "name": "Planner"},
    {"role": "implementer", "model": "claude-sonnet-4", "name": "Implementer"},
    {"role": "implementer", "model": "gpt-4.1-mini", "name": "Build Gate",
     "stepType": "gate",
     "command": "cd $WORKSPACE && xcodebuild -scheme MyApp build 2>&1 | tail -5"},
    {"role": "reviewer", "model": "gpt-4.1", "name": "Reviewer"},
    {"role": "implementer", "model": "gpt-4.1-mini", "name": "Commit",
     "stepType": "deterministic",
     "command": "cd $WORKSPACE && git add -A && git commit -m 'feat: implement task'"}
  ]
}
```

Notes:
- Deterministic/gate steps still require a `role` and `model` (for schema consistency) but the
  model is not used — no LLM call is made, and `estimatedCost` returns 0.
- The `command` field is ignored for `agentic` steps.
- Shell commands run in `/bin/zsh` with `/opt/homebrew/bin` on PATH.



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
    {"role": "implementer", "model": "gpt-4.1-mini", "name": "Build Check",
     "stepType": "gate", "command": "cd $WORKSPACE && swift build 2>&1 | tail -5"},
    {"role": "reviewer", "model": "gpt-4.1", "name": "Reviewer"}
  ]
}
```

Notes:
- Max 8 steps.
- `role` must be one of `planner`, `implementer`, `reviewer`.
- `model` can be a Copilot model id (e.g. `gpt-4.1`, `claude-sonnet-4.5`).
- `stepType` can be `agentic` (default), `deterministic`, or `gate` — see [Step Types](#step-types-blueprint-formalization).
- `command` is required for `deterministic` and `gate` steps.
- `allowedTools` / `deniedTools` restrict tool access for `agentic` steps.

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

### Issue Analyzer Template

The "Issue Analyzer" template analyzes GitHub issues and produces structured implementation plans.

**Use case:** Analyze a GitHub issue, search RAG for relevant code, and output a plan for implementers.

**Input:** GitHub issue URL or number (e.g., `https://github.com/owner/repo/issues/123` or `#123 owner/repo`)

**Tools required:** `github.issue.get`, `rag.search` (ensure these are enabled in tool permissions)

**Example:**
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"tools/call",
    "params":{
      "name":"chains.run",
      "arguments":{
        "templateName":"Issue Analyzer",
        "prompt":"Analyze GitHub issue cloke/peel#243",
        "workingDirectory":"/path/to/repo"
      }
    }
  }' \
  http://127.0.0.1:8765/rpc
```

**Output format (IssueAnalysisPlan):**
```json
{
  "issueNumber": 243,
  "issueTitle": "Issue Analysis Template",
  "issueSummary": "Add template to analyze GitHub issues and produce implementation plans",
  "affectedFiles": [
    {
      "path": "Shared/AgentOrchestration/Models/ChainTemplate.swift",
      "changeType": "modify",
      "description": "Add Issue Analyzer template to builtInTemplates"
    }
  ],
  "suggestedApproach": "1. Add template to ChainTemplate.swift...",
  "estimatedComplexity": "medium",
  "ragSearchQueries": ["ChainTemplate", "GitHub API", "RAG search"],
  "delegationReady": true
}
```

**Delegation workflow:**
- Set `delegationReady: true` when the plan is complete and ready for implementers
- Set `delegationReady: false` when more information is needed or issue is unclear
- Implementer step is included in template but optional (skip if only analysis is needed)

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
                  │ 1. Build, then Launch MCP
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ build.sh + build-and-launch.sh                               │
│  - build.sh is the canonical shell build entry point         │
│  - build-and-launch.sh delegates builds to build.sh          │
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
│  │  - Dispatches by stepType:                           │  │
│  │    • agentic → LLM agent (Copilot/Claude CLI)        │  │
│  │    • deterministic → shell command (/bin/zsh)        │  │
│  │    • gate → shell command (pass/fail check)          │  │
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

- [Tools/build.sh](../../Tools/build.sh) - Canonical shell build entry point
- [Tools/build-and-launch.sh](../../Tools/build-and-launch.sh) - MCP launch wrapper
- [Tools/PeelCLI/](../../Tools/PeelCLI/) - CLI wrapper for MCP
- [Shared/AgentOrchestration/MCPServerService.swift](../../Shared/AgentOrchestration/MCPServerService.swift) - MCP server implementation
- [Shared/AgentOrchestration/AgentChainRunner.swift](../../Shared/AgentOrchestration/AgentChainRunner.swift) - Chain execution engine
- [Shared/AgentOrchestration/AgentManager.swift](../../Shared/AgentOrchestration/AgentManager.swift) - Agent lifecycle management
- [MCP_TEST_PLAN.md](MCP_TEST_PLAN.md) - Test cases

---

## Related Docs

- [PRODUCT_MANUAL.md](../PRODUCT_MANUAL.md) - Full product manual with complete MCP API reference
- [LOCAL_RAG_GUIDE.md](LOCAL_RAG_GUIDE.md) - Local RAG search and management
- [SWARM_GUIDE.md](SWARM_GUIDE.md) - Distributed swarm setup
- [LOCAL_CHAT_GUIDE.md](LOCAL_CHAT_GUIDE.md) - Local MLX chat
