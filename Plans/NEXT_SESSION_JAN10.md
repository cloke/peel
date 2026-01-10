# Next Session Plan - January 10, 2026

## Priority: UX Polish for Agent Chains

### Context
The agent orchestration system is functional but has UX quirks:
- Streaming infrastructure added but not fully working
- Completion state not always obvious
- Some UI responsiveness issues observed

---

## Top Priority: Debug & Fix Streaming

### Issue
Streaming output from copilot CLI isn't appearing in the Live Status panel.

### Investigation Steps
1. Verify `--stream on` flag is being passed correctly
2. Check if copilot outputs to stdout or stderr during streaming
3. Add debug logging to see what data is coming through
4. Test with `gh copilot -p "simple prompt" --stream on` in terminal first

### Files to Check
- `Shared/Services/CLIService.swift` - `executeWithStreaming()` function
- `Shared/Applications/Agents_RootView.swift` - `parseStreamingLine()` function

### Architecture Reference
```
User runs chain
  → runChain() in Agents_RootView
    → runSingleAgent() calls CLIService.runCopilotSession(streaming: true)
      → executeWithStreaming() reads FileHandle.bytes.lines
        → onOutput callback fires for each line
          → parseStreamingLine() filters/formats
            → liveStatusMessages.append() updates UI
              → LiveStatusPanel shows messages
```

---

## Quick Wins

### 1. Clear Button for Prompt
Add a button to clear the prompt field after completion:
```swift
// In ChainDetailView, near the prompt TextField
if !chain.prompt.isEmpty {
  Button("Clear") { chain.prompt = "" }
}
```

### 2. Scrollable Live Status
Make the Live Status panel scroll to show all output:
```swift
ScrollView {
  ForEach(liveStatusMessages) { message in
    // ...
  }
}
.frame(maxHeight: 200)
```

### 3. Live Elapsed Timer
Update elapsed time every second while running:
```swift
// Add a timer that updates elapsedTime while isRunning
.onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
  if isRunning, let start = chainStartTime {
    elapsedTime = Date().timeIntervalSince(start)
  }
}
```

---

## Bugs to Investigate

### 1. Beach Ball at Startup
- Observed when starting a chain run
- Was fixed with `Task.detached` but may still occur
- Check if any `await` is blocking main actor

### 2. Streaming Parse Too Aggressive
- `parseStreamingLine()` might filter out useful content
- Consider showing more raw output, less filtering

### 3. Completion Not Obvious
- Green banner added but needs testing
- Sound (NSSound.beep) may not work in all contexts
- Consider more prominent visual change

---

## Testing Checklist

- [ ] Run "Free Review" template with simple prompt
- [ ] Verify streaming output appears in Live Status
- [ ] Confirm completion banner appears
- [ ] Test "New Task" button clears prompt
- [ ] Check session tracker updates correctly
- [ ] Run "Code Review" template (with premium models)
- [ ] Test review loop with a prompt that needs iteration

---

## Future Features (Reference)

From PARALLEL_AGENTS_PLAN.md:
- Phase 1: Worktree support for parallel work
- Phase 2: Parallel implementer execution with TaskGroup
- Phase 3: Merger agent role
- Phase 4: Dynamic model selection by planner

---

## Files Modified Recently

### January 9, 2026
- `CLIService.swift` - Added `executeWithStreaming()` with AsyncSequence
- `Agents_RootView.swift` - Added Live Status panel, streaming callbacks
- `AgentChain.swift` - Added review loop, verdict parsing
- `ChainTemplate.swift` - Cost display improvements

---

## Session Goals

1. ✅ Get streaming output visibly working - readabilityHandler + StreamAccumulator actor
2. ✅ Make completion state unmistakably clear - "New Task" resets chain  
3. ✅ Fix any blocking/beach ball issues - Actor-based streaming on background queues
4. ✅ Test all built-in templates work correctly - Agent chain successfully made UX changes

## Changes Made

### CLIService.swift
- Replaced AsyncSequence streaming with `readabilityHandler` for immediate output
- Added `StreamAccumulator` actor for thread-safe data collection
- Fixed actor isolation with separate `processStdoutBuffer()`/`processStderrBuffer()`

### Agents_RootView.swift  
- Added Clear button for prompt field
- Increased Live Status panel height (120 → 200)
- Improved `parseStreamingLine()` to filter stats lines
- "New Task" button now resets chain state and clears errors

### Agent Chain Test
- Successfully ran chain to make UX improvements
- Brew: Fixed PATH lookup for `brew` executable  
- GitHub: Added loading spinner during data fetch

---

## Next: Parallel Agents

See **NEXT_SESSION_JAN11.md** for the parallel implementers plan:
- Planner splits task into independent sub-tasks
- Multiple implementers run in parallel (each in a git worktree)
- Merger agent combines changes and handles conflicts
- Feedback loop if merger finds issues

Good luck! 🚀
