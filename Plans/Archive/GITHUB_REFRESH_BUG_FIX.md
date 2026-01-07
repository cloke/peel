# GitHub Repository Switching Bug Fix ✅

**Date**: January 6, 2026  
**Issue**: When switching between repositories in the GitHub view, the PR list (and other tabs) showed stale data from the previous repository  
**Status**: ✅ Fixed

## Problem

When navigating between different repositories in the GitHub sidebar, the views in the TabView (Pull Requests, Commits, Issues, Actions) were not refreshing. The user would see data from the previously selected repository until manually switching tabs to force a refresh.

### Root Cause

All four tab views were using either:
- `.onAppear { }` - Only executes when view first appears, not on subsequent appearances
- `.task { }` - Without an `id` parameter, only executes once when view is created

When SwiftUI reuses the same view instance with a different `repository` parameter, these modifiers don't re-execute, causing stale data to be displayed.

## Solution

Replace all data-loading task modifiers with `.task(id: repository.id)`:

```swift
// ❌ BEFORE - Only loads once
.onAppear {
  Task {
    pullRequests = try await Github.pullRequests(from: repository)
  }
}

// or

.task {
  commits = try await Github.commits(from: repository)
}

// ✅ AFTER - Reloads when repository changes
.task(id: repository.id) {
  state = .loading
  pullRequests = try await Github.pullRequests(from: repository)
  state = pullRequests.count == 0 ? .empty : .loaded
}
```

The `.task(id:)` modifier automatically cancels the previous task and starts a new one whenever the `id` value changes. In this case, when `repository.id` changes (i.e., user selects a different repository), the view automatically refreshes its data.

## Files Modified

### 1. PullRequestsView.swift
**File**: `Local Packages/Github/Sources/Github/Views/PullRequests/PullRequestsView.swift`

**Changes**:
- ✅ Replaced `.onAppear` with `.task(id: repository.id)`
- ✅ Added `state = .loading` at start of task to show loading indicator
- ✅ Properly handles loading states during repository switches

### 2. CommitsListView.swift
**File**: `Local Packages/Github/Sources/Github/Views/Commits/CommitsListView.swift`

**Changes**:
- ✅ Changed `.task { }` to `.task(id: repository.id) { }`
- ✅ Now refreshes commit list when repository changes

### 3. IssuesListView.swift
**File**: `Local Packages/Github/Sources/Github/Views/Issues/IssuesListView.swift`

**Changes**:
- ✅ Changed `.task { }` to `.task(id: repository.id) { }`
- ✅ Now refreshes issues list when repository changes

### 4. ActionsView.swift
**File**: `Local Packages/Github/Sources/Github/Views/Actions/ActionsListView.swift`

**Changes**:
- ✅ Changed `.task { }` to `.task(id: repository.id) { }`
- ✅ Now refreshes actions/workflows when repository changes

## Benefits

1. **Automatic Refresh**: Data automatically refreshes when switching repositories
2. **Loading Indicator**: Shows loading state during refresh (for PullRequestsView)
3. **Task Cancellation**: Previous task is automatically cancelled when switching repositories
4. **Better UX**: No need to manually switch tabs to force a refresh
5. **Modern SwiftUI**: Uses `.task(id:)` which is the recommended pattern for async data loading

## Technical Details

### .task(id:) Modifier Behavior

```swift
.task(id: someValue) {
  // This block:
  // 1. Executes when view appears
  // 2. Re-executes when 'someValue' changes
  // 3. Automatically cancels previous task before re-executing
  // 4. Properly handles task cancellation with Task.isCancelled
}
```

### Why This Works

When the user selects a different repository:
1. The `repository` parameter changes to a new Repository object
2. The new repository has a different `id` (UUID)
3. SwiftUI detects the `id` change in `.task(id: repository.id)`
4. SwiftUI cancels the previous task
5. SwiftUI executes the new task with fresh data
6. UI updates with the correct repository's data

## Testing Recommendations

- ✅ Switch between multiple repositories in GitHub view
- ✅ Verify Pull Requests tab shows correct data immediately
- ✅ Verify Commits tab refreshes on repository switch
- ✅ Verify Issues tab refreshes on repository switch
- ✅ Verify Actions tab refreshes on repository switch
- ✅ Test rapid switching between repositories (task cancellation)

## Build Status

✅ **Build Successful** - All changes compile without errors

## Related Patterns

This same pattern should be applied to any view that loads data based on a parameter:

```swift
struct MyDataView: View {
  let item: Item
  @State private var data: Data?
  
  var body: some View {
    // ✅ CORRECT - Refreshes when item changes
    ContentView(data: data)
      .task(id: item.id) {
        data = try? await loadData(for: item)
      }
  }
}
```

## Future Considerations

If modernizing to @Observable:
- This pattern still applies
- `.task(id:)` works seamlessly with @Observable objects
- Consider using `@Observable` for loading states instead of separate @State variables

---

**Fix Complete**: Repository switching now works correctly in all GitHub view tabs! 🎉
