# Documentation

How the system works today.

## Guides

Step-by-step instructions for common tasks.

| Guide | Description |
|-------|-------------|
| [MCP_AGENT_WORKFLOW](guides/MCP_AGENT_WORKFLOW.md) | Build, launch, and connect via MCP |
| [MCP_TEST_PLAN](guides/MCP_TEST_PLAN.md) | Testing the MCP server |

## Reference

Technical reference material.

| Doc | Description |
|-----|-------------|
| [CODE_AUDIT_INDEX](reference/CODE_AUDIT_INDEX.md) | File-by-file audit, patterns to avoid |
| [RAG_PATTERN_INDEX](reference/RAG_PATTERN_INDEX.md) | Preferred patterns and anti-patterns for RAG checks |

---

## Quick Reference for Agents

### Build & Launch
```bash
./Tools/build-and-launch.sh --wait-for-server
```

### Key Source Files
| Area | File |
|------|------|
| App entry | `Shared/PeelApp.swift` |
| MCP Server | `Shared/AgentOrchestration/AgentManager.swift` |
| Agent chains | `Shared/AgentOrchestration/AgentManager.swift` |
| CLI wrapper | `Tools/PeelCLI/` |
| Build script | `Tools/build-and-launch.sh` |

### Packages
| Package | Purpose |
|---------|---------|
| `Local Packages/Git` | Git commands, worktrees |
| `Local Packages/Github` | GitHub API |
| `Local Packages/Brew` | Homebrew |
