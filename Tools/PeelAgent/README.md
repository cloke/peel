# PeelAgent — Interactive AI Coding CLI

An interactive AI coding agent for your terminal, inspired by Claude Code.
Uses the **GitHub Copilot API** (via your Copilot subscription) by default,
or optionally the Anthropic API for direct Claude access.
Can read/write files, run commands, search code, and use git.

## Quick Start

```bash
# Build
cd Tools/PeelAgent
swift build -c release

# Run (interactive mode) — uses GitHub token automatically, Claude by default
.build/release/peel

# Run with a single prompt
.build/release/peel prompt "Fix the compile error in main.swift"

# Auto-approve all tool executions
.build/release/peel --yolo

# Use a specific model
.build/release/peel --model claude-sonnet-4.6

# Use Anthropic (Claude direct) instead of Copilot
.build/release/peel --provider anthropic --api-key "sk-ant-..."

# Work in a specific directory
.build/release/peel --directory /path/to/project
```

## Providers

| Provider | Auth | Default Model | Models Available |
|----------|------|---------------|------------------|
| **copilot** (default) | `copilot login` (preferred) or `gh auth` | claude-sonnet-4.5 | Claude (sonnet-4.5, sonnet-4.6, opus-4.5, opus-4.6, haiku-4.5), GPT (4.1, 4.1-mini, 4o, o1, o3-mini), Gemini |
| **anthropic** | `ANTHROPIC_API_KEY` | claude-sonnet-4-20250514 | All Claude models (direct API) |

The provider is auto-detected: if you have `copilot login` done (or `gh` authenticated), it uses Copilot.
If only `ANTHROPIC_API_KEY` is set, it uses Anthropic.

> **Note:** `copilot login` gives access to all models (Claude, GPT, Gemini).
> Plain `gh auth` falls back to the GitHub Models API which only supports GPT models.

## Features

- **Multi-provider** — GitHub Copilot (default, free with subscription) or Anthropic
- **Interactive chat** — natural language conversation with tool execution
- **File operations** — read, write, and edit files with precision
- **Code search** — grep for content or find files by pattern
- **Shell commands** — run any terminal command
- **Git integration** — status, diff, log, commit
- **Streaming** — real-time response streaming
- **Approval flow** — destructive operations require confirmation (bypass with `--yolo`)
- **Token tracking** — monitor API usage with the `history` command

## Tools Available

| Tool | Description | Needs Approval |
|------|-------------|:--------------:|
| `read_file` | Read file contents or line ranges | No |
| `write_file` | Create or overwrite files | Yes |
| `replace_in_file` | Find-and-replace exact strings in files | Yes |
| `list_directory` | List directory contents | No |
| `search_files` | Grep for content or find files by name | No |
| `run_command` | Execute shell commands | Varies* |
| `git_status` | Show branch and working tree status | No |
| `git_diff` | Show working directory or staged changes | No |
| `git_log` | Show recent commit history | No |
| `git_commit` | Stage files and create a commit | Yes |

\* Read-only commands (cat, ls, grep, etc.) don't need approval.

## Interactive Commands

Once in a chat session:
- **quit** / **exit** — end the session
- **clear** — reset conversation history
- **history** — show token usage statistics
- **help** — show available commands

## Architecture

```
PeelAgent/
├── PeelCommand.swift     — CLI entry point (ArgumentParser)
├── LLMProvider.swift     — Provider protocol abstraction
├── CopilotClient.swift   — GitHub Copilot API (OpenAI-compatible, default)
├── ClaudeClient.swift    — Anthropic Messages API (direct Claude access)
├── AgentSession.swift    — Main agent loop (conversation + tool dispatch)
├── ToolExecutor.swift    — Tool implementations (file, terminal, git, search)
├── AgentTools.swift      — Tool definitions (JSON schema)
└── Terminal.swift        — ANSI terminal formatting utilities
```

## Requirements

- macOS 14+
- Swift 6.0+
- `copilot login` for full model access (Claude, GPT, Gemini), **or** `gh auth login` for GPT-only, **or** Anthropic API key

## Relationship to Peel App

This is a standalone CLI that does **not** require the Peel macOS app to be running.
It implements its own tool execution directly. In the future, it may optionally
connect to a running Peel MCP server for additional capabilities (RAG, embeddings,
chain orchestration, etc.).

See also:
- `Tools/PeelCLI/` — thin client that connects to a running Peel app's MCP server
- `Tools/MCPCLI/` — skeleton headless MCP server (non-functional)
- `Plans/MCP_DROP_IN_TOOL_PLAN.md` — plan for extracting MCPServerKit
