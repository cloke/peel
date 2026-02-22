# Documentation

How the system works today.

**Last Updated:** February 19, 2026

---

## Product Manual

The comprehensive product manual covering all features, navigation, MCP API reference, and troubleshooting:

- **[PRODUCT_MANUAL.md](PRODUCT_MANUAL.md)** — Full product manual (v1.0)

---

## Guides

Step-by-step instructions for common tasks.

| Guide | Description |
|-------|-------------|
| [MCP_AGENT_WORKFLOW](guides/MCP_AGENT_WORKFLOW.md) | Build, launch, and connect via MCP; chain execution workflow |
| [LOCAL_RAG_GUIDE](guides/LOCAL_RAG_GUIDE.md) | Local RAG setup, indexing, search modes, lessons, skills |
| [SWARM_GUIDE](guides/SWARM_GUIDE.md) | Distributed swarm setup (Bonjour LAN + Firestore WAN) |
| [LOCAL_CHAT_GUIDE](guides/LOCAL_CHAT_GUIDE.md) | On-device MLX LLM chat |
| [MCP_CLI_USAGE](guides/MCP_CLI_USAGE.md) | PeelCLI commands, tools-call workflow, and MCPCLI headless server |
| [MCP_TEST_PLAN](guides/MCP_TEST_PLAN.md) | Testing the MCP server |
| [MCP_EMBEDDING_GUIDE](guides/MCP_EMBEDDING_GUIDE.md) | Embed MCPCore in another app; app-embedded vs headless differences |
| [MCPCLI Config Example](guides/examples/mcpcli.config.example.json) | Copy/paste starter config for `Tools/MCPCLI` headless server |

## Reference

Technical reference material.

| Doc | Description |
|-----|-------------|
| [CODE_AUDIT_INDEX](reference/CODE_AUDIT_INDEX.md) | File-by-file audit, patterns to avoid |
| [RAG_PATTERN_INDEX](reference/RAG_PATTERN_INDEX.md) | Preferred patterns and anti-patterns for RAG checks |
| [RAG_EMBEDDING_MODEL_EVALUATION](reference/RAG_EMBEDDING_MODEL_EVALUATION.md) | Embedding provider comparison and benchmarks |
| [MCP_VALIDATION](MCP_VALIDATION.md) | MCP validation results |

---

## Quick Reference for Agents

### Build & Launch
```bash
./Tools/build-and-launch.sh --wait-for-server
```

### MCP Connection
```bash
# List tools
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# Run a chain
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chains.run","arguments":{"prompt":"...","workingDirectory":"/path/to/repo"}}}'
```

### Roadmap Sync (Project 1)
```bash
./Tools/roadmap-sync.sh
```

Options:
- `--start-date YYYY-MM-DD` start scheduling on a specific date
- `--remove-done` remove items marked Done from the project
- `--repo owner/repo` sync open issues from a different repo

### Key Source Files
| Area | File |
|------|------|
| App entry | `Shared/PeelApp.swift` |
| MCP Server | `Shared/AgentOrchestration/MCPServerService.swift` |
| Agent chains | `Shared/AgentOrchestration/AgentChainRunner.swift` |
| Agent lifecycle | `Shared/AgentOrchestration/AgentManager.swift` |
| RAG Store | `Shared/AgentOrchestration/RAGStore.swift` |
| Swarm Coordinator | `Shared/AgentOrchestration/SwarmCoordinator.swift` |
| CLI wrapper | `Tools/PeelCLI/` |
| Build script | `Tools/build-and-launch.sh` |

### Packages
| Package | Purpose |
|---------|---------|
| `Local Packages/ASTChunker` | AST-based code chunking for RAG |
| `Local Packages/Git` | Git commands, worktrees |
| `Local Packages/Github` | GitHub API |
| `Local Packages/Brew` | Homebrew |
| `Local Packages/MCPCore` | MCP protocol types |
| `Local Packages/PeelUI` | Shared UI components |
| `Local Packages/PIIScrubber` | PII scrubbing engine |
