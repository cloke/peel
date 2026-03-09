# UX Sidebar Cleanup Plan

**Date:** March 9, 2026
**Status:** Proposed
**Priority:** High — multiple broken/confusing flows

---

## Summary

A deep UX review (screenshots captured in `tmp/ux-review/`) reveals three categories of problems:

1. **GitHub login is completely unreachable** — The only Sign In button was in the legacy `Github_RootView`, which is no longer rendered
2. **Overlapping concepts across sidebar + repo detail** — Activity Dashboard ≈ RepositoriesCommandCenter, per-repo Activity tab ≈ Dashboard filter
3. **Sidebar structure is messy** — Swarm always visible, Chat buried under Activity, and the two-section model (Repositories / Activity) tries to do too much

---

## Problem 1: GitHub Login Is Lost (CRITICAL)

### Current State
- The GitHub "Login" button lives **only** in `Shared/Applications/Github_RootView.swift` (line 345)
- `Github_RootView` is marked as a **legacy view** and is not rendered from the current sidebar
- The sidebar's `visibleCases` are `[.repositories, .activity]` — the `.github` case is hidden for migration compat
- The new unified views (`UnifiedRepositoriesView`, `RepoDetailView`, `RepositoriesCommandCenter`) have **zero** auth UI
- A user who doesn't already have a Keychain token has no way to authenticate in-app

### Impact
- New users can't sign in to GitHub at all
- If a user resets the app (Settings → Reset), they lose their token with no way to re-authenticate
- All GitHub API features silently fail with empty responses

### Fix: Add GitHub Account to Sidebar/Settings

**Option A (Recommended) — Account section at bottom of sidebar:**
```
┌─────────────────────────┐
│ Repositories            │
│ Activity                │
│ ─────────────────────── │
│ Repositories            │
│   peel                  │
│   tio-api               │
│   ...                   │
│ ─────────────────────── │
│ Swarm                   │
│   2 online              │
│ ─────────────────────── │
│ ┌─────────────────────┐ │  ← NEW
│ │  🟢 @cloke          │ │  When signed in
│ │  ⚪ Sign in to GH   │ │  When signed out
│ └─────────────────────┘ │
└─────────────────────────┘
```

Add a bottom-pinned section to the List in `ContentView.sidebarContent`:
- When signed in: Show avatar + username, link to Settings/Account
- When signed out: Show "Sign in to GitHub" button that triggers `Github.authorize()`
- Pull `hasToken` check from `Github.hasToken` (already exists as a static async property)

**Files to change:**
- `macOS/ContentView.swift` — Add account section to sidebar
- `Shared/Views/SettingsView.swift` — Add "GitHub Account" tab with sign-in/sign-out and token status
- Optionally: `Shared/Applications/RepositoriesCommandCenter.swift` — Show an auth prompt banner when not signed in

---

## Problem 2: Overlapping Views

### 2A: RepositoriesCommandCenter ≈ ActivityDashboardView

Both views show nearly identical information:

| Section | Command Center | Activity Dashboard |
|---------|:---:|:---:|
| Open PRs | ✅ | ✅ (PR Review Queue) |
| Active chains | ✅ ("Agent Work") | ✅ ("Running Now") |
| Active worktrees | ✅ ("Agent Work") | ✅ ("Running Now") |
| Pending reviews | ✅ (parallel runs) | ❌ (separate sidebar item) |
| Swarm status | ❌ | ✅ |
| RAG indexing | ❌ | ✅ |
| Recent activity feed | ❌ | ✅ (paginated) |
| Repo cards summary | ✅ | ❌ |

**Fix:** Merge these into a single **"Home"** view that serves as both the no-repo-selected landing page AND the global dashboard:

```
Home (replaces both)
├── Needs Attention (open PRs, pending reviews)
├── Running Now (chains, parallel runs)
├── Repository Cards (quick stats grid)
├── Swarm Status (compact, only when active)
├── RAG Status (compact, only when indexed)
└── Recent Activity (collapsible feed)
```

This eliminates the duplication while keeping all info accessible.

**Files to change:**
- `Shared/Applications/UnifiedRepositoriesView.swift` — Merge `RepositoriesCommandCenter` content
- `Shared/Applications/ActivityDashboardView.swift` — Deprecate or redirect to merged view
- `macOS/ContentView.swift` — Point `.activityDashboard` and `.repoCommandCenter` at the same view

### 2B: Per-Repo Activity Tab ≈ Global Dashboard Filtered by Repo

The repo detail "Activity" tab is the global activity feed pre-filtered to one repo. The global dashboard also has a repo filter dropdown doing the same thing.

**Fix:**
- Keep the per-repo Activity tab (it makes sense in context)
- Remove the repo filter from the global dashboard (dashboard should be global-only)
- Add a "View all activity" link from per-repo tab to global feed

### 2C: SwarmManagementView in Sidebar AND Settings

The exact same `SwarmManagementView` component is rendered in two places:
1. Sidebar → Swarm section → click → detail pane
2. Settings → Swarm tab

**Fix:**
- **Settings:** Keep for swarm configuration (start/stop, role, diagnostics)
- **Sidebar → detail:** Show a **lightweight operational view** — connected workers, running tasks, quick actions. Not the full management view.
- OR: Remove from Settings entirely since the sidebar makes it always-accessible

---

## Problem 3: Sidebar Structure

### Current Sidebar Layout

When on **Repositories**:
```
┌─ Repositories (top-level)    ┐
├─ Activity (top-level)        │
├─ [Homebrew] (if enabled)     │  ← Fixed section
├─────────────────────────────-│
│ Repositories                 │  ← Section header (redundant with top-level)
│   Filter chips: All|Cloned|… │
│   repo1                      │
│   repo2                      │  ← Contextual section
│   ...                        │
├─────────────────────────────-│
│ Swarm                        │  ← Always visible
│   2 online                   │
│   worker1                    │
└──────────────────────────────┘
```

When on **Activity**:
```
┌─ Repositories (top-level)    ┐
├─ Activity (top-level)        │  ← Fixed section
├─────────────────────────────-│
│ [Running]                    │
│   chain 1 (if any running)   │  ← Dynamic section
├─────────────────────────────-│
│ Activity                     │  ← Section header
│   Dashboard                  │
│   PR Reviews                 │
│   Templates                  │
│   Parallel Runs              │
│   Worktrees                  │
│   Local Chat                 │  ← Contextual section
├─────────────────────────────-│
│ [Recent]                     │
│   ... feed items ...         │  ← Dynamic section
├─────────────────────────────-│
│ Swarm                        │  ← Always visible
│   2 online                   │
└──────────────────────────────┘
```

### Issues
1. **"Repositories" appears twice** — once as a top-level navigation item and once as a section header → confusing
2. **The top-level toggle between Repositories/Activity feels like tabs** but they're source-list items that change what appears below → non-standard macOS pattern
3. **Swarm is always visible** even when working on repos — clutters the sidebar when you don't care about swarm
4. **Activity sidebar has too many items** — Dashboard, PR Reviews, Templates, Parallel Runs, Worktrees, Chat, plus running chains AND recent feed. That's 6+ static items plus dynamic content
5. **Local Chat is buried** under Activity → should be a first-class global feature

### Proposed New Sidebar Structure

Flatten the two-mode sidebar into a single unified list:

```
┌──────────────────────────────┐
│ 🏠 Home                     │  ← Merged CommandCenter/Dashboard
│ 💬 Chat                     │  ← Promoted to top-level
├──────────────────────────────│
│ REPOSITORIES                 │
│   Filter: All|Cloned|…       │
│   peel                    ▸  │
│   tio-api                 ▸  │
│   tio-front-end           ▸  │
├──────────────────────────────│
│ AGENT WORK                   │  ← Consolidated
│   Templates & Run            │
│   Parallel Runs (3)          │
│   Worktrees (5)              │
│   PR Reviews (2)             │
├──────────────────────────────│
│ [RUNNING]                    │  ← Only when chains active
│   chain 1  ⏳               │
│   chain 2  ⏳               │
├──────────────────────────────│
│ SWARM                        │  ← Collapsible
│   2 online                   │
├──────────────────────────────│
│ 🟢 @cloke                   │  ← GitHub account
└──────────────────────────────┘
```

**Key changes:**
1. **No mode switching** — everything is visible always, just in sections
2. **Home** replaces both CommandCenter and ActivityDashboard
3. **Chat** is top-level, always accessible
4. **Agent Work** section consolidates Templates, Parallel Runs, Worktrees, PR Reviews
5. **Running chains** are a dynamic section that appears only when something is active
6. **Swarm** stays always-visible but is collapsible
7. **GitHub account** at the bottom replaces the lost login button
8. Recent activity feed moves into the Home detail view (not sidebar)

---

## Implementation Plan

### Phase 1: Critical Fix — GitHub Login (Quick Win)

1. Add GitHub account indicator to sidebar bottom in `ContentView.swift`
2. Add "Sign in to GitHub" action that calls `Github.authorize()`
3. Add "GitHub Account" tab to `SettingsView` with sign-in/sign-out

**Estimated scope:** ~3 files, ~100 lines

### Phase 2: Merge Dashboards

1. Create a unified `HomeView` combining `RepositoriesCommandCenter` + `ActivityDashboardView`
2. Wire Home as the default detail when no repo is selected
3. Wire it as the Activity → Dashboard target too (same view)
4. Remove repo filter from global dashboard (per-repo tab handles that)

**Estimated scope:** ~4 files, ~200 lines refactored

### Phase 3: Flatten Sidebar

1. Remove the Repositories/Activity mode toggle
2. Implement the unified sidebar layout with all sections always visible
3. Move Chat to top-level
4. Make Swarm section collapsible
5. Remove "Repositories" duplicate section header
6. Move Recent activity feed from sidebar to Home detail view

**Estimated scope:** ~2 files (mostly `ContentView.swift`), ~300 lines refactored

### Phase 4: Cleanup

1. Consider removing `SwarmManagementView` from Settings (sidebar suffices)
2. Remove or deprecate `ActivityDashboardView` (replaced by HomeView)
3. Update MCP automation state to match new sidebar IDs
4. Update `ui.navigate` viewIds for MCP compatibility

---

## Screenshots Reference

All screenshots saved in `tmp/ux-review/`:

| Screenshot | Shows |
|------------|-------|
| `ux-review-repositories.png` | Repositories sidebar with repo list |
| `ux-review-repo-peel-overview.png` | Repo detail → Overview tab |
| `ux-review-repo-peel-branches.png` | Repo detail → Branches tab |
| `ux-review-repo-peel-activity.png` | Repo detail → Activity tab |
| `ux-review-repo-peel-rag.png` | Repo detail → RAG tab |
| `ux-review-repo-peel-skills.png` | Repo detail → Skills tab |
| `ux-review-activity-full.png` | Activity Dashboard (global) |
| `ux-review-swarm.png` | Swarm Management view |

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| Flatten sidebar (no mode toggle) | Two-mode sidebar is non-standard macOS, confusing, hides content |
| Merge CommandCenter + Dashboard | 80% overlap in content, users see nearly identical views |
| GitHub account in sidebar bottom | Standard macOS pattern (Xcode, Finder sidebar), and login is critical |
| Chat as top-level item | Chat is a different interaction model from activity tracking |
| Keep per-repo Activity tab | Scoped view naturally makes sense when looking at one repo |
| Keep Swarm always visible | Workers run across repos — not scoped to one section |
