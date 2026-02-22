# RAG Embedding Model Evaluation

**Date:** 2026-01-25  
**Updated:** 2026-02-22 (Qwen re-enabled after mlx-swift 0.30.3 fix; dimension-aware search)  
**Test Corpus:** tio-front-end (Ember/TypeScript, 1,846 files, 4,043 chunks)  
**Test Type:** Vector semantic search for refactoring patterns

---

## Executive Summary

| Provider | Vector Search Quality | Speed | Recommended Use |
|----------|----------------------|-------|-----------------|
| **MLX Qwen3-Embedding-0.6B-4bit** | ✅ Good | ~5 emb/s | **Default for 24GB+ (macOS)** |
| **MLX nomic-embed-text-v1.5** | ✅ Good | ~5 emb/s | **Default for 16-24GB (macOS)** |
| **Text Search (any)** | ✅ Excellent | Fast | **Primary method for code search** |
| CodeBERT (CoreML) | ⚠️ Poor | ~90s index | Legacy fallback |
| Apple NLEmbedding | ❌ Very Poor | ~10s index | Not for code |

**Key Finding:** For code search, **text/keyword search significantly outperforms vector search** with local models tested so far. However, **MLX with nomic or Qwen** provides reasonable semantic search as a complement to text search. Dimension-aware search handles cross-machine synced repos automatically.

---

## ✅ MLX Native Swift Implementation (Jan 25-26, 2026)

### What Changed

- Added `mlx-swift-lm` package with `MLXEmbedders` library
- Created `MLXEmbeddingProvider` - **pure Swift, no Python**
- MLX is now the **default provider on macOS**
- Auto-selects model tier based on available memory
- **Bug Fix:** Mean pooling for correct embedding dimensions

### Qwen Crash Fix (Feb 2026)

The Qwen3-Embedding-0.6B-4bit-DWQ model previously crashed due to a Metal GPU race condition in mlx-swift's `clearCache`. This was fixed in **mlx-swift 0.30.3** ([PR #331: Fix race condition in clearCache causing Metal crash](https://github.com/ml-explore/mlx-swift/pull/331)).

**Qwen is now re-enabled** for machines with 24GB+ RAM. The `MLXEmbeddingProvider.recommendedModel()` function returns `.large` (Qwen, 1024d) for these machines.

### Dimension-Aware Search (Feb 2026)

When repos are synced between machines with different embedding models (e.g., Mac Studio using Qwen 1024d, laptop using nomic 768d), the vector search now:

1. **Detects dimension mismatch** between the local provider and stored embeddings
2. **Creates a temporary provider** matching the stored embedding dimensions
3. **Generates the query embedding** with the matching model
4. **Calls `searchVectorWithEmbedding()`** in RAGCore with the pre-computed vector
5. **Falls back to text search** if no matching model is available locally

This is implemented in `MCPServerService+ServerCore.swift` via `vectorSearchWithDimensionCheck()`.

### Architecture

```
LocalRAGEmbeddingProviderFactory
    ↓
MLXEmbeddingProvider (default on macOS)
    ↓
MLXEmbedders.loadModelContainer()
    ↓
HuggingFace model download (cached)
    ↓
Native MLX inference (CPU + GPU + Neural Engine)
```

### Available Model Tiers

| Tier | RAM | Model | Dims | Status | Notes |
|------|-----|-------|------|--------|-------|
| **Small** | 8GB+ | all-MiniLM-L6-v2 | 384 | ✅ Works | Fast, general purpose |
| **Medium** | 16GB+ | nomic-embed-text-v1.5 | 768 | ✅ Works | Good balance |
| **Large** | 24GB+ | Qwen3-Embedding-0.6B-4bit | 1024 | ✅ Works | Best quality, code-aware |

### Model/Machine Matrix

| Machine Memory | Selected Model | Dimensions | Status |
|----------------|----------------|------------|--------|
| < 12GB | all-MiniLM-L6-v2 | 384 | ✅ |
| 12-24GB | nomic-embed-text-v1.5 | 768 | ✅ |
| 24GB+ | Qwen3-Embedding-0.6B-4bit | 1024 | ✅ |
| 256GB (Mac Studio) | Qwen3-Embedding-0.6B-4bit | 1024 | ✅ |

### Provider Priority (Auto Mode)

1. **MLX** (macOS default) - Native Swift, uses all Apple Silicon chips
2. **CoreML** - Pre-converted models (legacy support)
3. **System** - Apple NLEmbedding (no download, poor for code)
4. **Hash** - Fallback (no semantic understanding)

### Switching Providers

```bash
# Check current config
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.config","arguments":{"action":"get"}}}' \
  http://127.0.0.1:8765/rpc

# Force MLX (default anyway)
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.config","arguments":{"action":"set","provider":"mlx"}}}' \
  http://127.0.0.1:8765/rpc

# Force CoreML (legacy)
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.config","arguments":{"action":"set","provider":"coreml"}}}' \
  http://127.0.0.1:8765/rpc
```

---

## Historical Test Results

### Provider: Apple NLEmbedding (SystemEmbeddingProvider)

**Configuration:**
- Uses Apple's built-in `NLEmbedding.sentenceEmbedding(for: .english)`
- Runs on ANE (Apple Neural Engine) when available
- Dimension: 512

**Indexing Performance:**
```
Files: 1,846  |  Chunks: 4,043  |  Time: 10,258ms (~10s)
```
✅ **Very fast** - 6-9x faster than CoreML CodeBERT

**Search Quality:**
```
Query: "form validation pattern input error message"
Results: pnpm-lock.yaml (all 10 results!)

Query: "modal dialog confirmation button cancel"  
Results: pnpm-lock.yaml (all 10 results!)
```
❌ **Terrible** - Returns lock files for every query. Apple's NLEmbedding is trained on natural language prose, not code.

---

### Provider: CodeBERT (CoreMLEmbeddingProvider)

**Configuration:**
- Microsoft CodeBERT base model converted to CoreML
- Sequence length: 256 tokens
- Dimension: 768

**Indexing Performance:**
```
Files: 1,846  |  Chunks: 4,043  |  Time: ~90,000ms (~90s)
```
⚠️ **Slow** - ~9x slower than Apple NLEmbedding

**Search Quality:**
```
Query: "form validation pattern input error message"
Results: robots.txt, adapters/, README.md, small config files

Query: "modal dialog confirmation button cancel"
Results: README.md, robots.txt, small adapter files
```
⚠️ **Poor** - Returns small/irrelevant files. Better than Apple but still not useful.

---

### Provider: Text Search (Keyword/FTS)

**Search Quality:**
```
Query: "@tracked error"
Results: 15 relevant component files ✅

Query: "restartableTask"
Results: 20 files using ember-concurrency ✅

Query: "Table THead TBody"
Results: 25 table component usages ✅

Query: "Modal Header Footer"
Results: 25 modal implementations ✅
```
✅ **Excellent** - Finds exactly what you're looking for when you know the pattern.

---

## Analysis

### Why Vector Search Fails for Code

1. **Training Data Mismatch**
   - Apple NLEmbedding: Trained on English prose (Wikipedia, news, books)
   - CodeBERT: Trained on code, but with mean pooling loses code structure
   - Neither captures Ember/TypeScript/JSX semantic patterns

2. **Chunking Issues**
   - Current chunking is line-based with token budget
   - Breaks semantic units (components, functions) arbitrarily
   - Lock files (pnpm-lock.yaml) create many similar chunks that dominate results

3. **Query Mismatch**
   - Natural language queries ("form validation") don't match code syntax
   - Code queries need exact tokens or regex patterns

### Why Apple NLEmbedding is Fast

Apple NLEmbedding runs on the **Apple Neural Engine (ANE)**:
- Dedicated ML accelerator (16 neural engine cores on M1+)
- Optimized for Apple's own models
- ~10s for 4K chunks vs ~90s for CoreML CodeBERT

However, speed doesn't matter if results are wrong.

---

## Recommended Default Provider

### Current Default: **MLX (mlx-swift-lm)**

As of Jan 25, 2026, MLX is the default provider because:

1. **Native Swift** - No Python dependencies, no external processes
2. **Apple Silicon optimized** - Uses CPU, GPU, and Neural Engine (unified memory)
3. **Code-aware models** - Qwen3-Embedding is optimized for code
4. **Memory-tiered** - Auto-selects model based on available RAM
5. **HuggingFace integration** - Models download automatically

### Provider Selection Logic

```swift
// In LocalRAGEmbeddingProviderFactory.makeAutoProvider()
#if os(macOS)
  // MLX for macOS - best Apple Silicon utilization
  return MLXEmbeddingProvider(forCodeSearch: true)
#else
  // iOS: CoreML > System > Hash
  // (MLX not available on iOS)
#endif
```

### When to Use Other Providers

| Provider | Use When |
|----------|----------|
| **MLX** | Default - macOS with Apple Silicon |
| **CoreML** | Have pre-converted model, need specific behavior |
| **System** | Need fast indexing, quality not critical |
| **Hash** | Fallback only, no semantic understanding |

---

## Better Models Available via MLX

MLXEmbedders supports these models out of the box (no conversion needed):

### Code-Specific Embedding Models

| Model | HuggingFace ID | Size | Status |
|-------|----------------|------|--------|
| **Qwen3-Embedding-0.6B-4bit** | mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ | ~300MB | ✅ Default (large tier, 24GB+) |
| nomic-embed-text-v1.5 | nomic-ai/nomic-embed-text-v1.5 | ~500MB | ✅ Medium tier (16-24GB) |
| all-MiniLM-L6-v2 | sentence-transformers/all-MiniLM-L6-v2 | ~100MB | ✅ Small tier (<16GB) |

### Adding More Models

MLXEmbedders supports BertModel, NomicBertModel, DistilBertModel, and Qwen3Model architectures. To add a new model:

1. Find an MLX-compatible model on HuggingFace (look for `mlx-community/` prefix)
2. Add to `MLXEmbeddingModelConfig.availableModels` in `MLXEmbeddingProvider.swift`
3. Model downloads automatically on first use

### Models That Would Need Conversion (Not Currently Supported)

| Model | Size | Notes |
|-------|------|-------|
| jina-embeddings-v2-base-code | 137M | Would need MLX conversion |
| Salesforce/SFR-Embedding-Code-400M_R | 400M | Not MLX format |
| gte-Qwen2-7B-instruct | 7B | Very large, may exist in mlx-community |
- Test with same corpus

---

## MCP Tool for Switching Providers

A new `rag.config` tool was added to switch providers at runtime:

```bash
# Check current config
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.config","arguments":{"action":"get"}}}' \
  http://127.0.0.1:8765/rpc

# Switch to Apple NLEmbedding (fast but poor quality)
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.config","arguments":{"action":"set","provider":"system"}}}' \
  http://127.0.0.1:8765/rpc

# Switch to CoreML CodeBERT (default)
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.config","arguments":{"action":"set","provider":"coreml"}}}' \
  http://127.0.0.1:8765/rpc
```

**Note:** Switching providers recreates the store. Existing indexes need re-indexing if embedding dimensions differ.

---

## Recommendations

### Completed ✅
1. ✅ Implemented MLX as default provider
2. ✅ Added model tiering (small/medium/large based on RAM)
3. ✅ Native Swift, no Python dependencies
4. ✅ Document vector search as experimental
5. ✅ Re-enabled Qwen3 for 24GB+ after mlx-swift 0.30.3 fix
6. ✅ Dimension-aware search for cross-machine synced repos
7. ✅ RAGCore `searchVectorWithEmbedding()` for pre-computed query vectors

### Short Term
1. Test Qwen3 search quality vs nomic on code corpora
2. Exclude lock files from indexing (pnpm-lock.yaml, package-lock.json)
3. Repo path remapping for synced repos (DB stores source machine paths)

### Medium Term
1. Add file exclusion patterns to indexer
2. Improve chunking to respect code boundaries (functions, classes)
3. Remote query embedding via Mac Studio (avoid downloading large models locally)
4. Test additional MLX models (jina if converted)

### Long Term
1. Distributed actors for model offloading to Mac Studio (#37)
2. Consider fine-tuning on codebase-specific patterns
3. Implement query preprocessing (NL → code patterns)

---

## Appendix: Test Queries

### Vector Search Queries Tested

| Query | Expected | CodeBERT Result | Apple Result |
|-------|----------|-----------------|--------------|
| "form validation pattern" | Form components | robots.txt, adapters | pnpm-lock.yaml |
| "modal dialog confirmation" | Modal components | README, adapters | pnpm-lock.yaml |
| "API error handling" | Service files | Small files | pnpm-lock.yaml |
| "loading state management" | Components with @tracked | Config files | pnpm-lock.yaml |

### Text Search Queries (All Successful)

| Query | Results | Quality |
|-------|---------|---------|
| `@tracked error` | 15 files | ✅ Relevant |
| `restartableTask` | 20 files | ✅ Relevant |
| `dropTask` | 20 files | ✅ Relevant |
| `Table THead TBody` | 25 files | ✅ Relevant |
| `Modal Header Footer` | 25 files | ✅ Relevant |
| `valibot schema` | 20 files | ✅ Relevant |
| `async model(` | 20 files | ✅ Relevant |

---

## References

- [jina-embeddings-v2-base-code](https://huggingface.co/jinaai/jina-embeddings-v2-base-code)
- [Salesforce SFR-Embedding-Code](https://huggingface.co/Salesforce/SFR-Embedding-Code-400M_R)
- [gte-Qwen2-1.5B-instruct](https://huggingface.co/Alibaba-NLP/gte-Qwen2-1.5B-instruct)
- [CodeBERT](https://huggingface.co/microsoft/codebert-base)
- [Apple NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding)
