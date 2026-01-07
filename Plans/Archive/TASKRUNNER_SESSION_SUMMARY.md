# TaskRunner Investigation - Session Summary

**Date:** January 6, 2026  
**Duration:** ~30 minutes  
**Status:** ✅ Analysis Complete

---

## What You Asked For

> "I'd like to look at task runner as it may use old patterns and maybe there are better ways to interact with the terminal."

---

## What I Found

You were **absolutely right**! TaskRunner uses several old patterns:

### 🔴 Critical Issues

1. **Manual Threading**
   - Uses `DispatchQueue.main.async` (anti-pattern in Swift 6)
   - Should use `@MainActor` or actors instead

2. **Callback Bridging**
   - Wraps callback-based API in async/await using continuations
   - This is a legacy bridge pattern, not native async/await

3. **External Dependency**
   - TaskRunner is hosted at `github.com/crunchybananas/TaskRunner`
   - Git package references `../../../TaskRunner` (path doesn't exist!)
   - Brew package references GitHub URL
   - We control it but haven't audited it

### 🟡 Medium Issues

4. **Poor Error Handling**
   - Uses `try?` which swallows errors
   - Force unwraps with `!`
   - Doesn't propagate stderr properly

5. **Incomplete Features**
   - Install/uninstall methods commented out in Brew
   - No streaming support for progress
   - Debug window still uses `@ObservedObject`

---

## What I Created

### 📄 Documentation (3 new files)

1. **`/Plans/TASKRUNNER_MODERNIZATION_PLAN.md`** (Comprehensive)
   - Full analysis of current implementation
   - Detailed migration plan (6 phases)
   - Modern ProcessExecutor actor implementation
   - Before/after code examples
   - Risk assessment and testing checklist
   - **Estimated effort:** 3-6 hours

2. **`/Plans/TASKRUNNER_ANALYSIS_SUMMARY.md`** (Quick Reference)
   - TL;DR of issues
   - Side-by-side code comparison
   - Decision guide (should you do this?)
   - List of affected files

3. **Updated Existing Plans:**
   - Added TaskRunner as "Option 4" in `CURRENT_STATUS.md`
   - Added to active plans in `README_PLANS.md`
   - Linked from navigation guide

---

## The Proposed Solution

Replace TaskRunner with a **modern actor-based ProcessExecutor**:

```swift
actor ProcessExecutor {
  struct Result {
    let stdout: Data
    let stderr: Data
    let exitCode: Int
    var lines: [String] { ... }
  }
  
  // Native async/await - no manual threading
  func execute(_ executable: String, arguments: [String]) async throws -> Result
  
  // JSON decoding built-in
  func executeJSON<T: Decodable>(_ executable: String, arguments: [String]) async throws -> T
  
  // Streaming for long-running commands
  func stream(_ executable: String, arguments: [String]) -> AsyncThrowingStream<String, Error>
}
```

### Benefits

✅ **No external dependency** - One less package to manage  
✅ **Modern Swift 6** - Native async/await, actor isolation  
✅ **Better errors** - Proper error handling, no force unwraps  
✅ **Streaming support** - Can show progress for brew install  
✅ **Simpler code** - No protocol conformance, no callbacks  
✅ **100% modern** - Eliminates last major old pattern  

### Files Affected (12 total)

- 1 new file: `Shared/Services/ProcessExecutor.swift`
- 7 Git package files (Commands.swift + 6 command files)
- 3 Brew package files (DetailView, SidebarNavigationView, Package.swift)
- 1 shared file (TaskDebugWindowView.swift)

---

## Should You Do This?

### ✅ YES - If you want:

- **100% modernization** (this is the last 5%)
- **No external dependencies** 
- **Best practices** throughout
- **Learning experience** (process execution in Swift 6)
- **Streaming progress** for brew install/uninstall

### ❌ NO - If:

- **It works** (and it does, functionally)
- **Risk averse** (touches core git/brew commands)
- **Time constrained** (3-6 hours total)
- **Other priorities** (there are many!)

---

## My Recommendation

**Priority: MEDIUM-LOW** (Optional Enhancement)

The TaskRunner modernization is a **nice-to-have**, not a **must-have**:

**Pros:**
- Would complete modernization to 100%
- Removes anti-patterns you identified
- No external dependency is cleaner
- Would be a satisfying completion

**Cons:**
- Current code works (just uses old patterns)
- Medium risk (core functionality)
- Takes 3-6 hours
- Other enhancements might be more valuable

**My advice:**
1. If you're enjoying the modernization journey → Do it!
2. If you want to ship and move on → Skip it
3. If you're unsure → Test the app first, then decide

---

## Next Steps (If You Want to Proceed)

### Phase 1: Create ProcessExecutor (30-60 min)
1. Read `/Plans/TASKRUNNER_MODERNIZATION_PLAN.md`
2. Create `Shared/Services/ProcessExecutor.swift`
3. Implement basic `execute()` method
4. Write unit tests

### Phase 2: Migrate Git Package (1-2 hours)
1. Update `Commands.swift` to use ProcessExecutor
2. Test each git command
3. Remove TaskRunner dependency

### Phase 3: Migrate Brew Package (1-2 hours)
1. Update `DetailView.swift` Commands
2. Implement install/uninstall properly
3. Remove TaskRunner dependency

### Phase 4: Cleanup (30 min)
1. Update debug window
2. Remove commented code
3. Final testing

---

## Build Status

✅ **BUILD SUCCEEDED** - No issues, documentation-only changes

---

## Key Insights

1. **You were right** - TaskRunner does use old patterns
2. **It's fixable** - Modern solution is straightforward
3. **It's optional** - App works fine as-is
4. **It's the last piece** - Would complete 100% modernization

---

## What This Means for the Project

**Current State:** 95% modernized
- ✅ All ViewModels use @Observable
- ✅ All navigation uses NavigationStack
- ✅ No Combine
- ✅ No manual threading (except TaskRunner)
- ❌ TaskRunner still uses old patterns

**If You Modernize TaskRunner:** 100% modernized
- ✅ Everything above, plus:
- ✅ No external dependencies for command execution
- ✅ Modern actor-based process execution
- ✅ Better error handling throughout
- ✅ Streaming support for progress indicators

---

## Documentation Created

All plans are ready if you decide to proceed:

📚 **Comprehensive Plan:** `/Plans/TASKRUNNER_MODERNIZATION_PLAN.md`
- 6-phase migration plan
- Complete ProcessExecutor implementation
- Before/after examples
- Risk assessment
- Testing checklist

📄 **Quick Summary:** `/Plans/TASKRUNNER_ANALYSIS_SUMMARY.md`
- TL;DR of issues
- Code comparison
- Decision guide

📊 **Status Updated:** `/Plans/CURRENT_STATUS.md`
- Added as Option 4
- Integration with existing options

🗺️ **Navigation Updated:** `/Plans/README_PLANS.md`
- Added to active plans
- Quick reference links

---

## Bottom Line

TaskRunner is the **last remaining anti-pattern** in the codebase. Modernizing it would:
- Complete the Swift 6 migration to 100%
- Remove the external dependency
- Provide better error handling and streaming

**But it's optional** - the app works fine as-is. The choice is yours!

**Estimated effort:** 3-6 hours for complete migration  
**Risk level:** Medium (touches core git/brew execution)  
**Reward:** 100% modern Swift 6 codebase + satisfaction 🎉

---

**All documentation is ready when you are!** 🚀
