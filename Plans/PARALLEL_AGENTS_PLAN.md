# Parallel Agents with Worktrees and Merge Agent

## Vision

Enable truly parallel code changes by having multiple implementers work in **separate git worktrees**, then using a **Merge Agent** to intelligently combine their work.

## Architecture

```
┌─────────────┐
│   Planner   │
│  (Analyze)  │
└──────┬──────┘
       │ Creates branch name + task split
       ▼
┌──────────────────────────────────────┐
│     Branch: feature/planner-name     │
│          (created, not checked out)  │
└──────────────────────────────────────┘
       │
       ├─────────────────┬─────────────────┐
       ▼                 ▼                 ▼
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│Implementer 1│   │Implementer 2│   │Implementer 3│
│ (Worktree A)│   │ (Worktree B)│   │ (Worktree C)│
└──────┬──────┘   └──────┬──────┘   └──────┬──────┘
       │                 │                 │
       │ Run in parallel (TaskGroup)       │
       ▼                 ▼                 ▼
┌──────────────────────────────────────────┐
│              Merge Agent                  │
│  - Analyzes all worktree changes         │
│  - Detects conflicts                     │
│  - Merges into feature branch            │
│  - Reports issues back to implementers   │
└──────────────────────────────────────────┘
       │
       ▼
┌─────────────┐
│  Reviewer   │
│ (Optional)  │
└─────────────┘
```

## New Agent Roles

### 1. Planner (Enhanced)
In addition to current responsibilities:
- **Decide branch name** based on the task
- **Create the branch** (but don't check it out)
- **Split the task** into independent sub-tasks for each implementer
- Output structured task assignments

Example output:
```json
{
  "branchName": "feature/add-user-settings",
  "tasks": [
    {
      "implementer": 1,
      "description": "Add SettingsViewModel with user preferences",
      "files": ["Shared/ViewModels/SettingsViewModel.swift"]
    },
    {
      "implementer": 2, 
      "description": "Add SettingsView UI with toggles and pickers",
      "files": ["Shared/Views/SettingsView.swift"]
    }
  ]
}
```

### 2. Merger (New Role)
```swift
public enum AgentRole: String, Codable, CaseIterable {
  case planner
  case implementer
  case reviewer
  case merger  // NEW
}
```

Responsibilities:
- Analyze changes from all worktrees
- Detect semantic conflicts (not just git conflicts)
- Decide merge strategy:
  - Clean merge: All changes are independent
  - Sequential merge: Apply in order with conflict resolution
  - Request changes: Send specific feedback to implementers
- Execute the merge into the feature branch
- Report results

System prompt:
```
You are a MERGER agent. Your role is to:
- Analyze changes from multiple implementers working in parallel
- Detect conflicts (both git conflicts and semantic conflicts)
- Merge changes into the target branch intelligently
- If conflicts can't be auto-resolved, provide specific feedback

You have WRITE ACCESS to merge branches and resolve conflicts.
You should prefer clean merges when possible.
Report any issues that need implementer attention.
```

## Implementation Phases

### Phase 1: Worktree Support
1. Add `createWorktree(branchName:)` to Git service
2. Add `removeWorktree(path:)` cleanup
3. Each implementer gets a unique worktree path
4. Track worktree paths in `AgentWorkspace`

### Phase 2: Parallel Execution
```swift
// In runChain()
if chain.enableParallelImplementers {
  // 1. Run planner first
  try await runSingleAgent(planner, at: 0)
  
  // 2. Parse planner output for branch name and tasks
  let plan = parsePlannerOutput(chain.results.last!.output)
  
  // 3. Create feature branch
  try await gitService.createBranch(plan.branchName)
  
  // 4. Create worktrees and run implementers in parallel
  await withTaskGroup(of: AgentResult.self) { group in
    for (index, implementer) in implementers.enumerated() {
      let worktreePath = "\(tempDir)/worktree-\(index)"
      group.addTask {
        try await gitService.createWorktree(at: worktreePath, branch: "impl-\(index)")
        return await runSingleAgent(implementer, workingDirectory: worktreePath)
      }
    }
    // Collect results
  }
  
  // 5. Run merger
  try await runSingleAgent(merger, at: mergerIndex)
  
  // 6. Cleanup worktrees
  for path in worktreePaths {
    try await gitService.removeWorktree(at: path)
  }
}
```

### Phase 3: Feedback Loops
```swift
enum MergeVerdict {
  case merged(commitHash: String)
  case conflicts(feedback: [ImplementerFeedback])
  case needsReview(issues: [String])
}

struct ImplementerFeedback {
  let implementerIndex: Int
  let issue: String
  let suggestedFix: String
}

// If merger returns conflicts, re-run specific implementers
if case .conflicts(let feedback) = mergeVerdict {
  for item in feedback {
    let implementer = chain.agents[item.implementerIndex]
    // Re-run with feedback context
    try await runSingleAgent(implementer, feedback: item)
  }
  // Re-run merger
  try await runSingleAgent(merger)
}
```

## Chain Templates

### Parallel Feature (New Template)
```swift
ChainTemplate(
  name: "Parallel Feature",
  description: "Split work across multiple implementers with automatic merge",
  steps: [
    AgentStepTemplate(role: .planner, model: .claudeOpus45, name: "Task Splitter"),
    AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer 1"),
    AgentStepTemplate(role: .implementer, model: .claudeSonnet45, name: "Implementer 2"),
    AgentStepTemplate(role: .merger, model: .claudeSonnet45, name: "Merger"),
    AgentStepTemplate(role: .reviewer, model: .gpt41, name: "Final Review")
  ],
  isBuiltIn: true,
  enableParallel: true  // New flag
)
```

## UI Changes

### Chain Detail View
- Show parallel indicator for multi-implementer chains
- Display worktree status for each implementer
- Show merge progress/conflicts
- Visualize the branch graph

### Results View
- Group parallel implementer results together
- Show merge result with diff summary
- Display any feedback loops that occurred

## Challenges & Solutions

### Challenge 1: Task Splitting
**Problem:** How does planner know how to split tasks?

**Solution:** Add explicit instructions in planner prompt:
```
When given a complex task, split it into independent sub-tasks that can 
be worked on in parallel. Each sub-task should:
- Work on different files when possible
- Have clear boundaries
- Not depend on other sub-tasks' outputs
```

### Challenge 2: Conflict Resolution
**Problem:** What if implementers change the same file?

**Solutions:**
1. **Prevention:** Planner assigns disjoint file sets
2. **Detection:** Merger identifies overlapping changes
3. **Resolution:** 
   - Auto-merge if changes are in different functions
   - Request clarification if changes conflict semantically
   - Allow manual resolution as fallback

### Challenge 3: Worktree Management
**Problem:** Worktrees need cleanup even if chain fails

**Solution:** Use `defer` and track all created worktrees:
```swift
var createdWorktrees: [String] = []
defer {
  for path in createdWorktrees {
    try? await gitService.removeWorktree(at: path)
  }
}
```

### Challenge 4: Premium Cost
**Problem:** Parallel execution uses more premium requests

**Solution:** 
- Show estimated cost before running
- Allow mixing premium/free models
- Track per-implementer costs

## Timeline

1. **Phase 1 (Week 1):** Worktree support in Git service
2. **Phase 2 (Week 2):** Parallel execution with TaskGroup
3. **Phase 3 (Week 3):** Merger agent and feedback loops
4. **Phase 4 (Week 4):** UI polish and templates

## Notes

- The existing WORKTREE_FEATURE_PLAN.md covers the UI for worktree browsing
- This plan is about using worktrees for **agent isolation**
- Could potentially integrate with the worktree browser UI later
