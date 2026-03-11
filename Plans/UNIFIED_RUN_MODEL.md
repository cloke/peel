# Unified Run Model — Consolidation Plan

> **Goal**: One model, one queue, one review surface. A "Run" is a Run — PR review, local code agent work, 1 task or 1000. Long-lived ideas that you triage at your own pace.

**Status**: Proposed  
**Epic**: Personal Agent (#367)

---

## Problem

Five overlapping tracking systems exist today:

| System | Model | Storage | Tracks |
|--------|-------|---------|--------|
| Parallel Worktree Runner | `ParallelWorktreeRun` + `Execution` | In-memory + `ParallelRunSnapshot` (SwiftData) | Actual execution, review gates, merge |
| Legacy Chain Tracking | `ActiveRunInfo` + `activeChainTasks` | In-memory only (lost on quit) | VM-routed chain runs |
| Chain History | `MCPRunRecord` + `MCPRunResultRecord` | SwiftData | Post-completion records |
| PR Review Queue | `PRReviewQueueItem` | SwiftData | PR review → fix → push lifecycle |
| Agent Chain | `AgentChain` + `AgentChainResult` | In-memory (results persisted post-run) | Live chain state |

This causes:
- `chains.run.status` can't find parallel-routed runs (just fixed)
- `chains.stop` can't cancel parallel-routed runs (just fixed)
- Zombie runs when tracking layers disagree
- 4 sidebar entries showing overlapping data
- PR reviews are a special case instead of just another run
- No way to have a long-lived "idea" that spawns runs over days/weeks

---

## Target Architecture

### The Model: `Run`

Everything is a `Run`. A Run has 1-to-N `Execution`s. An Execution is one worktree doing one piece of work.

```
Run (the unit of work you care about)
├── id: UUID
├── name: String                    — "Review PR #7091" or "Refactor auth module"
├── kind: RunKind                   — .prReview | .codeChange | .investigation | .custom
├── status: RunStatus               — .pending | .running | .awaitingReview | .approved | .merging | .completed | .failed | .paused
├── priority: Int                   — Queue ordering
├── prompt: String                  — What was asked
├── projectPath: String             — Repo root
├── baseBranch: String
├── templateName: String?
│
├── executions: [Execution]         — 1 for simple, N for parallel
│   ├── id: UUID
│   ├── worktreePath: String?
│   ├── branchName: String?
│   ├── status: ExecutionStatus     — Same rich enum we have today
│   ├── output: String
│   ├── diff: DiffSummary
│   ├── reviewRecords: [ReviewRecord]
│   ├── artifacts: [Artifact]
│   ├── chainStepResults: [ChainStepSummary]
│   └── ...
│
├── context: RunContext             — Kind-specific metadata
│   ├── pr: PRContext?              — owner, repo, prNumber, headRef, htmlURL, verdict
│   ├── vm: VMContext?              — executionEnvironment, directoryShares
│   └── idea: IdeaContext?          — parent idea, iteration number
│
├── reviewGate: Bool                — Requires human review before merge
├── autoMerge: Bool                 — Merge on approval without asking
│
├── timestamps: RunTimestamps
│   ├── created, started, completed
│   ├── reviewStarted, reviewCompleted
│   └── lastUpdated
│
├── error: String?
├── operatorGuidance: [String]
├── sourceChainRunId: UUID?         — Backward compat during migration
└── parentRunId: UUID?              — For "idea" runs that spawn sub-runs
```

### What Goes Away

| Current | Replaced By |
|---------|-------------|
| `ParallelWorktreeRun` | `Run` |
| `ParallelWorktreeExecution` | `Execution` |
| `PRReviewQueueItem` | `Run` with `kind: .prReview` + `context.pr` |
| `ActiveRunInfo` | `Run` (in-memory runs are just runs with `.running` status) |
| `MCPRunRecord` | `Run` (completed runs stay in the same table) |
| `completedRunsById` dict | Query: `runs.filter { $0.status.isTerminal }` |
| `activeChainTasks` dict | `RunManager.activeTasks[runId]` |

### What Stays (internal, not user-facing)

| Current | Why |
|---------|-----|
| `AgentChain` | Internal execution engine — creates a Run's Execution results |
| `AgentChainRunner` | Runs the actual chain steps |
| `WorkspaceManager` | Creates/destroys git worktrees |
| `ParallelRunSnapshot` | Becomes the SwiftData backing for `Run` |

---

## The Queue: One Review Surface

Today's sidebar has: Activity Dashboard, Worktrees, Chains, Agent Runs, PR Reviews.

**After**: One **Runs** view with smart filters.

```
┌─────────────────────────────────────────────┐
│  Runs                              [+ New]  │
├─────────────────────────────────────────────┤
│  ▼ Needs Review (3)                         │
│    ● PR #7091 — PSLF non-partner TBD        │
│    ● Refactor auth module (2/3 tasks done)   │
│    ● PR #7096 — Limit receipt uploads        │
│                                              │
│  ▼ Running (1)                               │
│    ◐ Investigate flaky test suite             │
│                                              │
│  ▼ Approved / Ready to Merge (1)             │
│    ✓ PR #7078 — Eligibility periods          │
│                                              │
│  ▼ Ideas / Paused (2)                        │
│    ◉ Rewrite billing pipeline (iteration 3)  │
│    ◉ Migrate to structured concurrency       │
│                                              │
│  ▼ Completed (47)                 [Show all] │
│    ✓ PR #6973 — Consolidate MCP controllers  │
│    ✓ ...                                     │
└─────────────────────────────────────────────┘
```

Filters: kind (PR, code, idea), status, repo, date range  
Sort: priority, newest, oldest, most recently updated

### Long-Running Ideas

A Run with `kind: .idea` + `status: .paused` is an idea you're working on over days/weeks. It can:
- Have a `parentRunId` so sub-runs link back to it
- Be resumed → spawns a new execution iteration
- Accumulate review records and artifacts across iterations
- Show a timeline: "Iteration 1 → reviewed → needs fix → Iteration 2 → approved"

---

## Migration Strategy

### Phase 1: Unified RunManager (behind the scenes)

Create `RunManager` as the single source of truth. It wraps `ParallelWorktreeRunner` (which already does 90% of the work).

```swift
@MainActor @Observable
final class RunManager {
  /// All runs, including historical. Active runs are in-memory;
  /// completed runs loaded from SwiftData on demand.
  private(set) var runs: [Run] = []
  
  /// Active Swift Tasks for running executions
  var activeTasks: [UUID: Task<Void, Never>] = [:]
  
  // Delegates to existing infrastructure
  let worktreeRunner: ParallelWorktreeRunner
  let chainRunner: AgentChainRunner
  let workspaceManager: WorkspaceManager
  
  // MARK: - Public API
  func createRun(...) -> Run
  func startRun(_ run: Run) async throws
  func stopRun(_ run: Run) async
  func approveExecution(...) 
  func rejectExecution(...)
  func mergeExecution(...)
  func pauseRun(_ run: Run)     // For ideas — park it
  func resumeRun(_ run: Run)    // Spawn new iteration
  
  // MARK: - Queries
  func runsNeedingReview() -> [Run]
  func runningRuns() -> [Run]
  func runsByKind(_ kind: RunKind) -> [Run]
}
```

**Key**: `RunManager` is a thin coordination layer. The actual execution still goes through `ParallelWorktreeRunner` / `AgentChainRunner`. We're not rewriting execution — we're unifying the tracking.

### Phase 2: Route `handleChainRun` through RunManager

```swift
// Before (current):
let run = runner.createAndStartSingleTaskRun(...)

// After:
let run = runManager.createRun(
  name: template.name,
  kind: .codeChange,
  prompt: prompt,
  projectPath: projectPath,
  ...
)
try await runManager.startRun(run)
```

For PR reviews:
```swift
// Before (current):
let qi = mcp.prReviewQueue.enqueue(...)
mcp.prReviewQueue.markReviewing(qi, ...)
let (_, data) = await mcp.handleChainRun(...)

// After:
let run = runManager.createRun(
  name: "Review PR #\(prNumber)",
  kind: .prReview,
  context: .pr(owner: owner, repo: repo, prNumber: prNumber, ...),
  prompt: buildPrompt(),
  ...
)
try await runManager.startRun(run)
```

### Phase 3: Kill Legacy Tracking

Remove:
- `activeRunsById`, `activeChainTasks`, `activeChainRunIds`, `completedRunsById` from MCPServerService
- `PRReviewQueue` (absorbed into RunManager)
- `MCPRunRecord` creation (Run persistence handles it)
- Separate `ParallelRunSnapshot` (Run IS the snapshot)

`chains.run.status` / `chains.stop` / `chains.list` all just query `RunManager`.

### Phase 4: Unified UI

Replace the 4+ sidebar sections with one **Runs** view.

- `RunsListView` — the queue (filterable, sortable)
- `RunDetailView` — shows executions, diffs, review controls, timeline
- `ExecutionDetailView` — already exists, reuse it
- Kill: `ParallelWorktreeDashboardView`, `PRReviewQueueView`, separate chain views

### Phase 5: Route VM Templates Through RunManager

The 7 VM templates currently bypass parallel worktrees. Add VM lifecycle support to RunManager so they're just another execution environment on a Run.

---

## Execution Order

| # | What | Risk | Effort |
|---|------|------|--------|
| 1 | Create `Run` model + `RunManager` wrapper around `ParallelWorktreeRunner` | Low — additive | Medium |
| 2 | Route `handleChainRun` through `RunManager.createRun()` | Medium — all chains affected | Medium |
| 3 | Absorb PR review queue into RunManager (PR = Run with kind) | Medium — SwiftData migration | Medium |
| 4 | Build unified Runs UI | Low — new view, old views stay until ready | Large |
| 5 | Delete legacy tracking (`activeRunsById`, etc.) | High — must verify nothing references it | Small |
| 6 | Delete old views | Low — behind feature flag | Small |
| 7 | VM template routing through RunManager | Medium — VM lifecycle in runner | Large |

Phases 1-3 can land as a single PR. Phase 4 can be incremental (new view + old views coexist). Phase 5 is independent.

---

## MCP Tool Surface (unchanged externally)

The MCP tools keep the same names but query RunManager:

| Tool | Behavior Change |
|------|-----------------|
| `chains.run` | Creates a Run via RunManager instead of routing internally |
| `chains.run.status` | Queries `runManager.run(id:)` — one lookup, no fallback chains |
| `chains.run.list` | `runManager.runs` — no more stitching 4 sources |
| `chains.stop` | `runManager.stopRun()` — works for all run types |
| `pr.review.queue.list` | `runManager.runsByKind(.prReview)` |
| `pr.review.queue.update` | `runManager.updateRun(...)` |
| `parallel.*` tools | Thin wrappers around RunManager methods |

New tools:
| Tool | Purpose |
|------|---------|
| `runs.list` | Unified listing (replaces chains.run.list + pr.review.queue.list + parallel.list) |
| `runs.review` | Approve/reject any execution |
| `runs.pause` / `runs.resume` | Park/resume long-running ideas |

Old tools remain as aliases during migration.

---

## Key Design Decisions

1. **`Run` is SwiftData-persisted from creation** — no more in-memory-only tracking that dies on quit
2. **`ParallelWorktreeRunner` stays as the execution engine** — we're not rewriting it, just wrapping it
3. **PR-specific fields live in `RunContext.pr`** — not polluting the base model
4. **`parentRunId` enables idea hierarchies** — an idea spawns sub-runs, each is independently reviewable
5. **Review records are on Execution, not Run** — because you review individual pieces of work
6. **One queue, many filters** — not separate queues per type
