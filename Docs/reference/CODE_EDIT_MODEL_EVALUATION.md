# Local Code Editing — Model Evaluation Report

**Date:** February 10, 2025  
**Machine:** Mac Studio, 256GB RAM, Apple Silicon  
**MLX Framework:** MLX Swift (MLXLLM, MLXLMCommon via LLMModelFactory)  
**MCP Server:** Peel MCP on port 8765

---

## Executive Summary

Tested local on-device code editing through Peel's `code.edit` MCP tool using two Qwen model tiers. The **Qwen3-Coder-30B-A3B** (MoE, 4-bit) significantly outperforms the **Qwen2.5-Coder-7B** across all test categories, with the critical difference being in error handling and complex refactoring tasks where the 7B model loses existing logic while the 30B preserves it.

**Key Finding:** Qwen3-Coder-Next (the original target model) uses an unsupported `qwen3_next` architecture in MLX Swift's LLMModelFactory. The Qwen3-Coder-30B-A3B (Mixture of Experts) is the best compatible alternative for the large tier.

---

## Model Configuration

| Tier | Model | HF Repo | Architecture | Size | Status |
|------|-------|---------|-------------|------|--------|
| Small | Qwen2.5-Coder-7B | `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` | `qwen2` | ~4GB | ✅ Works |
| Medium | Qwen2.5-Coder-14B | `lmstudio-community/Qwen2.5-Coder-14B-Instruct-MLX-4bit` | `qwen2` | ~8GB | ✅ Configured |
| Large | Qwen3-Coder-30B-A3B | `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit` | `qwen3_moe` | ~17GB | ✅ Works |
| ~~Large~~ | ~~Qwen3-Coder-Next~~ | ~~`mlx-community/Qwen3-Coder-Next-4bit`~~ | ~~`qwen3_next`~~ | ~~~48GB~~ | ❌ Unsupported |

### Supported vs Unsupported Architectures

MLX Swift's `LLMModelFactory` supports: `qwen2`, `qwen3`, `qwen3_moe`  
**NOT supported:** `qwen3_next` (used by Qwen3-Coder-Next)

The `qwen3_next` model type maps to `Qwen3NextForCausalLM` which is a newer architecture not yet in the MLX Swift library. Error: `"Unsupported model type: qwen3_next"`.

---

## Test Results Summary

### Test Matrix

| # | Task | Model | Duration | Tokens | Grade | Key Issue |
|---|------|-------|----------|--------|-------|-----------|
| 1 | Modernize ObservableObject | 7B | 7.3s | 501 | C+ | Leftover Combine, @MainActor misplaced |
| 2 | Extract Method | 7B | 3.2s | 174 | A | Perfect extraction |
| 3 | Add Error Handling | 7B | 9.5s | 577 | D | Lost existing logic, API mistakes |
| 4 | Rename (diff mode) | 7B | 67.6s | 4096 | F | Infinite repetition loop |
| 5 | Modernize ObservableObject | 30B | 29.1s | 676 | A- | Minor spacing issue only |
| 6 | Extract Method | 30B | 32.6s | 767 | A | Clean, all logic preserved |
| 7 | Add Error Handling | 30B | 37.2s | 823 | A- | All logic preserved, proper throws |
| 8 | Rename (diff mode) | 30B | 32.3s | 709 | B+ | Output full file instead of diffs |

### Speed Comparison

| Metric | 7B | 30B | Notes |
|--------|-----|------|-------|
| Tokens/sec | ~69 tok/s | ~23 tok/s | 7B is 3x faster |
| Typical edit | 3-10s | 29-37s | 30B takes ~4x longer |
| Cold start (download) | ~2 min | ~17 min | First-time download |
| Memory usage | ~4GB | ~17GB | 30B uses MoE (3B active params) |

---

## Detailed Test Analysis

### Test 1: Modernize ObservableObject → @Observable (7B)
**Input:** Synthetic SwiftUI ViewModel using ObservableObject, @Published, Combine debounce, DispatchQueue  
**Result:** Partially correct. Issues:
- ❌ Left `AnyCancellable` import (`import Combine` removed but artifact remained)
- ❌ `@MainActor` placed on individual methods instead of class level
- ❌ `Task.sleep(nanoseconds:)` used without `try` (it throws)
- ❌ Combine debounce not fully replaced (logic incomplete)
- ✅ `@Observable` macro correctly applied
- ✅ `@Published` properties removed

### Test 2: Extract Method (7B)
**Input:** RepoTechDetector.swift — extract Ember detection into `checkPackageForEmber(at:)`  
**Result:** Excellent.
- ✅ Correct method signature and return type
- ✅ Proper delegation from `isEmberRepo`
- ✅ All existing logic preserved
- ✅ Swift style consistent

### Test 3: Add Error Handling (7B)
**Input:** Add `RepoDetectionError` enum, make `loadPackageJSON` throw, add do-catch  
**Result:** Fundamentally broken.
- ✅ Created `RepoDetectionError` enum correctly
- ❌ **Lost all dependency-scanning logic** (containsEmberDependency, stringArray calls gone)
- ❌ **Lost keyword checking** from isEmberRepo
- ❌ Treated `Data(contentsOf:)` as returning optional (it throws)
- ❌ Would not compile as written

### Test 4: Rename Variables — diff mode (7B)
**Input:** Rename `isEmberRepo` → `detectEmberFramework`, `repoPath` → `repositoryPath`  
**Result:** Individual diffs were correct but output was unusable.
- ✅ Each individual diff hunk was correct
- ❌ **Infinite repetition loop** — same diffs repeated endlessly
- ❌ Hit maxTokens (4096) without stopping
- ❌ 67.6 seconds wasted on repeated output

### Test 5: Modernize ObservableObject → @Observable (30B)
**Input:** Same synthetic ViewModel as Test 1  
**Result:** Clean and correct.
- ✅ `@Observable` macro properly applied
- ✅ `@MainActor` on class level (correct placement)
- ✅ All `@Published` removed, regular stored properties used
- ✅ Combine completely removed (no artifacts)
- ✅ `try? await Task.sleep(for: .seconds(...))` — correct modern API
- ✅ Task-based debounce with cancellation properly implemented
- ✅ Added `setUsername(_:)` method for debounce trigger
- ⚠️ Minor: `name.count< 3` missing space before `<`

### Test 6: Extract Method (30B)
**Input:** Same extraction as Test 2  
**Result:** Clean and correct.
- ✅ Method extracted with correct signature
- ✅ All helper methods preserved
- ✅ Proper delegation flow
- ✅ Verbose but complete output (767 vs 174 tokens for 7B)

### Test 7: Add Error Handling (30B)
**Input:** Same error handling task as Test 3  
**Result:** Dramatically better than 7B.
- ✅ `RepoDetectionError` enum with all three cases
- ✅ `loadPackageJSON` properly throws
- ✅ `isEmberRepo` uses do-catch correctly
- ✅ **ALL existing logic preserved** (dependency scanning, keyword checking, helper methods)
- ✅ Error logging with `print()`
- ⚠️ Minor: Uses `try?` to suppress original `Data(contentsOf:)` error before rethrowing custom error

### Test 8: Rename — diff mode (30B)
**Input:** Same rename task as Test 4  
**Result:** Correct output, wrong format.
- ✅ All renames applied correctly
- ✅ Call sites updated properly
- ✅ `detectTags` correctly keeps local `repoPath` variable (not part of rename)
- ✅ **No infinite repetition** — clean termination within token budget
- ⚠️ Output was full file, not unified diff format (ignored diff mode)
- 709 tokens (vs 7B's runaway 4096)

---

## Infrastructure Issues Discovered

### 1. HTTP Timeout During Model Download
**Severity:** High  
**Impact:** First `code.edit` call with a new model triggers download that can take 2-17 minutes. The HTTP connection (NWListener/curl) may drop before the response is sent.

**Observed behavior:**
- curl with 600s timeout exited with code 28 (operation timed out) during Qwen3-Coder-30B download
- However, the server-side Task continued downloading the model even after the connection dropped
- The model loaded successfully; subsequent calls worked

**Recommendation:** Add a `code.edit.load` tool that explicitly triggers model download/loading and returns progress updates. Or return an immediate "loading" response and let clients poll status.

### 2. Concurrent Request Crash
**Severity:** High  
**Impact:** Sending a second MCP request while a model is downloading caused the server to freeze (NWConnection state corruption).

**Root cause:** The MCP server's NWListener handler creates a new Task for each request, but model loading is a long-running operation on the MLXCodeEditor actor. A second request entering the actor during an `await` point (actor reentrancy) can cause state confusion.

**Recommendation:** Add request serialization for code.edit, or a "loading" state that rejects new requests until the model is ready.

### 3. `getOrCreateEditor` Ignores Tier Parameter
**Severity:** Medium  
**Impact:** In `CodeEditToolsHandler.handleEdit()`, if an editor was previously created (e.g., from a failed request), subsequent calls with a different tier reuse the existing editor.

**Location:** `CodeEditToolsHandler.swift` — `getOrCreateEditor(tier:)` checks `if let editor { return editor }` and ignores the `tier` parameter.

### 4. Diff Mode Not Producing Diffs
**Severity:** Medium  
**Impact:** When `mode: "diff"` is requested, the 30B model outputs the full file instead of unified diffs. The 7B model attempts diffs but gets stuck in an infinite loop.

**Root cause:** The system prompt for diff mode may not be strong enough, or the models don't reliably follow unified diff format.

**Recommendation:** Consider removing diff mode, or post-processing fullFile output into diffs programmatically.

---

## Model Selection Recommendations

| Use Case | Recommended Tier | Rationale |
|----------|-----------------|-----------|
| Quick renames, simple formatting | Small (7B) | Fast (3-10s), good enough for mechanical changes |
| Method extraction, simple refactors | Small (7B) or Medium (14B) | 7B handles well, 14B for safety margin |
| Complex modernization (pattern migration) | Large (30B) | 7B misses details, 30B gets them right |
| Error handling / logic changes | Large (30B) | **Critical** — 7B loses existing logic |
| Multi-file coordinated changes | Large (30B) | Need higher reasoning capability |

### Cost/Speed Tradeoffs

- **7B:** ~69 tok/s, 4GB RAM. Use for high-volume, simple edits.
- **30B MoE:** ~23 tok/s, 17GB RAM. Only 3B parameters active per token (efficient MoE). Use when correctness matters.
- **14B (untested):** Expected ~35-45 tok/s, 8GB RAM. Good middle ground (testing pending).

---

## Files Modified During Testing

| File | Change | Committed |
|------|--------|-----------|
| `Shared/Services/MLXCodeEditor.swift` | Updated large tier from Qwen3-Coder-Next to Qwen3-Coder-30B-A3B; updated medium tier to 14B; added qwen3_next incompatibility note | No |
| `tmp/code-edit-test/OldStyleViewModel.swift` | Synthetic test file (old patterns) | No |
| `tmp/code-edit-test/parse-result.py` | Result parsing helper | No |

---

## Next Steps

1. **Test medium tier (14B)** — Verify it downloads and generates correctly
2. **Fix diff mode** — Either improve prompting or remove the mode
3. **Add `code.edit.load` tool** — Separate model loading from editing to handle long downloads
4. **Add request serialization** — Prevent concurrent code.edit requests during model loading
5. **Fix `getOrCreateEditor`** — Allow tier switching or at minimum log a warning when tier is ignored
6. **Monitor MLX Swift updates** — `qwen3_next` support may be added in future releases
7. **Benchmark 14B** — Fill the gap between 7B speed and 30B quality

---

## Raw Test Data

Results stored at `/tmp/code-edit-result-{1..8}.json`  
Parser: `tmp/code-edit-test/parse-result.py`

| File | Test | Content |
|------|------|---------|
| result-1.json | 7B Modernize | ✅ Has data |
| result-2.json | (Qwen3-Next attempt) | ❌ Empty (download timeout) |
| result-3.json | 7B Error Handling | ✅ Has data |
| result-4.json | 7B Rename/Diff | ✅ Has data (infinite loop output) |
| result-5.json | 30B Modernize | ✅ Has data |
| result-6.json | 30B Extract Method | ✅ Has data |
| result-7.json | 30B Error Handling | ✅ Has data |
| result-8.json | 30B Rename/Diff | ✅ Has data |
