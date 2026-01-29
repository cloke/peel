# Swarm Worktree Integration Plan

**Date:** 2026-01-28  
**Status:** Phase 1 Implemented - Peel-side worktree isolation complete  
**Issue:** Multiple swarm tasks executing on same peel stomp on each other's branches

---

## Implementation Status

### Phase 1: Peel-Side Worktree Isolation ✅ COMPLETE

- [x] Created `SwarmWorktreeManager` class (`Shared/Distributed/SwarmWorktreeManager.swift`)
- [x] Modified `SwarmCoordinator.handleTaskRequest()` to use worktrees
- [x] Added `branchName` and `repoPath` to `ChainResult` for tracking
- [x] Added `useWorktreeIsolation` flag (defaults to `true`)
- [x] Build passes

### Phase 2: Branch Queue on Crown (Issue #201) - PENDING

### Phase 3: PR/Merge Queue (Issue #202) - PENDING

---

## Problem Statement

When the Crown dispatches multiple tasks to a peel (or even one task that creates multiple branches), they all operate in the same git checkout. This causes:

1. **Branch conflicts** - Task A creates `refactor/foo`, Task B tries to checkout `origin/main` and fails
2. **Dirty working directory** - Uncommitted changes from Task A break Task B
3. **Race conditions** - Multiple tasks trying to push to the same branch
4. **Lost work** - Force pushes can overwrite parallel work

---

## Solution: Worktree-per-Task Architecture

### Principle

Every swarm task should execute in an **isolated git worktree**, similar to how `ParallelWorktreeRunner` works for local parallel execution.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Crown (MacBook)                          │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                      BranchQueue                             │ │
│  │  - Tracks branches in-flight across all peels                │ │
│  │  - Generates unique branch names                             │ │
│  │  - Detects merge conflicts before they happen                │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                              │                                    │
│              TaskDispatch + BranchReservation                     │
└──────────────────────────────┼────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Peel (Mac Studio)                         │
│                                                                   │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ Main Repo       │  │ Worktree 1      │  │ Worktree 2      │  │
│  │ ~/code/tio-fe   │  │ ~/worktrees/    │  │ ~/worktrees/    │  │
│  │                 │  │ task-abc123/    │  │ task-def456/    │  │
│  │ (untouched)     │  │                 │  │                 │  │
│  │                 │  │ branch:         │  │ branch:         │  │
│  │                 │  │ swarm/task-abc  │  │ swarm/task-def  │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
│                              │                    │               │
│                              ▼                    ▼               │
│                        ┌───────────────────────────────┐         │
│                        │       WorktreeManager         │         │
│                        │  - Create/cleanup worktrees   │         │
│                        │  - Manage branch lifecycle    │         │
│                        └───────────────────────────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation Plan

### Phase 1: Peel-Side Worktree Isolation

**Goal:** Each task executes in an isolated worktree on the peel

#### 1.1 Add `SwarmWorktreeManager` to Peel

```swift
// Shared/Distributed/SwarmWorktreeManager.swift

@MainActor
final class SwarmWorktreeManager {
  private let worktreeBaseDir: String  // ~/peel-worktrees/
  
  /// Create a worktree for a swarm task
  func createWorktree(
    taskId: UUID,
    repoPath: String,
    branchName: String,
    baseBranch: String = "origin/main"
  ) async throws -> String {
    let worktreePath = "\(worktreeBaseDir)/\(taskId.uuidString)"
    
    // git worktree add -b <branch> <path> <base>
    let result = try await Git.run(
      "worktree", "add",
      "-b", branchName,
      worktreePath,
      baseBranch,
      in: repoPath
    )
    
    return worktreePath
  }
  
  /// Cleanup worktree after task completes
  func removeWorktree(taskId: UUID, repoPath: String) async throws {
    let worktreePath = "\(worktreeBaseDir)/\(taskId.uuidString)"
    try await Git.run("worktree", "remove", "--force", worktreePath, in: repoPath)
  }
}
```

#### 1.2 Modify `SwarmCoordinator.executeTask()` to Use Worktrees

```swift
private func executeTask(_ request: ChainRequest) async {
  // 1. Determine repo path from request or detect
  let repoPath = request.workingDirectory ?? detectRepoPath()
  
  // 2. Generate unique branch name
  let branchName = "swarm/task-\(request.id.uuidString.prefix(8))"
  
  // 3. Create isolated worktree
  let worktreePath = try await worktreeManager.createWorktree(
    taskId: request.id,
    repoPath: repoPath,
    branchName: branchName
  )
  
  // 4. Create modified request with worktree path
  var isolatedRequest = request
  isolatedRequest.workingDirectory = worktreePath
  isolatedRequest.metadata["branchName"] = branchName
  isolatedRequest.metadata["originalRepo"] = repoPath
  
  // 5. Execute chain in worktree
  defer {
    Task { try? await worktreeManager.removeWorktree(taskId: request.id, repoPath: repoPath) }
  }
  
  let result = try await chainExecutor.execute(isolatedRequest)
  // ... report result
}
```

---

### Phase 2: Crown-Side Branch Queue

**Goal:** Prevent branch name collisions and track in-flight work

#### 2.1 Add `BranchQueue` to Crown
```swift
// Shared/Distributed/BranchQueue.swift

@MainActor
@Observable
final class BranchQueue {
  /// Branches currently being worked on (taskId -> branchInfo)
  private var inFlightBranches: [UUID: BranchReservation] = [:]
  
  struct BranchReservation: Sendable {
    let taskId: UUID
    let branchName: String
    let repoPath: String
    let workerId: String
    let createdAt: Date
  }
  
  /// Reserve a branch name for a task
  func reserveBranch(
    taskId: UUID,
    preferredName: String,
    repoPath: String,
    workerId: String
  ) throws -> String {
    // Check for conflicts
    if inFlightBranches.values.contains(where: { 
      $0.branchName == preferredName && $0.repoPath == repoPath 
    }) {
      // Generate alternative name
      return "\(preferredName)-\(taskId.uuidString.prefix(4))"
    }
    
    let reservation = BranchReservation(
      taskId: taskId,
      branchName: preferredName,
      repoPath: repoPath,
      workerId: workerId,
      createdAt: Date()
    )
    inFlightBranches[taskId] = reservation
    return preferredName
  }
  
  /// Release a branch when task completes (merged or abandoned)
  func releaseBranch(taskId: UUID) {
    inFlightBranches.removeValue(forKey: taskId)
  }
  
  /// Check if a branch is available
  func isBranchAvailable(_ name: String, in repoPath: String) -> Bool {
    !inFlightBranches.values.contains { 
      $0.branchName == name && $0.repoPath == repoPath 
    }
  }
}
```

#### 2.2 Enhanced Task Dispatch

```swift
// In SwarmCoordinator
public func dispatchChain(_ request: ChainRequest) async throws -> ChainResult {
  // 1. Select peel
  guard let peel = selectPeel(for: request) else {
    throw DistributedError.noWorkersAvailable
  }
  
  // 2. Reserve branch name if repo work is involved
  var enhancedRequest = request
  if let repoPath = request.workingDirectory {
    let suggestedBranch = request.metadata["branchName"] as? String 
      ?? "swarm/task-\(request.id.uuidString.prefix(8))"
    
    let reservedBranch = try branchQueue.reserveBranch(
      taskId: request.id,
      preferredName: suggestedBranch,
      repoPath: repoPath,
      workerId: peel.id
    )
    
    enhancedRequest.metadata["reservedBranch"] = reservedBranch
    enhancedRequest.metadata["useWorktree"] = true
  }
  
  // 3. Send to peel with branch reservation
  // ...
}
```

---

### Phase 3: Merge Queue


#### 3.1 Add Merge Queue for PR Creation

```swift
// Shared/Distributed/MergeQueue.swift

@MainActor
@Observable
final class MergeQueue {
  enum MergeRequest: Sendable {
    case createPR(taskId: UUID, branchName: String, repoPath: String)
    case merge(taskId: UUID, prNumber: Int)
  }
  
  private var pendingMerges: [MergeRequest] = []
  private var isProcessing = false
  
  func enqueue(_ request: MergeRequest) {
    pendingMerges.append(request)
    processNextIfIdle()
  }
  
  private func processNextIfIdle() {
    guard !isProcessing, let next = pendingMerges.first else { return }
    isProcessing = true
    pendingMerges.removeFirst()
    
    Task {
      defer { 
        isProcessing = false
        processNextIfIdle()
      }
      
      switch next {
      case .createPR(let taskId, let branch, let repo):
        try? await createPR(taskId: taskId, branch: branch, repo: repo)
      case .merge(let taskId, let pr):
        try? await mergePR(taskId: taskId, prNumber: pr)
      }
    }
  }
}
```

---


### Swarm Task Options

Add to `ChainRequest`:

```swift
struct SwarmTaskOptions: Sendable, Codable {
  /// Use worktree isolation (default: true for repo work)
  var useWorktree: Bool = true
  
  /// Preferred branch name (will be made unique if conflicts)
  var preferredBranch: String?
  
  /// Auto-cleanup worktree after completion (default: true)
  var autoCleanupWorktree: Bool = true
  
  /// Create PR automatically after successful execution
  var autoCreatePR: Bool = false
  
  /// Target branch for PR (default: main)
  var targetBranch: String = "main"
}
```

### MCP Tool Updates

Update `swarm.dispatch` to accept worktree options:

```json
{
  "prompt": "Refactor the auth component",
  "repoPath": "/Users/coryloken/code/tio-workspace/tio-front-end",
  "worktreeOptions": {
    "useWorktree": true,
    "preferredBranch": "refactor/auth-cleanup",
    "autoCreatePR": true
  }
}
```

---

## Migration Path

1. **v1 (immediate):** Add worktree isolation to peels - each task gets its own worktree
2. **v2:** Add branch queue to Crown - prevent name collisions
3. **v3:** Add merge queue - orderly PR creation and merging
4. **v4:** Conflict detection - check for merge conflicts before dispatch

---

## Open Questions

1. **Worktree cleanup timing:** Immediately after task? After PR merged? After review?
2. **Branch naming convention:** `swarm/task-{id}` vs user-specified vs template-based?
3. **Repo discovery:** How does a peel know which repo to use if not specified?
4. **Cross-repo tasks:** How to handle tasks that span multiple repos?
5. **Merge conflict handling:** Retry on different base? Ask user? Auto-resolve?

---


- [ParallelWorktreeRunner.swift](../Shared/Services/ParallelWorktreeRunner.swift) - Local parallel execution (model to follow)
- [SwarmCoordinator.swift](../Shared/Distributed/SwarmCoordinator.swift) - Current swarm implementation
2. **Branch naming convention:** `swarm/task-{id}` vs user-specified vs template-based?
