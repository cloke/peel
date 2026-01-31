# RAG Three-Phase Search Guide

**Purpose:** Explain how Peel's RAG system enables agents to find relevant code efficiently, freeing context window for problem-solving rather than code discovery.

---

## The Problem: Context Window Tax

Without RAG, an agent working on a 67,000+ line codebase must:
1. Grep/search for keywords → often returns 50+ matches
2. Read multiple files to find the right one → 500-2000 tokens per file
3. Re-read to understand relationships → more tokens
4. Finally start working on the actual problem

**Result:** 60-80% of context window spent on "finding" before "fixing"

---

## The Solution: Three-Phase RAG

| Phase | What It Does | Token Cost | Quality |
|-------|--------------|------------|---------|
| **1. Vector/Text Search** | Find relevant chunks by meaning or keywords | ~200 tokens response | Good starting point |
| **2. Graph/Dependencies** | Understand relationships between code | ~300 tokens response | Shows architecture |
| **3. AI Analysis** | Get semantic summaries and intent | ~100 tokens per chunk | Explains "why" |

---

## Phase 1: Vector/Text Search

Find code by meaning (vector) or exact keywords (text).

### Example: Find MCP Tool Handlers

**Query:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "rag.search",
    "arguments": {
      "query": "MCP tool handler registration",
      "repoPath": "/Users/cloken/code/KitchenSink",
      "mode": "vector",
      "limit": 3
    }
  }
}
```

**Response:**
```json
{
  "mode": "vector",
  "results": [
    {
      "filePath": "/Users/cloken/code/KitchenSink/Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler.swift",
      "startLine": 46,
      "endLine": 49,
      "constructType": "method",
      "name": "SwarmToolsHandler.init",
      "language": "Swift",
      "modulePath": "Shared/AgentOrchestration",
      "featureTags": ["agent", "concurrency", "foundation", "handler", "swarm", "swift", "tools"],
      "score": 0.626,
      "snippet": "public init(chainRunner: AgentChainRunner? = nil, agentManager: AgentManager? = nil) {\n    self.chainRunner = chainRunner\n    self.agentManager = agentManager\n  }"
    },
    {
      "filePath": "/Users/cloken/code/KitchenSink/Shared/AgentOrchestration/ToolHandlers/ParallelToolsHandler.swift",
      "startLine": 5,
      "endLine": 10,
      "constructType": "protocolDecl",
      "name": "ParallelToolsHandlerDelegate",
      "language": "Swift",
      "featureTags": ["agent", "concurrency", "foundation", "handler", "swift", "tools"],
      "score": 0.611,
      "snippet": "@MainActor\nprotocol ParallelToolsHandlerDelegate: AnyObject {\n  var parallelWorktreeRunner: ParallelWorktreeRunner? { get }\n  var parallelDataService: DataService? { get }\n  var parallelTelemetryProvider: MCPTelemetryProviding { get }\n}"
    }
  ]
}
```

### What This Tells Me

- **Exact files and line numbers** - I can `read_file` precisely
- **Construct type** - I know it's a method/protocol/class before reading
- **Feature tags** - I know this involves `swarm`, `agent`, `tools`
- **Module path** - I understand the folder organization
- **Relevance score** - Higher = more semantically similar to my query

### Text Mode Alternative

For exact keyword searches (e.g., finding all `@MainActor` usages):

```json
{
  "arguments": {
    "query": "@MainActor protocol",
    "mode": "text",
    "limit": 10
  }
}
```

---

## Phase 2: Dependency Graph

Understand how code relates to other code.

### Example: What Does SwarmToolsHandler Depend On?

**Query:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "rag.dependencies",
    "arguments": {
      "repoPath": "/Users/cloken/code/KitchenSink",
      "filePath": "/Users/cloken/code/KitchenSink/Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler.swift"
    }
  }
}
```

**Response:**
```json
{
  "dependencies": [
    {
      "type": "import",
      "target": "Foundation",
      "targetPath": null
    },
    {
      "type": "import", 
      "target": "MCPCore",
      "targetPath": "Local Packages/MCPCore"
    },
    {
      "type": "conform",
      "target": "MCPToolHandler",
      "targetPath": "Local Packages/MCPCore/Sources/MCPCore/MCPToolHandler.swift"
    }
  ],
  "stats": {
    "importCount": 2,
    "conformCount": 1,
    "inheritCount": 0
  }
}
```

### What Does This Enable?

**Before graph:** "I need to understand SwarmToolsHandler" → read file → see it conforms to `MCPToolHandler` → search for that → read another file → repeat

**With graph:** One query shows me the full dependency tree. I immediately know:
- It conforms to `MCPToolHandler` (protocol in MCPCore)
- I should look at MCPCore for the contract it implements
- No inheritance, so it's a final implementation

### Reverse: What Uses This Code?

**Query:**
```json
{
  "params": {
    "name": "rag.dependents",
    "arguments": {
      "repoPath": "/Users/cloken/code/KitchenSink",
      "symbolName": "MCPToolHandler"
    }
  }
}
```

**Response:**
```json
{
  "dependents": [
    {"filePath": "Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler.swift", "type": "conform"},
    {"filePath": "Shared/AgentOrchestration/ToolHandlers/RAGToolsHandler.swift", "type": "conform"},
    {"filePath": "Shared/AgentOrchestration/ToolHandlers/ParallelToolsHandler.swift", "type": "conform"},
    {"filePath": "Shared/AgentOrchestration/ToolHandlers/GitToolsHandler.swift", "type": "conform"}
  ]
}
```

Now I know every tool handler in the codebase without searching.

---

## Phase 3: AI Analysis (Qwen)

Get semantic understanding of what code does, not just what it contains.

### How Analysis Enriches Chunks

**Before Analysis (raw chunk):**
```json
{
  "filePath": "Shared/Services/ParallelWorktreeRunner.swift",
  "snippet": "func executeTask(_ task: SwarmTask, in worktree: WorktreeInfo) async throws -> TaskResult {...}",
  "featureTags": ["swift", "concurrency"],
  "constructType": "method"
}
```

**After Qwen Analysis:**
```json
{
  "filePath": "Shared/Services/ParallelWorktreeRunner.swift",
  "snippet": "func executeTask(_ task: SwarmTask, in worktree: WorktreeInfo) async throws -> TaskResult {...}",
  "featureTags": ["swift", "concurrency"],
  "constructType": "method",
  "aiSummary": "Executes a swarm task in an isolated git worktree, handling branch creation, agent execution, and result collection with automatic cleanup on failure",
  "aiTags": ["task-execution", "worktree-isolation", "error-handling", "async-await", "swarm-coordination"]
}
```

### How AI Tags Improve Search

**Query:** "error handling in distributed tasks"

**Without AI analysis:** Might not match because "error handling" isn't in the code text

**With AI analysis:** Matches because `aiTags` includes `["error-handling", "swarm-coordination"]` and `aiSummary` mentions "automatic cleanup on failure"

### Checking Analysis Status

```json
{
  "params": {
    "name": "rag.analyze.status",
    "arguments": {
      "repoPath": "/Users/cloken/code/KitchenSink"
    }
  }
}
```

**Response:**
```json
{
  "repoPath": "/Users/cloken/code/KitchenSink",
  "totalChunks": 2466,
  "analyzedChunks": 1122,
  "unanalyzedChunks": 1344,
  "percentAnalyzed": "45.5",
  "modelRecommendation": "Qwen2.5-Coder-3B recommended for 24GB RAM"
}
```

---

## Faceted Browsing

Get an overview of what's in a repo before searching.

**Query:**
```json
{
  "params": {
    "name": "rag.facets",
    "arguments": {
      "repoPath": "/Users/cloken/code/KitchenSink"
    }
  }
}
```

**Response (summarized):**
```json
{
  "constructTypes": [
    {"type": "method", "count": 1142},
    {"type": "structDecl", "count": 385},
    {"type": "classDecl", "count": 281},
    {"type": "actorDecl", "count": 28},
    {"type": "protocolDecl", "count": 25}
  ],
  "featureTags": [
    {"tag": "swift", "count": 250},
    {"tag": "swiftui", "count": 93},
    {"tag": "agent", "count": 59},
    {"tag": "git", "count": 100},
    {"tag": "mcp", "count": 32},
    {"tag": "swarm", "count": 8}
  ],
  "modulePaths": [
    {"path": "Local Packages/Git", "count": 51},
    {"path": "Shared/AgentOrchestration", "count": 34},
    {"path": "Shared/Distributed", "count": 13}
  ]
}
```

### What This Enables

Before I even search, I know:
- There are 28 actors (thread-safe services)
- 25 protocols define the interfaces
- Most code is in Git package and AgentOrchestration
- 8 chunks are tagged `swarm` - I can filter to just those

---

## Putting It Together: A Real Workflow

**Task:** "Add retry logic to swarm task execution"

### Without RAG (Old Way)

```
1. grep_search "swarm task" → 47 results
2. read_file SwarmTask.swift → 200 tokens, just a struct
3. grep_search "execute.*task" → 89 results  
4. read_file ParallelWorktreeRunner.swift lines 1-100 → 400 tokens
5. read_file ParallelWorktreeRunner.swift lines 100-200 → 400 tokens
6. grep_search "retry" → 12 results, none relevant
7. Finally understand where to add code
```

**Context spent finding code: ~1000+ tokens, 7 tool calls**

### With RAG (New Way)

```
1. rag.search "swarm task execution retry" → 3 results with exact locations
2. rag.dependencies on top result → shows related files
3. read_file the ONE relevant section → 300 tokens
4. Start coding
```

**Context spent finding code: ~500 tokens, 3 tool calls**

---

## Summary: Context Window Savings

| Approach | Tool Calls | Tokens for Discovery | Tokens Left for Problem |
|----------|------------|---------------------|------------------------|
| grep + read_file | 5-10 | 1000-2000 | Less |
| RAG vector search | 1-2 | 200-400 | More |
| RAG + dependencies | 2-3 | 300-500 | More |
| RAG + AI analysis | 1-2 | 200-300 | Most |

**Key Insight:** RAG doesn't just find code faster—it returns *understanding* (summaries, tags, relationships) that would otherwise require reading and analyzing multiple files.

---

## Quick Reference: RAG Tools

| Tool | Use Case |
|------|----------|
| `rag.search` (vector) | "Find code that does X" |
| `rag.search` (text) | "Find exact keyword Y" |
| `rag.facets` | "What's in this repo?" |
| `rag.dependencies` | "What does this file use?" |
| `rag.dependents` | "What uses this symbol?" |
| `rag.analyze.status` | "How much AI analysis is done?" |
| `rag.stats` | "How big is the index?" |

---

*Last updated: January 30, 2026*
