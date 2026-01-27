# AST Chunking Stability Analysis & Plan

**Date:** January 26, 2026  
**Status:** ✅ STABILIZED  
**Priority:** High - Blocking RAG stability

---

## Resolution Summary (January 26, 2026)

### What Was Done

1. **Fixed RubyChunker pipe deadlock** - Applied async pipe reading pattern from GlimmerChunker to prevent buffer deadlock on large AST outputs (>64KB)

2. **Added ChunkingHealthTracker** - Records failures per file, enables auto-fallback on re-index, persists to `~/Library/Application Support/Peel/chunking_failures.json`

3. **Added per-file error boundaries** - `HybridChunker.chunkSafe()` method with failure tracking and automatic line-based fallback

4. **Disabled Swift AST chunking** - SwiftSyntax Parser has unbounded recursion causing stack overflow on deeply nested files (closures in closures). File SIZE doesn't predict nesting DEPTH, so no safe threshold exists. Line-based chunking works well for RAG purposes.

5. **Enhanced LocalRAGIndexReport** - Now includes `astFilesChunked`, `lineFilesChunked`, `chunkingFailures` for diagnostics

### Current State

| Language | Chunker | Status |
|----------|---------|--------|
| Swift | SwiftSyntax | ❌ Disabled (stack overflow) |
| Ruby | tree-sitter | ✅ Working (pipe fix applied) |
| Glimmer (GTS/GJS) | tree-sitter | ✅ Working |
| TypeScript/JavaScript | Line-based | ✅ Working |
| Others | Line-based | ✅ Working |

### Test Results

```
KitchenSink: 206 files, 469 chunks, 5.9s - ✅ No crash
tio-front-end: 1806 files, 14822 chunks - ✅ No crash  
tio-api: 2390 files, 3500 chunks, 10.7m - ✅ No crash (Ruby AST working)
```

---

## Original Problem Statement

AST-based chunking worked incrementally until TypeScript support was added. The trigger was scanning `application.ts` with the tree-sitter TypeScript chunker. Since then, the system has been unstable even after "disabling" TypeScript support.

### Timeline (What Actually Happened)

| Change | Commit | Status |
|--------|--------|--------|
| Line-based chunking only | pre-`a5f44de` | ✅ Stable |
| + Swift AST (SwiftSyntax) | `a5f44de` | ✅ Worked |
| + Ruby AST (tree-sitter CLI) | `6e6c366` | ⚠️ Had pipe deadlock bug |
| + Glimmer AST (tree-sitter CLI) | `54d4808` | ✅ Worked (had async pipe fix) |
| + TypeScript AST (tree-sitter CLI) | `54d4808` | ❌ **TRIGGER** |
| "Disable" TS in HybridChunker | `24b3955` | ❌ Still crashes (Swift stack overflow) |
| "Disable" Swift AST too | `6a85d11` | ❌ Still crashes (Ruby pipe deadlock) |
| Re-enable Swift with size guard | current | ❌ Still crashes (size ≠ nesting) |
| **Fix Ruby pipe + disable Swift** | `HEAD` | ✅ **STABLE** |

### Root Causes Found

1. **Ruby pipe deadlock**: RubyChunker read output AFTER process exit, causing deadlock when AST output >64KB
2. **Swift stack overflow**: SwiftSyntax Parser uses unbounded recursion. Deeply nested closures cause stack overflow. File SIZE doesn't predict nesting DEPTH.

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

## Future Work: Re-enabling Swift AST

To safely re-enable Swift AST chunking, we need **subprocess isolation**:

### Option 1: Task.detached with Stack Guard
```swift
// Run SwiftSyntax in a detached task with stack monitoring
let result = try await withTimeout(seconds: 5) {
  try await Task.detached(priority: .userInitiated) {
    swiftChunker.chunk(source: text)
  }.value
}
```
**Problem**: Swift tasks share the process stack limit.

### Option 2: Subprocess with CLI
```swift
// Run ast-chunker-cli (the CLI target in ASTChunker package) as subprocess
let process = Process()
process.executableURL = URL(fileURLWithPath: astChunkerCLIPath)
process.arguments = ["--swift", tempFile.path]
// ... async pipe reading pattern ...
```
**Pros**: Complete isolation. If CLI crashes, main app continues.
**Cons**: Overhead of spawning process per file.

### Option 3: tree-sitter Swift bindings
Replace SwiftSyntax with tree-sitter-swift (like we use for Ruby).
**Pros**: Same architecture as other chunkers, known to work.
**Cons**: May lose some Swift-specific AST detail.

### Recommended Path
1. Build `ast-chunker-cli` target as part of app bundle
2. Use subprocess isolation for Swift files only
3. Fall back to line-based if subprocess times out or crashes
4. Track failures with ChunkingHealthTracker

---

## Code Changes Made (January 26, 2026)

### Files Modified:
- `Local Packages/ASTChunker/Sources/ASTChunker/RubyChunker.swift` - Applied async pipe reading fix
- `Shared/Services/LocalRAGStore.swift` - Added ChunkingHealthTracker, ChunkingResult, chunkSafe(), disabled Swift AST, enhanced index report

### Key Code Patterns Added:

#### Async Pipe Reading (prevents deadlock)
```swift
let group = DispatchGroup()
group.enter()
DispatchQueue.global(qos: .userInitiated).async {
  outputData = outputHandle.readDataToEndOfFile()
  group.leave()
}
// ... process.run() ...
group.wait(timeout: .now() + parseTimeout)
```

#### ChunkingHealthTracker (auto-fallback)
```swift
if healthTracker.shouldSkipAST(for: filePath, hash: fileHash) {
  return lineChunker.chunk(text: text)  // Auto fallback
}
```

---

## Questions Resolved

- ✅ **Root cause identified**: Two separate bugs - Ruby pipe deadlock + Swift unbounded recursion
- ✅ **Is AST chunking significantly better?**: Yes, when stable (Ruby/Glimmer working)
- ✅ **Should we invest in tree-sitter-swift?**: Consider as alternative to SwiftSyntax
- ✅ **Current status**: STABLE with Ruby/Glimmer AST, Swift line-based
