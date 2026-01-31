---
title: RAG Architecture V2 - Long-term Design
status: partially-implemented
created: 2026-01-25
updated: 2026-01-30
tags:
  - rag
  - architecture
  - performance
audience:
  - developer
  - ai-agent
notes: Many proposals implemented. MLX embeddings replaced CoreML. Python tokenizer eliminated.
---

# RAG Architecture V2 - Long-term Design

**Created:** January 25, 2026  
**Status:** Partially Implemented  
**Related:** LOCAL_RAG_PLAN.md, Issue #74

> **Note (Jan 30):** Many of the issues described below have been resolved:
> - ✅ Python tokenizer eliminated - now using native Swift
> - ✅ MLX embeddings with batching
> - ✅ Progress reporting added
> - ⚪ Per-repo SQLite still pending (single DB works well for now)

---

## Problem Statement

The current RAG implementation has several critical issues that prevent it from scaling:

### Performance Issues

| Issue | Impact | Root Cause |
|-------|--------|------------|
| 45+ min indexing for large repos | Unusable for real workloads | Python tokenizer spawns per-chunk |
| Sequential embedding generation | ~2s per chunk with Core ML | No batching or parallelism |
| Full re-index on partial changes | Wasted compute | Coarse-grained change detection |

### Architectural Issues

| Issue | Risk | Current State |
|-------|------|---------------|
| Single SQLite for all repos | Data corruption, contention | `rag.sqlite` holds everything |
| No index isolation | Delete one repo affects query perf | Foreign keys only |
| Embedding dimension mismatch | Comparison errors | 512 vs 768 dims mixed |
| No progress reporting | User frustration | Silent long operations |

---

## Performance Root Cause Analysis

### The Python Tokenizer Problem

```
Current flow (per chunk):
  1. Fork Python process (~100ms)
  2. Python imports transformers (~500ms cold, ~50ms warm)
  3. Load tokenizer config (~20ms)
  4. Tokenize single text (~5ms)
  5. Serialize JSON output (~2ms)
  6. Process cleanup (~10ms)

Total per chunk: ~200-700ms
For 1500 chunks: 5-17 minutes JUST for tokenization
```

### The Embedding Problem

```
Current flow:
  1. Tokenize chunk (see above)
  2. Run Core ML prediction (~50ms per chunk)
  3. No batching - each chunk is a separate prediction

For 1500 chunks: ~75 seconds for Core ML alone
But tokenization dominates: 5-17 minutes
```

---

## Proposed Architecture

### Option A: Per-Repo SQLite Files (Recommended)

```
~/Library/Application Support/Peel/RAG/
├── meta.sqlite              # Global: repo registry, settings
├── repos/
│   ├── {repo-hash-1}.sqlite # Chunks, embeddings for repo 1
│   ├── {repo-hash-2}.sqlite # Chunks, embeddings for repo 2
│   └── ...
├── cache/
│   └── embeddings.sqlite    # Global embedding cache by content hash
└── Models/
    └── codebert-base-256.mlmodelc
```

**Benefits:**
- Complete isolation - deleting a repo is `rm file.sqlite`
- No contention during parallel indexing
- Can index multiple repos simultaneously
- Easy backup/restore per repo
- Database size stays manageable

**Trade-offs:**
- Cross-repo search requires opening multiple connections
- More file management logic

### Option B: Single DB with Better Isolation (Alternative)

Keep single `rag.sqlite` but:
- Use WAL mode for better concurrency
- Add explicit transactions around repo operations
- Add progress tracking table
- Better error recovery

**Trade-offs:**
- Still risk of corruption affecting all repos
- Simpler code but less robust

### Recommendation: Option A

For a "best-in-class AI companion", isolation and reliability matter more than code simplicity.

---

## Tokenizer Fix (Critical)

### Current: External Python (Unusable at Scale)

```swift
// Spawns Python for EVERY chunk
func encode(_ text: String, maxLength: Int) -> ([Int32], [Int32]) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  // ... runs for each of 1500 chunks = 1500 Python processes
}
```

### Fix Option 1: Batch Python Tokenizer (Quick Win)

Modify `tokenize_codebert.py` to accept multiple texts:

```python
# Input: JSON array of texts
# Output: JSON array of {input_ids, attention_mask}
```

Swift side sends all chunk texts in one call, gets all tokens back.

**Expected improvement:** 5-17 min → 30-60 seconds

### Fix Option 2: Native Swift BPE Tokenizer (Best)

Implement BPE tokenization in Swift using the vocab.json:

```swift
struct SwiftBPETokenizer: LocalRAGTokenizer {
  private let vocab: [String: Int]
  private let merges: [(String, String)]
  
  func encode(_ text: String, maxLength: Int) -> ([Int32], [Int32]) {
    // Pure Swift, no process spawn, ~1ms per chunk
  }
}
```

**Expected improvement:** 5-17 min → 2-3 seconds for tokenization

### Fix Option 3: Use SimpleVocabTokenizer (Immediate)

The existing `SimpleVocabTokenizer` is fast but naive (word-level, not BPE).

For v1, we could:
1. Default to SimpleVocabTokenizer (fast but lower quality)
2. Offer "high quality mode" that uses Python batch tokenizer
3. Long-term: ship Swift BPE

---

## Embedding Generation Improvements

### Current: Sequential, One at a Time

```swift
for text in texts {
  let embedding = try await model.prediction(...)  // Sequential
}
```

### Improved: Batch Predictions

Core ML supports batch prediction:

```swift
let batchProvider = MLArrayBatchProvider(array: featureProviders)
let batchResults = try model.predictions(from: batchProvider)
```

**Expected improvement:** Linear speedup with batch size (up to GPU limits)

### Improved: Async Parallel Processing

```swift
await withTaskGroup(of: ([Float], Int).self) { group in
  for (index, chunk) in chunks.enumerated() {
    group.addTask {
      let embedding = try await self.embed(chunk)
      return (embedding, index)
    }
  }
}
```

---

## Progress Reporting

Add observable progress to indexing:

```swift
struct IndexingProgress: Sendable {
  let phase: Phase  // scanning, chunking, tokenizing, embedding, storing
  let current: Int
  let total: Int
  let currentFile: String?
  let estimatedSecondsRemaining: Int?
  
  enum Phase { case scanning, chunking, tokenizing, embedding, storing }
}

// Observable from UI
@Published var indexingProgress: IndexingProgress?
```

---

## Migration Path

### Phase 1: Quick Wins (This Week)
1. ✅ Add missing file extensions (gts, gjs, etc.) - DONE
2. ✅ Improve text search for multi-word queries - DONE
3. [ ] Switch to batch Python tokenizer
4. [ ] Add progress reporting

### Phase 2: Performance (Next Week)
1. [ ] Implement Swift BPE tokenizer
2. [ ] Add batch Core ML predictions
3. [ ] Parallelize embedding generation

### Phase 3: Architecture (Following Week)
1. [ ] Migrate to per-repo SQLite files
2. [ ] Add cross-repo search coordinator
3. [ ] Implement proper error recovery

### Phase 4: Polish
1. [ ] Add embedding dimension validation
2. [ ] Re-index repos with mismatched dimensions
3. [ ] Add index health checks

---

## Model Selection Recommendations

### Current: CodeBERT (768-dim)
- Pros: Trained on code, good semantic understanding
- Cons: Large, slow, requires careful tokenization

### Alternative: all-MiniLM-L6-v2 (384-dim)
- Pros: 2x faster, smaller embeddings, well-tested
- Cons: Not code-specific

### Alternative: CodeSage (256-dim)
- Pros: Code-focused, small, fast
- Cons: Less common, may need conversion

### Recommendation
1. Keep CodeBERT for "high quality" mode
2. Add smaller model option for "fast" mode
3. Let user choose based on their needs

---

## Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Index 1000 files | 45 min | < 2 min |
| Index 100 files | 5 min | < 15 sec |
| Search latency (text) | 50ms | < 20ms |
| Search latency (vector) | 200ms | < 50ms |
| Memory during indexing | 2GB+ | < 500MB |

---

## Open Questions

1. Should we support remote/cloud embedding APIs as fallback?
2. How to handle very large repos (100k+ files)?
3. Should we pre-index common frameworks/libraries?
4. How to handle monorepos with multiple logical projects?

---

## References

- [SQLite WAL Mode](https://sqlite.org/wal.html)
- [Core ML Batch Predictions](https://developer.apple.com/documentation/coreml/mlmodel/2880280-predictions)
- [BPE Tokenization](https://huggingface.co/learn/nlp-course/chapter6/5)
