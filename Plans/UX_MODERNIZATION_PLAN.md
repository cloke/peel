# UX Modernization Plan

**Date:** January 7, 2026  
**Status:** 🔴 **NOT STARTED**  
**Priority:** High  
**Prerequisite:** Swift 6 modernization ✅ COMPLETE

---

## Executive Summary

The Swift 6 / SwiftUI 6 modernization is **complete**. The codebase now uses modern patterns (@Observable, NavigationStack, async/await). However, the **UI/UX still feels outdated** due to patterns from 2020-era SwiftUI development. This plan identifies specific UX issues and proposes fixes.

---

## 🚨 Critical UX Issues Identified

### 1. **Deprecated Preview Syntax** (15 files)
**Issue:** Using old `PreviewProvider` protocol instead of modern `#Preview` macro  
**Impact:** Slower previews, more verbose code  
**Files Affected:**
- `LocalChangesListView.swift`, `HistoryListView.swift`, `LogEntryRowView.swift`
- `BranchListView.swift`, `DiffView.swift`
- `SidebarNavigationView.swift`, `SearchBarView.swift`, `ResultDetailView.swift`, `DetailView.swift`
- `AvatarView.swift`, `CommitDetailView.swift`
- `Github_RootView.swift`, `Git_RootView.swift`, `Brew_RootView.swift`
- `SettingsView.swift`, `ContentView.swift`

**Modern Pattern:**
```swift
// ❌ Old (verbose)
struct MyView_Previews: PreviewProvider {
  static var previews: some View {
    MyView()
  }
}

// ✅ New (concise)
#Preview {
  MyView()
}
```

### 2. **Old Alert Syntax** (1 file)
**Issue:** Using deprecated `Alert(title:message:dismissButton:)` initializer  
**File:** `Git_RootView.swift:47`

**Modern Pattern:**
```swift
// ❌ Old
.alert(isPresented: $repoNotFoundError) {
  Alert(title: Text("Repository Not Found!"), ...)
}

// ✅ New
.alert("Repository Not Found!", isPresented: $repoNotFoundError) {
  Button("OK", role: .cancel) { }
} message: {
  Text("A git repository could not be found.")
}
```

### 3. **print() for Error Handling** (20+ locations)
**Issue:** Errors logged to console with `print()` instead of shown to user  
**Impact:** Users don't know when operations fail  
**Key Files:**
- `SidebarNavigationView.swift` - Brew install/search errors
- `DetailView.swift` - Brew info fetch errors
- `Network.swift` - GitHub API errors
- `PullRequestsListItemView.swift` - Avatar loading errors

**Modern Pattern:**
```swift
// ❌ Old - user never sees error
} catch {
  print("Failed to fetch: \(error)")
}

// ✅ New - proper error UI
@State private var errorMessage: String?

} catch {
  errorMessage = error.localizedDescription
}

.alert("Error", isPresented: .constant(errorMessage != nil)) {
  Button("OK") { errorMessage = nil }
} message: {
  Text(errorMessage ?? "")
}
```

### 4. **Missing Loading States** (Multiple views)
**Issue:** Some views show nothing during loading  
**Affected Areas:**
- GitHub Personal view - loads all PRs sequentially with no feedback
- Brew "Installed" button - no feedback while loading
- Organization expansion - only shows ProgressView briefly

### 5. **Inconsistent Navigation Patterns**
**Issue:** Mixed usage of NavigationSplitView vs NavigationStack  
**Pattern Mismatch:**
- `Github_RootView` uses `NavigationSplitView`
- `Git.swift` uses `NavigationStack`
- `Brew` has no explicit navigation container (relies on List navigation)

**Note:** This may be intentional (different tools need different layouts), but should be verified.

### 6. **Hardcoded Frame Sizes** (Multiple views)
**Issue:** Using hardcoded `.frame(idealHeight: 400)` and similar
**Files:**
- `Github_RootView.swift:63` - `.frame(idealHeight: 400)`
- `Git_RootView.swift:28` - `.frame(idealHeight: 400)` and `.frame(minWidth: 100)`
- `PersonalView.swift:59` - `.frame(idealWidth: 300)`

**Modern Pattern:** Use responsive layouts that adapt to window size

### 7. **Clunky Tool Selection Menu**
**Issue:** Tool switcher is a menu in toolbar, not discoverable
**File:** `CommonToolbarItems.swift`
**Current:** Menu dropdown with "Brew", "Git", "Github" buttons

**Modern Alternative:** Tab-based navigation or sidebar with tool icons

### 8. **Force Unwrap in UI** (Critical)
**Issue:** Force unwrapping optional data can crash
**File:** `Github_RootView.swift:27`
```swift
ProfileNameView(me: viewModel.me!)  // ❌ Crash risk
```

---

## 📋 UX Modernization Tasks

### Phase 1: Critical Fixes (30 min) ⭐ DO FIRST
- [ ] Fix force unwrap in `Github_RootView.swift`
- [ ] Replace deprecated Alert syntax in `Git_RootView.swift`
- [ ] Add error UI for critical operations (GitHub login failure)

### Phase 2: Preview Modernization (20 min)
- [ ] Convert all `PreviewProvider` to `#Preview` macro (15 files)

### Phase 3: Error Handling (1-2 hours)
- [ ] Create reusable `ErrorView` component
- [ ] Create `LoadingState<T>` enum for consistent state handling
- [ ] Replace `print()` error handling with proper UI (20+ locations)
- [ ] Add retry actions to error states

### Phase 4: Loading States (1 hour)
- [ ] Add loading indicators to all async operations
- [ ] Add skeleton views for list loading
- [ ] Show progress for Brew install/uninstall operations

### Phase 5: Layout Polish (1-2 hours)
- [ ] Remove hardcoded frame sizes
- [ ] Improve spacing and typography
- [ ] Add subtle animations/transitions
- [ ] Better empty states ("No repositories", "No pull requests")

### Phase 6: Navigation Consistency (1 hour)
- [ ] Audit navigation patterns across all tools
- [ ] Decide on consistent approach (document decision)
- [ ] Consider tab-based tool selection vs current menu

---

## 🔍 Detailed File-by-File Analysis

### Github_RootView.swift - HIGH PRIORITY
**Issues:**
1. Force unwrap `viewModel.me!` on line 27 - **CRASH RISK**
2. Nested `Task` in button action without error propagation to UI
3. Manual hasToken state synchronization (fragile)
4. `.task` modifier nested in Spacer (unusual placement)
5. Hardcoded frame size

**Recommended Changes:**
- Use `if let me = viewModel.me` instead of force unwrap
- Extract login logic to ViewModel
- Move `.task` to root view level
- Use responsive layout

### Git_RootView.swift - MEDIUM PRIORITY
**Issues:**
1. Old Alert syntax (deprecated)
2. Singleton ViewModel pattern (`ViewModel.shared`)
3. Hardcoded frame sizes
4. No loading state for repository loading

### Brew - SidebarNavigationView.swift - MEDIUM PRIORITY
**Issues:**
1. No error UI (just `print()`)
2. No feedback when "Installed" button is clicked
3. Old PreviewProvider syntax

### PersonalView.swift - MEDIUM PRIORITY
**Issues:**
1. Sequential loading of all org repos/PRs (slow, no progress)
2. `.onAppear` instead of `.task` for async work
3. No loading state indicator
4. Hardcoded frame size

---

## 📊 Effort Estimates

| Phase | Time | Impact | Status |
|-------|------|--------|--------|
| Phase 1: Critical Fixes | 30 min | High | ✅ DONE |
| Phase 2: Preview Modernization | 20 min | Low | ✅ DONE |
| Phase 3: Error Handling | 1-2 hrs | High | 🔴 Not Started |
| Phase 4: Loading States | 1 hr | Medium | 🔴 Not Started |
| Phase 5: Layout Polish | 1-2 hrs | Medium | 🔴 Not Started |
| Phase 6: Navigation Consistency | 1 hr | Medium | 🔴 Not Started |

**Remaining Estimated Time:** 4-6 hours

---

## ✅ Success Criteria

- [ ] No force unwraps in UI code
- [ ] All errors shown to user (not just console)
- [ ] All async operations have loading indicators
- [ ] All views use modern `#Preview` syntax
- [ ] No deprecated API usage
- [ ] Responsive layouts (no hardcoded sizes)
- [ ] Consistent navigation patterns documented

---

## Appendix: Code Patterns Reference

### Modern Error Handling Pattern
```swift
enum ViewState<T> {
  case idle
  case loading
  case loaded(T)
  case error(String)
}

@MainActor
@Observable
class ViewModel {
  var state: ViewState<[Item]> = .idle
  
  func load() async {
    state = .loading
    do {
      let items = try await fetchItems()
      state = items.isEmpty ? .idle : .loaded(items)
    } catch {
      state = .error(error.localizedDescription)
    }
  }
}

struct ContentView: View {
  @State private var viewModel = ViewModel()
  
  var body: some View {
    Group {
      switch viewModel.state {
      case .idle:
        ContentUnavailableView("No Items", systemImage: "tray")
      case .loading:
        ProgressView()
      case .loaded(let items):
        List(items) { item in ItemRow(item: item) }
      case .error(let message):
        ContentUnavailableView {
          Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Retry") { Task { await viewModel.load() } }
        }
      }
    }
    .task { await viewModel.load() }
  }
}
```

### Modern Preview Syntax
```swift
#Preview {
  MyView()
}

#Preview("Dark Mode") {
  MyView()
    .preferredColorScheme(.dark)
}

#Preview("With Data") {
  MyView(items: [.sample1, .sample2])
}
```

### Modern Alert Syntax
```swift
@State private var showingError = false
@State private var errorMessage = ""

.alert("Error", isPresented: $showingError) {
  Button("OK", role: .cancel) { }
  Button("Retry") { retryAction() }
} message: {
  Text(errorMessage)
}
```

---

## Next Steps

1. **Decide Priority:** Do you want polished UX or move to features?
2. **Phase 1 is Quick Win:** 30 minutes to fix crash risks
3. **Phase 2 is Safe:** Preview changes have zero runtime impact
4. **Phase 3-6 are Incremental:** Can do one at a time

**Recommendation:** At minimum, do **Phase 1** (critical fixes) before any feature work.
