# KitchenSink Code Audit Index

**Last Full Audit:** January 16, 2026  
**Last Updated:** January 17, 2026  
**Swift Version:** 6.0  
**SwiftUI Version:** 6.0  
**Targets:** macOS 26, iOS 26

This document tracks file reviews, prevents code duplication, and ensures old patterns don't sneak back in.

---

## Quick Reference: Patterns to Avoid

| ❌ Deprecated Pattern | ✅ Modern Pattern | Auto-Detectable |
|-----------------------|-------------------|-----------------|
| `ObservableObject` | `@Observable` | grep: `ObservableObject` |
| `@Published` | Direct properties on @Observable | grep: `@Published` |
| `@StateObject` | `@State` | grep: `@StateObject` |
| `@ObservedObject` | `@Environment` or passed reference | grep: `@ObservedObject` |
| `NavigationView` | `NavigationStack`/`NavigationSplitView` | grep: `NavigationView` |
| `import Combine` | async/await | grep: `import Combine` |
| `DispatchQueue.main` | `@MainActor` | grep: `DispatchQueue.main` |
| `try!` | do/catch (unless compile-time constant) | grep: `try!` |
| `!` force unwrap | guard let / if let | manual review |
| `PreviewProvider` | `#Preview` macro | grep: `PreviewProvider` |

---

## Audit Commands

Run these to quickly check for deprecated patterns:

```bash
# Check for deprecated Observable patterns
cd /Users/cloken/code/KitchenSink
grep -r "ObservableObject\|@Published\|@StateObject\|@ObservedObject" --include="*.swift" .

# Check for deprecated NavigationView
grep -r "NavigationView" --include="*.swift" .

# Check for Combine imports (excluding Alamofire internals)
grep -r "import Combine" --include="*.swift" . | grep -v "Pods\|.build"

# Check for DispatchQueue.main
grep -r "DispatchQueue.main" --include="*.swift" .

# Check for force try (review if not compile-time constants)
grep -r "try!" --include="*.swift" .

# Check for force unwraps
grep -rn "\.first!" --include="*.swift" .
grep -rn "URL(string:" --include="*.swift" . | grep "!"

# Check for legacy PreviewProvider
grep -r "PreviewProvider" --include="*.swift" .
```

---

## File Status Index

### Legend
- ✅ **Modern** - No issues, follows all patterns
- ⚠️ **Minor** - Small issues (documented exceptions, TODO stubs)
- 🔶 **Needs Fix** - Has deprecated patterns or force unwraps
- 🔴 **Legacy** - Significant refactoring needed
- 📝 **Docs** - Documentation file

---

## Shared/ Directory

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| [KitchenSyncApp.swift](../Shared/KitchenSyncApp.swift) | ⚠️ Minor | 2026-01-16 | `fatalError` in ModelContainer (acceptable) |
| [CommonToolbarItems.swift](../Shared/CommonToolbarItems.swift) | ✅ Modern | 2026-01-16 | None |

### Shared/AgentOrchestration/

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| [AgentManager.swift](../Shared/AgentOrchestration/AgentManager.swift) | ✅ Modern | 2026-01-16 | Uses @MainActor @Observable |
| [AppleAIService.swift](../Shared/AgentOrchestration/AppleAIService.swift) | ✅ Modern | 2026-01-16 | Uses @MainActor @Observable |
| [CLIService.swift](../Shared/AgentOrchestration/CLIService.swift) | ✅ Modern | 2026-01-16 | Uses @MainActor @Observable |
| [VMIsolationService.swift](../Shared/AgentOrchestration/VMIsolationService.swift) | ✅ Modern | 2026-01-16 | Fixed force unwrap, TODO stubs for future |
| [VMIsolationView.swift](../Shared/AgentOrchestration/VMIsolationView.swift) | ⚠️ Minor | 2026-01-16 | 1 force unwrap L2420 |
| [WorkspaceManager.swift](../Shared/AgentOrchestration/WorkspaceManager.swift) | ✅ Modern | 2026-01-16 | Uses @MainActor @Observable |
| [WorktreeService.swift](../Shared/AgentOrchestration/WorktreeService.swift) | ✅ Modern | 2026-01-16 | Uses @MainActor @Observable |

### Shared/AgentOrchestration/Models/

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| AgentModels.swift | ✅ Modern | 2026-01-16 | Sendable structs |

### Shared/Applications/

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| [Agents_RootView.swift](../Shared/Applications/Agents_RootView.swift) | ✅ Modern | 2026-01-16 | Fixed force unwrap, Uses NavigationSplitView |
| [Brew_RootView.swift](../Shared/Applications/Brew_RootView.swift) | ✅ Modern | 2026-01-16 | Uses NavigationStack |
| [Git_RootView.swift](../Shared/Applications/Git_RootView.swift) | ✅ Modern | 2026-01-16 | Uses NavigationStack |
| [Github_RootView.swift](../Shared/Applications/Github_RootView.swift) | ✅ Modern | 2026-01-16 | Updated to #Preview macro |
| [Workspaces_RootView.swift](../Shared/Applications/Workspaces_RootView.swift) | ✅ Modern | 2026-01-16 | Uses NavigationSplitView |

### Shared/Services/

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| VSCodeService.swift | ✅ Modern | 2026-01-16 | Uses actor |

### Shared/Views/

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| TaskDebugWindow.swift | ⚠️ Stub | 2026-01-16 | Stub file, updated to #Preview |
| LoadingStateViews.swift | ✅ Modern | 2026-01-16 | Clean enum pattern |

### Shared/Extensions/

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| Date+Extensions.swift | ✅ Modern | 2026-01-16 | nonisolated(unsafe) static |
| View+Extensions.swift | ✅ Modern | 2026-01-16 | Simple extension |

---

## Local Packages/Brew/

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| Package.swift | ✅ Modern | 2026-01-16 | Swift 6.0 |
| README.md | ⚠️ Minimal | 2026-01-16 | Only placeholder text |
| Sources/Brew/Commands.swift | ✅ Modern | 2026-01-16 | Static constants |
| Sources/Brew/Models.swift | ✅ Modern | 2026-01-16 | Codable structs |
| Sources/Brew/BrewRootView.swift | ✅ Modern | 2026-01-16 | @MainActor @Observable |
| Sources/Brew/SearchView.swift | ✅ Modern | 2026-01-16 | @MainActor @Observable |
| Sources/Brew/SidebarNavigationView.swift | ✅ Modern | 2026-01-16 | Clean view |

---

## Local Packages/Git/

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| Package.swift | ✅ Modern | 2026-01-16 | Swift 6.0 |
| README.md | ✅ Adequate | 2026-01-16 | Brief description |
| Sources/Git/Git.swift | ✅ Modern | 2026-01-16 | NavigationStack |
| Sources/Git/ViewModel.swift | ✅ Modern | 2026-01-16 | Singleton documented (acceptable for app state) |
| Sources/Git/Commands/Diff.swift | ✅ Modern | 2026-01-16 | `try!` regex documented (compile-time constant) |
| Sources/Git/Views/BranchListView.swift | ✅ Modern | 2026-01-16 | Cleaned commented code, updated #Preview |
| Sources/Git/Views/BranchSwitchView.swift | ✅ Modern | 2026-01-16 | Uses documented singleton |
| Sources/Git/Views/*.swift (others) | ✅ Modern | 2026-01-16 | Clean async/await |
| Sources/Git/Models/Repository.swift | ✅ Modern | 2026-01-16 | @Observable |

---

## Local Packages/Github/

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| Package.swift | ✅ Modern | 2026-01-16 | Swift 6.0 |
| README.md | ✅ Adequate | 2026-01-16 | Brief description |
| Sources/Github/Github.swift | ✅ Modern | 2026-01-16 | Namespace |
| Sources/Github/ViewModel.swift | ✅ Modern | 2026-01-16 | @MainActor @Observable |
| Sources/Github/Network.swift | ✅ Modern | 2026-01-16 | Fixed all force unwraps with guards |
| Sources/Github/Services/KeychainService.swift | ✅ Modern | 2026-01-16 | Actor-based |
| Sources/Github/Services/VSCodeService.swift | ✅ Modern | 2026-01-16 | Actor-based |
| Sources/Github/Views/OrganizationDetailView.swift | ✅ Modern | 2026-01-16 | Fixed URL force unwrap |
| Sources/Github/Views/OrganizationPullRequestsListView.swift | ✅ Modern | 2026-01-16 | Fixed force unwraps |
| Sources/Github/Views/CommitsListItemView.swift | ✅ Modern | 2026-01-16 | Updated to #Preview |
| Sources/Github/Views/CommitDetailView.swift | ✅ Modern | 2026-01-16 | Removed duplicate Color extension |
| Sources/Github/Models/*.swift | ✅ Modern | 2026-01-16 | Codable structs |

---

## Local Packages/GithubUI/ - REMOVED

Package was empty (no sources). Deleted on 2026-01-16.

---

## Documentation Status

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| Package.swift | 🔴 Empty | 2026-01-16 | **No sources - remove or implement** |

---

## Platform-Specific (iOS/)

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| [ContentView.swift](../iOS/ContentView.swift) | ✅ Modern | 2026-01-16 | Modern TabView, NavigationStack |
| Info.plist | ✅ Good | 2026-01-16 | armv7 legacy but harmless |

---

## Platform-Specific (macOS/)

| File | Status | Last Reviewed | Issues |
|------|--------|---------------|--------|
| [ContentView.swift](../macOS/ContentView.swift) | ✅ Modern | 2026-01-16 | Clean @AppStorage usage |
| Info.plist | ✅ Good | 2026-01-16 | Proper URL scheme |
| macOS.entitlements | ✅ Good | 2026-01-16 | iCloud + virtualization |

---

## Documentation Status

| File | Status | Last Reviewed | Notes |
|------|--------|---------------|-------|
| /README.md | ✅ Current | 2026-01-16 | Rewritten with modern structure |
| /START_HERE.md | ✅ Current | 2026-01-16 | Updated for Jan 16 |
| /Plans/CODE_AUDIT_INDEX.md | ✅ Current | 2026-01-17 | This file |
| /Plans/MODERNIZATION_COMPLETE.md | ✅ Current | 2026-01-16 | Historical record |
| /Plans/AGENT_ORCHESTRATION_PLAN.md | ✅ Current | 2026-01-16 | Updated to @Observable patterns |
| /Plans/SWIFTUI_MODERNIZATION_PLAN.md | ✅ Complete | 2026-01-16 | Archived |
| /Plans/SWIFTDATA_PLAN.md | ✅ Complete | 2026-01-16 | Archived |
| /Plans/UX_MODERNIZATION_PLAN.md | ✅ Complete | 2026-01-16 | Archived |

---

## Remaining Items

### Low Priority ⚠️

| Item | Notes |
|------|-------|
| VMIsolationView.swift force unwrap | L2420 - minor, in error path |
| Git ViewModel singleton | Documented as acceptable for app-wide state |
| TaskDebugWindow.swift | Stub file - remove or implement |
| Brew/README.md | Expand with usage examples |

---

## Agent Anti-Duplication Guidelines

### Before Creating New Code

1. **Search first** - Use `grep -r "FeatureName" --include="*.swift" .`
2. **Check this index** - Is there an existing similar component?
3. **Check packages** - Brew, Git, Github already have reusable patterns

### Common Reusable Components

| Component | Location | Use For |
|-----------|----------|---------|
| LoadingState enum | Shared/Views/LoadingStateViews.swift | Any async data loading |
| ProcessExecutor actor | Local Packages/Git/Sources/Git/Commands/ | Shell command execution |
| KeychainService | Local Packages/Github/Services/ | Secure token storage |
| VSCodeService | Shared/Services/ or Github/Services/ | IDE integration |
| @Observable ViewModel pattern | All packages | State management |

### Code Location Rules

| Feature Type | Location |
|--------------|----------|
| GitHub API models | Local Packages/Github/Models/ |
| GitHub views | Local Packages/Github/Views/ |
| Git operations | Local Packages/Git/ |
| Brew operations | Local Packages/Brew/ |
| Agent orchestration | Shared/AgentOrchestration/ |
| Shared UI components | Shared/Views/ or Shared/Components/ |
| Platform entry points | iOS/ or macOS/ |

---

## Review Checklist for PRs

```markdown
## Code Quality Checklist

### Swift 6 Compliance
- [ ] No `ObservableObject` (use `@Observable`)
- [ ] No `@Published` (use direct properties)
- [ ] No `@StateObject` (use `@State`)
- [ ] No `NavigationView` (use `NavigationStack`/`NavigationSplitView`)
- [ ] No `import Combine` (use async/await)
- [ ] No `DispatchQueue.main` (use `@MainActor`)
- [ ] ViewModels have `@MainActor @Observable`
- [ ] Actors used for thread-safe services

### Error Handling
- [ ] No `try!` (use do/catch)
- [ ] No force unwraps `!` (use guard/if-let)
- [ ] Proper error states in UI

### Code Hygiene
- [ ] No commented-out code blocks
- [ ] No duplicate code (checked index)
- [ ] Uses existing reusable components
- [ ] Follows 2-space indentation
```

---

## Automated Checks

Add to CI/pre-commit hook:

```bash
#!/bin/bash
# .git/hooks/pre-commit or CI script

ERRORS=0

# Check for deprecated patterns
if grep -r "ObservableObject" --include="*.swift" . 2>/dev/null | grep -v "// Legacy\|// TODO"; then
  echo "❌ Found ObservableObject - use @Observable instead"
  ERRORS=$((ERRORS + 1))
fi

if grep -r "@Published" --include="*.swift" . 2>/dev/null; then
  echo "❌ Found @Published - use direct properties with @Observable"
  ERRORS=$((ERRORS + 1))
fi

if grep -r "NavigationView" --include="*.swift" . 2>/dev/null; then
  echo "❌ Found NavigationView - use NavigationStack/NavigationSplitView"
  ERRORS=$((ERRORS + 1))
fi

exit $ERRORS
```

---

**Next Review:** Add to session notes when files are modified
