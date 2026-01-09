# Agent Orchestration - Next Steps (Jan 9, 2026)

## Session Summary

### Completed Features ✅
- Agent Roles (Planner/Implementer/Reviewer) with system prompts
- Framework Hints (Swift, Ember, React, Python, Rust)
- Chain Templates (Code Review, Quick Fix, Free Review, Deep Analysis, Multi-Implementer)
- Working Directory required + persisted
- Sidebar selection fixed
- Live status indicator while running
- Context passing between agents verified working

### Current Limitations
- Agents run **sequentially** (not in parallel yet)
- No review loop (agents can't iterate back and forth)
- No real-time tool status (simulated based on time)

---

## Test Prompt for Next Session

### Goal: Test Multi-Agent Chain with Review

**Template to use:** Create a custom chain OR modify "Code Review" template

**Recommended Chain:**
1. **Planner** (Claude Sonnet 4.5) - Analyzes and creates plan
2. **Implementer** (Claude Sonnet 4.5) - Makes changes
3. **Reviewer** (GPT-4.1 Free) - Reviews the changes

**Test Prompt:**
```
Look at the Agents_RootView.swift file. Find one small improvement 
that could be made to the UI or UX. The improvement should be:
- A single file change
- Under 20 lines of code
- Visible in the UI
- Something a user would notice

Planner: Identify the improvement and specify exactly what to change.
Implementer: Make the change.
Reviewer: Verify the change is correct and matches the plan.
```

**What to look for:**
1. Does the Planner identify something reasonable?
2. Does the Implementer make the exact change the Planner specified?
3. Does the Reviewer actually verify (not just say "looks good")?
4. Is there a git diff after the chain completes?

---

## Parallel Agent Design (Future)

Currently agents run sequentially. For true parallel execution:

```swift
// Current (sequential)
for agent in chain.agents {
  let result = await runAgent(agent)
  results.append(result)
}

// Future (parallel implementers)
// 1. Run planner first
let plan = await runAgent(planner)

// 2. Split plan into tasks
let tasks = parsePlanIntoTasks(plan)

// 3. Run implementers in parallel
await withTaskGroup(of: AgentResult.self) { group in
  for (task, implementer) in zip(tasks, implementers) {
    group.addTask {
      await runAgent(implementer, task: task)
    }
  }
  for await result in group {
    results.append(result)
  }
}

// 4. Run reviewer on all results
let review = await runAgent(reviewer, context: results)
```

**Challenges:**
- How does planner specify which tasks go to which implementer?
- How do we merge changes from parallel implementers?
- What if implementers make conflicting changes?

---

## Ideas for Next Session

### 1. Session Cost Tracking
Track total premium requests used across a session:
```swift
@Observable class SessionTracker {
  var totalPremiumUsed: Int = 0
  var requestHistory: [RequestRecord] = []
}
```

### 2. Streaming Output
Show response as it generates instead of waiting:
- Parse copilot stderr in real-time
- Show actual tool invocations (not simulated)

### 3. Review Loop
Allow reviewer to send changes back to implementer:
```swift
enum ReviewResult {
  case approved
  case needsChanges(feedback: String)
}

// If needs changes, re-run implementer with feedback
while reviewResult == .needsChanges {
  let fix = await runImplementer(feedback)
  reviewResult = await runReviewer(fix)
}
```

### 4. Save Chain Results
Persist chain results to disk for later review:
- Export as markdown
- Save to SwiftData
- Show history of past runs

---

## After Running Test Prompt

1. **Check git diff:** `git diff HEAD`
2. **Review the changes:** Are they what the planner specified?
3. **Build the app:** Does it compile?
4. **Run the app:** Does the UI change work?
5. **Report back:** Share the Planner output, Implementer output, and Reviewer output

---

## Quick Reference

**Build command:**
```bash
cd /Users/cloken/code/KitchenSink
xcodebuild -scheme "KitchenSink (macOS)" -destination 'platform=macOS' build
```

**Check diff:**
```bash
git diff HEAD
git diff --stat HEAD
```

**Revert if needed:**
```bash
git checkout HEAD -- path/to/file
```
