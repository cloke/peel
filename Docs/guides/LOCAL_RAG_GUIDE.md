# Local RAG Guide

**Created:** February 19, 2026
**Status:** Active

---

## Overview

Peel's Local RAG (Retrieval-Augmented Generation) indexes your codebase for semantic search entirely on-device using MLX embeddings. No cloud APIs required.

Key capabilities:
- **Hybrid search** — Combined text + vector search with RRF (Reciprocal Rank Fusion)
- **MLX embeddings** — On-device embedding generation using Apple Silicon
- **Dependency graph** — Module-level dependency tracking with D3 visualization
- **Lessons** — Learned error-to-fix patterns for agent guidance
- **Skills** — Repo-scoped rules injected into agent prompts
- **Code analysis** — MLX LLM-powered chunk analysis and enrichment
- **Branch-aware** — Separate indexing for worktrees and feature branches

---

## Getting Started

### Index a Repository

**From the UI:**
1. Navigate to **Agents > Local RAG** in the sidebar
2. Enter a repository path
3. Click **Index Repository**

**Via MCP:**
```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0", "id": 1,
    "method": "tools/call",
    "params": {
      "name": "rag.index",
      "arguments": {
        "repoPath": "/path/to/your/repo"
      }
    }
  }'
```

### Check Index Status

```bash
# RAG store status
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.status","arguments":{}}}'

# List indexed repos
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.repos.list","arguments":{}}}'
```

---

## Search Modes

### Text Search
Keyword matching with AND/OR logic. Best for exact code snippets and function names.

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"rag.search",
      "arguments":{
        "query":"validateForm",
        "repoPath":"/path/to/repo",
        "mode":"text",
        "limit":10,
        "matchAll":true
      }
    }
  }'
```

### Vector Search
Semantic similarity using MLX embeddings. Best for conceptual queries.

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"rag.search",
      "arguments":{
        "query":"how does authentication work",
        "repoPath":"/path/to/repo",
        "mode":"vector",
        "limit":5
      }
    }
  }'
```

### Hybrid Search (Recommended)
Combines text + vector results using Reciprocal Rank Fusion. Best overall quality.

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"rag.search",
      "arguments":{
        "query":"error handling middleware",
        "repoPath":"/path/to/repo",
        "mode":"hybrid",
        "limit":10
      }
    }
  }'
```

### Search Filters

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | string | Search query |
| `repoPath` | string | Repository path |
| `mode` | string | `text`, `vector`, or `hybrid` |
| `limit` | int | Max results (default: 10) |
| `excludeTests` | bool | Skip test/spec files |
| `constructType` | string | Filter: `function`, `classDecl`, `component`, `method` |
| `matchAll` | bool | Text mode: `true` = AND, `false` = OR |

---

## Embedding Configuration

### Providers

| Provider | Description | Quality | Setup |
|----------|-------------|---------|-------|
| `mlx` | MLX native on Apple Silicon | Best | Default, auto-downloads model |
| `system` | Apple NLEmbedding | Good | Built-in, no setup |
| `hash` | Fallback hash-based | Basic | Always available |

### Change Provider

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"rag.config",
      "arguments":{"action":"set","key":"embeddingProvider","value":"mlx"}
    }
  }'
```

### MLX Models

Default: `nomic-embed-text-v1.5` (768 dimensions). Auto-selected by RAM:
- 8GB: MiniLM (384 dims, faster)
- 16GB+: nomic (768 dims, better quality)

```bash
# List available models
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.model.list","arguments":{}}}'

# Set model
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.model.set","arguments":{"modelId":"nomic-ai/nomic-embed-text-v1.5"}}}'

# Test embeddings
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.embedding.test","arguments":{}}}'
```

### HuggingFace Reranker

Enable a reranker for improved search result ordering:

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"rag.reranker.config",
      "arguments":{"apiToken":"hf_...","modelId":"cross-encoder/ms-marco-MiniLM-L-6-v2"}
    }
  }'
```

---

## Lessons (Error-to-Fix Learning)

Lessons capture recurring error patterns and their fixes. They are injected into chain prompts to help agents avoid repeating mistakes.

### View Lessons

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.lessons.list","arguments":{}}}'
```

### Add a Lesson

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"rag.lessons.add",
      "arguments":{
        "filePattern":"*.swift",
        "errorSignature":"Cannot convert value of type",
        "fixDescription":"Add explicit type annotation or use as? cast",
        "fixCode":"let value = rawValue as? String ?? \"\"",
        "confidence":0.8
      }
    }
  }'
```

### Query Lessons

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"rag.lessons.query",
      "arguments":{"errorSignature":"Cannot convert value"}
    }
  }'
```

---

## Skills (Repo Guidance)

Skills are short, repo-scoped rules injected into agent prompts.

### List Skills

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.skills.list","arguments":{}}}'
```

### Add a Skill

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{
      "name":"rag.skills.add",
      "arguments":{
        "content":"Use @Observable instead of ObservableObject for all new ViewModels"
      }
    }
  }'
```

### Auto-Detect Skills (Ember)

```bash
# Detect skill candidates from code patterns
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.skills.ember.detect","arguments":{}}}'
```

### Export/Import/Sync

```bash
# Export to .peel/skills.json
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.skills.export","arguments":{}}}'

# Import from .peel/skills.json
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.skills.import","arguments":{}}}'

# Two-way sync
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.skills.sync","arguments":{}}}'
```

---

## Code Intelligence

### Dependency Analysis

```bash
# What does a file depend on?
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.dependencies","arguments":{"filePath":"Shared/PeelApp.swift","repoPath":"/path/to/repo"}}}'

# What depends on this file?
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.dependents","arguments":{"filePath":"Shared/PeelApp.swift","repoPath":"/path/to/repo"}}}'
```

### Analytics

| Tool | Description |
|------|-------------|
| `rag.stats` | Index statistics |
| `rag.largefiles` | Large files (refactor candidates) |
| `rag.hotspots` | Change hotspots |
| `rag.duplicates` | Duplicate code detection |
| `rag.orphans` | Potentially unused files |
| `rag.facets` | Language/type distribution |
| `rag.patterns` | Known code patterns |
| `rag.constructtypes` | Construct type breakdown |
| `rag.similar` | Find similar code chunks |
| `rag.structural` | Query by structural characteristics |

---

## Branch-Aware Indexing

Index worktrees and feature branches separately:

```bash
# Index a specific branch
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.branch.index","arguments":{"repoPath":"/path/to/repo","branchName":"feature/my-feature"}}}'

# Clean up after merge
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.branch.cleanup","arguments":{"repoPath":"/path/to/repo","branchName":"feature/my-feature"}}}'
```

---

## Maintenance

### Re-index a Repository

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.index","arguments":{"repoPath":"/path/to/repo","forceReindex":true}}}'
```

### Remove a Repository

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.repos.delete","arguments":{"repoPath":"/path/to/repo"}}}'
```

### Clear Cache

```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.cache.clear","arguments":{}}}'
```

### Auto-Resume

If the app quits during indexing, interrupted operations automatically resume on next launch.

---

## Troubleshooting

### Search Returns No Results
1. Verify the repo is indexed: `rag.repos.list`
2. Try a different search mode (text vs vector vs hybrid)
3. Re-index with `forceReindex: true`
4. Check provider: `rag.config` with `action: "get"`

### Indexing Stalls
1. Auto-resume handles most cases on next launch
2. Cancel and restart from the RAG dashboard
3. Check memory — MLX models need sufficient RAM
4. `rag.cache.clear` and re-index

### Embedding Quality Issues
1. Test with `rag.embedding.test` to verify dimensions and timing
2. Try switching providers (`mlx` vs `system`)
3. Enable HuggingFace reranker for better result ordering

---

## Related Docs

- [PRODUCT_MANUAL.md](../PRODUCT_MANUAL.md) — Full MCP API reference
- [MCP_AGENT_WORKFLOW.md](MCP_AGENT_WORKFLOW.md) — Chain execution workflow
- [RAG_EMBEDDING_MODEL_EVALUATION](../reference/RAG_EMBEDDING_MODEL_EVALUATION.md) — Embedding model benchmarks
