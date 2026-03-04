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
**Updated:** March 4, 2026  
**Goal:** Transform Peel from a developer tool collection into a cohesive product that new users immediately understand.

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
| Worker messages | Swarm tab | Communication about activity |

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
3. ✅ Port `Git_RootView` branch/commit UI into Branches sub-tab — Embeds real `GitRootView` for cloned repos
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

1. ⬜ Onboarding flow update (new FeatureDiscoveryView for 2-tab layout)
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
1. ⬜ Add "Labs" tab to Settings window with feature toggles
2. ⬜ Extend CommandPaletteView to support action results (not just RAG search)
3. ⬜ Wire enabled lab features into appropriate surfaces (repo context menus, Activity sections)
4. ⬜ Move MCP Dashboard into Settings > MCP Server tab
5. ⬜ Move VM Isolation into Settings > VM Isolation tab
6. ⬜ Add Local Chat as floating panel (Cmd+Shift+C)

---

## What Happens to Each Current Feature

| Current Feature | New Home | Notes |
|----------------|----------|-------|
| Git branch/commit view | Repositories > Repo > Branches | Core of the repo detail |
| GitHub favorites | Repositories sidebar (★ indicator) | Attribute, not separate section |
| GitHub PRs | Repositories > Repo > Branches (linked to branches) | PRs are branch metadata |
| Recent PRs | Activity (recent section) | Activity is time-based |
| Tracked repos (auto-pull) | Repositories > Repo settings | Per-repo configuration |
| Agent chains | Activity (running/recent) | Chains are work happening |
| Chain templates | "Run New Task" dialog | Templates = ways to start work |
| Chain history | Activity (recent, filterable) | Past work |
| Parallel worktrees | Activity (running work) | Worktree = where agent works |
| Worktree management | Repositories > Repo > Branches | Worktrees are branches |
| Local RAG | Repositories > Repo > RAG | Per-repo feature |
| RAG search | Cmd+K global overlay | Cross-repo search |
| Dependency graph | Repositories > Repo > RAG > Analysis | Per-repo analysis |
| Skills | Repositories > Repo > Skills | Per-repo configuration |
| Local chat | Floating panel (Cmd+Shift+C) | Conversation, not a "tab" |
| MCP Activity | Settings > MCP Server | Infrastructure monitoring |
| Copilot/Claude status | Settings > Connections | Infrastructure setup |
| VM Isolation | Settings > VM Isolation | Advanced infrastructure |
| PII Scrubber | Settings > Feature Flags | Niche utility |
| Docling Import | Settings > Feature Flags | Niche utility |
| Translation Validation | Settings > Feature Flags | Niche utility |
| Swarm workers | Activity > Workers panel | Who's doing the work |
| Swarm config | Settings > Swarm | Infrastructure setup |
| Brew | Settings > Feature Flags (if enabled, own tab) | Separate concern |
| Workspaces | Eliminated | Concept absorbed into repos |
| Feature Discovery | Updated for new layout | Onboarding |

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

## Open Questions

1. **Local Chat:** Floating panel vs. integrated into repo detail? Floating feels more flexible (chat about repo X while looking at repo Y).
2. **Brew:** Keep as hidden feature flag tab, or move entirely to Settings? It's orthogonal to the repo/agent story.
3. **Template Gallery:** Should "Run New Task" pre-filter templates by the selected repo's framework? (Yes, probably.)
4. **iOS parity:** How much of the Activity view makes sense on iOS where agents can't run locally? (Monitor-only is still valuable.)
5. **Experimental features surface:** PII scrubber, VMs, Docling, translations, dependency graph, local chat are all hidden after the 2-tab overhaul. Need a "Labs" or overflow mechanism — see Phase 5 proposal.

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
