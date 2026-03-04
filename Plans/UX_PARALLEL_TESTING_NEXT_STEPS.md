# Parallel UX Testing — Next Steps

**Status:** Phase 1 COMPLETE, Phase 2.1 + 2.2 DONE, live test completed — as of March 4, 2026  
**Goal:** Unleash Peel to do massive parallel UX work across web apps

---

## What Works Today

- **12 Chrome MCP tools:** `navigate`, `snapshot`, `screenshot`, `evaluate`, `fill`, `click`, `wait`, `select`, `check`, `launch`, `close`, `status`
- **Curl-based agent bridge:** Agents running via Copilot CLI can call Chrome tools through `curl` to the MCP server (`http://127.0.0.1:8765/rpc`) using an `mcp_call` shell helper injected into their prompt
- **`apiBaseURL` mode:** Tasks can point at an externally running app (e.g., `http://localhost:4250`) — skips dev server startup in worktrees
- **Parallel isolation:** Each task gets its own Chrome session (unique debug port + user data dir) via `UXTestOrchestrator`
- **End-to-end verified:** 2-task parallel run where both agents navigated, snapshotted DOM, filled forms, clicked buttons, and took screenshots — all via curl

---

## Phase 1: Make It Reliable (High Priority)

### 1.1 — Screenshot persistence & artifact collection ✅ DONE
**Problem:** `chrome.screenshot` returns base64 in the MCP response. The agent sees it in the curl output but can't meaningfully use a giant base64 blob. Screenshots are saved to `~/Library/Application Support/Peel/Screenshots/` but agents don't know the path.

**Implemented:**
- `chrome.screenshot` returns the **file path** (was already done)
- Added `savePath` optional parameter so agents can specify where to save (e.g., in their worktree)
- Added `artifacts` array to `ParallelWorktreeExecution` that collects screenshot paths, reports, etc.
- Artifacts are surfaced in `parallel.status` / `encodeExecution` response

### 1.2 — chrome.waitForSelector / waitForNavigation ✅ DONE
**Problem:** After `chrome.click` (especially form submits), the page may be loading. Agents currently guess `sleep 2` between actions, which is fragile.

**Implemented:**
- Added `chrome.wait` tool — polls for a CSS selector at 250ms intervals with configurable timeout (default 5s)
- Returns found/not-found, attempt count, element visibility
- On timeout, returns current URL for debugging and suggests `chrome.snapshot`
- Prompt context updated to recommend `chrome.wait` instead of `sleep`

### 1.3 — chrome.selectOption / chrome.check ✅ DONE
**Problem:** Forms have dropdowns (`<select>`) and checkboxes that `fill` and `click` don't handle cleanly.

**Implemented:**
- `chrome.select` — takes `selector` + `value`, matches by option value or visible text, dispatches change events. On failure, lists all available options.
- `chrome.check` — takes `selector` + `checked: bool`, toggles checkbox/radio inputs with proper event dispatch

### 1.4 — Better error messages from Chrome tools ✅ DONE
**Problem:** When a CSS selector doesn't match, the agent gets a cryptic JS null error.

**Implemented:**
- `chrome.fill` and `chrome.click` now return clear errors like `"No element found matching selector: input[name=email]"` with `currentURL` and a `hint` suggesting `chrome.snapshot`
- `chrome.select` lists available options when the requested option isn't found
- `chrome.check` reports the actual element type when it's not a checkbox/radio

### 1.5 — Auth/credential injection via repo profile ✅ DONE (pre-existing)
**Problem:** The PoC failed login because `admin@example.com / password` wasn't valid. Agents need to know real credentials.

**Already implemented:**
- `RepoProfile.AuthConfig.testAccounts` array exists with role/username/password/notes
- `RepoProfileService.buildPromptContext()` injects test accounts into agent prompts
- Profile lives in `.peel/profile.json` (gitignored)

---

## Phase 2: Scale It Up (Medium Priority)

### 2.1 — Per-worktree dev servers (full isolation) ✅ DONE
**Current:** All tasks share one externally running app via `apiBaseURL`.  
**Problem:** If tasks need to test destructive operations (create/delete records), they interfere with each other.

**Implemented:**
- Added `installDependencies: Bool` flag to `WorktreeTask` (default false, opt-in)
- Added `DevServerManager.installDependencies()` method:
  - **Fast path:** symlinks `node_modules` from main repo (derives path from worktree location)
  - **Fallback:** runs full `pnpm install --frozen-lockfile` / `npm ci` / `yarn install --frozen-lockfile` / `bun install --frozen-lockfile`
  - Skips if `node_modules` already exists
- Added `installCommand()` to `DetectedRuntime` enum for all 5 runtimes
- Wired through `UXTestOrchestrator.createSession` → installs deps before starting dev server
- Wired through `ParallelWorktreeRunner` → passes flag from task to session creation
- Added `installDependencies` to `parallel.create` / `parallel.append` task parsing + tool definition
- Expanded port ranges from 20 to 50 slots (3001-3050 dev, 9222-9271 Chrome) for bigger parallel runs

### 2.2 — Parallel UX task templates
**Problem:** Creating parallel UX tasks requires manually writing JSON with `useUXTesting`, `apiBaseURL`, tool instructions, etc.

**Fix:**
- ✅ Added `UX Audit` chain template (ID `A0000001-0012`, template #17) that:
  1. Planner step discovers routes from codebase, creates parallel tasks with `useUXTesting: true` and `installDependencies: true`
  2. Each task navigates to its route, screenshots, snapshots DOM, evaluates against UX criteria
  3. Reviewer step aggregates all findings into a unified UX Audit Report
  4. Covers: layout, typography, accessibility, error states, consistency, performance
- Add a `UX Regression` template that:
  1. Takes before/after URLs (or a branch)
  2. Screenshots each page on both versions
  3. Diffs the screenshots and reports visual regressions
- Add a `UX Flow Test` template for multi-step flows (login → dashboard → create record → verify)

### 2.3 — Screenshot diffing
**Problem:** Agents describe what they see in text, which is useful but not visual.

**Fix:**
- Add `chrome.diff` tool that takes two screenshot paths and produces a visual diff (highlight changed pixels)
- Or use a simpler approach: agents take before/after screenshots, and a reviewer step compares them
- Consider integrating with an image comparison library (pixel diff or perceptual hash)

### 2.4 — Multi-page routing support
**Problem:** Single-page apps may need the agent to know the full route map to audit all pages.

**Fix:**
- Add route discovery: agent runs `chrome.evaluate` with a script that extracts all `<a href>` and `react-router` routes
- Or parse the app's router config file (e.g., `src/router.tsx`) and inject known routes into the prompt
- `RepoProfile` could detect the framework (React Router, Next.js, Vue Router) and extract routes

---

## Phase 3: Production Quality (Lower Priority)

### 3.1 — Chrome session health monitoring
- Detect Chrome crashes (process exits unexpectedly) and auto-restart
- Add heartbeat pings to Chrome debug port
- Report Chrome memory usage in `chrome.status`
- Set per-session timeouts (kill Chrome after N minutes of inactivity)

### 3.2 — Agent tool calling (eliminate curl)
**Current:** Agents call Chrome tools via `curl` to the MCP server — works but verbose.  
**Ideal:** Agents have native tool-calling ability.

**Options:**
- A. Wrap `cliService.runCopilotSession()` with a tool proxy that intercepts agent tool calls and routes them to MCP
- B. Run agents via a different executor that supports MCP tool use natively
- C. Keep curl approach but improve the `mcp_call` helper (add retries, better error formatting, shorter syntax)

Option C is pragmatic and already works. A/B are bigger lifts.

### 3.3 — Visual regression CI
- After a parallel UX run completes, compare screenshots against a baseline stored in the repo
- Auto-fail tasks that introduce visual regressions beyond a threshold
- Store baseline screenshots in `.peel/screenshots/baseline/`

### 3.4 — Mobile viewport testing
- Add `chrome.emulate` tool to set device viewport (iPhone, iPad, etc.)
- Or pass `--window-size` to Chrome launch args per session
- Each task could specify a viewport, enabling parallel desktop + mobile testing of the same page

### 3.5 — Network interception
- `chrome.interceptRequest` — block/mock API calls for testing error states
- `chrome.getNetworkLog` — return all network requests made during the session
- Useful for testing loading states, error boundaries, and API failure handling

---

## Immediate Action Items (This Week)

| # | Task | Effort | Impact | Status |
|---|------|--------|--------|--------|
| 1 | Add `testAccounts` to `.peel/profile.json` + inject into prompt | Small | Unblocks login tests | ✅ Done (pre-existing) |
| 2 | Return file path from `chrome.screenshot` + add `artifacts` to execution | Small | Makes screenshots useful | ✅ Done |
| 3 | Add `chrome.wait` (waitForSelector) | Medium | Eliminates timing bugs | ✅ Done |
| 4 | Better error messages from fill/click (selector not found) | Small | Reduces agent confusion | ✅ Done |
| 5 | Create `UX Audit` chain template | Medium | Enables one-command full-app audit | ✅ Done |
| 6 | Test with 5-10 parallel tasks on a real app | Small | Validate scaling | ✅ Done (see results below) |

---

## Live Test Results: tio-admin 10-Page UX Audit (March 4, 2026)

**Target:** tio-admin (Ember 6.10 + Vite, pnpm monorepo `tio-front-end`)
**Mode:** `apiBaseURL: "http://localhost:4250"` (shared dev server, 10 parallel Chrome sessions)
**Run ID:** `FDEDBD18-7C12-4905-A609-F48E63704DCD`
**Model:** Claude Sonnet 4.6

### Results Summary

| Page | Duration | Files Changed | Insertions | Deletions |
|------|----------|---------------|------------|-----------|
| Login | 377s | 5 | +31 | -9 |
| Dashboard | 669s | 9 | +32 | -13 |
| Companies | 623s | 5 | +58 | -5 |
| People | 615s | 8 | +68 | -23 |
| Accounts | 743s | 4 | +50 | -18 |
| Settings | 866s | 7 | +57 | -38 |
| PSLF | 849s | **12** | **+171** | -29 |
| Tuition Assistance | 712s | 9 | +58 | -18 |
| Analytics | 578s | 6 | +26 | -59 |
| Eligibility | 532s | 0 | 0 | 0 |
| **Total** | — | **65** | **+551** | **-212** |

### What Worked
- **10 parallel Chrome sessions** launched and connected successfully (ports 9222-9231)
- **4 concurrent agents** running at once (default `maxImplementers`), with task queue cycling through remaining 6
- **Worktrees created** under `/Users/coryloken/code/tio-workspace/.agent-workspaces/workspace-*`
- **Agents browsed real pages**, took screenshots, captured DOM snapshots, and made meaningful code changes
- **Quality of changes** was high: added loading states, improved error handling, added i18n translations (en-us, es-mx, fr-ca), fixed form accessibility attributes, improved navigation

### Sample Changes (Login Page)
- Added `@tracked isLoading` state for login button feedback
- Changed input type from `text` to `email` with `autocomplete="username"`
- Added `@isRequired={{true}}` to form fields
- Better error handling: `error instanceof Error ? error.message : String(error)`
- Added `autocomplete="current-password"` to password field

### Why All 10 "Failed"
**Root cause:** Default chain template includes a **Build Check gate** step that runs after the agent completes. The gate tries to build the project but fails with exit code 66 because:
1. The build gate doesn't know how to build an Ember/Vite app
2. The worktrees don't have `node_modules` installed (we used `apiBaseURL` mode, not `installDependencies`)

**Evidence:** All 10 chain logs show: `"Gate 'Build Check' failed (exit 66)"`

**Fixes needed:**
- UX Audit template should use a chain template **without a build gate** (or with a skip-build option)
- Or configure the build command per-repo in `.peel/profile.json` so the gate knows how to build Ember apps
- Or make the build gate aware of the project's package manager and run the right command

### Concurrency & Performance
- Max 4 concurrent agents (default `maxImplementers`)
- Tasks queued and executed in FIFO order as slots freed up
- Average task duration: ~656s (~11 minutes)
- All Chrome sessions stable — no crashes or timeouts during the run

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    parallel.create + start                   │
└─────────────────────┬───────────────────────────────────────┘
                      │
            ┌─────────▼──────────┐
            │ ParallelWorktreeRunner │
            │  (orchestrates N tasks) │
            └────┬────┬────┬─────┘
                 │    │    │
    ┌────────────▼┐ ┌─▼────────┐ ┌▼────────────┐
    │  Task 1     │ │ Task 2   │ │  Task N     │
    │  Worktree   │ │ Worktree │ │  Worktree   │
    └──────┬──────┘ └────┬─────┘ └──────┬──────┘
           │             │              │
    ┌──────▼──────┐ ┌────▼─────┐ ┌──────▼──────┐
    │ UX Session  │ │UX Session│ │ UX Session  │
    │ Chrome:9222 │ │Chrome:9223│ │Chrome:9224  │
    └──────┬──────┘ └────┬─────┘ └──────┬──────┘
           │             │              │
           └─────────────┼──────────────┘
                         │
              ┌──────────▼──────────┐
              │  Copilot CLI Agent  │
              │  (per worktree)     │
              │                     │
              │  mcp_call "chrome.X"│
              │  ↓ curl to :8765    │
              └──────────┬──────────┘
                         │
              ┌──────────▼──────────┐
              │  MCPServerService   │
              │  ChromeToolsHandler │
              │  → ChromeSessionMgr │
              └─────────────────────┘
```

---

## Open Questions

1. **Shared vs isolated backend?** For read-only audits, a shared app instance is fine. For write tests (create/edit/delete), do we need per-task backends? Or can we seed + reset test data between tasks?

2. **Screenshot storage?** Application Support is fine for now. Should we move to the repo's `.peel/screenshots/` for version control? Or a separate artifact store?

3. **Concurrency limits?** Chrome instances use ~150-300MB RAM each. With 10 parallel tasks, that's 1.5-3GB just for Chrome. Need to test limits and potentially add a Chrome session pool with bounded concurrency.

4. **Agent model for UX tasks?** UX observation tasks (describe the page) work fine with Sonnet/GPT-4.1. Interaction tasks (login, fill forms) may benefit from more capable models. Should the template auto-select?

---

*Created: March 4, 2026*  
*Last proven: 2-task parallel run with Chrome fill/click/screenshot via curl bridge*
