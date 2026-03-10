# Cross-Repo PR Review Dashboard — Design Plan

## Problem
When managing multiple repositories (cloke/*), there's no unified view of all open PRs across repos. Reviewing them individually is slow and fragmented. The goal is a tool that:
1. Fetches all open PRs across all cloke/* repos
2. Lets agents analyze each PR (diff quality, risk, CI status)
3. Produces a morning summary with actionable items
4. Supports bulk review actions (approve, request changes, comment)

## Existing Infrastructure (Already Built)

Peel already has most of the building blocks:

| Component | Location | What it does |
|-----------|----------|-------------|
| `Github.pullRequests()` | `Local Packages/Github/Sources/Github/Network.swift:67-94` | Fetches PRs from any repo |
| `github.pr.*` MCP tools | `Shared/AgentOrchestration/ToolHandlers/GitHubToolsHandler.swift` | Get/diff/review/comment on PRs via MCP |
| `PRReviewQueue` | `Shared/Services/PRReviewQueue.swift` | Tracks PR review lifecycle (pending→reviewing→reviewed→pushed) |
| `PRReviewQueueView` | `Shared/Applications/PRReviewQueueView.swift` | Shows review queue with expanded details |
| `pr.review.queue.*` MCP tools | `Shared/AgentOrchestration/ToolHandlers/PRReviewToolsHandler.swift` | Enqueue/status/update queue items |
| `RepositoryAggregator` | `Shared/Services/RepositoryAggregator.swift` | Merges repo data from multiple sources, includes top 5 PRs per repo |
| `RecentPullRequest` model | `Shared/Models/RepositoryModels.swift:65-89` | SwiftData model for tracked PRs |

## Proposed Architecture

### Option A: MCP-Driven Workflow (Recommended First Step)
Add 2 new MCP tools that orchestrate existing infrastructure:

**`pr.dashboard.scan`** — Scans all repos for open PRs
- Input: `{ "owner": "cloke", "includeArchived": false }`
- Fetches repo list via GitHub API, then fetches open PRs for each
- Returns: aggregated PR list with metadata (title, author, age, CI status, size)
- Stores results in SwiftData for the dashboard view

**`pr.dashboard.summarize`** — Generates morning summary
- Input: `{ "owner": "cloke", "since": "24h" }` 
- For each open PR: fetches diff stats, CI status, existing reviews
- Dispatches lightweight agent chains (Free Review template) to analyze each
- Produces markdown summary: critical PRs, stale PRs, PRs needing review, PRs ready to merge

### Option B: Full Peel View (Follow-up)
New SwiftUI view: `Shared/Applications/PRDashboardView.swift`

**Layout:**
```
┌─────────────────────────────────────────────────────┐
│ PR Dashboard — cloke/*                    [Refresh] │
├───────────┬─────────────────────────────────────────┤
│ Filters   │ PR List (sorted by priority)            │
│ ☑ Needs   │ ┌─────────────────────────────────────┐ │
│   Review  │ │ 🔴 peel #372 — Fix auth flow       │ │
│ ☑ CI      │ │    2 files, +15/-3, CI failing      │ │
│   Failing │ │    Agent: "Auth token not refreshed" │ │
│ ☑ Stale   │ ├─────────────────────────────────────┤ │
│ ☐ Draft   │ │ 🟡 tio-api #89 — Add caching       │ │
│           │ │    12 files, +340/-20, CI passing    │ │
│ Repos:    │ │    Agent: "No tests for new cache"  │ │
│ ☑ peel    │ ├─────────────────────────────────────┤ │
│ ☑ tio-api │ │ 🟢 tio-admin #45 — Bump deps       │ │
│ ☑ dotfiles│ │    1 file, +5/-5, CI passing        │ │
│           │ │    Agent: "Looks good, auto-merge"  │ │
│           │ └─────────────────────────────────────┘ │
├───────────┴─────────────────────────────────────────┤
│ Morning Summary (generated at 8:00 AM)              │
│ • 3 PRs need review across 2 repos                  │
│ • 1 PR has failing CI (peel #372)                   │
│ • 2 PRs are stale (>7 days, no activity)            │
│ • Recommended: merge tio-admin #45 (trivial)        │
└─────────────────────────────────────────────────────┘
```

**Data Model Extension:**
```swift
@Model
final class PRDashboardItem {
  var id: UUID = UUID()
  var repoOwner: String = ""
  var repoName: String = ""
  var prNumber: Int = 0
  var prTitle: String = ""
  var author: String = ""
  var state: String = ""           // open/draft
  var ciStatus: String = ""        // passing/failing/pending
  var additions: Int = 0
  var deletions: Int = 0
  var changedFiles: Int = 0
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var agentSummary: String = ""    // One-line agent analysis
  var riskLevel: String = ""       // low/medium/high
  var priority: Int = 0            // Computed: CI failing > needs review > stale > rest
  var lastScannedAt: Date = Date()
}
```

## Implementation Plan

### Phase 1: MCP Tools (1-2 sessions)
1. Add `pr.dashboard.scan` MCP tool in new `PRDashboardToolsHandler.swift`
2. Add `pr.dashboard.summarize` using Free Review template chains
3. Wire into existing `PRReviewQueue` for state tracking
4. Test via CLI: scan repos, generate summary

### Phase 2: SwiftUI View (1-2 sessions)  
1. Create `PRDashboardView.swift` with filter sidebar + PR list
2. Add `PRDashboardItem` SwiftData model
3. Integrate with RepositoryAggregator for repo list
4. Add morning summary section with scheduled refresh

### Phase 3: Automation (1 session)
1. Scheduled scan (configurable: daily at 8am, or on-demand)
2. Notification for critical PRs (CI failing, security issues)
3. Bulk actions: approve all low-risk, comment on stale
4. Integration with agent chains for automated fix suggestions

## Cost Optimization
- PR scanning: no LLM cost (pure API calls)
- Summary generation: use Free Review template (GPT-4.1-mini, 0 premium cost)
- Only analyze diffs for PRs that changed since last scan
- Cache GitHub API responses (5-minute TTL for PR list, 1-hour for diffs)

## Dependencies
- GitHub OAuth token with `repo` scope (already required for existing features)
- Existing `github.pr.*` MCP tools (already implemented)
- PRReviewQueue system (already implemented)
