# UX Modernization Plan

**Date:** January 7, 2026  
**Status:** ✅ **COMPLETE**  
**Priority:** High  

---

## Executive Summary

All modernization work is **complete**. The app is now using:
- ✅ Swift 6 / SwiftUI 6 patterns
- ✅ Modern error handling with UI feedback
- ✅ SwiftData for persistence (iCloud-ready)
- ✅ Git worktree management with VS Code integration

---

## Completed Work

### Swift 6 Modernization ✅
- @Observable instead of ObservableObject
- NavigationStack/NavigationSplitView
- async/await throughout
- Actors for thread safety

### UX Polish ✅
- Fixed force unwrap crash risks
- Fixed deprecated Alert syntax
- Converted 15+ files to #Preview macro
- Added error alerts and loading states
- Added ContentUnavailableView empty states
- Segmented tool picker with icons + labels

### SwiftData Integration ✅
- iCloud-safe models (no circular refs, UUID identity)
- Git repositories persist via SwiftData
- Separate synced vs device-local models
- Ready for iCloud with one line change

### Git Worktrees ✅
- List/create/delete worktree commands
- Open worktree in VS Code
- UI in Git sidebar

---

## What's Persisted Where

| Data | Storage | iCloud Ready |
|------|---------|--------------|
| GitHub OAuth Token | Keychain | ❌ (security) |
| Git Repositories | SwiftData | ✅ Yes |
| Selected Repo | SwiftData | ❌ Device-local |
| Tool Selection | @AppStorage | ❌ No |
| GitHub Data | API (live) | N/A |
| Brew Data | CLI (live) | N/A |

---

## Build Status

✅ **BUILD SUCCEEDED** - App launched and working

---

# Next Steps for Future Sessions

## Known Issues (Track)
- Git → Local Changes commit editor: placeholder alignment still slightly offset vs cursor.
	- Consider custom NSTextView wrapper for precise placeholder alignment in SwiftUI.
- OAuth: Evaluate replacing OAuthSwift with native ASWebAuthenticationSession flow.

## Option 1: PR → Worktree Integration (Recommended)
**Goal:** One-click "Review Locally" button on GitHub PRs

**Tasks:**
1. Add "Review Locally" button to `PullRequestDetailView`
2. Create worktree from PR's branch
3. Open worktree in VS Code automatically
4. Track which PRs have active worktrees (SwiftData)

**Files to modify:**
- `Local Packages/Github/Sources/Github/Views/PullRequests/PullRequestsView.swift`
- `Local Packages/Git/Sources/Git/WorktreeListView.swift`

**Estimated time:** 2-3 hours

---

## Option 2: GitHub Favorites
**Goal:** Star repos and see them in a favorites section

**Tasks:**
1. Add star button to repo views
2. Create favorites section in GitHub sidebar
3. Wire up to `GitHubFavorite` SwiftData model

**Estimated time:** 1-2 hours

---

## Option 3: Recent PRs
**Goal:** Quick access to recently viewed PRs

**Tasks:**
1. Track PR views in `RecentPullRequest` model
2. Show "Recent" section in Personal view
3. Auto-cleanup old entries

**Estimated time:** 1 hour

---

## Option 4: Enable iCloud Sync
**Goal:** Sync repositories and favorites across Macs

**Tasks:**
1. Enable CloudKit in Xcode capabilities
2. Change `cloudKitDatabase: .none` to `.automatic`
3. Test sync between devices
4. Handle merge conflicts

**Files to modify:**
- `Shared/KitchenSyncApp.swift` (one line change)
- Xcode project capabilities

**Estimated time:** 1-2 hours (plus testing)

---

## Option 5: Agent Orchestration (Larger Feature)
**Goal:** Manage AI coding agents with isolated workspaces

**See:** `AGENT_ORCHESTRATION_PLAN.md`

**Estimated time:** 1-2 weeks

---

## Quick Reference

**To start a new session, copy this:**

```
I'm continuing work on KitchenSink. Last session completed:
- UX modernization (all phases)
- SwiftData integration (iCloud-ready)
- Git worktree management

I want to work on: [CHOOSE ONE]
- PR → Worktree integration (review PRs locally)
- GitHub favorites feature
- Recent PRs feature  
- Enable iCloud sync
- Agent orchestration

Please read the relevant plan in /Plans/ and let's get started.
```

---

## Files Reference

| Area | Key Files |
|------|-----------|
| App Entry | `Shared/KitchenSyncApp.swift` |
| SwiftData Models | `Shared/KitchenSyncApp.swift` (bottom) |
| Git UI | `Shared/Applications/Git_RootView.swift` |
| GitHub UI | `Shared/Applications/Github_RootView.swift` |
| Worktrees | `Local Packages/Git/Sources/Git/WorktreeListView.swift` |
| Plans | `Plans/WORKTREE_FEATURE_PLAN.md`, `Plans/AGENT_ORCHESTRATION_PLAN.md` |