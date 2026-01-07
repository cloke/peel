# Git Environment Crash Fix

**Date:** January 6, 2026  
**Issue:** Crash when navigating to branch history view

## Problem

The app was crashing with the following error:
```
Load branches in tio-workspace
load type: remote, count 4
SwiftUICore/Environment+Objects.swift:34: Fatal error: No Observable object of type Repository found. 
A View.environmentObject(_:) for Repository may be missing as an ancestor of this view.
```

## Root Cause

The crash occurred when clicking on a branch in the branch list to view its history. Two issues were identified:

1. **NavigationView in destination view**: `HistoryListView` was using a `NavigationView` wrapper inside its body, even though it was already being displayed as a navigation destination within a `NavigationStack` from `GitRootView`. This created a new navigation context that didn't inherit the environment from the parent.

2. **Incorrect navigationDestination placement**: The `.navigationDestination(for: String.self)` modifier was placed inside the `ForEach` loop in `BranchListView`, causing it to be registered multiple times (once for each branch item).

## Solution

### 1. Removed NavigationView from HistoryListView

**File:** `Local Packages/Git/Sources/Git/HistoryListView.swift`

**Before:**
```swift
var body: some View {
  NavigationView {
    List(commits, selection: $selection) { ... }
    .listStyle(.sidebar)
    .task { ... }
    .onChange(of: selection) { ... }
    Text("Select a commit")
  }
}
```

**After:**
```swift
var body: some View {
  List(commits, selection: $selection) { ... }
  .listStyle(.sidebar)
  .navigationTitle("History: \(branch)")
  .task { ... }
  .onChange(of: selection) { ... }
}
```

**Changes:**
- Removed `NavigationView` wrapper
- Removed placeholder text "Select a commit" 
- Added `.navigationTitle("History: \(branch)")` for proper title display
- Updated preview to include `.environment(Model.Repository(...))`

### 2. Moved navigationDestination outside ForEach

**File:** `Local Packages/Git/Sources/Git/BranchListView.swift`

**Before:**
```swift
Section("test", isExpanded: $isExpanded) {
  ForEach(localBranches.indices, id: \.self) { index in
    NavigationLink(value: localBranches[index].name) { ... }
    .navigationDestination(for: String.self) { branchName in
      HistoryListView(branch: branchName)
    }
    .font(.footnote)
    // ... other modifiers
  }
}
```

**After:**
```swift
Section("test", isExpanded: $isExpanded) {
  ForEach(localBranches.indices, id: \.self) { index in
    NavigationLink(value: localBranches[index].name) { ... }
    .font(.footnote)
    // ... other modifiers
  }
  .navigationDestination(for: String.self) { branchName in
    HistoryListView(branch: branchName)
  }
}
```

**Changes:**
- Moved `.navigationDestination` from inside `ForEach` to after `ForEach`
- This ensures the destination is registered only once, not once per branch
- Updated preview to include `.environment(Model.Repository(...))`

## Why This Works

The environment system in SwiftUI propagates values down the view hierarchy. The flow is:

1. `GitRootView` creates a `NavigationStack` and sets `.environment(repository)`
2. `BranchListView` receives the repository via `@Environment(Model.Repository.self)`
3. When navigating via `NavigationLink`, the environment is passed to the destination
4. `HistoryListView` now correctly receives the repository from the parent's environment

By removing the nested `NavigationView` from `HistoryListView`, the view no longer creates a new navigation context, allowing the environment to propagate correctly.

## Files Modified

1. `/Users/cloken/code/KitchenSink/Local Packages/Git/Sources/Git/HistoryListView.swift`
   - Removed `NavigationView` wrapper
   - Added `.navigationTitle()`
   - Updated preview

2. `/Users/cloken/code/KitchenSink/Local Packages/Git/Sources/Git/BranchListView.swift`
   - Moved `.navigationDestination` outside `ForEach`
   - Updated preview

## Testing

Build verified successful:
```bash
cd "Local Packages/Git" && swift build
# Build complete! (6.37s)
```

## Related Patterns

This fix aligns with the Swift 6 and SwiftUI 6 modernization guidelines:

✅ Using `@Observable` instead of `ObservableObject` (already done for `Model.Repository`)  
✅ Using `@Environment(Type.self)` instead of `@EnvironmentObject`  
✅ Using `NavigationStack` instead of `NavigationView` (in `GitRootView`)  
✅ Avoiding nested `NavigationView` components  
✅ Proper placement of navigation modifiers  

## Notes

- The `Model.Repository` class was already modernized to use `@Observable` 
- All views were already using `@Environment(Model.Repository.self)` correctly
- The issue was purely about the view hierarchy and navigation structure
- Similar patterns should be applied to any other views that wrap themselves in `NavigationView` when used as navigation destinations

## Update: Crash Still Occurring

**Status:** Crash persists after initial fixes. Added comprehensive logging to trace the exact failure point.

### Additional Investigation

Despite fixing the NavigationView nesting and navigationDestination placement, the crash still occurs. This suggests a deeper issue, possibly:

1. **Build cache issue** - Xcode may be using stale compiled code
2. **Environment propagation issue** - The environment may not be propagating correctly through the view hierarchy
3. **Timing issue** - The crash may occur during view updates when branches are loaded

### Actions Taken

1. **Cleaned Xcode build** - Ran `xcodebuild clean` and removed DerivedData
2. **Added comprehensive logging** to trace execution flow:
   - 🔴 Repository.loadBranches - tracks branch loading
   - 🟣 GitRootView - tracks initialization and rendering
   - 🟡 BranchListView - tracks list rendering
   - 🟢 HistoryListView - tracks history view rendering
   - 🔵 BranchListItemView - tracks individual branch item rendering

3. **Verified code patterns**:
   - ✅ No `@EnvironmentObject` usage found in Git package
   - ✅ No `ObservableObject` conformance in Git package (all use `@Observable`)
   - ✅ All environment access uses `@Environment(Model.Repository.self)`

### Logging Output to Review

When running the app, look for this sequence in the console:

```
🟣 GitRootView init - Switched to repository: [name]
🟣 GitRootView rendering body for repo: [name]
🟣 GitRootView - Starting repository.load()
🔴 Load branches in [name]
🔴 load type: local, count [N]
🔴 Setting localBranches
🔴 Done setting localBranches
🔴 load type: remote, count [N]
🔴 Setting remoteBranches
🔴 Done setting remoteBranches
🟣 GitRootView - Finished repository.load()
🟡 BranchListView rendering: [label], repo: [name], branches: [count]
🔵 BranchListItemView rendering for branch: [name], repo: [name]
```

If clicking on a branch, should see:
```
🟢 HistoryListView rendering for branch: [name], repo: [name]
```

### Next Steps

1. **Run the app** and reproduce the crash
2. **Review console logs** to see where execution stops
3. **Check crash log** to see exact line number and stack trace
4. **Possible fixes** based on findings:
   - If crash is in BranchListView rendering: Issue with how branches array is mutated
   - If crash is in HistoryListView: Environment not propagating through navigationDestination
   - If crash is before any logging: Issue in view initialization

### Files Modified for Logging

1. `Local Packages/Git/Sources/Git/Models/Repository.swift` - Added detailed logging in loadBranches
2. `Local Packages/Git/Sources/Git/Git.swift` - Added logging in init and body
3. `Local Packages/Git/Sources/Git/BranchListView.swift` - Added logging in body for BranchListView and BranchListItemView
4. `Local Packages/Git/Sources/Git/HistoryListView.swift` - Added logging in body

### Temporary Logging Code

All logging uses emoji prefixes for easy filtering:
- 🔴 = Repository operations
- 🟣 = GitRootView
- 🟡 = BranchListView
- 🟢 = HistoryListView
- 🔵 = BranchListItemView

These can be removed once the issue is resolved.
