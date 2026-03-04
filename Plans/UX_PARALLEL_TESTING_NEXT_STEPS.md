# Parallel UX Testing — Next Steps

**Status:** Proof-of-concept WORKING as of March 4, 2026  
**Goal:** Unleash Peel to do massive parallel UX work across web apps

---

## What Works Today

- **9 Chrome MCP tools:** `navigate`, `snapshot`, `screenshot`, `evaluate`, `fill`, `click`, `launch`, `close`, `status`
- **Curl-based agent bridge:** Agents running via Copilot CLI can call Chrome tools through `curl` to the MCP server (`http://127.0.0.1:8765/rpc`) using an `mcp_call` shell helper injected into their prompt
- **`apiBaseURL` mode:** Tasks can point at an externally running app (e.g., `http://localhost:4250`) — skips dev server startup in worktrees
- **Parallel isolation:** Each task gets its own Chrome session (unique debug port + user data dir) via `UXTestOrchestrator`
- **End-to-end verified:** 2-task parallel run where both agents navigated, snapshotted DOM, filled forms, clicked buttons, and took screenshots — all via curl

---

## Phase 1: Make It Reliable (High Priority)

### 1.1 — Screenshot persistence & artifact collection
**Problem:** `chrome.screenshot` returns base64 in the MCP response. The agent sees it in the curl output but can't meaningfully use a giant base64 blob. Screenshots are saved to `~/Library/Application Support/Peel/Screenshots/` but agents don't know the path.

**Fix:**
- Return the **file path** from `chrome.screenshot` (already saved to disk) instead of or in addition to base64
- Add a `savePath` optional parameter so agents can specify where to save (e.g., in their worktree)
- Add an `artifacts` array to `ParallelWorktreeExecution` that collects screenshot paths, so the parallel run status shows what was captured
- Surface artifacts in `parallel.status` response

### 1.2 — chrome.waitForSelector / waitForNavigation
**Problem:** After `chrome.click` (especially form submits), the page may be loading. Agents currently guess `sleep 2` between actions, which is fragile.

**Fix:**
- Add `chrome.wait` tool — waits for a CSS selector to appear in the DOM (poll-based with timeout)
- Optionally support waiting for navigation to complete (`Page.loadEventFired` CDP event)
- Update `buildPromptContext()` to include `chrome.wait` in the tool list

### 1.3 — chrome.selectOption / chrome.check
**Problem:** Forms have dropdowns (`<select>`) and checkboxes that `fill` and `click` don't handle cleanly.

**Fix:**
- `chrome.select` — takes `selector` + `value`, dispatches change event on `<select>` elements
- `chrome.check` — takes `selector` + `checked: bool`, toggles checkbox/radio inputs

### 1.4 — Better error messages from Chrome tools
**Problem:** When a CSS selector doesn't match, the agent gets a cryptic JS null error.

**Fix:**
- `chrome.fill` and `chrome.click` should return clear errors like `"No element found matching selector: input[name=email]"` with a suggestion to use `chrome.snapshot` to find the right selector
- Include the current URL in error responses for debugging

### 1.5 — Auth/credential injection via repo profile
**Problem:** The PoC failed login because `admin@example.com / password` wasn't valid. Agents need to know real credentials.

**Fix:**
- Extend `.peel/profile.json` with a `testAccounts` array: `[{ "role": "admin", "email": "...", "password": "..." }]`
- `RepoProfileService.buildPromptContext()` already injects profile data into agent prompts — add test accounts to the output
- Alternatively, support environment-variable-based credential injection so secrets aren't in the profile file
- For local-only testing, `.peel/profile.json` in gitignore is fine

---

## Phase 2: Scale It Up (Medium Priority)

### 2.1 — Per-worktree dev servers (full isolation)
**Current:** All tasks share one externally running app via `apiBaseURL`.  
**Problem:** If tasks need to test destructive operations (create/delete records), they interfere with each other.

**Fix:**
- Before starting the dev server in a worktree, run `pnpm install` (or detect + use the right package manager via `DevServerManager.DetectedRuntime`)
- Add `installDependencies: Bool` flag to `WorktreeTask` (default false, opt-in for full isolation)
- When enabled: `pnpm install` → `pnpm dev --port <allocated>` → Chrome navigates to `http://localhost:<port>`
- Consider symlinking `node_modules` from the main repo as a faster alternative to full install

### 2.2 — Parallel UX task templates
**Problem:** Creating parallel UX tasks requires manually writing JSON with `useUXTesting`, `apiBaseURL`, tool instructions, etc.

**Fix:**
- Add a `UX Audit` chain template that:
  1. Takes a repo path + app URL as inputs
  2. Auto-generates N tasks from a list of pages/routes to audit  
  3. Each task navigates to its route, screenshots it, describes the UI, flags issues
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

| # | Task | Effort | Impact |
|---|------|--------|--------|
| 1 | Add `testAccounts` to `.peel/profile.json` + inject into prompt | Small | Unblocks login tests |
| 2 | Return file path from `chrome.screenshot` + add `artifacts` to execution | Small | Makes screenshots useful |
| 3 | Add `chrome.wait` (waitForSelector) | Medium | Eliminates timing bugs |
| 4 | Better error messages from fill/click (selector not found) | Small | Reduces agent confusion |
| 5 | Create `UX Audit` chain template | Medium | Enables one-command full-app audit |
| 6 | Test with 5-10 parallel tasks on a real app | Small | Validate scaling |

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
