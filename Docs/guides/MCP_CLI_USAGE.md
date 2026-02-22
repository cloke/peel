---
title: MCP CLI Usage (PeelCLI)
status: active
updated: 2026-02-22
---

# MCP CLI Usage (PeelCLI)

This document describes the CLI wrapper (PeelCLI) used to run MCPCore in headless mode, invoke chains, and inspect runs.

Tools entrypoint (example build path):

```
Tools/PeelCLI/.build/debug/peel-mcp
```

## Common commands

- `chains-run --prompt "..." [--template-name "default"]`
  Start a chain with a natural language prompt.
  Flags: `--prompt` (string), `--template-name` (string), `--template-id` (string)

- `chains-run-status --run-id <id>`
  Query the status of a running or completed chain.

- `chains-run-list [--limit 20]`
  List recent chain runs (id, status, startedAt).

- `chains-poll --run-id <id>`
  Poll a chain run until it completes and print the result.

- `chains-run-batch`
  Start multiple chains in a batch.

- `tools-list`
  List all available MCP tools registered with the running Peel app.

- `tools-call --tool-name <name> [--arguments-json <path>]`
  Invoke any MCP tool directly. Pass arguments as a JSON file path.
  Example: `tools-call --tool-name rag.search --arguments-json tmp/args.json`

- `templates-list`
  List available chain templates (by name and ID).

- `rag-pattern-check --repo-path <path>`
  Run a RAG pattern check against a local repo to detect deprecated patterns.

- `rag-audit`
  Audit the current RAG index for consistency.

- `parallel-create`
  Create a parallel chain group.

- `parallel-start`
  Start a previously created parallel chain group.

- `parallel-status`
  Show status of a parallel chain group.

- `workspaces-agent-list`
  List active agent workspaces (worktrees created for chain runs).

- `workspaces-agent-cleanup-status`
  Show cleanup status of agent workspaces.

- `server-stop --address <host:port>`
  Stop a running Peel MCP server (sends a stop signal to the app).

- `app-quit`
  Quit the running Peel app.

## Global flags

- `--log-level` : debug|info|warn|error
- `--allow-while-chains-running` : When starting build-and-launch scripts, allow launching while chains are active

> **Note:** PeelCLI connects to a **running Peel app** over the local MCP socket (default port 8765). It does not start a server itself. To run a headless server without the Peel app, use `Tools/MCPCLI` (see [Headless Server (MCPCLI)](#headless-server-mcpcli) below).

## Sample config (JSON) — for MCPCLI headless only

```json
{
  "port": 8765,
  "repoRoot": "/path/to/repo",
  "dataStorePath": "/path/to/data",
  "allowedTools": null,
  "logLevel": "info"
}
```

See:
- `Tools/MCPCLI/config.example.json`
- `Docs/guides/examples/mcpcli.config.example.json`

## Common workflows

1. Run a chain from the CLI (requires Peel app running with MCP enabled):

```
Tools/PeelCLI/.build/debug/peel-mcp chains-run --prompt "Audit src/ for security issues"
```

2. Check status of a run:

```
Tools/PeelCLI/.build/debug/peel-mcp chains-run-status --run-id abc123
```

3. List recent runs:

```
Tools/PeelCLI/.build/debug/peel-mcp chains-run-list --limit 50
```

4. Invoke a tool directly:

```bash
echo '{"query": "error handling", "repoPath": "/path/to/repo", "mode": "vector", "limit": 5}' > tmp/args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.search --arguments-json tmp/args.json
```

## Notes & recommendations

- PeelCLI requires the Peel app to be running with MCP enabled (use `Tools/build-and-launch.sh --wait-for-server`).
- Store argument JSON files in the repo-local `tmp/` directory (never `/tmp`) to avoid macOS permission prompts.
- Keep `tmp/` inside the repo; it is gitignored per project guidelines.
- Headless servers (MCPCLI) will not provide UI-driven tools (screenshots, UI automation).

---

## Headless Server (MCPCLI)

`Tools/MCPCLI` is a **separate** headless server binary. It runs the MCP server without the Peel app — useful for CI, servers, or other tools that don't need a GUI.

**Build:**
```bash
cd Tools/MCPCLI
swift build -c release
```

**Run:**
```bash
.build/release/mcp-server --config config.json
# Override port at runtime:
.build/release/mcp-server --config config.json --port 9000
```

**Config fields** (see `config.example.json`):

| Field | Description |
|-------|-------------|
| `port` | TCP port to listen on (default 8765) |
| `repoRoot` | Path to the repository to serve |
| `dataStorePath` | Path to the persistent data store |
| `allowedTools` | Array of tool names to expose, or `null` for all |
| `logLevel` | `debug`, `info`, `warn`, or `error` |

**Key difference from PeelCLI:**
- `Tools/PeelCLI` — sends commands to a **running Peel app** over the local MCP socket
- `Tools/MCPCLI` — **is** the server; runs standalone without the Peel app

---

See also: ../guides/MCP_HEADLESS_FEASIBILITY.md and ../guides/MCP_EMBEDDING_GUIDE.md
