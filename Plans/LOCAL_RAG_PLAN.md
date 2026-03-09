---
title: Local RAG for Codebase Context
status: v1-complete
created: 2026-01-19
updated: 2026-01-30
audience: [developers]
related_issues:
  - https://github.com/cloke/peel/issues/74
related_docs:
  - Plans/ROADMAP.md
  - Plans/apple-agent-big-ideas.md
---

# Local RAG for Codebase Context

## Summary
Create an always-on, local vector index for repository context that powers fast semantic search for agents without uploading code. This introduces an embedded vector DB and a lightweight indexing pipeline with tiered memory (hot/warm/cold), deduplication, and an embedding cache.

## Current Status (Jan 30, 2026)

### ✅ V1 Complete
- Local SQLite-backed `LocalRAGStore` with schema v6
- Repo scanning + AST-based chunking (Swift, Ruby, TypeScript/JS)
- MLX embeddings (default) with Core ML and System fallbacks
- MCP tools (`rag.init`, `rag.index`, `rag.search`, `rag.status`, `rag.dependencies`, `rag.structural`, `rag.similar`)
- Dependency graph indexing and visualization
- Structural queries (file size, method count)
- Similar code detection
- Performance optimizations (batching, caching)

### Phase 3 Layer 2 Complete
- Code Intelligence Graph fully operational
- Metadata extraction (imports, protocols, decorators, frameworks)
- Module path and feature tag facets

### March 2026 Follow-up Progress
- Seeded language-agnostic symbol metadata in `ASTChunkMetadata` via `symbolDefinitions` and `symbolReferences`
- Kept metadata backward-compatible with older stored JSON that lacks symbol fields
- Enabled production `ASTChunkerService` routing for TypeScript-family files through `JSCoreTypeScriptChunker`
- Preserved `GlimmerChunker` as the preferred parser for `gts`/`gjs`, with JSCore fallback when Glimmer parsing is unavailable

### Return-Later Next Steps
1. Persist normalized symbols into the RAG store schema instead of keeping them chunk-local only
2. Add MCP/RAG queries for symbol definitions, symbol references, and unused-symbol candidates
3. Add confidence scoring by parser path so SwiftSyntax, Glimmer tree-sitter, JSCore TypeScript, and line fallback are not treated equally
4. Extend dead-code analysis from file-level orphans to symbol-level candidates (types, methods, properties, components)
5. Add framework-aware symbol edges for runtime discovery patterns, especially SwiftUI, SwiftData, and Ember/Glimmer template wiring

## Goals
- Local-only semantic search for repos in Peel workspaces.
- Single-file, embedded storage with fast reads.
- Incremental indexing and file-level updates.
- Tiered memory and embedding cache to reduce recompute.
- Cross-agent context deduplication.

## Non-Goals (v1)
- Multi-machine sync.
- Remote or cloud indexing.
- Full text search ranking parity with cloud engines.

## Database Choice
**Primary recommendation: SQLite + `sqlite-vec` extension**
- Embedded, single-file, cross-platform (macOS + iOS).
- Works well with Swift (no daemon, no network, simple lifecycle).
- Supports vector similarity search in-process.
- Pairs cleanly with FTS5 for keyword + hybrid search.

**Why not a separate service?**
A local daemon adds lifecycle complexity, permission handling, and sandbox friction. SQLite keeps everything inside the app sandbox and fits the “local-first” constraint.

## Embedding Model Choice
**MVP**: On-device embeddings via Core ML model bundle.
- Ship a small, general-purpose embedding model as a Core ML asset.
- Run on ANE when available, fallback to GPU/CPU.
- Keep the interface behind `EmbeddingProvider` so we can swap later.

**Fallback (optional)**: External embedding API (disabled by default).
- Only if user explicitly enables cloud embeddings.
- Keep data strictly opt-in with clear UI warnings.

## MVP Scope (Phase 1)
- Index a single repo at a time (current workspace selection).
- Basic chunking (line-based with max token budget).
- Store embeddings in SQLite + sqlite-vec.
- Search top-k by vector similarity.
- Simple UI or MCP tool exposure to fetch results.

## Dependency Strategy
- Add a SwiftPM package for SQLite with extension support (e.g., `SQLite.swift` or direct `sqlite3` C API wrapper).
- Bundle `sqlite-vec` as a C module and load it at runtime via `sqlite3_load_extension`.
- Store the DB file in Application Support under a dedicated subfolder (e.g., `Application Support/Peel/RAG/`).
- Provide a single `LocalRAGStore` actor that owns the DB connection and exposes async methods.

## High-Level Architecture
```
IndexingService
  -> FileScanner (git-aware, ignores build/derived data)
  -> Chunker (language-aware, size-bounded)
  -> EmbeddingProvider (local model or API)
  -> LocalRAGStore (SQLite + sqlite-vec)

QueryService
  -> Embed query
  -> Vector search
  -> Optional FTS5 rerank
  -> Context assembly + dedupe
```

## Data Model (SQLite)
- `files` (id, repo_id, path, hash, language, updated_at)
- `chunks` (id, file_id, start_line, end_line, text, token_count)
- `embeddings` (chunk_id, embedding VECTOR)
- `cache_embeddings` (text_hash, embedding VECTOR, updated_at)
- `repos` (id, name, root_path, last_indexed_at)

## Indexing Pipeline
1. Scan repos (respect `.gitignore`, skip build artifacts).
2. Chunk files by language heuristics with max token budget.
3. Hash chunks and reuse cached embeddings when possible.
4. Insert/update chunk records, delete stale entries.
5. Maintain hot tier for recently-accessed chunks.

## Query Flow
1. Embed query string.
2. Vector search across relevant repos (top-k).
3. Optional keyword/FTS rerank.
4. Deduplicate by file + chunk hash.
5. Return snippets + metadata + file refs.

## APIs (Swift)
- `LocalRAGStore.index(repoURL:)`
- `LocalRAGStore.search(query: repoScope:) -> [ContextSnippet]`
- `LocalRAGStore.delete(repoID:)`
- `LocalRAGStore.stats() -> RAGStats`

## Observability
- Indexing throughput (files/sec, chunks/sec).
- Query latency p50/p95.
- Embedding cache hit rate.
- DB size by repo.

## Security & Privacy
- All data stored locally.
- No code or embeddings leave the device by default.
- Option to purge per-repo index.

## Milestones
1. **MVP**: SQLite + sqlite-vec, repo indexing, basic semantic search.
2. **Hybrid Search**: add FTS5 + reranking.
3. **Tiered Memory**: hot/warm/cold eviction strategy.
4. **Deduper + Cache**: cross-agent embedding cache.

## Phase 1 Remaining Work
1. **Core ML embeddings** ([#74](https://github.com/cloke/peel/issues/74))
  - `EmbeddingProvider` protocol and Core ML backend.

## Open Questions
- Preferred embedding model (local vs API)?
- Target max DB size per repo?
- How to expose results in UI vs MCP tool surface?
