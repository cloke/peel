# Next Session Plan - January 11, 2026

## Priority: Parallel Agent Implementation

### Context
Streaming output is working. Now focus on the killer feature: **parallel implementers with worktrees and merge loop**.

---

## The Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                         USER PROMPT                                  │
│        "Make these 5 UX improvements to the Brew view"              │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    PLANNER (Opus - 3×)                              │
│  - Analyzes the 5 UX changes                                        │
│  - Splits into independent tasks                                    │
│  - Creates feature branch: feature/brew-ux-improvements             │
│  - Assigns model per task (trivial → GPT 4.1, complex → Sonnet)     │
│  - Outputs structured JSON task list                                │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
         ┌─────────────────────┼─────────────────────┐
         │                     │                     │
         ▼                     ▼                     ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  IMPLEMENTER 1  │  │  IMPLEMENTER 2  │  │  IMPLEMENTER 3  │  ... up to 5
│  (Worktree A)   │  │  (Worktree B)   │  │  (Worktree C)   │
│  GPT 4.1 (Free) │  │  Sonnet (1×)    │  │  GPT 4.1 (Free) │
│  "Add button"   │  │  "Refactor VM"  │  │  "Fix colors"   │
└────────┬────────┘  └────────┬────────┘  └────────┬────────┘
         │                    │                     │
         │      ALL RUN IN PARALLEL (TaskGroup)     │
         │                    │                     │
         └────────────────────┼─────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    MERGER (Sonnet - 1×)                             │
│  - Collects all worktree changes                                    │
│  - Detects conflicts (git + semantic)                               │
│  - If clean: merge all into feature branch ✓                        │
│  - If conflict: identify which implementer needs to fix             │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
              ┌────────────────┴────────────────┐
              │                                 │
         [SUCCESS]                         [CONFLICT]
              │                                 │
              ▼                                 ▼
┌─────────────────────┐          ┌─────────────────────────────────┐
│  REVIEWER (GPT 4.1) │          │  RE-RUN SPECIFIC IMPLEMENTER    │
│  Final check        │          │  with merge feedback context     │
│  Approve/Reject     │          └────────────────┬────────────────┘
└─────────────────────┘                           │
                                                  ▼
                                    ┌─────────────────────────┐
                                    │  BACK TO MERGER         │
                                    │  (max 2 iterations)     │
                                    └─────────────────────────┘
```

---

## Implementation Tasks

### Phase 1: Git Worktree Support (Day 1)
**Goal:** Add worktree operations to Git package

```swift
// In Git package
public actor GitWorktreeService {
  /// Create a worktree at the given path for a branch
  func createWorktree(at path: String, branch: String, from baseBranch: String) async throws
  
  /// Remove a worktree and clean up
  func removeWorktree(at path: String) async throws
  
  /// List all worktrees
  func listWorktrees() async throws -> [Worktree]
  
  /// Get changes in a worktree (for merger to analyze)
  func getWorktreeChanges(at path: String) async throws -> [FileChange]
}
```

**Commands:**
```bash
git worktree add <path> -b <branch> <base>   # Create
git worktree remove <path>                    # Remove
git worktree list                             # List
git diff --name-status                        # Changes
```

### Phase 2: Merger Agent Role (Day 1)
**Goal:** Add merger role and prompts

```swift
public enum AgentRole: String, Codable, CaseIterable {
  case planner
  case implementer
  case reviewer
  case merger      // NEW
  
  var systemPrompt: String {
    switch self {
    case .merger:
      return """
        You are a MERGER agent responsible for combining parallel work.
        
        Your tasks:
        1. Analyze changes from multiple worktrees
        2. Detect conflicts (git conflicts + semantic conflicts)
        3. Merge clean changes into the target branch
        4. For conflicts, provide specific feedback to the implementer
        
        Output format for conflicts:
        ```json
        {
          "status": "conflict",
          "implementer": 2,
          "issue": "Changes to BrewViewModel conflict with Implementer 1's changes",
          "suggestion": "Use the refreshState property added by Implementer 1 instead of creating isRefreshing"
        }
        ```
        
        Output format for success:
        ```json
        {
          "status": "merged",
          "commitHash": "abc123",
          "summary": "Merged 5 implementer changes into feature/brew-ux"
        }
        ```
      """
    // ... existing cases
    }
  }
}
```

### Phase 3: Parallel Chain Execution (Day 2)
**Goal:** Run implementers in parallel with TaskGroup

```swift
// In ChainDetailView or AgentChainRunner
func runParallelChain() async throws {
  // 1. Run planner
  let planResult = try await runSingleAgent(planner)
  let plan = try parsePlannerOutput(planResult.output)
  
  // 2. Create feature branch
  try await gitService.createBranch(plan.branchName, from: "main")
  
  // 3. Create worktrees and run implementers in parallel
  var worktreePaths: [String] = []
  defer {
    // Cleanup worktrees even on failure
    for path in worktreePaths {
      try? await gitService.removeWorktree(at: path)
    }
  }
  
  let implementerResults = try await withThrowingTaskGroup(of: AgentResult.self) { group in
    for (index, task) in plan.tasks.enumerated() {
      let worktreePath = tempDirectory.appendingPathComponent("worktree-\(index)")
      worktreePaths.append(worktreePath.path)
      
      group.addTask {
        // Create worktree
        try await gitService.createWorktree(
          at: worktreePath.path,
          branch: "impl-\(index)",
          from: plan.branchName
        )
        
        // Run implementer with dynamic model
        let implementer = Agent(
          role: .implementer,
          model: task.recommendedModel,
          workingDirectory: worktreePath.path
        )
        return try await runSingleAgent(implementer, prompt: task.description)
      }
    }
    
    // Collect all results
    var results: [AgentResult] = []
    for try await result in group {
      results.append(result)
    }
    return results
  }
  
  // 4. Run merger
  let mergeResult = try await runMerger(
    worktrees: worktreePaths,
    targetBranch: plan.branchName
  )
  
  // 5. Handle merge result
  if case .conflict(let feedback) = mergeResult.verdict {
    // Re-run specific implementer with feedback
    try await handleMergeConflict(feedback, worktrees: worktreePaths)
  }
  
  // 6. Run reviewer on merged result
  try await runSingleAgent(reviewer)
}
```

### Phase 4: Merge Feedback Loop (Day 2)
**Goal:** Handle conflicts by re-running implementers

```swift
struct MergeVerdict: Codable {
  enum Status: String, Codable {
    case merged
    case conflict
  }
  
  let status: Status
  let commitHash: String?      // If merged
  let implementerIndex: Int?   // If conflict
  let issue: String?           // If conflict
  let suggestion: String?      // If conflict
}

func handleMergeConflict(_ feedback: MergeVerdict, worktrees: [String], iteration: Int = 0) async throws {
  guard iteration < 2 else {
    throw ChainError.mergeFailedAfterRetries
  }
  
  guard let implIndex = feedback.implementerIndex,
        let issue = feedback.issue else {
    throw ChainError.invalidMergeFeedback
  }
  
  // Re-run the specific implementer with feedback
  let worktreePath = worktrees[implIndex]
  let feedbackPrompt = """
    The merger found an issue with your changes:
    
    Issue: \(issue)
    Suggestion: \(feedback.suggestion ?? "Please fix the conflict")
    
    Please update your changes to resolve this.
    """
  
  try await runSingleAgent(
    implementer,
    prompt: feedbackPrompt,
    workingDirectory: worktreePath
  )
  
  // Re-run merger
  let newMergeResult = try await runMerger(worktrees: worktrees, targetBranch: targetBranch)
  
  if case .conflict(let newFeedback) = newMergeResult.verdict {
    try await handleMergeConflict(newFeedback, worktrees: worktrees, iteration: iteration + 1)
  }
}
```

---

## Data Models

### PlannerOutput
```swift
struct PlannerOutput: Codable {
  let branchName: String
  let tasks: [TaskAssignment]
}

struct TaskAssignment: Codable {
  let implementerIndex: Int
  let description: String
  let files: [String]          // Files this task will touch
  let complexity: Complexity
  let recommendedModel: CopilotModel
  
  enum Complexity: String, Codable {
    case trivial    // GPT 4.1 (free)
    case simple     // GPT 4.1 or Haiku
    case medium     // Sonnet
    case complex    // Sonnet or Opus
    case critical   // Opus
  }
}
```

### Chain Template
```swift
struct ChainTemplate {
  // ... existing properties
  var enableParallel: Bool = false
  var maxImplementers: Int = 5
}

// New built-in template
static let parallelFeature = ChainTemplate(
  name: "Parallel Feature",
  description: "Split work across multiple implementers with automatic merge",
  steps: [
    AgentStepTemplate(role: .planner, model: .claudeOpus45, name: "Task Splitter"),
    // Implementers created dynamically based on planner output
    AgentStepTemplate(role: .merger, model: .claudeSonnet45, name: "Merger"),
    AgentStepTemplate(role: .reviewer, model: .gpt41, name: "Final Review")
  ],
  isBuiltIn: true,
  enableParallel: true
)
```

---

## UI Updates

### Chain Detail View
```swift
// Show parallel mode indicator
if chain.enableParallel {
  Label("Parallel Mode", systemImage: "arrow.triangle.branch")
    .foregroundStyle(.blue)
}

// Show worktree status during execution
if case .running = chain.state {
  ForEach(activeWorktrees) { worktree in
    HStack {
      Text(worktree.implementerName)
      Spacer()
      if worktree.isComplete {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else {
        ProgressView().scaleEffect(0.6)
      }
    }
  }
}
```

### Cost Estimation
```swift
// Before running, show estimated cost
var estimatedCost: String {
  let plannerCost = 3.0  // Opus
  let implementerCosts = tasks.map { $0.recommendedModel.premiumCost }.reduce(0, +)
  let mergerCost = 1.0   // Sonnet
  let reviewerCost = 0.0 // GPT 4.1 (free)
  
  let total = plannerCost + implementerCosts + mergerCost + reviewerCost
  return String(format: "%.0f× Premium", total)
}
```

---

## Testing Checklist

- [ ] Create worktree via Git service
- [ ] Run 2 implementers in parallel
- [ ] Merger successfully combines non-conflicting changes
- [ ] Merger detects and reports conflicts
- [ ] Re-run implementer with merge feedback
- [ ] Full chain: Planner → 3 Parallel Implementers → Merger → Reviewer
- [ ] Worktrees cleaned up on success
- [ ] Worktrees cleaned up on failure
- [ ] Cost estimation accurate

---

## Files to Create/Modify

### New Files
- `Local Packages/Git/Sources/Git/WorktreeService.swift`
- `Shared/AgentOrchestration/Models/PlannerOutput.swift`
- `Shared/AgentOrchestration/Models/MergeVerdict.swift`

### Modified Files
- `Shared/AgentOrchestration/Models/AgentRole.swift` - Add `.merger`
- `Shared/AgentOrchestration/Models/ChainTemplate.swift` - Add parallel flag
- `Shared/Applications/Agents_RootView.swift` - Parallel execution + UI
- `Shared/AgentOrchestration/CLIService.swift` - Support dynamic model per agent

---

## Session Goals

1. 🔲 Implement GitWorktreeService in Git package
2. 🔲 Add Merger agent role with prompts
3. 🔲 Create PlannerOutput and MergeVerdict models
4. 🔲 Implement parallel chain execution with TaskGroup
5. 🔲 Add merge feedback loop
6. 🔲 Create "Parallel Feature" chain template
7. 🔲 Test with simple 2-implementer chain

Let's build this! 🚀
