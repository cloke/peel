# AST Chunking Stability Analysis & Plan

**Date:** January 26, 2026  
**Status:** REVERT REQUIRED  
**Priority:** High - Blocking RAG stability

---

## Problem Statement

AST-based chunking worked incrementally until TypeScript support was added. The trigger was scanning `application.ts` with the tree-sitter TypeScript chunker. Since then, the system has been unstable even after "disabling" TypeScript support.

### Timeline (What Actually Happened)

| Change | Commit | Status |
|--------|--------|--------|
| Line-based chunking only | pre-`a5f44de` | ✅ Stable |
| + Swift AST (SwiftSyntax) | `a5f44de` | ✅ Worked |
| + Ruby AST (tree-sitter CLI) | `6e6c366` | ✅ Worked |
| + Glimmer AST (tree-sitter CLI) | `54d4808` | ✅ Worked |
| + TypeScript AST (tree-sitter CLI) | `54d4808` | ❌ **TRIGGER** - scanning application.ts caused memory explosion |
| "Disable" TS in HybridChunker | `24b3955` | ❌ Still crashes |
| "Disable" Swift AST too | `6a85d11` | ❌ Still crashes |
| Re-enable Swift with size guard | current | ❌ Still crashes |

**Key insight:** The problem isn't just TypeScript. Something in the codebase changed during the TypeScript work that broke error isolation. Even with TypeScript "disabled", other chunkers now crash the app.

---

## Root Cause Hypothesis

The TypeScript commit (`54d4808`) did more than add TypeScript support. It likely:

1. **Changed the ASTChunkerService architecture** - May have introduced shared state or changed how exceptions propagate
2. **Modified error handling** - Errors that were previously caught may now crash
3. **Changed memory management** - Chunkers may now retain data across files
4. **Threading changes** - Parsing may have moved to a thread with smaller stack

**The "disabling" approach doesn't work** because the structural changes remain even when the TypeScript code path is commented out.

---

## Action Plan

### Phase 1: Clean Revert (Next Session)

**Goal:** Get back to last known stable state

1. **Identify last stable commit** - Find the commit BEFORE TypeScript work began
   ```bash
   git log --oneline | grep -B5 "54d4808"
   ```

2. **Revert AST-related changes** - Either:
   - Hard revert to pre-TypeScript commit for AST code only
   - Or manually restore the pre-TypeScript versions of:
     - `Shared/Services/LocalRAGStore.swift` (HybridChunker)
     - `Local Packages/ASTChunker/` (entire package)

3. **Verify stability** - Index both KitchenSink and tio-front-end without crashes

### Phase 2: Proper Architecture (Before Re-adding AST)

**Goal:** Design chunking system that isolates failures

1. **Subprocess isolation** - Each AST parser runs in its own process
   - If SwiftSyntax crashes → subprocess dies, main app continues
   - Fall back to line-based for that file

2. **Per-file error boundaries** - Wrap each file's chunking in try/catch
   ```swift
   for file in files {
     do {
       chunks = try astChunker.chunk(file)
     } catch {
       log("[AST] Failed for \(file), using line chunking")
       chunks = lineChunker.chunk(file)
     }
   }
   ```

3. **Memory guards** - Monitor memory during indexing, pause if growing too fast

4. **File complexity scoring** - Skip AST for files that look problematic:
   - > 100KB
   - > 10 levels of nesting
   - Known problematic patterns (huge literals, generated code)

### Phase 3: Incremental Re-addition (One at a Time)

**Goal:** Add AST support back with proper testing at each step

| Step | Language | Parser | Test On |
|------|----------|--------|---------|
| 1 | Swift | SwiftSyntax (subprocess) | KitchenSink |
| 2 | Ruby | tree-sitter | tio-api |
| 3 | Glimmer (.gts/.gjs) | tree-sitter | tio-front-end |
| 4 | TypeScript | tree-sitter | tio-front-end (including application.ts!) |

**Each step must pass:**
- [ ] Index completes without crash
- [ ] Memory stays < 4GB during indexing
- [ ] App remains responsive
- [ ] No SIGBUS/SIGSEGV in crash logs

---

## Files to Examine in Next Session

1. **Commit diff for TypeScript work:**
   ```bash
   git show 54d4808 --stat
   git diff 6e6c366..54d4808 -- Shared/Services/LocalRAGStore.swift
   git diff 6e6c366..54d4808 -- Local\ Packages/ASTChunker/
   ```

2. **ASTChunkerService.swift** - Was this modified? It's separate from HybridChunker

3. **LocalRAGStore.swift indexRepository()** - How does it call chunkers? Error handling?

---

## Questions Resolved

- ~~Is AST chunking significantly better?~~ **Yes, when stable**
- ~~Should we invest in tree-sitter-swift?~~ **After stability is restored**
- **Current priority:** Revert to stable, then rebuild properly

---

## Commands for Next Session

```bash
# 1. Find last stable commit (before TS work)
git log --oneline -20 | grep -B2 "54d4808"

# 2. Check what 54d4808 changed
git show 54d4808 --stat

# 3. Compare LocalRAGStore before/after TS work
git diff 6e6c366..54d4808 -- Shared/Services/LocalRAGStore.swift

# 4. Revert to pre-TS state for testing
git checkout 6e6c366 -- Shared/Services/LocalRAGStore.swift
git checkout 6e6c366 -- Local\ Packages/ASTChunker/

# 5. Build and test
./Tools/build-and-launch.sh --wait-for-server
```

---

## Session Handoff Notes

- This session has been running a long time with multiple quick-fix attempts
- User correctly identified that "disable and retry" approach isn't working
- Need fresh investigation starting from the TypeScript commit
- **Do not make code changes without user approval**
- **Do not fall back to "simpler" solutions without discussion**
