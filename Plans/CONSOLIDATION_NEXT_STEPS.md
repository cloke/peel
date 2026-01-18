# Code Consolidation & Cleanup Plan

**Created:** January 18, 2026  
**Updated:** January 17, 2026  
**Status:** Proposed  
**Goal:** Reduce overlap between Git, GitHub, Workspaces, and Agents features while enabling cross-feature integration

---

## ✅ Selected Safe Picks (Jan 17, 2026)

These are low-risk, localized changes that can be done without architectural refactors:

- [x] Delete duplicate `VSCodeService` in `ReviewLocallyService.swift` (lines 247-299)
- [x] Delete `findVSCode()` + `openInVSCode()` in `Git/Git.swift` (lines 6-31)
- [x] Delete `findVSCode()` + `openInVSCode()` in `Git/WorktreeListView.swift` (lines 14-42)
- [x] Delete duplicate `parseWorktreeList()` in `WorkspaceDashboardService.swift` (lines 314-371)
- [x] Replace `WorkspaceDashboardService.runGit()` to use `Git.Commands.simple()`
- [x] Inject VSCode opener via closure in Git package views

These map directly to Phase 1 items 1, 2, 3, 4, and 5 below, plus the git helper cleanup in Phase 2.

## Executive Summary

After deep-diving the codebase, I found significant overlap in:
1. **VSCode integration** - 3 separate implementations
2. **Worktree management** - 4 different approaches  
3. **Worktree parsing** - Duplicated in 2 files
4. **Repository models** - 6+ different representations
5. **Error types** - 3 separate WorktreeError/WorkspaceError enums
6. **Git command execution** - Multiple runners

These create "walled gardens" where each feature (Git, GitHub, Agents, Workspaces) has its own isolated implementation of the same concepts.

### Feature Visibility Matrix (Current State)

| Worktree Source | Git Tab | Workspaces Tab | Agents Tab |
|-----------------|---------|----------------|------------|
| Manual (Git package) | ✅ | ❌ | ❌ |
| PR Review (ReviewLocallyService) | ❌ | ❌ | ❌ |
| Agent (WorkspaceManager) | ❌ | ❌ | ✅ |
| Chain (WorktreeService) | ❌ | ❌ | ✅ |
| Workspace Dashboard | ❌ | ✅ | ❌ |

**Goal:** All worktrees visible in Workspaces tab with source tags.

---

## 🔴 Critical: VSCodeService Duplication

### Current State (2 implementations)

| Location | Type | Features |
|----------|------|----------|
| `Shared/Services/VSCodeService.swift` | Actor | Full-featured: open, openFile, openDiff, openIsolated |
| `Git/VSCodeLauncher.swift` | Helpers | open (path), install detection |

### Recommended Action

**DELETE** the duplicate VSCodeService in `ReviewLocallyService.swift` (lines 247-299) and use `Git.VSCodeLauncher`.

```swift
// ReviewLocallyService.swift - REMOVE lines 247-299 entirely
// (the duplicate VSCodeService actor and VSCodeError enum)
// Use Git.VSCodeLauncher from the Github package
```

**ALSO DELETE** the private `findVSCode()` and `openInVSCode()` functions in:
- `Git/Git.swift` (lines 6-31)
- `Git/WorktreeListView.swift` (lines 14-42)

### Integration Points

The Git package cannot directly import from Shared, so either:
1. **Option A:** Create a `Core` or `Common` local package that Git and Github can import
2. **Option B:** Pass VSCode as a closure/protocol from the app layer  
3. **Option C:** Move VSCodeService into a standalone `VSCode` local package

**Recommended:** Option B - Inject via closure. Example:

```swift
// In Git package
public struct GitRootView: View {
  var onOpenInVSCode: (String) -> Void = { _ in }
  
  // Usage: onOpenInVSCode(worktree.path)
}

// At app layer (Git_RootView.swift)
GitRootView(repository: viewModel.selectedRepository) { path in
  Task { try? await VSCodeService.shared.open(path: path) }
}
```

This is simpler than creating a new package and follows dependency inversion.

---

## 🟠 High Priority: Worktree/Workspace Model Fragmentation

### Current State (5+ Models!)

| Model | Location | Purpose |
|-------|----------|---------|
| `Git.Worktree` | `Git/Commands/Worktree.swift` | Raw git worktree data (SOURCE OF TRUTH) |
| `WorktreeInfo` | `Shared/Services/WorkspaceDashboardService.swift` | Dashboard display |
| `AgentWorkspace` | `Shared/AgentOrchestration/Models/AgentWorkspace.swift` | Agent isolation |
| `ActiveWorktree` | `Shared/AgentOrchestration/WorktreeService.swift` | Chain worktrees |
| `LocalRepository` | `Github/Services/ReviewLocallyService.swift` | PR review repos |
| `TrackedWorktree` | `Shared/PeelApp.swift` (SwiftData) | Persistence (UNUSED!) |

### The Problem

- `Git.Worktree` is the "ground truth" from git commands
- `WorktreeInfo` duplicates parsing logic that `Git.Worktree` already does (lines 314-371)
- `AgentWorkspace` wraps worktrees but also duplicates concepts
- `ActiveWorktree` is essentially another wrapper
- `TrackedWorktree` SwiftData model exists but ISN'T CONNECTED to any runtime models!

### Recommended Consolidation

**Single Source of Truth:** `Git.Worktree` should be the base model. Other features should:
1. Use `Git.Worktree` directly when displaying worktrees
2. Create lightweight wrappers only for feature-specific metadata
3. Use `TrackedWorktree` SwiftData model for persistence

```swift
// Proposed: AgentWorkspace becomes a wrapper, not a duplicate
@MainActor
@Observable
public final class AgentWorkspace: Identifiable {
  public let id: UUID
  public let worktree: Git.Worktree  // Use Git's model directly
  public var assignedAgentId: UUID?
  public var status: WorkspaceStatus
  // Feature-specific properties only
}

// WorktreeInfo should be DELETED - use Git.Worktree directly
// Or create a thin extension:
extension Git.Worktree {
  var repoName: String { URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent }
  var workspaceName: String { /* computed from parent */ }
}
```

**DELETE** `WorktreeInfo` from `WorkspaceDashboardService.swift` and use `Git.Worktree` directly.

**CONNECT** `TrackedWorktree` (SwiftData) to track worktree metadata that survives app restarts:
- Purpose/description
- Linked PR number
- Source (agent, PR review, manual)
- Creation date

---

## 🟠 High Priority: Duplicate Worktree Parsing

### Current State (2 Parsers!)

| Location | Lines | Function |
|----------|-------|----------|
| `Git/Commands/Worktree.swift` | 176-254 | `parseWorktreeList(_:)` - CANONICAL |
| `Shared/Services/WorkspaceDashboardService.swift` | 314-371 | `parseWorktreeList(_:...)` - DUPLICATE |

Both parse `git worktree list --porcelain` output. The duplicate in `WorkspaceDashboardService` is less complete (missing `lockReason`, `pruneReason`, `isBare` fields).

### Recommended Fix

**DELETE** lines 308-371 in `WorkspaceDashboardService.swift` and import from Git package:

```swift
// WorkspaceDashboardService.swift - BEFORE
private func loadWorktrees(for repo: WorkspaceRepo, in workspace: Workspace) async throws -> [WorktreeInfo] {
  let output = try await runGit(["worktree", "list", "--porcelain"], in: repo.path)
  return parseWorktreeList(output, repoName: repo.name, workspaceName: workspace.name, mainPath: repo.path)
}

// AFTER - Use Git.Commands.Worktree.list() directly
private func loadWorktrees(for repo: WorkspaceRepo, in workspace: Workspace) async throws -> [Git.Worktree] {
  let repository = Model.Repository(name: repo.name, path: repo.path)
  return try await Commands.Worktree.list(on: repository)
}
```

---

## 🟠 High Priority: Duplicate Worktree Services

### Current State (3 Services!)

| Service | Location | Responsibility |
|---------|----------|----------------|
| `Commands.Worktree` | `Git/Commands/Worktree.swift` | Git worktree commands |
| `WorkspaceManager` | `Shared/AgentOrchestration/WorkspaceManager.swift` | Agent workspaces |
| `WorktreeService` | `Shared/AgentOrchestration/WorktreeService.swift` | Chain worktrees |
| `WorkspaceDashboardService` | `Shared/Services/WorkspaceDashboardService.swift` | Dashboard worktrees |

### The Overlap

1. `WorkspaceDashboardService` re-implements worktree parsing (lines 314-371) instead of using `Commands.Worktree.list()`
2. `WorktreeService` wraps `Commands.Worktree` but adds chain-specific tracking
3. `WorkspaceManager` also wraps `Commands.Worktree` for agent workspaces

### Recommended Consolidation

**Option A: Merge WorkspaceManager + WorktreeService**
- Both serve the same "Agents" feature
- Merge into single `AgentWorkspaceService`

**Option B: Make WorkspaceDashboardService use Git.Commands**
- Delete lines 308-371 (parsing logic)
- Call `Commands.Worktree.list()` instead of manual parsing

```swift
// WorkspaceDashboardService - replace manual parsing
private func loadWorktrees(for repo: WorkspaceRepo, in workspace: Workspace) async throws -> [Git.Worktree] {
  let repository = Model.Repository(name: repo.name, path: repo.path)
  return try await Commands.Worktree.list(on: repository)
}
```

---

## 🟡 Medium Priority: Feature Integration Opportunities

### 1. "Review Locally" Should Use Workspaces Feature

`ReviewLocallyService` in the GitHub package creates worktrees for PR review. This should integrate with the Workspaces dashboard so users can see their PR review worktrees in one place.

**Current Flow:**
```
GitHub PR → ReviewLocallyService → Creates worktree → Opens VS Code
                                   (invisible to Workspaces tab)
```

**Proposed Flow:**
```
GitHub PR → WorkspaceDashboardService.createWorktreeForPR() → Creates worktree
         → Visible in Workspaces tab
         → Opens VS Code
```

### 2. Agent Workspaces Should Appear in Workspaces Tab

Currently:
- Agents tab shows agent workspaces
- Workspaces tab shows manually-added workspaces
- These are completely separate

**Proposed:**
- Workspaces tab should show ALL worktrees (manual + agent + PR review)
- Each worktree tagged with source: `manual`, `agent`, `pr-review`
- Filter/group by source

### 3. Git Tab Worktree List Should Link to Workspaces

The Git tab has `WorktreeListView` which shows worktrees for the current repo.
Users should be able to "Open in Workspaces Dashboard" to see the full picture.

---

## 🟡 Medium Priority: Repository Model Alignment

### Current Models (6 Types!)

| Model | Package | Purpose | Persisted? |
|-------|---------|---------|-----------|
| `Model.Repository` | Git | Runtime git operations | No |
| `Github.Repository` | Github | API response model | No |
| `SyncedRepository` | Shared (SwiftData) | Cross-device sync | ✅ iCloud |
| `LocalRepositoryPath` | Shared (SwiftData) | Device-local path mapping | ✅ Local |
| `Workspace` | Shared | Workspace container | ✅ UserDefaults |
| `WorkspaceRepo` | Shared | Repo within workspace | No |
| `LocalRepository` | Github | PR review local repo | ✅ UserDefaults |

### Relationships That Should Exist

```
SyncedRepository (SwiftData - iCloud sync)
    ↓ has many
LocalRepositoryPath (SwiftData - device-local path)
    ↓ creates
Model.Repository (runtime Git operations)
    ↓ contains
Git.Worktree (worktree instances)
    ↓ tracked by
TrackedWorktree (SwiftData - metadata persistence)

Github.Repository (API data)
    ↓ can be linked via remoteURL to
SyncedRepository (local clone)
```

### Recommended Changes

1. **DELETE** `LocalRepository` in `ReviewLocallyService` - use `Model.Repository` directly
2. **DELETE** `WorkspaceRepo` - it's redundant with `Model.Repository`
3. **Link** `SyncedRepository` to `Github.Repository` via `remoteURL` matching
4. **Simplify** `Workspace` - convert from UserDefaults to SwiftData
5. **USE** `TrackedWorktree` SwiftData model - currently defined but unused!

### Migration Path

```swift
// Step 1: Make ReviewLocallyService use Model.Repository
// OLD
public struct LocalRepository { ... }

// NEW - just use Git's model
import Git
// let repository = Model.Repository(name: name, path: path)
```

---

## 🟢 Lower Priority: Code Organization

### 1. Move Common Git Helpers to Git Package

`WorkspaceDashboardService` has git helper methods (lines 576-610) that duplicate `Commands.simple()`:

```swift
// DELETE this and use Git.Commands.simple() instead
private func runGit(_ args: [String], in directory: String) async throws -> String
```

### 2. Consolidate Error Types (3 Duplicates!)

| Error Type | Location | Cases |
|------------|----------|-------|
| `WorktreeError` | `WorkspaceDashboardService.swift:615` | cannotRemoveMain, repoNotFound, commandFailed |
| `WorkspaceError` | `WorkspaceManager.swift:258` | creationFailed, cleanupFailed, cannotRemove, notFound |
| `WorktreeError` | `WorktreeService.swift:42` | repositoryNotFound, worktreeCreationFailed, worktreeRemovalFailed, worktreeNotFound, branchCreationFailed, gitNotAvailable |

**Recommended:** Single unified error type in a shared location:

```swift
// Shared/Services/WorktreeErrors.swift
public enum WorktreeError: LocalizedError {
  case repositoryNotFound(String)
  case creationFailed(Error)
  case removalFailed(Error)
  case cannotRemoveMain
  case notFound(UUID)
  case gitNotAvailable
  case commandFailed(String)
  
  public var errorDescription: String? { ... }
}
```

### 3. Remove Dead Code

- `TaskDebugWindow.swift` - stub file mentioned in CODE_AUDIT_INDEX.md
- Any iOS stubs that are placeholders only
- Unused `TrackedWorktree` SwiftData model (or CONNECT it!)

### 4. Unused SwiftData Models

The following SwiftData models in `PeelApp.swift` appear to be defined but not actively used:

| Model | Lines | Status |
|-------|-------|--------|
| `TrackedWorktree` | 176-201 | **UNUSED** - should track worktrees |
| `LocalRepositoryPath` | 149-173 | Partially used |
| `DeviceSettings` | ~210+ | Check usage |

---

## Implementation Order

### Phase 1: Quick Wins (Low Risk) - 1 session
1. [x] Delete duplicate `VSCodeService` in `ReviewLocallyService.swift` (lines 247-299)
2. [x] Delete `findVSCode()` + `openInVSCode()` in `Git/Git.swift` (lines 6-31)
3. [x] Delete `findVSCode()` + `openInVSCode()` in `Git/WorktreeListView.swift` (lines 14-42)
4. [x] Inject VSCode opener via closure in Git package views
5. [x] Delete duplicate `parseWorktreeList()` in `WorkspaceDashboardService.swift` (lines 314-371)

### Phase 2: Model Alignment - 1 session
6. [x] Make `WorkspaceDashboardService` use `Commands.Worktree.list()`
7. [ ] Delete `WorktreeInfo` struct, use `Git.Worktree` + extension
8. [ ] Delete `LocalRepository` in `ReviewLocallyService` - use `Model.Repository`
9. [x] Switch `runGit()` helper in `WorkspaceDashboardService` to use `Commands.simple()`

### Phase 3: Service Consolidation - 1-2 sessions
10. [ ] Merge `WorktreeService` into `WorkspaceManager` (both serve Agents)
11. [ ] Consolidate 3 error enums into single `WorktreeError`
12. [ ] Connect `TrackedWorktree` SwiftData model to track all worktrees

### Phase 4: Feature Integration - 1-2 sessions
13. [ ] Make agent workspaces visible in Workspaces dashboard
14. [ ] Make PR review worktrees visible in Workspaces dashboard  
15. [ ] Add source tags (agent, PR review, manual) to worktree display
16. [ ] Add cross-linking between Git, GitHub, Workspaces, and Agents tabs

### Phase 5: Cleanup - 1 session
17. [ ] Delete `WorkspaceRepo` - redundant with `Model.Repository`
18. [ ] Migrate `Workspace` from UserDefaults to SwiftData
19. [ ] Remove any remaining dead code
20. [ ] Update documentation

---

## Architecture Vision

After consolidation, the feature boundaries should be:

| Feature | Responsibility | Does NOT Own |
|---------|---------------|--------------|
| **Git Package** | Git commands, `Model.Repository`, `Git.Worktree` | UI, VS Code integration |
| **Github Package** | API models, API calls, GitHub-specific views | Local git operations |
| **Agents (Shared)** | Agent lifecycle, agent-specific state | Worktree creation (delegates to Git) |
| **Workspaces (Shared)** | Unified worktree dashboard, VS Code launching | Git commands (delegates to Git) |

Cross-cutting concerns (VS Code, file system access) should live in shared services that all features use.

---

## Questions for Discussion

1. **Should Workspaces become the "hub" for all worktree views?**
   - Pro: Single place to see all worktrees
   - Con: Agents/Git tabs lose their worktree displays
   - **Recommendation:** Keep local displays but link to Workspaces for "full view"

2. **Should ReviewLocallyService move from Github package to Shared?**
   - It's already tightly coupled to Git and VSCode
   - **Recommendation:** Keep in Github but ensure it notifies Workspaces

3. **Is the separate Workspaces tab needed, or should it merge with Git?**
   - Workspaces handles multi-repo setups, Git handles single repo
   - **Recommendation:** Keep separate, Workspaces is the "orchestration" view

4. **Should TrackedWorktree SwiftData model sync to iCloud?**
   - Pro: See your worktrees across devices
   - Con: Paths are device-specific
   - **Recommendation:** Keep device-local, just sync metadata (purpose, PR link)

---

**Total Estimated Effort:** 5-7 focused sessions

**Risk Level:** Medium - touching shared code paths, but changes are mostly deletions of duplicates

**Dependencies:** None - can be done incrementally

**Suggested Starting Point:** Phase 1 (Quick Wins) can be done immediately with no breaking changes
