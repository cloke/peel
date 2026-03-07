# RAG Orphan Baseline

**Last Updated:** 2026-01  
**Tool:** `rag.orphans`  
**Purpose:** Document files that are legitimately "entry-point only" so the orphan report stays actionable. Run `rag.orphans` after each refactor cycle and compare against this baseline.

---

## How to Use This Baseline

```bash
# Run rag.orphans via PeelCLI
echo '{"repoPath":"/path/to/repo","excludeTests":true,"excludeEntryPoints":true,"limit":50}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.orphans --arguments-json tmp/peel-mcp-args.json
```

Any file **not** in this list that appears in the orphan report is a candidate for investigation. Files in this baseline should be reviewed periodically — if they slip further from their known callers, they may become true orphans.

---

## Known Entry Points (Not Orphans)

### App Entry Points

| File | Category | Reason not flagged as orphan |
|------|----------|-------------------------------|
| `Shared/PeelApp.swift` | `@main` entry | SwiftUI `@main` entry point — never imported, always discovered by the SwiftUI framework |
| `macOS/ContentView.swift` | Platform entry | Root view injected by `PeelApp.swift` via `WindowGroup` |
| `iOS/ContentView.swift` | Platform entry | Root view injected by `PeelApp_iOS.swift` via `WindowGroup` |
| `iOS/PeelApp_iOS.swift` | `@main` entry | iOS-specific `@main` entry point |

### SwiftData Models

| File | Category | Reason not flagged as orphan |
|------|----------|-------------------------------|
| `Shared/SwiftDataModels.swift` | SwiftData model definitions | `@Model` classes registered via `ModelContainer` in `PeelApp.swift` — no explicit per-model imports |

### Firebase / Distributed Services

| File | Category | Reason not flagged as orphan |
|------|----------|-------------------------------|
| `Shared/Distributed/FirebaseService.swift` | Firebase SDK wrapper | Shared singleton used by `SwarmCoordinator`, `SwarmStatusView`, `PeelApp`, `SwarmToolsHandler+Firestore`, `SwarmToolsHandler+Firebase`, `SwarmToolsHandler+PeerDiscovery` (6 callers confirmed). Orphan tools may miss it if RAG hasn't indexed all callers yet. |
| `Shared/Distributed/SwarmCoordinator.swift` | Distributed coordinator | Accessed via `.shared` singleton pattern — no module-boundary import needed |
| `Shared/Distributed/PeelWorker.swift` | Worker mode | Instantiated via `SwarmCoordinator` worker-mode path |
| `Shared/Distributed/BonjourDiscoveryService.swift` | Network discovery | Used by `SwarmCoordinator` via composition |

### MCPServerService Extensions

All `MCPServerService+*.swift` files are `extension` files that extend `MCPServerService`. They have **no explicit import** of the type they extend — this is a Swift language property (same-module extensions require no import). RAG orphan detection may flag them because they don't appear in any `import` statement.

| File | Category | Reason |
|------|----------|--------|
| `Shared/AgentOrchestration/MCPServerService+ToolDefinitions.swift` | Extension | `extension MCPServerService` in same module — imports are implicit |
| `Shared/AgentOrchestration/MCPServerService+ServerCore.swift` | Extension | Same |
| `Shared/AgentOrchestration/MCPServerService+RAGToolsDelegate.swift` | Extension | Same |
| `Shared/AgentOrchestration/MCPServerService+ChainHandlers.swift` | Extension | Same |
| `Shared/AgentOrchestration/MCPServerService+SmallDelegates.swift` | Extension | Same |
| `Shared/AgentOrchestration/MCPServerService+WorktreeToolsDelegate.swift` | Extension | Same |
| `Shared/AgentOrchestration/MCPServerService+GitHubToolsDelegate.swift` | Extension | Same |
| `Shared/AgentOrchestration/MCPServerService+RAGArtifactSync.swift` | Extension | Same |

### Handler Extension Files (#300, #301)

All `*Handler+*.swift` files are extension files created as part of the ToolDefs decentralization (#300) and god-handler split (#301). Same reasoning as MCPServerService extensions — no import needed for same-module extensions.

| File | Category | Reason |
|------|----------|--------|
| `Shared/AgentOrchestration/ToolHandlers/RAGToolsHandler+Analysis.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/RAGToolsHandler+Indexing.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/RAGToolsHandler+Lessons.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/RAGToolsHandler+Search.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/RAGToolsHandler+Skills.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/RAGToolsHandler+ToolDefinitions.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/RAGToolsHandler+Types.swift` | Supporting types | Free-standing types used by the handler protocol |
| `Shared/AgentOrchestration/ToolHandlers/RAGToolsHandlerDelegate.swift` | Protocol | Conformed to by `MCPServerService`; no per-file import needed |
| `Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler+Firebase.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler+Firestore.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler+PeerDiscovery.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler+TaskDispatch.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler+ToolDefinitions.swift` | Extension | Same-module extension |
| `Shared/AgentOrchestration/ToolHandlers/ChainToolsHandler.swift` | Handler + Extension | Registration via `MCPServerService` init array |

### Other Common Patterns

| File | Category | Reason |
|------|----------|--------|
| `Shared/MCPCoreTypeAliases.swift` | Type aliases | Defines typealiases for MCPCore types — no callers needed; consumed implicitly |
| `Shared/Distributed/DistributedTypes.swift` | Type definitions | Shared types for distributed coordination — may have few explicit callers |

---

## Known True Orphans (To Delete)

> Files confirmed to be dead code with no callers. Update this section as orphans are resolved.

_None confirmed at this baseline (2026-01). Run `rag.orphans` to identify candidates._

---

## Orphan Check Workflow

1. After any significant refactor, run `rag.orphans` (see command above).
2. For each reported file, check this baseline:
   - **In baseline** → ignore, it's a known entry point or extension.
   - **Not in baseline** → investigate. Is it truly unused? If it's a new extension from a refactor, add it here.
3. If a file is truly orphaned (dead code), delete it and update this document.
4. If a file is a new legitimate entry point, add it to the **Known Entry Points** table above.

---

## History

| Date | Change | Issue |
|------|--------|-------|
| 2026-01 | Initial baseline established | #302 |
| 2026-01 | Added 13 RAG/Swarm extension files after god-handler split | #301 |
| 2026-01 | `MCPServerService+ToolDefinitions.swift` confirmed not a true orphan (extension pattern) | #300 |
