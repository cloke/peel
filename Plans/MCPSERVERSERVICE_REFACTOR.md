# MCPServerService Refactoring Plan

**Created:** 2026-02-11
**Status:** Phase 1 Complete
**Issue:** MCPServerService.swift is 7,581 lines — a god-object doing HTTP serving, tool routing, RAG, chains, worktrees, dependency graphs, learning loop, prompt rules, and more.

**Goal:** Reduce to ~800-900 lines (coordinator + HTTP server + request routing only).

**Progress:**
- Phase 1 complete (2026-02-11): 7,582 → 6,449 lines (1,133 lines extracted into 6 extension files)

---

## Current Breakdown

| Lines | Section | Location |
|-------|---------|----------|
| 171 | Class definition, properties, init | L1–190 |
| 138 | RAG Analysis State types | L191–328 |
| 172 | Prompt Rules types + helpers | L329–500 |
| 360 | Tool handler wiring / setup | L501–860 |
| 384 | Dependency Graph building | L861–1244 |
| 1,248 | Learning Loop CRUD | L1245–2492 |
| 940 | Chain handler methods (internal) | L2493–3432 |
| 735 | Prompt Rules handlers | L3433–4167 |
| 28 | Ember Skills tool defs | L4168–4195 |
| 269 | Lesson tool defs | L4196–4464 |
| 821 | Code Editing tool defs | L4465–5285 |
| 321 | Swarm tool defs | L5286–5606 |
| 252 | Firestore Swarm tool defs | L5607–5858 |
| 80 | Firebase Emulator tool defs | L5859–5938 |
| 76 | Worktree tool defs | L5939–6014 |
| 256 | AI Terminal tool defs | L6015–6270 |
| 180 | RepoToolsHandler (inline class) | L6271–6450 |
| 32 | MCPToolHandlerDelegate conformance | L6451–6482 |
| 14 | ParallelToolsHandlerDelegate | L6483–6496 |
| 8 | RepoToolsHandlerDelegate | L6497–6504 |
| 6 | CodeEditToolsHandlerDelegate | L6505–6510 |
| 326 | RAGToolsHandlerDelegate (RAGStore access) | L6511–6844 |
| 32 | Configuration delegate accessors | L6845–6876 |
| 45 | AI Analysis delegate | L6877–6921 |
| 29 | RAGArtifactSyncDelegate | L6922–6950 |
| 325 | ChainToolsHandlerDelegate | L6951–7279 |
| 279 | WorktreeToolsHandlerDelegate | L7280–7558 |
| 23 | GitHubToolsHandlerDelegate | L7559–7581 |

---

## Phase 1 — Move delegate extensions to separate files (~1,100 lines)

Low-risk, purely mechanical: cut `extension MCPServerService: XyzDelegate {}` blocks into their own files. No behavior changes.

- [x] **1a.** `MCPServerService+WorktreeToolsDelegate.swift` — L7280–7558 (279 lines)
- [x] **1b.** `MCPServerService+ChainToolsDelegate.swift` — L6951–7279 (325 lines)
- [x] **1c.** `MCPServerService+RAGToolsDelegate.swift` — L6511–6921 (RAGToolsHandlerDelegate + RAGStore access + config + AI analysis = ~410 lines)
- [x] **1d.** `MCPServerService+RAGArtifactSync.swift` — L6922–6950 (29 lines)
- [x] **1e.** `MCPServerService+GitHubToolsDelegate.swift` — L7559–7581 (23 lines)
- [x] **1f.** `MCPServerService+SmallDelegates.swift` — MCPToolHandler, Parallel, Repo, CodeEdit delegates (L6451–6510, ~60 lines)
- [x] **1g.** Build verification

**Estimated reduction:** ~1,100 lines → file drops to ~6,400 lines

---

## Phase 2 — Move RepoToolsHandler to its own file (~180 lines)

The `RepoToolsHandler` class + protocol at L6271–6450 is a standalone type that got left behind when other handlers moved to `ToolHandlers/`.

- [ ] **2a.** Move RepoToolsHandler class + RepoToolsHandlerDelegate protocol to `ToolHandlers/RepoToolsHandler.swift` (the existing file is just a stub)
- [ ] **2b.** Build verification

**Estimated reduction:** ~180 lines → file drops to ~6,220 lines

---

## Phase 3 — Extract inline tool definitions (~2,100 lines)

Tool definition arrays (Swarm, Firestore, Firebase, Worktree, Terminal, Code Editing, Ember, Lessons) are defined inline. Move them into their respective handler files or a new `ToolDefinitions/` directory.

- [ ] **3a.** Code Editing tool defs → `ToolHandlers/CodeEditToolsHandler.swift` (821 lines)
- [ ] **3b.** Swarm + Firestore Swarm tool defs → `ToolHandlers/SwarmToolsHandler.swift` (573 lines)
- [ ] **3c.** Firebase Emulator tool defs → new or existing handler (80 lines)
- [ ] **3d.** Worktree tool defs → `ToolHandlers/WorktreeToolsHandler.swift` (76 lines)
- [ ] **3e.** AI Terminal tool defs → `ToolHandlers/TerminalToolsHandler.swift` (256 lines)
- [ ] **3f.** Ember Skills + Lesson tool defs → `ToolHandlers/` (297 lines)
- [ ] **3g.** Build verification

**Estimated reduction:** ~2,100 lines → file drops to ~4,120 lines

---

## Phase 4 — Extract business logic into services (~2,400 lines)

These sections are self-contained business logic that should be their own types.

- [ ] **4a.** `MCPLearningLoopService.swift` — Lesson CRUD (1,248 lines)
- [ ] **4b.** `MCPDependencyGraphBuilder.swift` — Graph building (384 lines)
- [ ] **4c.** `MCPPromptRulesHandler.swift` — Prompt rules request handling (735 lines)
- [ ] **4d.** Build verification

**Estimated reduction:** ~2,400 lines → file drops to ~1,720 lines

---

## Phase 5 — Extract chain handler internals (~940 lines)

The `handleChainRun`, `handleChainRunBatch`, etc. methods at L2493–3432 should move to `ChainToolsHandler` or a new `MCPChainRequestHandler`. This is the riskiest extraction due to deep coupling with `agentManager`, `workspaceManager`, and queue state.

- [ ] **5a.** Audit state dependencies of chain handler methods
- [ ] **5b.** Extract to `MCPChainRequestHandler.swift`
- [ ] **5c.** Build verification

**Estimated reduction:** ~940 lines → file drops to ~780 lines ✅

---

## Final Target

~780–900 lines containing:
- Class properties + init
- HTTP server lifecycle (`start`, `stop`, connection handling)
- Request routing (`handleRPC` → dispatch)
- Tool registration / enable-disable
- Small helper methods

---

## Rules

1. One phase at a time. Build-verify after each.
2. No behavior changes — purely structural moves.
3. Each new file gets the same copyright header and imports only what it needs.
4. Extensions use `internal` access by default (matching current visibility).
