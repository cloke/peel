---
title: Health Check Action Plan
status: active
created: 2026-01-20
updated: 2026-01-20
audience: [developer, ai-agent]
related_docs:
  - Plans/ROADMAP.md
  - Sessions/HEALTH_CHECK_2026-01-19.md
---

# Health Check Action Plan – January 20, 2026
## Session Paused - Next Steps

### Completed This Session
1. ✅ Extracted `TranslationValidatorService.swift` (~520 lines) from AgentManager
2. ✅ Extracted `PIIScrubberService.swift` (~220 lines) from AgentManager  
3. ✅ AgentManager reduced from 4,710 → 3,996 lines
4. ✅ Fixed NLEmbedding crash - added text sanitization in `LocalRAGEmbeddings.swift`

### Immediate Next Steps (Resume Here)
1. **Commit the crash fix** - `LocalRAGEmbeddings.swift` has uncommitted changes
2. **Re-test RAG indexing on tio-workspace** - Previous attempt crashed on malformed text
3. **Benchmark search performance** - Test query speed across 3K+ files

### Commands to Resume
```bash
cd /Users/cloken/code/KitchenSink

# 1. Commit the fix
git add -A && git commit -m "Fix NLEmbedding crash: sanitize text before embedding

- Add text length limit (10K chars)
- Filter control characters and null bytes
- Collapse excessive whitespace
- Return zero vector for empty text after sanitization"

# 2. Launch app with MCP
./Tools/build-and-launch.sh --wait-for-server

# 3. Init RAG and index tio-workspace
curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.init","arguments":{}}}' \
  http://127.0.0.1:8765/rpc

curl -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.index","arguments":{"repoPath":"/Users/cloken/code/tio-workspace"}}}' \
  http://127.0.0.1:8765/rpc
```

---
## Executive Summary

### Overall Health: ✅ Excellent

The codebase is in excellent shape following the January 19 health check and subsequent work:

| Area | Status | Notes |
|------|--------|-------|
| **Build** | ✅ Passing | macOS scheme builds successfully |
| **Swift 6** | ✅ Complete | @Observable, @MainActor, async/await throughout |
| **SwiftData** | ✅ Working | CloudKit-compatible models |
| **MCP Server** | ✅ Functional | 45+ tools, UI automation, permissions |
| **Local RAG** | 🔄 In Progress | Core infrastructure done, embeddings working |
| **PII Scrubber** | 🔄 In Progress | CLI + MCP + basic UI complete |
| **Issue Tracking** | ✅ Synced | gh-issue-sync reports no discrepancies |
| **Documentation** | ✅ Current | Roadmap and plans up to date |

---

## Recent Work Summary (Since Jan 19)

### Completed
- ✅ #66 MCP UI automation tools + permissions (closed)
- ✅ #68 MCP tool grouping toggles (closed)
- ✅ #60 MCP latency chart (closed)
- ✅ PII scrubber config validation and report export
- ✅ PII scrubber NER detection (names/orgs/places)
- ✅ Local RAG: System embeddings via NLEmbedding
- ✅ Local RAG: Dashboard UI with status/stats/search
- ✅ Local RAG: MCP tools (rag.init, rag.index, rag.search, rag.status)

### In Progress
- 🔄 #76 PII scrubber enhancements (audit report UI + export remaining)
- 🔄 #72-75 Local RAG sub-issues (core work done, issues still open)
- 🔄 #42 Local RAG parent issue (substantial progress)

---

## Open Issues Analysis

**Total Open Issues:** 30

### By Category

| Category | Count | Issues |
|----------|-------|--------|
| Local RAG | 5 | #42, #72-75 |
| PII Scrubber | 2 | #31 (design doc), #76 (enhancements) |
| Agent Features | 7 | #29, #30, #39, #40, #44, #69, #71 |
| Charts/Visualization | 6 | #59, #61, #62, #63, #64, #65 |
| VM Isolation | 2 | #54, #52 |
| Future/Big Ideas | 6 | #35, #36, #37, #41, #43, #67 |
| Documentation | 2 | #31, #38 |

### Issues Ready to Close

| Issue | Title | Status | Recommendation |
|-------|-------|--------|----------------|
| #72 | Local RAG: SQLite store | Open | **Can close** - `LocalRAGStore` fully implemented |
| #73 | Local RAG: Repo scan + chunking | Open | **Can close** - `LocalRAGFileScanner` + `LocalRAGChunker` done |
| #74 | Local RAG: Embedding provider | Open | **Partial** - System embeddings work, Core ML blocked on model |
| #75 | Local RAG: Query API + MCP hook | Open | **Can close** - `rag.search` (text + vector modes) implemented |

### Issues Needing Updates

| Issue | Current State | Update Needed |
|-------|---------------|---------------|
| #42 | Parent issue | Update with sub-issue completion status |
| #76 | PII enhancements | Checklist update for completed NER/config |

---

## Code Quality Assessment

### AgentManager.swift Analysis

**File Stats:**
- 4,710 lines
- 158 functions
- 46 type definitions

**Observation:** This file has grown large with multiple services embedded:
- `AgentManager` (core orchestration)
- `AgentChainRunner` (chain execution)
- `MCPServerService` (MCP JSON-RPC + 45+ tools)
- `TranslationValidatorService`
- `PIIScrubberService`

**Recommendation:** Consider extracting services to separate files for maintainability:
1. `TranslationValidatorService` → `Shared/Services/TranslationValidatorService.swift`
2. `PIIScrubberService` → `Shared/Services/PIIScrubberService.swift`
3. Keep MCP tools within MCPServerService but split into extensions by category

### TODOs in Codebase

Only 6 TODOs found in main source:
- 4 in `VMIsolationService.swift` (expected - VM features are Phase 3)
- 2 in `ValidationRule.swift` (detection helpers, not blockers)

### Local RAG Implementation Gap

The plan calls for `sqlite-vec` extension for vector similarity, but current implementation uses:
- **In-memory cosine similarity** scanning all embeddings
- Works for small repos but won't scale to large codebases

**Options:**
1. Keep current approach for MVP (sufficient for single-repo use)
2. Add `sqlite-vec` extension loading in a future iteration
3. Use FTS5 for hybrid search (already in schema, not yet used)

---

## Recommended Action Items

### Immediate (This Session)

1. **Close completed Local RAG issues**
   - Close #72, #73, #75 with implementation notes
   - Update #74 with partial status (system embeddings working)
   - Update #42 with progress summary

2. **Update #76 checklist**
   - Mark NER detection complete
   - Mark config rules complete
   - Note remaining: audit report UI/export

### Short Term (This Week)

3. **Extract services from AgentManager.swift**
   - Create `TranslationValidatorService.swift`
   - Create `PIIScrubberService.swift`
   - Reduces AgentManager.swift by ~700 lines

4. **Complete PII scrubber audit UI** (#76)
   - Export report as JSON/text file
   - Show validation errors in UI

5. **Add Local RAG to roadmap**
   - Update ROADMAP.md Phase 2 section
   - Add code_locations for new RAG files

### Medium Term (Next Sprint)

6. **Evaluate sqlite-vec vs brute-force search**
   - Benchmark current approach on larger repos
   - Decide if extension is needed for v1

7. **Review chart issues** (#59-65)
   - Consolidate similar chart requests
   - Prioritize by data availability

8. **iOS parity audit** (#38)
   - Document what works on iOS vs macOS-only
   - The AgentManager iOS stub indicates gaps

---

## Roadmap Alignment Check

| Roadmap Phase | Status | Notes |
|---------------|--------|-------|
| **Phase 1C (Polish)** | ✅ 90% Complete | Most items done, #76 in progress |
| **Phase 2 (Local AI)** | 🔄 Started | PII + Local RAG underway |
| **Phase 3 (Isolation)** | 📋 Planned | VM work blocked on Alpine rootfs |

### Roadmap Update Needed

The roadmap should be updated to reflect:
1. Local RAG progress (#42, #72-75)
2. PII scrubber enhancements (#76) partial completion
3. Move #72-75 to Phase 2 "In Progress" section

---

## Tool Validation

| Tool | Status | Last Run |
|------|--------|----------|
| `gh-issue-sync` | ✅ No discrepancies | Today |
| `roadmap-audit` | ✅ All checks pass | Today |
| `pii-scrubber` | ✅ Builds and runs | Today |
| `build-and-launch.sh` | ✅ Works | Today |

---

## Summary of Actions

### Immediate Actions (Priority Order)

1. [ ] Close #72 (SQLite store) - implementation complete
2. [ ] Close #73 (repo scan + chunking) - implementation complete
3. [ ] Close #75 (query API + MCP) - implementation complete
4. [ ] Update #74 (embeddings) - partial, note Core ML blocked
5. [ ] Update #42 (parent) - summarize progress
6. [ ] Update #76 checklist - NER and config done

### Follow-up Actions

7. [ ] Update ROADMAP.md with Local RAG code locations
8. [ ] Extract TranslationValidatorService to separate file
9. [ ] Extract PIIScrubberService to separate file
10. [ ] Benchmark Local RAG on larger repository

---

*Generated: January 20, 2026*
