---
title: MCP CLI Usage (PeelCLI)
status: draft
updated: 2026-02-19
---

# MCP CLI Usage (PeelCLI)

This document describes the CLI wrapper (PeelCLI) used to run MCPCore in headless mode, invoke chains, and inspect runs.

Tools entrypoint (example build path):

```
Tools/PeelCLI/.build/debug/peel-mcp
```

## Common commands

- chains-run --prompt "..." --template-name "default"
  - Start a chain with a natural language prompt.
  - Flags: --prompt (string), --template-name (string), --config (path to JSON/YAML config), --tmp-dir (workspace root)

- chains-status --run-id <id>
  - Query the status of a running or completed chain.

- chains-list --limit 20
  - List recent chain runs (id, status, startedAt).

- server-start --config /path/to/config.json
  - Launch MCPCore in headless mode using the provided config. Useful to run as a long-lived service.

- server-stop --address <host:port>
  - Stop a running headless server (if supported by transport).

## Global flags

- --config / -c <path>  : Path to JSON/YAML config file (port, allowedTools, repoRoot, logLevel)
- --port -p <port>      : Port to bind the server (overrides config)
- --tmp-dir             : Directory used for temporary workspaces (defaults to tmp/)
- --log-level           : debug|info|warn|error
- --allow-while-chains-running : When starting build-and-launch scripts, allow launching while chains are active

## Sample config (JSON)

```json
{
  "port": 8765,
  "transport": "tcp",
  "allowedTools": ["git", "shell"],
  "repoRoot": "/path/to/repo",
  "defaultTemplates": ["free-review"],
  "logLevel": "info"
}
```

## Common workflows

1. Start headless server and keep running (daemon):

```
Tools/PeelCLI/.build/debug/peel-mcp server-start --config /etc/mcp/config.json --tmp-dir /var/tmp/peel
```

2. Run a chain from the CLI (one-off):

```
Tools/PeelCLI/.build/debug/peel-mcp chains-run --prompt "Audit src/ for security issues" --config ./mcp-config.json
```

3. Check status of a run:

```
Tools/PeelCLI/.build/debug/peel-mcp chains-status --run-id abc123
```

4. List runs:

```
Tools/PeelCLI/.build/debug/peel-mcp chains-list --limit 50
```

## Notes & recommendations

- Use the --config file to pin server settings for reproducible CI runs.
- For long-lived services, run PeelCLI under a process manager (systemd, launchd) and configure logs to rotate.
- Keep tmp/ inside the repo (per project guidance) to avoid macOS permission prompts.
- Headless servers will not provide UI-driven tools (screenshots, UI automation).

---

See also: ../guides/MCP_HEADLESS_FEASIBILITY.md and ../guides/MCP_EMBEDDING_GUIDE.md
