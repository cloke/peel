# Code Health Cleanup Plan

**Created:** February 13, 2026
**Status:** In Progress

## Summary

RAG deep-dive identified ~9,019 wasted tokens across 27 duplicate groups, 10 complexity hotspots, and several consolidation opportunities. This plan tracks the cleanup work.

---

## Quick Wins (< 30 min each)

### 1. Delete private `StatCard` in MCPDashboardView — use PeelUI version
- **Files:** `Shared/Applications/Agents/MCPDashboardView.swift`
- **Issue:** Private `StatCard(title:value:)` duplicates `PeelUI.StatCard(value:label:icon:)`.
- **Action:** Delete the private struct. Update 3 call sites to use PeelUI's API (add an icon, swap `title:` → `label:`).
- [ ] Done

### 2. Extract `StatPill` to PeelUI
- **Files:** `CIFailureFeedbackView.swift`, `LocalRAGDashboardView.swift`
- **Issue:** Two different `StatPill` structs with different APIs:
  - CIFailureFeedback: `label:value:color:` (text-only, circle indicator)
  - LocalRAGDashboard: `value:label:icon:color:` (icon + numeric)
- **Action:** Create a unified `StatPill` in `PeelUI/CardComponents.swift` that supports both patterns (optional icon, flexible value type). Delete the two private copies.
- [ ] Done

### 3. Consolidate `chartWeekStarts()` and `parseDate()` in Github package
- **Files:** `ActionsListView.swift`, `RepositoryInsightsView.swift`, `PersonalView.swift`
- **Issue:** Identical `chartWeekStarts()` in 2 files, `parseDate()` in 3 files.
- **Action:** Add shared helpers to `Date+Formatting.swift` in the Github package.
- [ ] Done

### 4. Re-index RAG to clear stale entries
- **Issue:** RAG index still contains deleted `LocalRAGStore.swift` (was 6,878 lines).
- **Action:** Run `rag.repos.delete` then `rag.index` with `forceReindex: true`.
- [ ] Done

---

## Medium Effort (1–2 hr)

### 5. Extract shared Translation types into a package
- **Files:** `TranslationValidatorService.swift` (app), `TranslationValidator.swift` (PeelSkills CLI)
- **Issue:** 9 identical model types copy-pasted between app and CLI tool.
- **Action:** Create a `TranslationTypes` target or shared source set that both depend on.
- [ ] Done

---

## Larger Refactors (Future — tracked, not in this session)

### 6. Decompose `MCPServerService` (7,559 lines across 11 files)
- Already split into extensions, but the class itself remains a god-class.
- Future: Extract subsystems (tool definitions, server lifecycle, delegate routing) into composed types.
- [ ] Done

### 7. Break down large views (> 1,000 lines)
- `VMIsolationView.swift` (1,121 lines)
- `RAGRepositoryCardView.swift` (1,429 lines)
- `RAGToolsHandler.swift` (2,328 lines)
- `LocalRAGDashboardView.swift` (1,043 lines)
- [ ] Done

### 8. Consolidate `AuditReport` / `AuditResult` name collisions
- Defined in RoadmapAudit, PatternAudit, PeelCLI, PIIScrubber — likely different shapes.
- Audit whether they can share a protocol or at least be disambiguated by naming.
- [ ] Done
