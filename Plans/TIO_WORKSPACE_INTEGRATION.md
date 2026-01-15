# Kitchen Sync + tio-workspace Integration Plan

**Date:** January 15, 2026  
**Status:** ✅ Phase 1 Complete  
**Goal:** Generic workspace and worktree dashboard for any project

---

## What Was Built (Phase 1)

### Workspace Dashboard
- **Generic workspace picker** - add any project folder
- **Multi-repo detection** - submodules, nested git repos
- **Worktree dashboard** - see all active worktrees grouped by repo
- **Status indicators** - green (clean), yellow (uncommitted changes)
- **Create/remove worktrees** - with detached HEAD option
- **Open in VS Code** - one-click launch

### Run Agent Chain Feature
- Select from built-in chain templates (Code Review, Quick Fix, etc.)
- Enter task description and context
- Generates structured prompt for Copilot
- Copies to clipboard and opens VS Code
- Ready for you to paste into Copilot chat (Cmd+Shift+I)

### Files Created
- `Shared/Services/WorkspaceDashboardService.swift` - Core service
- `Shared/Applications/Workspaces_RootView.swift` - Dashboard UI

### Files Modified
- `macOS/ContentView.swift` - Added "workspaces" case
- `Shared/CommonToolbarItems.swift` - Added to toolbar picker

---

## Decision: Generic Over Specific ✅

We're building a **generic workspace manager** that works with:
- Multi-repo workspaces (like tio-workspace with submodules)
- Single git repositories
- Folders containing multiple repos

tio-workspace is just one workspace you can add to the dashboard.

---

## The Opportunity: GUI Worktree Manager

### Vision
Kitchen Sync becomes the **command center** for tio-workspace development:
- Visual worktree management (create, list, cleanup)
- One-click "Open in VS Code"
- Track agent work across worktrees
- Cost tracking for agent usage

### Key Insight: We CAN Open VS Code + Copilot
While we can't **programmatically start a Copilot chat**, we CAN:

```bash
# Open folder in VS Code with Copilot agent mode
code -n /path/to/worktree

# Better: Open with reuse window if same folder
code -r /path/to/worktree

# Even better: Open with specific file and line
code -g /path/to/worktree/file.rb:42
```

Once VS Code opens, the user can:
1. Press `Cmd+Shift+I` to open Copilot Chat
2. Use `@workspace` to give Copilot context about the worktree
3. The worktree isolation means Copilot sees only that task's files

---

## Feature Ideas

### 1. Worktree Dashboard 🌳
**Priority: High**

A dedicated view in Kitchen Sync showing:
- All active worktrees across tio-workspace repos
- Status: active, has uncommitted changes, stale
- Quick actions: Open in VS Code, View diff, Cleanup

```swift
struct WorktreeDashboardView: View {
  @State private var worktrees: [TioWorktree] = []
  
  var body: some View {
    List(worktrees) { worktree in
      WorktreeRow(worktree: worktree)
        .contextMenu {
          Button("Open in VS Code") { openInVSCode(worktree) }
          Button("View Diff") { viewDiff(worktree) }
          Divider()
          Button("Cleanup", role: .destructive) { cleanup(worktree) }
        }
    }
  }
}
```

### 2. Smart Worktree Creator ➕
**Priority: High**

Create worktrees with intelligence:
- Choose repo from tio-workspace submodules
- Choose base: main, specific PR, specific branch
- Auto-generate meaningful name from description
- Pre-populate with task context

```
┌─────────────────────────────────────────┐
│  Create Worktree                        │
├─────────────────────────────────────────┤
│  Repository: [tio-api ▾]                │
│  Base:       [main ▾] / PR #6110 / br.. │
│  Task:       [Add search caching      ] │
│                                         │
│  Will create:                           │
│  ~/code/tio-worktrees/tio-api-add-search│
│                                         │
│  [Cancel]          [Create & Open ▸]    │
└─────────────────────────────────────────┘
```

### 3. PR Review Mode 🔍
**Priority: High**

Streamline PR review workflow:
1. Pick a repo (tio-api, tio-front-end, etc.)
2. See open PRs (pulls from GitHub)
3. Click to create worktree from PR branch
4. Open in VS Code for review
5. Leave comments via GitHub integration

### 4. Agent Task Launcher 🤖
**Priority: Medium**

Rather than manually opening Copilot, we could:
- Create worktree
- Open VS Code to that worktree
- Copy task prompt to clipboard
- User pastes into Copilot chat

Or even better with AppleScript:
```applescript
-- This might work to automate Copilot opening
tell application "Visual Studio Code"
  activate
  -- Wait for VS Code to load
  delay 1
  -- Open Copilot panel via keyboard shortcut
  tell application "System Events"
    keystroke "i" using {command down, shift down}
  end tell
end tell
```

### 5. Multi-Agent Orchestration 🎭
**Priority: Medium (depends on worktree completion)**

The full vision from PARALLEL_AGENTS_PLAN:
- Planner splits task into independent subtasks
- Create N worktrees, one per implementer
- Run implementers in parallel (in Kitchen Sync's agent runner)
- Merge agent combines results
- Cleanup worktrees

This is more ambitious but the infrastructure is already there.

---

## Implementation Phases

### Phase 1: Read tio-workspace (Week 1)
1. Add support for reading tio-workspace structure
2. Detect submodules and their paths
3. Parse `.gitmodules` for repo list
4. List worktrees for each submodule

```swift
actor TioWorkspaceService {
  let workspacePath = "/Users/coryloken/code/tio-workspace"
  
  /// Get all submodules in tio-workspace
  func getSubmodules() async throws -> [Submodule]
  
  /// Get worktrees for a specific submodule
  func getWorktrees(for submodule: Submodule) async throws -> [Worktree]
  
  /// Get open PRs for a submodule (via gh CLI)
  func getPullRequests(for submodule: Submodule) async throws -> [PullRequest]
}
```

### Phase 2: Worktree CRUD (Week 1-2)
1. Create worktree for agent work (detached HEAD)
2. Create worktree for PR review (on branch)
3. Cleanup worktree (with uncommitted changes warning)
4. List all worktrees

### Phase 3: VS Code Integration (Week 2)
1. Open worktree folder in VS Code
2. Open specific file at line number
3. (Stretch) AppleScript to open Copilot panel

### Phase 4: PR Integration (Week 2-3)
1. List open PRs from GitHub
2. Quick "Review in Worktree" action
3. View PR diff in Kitchen Sync
4. Comment on PR from Kitchen Sync

### Phase 5: Agent Orchestration (Week 3+)
1. Create task from PR description
2. Launch agent in worktree
3. Track agent progress
4. Multi-agent parallel execution

---

## Questions to Answer

1. **Scope**: Should this be tio-workspace specific or generic?
   - Generic: Any multi-repo workspace
   - Specific: Tailored for tio-workspace conventions
   - **Recommendation**: Start specific, generalize later

2. **VS Code Automation**: How far can we go?
   - Minimum: Open folder, copy prompt to clipboard
   - Medium: AppleScript to open Copilot panel
   - Maximum: VS Code extension (separate project)

3. **Agent Execution**: Run in Kitchen Sync or VS Code?
   - Kitchen Sync: Full control, streaming output, cost tracking
   - VS Code Copilot: Better context, interactive, existing tool
   - **Recommendation**: Both - Kitchen Sync for orchestration, VS Code for interactive

4. **GitHub Integration**: Use gh CLI or API?
   - gh CLI: Already available, no auth needed
   - API: More control, can batch requests
   - **Recommendation**: gh CLI for now (simpler)

---

## Files to Create/Modify

### New Files
- `Shared/Services/TioWorkspaceService.swift` - Workspace operations
- `Shared/Applications/TioWorkspace_RootView.swift` - New tab/view
- `Shared/Views/WorktreeDashboard/WorktreeDashboardView.swift`
- `Shared/Views/WorktreeDashboard/WorktreeRow.swift`
- `Shared/Views/WorktreeDashboard/CreateWorktreeSheet.swift`

### Modified Files
- `Shared/KitchenSyncApp.swift` - Add tio-workspace tab
- `Shared/Services/VSCodeService.swift` - Add AppleScript support
- `macOS/ContentView.swift` - Add navigation item

---

## Non-Goals (for now)

- Running agents inside VS Code from Kitchen Sync
- Automating full PR workflow (create, review, merge)
- Supporting workspaces other than tio-workspace
- VS Code extension development

---

## Success Metrics

1. **Time to start agent work**: Currently ~2 min → Target: 30 sec
2. **Worktree cleanup rate**: Track abandoned worktrees
3. **PR review time**: Measure time from PR open to review start

---

## Open Questions for Today

1. Which feature do you want first?
   - [ ] Worktree dashboard (read-only)
   - [ ] Create worktree + open VS Code
   - [ ] PR review workflow

2. Should this be a new tab in Kitchen Sync or enhance existing Git view?

3. Do you want Kitchen Sync to run the agents, or just prepare the worktree for VS Code Copilot?

---

## Session Checklist ✅

### Is the codebase clean?
- [x] MODERNIZATION_COMPLETE.md confirms all packages modernized
- [x] WorktreeService exists and is functional
- [x] VSCodeService exists with open/openIsolated support
- [x] Agent orchestration working with streaming

### Ready to start?
- [ ] Decide initial scope (dashboard vs create vs both)
- [ ] Decide UI location (new tab vs existing view)
- [ ] Start implementation

---

**Let's build this!** 🚀