---
name: peel-screenshot
description: "Capture and VIEW Peel app screenshots via MCP. Use when: verifying UI changes, checking layout, visually confirming rendering, taking screenshots of Peel views, inspecting what the app looks like. IMPORTANT: You CAN view images — use the Chrome MCP to render them."
---

# Peel Screenshot Capture & View

## When to Use
- After making UI/SwiftUI changes to verify rendering
- When the user asks to "check what it looks like" or "take a screenshot"
- To visually confirm agent output formatting, PR review rendering, etc.
- Any time you need to SEE the Peel app state

## Prerequisites
- Peel must be running with MCP enabled (port 8765)
- Chrome MCP server must be available (`mcp_io_github_chr_*` tools)

## Procedure

### Step 1: Navigate to the target view
```bash
curl -s -X POST 'http://127.0.0.1:8765/rpc' -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui.navigate","arguments":{"viewId":"VIEW_ID"}}}'
```

Available viewIds: `home`, `prReviews`, `templates`, `agentRuns`, `worktrees`, `chat`, `brew`, `repositories`, `activity`, `swarm`

For specific repos: `repo:<repo-key>` (e.g., `repo:tio-api`)

### Step 2: Optionally interact (select a run, tab, etc.)
```bash
# Tap a control
curl -s ... -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui.tap","arguments":{"controlId":"CONTROL_ID"}}}'

# Select a value
curl -s ... -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui.select","arguments":{"controlId":"CONTROL_ID","value":"VALUE"}}}'
```

Use `ui.snapshot` to discover available controls and their values.

### Step 3: Capture the screenshot
```bash
curl -s -X POST 'http://127.0.0.1:8765/rpc' -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot.capture","arguments":{"label":"DESCRIPTIVE_LABEL","outputDir":"/Users/coryloken/code/kitchen-sink/tmp"}}}'
```

This returns a JSON with `{"path": "/path/to/screenshot.png"}`. Extract the path.

### Step 4: VIEW the screenshot (CRITICAL — do not skip)

**Primary method — Chrome MCP:**
Use `mcp_io_github_chr_navigate_page` to open the file URL, then `mcp_io_github_chr_take_screenshot` to get a viewable image:

1. Navigate Chrome to the PNG:
   - Tool: `mcp_io_github_chr_navigate_page`
   - url: `file:///path/to/screenshot.png`

2. Take a Chrome screenshot (returns image data you CAN see):
   - Tool: `mcp_io_github_chr_take_screenshot`

**If Chrome MCP is unavailable (stale lock, timeout):**
1. Clear lock files:
   ```bash
   rm -f ~/.cache/chrome-devtools-mcp/chrome-profile/SingletonLock \
         ~/.cache/chrome-devtools-mcp/chrome-profile/SingletonSocket \
         ~/.cache/chrome-devtools-mcp/chrome-profile/SingletonCookie
   ```
2. Retry `mcp_io_github_chr_navigate_page`

**If Chrome MCP is still broken:**
1. Use `open_browser_page` to show it to the user (you won't see it)
2. Use `ui.snapshot` for text-based state verification
3. Tell the user you opened the screenshot but can't view it, and ask them to confirm

## Key Reminders
- **You CAN view images** via Chrome MCP screenshot tool — don't assume you can't
- Always save to `tmp/` (repo-local, gitignored), never `/tmp`
- Label screenshots descriptively: `pr-reviews-after-fix`, `agent-output-v2`
- Take a `ui.snapshot` alongside screenshots for control/state context
