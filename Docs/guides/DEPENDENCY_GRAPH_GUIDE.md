# Dependency Graph Indexing

**Issue**: [#176](https://github.com/cloke/peel/issues/176)  
**Status**: Complete (Jan 30, 2026)  
**Layer**: 2 - Code Intelligence

---

## Overview

The dependency graph tracks **how files relate to each other** through imports, inheritance, and other relationships. Before this feature, the RAG system knew *what* was in each file (through chunk embeddings), but not *how* files connect.

## Visual Example

```
                    ┌─────────────────┐
                    │ ApplicationRecord│
                    └────────┬────────┘
                             │ inherit
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
    ┌─────────┐        ┌─────────┐        ┌─────────┐
    │  User   │        │  Post   │        │  Comment│
    └────┬────┘        └─────────┘        └─────────┘
         │ include
    ┌────▼────┐
    │PgSearch │
    │::Model  │
    └─────────┘
```

This is a **directed graph** where:
- **Nodes** = Files or symbols (User, ApplicationRecord, etc.)
- **Edges** = Relationships (inherit, include, import)

---

## MCP Tools

### `rag.dependencies`

Query what a file depends on (forward lookup).

```bash
curl -X POST http://127.0.0.1:8765/rpc -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "rag.dependencies",
      "arguments": {
        "filePath": "app/models/user.rb",
        "repoPath": "/path/to/repo"
      }
    }
  }'
```

**Response:**
```json
{
  "count": 3,
  "filePath": "app/models/user.rb",
  "dependencies": [
    {"dependencyType": "include", "targetPath": "LegacySoftDelete"},
    {"dependencyType": "include", "targetPath": "PgSearch::Model"},
    {"dependencyType": "inherit", "targetPath": "ApplicationRecord"}
  ]
}
```

### `rag.dependents`

Query what depends on a target (reverse lookup).

```bash
curl -X POST http://127.0.0.1:8765/rpc -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "rag.dependents",
      "arguments": {
        "filePath": "ApplicationRecord",
        "repoPath": "/path/to/repo"
      }
    }
  }'
```

**Response:**
```json
{
  "count": 217,
  "targetPath": "ApplicationRecord",
  "dependents": [
    {"dependencyType": "inherit", "filePath": "app/models/user.rb"},
    {"dependencyType": "inherit", "filePath": "app/models/post.rb"},
    // ... 215 more
  ]
}
```

---

## Dependency Types

| Type | Language | Example |
|------|----------|---------|
| `import` | Swift, TS/JS | `import Foundation`, `import { foo } from 'bar'` |
| `require` | Ruby, JS | `require 'json'`, `require('module')` |
| `include` | Ruby | `include Concern` |
| `extend` | Ruby | `extend ClassMethods` |
| `inherit` | All | `class Foo < Bar`, `class Foo extends Bar` |
| `conform` | Swift | `struct X: Codable, Sendable` |

---

## Architecture

### Code Flow

```
┌──────────────┐     ┌───────────────┐     ┌──────────────┐
│ ASTChunker   │────▶│ LocalRAGStore │────▶│   SQLite     │
│ (extracts    │     │ (stores deps) │     │ (queries)    │
│  metadata)   │     └───────────────┘     └──────────────┘
└──────────────┘              │
                              ▼
                    ┌───────────────┐
                    │RAGToolsHandler│
                    │ .dependencies │
                    │ .dependents   │
                    └───────────────┘
```

### Database Schema (v5)

```sql
CREATE TABLE dependencies (
    id INTEGER PRIMARY KEY,
    source_file_id INTEGER NOT NULL,  -- The file that HAS the dependency
    target_path TEXT NOT NULL,        -- What it depends ON (path or symbol)
    dependency_type TEXT NOT NULL,    -- import/inherit/include/conform/etc
    target_file_id INTEGER,           -- Resolved file ID (if internal)
    UNIQUE(source_file_id, target_path, dependency_type),
    FOREIGN KEY (source_file_id) REFERENCES files(id)
);

CREATE INDEX idx_dependencies_source ON dependencies(source_file_id);
CREATE INDEX idx_dependencies_target ON dependencies(target_path);
```

### Extraction Logic

Located in [LocalRAGStore.swift](../../Shared/Services/LocalRAGStore.swift):

```swift
func extractDependencies(from metadata: ASTChunkMetadata, ...) {
    // Parse imports: "import Foundation" → (import, Foundation)
    // Parse inheritance: "class Foo: Bar" → (inherit, Bar)
    // Parse protocols: "struct X: Codable" → (conform, Codable)
    // Parse mixins: "include PgSearch::Model" → (include, PgSearch::Model)
}
```

Key implementation details:
- Deduplicates per-file to avoid redundant edges
- Extracts from `ASTChunkMetadata` which is already populated by chunkers
- Stores at indexing time, queries at runtime

---

## Use Cases

### Impact Analysis

Before changing `ApplicationRecord`, see how many files will be affected:

```bash
# Returns 217 models that inherit from it!
rag.dependents(filePath: "ApplicationRecord", repoPath: "/path/to/rails-app")
```

### Architecture Understanding

"Show me all files that import the Auth module":

```bash
rag.dependents(filePath: "AuthModule", repoPath: "/path/to/app")
```

### Refactoring Safety

Planning to rename `PgSearch::Model`? Query dependents first to know the blast radius.

### Onboarding

New to a codebase? Query dependencies to understand what a file needs:

```bash
rag.dependencies(filePath: "app/controllers/users_controller.rb", ...)
```

---

## Testing Results

| Language | Example | Result |
|----------|---------|--------|
| Swift | LocalRAGStore.swift | 10 deps (imports + protocol conformance) |
| Ruby | app/models/user.rb | 3 deps (includes + inherit) |
| Ruby | ApplicationRecord dependents | 217 models inherit from it |
| TypeScript | router.ts | imports + EmberRouter inherit |

---

## Follow-up Work

Tracked in [#208](https://github.com/cloke/peel/issues/208):

- [ ] Resolve target file IDs for internal imports
- [ ] Populate symbols table for symbol-level queries
- [ ] Add dependency counts to `rag.stats`
- [ ] Call graph extraction (function/method calls)

---

## Related

- [RAG Architecture V2](../../Plans/RAG_ARCHITECTURE_V2.md) - Overall RAG design
- [LOCAL_RAG_PLAN.md](../../Plans/LOCAL_RAG_PLAN.md) - Original RAG planning
- [MCP Agent Workflow](MCP_AGENT_WORKFLOW.md) - How to use MCP tools
