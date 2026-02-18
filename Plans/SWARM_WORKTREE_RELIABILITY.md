# Swarm Worktree Reliability Plan

**Status:** In Progress  
**Created:** 2026-02-18  
**Issues:** #281 #282 #283 #284 #285 #286  
**Root problem:** `SwarmWorktreeManager.activeWorktrees` is in-memory only — Peel restarts lose all task→worktree mappings, causing `commitAndPushChanges` to silently return `false`.

---

## Architecture Decision: SwiftData, Local-Only

**Why SwiftData over a JSON file in Application Support:**
- Already used throughout the app; shared model container is configured
- `TrackedWorktree` model already exists — extend it rather than create new infrastructure
- Queryable: find all `source == "swarm" AND taskStatus == "active"` on startup for recovery
- History: keep cleaned records for the status panel (filter by `completedAt > now - 1hr`)
- Free crash-safety (SQLite WAL)

**Why NOT cloud sync for swarm state:**
- Worktree paths are local machine paths; they're meaningless on other devices
- Cross-machine task coordination already uses Firestore (the right tool for that)
- Conflicts between two machines' worktree state would be unresolvable
- Implementation: fields live in `TrackedWorktree` which is in the shared container; CloudKit ignores models that aren't registered in the CloudKit schema — but more cleanly, these fields all have defaults so they are compatible if sync is ever enabled (they just wouldn't be meaningful on another device)

---

## Implementation Sequence

### Step 1: Extend `TrackedWorktree` (#281)
**File:** `Shared/SwiftDataModels.swift`

Add to the existing `TrackedWorktree` @Model:
```swift
var taskId: String = ""           // swarm task UUID ("" = manual worktree)
var taskStatus: String = "active" // active | committed | failed | orphaned | cleaned
var mainRepoPath: String = ""     // main repo path (worktree's parent repo)
var taskPrompt: String?           // first 200 chars of prompt, for display
var workerId: String?             // worker device ID
var failureReason: String?
var completedAt: Date?
```

Also add constants:
```swift
extension TrackedWorktree {
  static let sourceManual = "manual"
  static let sourceSwarm = "swarm"
  static let sourceParallel = "parallel"

  static let statusActive = "active"
  static let statusCommitted = "committed"
  static let statusFailed = "failed"
  static let statusOrphaned = "orphaned"
  static let statusCleaned = "cleaned"
}
```

**CloudKit compatibility:** All new fields have default values. ✅

---

### Step 2: Back SwarmWorktreeManager with SwiftData (#282)
**File:** `Shared/Distributed/SwarmWorktreeManager.swift`

1. Add `modelContext: ModelContext?` property — injected from app, optional so tests still work without container
2. `createWorktree` → persist `TrackedWorktree` record before returning path
3. `commitAndPushChanges` → if `activeWorktrees[taskId]` is nil, fall back to SwiftData query by `taskId`
4. `removeWorktree` → set `taskStatus = "cleaned"`, `completedAt = Date()` (don't delete)
5. `init` → call `recoverFromPersistence()` which loads all `taskStatus == "active"` records and repopulates `activeWorktrees`

How `modelContext` gets injected:
- `SwarmCoordinator` (which owns `SwarmWorktreeManager`) is initialized in `PeelApp` or `ContentView`
- Pass `ModelContext(Self.sharedModelContainer)` from `PeelApp.init`

---

### Step 3: Orphan Recovery (#283)
**File:** `Shared/Distributed/SwarmWorktreeManager.swift` (new `recoverAndPrune()` method)

Called from `init` after `recoverFromPersistence()`:
1. Parse `git worktree list --porcelain` for each unique `mainRepoPath` in active DB records
2. DB record with no matching git worktree → mark `taskStatus = "orphaned"` (don't silently delete)
3. Filesystem entry in `~/peel-worktrees/task-*` with no DB record → `git worktree prune` + remove from disk
4. Tolerant of missing repos (catches all errors per-repo)

---

### Step 4: Move Fetch Off Critical Path (#285)
**File:** `Shared/Distributed/SwarmWorktreeManager.swift`

Change `createWorktree`:
```swift
// Before: blocks entire worktree creation on git fetch
let fetchResult = try await runGitCommand(args: ["fetch", "origin"], in: repoPath)

// After: fire-and-forget unless base ref is genuinely missing
let baseBranchExists = await refExists(baseBranch, in: repoPath)
if !baseBranchExists {
  // Only wait for fetch if we actually need it
  try await runGitCommandWithTimeout(["fetch", "origin"], in: repoPath, timeout: 15)
}
// Log warning if fetch failed instead of swallowing
```

---

### Step 5: BranchQueue (#284) — Crown Side
**File:** `Shared/Distributed/BranchQueue.swift` (already has design in SWARM_WORKTREE_INTEGRATION.md)

- `@MainActor @Observable final class BranchQueue`
- In-memory + SwiftData backed reservations
- `SwarmCoordinator` (brain mode) calls `reserveBranch` before dispatching
- Workers receive branch name in task payload instead of generating it

---

### Step 6: Worktree Status UI (#286)
**File:** `Shared/Distributed/SwarmStatusView.swift`

- Query `TrackedWorktree` where `source == "swarm"` and recent
- Show in a collapsible section of the swarm panel
- Disk size + age + status badge

---

## Testing Strategy

- Unit tests for `SwarmWorktreeManager` need a mock `ModelContext` (in-memory container)
- Key regression: task created → Peel restarts → `commitAndPushChanges` still works
- Orphan recovery: manually create directory in `~/peel-worktrees/` with no DB record → verify it's pruned on next launch
