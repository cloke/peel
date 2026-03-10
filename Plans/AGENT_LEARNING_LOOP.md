---
title: Agent Learning Loop & Execution Guardrails
status: active
tags:
  - agent-orchestration
  - learning
  - quality
updated: 2026-03-10
---

# Agent Learning Loop & Execution Guardrails

## Problem Statement

Three related problems with the current agent chain system:

### 1. Plan and Quit
Agents (especially planners) return `shouldSkipWork = true` or write plan files instead of implementing. The planner gate at `AgentChainRunner:382` sees `tasks=[]` + `noWorkReason` and marks the chain complete — no implementers ever run. Last night's commits created Plans/ docs instead of code.

### 2. No Institutional Memory
Each chain run is isolated. Agents don't learn from:
- Previous runs on the same repo
- Common mistakes (e.g., "always run build gate after changes")
- CI failures that were already solved
- Patterns that work well for a given codebase

`RepoGuidanceSkill` exists but is manually created. `CIFailureRecord` tracks failures but doesn't auto-generate reusable guidance.

### 3. Single-Agent Bottleneck on Big Ideas
"Implement PR dashboard" is too big for one agent. There's no mechanism to:
- Decompose a big idea into independently implementable pieces
- Have multiple agents work on sub-tasks
- Merge results with conflict resolution
- Validate the whole after all pieces land

## Design

### Part 1: Chain Learnings (Institutional Memory)

New SwiftData model: `ChainLearning` — auto-captured after every chain run.

```swift
@Model
final class ChainLearning {
  var id: UUID = UUID()
  var repoPath: String = ""
  var repoRemoteURL: String = ""
  var category: String = ""        // "mistake", "pattern", "tool-usage", "build-fix"
  var summary: String = ""         // One-line: "Always run `npm install` before build gate"
  var detail: String = ""          // Full context
  var source: String = "auto"      // "auto" (post-chain extraction) or "manual"
  var chainTemplateId: String = "" // Which template produced this
  var confidenceScore: Double = 0.5
  var appliedCount: Int = 0
  var wasHelpful: Int = 0          // User thumbs-up count
  var wasUnhelpful: Int = 0        // User thumbs-down count
  var isActive: Bool = true
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
}
```

**Auto-capture flow:**
1. After every chain completion (success or failure), extract learnings
2. Use the reviewer's output, build gate results, and error messages
3. Store as `ChainLearning` records scoped to the repo
4. Deduplicate by `summary` similarity before inserting

**Injection flow:**
1. When assembling a chain prompt (in `ParallelWorktreeRunner.buildPrePlannerContext`), query `ChainLearning` for the repo
2. Inject as `## Lessons Learned from Previous Runs` section
3. Mark `appliedCount += 1` so we can track frequency

### Part 2: Execution Guardrails (Anti-Plan-and-Quit)

Three mechanisms to prevent the "plan and quit" failure mode:

#### A. Planner Output Validation
In `AgentChainRunner`, after parsing `PlannerDecision`, validate that the planner actually produced work:
- If prompt explicitly asks for implementation and planner returns `shouldSkipWork`, **override the gate** and inject a corrective re-prompt
- Add a `requiresImplementation` flag to `AgentChain` (defaults to `true` for templates with implementer steps)

#### B. Implementation Verification Step
After implementers complete, before the chain finishes:
- Check if any files were actually modified (`git diff --stat` in the worktree)
- If no files changed and the chain was supposed to implement, mark as `failed` with reason "No files modified"
- This catches the case where an implementer writes a plan to a file instead of implementing

#### C. Completion Criteria in Templates
Add `completionCriteria` to `ChainTemplate`:
```swift
struct CompletionCriteria {
  var requiresFileChanges: Bool = true
  var requiredFilePatterns: [String] = []  // e.g., ["*.swift", "*.ts"]
  var forbiddenFilePatterns: [String] = [] // e.g., ["Plans/*.md"] for implementation chains
  var requiresBuildPass: Bool = false
}
```

### Part 3: Idea Decomposition (Big Ideas → Parallel Chains)

New template type: **"Idea"** — a meta-chain that:
1. **Analyzer** (premium model): Takes a high-level idea, produces a structured decomposition into 2-6 independent implementation tasks
2. **Dispatcher**: Creates one chain per task (using Full Implementation template), each in its own worktree
3. **Monitor**: Waits for all sub-chains to complete
4. **Integrator**: Merges all worktrees, resolves conflicts, runs full build
5. **Validator**: Final review of the integrated result

This builds on the existing `ParallelWorktreeRunner` but adds the decomposition and integration layers.

**Key difference from current parallel implementation:** The current parallel template runs 2-3 implementers on the *same task* split by the planner. The Idea template runs N chains on *different tasks* derived from one big idea.

## Implementation Order

### Phase 1: Learnings (this plan)
1. `ChainLearning` SwiftData model
2. Post-chain learning extraction in `AgentChainRunner.runChain()`
3. Learning injection in prompt assembly
4. MCP tools: `learnings.list`, `learnings.add`, `learnings.rate`

### Phase 2: Guardrails (this plan)
5. `requiresImplementation` flag on `AgentChain`
6. Planner output validation override
7. Post-implementation file change verification
8. `CompletionCriteria` on templates

### Phase 3: Idea Decomposition (future plan, builds on above)
9. Idea Analyzer chain template
10. Sub-chain dispatcher
11. Integration/merge step
12. End-to-end Idea template

## Files to Modify

| File | Change |
|------|--------|
| `Shared/Models/AgentModels.swift` | Add `ChainLearning` model |
| `Shared/Services/DataService.swift` | Add learning CRUD + query + injection block |
| `Shared/AgentOrchestration/AgentChainRunner.swift` | Post-chain learning extraction, planner gate override, file change verification |
| `Shared/AgentOrchestration/Models/AgentChain.swift` | Add `requiresImplementation` flag |
| `Shared/AgentOrchestration/Models/ChainTemplate.swift` | Add `CompletionCriteria` |
| `Shared/Services/ParallelWorktreeRunner.swift` | Inject learnings into pre-planner context |
| `Shared/AgentOrchestration/ToolHandlers/` | MCP tools for learnings |
