---
title: "Product UX Overhaul: Ship-Ready Peel"
status: active
created: 2026-03-04
updated: 2026-03-04
tags:
  - ux
  - navigation
  - product
  - design
  - ship-ready
audience:
  - developer
  - ai-agent
---

# Product UX Overhaul: Ship-Ready Peel

**Status:** Active  
**Created:** March 4, 2026  
**Updated:** March 5, 2026  
**Goal:** Transform Peel from a developer tool collection into a cohesive product that new users immediately understand.

> **Quick Status (March 5, 2026):** Phases 0–5b complete. Phase 6 (repo detail modernization) partially done — Branches tab reworked with inline layout, worktree approval chain, and agent PR review. RAG/Activity/Skills tabs still need card-based modernization. Phase 7 (worktree approvals + PR review) complete and building. **Phase 8 started** — P8-06 (PR Queue Reliability) fully implemented: O(1) dequeue, retry/backoff, async git push, SwiftData persistence. OPT-01/02/03 also done. GitHub issues #347–#356 created for full Phase 8/9 execution pack. **Swarm Console is now an inline detail view** in the Activity tab (not a modal/sheet). Chat tab added with Firebase messaging. Recent Activity paginated (50/page). Feature Discovery checklist updated for 2-tab layout. Several old features still unreachable — see "Feature Accessibility Audit" below.

---

## Executive Summary

Peel's core value proposition: **Your repositories have AI agents working on them continuously, and you can see everything happening across your machines from one place.**

Today's UX obscures this by splitting the experience into disconnected tabs (Agents, Workspaces, Brew, Repositories, Swarm) where the user's real mental model is: **"I have repos, I want things done to them, and I want to see what's happening."**

This plan reorganizes Peel around **two primary surfaces** and **one settings area**:

1. **Repositories** — The single source of truth. Every repo, local or remote, in one unified list with its full context: branches, worktrees, agent work, RAG status, pull status.
2. **Activity** — What's happening right now across all repos and workers. Running chains, active worktrees, swarm workers, indexing jobs.
3. **Settings** — Everything else: MCP config, CLI connections, feature flags, VM isolation, Brew (if enabled).

---

## The Problems (Current State Analysis)

### Problem 1: Repositories Are Split Into Three Concepts

| Current Surface | What It Shows | User Mental Model |
|----------------|---------------|-------------------|
| Repositories > Local | Local git repos (branches, commits, status) | "A repo I cloned" |
| Repositories > Remote | GitHub favorites, recent PRs, tracked repos | "A repo on GitHub" |
| Agents > Worktrees | Agent worktrees for repos | "A branch of a repo" |

**User truth:** A repository is a repository. If I cloned `tio-api`, I don't think of it as "a local repo" AND "a GitHub favorite" AND "something with worktrees." It's just `tio-api` — it happens to be cloned locally, linked to GitHub, has some agent worktrees, and is RAG-indexed.

**Evidence from screenshot audit:**
- The Repositories tab has a Local/Remote toggle that forces an artificial split
- `TrackedRemoteRepo` and `SyncedRepository` + `LocalRepositoryPath` are separate models for the same underlying concept
- `Git_RootView` and `Github_RootView` are entirely separate view hierarchies with no cross-linking

### Problem 2: The Agents Tab Is a Junk Drawer

The Agents sidebar currently contains:

| Sidebar Item | Actually About | Should Live... |
|-------------|---------------|---------------|
| Copilot / Claude connections | Infrastructure setup | Settings |
| MCP Activity | System monitoring | Activity feed or Settings |
| Template Gallery | Ways to start work | "New Task" dialog |
| Chain History | Past work on repos | Repository context or Activity |
| Local RAG | Per-repo indexing | Repository detail |
| Dependency Graph | Per-repo analysis | Repository detail |
| Docling Import | Niche import tool | Settings / Feature Flags |
| PII Scrubber | Niche utility | Settings / Feature Flags |
| Translation Validation | Niche utility | Settings / Feature Flags |
| Parallel Worktrees | Active work on repos | Repository detail + Activity |
| Worktrees | Branches/worktrees | Repository detail |
| Local Chat | AI interaction | Floating panel or repository-scoped |
| VM Isolation (4 sub-items) | Infrastructure | Settings |

That's **13+ items** in one sidebar. A new user sees this and has no idea where to start or what matters.

### Problem 3: Swarm Is Isolated

The Swarm tab shows connected workers, task logs, and worktrees — but has zero connection to which repositories those workers are operating on. You can't go from "Mac Studio is running a chain" to "...on tio-api, branch feature/auth."

### Problem 4: Workspaces Tab Is Confusing

The Workspaces tab manages worktrees — but worktrees are just branches of repositories. This tab duplicates what should be visible per-repository and adds an abstraction ("workspace") that doesn't map to how developers think.

### Problem 5: No Cohesive Story

A new user opens Peel and sees: Agents | Workspaces | Brew | Repositories | Swarm

Questions they'll ask:
- "What's the difference between Workspaces and Repositories?"
- "Why is RAG search inside Agents?"
- "What does Swarm do and why is it separate from Agents?"
- "Where do I see what agents are doing to my code?"

---

## The Product Vision

### One Sentence
**Peel is where you manage your repositories and the AI agents that work on them.**

### Information Architecture (New)

```
┌─────────────────────────────────────────────────────┐
│  [Repositories]  [Activity]  [⚙ Settings]          │
└─────────────────────────────────────────────────────┘
```

**Two primary tabs. One settings window.**

---

## Tab 1: Repositories (The Home Screen)

### Concept
Every repository you work with, in one unified list. No local/remote split — a repo is a repo.

### Layout: Sidebar + Detail

```
┌──────────────────┬──────────────────────────────────────┐
│ REPOSITORIES     │                                      │
│ ─────────────    │  tio-api                             │
│ 🔍 Search...     │  github.com/org/tio-api              │
│                  │  main (2 ahead, 1 behind) ✓ cloned   │
│ ★ tio-api     ● │  ─────────────────────────────────── │
│ ★ tio-front   ● │                                      │
│   kitchen-sink   │  [Branches] [Activity] [RAG] [Skills]│
│   my-side-proj   │                                      │
│                  │  BRANCHES & WORKTREES                 │
│ ─────────────    │  main ................ up to date     │
│ + Add Repository │  feature/auth ........ agent working  │
│                  │    └─ worktree (Mac Studio, 67%)      │
│                  │  fix/search-bug ....... PR #42 open   │
│                  │    └─ worktree (local, idle)          │
│                  │                                      │
│                  │  RECENT ACTIVITY                      │
│                  │  • Chain "Add auth" completed 2h ago  │
│                  │  • PR #41 merged 5h ago               │
│                  │  • RAG re-indexed 1h ago              │
│                  │                                      │
│                  │  [Run Agent Task] [Create Branch]     │
└──────────────────┴──────────────────────────────────────┘
```

### Unified Repository Model

A single repository concept that aggregates:

| Attribute | Source | Notes |
|-----------|--------|-------|
| Name | Git / GitHub | Display name |
| Remote URL | Git remote / GitHub API | Canonical identifier |
| Local path | `LocalRepositoryPath` | Where it's cloned (if at all) |
| GitHub metadata | `GitHubFavorite` | Stars, PRs, issues |
| Clone status | Filesystem check | Cloned / Not cloned / Stale |
| RAG status | RAG store | Indexed / Not indexed / Stale |
| Tracked status | `TrackedRemoteRepo` | Auto-pull config |
| Active work | `AgentManager` chains | Running chains / worktrees |
| Worktrees | Git worktree list | Active branches |
| Pull requests | GitHub API | Open PRs for this repo |
| Skills | `RepoGuidanceSkill` | Repo-specific agent guidance |

**Key insight:** The repo's remote URL (normalized) is the join key. `SyncedRepository.remoteURL` = `TrackedRemoteRepo.remoteURL` = `GitHubFavorite.fullName` = `RepoRegistry` entry.

### Repository Detail Tabs

Each repository's detail pane has sub-tabs:

#### Branches (default)
- All local branches + their tracking status
- Active worktrees with agent status
- PRs associated with branches
- Quick actions: create branch, run agent on branch, open in VS Code

#### Activity
- Chain runs targeting this repo (from `MCPRunRecord`)
- Pull history (from `TrackedRemoteRepo`)
- PR activity (from GitHub API)
- Timeline view, most recent first

#### RAG
- Index status (chunks, last indexed, staleness)
- Search scoped to this repo
- Analysis results (patterns, hotspots, duplicates)
- One-click re-index

#### Skills
- Repo-specific guidance skills
- Framework detection status
- Skill editor

### Adding Repositories

One "Add Repository" flow that handles all cases:

1. **Clone from GitHub** — Pick from your GitHub repos, clone locally, auto-track
2. **Open Local** — Browse to existing clone, auto-detect remote
3. **Track Remote** — Just track a GitHub repo (no clone), view PRs/issues
4. **Detect Workspace** — Point to a directory with multiple repos (monorepo / workspace)

The distinction between "local" and "remote" becomes an attribute, not a navigation choice.

### Repository Status Indicators

Each repo in the sidebar shows at-a-glance status:

- 🟢 Green dot = agents actively working
- 🔵 Blue dot = RAG indexed and current
- 🟡 Yellow dot = needs pull / stale index
- ⚪ Gray = no activity, not indexed

---

## Tab 2: Activity (The Dashboard)

### Concept
What's happening right now, across all repos and workers. This replaces the scattered chain/worktree/swarm views.

### Layout

```
┌─────────────────────────────────────────────────────────┐
│  ACTIVITY                                               │
│                                                         │
│  RUNNING NOW                           WORKERS          │
│  ───────────                           ───────          │
│  🔄 "Add authentication" on tio-api    💻 This Mac ✓   │
│     Step 3/5 · implement · 67%         🖥️ Mac Studio ✓ │
│     Worker: Mac Studio                    └ working on  │
│     [View] [Pause] [Cancel]                 tio-api     │
│                                                         │
│  🔍 Indexing kitchen-sink              📊 Cluster      │
│     87% · 4,200/4,800 chunks             2 online      │
│                                           0 offline     │
│  📥 Pulling tio-front-end                               │
│     origin/main → local                                 │
│                                                         │
│  RECENT                                                 │
│  ──────                                                 │
│  ✅ "Fix search bug" on kitchen-sink    2h ago          │
│     4 files changed · PR #87 created                    │
│  ✅ RAG re-indexed tio-api              3h ago          │
│  ❌ "Refactor auth" on tio-front        5h ago          │
│     Gate rejected: tests failed                         │
│                                                         │
│  [Run New Task]  [View Chain History]                    │
└─────────────────────────────────────────────────────────┘
```

### What Lives Here

| Content | Previously In | Why It Fits |
|---------|--------------|-------------|
| Running chains | Agents sidebar + detail | Active work = activity |
| Chain history | Agents > Chain History | Past activity |
| Worktree operations | Agents > Parallel Worktrees | Active work = activity |
| RAG indexing progress | Agents > Local RAG | Background activity |
| Repo pull status | Repositories > Remote | Background activity |
| Swarm workers | Swarm tab | Workers doing the activity |
| Worker messages | Swarm Console > Chat tab | Communication about activity |
| Swarm Console | Activity > inline detail view | Full swarm management without leaving Activity |

### Workers Panel (Right Side)

Always-visible panel showing:
- This machine's status (role, current task)
- Connected LAN peers
- Firestore/WAN workers
- Per-worker: what repo they're working on, current task

Replaces the entire Swarm tab.

### Activity Filtering

- Filter by repo
- Filter by status (running / completed / failed)
- Filter by worker
- Time range

---

## Settings (Window, Not Tab)

### Concept
Everything that isn't "repositories" or "activity" goes in the Settings window (Cmd+,). This is already partially implemented — just needs consolidation.

### Settings Tabs

| Tab | Contains | Previously In |
|-----|---------|--------------|
| **General** | Default repo, auto-pull interval, theme | Scattered |
| **Connections** | Copilot status, Claude status, GitHub auth | Agents sidebar |
| **MCP Server** | Enable/disable, port, VS Code config | Settings + Agents sidebar |
| **RAG** | Provider (MLX/CoreML), model, reranker config | Agents > Local RAG |
| **Swarm** | Role, auto-start, display name, Firebase config | Swarm tab header |
| **VM Isolation** | Linux/macOS VM config, pools | Agents > VM Isolation |
| **Feature Flags** | Brew, PII Scrubber, Docling, Translations | Settings |
| **Advanced** | Template gallery, dependency graph, local chat | Agents sidebar |

### What Stays Accessible From Main UI

- **"Run Agent Task" button** — Available in both Repositories (scoped to selected repo) and Activity. Opens the chain creation sheet (currently `NewChainSheet`).
- **RAG search** — Cmd+K style global search overlay, not hidden in a tab.
- **Worker status** — Always visible in Activity tab.

---

## Data Model Unification

### New: `UnifiedRepository` (View Model, Not @Model)

Don't change the underlying SwiftData models — instead create a unified view model that aggregates them:

```swift
@MainActor
@Observable
class UnifiedRepository: Identifiable {
  let id: String  // Normalized remote URL or local path
  
  // Identity
  var name: String
  var remoteURL: String?
  var localPath: String?
  
  // Aggregated state
  var cloneStatus: CloneStatus    // .cloned, .notCloned, .stale
  var ragStatus: RAGStatus        // .indexed(chunks, lastDate), .notIndexed, .stale
  var pullStatus: PullStatus      // .upToDate, .behind(n), .pulling, .error
  var activeChains: [ChainInfo]   // Currently running
  var worktrees: [WorktreeInfo]   // Active worktrees
  var recentActivity: [ActivityItem]
  
  // Links to underlying models
  var syncedRepository: SyncedRepository?
  var gitHubFavorite: GitHubFavorite?
  var trackedRemoteRepo: TrackedRemoteRepo?
  var localRepositoryPath: LocalRepositoryPath?
  
  // Derived
  var isFavorite: Bool { gitHubFavorite != nil }
  var isTracked: Bool { trackedRemoteRepo != nil }
  var isCloned: Bool { localPath != nil }
  var hasActiveWork: Bool { !activeChains.isEmpty }
  
  enum CloneStatus { case cloned, notCloned, stale }
  enum RAGStatus { 
    case indexed(chunks: Int, lastIndexed: Date)
    case indexing(progress: Double)
    case notIndexed
    case stale(chunks: Int, lastIndexed: Date)
  }
  enum PullStatus { case upToDate, behind(Int), pulling, error(String), unknown }
}
```

### `RepositoryAggregator` Service

A new service that:
1. Observes all SwiftData models (`SyncedRepository`, `GitHubFavorite`, `TrackedRemoteRepo`, `LocalRepositoryPath`)
2. Queries `RepoRegistry`, `AgentManager`, RAG status
3. Produces a single `[UnifiedRepository]` array
4. Updates reactively when any source changes

```swift
@MainActor
@Observable
class RepositoryAggregator {
  var repositories: [UnifiedRepository] = []
  
  func refresh(
    syncedRepos: [SyncedRepository],
    favorites: [GitHubFavorite],
    trackedRepos: [TrackedRemoteRepo],
    localPaths: [LocalRepositoryPath],
    ragRepos: [RAGRepoStatus],
    activeChains: [AgentChain]
  ) {
    // Join on normalized remote URL
    // Merge all attributes into UnifiedRepository instances
    // Sort by: has active work > is favorite > recently accessed
  }
}
```

---

## Navigation Architecture (New)

### macOS

```swift
enum PeelTab: String, CaseIterable, Identifiable {
  case repositories
  case activity
  
  var id: String { rawValue }
  var title: String { ... }
  var icon: String { ... }
}

struct ContentView: View {
  @AppStorage("selectedTab") private var selectedTab: PeelTab = .repositories
  
  var body: some View {
    Group {
      switch selectedTab {
      case .repositories: RepositoriesView()
      case .activity: ActivityView()
      }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Tab", selection: $selectedTab) {
          ForEach(PeelTab.allCases) { tab in
            Label(tab.title, systemImage: tab.icon).tag(tab)
          }
        }
        .pickerStyle(.segmented)
      }
    }
  }
}
```

### iOS

```swift
TabView(selection: $selectedTab) {
  Tab("Repositories", systemImage: "tray.full.fill", value: .repositories) {
    RepositoriesView()
  }
  Tab("Activity", systemImage: "bolt.fill", value: .activity) {
    ActivityView()
  }
}
```

### Global Shortcuts

- **Cmd+K** — Global RAG search (searches across all indexed repos)
- **Cmd+N** — New agent task (opens chain creation scoped to selected repo)
- **Cmd+1** — Repositories tab
- **Cmd+2** — Activity tab
- **Cmd+,** — Settings

---

## Migration Strategy

### Phase 0: Foundation (Non-Breaking) ✅ COMPLETE
**Goal:** Build the new data layer without changing any UI.

1. ✅ Create `UnifiedRepository` view model — `Shared/Models/UnifiedRepository.swift`
2. ✅ Create `RepositoryAggregator` service — `Shared/Services/RepositoryAggregator.swift`
3. ✅ Create `ActivityFeed` service — `Shared/Services/ActivityFeed.swift` + `Shared/Models/ActivityItem.swift`
4. ⬜ Add tests for aggregation logic
5. ✅ Wire into `PeelApp.swift` as environment objects

**Completed:** March 4, 2026

### Phase 1: New Repositories View ✅ COMPLETE
**Goal:** Replace the current Repositories tab with the unified view.

1. ✅ Build `UnifiedRepositoriesView` with sidebar + detail — `Shared/Applications/UnifiedRepositoriesView.swift`
2. ✅ Build repository detail with sub-tabs (Branches, Activity, RAG, Skills) — `Shared/Applications/RepoDetailView.swift`
3. ✅ Port `Git_RootView` branch/commit UI into Branches sub-tab — Embeds real `GitRootView` (to be reworked in Phase 6A)
4. ⬜ Port `Github_RootView` favorites/PRs into the sidebar as attributes
5. ✅ RAG sub-tab: real Index/Search/Analyze/Enrich actions wired to MCPServerService
6. ✅ RAG sub-tab: AI Analysis & Enrichment pipeline buttons (Analyze → Enrich)
7. ✅ RAG sub-tab: Lessons display from MCPServerService
8. ⬜ Port `TrackedReposView` auto-pull config into repository settings sheet
9. ✅ Wire "Add Repository" unified flow — Open Local (NSOpenPanel) + Track Remote (URL input)
10. ✅ Skills sub-tab wired to DataService with expandable rows, Show Inactive toggle
11. ✅ Default detail pane shows cross-repo RAG overview — `Shared/Applications/RAGOverviewDetailView.swift`
    - Expandable repo cards with analysis progress, skills, lessons
    - Analyze/Enrich action buttons per repo
    - Global RAG search

**Completed:** March 4, 2026

### Phase 2: Activity View ✅ COMPLETE
**Goal:** Replace the Agents tab's chain/worktree views with a unified Activity view.

1. ✅ Build `ActivityDashboardView` with running/recent sections — `Shared/Applications/ActivityDashboardView.swift`
2. ✅ Build workers panel (Swarm section always visible with start button)
3. ✅ Chain drill-down — Tappable chain cards open `ChainDetailView` sheet (macOS)
4. ⬜ Port `ParallelWorktreeDashboardView` into activity items
5. ✅ Filtering by repo — Repo filter menu in toolbar
6. ✅ "Run New Task" button visible
7. ✅ RAG Indexing progress section

**Completed:** March 4, 2026

### Phase 3: Remove Old Tabs ✅ COMPLETE
**Goal:** Simplify navigation to just two tabs.

1. ✅ Replaced navigation with 2-tab layout (Repositories + Activity) in `macOS/ContentView.swift`
2. ✅ Updated `CommonToolbarItems.swift` with 2-segment toolbar
3. ⬜ Move remaining Agents sidebar items to Settings:
   - VM Isolation → Settings > VM Isolation
   - MCP Dashboard → Settings > MCP Server (or Activity > System)
   - Template Gallery → "Run New Task" dialog
   - Local Chat → Floating panel accessible from anywhere (Cmd+Shift+C)
   - CLI Setup → Settings > Connections
4. ✅ `CurrentTool` enum reduced to 2 cases + optional Brew
5. ✅ MCP UI automation controls consolidated — `MCPUIAutomationProvider` updated with `repositories` + `activity` view IDs, backward-compatible legacy mappings

**Note:** Old tabs removed; some sidebar items still need migration to Settings.

**Completed:** March 4, 2026

### Phase 4: Polish ✅ MOSTLY COMPLETE
**Goal:** Make it feel finished.

1. ⬜ Onboarding flow update (new FeatureDiscoveryView for 2-tab layout) ✅ DONE (March 5)
2. ✅ Empty states for key views (activity, RAG, repos)
3. ✅ Keyboard shortcuts — Cmd+1 (Repos), Cmd+2 (Activity), Cmd+K (Search)
4. ✅ MCP tool updates for new view IDs — `MCPUIAutomationProvider` fully updated
5. ✅ iOS layout — Rewritten to 2-tab (Repositories + Activity) in `iOS/ContentView.swift`
6. ⬜ Accessibility audit
7. ✅ Cmd+K global RAG search overlay — `Shared/Views/CommandPaletteView.swift`
8. ✅ Port branch/commit views into Branches sub-tab — Embeds `GitRootView` for cloned repos
9. ⬜ Port GitHub favorites/PRs into sidebar attributes
10. ✅ Activity filtering by repo
11. ✅ Chain drill-down from Activity dashboard — Tappable cards → `ChainDetailView` sheet
12. ⬜ Settings consolidation window (Cmd+,)

**Completed:** March 4, 2026

### Phase 5: Experimental Features Surface
**Goal:** Provide discoverability for features not yet surfaced in the 2-tab layout.

**Problem:** The UX overhaul simplified navigation from 5 tabs to 2, which is great for focus. But several features are now completely hidden with no way to reach them:
- **PII Scrubber** — Was in Agents sidebar
- **VM Isolation** (Linux/macOS VMs, Pools) — Was in Agents sidebar
- **Docling Import** — Was in Agents sidebar
- **Translation Validation** — Was in Agents sidebar
- **Local Chat** — Was in Agents sidebar
- **MCP Dashboard / Template Gallery** — Was in Agents sidebar
- **Dependency Graph** — Was in Agents sidebar

**Options (pick one or combine):**

#### Option A: Settings > Labs Tab
Move all experimental features into a "Labs" or "Feature Flags" tab in the Settings window (Cmd+,). Features enabled here could surface as:
- A "Labs" section in the Activity sidebar
- Additional sub-tabs in the repo detail
- Menu bar items

```
Settings > Labs
  ├── PII Scrubber         [Enable] → Adds tool to repo context menu
  ├── VM Isolation          [Enable] → Adds VM tab to Activity
  ├── Docling Import        [Enable] → Adds import action
  ├── Translation Checker   [Enable] → Adds check action
  └── Local Chat            [Enable] → Adds Cmd+Shift+C panel
```

#### Option B: "More Tools" Overflow in Toolbar
Add a `...` menu in the toolbar that lists all available tools/features not in the main tabs. Discoverable but not cluttering the primary UI.

#### Option C: Command Palette Integration
Extend the Cmd+K palette to include actions (not just RAG search):
- Type "pii" → "Run PII Scrubber on tio-api"
- Type "vm" → "Open VM Isolation"
- Type "chat" → "Open Local Chat"

This makes every feature discoverable via keyboard without adding UI chrome.

#### Option D: Activity > System Section
Add a "System" or "Tools" section at the bottom of the Activity dashboard that shows:
- MCP server status + dashboard link
- VM status (if enabled)
- Active background tools

**Recommended approach:** **A + C combined** — Settings > Labs for enable/disable + Cmd+K actions for quick access. This keeps the primary UI clean while making everything findable.

**Tasks:**
1. ✅ Add "Labs" tab to Settings window with feature toggles — `LabsToggleRow` rich descriptions
2. ✅ Extend CommandPaletteView to support action results — `CommandAction` model with nav + lab actions
3. ✅ Labs toolbar item (beaker menu) for quick access — `Shared/Views/LabsToolbarItem.swift`
4. ⬜ Wire enabled lab features into appropriate surfaces (repo context menus, Activity sections)
5. ⬜ Move MCP Dashboard into Settings > MCP Server tab
6. ⬜ Move VM Isolation into Settings > VM Isolation tab
7. ⬜ Add Local Chat as floating panel (Cmd+Shift+C)

**Partially Complete:** March 4, 2026

### Phase 5b: Activity Dashboard Polish ✅ COMPLETE
**Goal:** Make the Activity dashboard fully functional with templates, worktrees, and detail views.

1. ✅ Template browser sheet — `Shared/Views/TemplateBrowserSheet.swift`
   - Category picker (core/specialized/yolo), search, template cards with step pills
   - Run panel with prompt field, kicks off chains via `handleChainRun`
2. ✅ Activity item detail sheet — `Shared/Views/ActivityItemDetailSheet.swift`
   - Universal detail for any ActivityItem kind (chain, pull, RAG, worktree, PR, swarm, info)
   - Per-kind content with relevant data and actions
3. ✅ Running worktrees visible in Running Now section — `RunningWorktreeCard`
4. ✅ Quick templates section on dashboard — `QuickTemplateCard`
5. ✅ "Run Task" toolbar button wired to template browser
6. ✅ All activity rows tappable with universal navigation (not just chains)

**Completed:** March 4, 2026

### Phase 5c: Swarm Console + Activity Polish ✅ COMPLETE
**Goal:** Make swarm management accessible from Activity without leaving the tab, and handle long activity lists.

1. ✅ Swarm Console as inline detail view (not modal/sheet) — "Open Console" in Swarm section swaps dashboard to `SwarmManagementView` inline
2. ✅ Back button in toolbar to return from Swarm Console to dashboard
3. ✅ Animated transition between dashboard and console views
4. ✅ Chat tab in SwarmDetailView with Firebase messaging (SwarmMessagesView)
5. ✅ Broadcast composer and message timeline with sender/time/broadcast indicators
6. ✅ Recent Activity pagination (50 items/page with prev/next controls, page counter)
7. ✅ Auto-select first swarm and message listener lifecycle fixes
8. ✅ Feature Discovery checklist updated for 2-tab layout (Repositories + Activity)
9. ✅ Settings About description updated to match product positioning

**Completed:** March 5, 2026

### Phase 6: Repo Detail Tab Rework 🔄 IN PROGRESS
**Goal:** Modernize the repo detail sub-tabs to match the new dashboard design language. Currently these embed old views or use outdated layouts that create a jarring contrast.

**The Problem:**
When you select a repo, the detail pane should feel like a natural extension of the polished dashboard. Instead:
- **Branches tab** embeds the entire old `GitRootView` — a `NavigationSplitView` with its own sidebar, repo selector dropdown (redundant!), and old pre-overhaul design. It's navigation-inside-navigation.
- **RAG tab** uses dense `GroupBox` containers that don't match the card-based dashboard style
- **PRs** are scattered as minimal rows in the not-cloned fallback view — there's no proper PR sub-tab
- **Activity tab** is a flat list with no detail navigation or grouping
- **Skills tab** works but uses the same dense GroupBox pattern

#### 6A: Branches & PRs Tab Rework ✅ COMPLETE
**Current:** Inline card-based layout, no nested navigation.
**Completed:** March 4, 2026

**What was built:**
1. ✅ Removed embedded `GitRootView` — BranchesTabView now renders inline content directly
2. ✅ Local changes summary card (uncommitted changes count + status)  
3. ✅ Branch rows with tracking status, ahead/behind, current indicator, remote branches toggle
4. ✅ PR cards in dedicated `prsSection` with status badges, labels, CI checks
5. ✅ Worktree rows with branch, path, quick actions (Open in VS Code, Show in Finder)
6. ✅ Chain rows with status, steps, timing
7. ✅ For not-cloned repos: PR list + "Clone" CTA + tracking info
8. ✅ Quick actions: Open in Terminal, Open in VS Code, Open in Finder

**Files:** [RepoDetailView.swift](Shared/Applications/RepoDetailView.swift) (`BranchesTabView` struct, ~400 lines)

### Phase 7: Worktree Approval Chain + Agent PR Review ✅ COMPLETE
**Goal:** Surface worktree execution approval/reject/merge inline in the Branches tab, and add agent-powered PR review with structured assessment + GitHub actions.

**Completed:** March 4, 2026

**What was built:**

#### 7A: Worktree Approval Chain (inline in Branches tab)
- ✅ `WorktreeApprovalsSection` — appears when runs have pending approvals/merges
- ✅ `WorktreeRunApprovalCard` — progress bar, execution count, bulk Approve All / Merge All
- ✅ `InlineExecutionCard` — expandable per-execution card with:
  - Status icon, diff stats (files/insertions/deletions) inline in header
  - Expanded: description, chain step results (role/model/duration/cost), diff summary, RAG snippets
  - Action buttons: Approve / Reviewed / Reject (with reason) / Merge / Resolve Conflicts / Open Folder
- ✅ Active (non-review) runs section in Branches tab with progress bars

**Files:** [WorktreeApprovalViews.swift](Shared/Applications/WorktreeApprovalViews.swift) (~420 lines)

#### 7B: Agent PR Review
- ✅ `PRRowWithReview` — replaces old `RepoPRRow` with sparkles "Review" button on open PRs
- ✅ `PRReviewSheet` — template picker (Standard PR Review / Deep PR Review)
  - Dispatches chain via `handleChainRun`, polls for results (up to 120s)
  - Structured result display: verdict banner, risk level, summary, issues list, suggestions, CI status
  - Action buttons: Approve on GitHub, Post Review, Request Changes, Fix with Agent
  - Raw output disclosure, error state with retry
- ✅ `PRReviewState` — @Observable state machine managing loading/polling/result lifecycle

**Files:** [PRReviewViews.swift](Shared/Applications/PRReviewViews.swift) (~530 lines)

#### 7C: BranchesTabView Integration
- ✅ `MCPServerService` environment wired into BranchesTabView
- ✅ Computed `repoRuns`, `pendingApprovalRuns`, `activeRuns` filtered by repo path
- ✅ Approval section + active runs section inserted between local changes and branches
- ✅ PRs section uses `PRRowWithReview` for all repos (cloned + remote-only)

#### 6B: RAG Tab Modernization ⬜ NEXT
**Current:** Dense `GroupBox` containers (`RAGTabView`) — functional but visually inconsistent with dashboard
**New:** Card-based layout matching dashboard style.

Layout:
```
┌─────────────────────────────────────────────────────┐
│ ┌── INDEX STATUS ──────────────────────────────┐    │
│ │ ✅ Indexed · 4,200 chunks · nomic-embed      │    │
│ │ Last indexed: 2 hours ago                    │    │
│ │ [Re-Index] [Force Re-Index]                  │    │
│ └──────────────────────────────────────────────┘    │
│                                                     │
│ 🔍 Search this repo...          [Vector ▾] [→]     │
│ ┌── Results ───────────────────────────────────┐    │
│ │ 92% src/auth/handler.swift L42-L67           │    │
│ │ 85% src/models/user.swift L12-L30            │    │
│ └──────────────────────────────────────────────┘    │
│                                                     │
│ ── PIPELINE ──────────────────────────────────────  │
│ [Index ✅] ──→ [Analyze 67%] ──→ [Enrich ⬜]       │
│                                                     │
│ ── LESSONS (12) ──────────────────────────────────  │
│ 🟢 95% "Use async/await over Combine"              │
│ 🟢 87% "Prefer @Observable over ObservableObject"  │
│ 🟡 45% "Consider extracting to extension"          │
└─────────────────────────────────────────────────────┘
```

Tasks:
1. ⬜ Hero status card (indexed state, chunks, model, freshness)
2. ⬜ Prominent inline search bar (not buried in GroupBox)
3. ⬜ Visual pipeline indicator: Index → Analyze → Enrich with step states
4. ⬜ Lesson cards with confidence indicators
5. ⬜ Match card styling from `ActivityDashboardView`

#### 6C: Activity Tab Enhancement ⬜
**Current:** Flat list of `RepoActivityItemRow`
**New:** Grouped timeline with detail navigation.

Tasks:
1. ⬜ Group by day (Today, Yesterday, This Week, Older)
2. ⬜ Tappable items open `ActivityItemDetailSheet`
3. ⬜ Filter by activity type
4. ⬜ Visual timeline connector between items

#### 6D: Skills Tab Polish ⬜
**Current:** `SkillsTabView` with GroupBox rows
**New:** Card-based skill cards with better visual hierarchy.

Tasks:
1. ⬜ Skill cards matching dashboard style
2. ⬜ Add/Edit skill capability (not just view)
3. ⬜ Visual priority indicator (heat bar or colored badge)

---

## What Happens to Each Current Feature

| Current Feature | New Home | Status | Notes |
|----------------|----------|--------|-------|
| Git branch/commit view | Repositories > Repo > Branches | ✅ Done | Inline card-based, no nested nav |
| GitHub favorites | Repositories sidebar (★ indicator) | ✅ Done | Filter chip, star badge in sidebar |
| GitHub PRs | Repositories > Repo > Branches (PRs section) | ✅ Done | Enhanced with agent review button |
| PR review by agent | Repositories > Repo > Branches > PR "Review" | ✅ Done | NEW: Chain-powered assessment + GitHub actions |
| Recent PRs | Activity (recent section) | ✅ Done | Mixed into activity items |
| Tracked repos (auto-pull) | Repositories > Repo settings | ⬜ Partial | Visible in sidebar but no settings sheet |
| Agent chains | Activity (running/recent) | ✅ Done | Cards with drill-down to ChainDetailView |
| Chain templates | "Run New Task" dialog | ✅ Done | TemplateBrowserSheet + quick templates |
| Chain history | Activity (recent, filterable) | ✅ Done | Part of recent activity section |
| Parallel worktrees | Repo > Branches (approval section) + Activity | ✅ Done | Inline approval chain + active runs |
| Worktree management | ~~Repositories > Repo > Branches~~ | ⚠️ Partial | Per-repo worktrees shown, global list missing |
| Local RAG | Repositories > Repo > RAG | ✅ Done | Functional but needs visual modernization (6B) |
| RAG search | Cmd+K global overlay | ✅ Done | Cross-repo vector+text search |
| Dependency graph | ~~Repositories > Repo > RAG > Analysis~~ | ❌ Hidden | No path in new UX |
| Skills | Repositories > Repo > Skills | ✅ Done | View + show inactive toggle |
| Local chat | ~~Floating panel (Cmd+Shift+C)~~ | ❌ Hidden | Never built |
| MCP Activity | ~~Settings > MCP Server~~ | ❌ Hidden | Only enable/port/tools in Settings |
| Copilot/Claude status | ~~Settings > Connections~~ | ❌ Hidden | No connections tab in Settings |
| VM Isolation | Labs toolbar / Cmd+K | ✅ Done | Feature-flagged, opens as sheet |
| PII Scrubber | Labs toolbar / Cmd+K | ✅ Done | Feature-flagged, opens as sheet |
| Docling Import | Labs toolbar / Cmd+K | ✅ Done | Feature-flagged, opens as sheet |
| Translation Validation | Labs toolbar / Cmd+K | ✅ Done | Feature-flagged, opens as sheet |
| Swarm workers | Activity > Workers panel | ✅ Done | Always-visible section |
| Swarm management | Activity > Swarm > Open Console (inline) | ✅ Done | Full console with sidebar + detail |
| Swarm chat / messaging | Activity > Swarm > Open Console > Chat tab | ✅ Done | Firebase-backed messaging |
| Swarm config | ~~Settings > Swarm~~ | ⬜ Not done | No Swarm settings tab yet |
| Brew | Labs toolbar (if enabled, own tab) | ✅ Done | Feature-flagged |
| Workspaces tab | Eliminated | ✅ Done | Concept absorbed into repos |
| Feature Discovery | ~~Updated for new layout~~ | ✅ Updated | Reflects 2-tab layout, new feature locations |
| Session Summary | ~~Agents header~~ | ❌ Hidden | No trigger in new UX |

---

## MCP Tool Compatibility

### New View IDs
```
repositories        → Unified repositories list
repositories.detail → Selected repository detail  
activity            → Activity dashboard
activity.workers    → Workers panel
```

### New Controls
```
repositories.select(repoId)     → Select a repository
repositories.add                → Add repository flow
repositories.detail.tab(name)   → Switch detail sub-tab
activity.filter(repo|status)    → Filter activity
activity.runTask                → Open new task dialog
```

### Deprecated (With Migration)
```
agents.*           → Route to activity.* or repositories.detail.*
workspaces.*       → Route to repositories.detail.branches
git.*              → Route to repositories (local scope)
github.*           → Route to repositories (remote scope)
swarm.*            → Route to activity.workers
```

---

## Success Criteria

A new user who:
1. Opens Peel for the first time
2. Has never seen the app before
3. Should within 60 seconds understand:
   - "This is where I manage my code repositories"
   - "I can see what AI agents are doing to my code"
   - "I can tell agents to do things to my repos"
   - "I can see my team's machines collaborating"

### Measurable Goals
- **Tab count:** 5 → 2 (+ Settings window)
- **Agents sidebar items:** 13+ → 0 (eliminated, contents distributed)
- **Steps to start an agent task:** Currently ~4 (switch to Agents, click chain, configure, run) → 2 (select repo, click "Run Task")
- **Steps to see RAG status:** Currently 3 (switch to Agents, click Local RAG, find repo) → 1 (select repo, see RAG sub-tab)

---

## Feature Accessibility Audit (March 4, 2026)

This tracks where every old feature lives in the new UX and whether it's actually reachable.

### ✅ Fully Accessible Features
| Feature | Old Location | New Location | How to Reach |
|---------|-------------|-------------|--------------|
| Git branches / commits | Repositories > Local > GitRootView | Repositories > Repo > Branches tab | Select repo → Branches (default tab) |
| GitHub PRs | Repositories > Remote > Recent PRs | Repositories > Repo > Branches tab (PRs section) | Select repo → scroll to PRs |
| PR review by agent | N/A (new) | Repositories > Repo > Branches > PR row → "Review" button | Click sparkles icon on any open PR |
| Worktree approval chain | Agents > Parallel Worktrees | Repositories > Repo > Branches tab (top section) | Auto-appears when runs have pending approvals |
| RAG index / search / analyze | Agents > Local RAG | Repositories > Repo > RAG tab | Select repo → RAG tab |
| RAG overview (cross-repo) | Agents > Local RAG | Repositories > (no repo selected) → RAG Overview | Default detail when no repo selected |
| Skills management | N/A (was hidden) | Repositories > Repo > Skills tab | Select repo → Skills tab |
| Per-repo activity | N/A | Repositories > Repo > Activity tab | Select repo → Activity tab |
| Running chains | Agents sidebar | Activity > Running Now | Switch to Activity tab |
| Chain history | Agents > Chain History | Activity > Recent | Switch to Activity tab, scroll down |
| Worktree operations | Agents > Parallel Worktrees | Activity > Running Now + Repo > Branches | Both surfaces show active worktrees |
| Swarm workers | Swarm tab | Activity > Swarm section | Always visible in Activity |
| Run new task / templates | Agents sidebar | Activity > Templates section + "Run Task" toolbar | Click "Run Task" or browse templates |
| Chain detail view | Agents > Chain detail | Activity > tap chain card → sheet | Tap any chain in Activity |
| Brew | Brew tab | Labs toolbar → Homebrew | Enable in Settings, access via beaker menu |
| PII Scrubber | Agents sidebar (feature-flagged) | Labs toolbar / Cmd+K | Enable in Settings, access via beaker or Cmd+K |
| Docling Import | Agents sidebar (feature-flagged) | Labs toolbar / Cmd+K | Enable in Settings, access via beaker or Cmd+K |
| Translation Validation | Agents sidebar (feature-flagged) | Labs toolbar / Cmd+K | Enable in Settings, access via beaker or Cmd+K |
| VM Isolation | Agents sidebar (feature-flagged) | Labs toolbar / Cmd+K | Enable in Settings, access via beaker or Cmd+K |
| Global RAG search | Buried in Agents sidebar | Cmd+K overlay | Keyboard shortcut from anywhere |
| Keyboard shortcuts | N/A | Cmd+1 (Repos), Cmd+2 (Activity), Cmd+K (Search) | Always available |
| Repo favorites | GitHub tab | Sidebar ★ indicators + "Favorites" filter | Filter chips in repo sidebar |
| Tracked repos (auto-pull) | Repositories > Remote > Tracked | Sidebar "Tracked" filter | Filter chip, per-repo badge |
| Add repo (clone / track) | Multiple places | Repositories > "+" button → Add sheet | Unified flow: Open Local / Track Remote |

### ⚠️ Reduced / Degraded Features
| Feature | Old Capability | Current State | Gap |
|---------|---------------|---------------|-----|
| **MCP Dashboard** | Full dashboard (active requests, tool list, connection log) | MCP settings tab has enable/port/tools | Lost: real-time request activity view, connection log |
| **Chain History** | Dedicated list view with filtering | Activity "Recent" section shows chains mixed with other items | Less focused; no chain-specific filtering yet |
| **Parallel Worktrees Dashboard** | Full dashboard with filtering, bulk ops, detailed execution view | Inline in Branches tab + Activity Running Now | Lost: global cross-repo worktree dashboard, filtering by worker/status |
| **Dependency Graph** | Full D3-powered visualization | Not surfaced anywhere | Completely hidden — was niche but useful for analysis |
| **Local Chat** | Sidebar item → chat view | Not surfaced anywhere | Completely hidden — no floating panel built yet |
| **Worktree Management** | Dedicated worktree list, create/delete | Branches tab shows repo worktrees, Activity shows running | Lost: global worktree list across all repos, cleanup tools |

### ❌ Features With No Path
| Feature | Old Location | Issue | Priority |
|---------|-------------|-------|----------|
| **MCP Activity Dashboard** | Agents > MCP Dashboard | No way to see live MCP request traffic | Medium — useful for debugging |
| **Dependency Graph** | Agents > Dependency Graph | D3 visualization completely unreachable | Low — niche feature |
| **Local Chat** | Agents > Local Chat | Floating panel never built | Medium — planned as Cmd+Shift+C |
| **CLI Setup / Connections** | Agents > Connections | Copilot/Claude status not visible in new UX | Low — one-time setup |
| **Template Gallery** (full) | Agents > Template Gallery | TemplateBrowserSheet exists but full gallery with categories not easily browsable | Low — templates in Activity are sufficient |
| **Session Summary** | Agents header | No way to trigger in new UX | Low — rarely used |
| **Global Worktree List** | Agents > Worktrees | No cross-repo worktree management view | Medium — useful for cleanup |

---

## Next Steps (Session Handoff — March 4, 2026)

### Immediate Priority: Don't Lose Features

The new UX is significantly cleaner but some functional features are harder to reach or completely hidden. The priority order:

#### Priority 1: Surface Hidden Functional Features
These features work but have no navigation path in the 2-tab layout.

1. **MCP Dashboard → Settings or Activity**
   - Option A: Add MCP status section to Activity (request count, connection status)
   - Option B: Full MCP Dashboard as Settings tab (like it was before but in Settings window)
   - Lean toward: **Both** — summary in Activity, full in Settings

2. **Local Chat → Floating Panel**
   - Build as Cmd+Shift+C floating panel (already planned)
   - Can scope to selected repo or be global
   - Alternative: Add as 5th repo detail tab ("Chat") scoped to that repo

3. **Connections (Copilot/Claude) → Settings**
   - Add "Connections" tab to Settings with Copilot/Claude status + setup
   - Or: status indicators in Activity tab header (green/red dots)

4. **Global Worktree Management**
   - Option A: Add "Worktrees" filter/section to Activity tab
   - Option B: Surface in Cmd+K as "Manage Worktrees" action
   - Lean toward: **Activity > filter by worktrees** since worktrees are activity

#### Priority 2: Visual Consistency (Phase 6B-6D)
The remaining repo detail tabs still use old GroupBox layouts that feel jarring next to the polished Branches tab.

5. **RAG Tab Modernization** (6B)
   - Hero status card, prominent search bar, visual pipeline (Index → Analyze → Enrich)
   - Lesson cards with confidence indicators
   - Match card styling from ActivityDashboardView

6. **Activity Tab Enhancement** (6C)
   - Group by day (Today, Yesterday, This Week)
   - Tappable items → ActivityItemDetailSheet
   - Filter by type
   
7. **Skills Tab Polish** (6D)
   - Card-based skill display
   - Add/edit capability (currently view-only)

#### Priority 3: Polish & Completeness

8. **Settings Consolidation**
   - Build proper Settings window with tabs: General, Connections, MCP, RAG, Swarm, VM, Labs
   - Currently SettingsView only has MCP tab
   - Move remaining Agents sidebar items here

9. **Onboarding Update**
   - `FeatureDiscoveryChecklistView` still references old 5-tab layout
   - Update for 2-tab layout + explain Labs toolbar + Cmd+K

10. **Port GitHub Favorites/PRs into sidebar** (Phase 1 item 4, Phase 4 item 9)
    - Show star count, open PR count, last activity as sidebar attributes
    - Add "Track Remote" config into repo settings sheet

11. **Dependency Graph**
    - Either add to RAG tab as "Analysis > Dependencies" section
    - Or add as Labs feature (since it's niche)
    - Or surface via Cmd+K action

### Implementation Notes for Next Session

**Files to know:**
- [macOS/ContentView.swift](macOS/ContentView.swift) — Top-level 2-tab routing
- [Shared/Applications/UnifiedRepositoriesView.swift](Shared/Applications/UnifiedRepositoriesView.swift) — Repo sidebar + detail routing
- [Shared/Applications/RepoDetailView.swift](Shared/Applications/RepoDetailView.swift) — 4 sub-tabs (Branches, Activity, RAG, Skills)
- [Shared/Applications/ActivityDashboardView.swift](Shared/Applications/ActivityDashboardView.swift) — Activity dashboard
- [Shared/Applications/WorktreeApprovalViews.swift](Shared/Applications/WorktreeApprovalViews.swift) — NEW: Worktree approval chain views
- [Shared/Applications/PRReviewViews.swift](Shared/Applications/PRReviewViews.swift) — NEW: Agent PR review views
- [Shared/Views/LabsToolbarItem.swift](Shared/Views/LabsToolbarItem.swift) — Labs beaker menu
- [Shared/Views/CommandPaletteView.swift](Shared/Views/CommandPaletteView.swift) — Cmd+K overlay
- [Shared/Views/SettingsView.swift](Shared/Views/SettingsView.swift) — Settings (currently MCP only)
- [Shared/Applications/Agents_RootView.swift](Shared/Applications/Agents_RootView.swift) — OLD: Reference for features that need migration

**Build verified:** ✅ All current code compiles (March 4, 2026)
**Xcode project:** Uses `PBXFileSystemSynchronizedRootGroup` for `Shared/` — new files auto-discovered, no manual project file edits needed

**Suggested session approach:**
1. Start with Priority 1 items — surface hidden features so nothing is lost
2. Then tackle 6B (RAG tab) as the most visually jarring remaining tab
3. Settings consolidation can happen in parallel since it's a separate window

---

## Continuation Plan: Multi-Agent Execution + Enterprise PR Review (March 4, 2026)

The UX foundation is now good enough to start the next product layer: **enterprise-scale execution and review orchestration**.

### Phase 8: Multi-Agent Job Orchestration at Scale 🔄 IN PROGRESS
**Goal:** Send one Peel job and have it fan out to many agents/workers safely, with predictable throughput and explicit human approval gates.

#### 8A: Unified Job Spec + Routing
Define a normalized `PeelJob` envelope that can be dispatched to local parallel runners, LAN swarm workers, and WAN workers with the same lifecycle states.

Required fields:
- `jobId`, `repoIdentifier`, `repoPath` (when local), `taskType`, `templateId`
- `priority`, `deadline`, `maxConcurrency`, `requiredCapabilities`
- `reviewPolicy` (auto-merge disabled/enabled, human gate required, reviewer set)

Reuse/align:
- [Plans/DISTRIBUTED_TASK_TYPES_SPEC.md](Plans/DISTRIBUTED_TASK_TYPES_SPEC.md)
- [Shared/Distributed/BranchQueue.swift](Shared/Distributed/BranchQueue.swift)
- [Shared/Distributed/SwarmWorktreeManager.swift](Shared/Distributed/SwarmWorktreeManager.swift)

#### 8B: Worker Leasing + Backpressure
Add leasing semantics so tasks cannot be double-consumed and stale workers are reclaimed automatically.

Behavior:
- Lease timeout + heartbeat updates
- Requeue on timeout with retry budget
- Per-repo and global concurrency caps
- Worker capability matching (`swift`, `node`, `ios-sim`, `large-context`)

#### 8C: Execution Modes (Single, Batch, Map-Reduce)
Support three job modes from the same UI/API:
1. **Single** — one job, one execution
2. **Batch** — one prompt, N repos
3. **Map-Reduce** — fan-out edits + fan-in synthesis/review step

Surface in UI:
- Activity shows parent job and child executions
- Branches tab shows execution lineage and gate state

#### 8D: Approval and Merge Gates
Promote current inline approval chain into policy-driven gates:
- Auto-approve only when policy + checks pass
- Human review required for high-risk changes
- Merge blocked when conflict/failed-check labels exist

Acceptance criteria:
- Dispatch one job to `N` workers with no branch collisions
- Restart Peel during execution and recover queue/worktrees
- Show deterministic status transitions from queued → running → review → merged/closed

### Phase 9: Enterprise PR Review Hub ⬜ NEXT
**Goal:** A single place to see all enterprise PRs, assign agent reviewers, and decide approve/request changes/fix.

#### 9A: Enterprise PR Ingestion
Create an enterprise PR index that aggregates open PRs across orgs/repos into one list with paging + freshness timestamps.

Core columns:
- Repo, PR, author, age, size, CI status, risk, required reviewers
- Labels: `peel:needs-review`, `peel:needs-help`, `peel:approved`, `peel:conflict`

#### 9B: Agent Assignment Workflow
Allow per-PR or bulk assignment of review agents/templates:
- Assign one or many agents per PR
- Pick review depth: Standard / Deep / Security / Performance
- Queue limits to prevent review storms

#### 9C: Decision Console
For each PR, show:
- Agent review summaries + disagreements
- Final decision controls: Approve, Comment, Request Changes, Fix with Agent
- Explicit human sign-off marker before merge when policy requires

#### 9D: Auditability & Governance
Record every decision path:
- Who assigned which agent
- Which model/template produced each recommendation
- What action was taken in GitHub and when

Acceptance criteria:
- Can view open PRs across configured enterprise scope in one screen
- Can assign agent review for selected PRs and monitor progress
- Can complete approve/fix/re-request cycle without leaving Peel

---

## Code Optimization Highlights (Targeted)

These are high-impact optimizations directly tied to the scale/review goals above.

### 1) Make review completion event-driven (remove poll loop)
**File:** [Shared/Applications/PRReviewViews.swift](Shared/Applications/PRReviewViews.swift)

Current:
- `pollForResult` loops up to 120 times with 1s sleeps and repeatedly scans run collections.

Optimize:
- Add a run-status async stream/callback from `MCPServerService` and update `PRReviewState` on events.
- Keep polling only as fallback timeout path.

Impact:
- Lower CPU/wakeups, faster UI updates, fewer race conditions when runs transition.

### 2) Replace unstructured text parsing with structured review payloads
**File:** [Shared/Applications/PRReviewViews.swift](Shared/Applications/PRReviewViews.swift)

Current:
- `parseReviewOutput` infers verdict/risk/issues from free-form text.

Optimize:
- Require chain templates to return strict JSON schema for review results.
- Decode with `Codable`; fallback to raw-text parser only for legacy templates.

Impact:
- Higher reliability for approve/request-changes automation; fewer false parses.

### 3) Move blocking git/process work off main-actor queues
**Files:** [Shared/Distributed/PRQueue.swift](Shared/Distributed/PRQueue.swift), [Shared/Distributed/BranchQueue.swift](Shared/Distributed/BranchQueue.swift)

Current:
- `PRQueue` is `@MainActor` and uses blocking `Process.waitUntilExit()` for `git push`.
- Queue internals may serialize UI and network/process work on the same actor.

Optimize:
- Convert queue execution to dedicated actor/service for process + network operations.
- Keep only UI-observable state updates on `@MainActor`.

Impact:
- Better UI responsiveness and improved throughput under high PR volume.

### 4) Improve queue data structure and retry strategy
**File:** [Shared/Distributed/PRQueue.swift](Shared/Distributed/PRQueue.swift)

Current:
- `pendingOperations.removeFirst()` is O(n).
- No explicit retry/backoff policy for transient GitHub/git failures.

Optimize:
- Use deque/ring-buffer semantics for O(1) dequeue.
- Add bounded retries with exponential backoff + jitter for transient failures.

Impact:
- More stable queue performance at enterprise scale; fewer manual retries.

### 5) Correct upstream commit detection and reduce noisy logging
**File:** [Shared/Distributed/SwarmWorktreeManager.swift](Shared/Distributed/SwarmWorktreeManager.swift)

Current:
- Unpushed commit check uses `origin/main..branchName`, which is wrong if base branch differs.
- Very verbose `info` logs in hot paths (active key dumps each call).

Optimize:
- Compare against branch upstream (`@{upstream}`) when available, fallback to configured base branch.
- Demote high-volume logs to debug and keep structured summary logs only.

Impact:
- Fewer false positives/negatives on push decisions; cleaner logs during multi-agent runs.

### 6) Add persistence for PR queue operation state
**File:** [Shared/Distributed/PRQueue.swift](Shared/Distributed/PRQueue.swift)

Current:
- `pendingOperations` and `createdPRs` are in-memory only.

Optimize:
- Persist queued operations and PR metadata in SwiftData similar to worktree/branch recovery.
- Resume gracefully after app restart.

Impact:
- Required for reliable long-running enterprise review workflows.

---

## GitHub Issue Set (Phase 8/9 Execution Pack)

Use these in order. Each item is intentionally small enough to ship independently while still composing into the full multi-agent + enterprise PR review workflow.

### Dependency Order

1. P8-01 `PeelJob` envelope + lifecycle states
2. P8-02 Worker leasing + heartbeat + requeue
3. P8-03 Queue backpressure + concurrency caps
4. P8-04 Parent/child execution mode support (single/batch/map-reduce)
5. P8-05 Approval-gate policy engine
6. P8-06 PR queue persistence + retry/backoff optimizations
7. P9-01 Enterprise PR ingestion service + index
8. P9-02 Enterprise PR list UI + filters
9. P9-03 Agent assignment orchestration (single + bulk)
10. P9-04 PR decision console + governance audit trail

### P8-01 — Introduce `PeelJob` Envelope and Lifecycle

## Summary
Create a unified `PeelJob` model and lifecycle state machine that routes jobs consistently across local parallel runs, LAN swarm workers, and WAN workers.

## Proposed Charts / Work
- Define `PeelJob` envelope and `JobState` transitions (`queued`, `leased`, `running`, `awaiting_review`, `approved`, `merged`, `failed`, `cancelled`)
- Normalize payload mapping from current chain/task inputs into `PeelJob`
- Add serialization/deserialization tests for backward compatibility
- Add migration adapters for existing chain run path to avoid breaking current UI

## Data Source
- `MCPRunRecord`
- Distributed task payloads from [Plans/DISTRIBUTED_TASK_TYPES_SPEC.md](Plans/DISTRIBUTED_TASK_TYPES_SPEC.md)

## UI Placement
- Activity tab cards (state and progress)
- Repo Branches tab (job lineage ribbon)

## Acceptance Criteria
- [ ] One API path can dispatch the same job envelope to local and swarm execution backends
- [ ] Lifecycle transitions are deterministic and logged
- [ ] Existing single-run flow still works without regression

### P8-02 — Worker Leasing + Heartbeat + Requeue

## Summary
Prevent double-consumption and stuck jobs by adding lease ownership, heartbeat renewal, timeout reclaim, and bounded retry.

## Proposed Charts / Work
- Add lease record (`jobId`, `workerId`, `leaseExpiresAt`, `retryCount`)
- Add heartbeat updates with timeout reclaim
- Requeue timed-out jobs with max retry budget and failure reason
- Add worker capability matching (`swift`, `node`, `ios-sim`, `large-context`)

## Data Source
- Swarm coordinator worker registry
- Distributed task queue store

## UI Placement
- Activity > Workers panel (lease + heartbeat badges)
- Activity > Running now (retry indicators)

## Acceptance Criteria
- [ ] A timed-out lease automatically requeues eligible jobs
- [ ] Jobs are not executed by two workers concurrently
- [ ] Capability mismatches are visible and actionable

### P8-03 — Backpressure and Concurrency Guardrails

## Summary
Add global and per-repo concurrency controls so large fan-out jobs remain stable and fair.

## Proposed Charts / Work
- Implement global max in-flight jobs + per-repo max in-flight jobs
- Add queue priority handling (`high`, `normal`, `low`) with starvation prevention
- Add queue telemetry (`queued`, `running`, `retrying`, `blocked`)
- Add safe defaults in settings

## Data Source
- Job queue metrics
- Repo identity from unified repository model

## UI Placement
- Activity filters and summary chips
- Settings > Swarm / execution policy

## Acceptance Criteria
- [ ] Dispatching 100+ jobs does not freeze UI or starve low-volume repos
- [ ] Per-repo caps are enforced consistently
- [ ] Operators can observe queue pressure in real time

### P8-04 — Execution Modes: Single, Batch, Map-Reduce

## Summary
Support one prompt across one repo, many repos, or fan-out/fan-in workflows with explicit parent-child artifacts.

## Proposed Charts / Work
- Add `ExecutionMode` to job envelope (`single`, `batch`, `mapReduce`)
- Model parent job + child execution graph
- Add fan-in synthesis step for map-reduce mode
- Persist child output references for downstream review

## Data Source
- Job/execution records
- Existing parallel worktree run data

## UI Placement
- Activity timeline (expand parent to children)
- Branches tab (child status summary)

## Acceptance Criteria
- [ ] Batch mode can run one prompt against N repos with independent branch isolation
- [ ] Map-reduce mode produces a deterministic fan-in summary artifact
- [ ] Failed children don’t corrupt successful siblings

### P8-05 — Approval Gate Policy Engine

## Summary
Turn current inline approvals into policy evaluation with explicit merge gates and human sign-off requirements.

## Proposed Charts / Work
- Define policy rules for risk thresholds, CI requirements, and mandatory human approval
- Evaluate gate status per execution and per PR
- Add machine-generated gate explanation payload
- Block merge actions when policy fails

## Data Source
- PR labels (`peel:*`)
- CI/check status
- Agent review verdict payloads

## UI Placement
- Branches tab approval cards
- Enterprise PR decision console

## Acceptance Criteria
- [ ] High-risk PRs require explicit human gate approval
- [ ] Merge action is disabled with clear reason when policy fails
- [ ] Gate outcomes are auditable after restart

### P8-06 — PR Queue Reliability + Performance Optimizations ✅ DONE

## Summary
Harden PR queue throughput and recovery by persisting queue state, adding retries/backoff, and removing main-actor blocking process work.

## Proposed Charts / Work
- Persist pending PR operations + created PR metadata in SwiftData
- Replace O(n) dequeue with deque-style O(1) pop
- Add transient failure retry with exponential backoff + jitter
- Move `git push` process execution off main actor

## Data Source
- PR queue operation records
- GitHub response status codes

## UI Placement
- Activity diagnostics (queue health)
- PR status badges in repo detail and enterprise view

## Acceptance Criteria
- [x] PR queue resumes after app restart without operator intervention
- [x] Queue throughput remains stable at high operation volume
- [x] UI does not block during push/retry operations

**Implementation (March 4, 2026):**
- `PRQueue.swift`: Head-index O(1) dequeue, `retryDelayNanos()` with exponential backoff + jitter, async `git push` via `terminationHandler`
- `WorktreeModels.swift`: `PRQueueOperationRecord` + `PRQueueCreatedPRRecord` SwiftData models
- `PeelApp.swift`: Schema registration for new models
- `SwarmCoordinator.swift`: `modelContext` injection into PRQueue
- GitHub issue: #352

### P9-01 — Enterprise PR Ingestion and Index

## Summary
Build a federated PR ingestion service that aggregates open PRs across configured orgs/repos into one indexed source.

## Proposed Charts / Work
- Add org/repo discovery + PR polling with incremental sync cursors
- Store normalized PR entities (repo, author, labels, CI status, risk)
- Add freshness timestamps and stale-data handling
- Add pagination and scoped sync controls

## Data Source
- GitHub API (enterprise/org/repo PR endpoints)
- Existing repo registry mappings

## UI Placement
- Activity > enterprise PR surface
- Repositories side filter chips (has open PRs, needs review)

## Acceptance Criteria
- [ ] One list can show open PRs across configured enterprise scope
- [ ] Sync can resume without full re-fetch
- [ ] Stale data is visibly marked

### P9-02 — Enterprise PR List UI + Filters

## Summary
Create the UI surface to browse all enterprise PRs with operationally useful filters and sorting.

## Proposed Charts / Work
- Build table/list with columns: repo, PR, author, age, size, CI, risk, labels
- Add filters: org, repo, risk, CI state, label, assigned-review-agent state
- Add bulk selection model for assignment/review actions
- Add keyboard shortcuts and saved filter sets

## Data Source
- Enterprise PR index store

## UI Placement
- Activity tab primary section (enterprise PR queue)

## Acceptance Criteria
- [ ] Operators can isolate high-risk, failing-CI PRs in under 3 clicks
- [ ] List supports bulk selection without losing filter context
- [ ] Sorting/filtering is performant for large enterprise datasets

### P9-03 — Agent Assignment Orchestration (Single + Bulk)

## Summary
Allow assigning one or many review agents/templates to selected PRs, including bulk dispatch controls and safeguards.

## Proposed Charts / Work
- Add assignment model (`reviewTemplate`, `agentProfile`, `priority`, `deadline`)
- Add per-PR and bulk assignment actions
- Enforce assignment queue limits and duplicate-assignment prevention
- Add assignment event timeline per PR

## Data Source
- Enterprise PR index
- Job queue and chain dispatch services

## UI Placement
- Enterprise PR list row actions and bulk toolbar
- PR detail pane assignment history

## Acceptance Criteria
- [ ] Bulk assignment of selected PRs dispatches expected review jobs
- [ ] Duplicate assignment attempts are prevented with clear feedback
- [ ] Assignment progress is visible end-to-end

### P9-04 — PR Decision Console + Governance Audit Trail

## Summary
Provide a single PR decision surface for approve/comment/request-changes/fix that captures all agent recommendations and human decisions.

## Proposed Charts / Work
- Build decision console with agent result comparison and disagreement highlight
- Wire GitHub actions (approve/comment/request changes/fix with agent)
- Capture immutable audit events: assigner, model/template, verdict, final human action
- Add exportable review timeline for compliance/reporting

## Data Source
- Agent review results
- PR decision events
- GitHub review/comment actions

## UI Placement
- Enterprise PR detail panel
- Repo Branches PR card (condensed decision state)

## Acceptance Criteria
- [ ] User can complete review-to-decision flow without leaving Peel
- [ ] All actions are attributable (who/what/when)
- [ ] Governance audit trail survives restarts and is queryable

### Optional Follow-Up: Immediate Optimization Tickets ✅ ALL DONE

- ~~OPT-01 Event-driven PR review completion~~ ✅ `pollForResult()` rewritten: direct run discovery via `findRunBySourceChainRunId` + `waitForRunCompletion` with adaptive backoff
- ~~OPT-02 Structured JSON review payload + `Codable` parsing~~ ✅ Added `ReviewJSONPayload` Decodable struct, `parseStructuredReviewOutput()` pipeline, strict JSON prompt schema
- ~~OPT-03 Upstream-aware commit detection + log noise reduction~~ ✅ `branchHasUnpushedCommits()` uses `@{upstream}` with `origin/main` fallback; consolidated verbose logging

---

## Appendix: Current Navigation Map

```
Current:
  Agents
    ├── Connections (Copilot, Claude)
    ├── Tools
    │   ├── MCP Activity
    │   ├── Template Gallery
    │   ├── Chain History
    │   ├── Local RAG
    │   ├── Dependency Graph
    │   ├── Docling Import*
    │   ├── PII Scrubber*
    │   ├── Translation Validation*
    │   ├── Parallel Worktrees
    │   ├── Worktrees
    │   └── Local Chat
    ├── VM Isolation
    │   ├── Overview
    │   ├── Linux
    │   ├── macOS
    │   └── Pools
    ├── Active Chains
    └── Active Agents
  
  Workspaces
    ├── Workspace list
    ├── Repo list
    └── Worktree management
  
  Repositories
    ├── Local (Git_RootView)
    │   └── Repo selector → branch/commit view
    └── Remote (Github_RootView)
        ├── Favorites
        ├── Recent PRs
        ├── Tracked repos
        └── Org browser
  
  Swarm
    ├── Start/Stop
    ├── Workers list
    ├── Worktrees
    └── Task log + messaging

Proposed:
  Repositories
    ├── Unified repo list (sidebar)
    │   ├── ★ Favorites at top
    │   ├── Cloned repos
    │   └── Remote-only repos
    └── Repo detail (main pane)
        ├── Branches & Worktrees
        ├── Activity (per-repo)
        ├── RAG (index, search, analysis)
        └── Skills
  
  Activity
    ├── Running now (chains, indexing, pulls)
    ├── Recent (completed/failed work)
    ├── Workers panel (LAN + WAN)
    └── Filters (repo, status, worker)
  
  Settings (Cmd+,)
    ├── General
    ├── Connections (Copilot, Claude, GitHub)
    ├── MCP Server
    ├── RAG (provider, model)
    ├── Swarm (role, auto-start)
    ├── VM Isolation
    ├── Feature Flags
    └── Advanced
```

---

## Appendix: What We're NOT Changing

- The underlying MCP server architecture
- The agent chain execution engine
- The RAG indexing/search pipeline
- The swarm coordinator networking
- The Git/GitHub package internals
- SwiftData models (we layer a view model on top)
- The `Tools/` CLI infrastructure

This is a **navigation and presentation** overhaul, not a rewrite of internals.
