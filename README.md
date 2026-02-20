# Peel

> Peel back the layers of your dev environment.

A macOS/iOS developer tools app for managing AI coding agents, git repositories, GitHub, Homebrew, and distributed swarm execution.

**Status:** Active Development
**Swift:** 6.0 with strict concurrency
**Targets:** macOS 26 (Tahoe), iOS 26

---

## Features

| Feature | macOS | iOS | Description |
|---------|-------|-----|-------------|
| **AI Agents & Chains** | Yes | -- | Orchestrated coding agents with review gates, live status |
| **Parallel Worktrees** | Yes | -- | Multi-task parallel execution with conflict resolution |
| **Local RAG** | Yes | -- | On-device code search with MLX embeddings, lessons, skills |
| **Local Chat (MLX)** | Yes | -- | Chat with on-device LLMs (Qwen3-Coder, etc.) |
| **Code Editing (MLX)** | Yes | -- | Edit code with local models via MCP |
| **Dependency Graph** | Yes | -- | Interactive D3 force-directed module visualization |
| **MCP Server** | Yes | -- | 120+ tools via JSON-RPC for IDE integration |
| **Template Gallery** | Yes | -- | Pre-built chain templates with semantic model tiers |
| **Distributed Swarm** | Yes | Monitor | Scale agents across Macs (Bonjour LAN + Firestore WAN) |
| **Repositories** | Yes | Yes | Unified local + remote repository view |
| **GitHub** | Yes | Yes | OAuth, PRs, issues, actions |
| **Git** | Yes | -- | Local repo management, commits, branches |
| **Homebrew** | Yes | -- | Package search, install with streaming output |
| **Workspaces** | Yes | -- | Multi-repo project management |
| **VM Isolation** | Yes | -- | Run agents in isolated VMs |
| **PII Scrubber** | Yes | -- | Remove PII from datasets (opt-in) |
| **Docling Import** | Yes | -- | Import documents via Docling (opt-in) |

---

## Quick Start

```bash
# Open in Xcode and press Cmd+R
open Peel.xcodeproj

# Or build + launch with MCP server
./Tools/build-and-launch.sh --wait-for-server
```

See [START_HERE.md](START_HERE.md) for detailed setup.

---

## Project Structure

```
Peel/
+-- Shared/                      # Cross-platform SwiftUI code
|   +-- PeelApp.swift            # Entry point, SwiftData config
|   +-- Applications/            # Root views per feature area
|   +-- AgentOrchestration/      # AI agents, chains, MCP server, RAG, swarm
|   +-- Services/                # Shared services
|   +-- Views/                   # Reusable components
|   +-- Distributed/             # Firestore swarm coordination
+-- Local Packages/
|   +-- ASTChunker/              # AST-based code chunking for RAG
|   +-- Brew/                    # Homebrew package management
|   +-- Git/                     # Git operations and UI
|   +-- Github/                  # GitHub API client and UI
|   +-- MCPCore/                 # MCP protocol types and helpers
|   +-- PeelUI/                  # Shared UI components
|   +-- PIIScrubber/             # PII scrubbing engine
+-- iOS/                         # iOS app entry point
+-- macOS/                       # macOS app entry point
+-- Tools/                       # Build scripts, CLI tools, skills
+-- Plans/                       # Architecture plans and roadmaps
+-- Docs/                        # Documentation
```

---

## Architecture

### MCP Server

Peel includes an MCP (Model Context Protocol) server on port 8765 with 120+ tools:

```bash
# Connect from VS Code (settings.json)
{
  "mcp.servers": {
    "peel": { "url": "http://127.0.0.1:8765/rpc" }
  }
}

# List available tools
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### Local RAG

On-device code indexing and search using MLX embeddings (nomic-embed-text-v1.5):
- Hybrid search (text + vector with RRF fusion)
- Dependency graph with D3 visualization
- Learned lessons and repo-scoped skills
- Code analysis with local MLX LLMs

### Distributed Swarm

Scale agent execution across multiple Macs:
- **Bonjour LAN** — Auto-discovery on local network
- **Firestore WAN** — Coordination across networks with invite links

### Modern Swift 6 Patterns

```swift
// @Observable (not ObservableObject)
@MainActor @Observable
class ViewModel {
  var items = [Item]()
  func load() async { items = await fetchItems() }
}

// Actors for thread safety
actor NetworkService {
  func fetch<T: Decodable>(_ url: URL) async throws -> T { ... }
}

// NavigationStack (not NavigationView)
NavigationStack(path: $path) { ... }
```

### Data Persistence

| Data Type | Storage | Sync |
|-----------|---------|------|
| OAuth tokens | Keychain | No |
| User preferences | @AppStorage | No |
| Favorites, history | SwiftData | iCloud |

---

## Documentation

| Document | Description |
|----------|-------------|
| [Docs/PRODUCT_MANUAL.md](Docs/PRODUCT_MANUAL.md) | Full product manual with MCP API reference |
| [Docs/README.md](Docs/README.md) | Documentation index |
| [Docs/guides/MCP_AGENT_WORKFLOW.md](Docs/guides/MCP_AGENT_WORKFLOW.md) | MCP build, launch, and chain workflow |
| [Docs/guides/LOCAL_RAG_GUIDE.md](Docs/guides/LOCAL_RAG_GUIDE.md) | Local RAG setup, search, and management |
| [Docs/guides/SWARM_GUIDE.md](Docs/guides/SWARM_GUIDE.md) | Distributed swarm setup and usage |
| [Docs/guides/LOCAL_CHAT_GUIDE.md](Docs/guides/LOCAL_CHAT_GUIDE.md) | Local MLX LLM chat guide |
| [START_HERE.md](START_HERE.md) | Quick start guide |
| [.github/copilot-instructions.md](.github/copilot-instructions.md) | Coding standards for AI agents |

---

## Development

### Prerequisites
- Xcode 16+
- macOS 26 SDK
- Homebrew (for Brew features)

### Building
```bash
# Build for macOS
xcodebuild -scheme "Peel (macOS)" build

# Build for iOS
xcodebuild -scheme "Peel (iOS)" -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build + launch with MCP
./Tools/build-and-launch.sh --wait-for-server
```

---

## License

Private project - not for distribution.
