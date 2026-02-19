# MCPCLI — Headless MCP Server

A standalone command-line MCP server that runs without the Peel app.

## Purpose

MCPCLI lets you run an MCP-compatible JSON-RPC server headlessly from a config file, without launching the full Peel macOS/iOS application. This is useful for CI environments, scripting, or when you want a lightweight server with a specific tool allowlist.

## Build

```bash
cd Tools/MCPCLI
swift build -c release
```

The binary will be at `.build/release/mcp-server`.

## Usage

```bash
.build/release/mcp-server --config config.json
```

Override the port at runtime:
```bash
.build/release/mcp-server --config config.json --port 9000
```

## Config File

Copy `config.example.json` to `config.json` and edit:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | Int | `8765` | TCP port to listen on |
| `repoRoot` | String? | `null` | Path to the repo root (logged on startup) |
| `dataStorePath` | String? | `null` | Path for persistent data |
| `allowedTools` | [String]? | `null` | Allowlist of tool names; `null` means allow all (advertised as stubs in `tools/list`) |
| `logLevel` | String | `"info"` | Log level: `"debug"`, `"info"`, `"warn"`, `"error"` |

## Example: Verify with curl

Start the server, then in another terminal:

```bash
# List tools
curl -X POST http://localhost:8765/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# Initialize handshake
curl -X POST http://localhost:8765/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test"}}}'
```

## Limitations

The following features are **only available through the full Peel app**:

- UI automation and screenshot capture
- Agent chain execution (`chains/run`)
- SwiftData persistence and iCloud sync
- RAG indexing and search (requires MLX embedding models)
- GitHub, Git, and Homebrew integrations
- Real tool implementations (this server advertises stubs only)
