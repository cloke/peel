# PR UX Unification Plan

## Status: Proposed
## Created: 2025-07-22

---

## 1. Current State — Side-by-Side Comparison

### Where PR-related UX lives today

| Surface | File | What it shows |
|---------|------|---------------|
| **Home (Command Center)** | `UnifiedRepositoriesView.swift` | Dashboard with running chains, "needs attention" PRs, PR review queue widget, agent work, repos, swarm, activity feed |
| **GitHub tab** | `Github_RootView.swift` | NavigationSplitView with Favorites, Recent PRs (with review status badges), Tracked Repos, Org repos, Profile |
| **PR Review Queue (shared)** | `PRReviewQueueView.swift` | Embeddable widget showing active/completed agent reviews — used by both Home and GitHub tab |
| **Agent Review Sheet (shared)** | `AgentReviewSheet.swift` | Modal sheet for running/monitoring agent reviews — shared via environment keys |
| **PR Detail (shared)** | `Github` package `PullRequestDetailView` | Canonical PR detail — used by Home's `PRDetailInlineView` AND GitHub tab's `RecentPRDestination` |

### Component sharing matrix

| Component | Home | GitHub Tab | Shared? |
|-----------|------|------------|---------|
| `PullRequestDetailView` | ✅ via `PRDetailInlineView` | ✅ via `RecentPRDestination` | ✅ Same view |
| `PRReviewQueueSection` | ✅ embedded in body | ✅ in `PRReviewQueueDetailView` | ✅ Same component |
| `AgentReviewSheet` | ✅ via coordinator | ✅ via coordinator | ✅ Same sheet |
| `PRReviewStatusBridge` | ✅ created & injected | ✅ created & injected | ⚠️ Duplicated setup |
| `PRReviewAgentCoordinator` | ✅ created & injected | ✅ created & injected | ⚠️ Duplicated setup |
| Open PRs fetching | `fetchAllOpenPRs()` (TaskGroup) | `fetchOpenPRs()` in `PRReviewQueueDetailView` | ❌ Duplicated |
| Open PRs display | `needsAttentionSection` rows | `openPRsSection` in queue detail | ❌ Different UX |
| Review status badge | N/A | `reviewStatusBadge` on sidebar rows | GitHub-only |
| Running chains cards | `runningNowSection` cards | N/A | Home-only |
| Activity feed | `recentActivitySection` | N/A | Home-only |
| Repo cards with badges | `repositoryCardsSection` | Org/Tracked repo list | Different UX |

---

## 2. UX Assessment — What's Better Where

### PR Detail (`PullRequestDetailView`) — **Both use the same view** ✅
No divergence here. Both Home and GitHub tab render the same `PullRequestDetailView` from the Github package. This includes:
- Header with title, branch, actions ("Open in Browser", "Review Locally", "Review with Agent")
- Status bar (state, CI checks, agent review status pill)
- Metadata grid, labels, reviewers
- Checks section, changed files (macOS), review actions (Approve/Request Changes/Comment/Merge)
- Reviews section, agent review section (inline results), comments, description

**Verdict:** Already unified. No changes needed.

### Agent Review UX — **Home version is better** (user confirmed)

The `AgentReviewSheet` (1452 lines, shared modal) is equally accessible from both surfaces via `PRReviewAgentCoordinator`. The difference is:

| Aspect | Home | GitHub Tab |
|--------|------|------------|
| Review Queue visibility | Inline `PRReviewQueueSection` always visible in scroll | Only visible in dedicated `PRReviewQueueDetailView` |
| Queue context | Queue appears alongside running chains, pending approvals, repos — full operational context | Queue is isolated — you have to navigate to a specific detail view |
| Quick action proximity | "Needs attention" PRs and review queue are adjacent — one scroll to get from PR → review queue → running agents | Sidebar shows recent PRs with badges, but no queue widget visible without extra navigation |

**Why Home is better for agent reviews:** The Command Center layout provides *operational awareness* — you see the review queue alongside running chains, pending approvals, and the PR that triggered it, all in one scrollable view. The GitHub tab isolates these into separate navigation destinations.

### PR Page Layout — **GitHub tab is generally better** (user confirmed)

| Aspect | Home | GitHub Tab |
|--------|------|------------|
| PR list browsing | `needsAttentionSection` shows open PRs as simple rows mixed with other content | Sidebar has dedicated "Recent PRs" section with review status badges |
| Repository organization | Repo cards in a grid with badge counts | Favorites + Tracked Repos + Org hierarchy with NavigationLinks |
| PR detail navigation | Inline replacement of whole view (`PRDetailInlineView`) — lose dashboard context | Standard NavigationSplitView — sidebar stays visible, detail in pane |
| Favorites/recents | Not supported | Built-in favorites and recent PR tracking |
| Review status on PR rows | Not visible on individual PR rows | `reviewStatusBadge` shows Running/Reviewed/Failed per PR |

**Why GitHub tab is better for PR browsing:** NavigationSplitView preserves context (sidebar always visible). Favorites and recents provide quick access. Review status badges on PR rows give instant visibility.

### What's duplicated but NOT shared

1. **Open PR fetching** — Home's `fetchAllOpenPRs()` and `PRReviewQueueDetailView.fetchOpenPRs()` both iterate tracked repos and call `Github.loadPullRequests()`
2. **Bridge/coordinator setup** — Both `UnifiedRepositoriesView` and `Github_RootView` create their own `PRReviewStatusBridge` and `PRReviewAgentCoordinator`, wire them to `mcpServer.prReviewQueue`, and inject them
3. **Open PR display** — Home's `needsAttentionSection` and queue detail's `openPRsSection` render similar PR rows with different styling

---

## 3. Unification Plan

### Guiding Principles
1. **GitHub tab layout** is the primary PR browsing surface (NavigationSplitView, favorites, recents, review badges)
2. **Home's operational context** for agent reviews is preserved (review queue + running chains + pending approvals visible together)
3. The PR detail view is already shared — don't touch it
4. Eliminate duplicated fetching, bridge/coordinator setup, and PR list rendering

### Phase 1: Extract shared PR infrastructure (Low risk)

**Goal:** Single source of truth for PR bridge/coordinator/fetching.

#### 1A. Create `PRReviewEnvironmentModifier` view modifier
Extract the duplicated bridge/coordinator/sheet setup into a single reusable modifier:

```swift
// Shared/Applications/PRReviewEnvironmentModifier.swift
struct PRReviewEnvironmentModifier: ViewModifier {
  @Environment(MCPServerService.self) var mcpServer
  @State private var reviewAgentCoordinator = PRReviewAgentCoordinator()
  @State private var reviewStatusBridge = PRReviewStatusBridge()
  @State private var reviewTarget: AgentReviewTarget?
  var dataProvider: GitHubDataProvider?

  func body(content: Content) -> some View {
    content
      .reviewWithAgentProvider(reviewAgentCoordinator)
      .prReviewStatusProvider(reviewStatusBridge)
      .sheet(item: $reviewTarget) { target in
        AgentReviewSheet(target: target)
      }
      .onAppear {
        reviewStatusBridge.queue = mcpServer.prReviewQueue
        reviewAgentCoordinator.onReview = { pr, repo in
          let localPath = dataProvider?.localPath(for: repo)
          reviewTarget = PRReviewAgentCoordinator.makeTarget(pr: pr, repo: repo, localRepoPath: localPath)
        }
      }
  }
}
```

**Impact:** Remove ~30 lines of duplicated setup from both `UnifiedRepositoriesView` and `Github_RootView`. Both apply `.prReviewEnvironment(dataProvider:)` instead.

#### 1B. Create `OpenPRsFetcher` shared service
Extract the parallel open-PR-fetching logic used by both Home and the queue detail:

```swift
// Shared/Applications/OpenPRsFetcher.swift
@MainActor
@Observable
class OpenPRsFetcher {
  var openPRs: [(Github.Repository, [Github.PullRequest])] = []
  var isLoading = false

  func fetch(trackedRepos: [TrackedRemoteRepo], githubVM: Github.ViewModel) async {
    isLoading = true
    defer { isLoading = false }
    // TaskGroup-based parallel fetch (currently in UnifiedRepositoriesView.fetchAllOpenPRs)
  }
}
```

**Impact:** Replace `fetchAllOpenPRs()` in `UnifiedRepositoriesView` (~25 lines) and `fetchOpenPRs()` in `PRReviewQueueDetailView` (~20 lines) with shared instance.

### Phase 2: Unify "PR attention" display (Medium risk)

**Goal:** One component for "PRs that need your attention" — used by both Home and GitHub tab.

#### 2A. Create `PRAttentionList` component
A shared component that shows open PRs with review status indicators:

```swift
struct PRAttentionList: View {
  let prs: [(Github.Repository, [Github.PullRequest])]
  var onSelectPR: ((Github.PullRequest, Github.Repository) -> Void)?
  var compact: Bool = false  // Home uses compact, GitHub tab uses full
}
```

- **Home:** Renders in compact mode within `needsAttentionSection` — shows PR title, repo, review status badge, tap to select
- **GitHub tab sidebar:** Could optionally use this in the "Recent PRs" section, or keep the current `NavigationLink` pattern if the sidebar UX is good enough

#### 2B. Embed review queue in GitHub tab
The GitHub tab currently doesn't surface the review queue prominently. Add `PRReviewQueueSection` to the GitHub tab's detail area (perhaps as a header/banner when reviews are active):

```swift
// In Github_RootView detailRootView
VStack {
  if mcpServer.prReviewQueue.activeItems.isNotEmpty {
    PRReviewQueueSection(queue: mcpServer.prReviewQueue, onSelectPR: { ... })
  }
  // existing detail content
}
```

This brings Home's "operational awareness" advantage to the GitHub tab without changing the NavigationSplitView layout.

### Phase 3: Consolidate navigation (Higher risk, optional)

**Goal:** Make Home's PR-related sections delegate to the GitHub tab rather than duplicating.

#### 3A. Home becomes a summary dashboard
Instead of Home having its own `PRDetailInlineView` (which replaces the entire view), PR items in Home would deep-link to the GitHub tab:

- "Needs attention" PR rows → navigate to GitHub tab with that PR selected
- Review queue items → navigate to GitHub tab's PR detail with review sheet  
- Running chains → stay in Home (these are unique to Home)

**Trade-off:** Loses Home's current "everything in one scroll" feel. May not be worth it if users like the current Command Center flow. **Recommend deferring this** until Phase 1–2 are in place and user feedback is collected.

#### 3B. Alternative: Keep Home's inline PR detail but add back-nav
Instead of removing `PRDetailInlineView`, add a breadcrumb/back button and keep the inline PR detail. This preserves the Command Center's "don't leave this view" philosophy while making navigation clearer.

---

## 4. Recommended Execution Order

| Step | Phase | Effort | Risk | Impact |
|------|-------|--------|------|--------|
| 1 | 1A — `PRReviewEnvironmentModifier` | Small | Low | Eliminates duplicated bridge/coordinator setup |
| 2 | 1B — `OpenPRsFetcher` | Small | Low | Eliminates duplicated PR fetching |
| 3 | 2B — Embed review queue in GitHub tab | Small | Low | Brings Home's best feature (operational awareness) to GitHub tab |
| 4 | 2A — `PRAttentionList` component | Medium | Medium | Unifies PR list rendering across surfaces |
| 5 | 3B — Improve Home's inline PR nav | Small | Low | Better UX within existing architecture |
| 6 | 3A — Home deep-links to GitHub tab | Large | High | Major navigation refactor — defer |

---

## 5. Files Affected

| File | Changes |
|------|---------|
| `Shared/Applications/UnifiedRepositoriesView.swift` | Remove bridge/coordinator setup (~30 lines), replace `fetchAllOpenPRs()` with `OpenPRsFetcher`, apply `.prReviewEnvironment()` modifier |
| `Shared/Applications/Github_RootView.swift` | Remove bridge/coordinator setup (~30 lines), apply `.prReviewEnvironment()` modifier, add `PRReviewQueueSection` to detail area |
| `Shared/Applications/PRReviewQueueView.swift` | Replace internal `fetchOpenPRs()` with `OpenPRsFetcher` |
| **NEW** `Shared/Applications/PRReviewEnvironmentModifier.swift` | Shared bridge/coordinator/sheet setup |
| **NEW** `Shared/Applications/OpenPRsFetcher.swift` | Shared open PR fetching service |
| `Shared/Applications/AgentReviewSheet.swift` | Move `PRReviewAgentCoordinator` to its own file or keep in sheet (minor) |

---

## 6. What NOT to Change

- **`PullRequestDetailView`** — Already shared, working well. Don't touch.
- **`AgentReviewSheet`** — Already shared via environment. Don't touch.
- **`PRReviewQueueSection`/`PRReviewQueueView`** — Already a shared component. Don't touch.
- **Home's running chains / swarm / activity sections** — These are Home-unique and valuable.
- **GitHub tab's NavigationSplitView layout** — This is the "generally better" layout, keep it.

---

## 7. Summary

The overlap is primarily at the **infrastructure level** (bridge/coordinator/fetching duplication) and the **"attention" display level** (both surfaces show open PRs in different ways). The core PR detail and agent review components are already properly shared.

**Key wins from this plan:**
1. ~60 lines of duplicated bridge/coordinator setup eliminated
2. ~45 lines of duplicated PR fetching logic consolidated
3. GitHub tab gains Home's best feature (inline review queue visibility)
4. Home remains the operational dashboard; GitHub tab remains the PR browsing surface
5. Both surfaces benefit from improvements to shared components
