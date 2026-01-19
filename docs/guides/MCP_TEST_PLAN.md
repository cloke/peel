# MCP Test Plan

**Created:** January 18, 2026  
**Updated:** January 18, 2026

## Goals
- Validate the MCP test harness server responds to JSON-RPC requests.
- Verify chain execution and results payloads are correct.
- Confirm templates are discoverable and runnable via MCP.

## Preconditions

### Option A: Manual (for UI testing)
- Build and run Peel from Xcode (⌘R).
- In Settings, enable MCP Server and choose a port.
- Ensure the selected working directory is a git repo for parallel runs.

### Option B: Script (for agent testing)
```bash
# Build, configure, and launch with MCP enabled
./Tools/build-and-launch.sh --wait-for-server --port 8765
```

This script:
1. Builds Peel via xcodebuild
2. Sets `mcp.server.enabled = true` via defaults
3. Launches the app
4. Waits until MCP server responds (with `--wait-for-server`)

Automated validation script:
```bash
./Tools/mcp-test-plan.sh --working-directory /path/to/git/repo
```

## VS Code Setup
- Configure a local MCP client to connect to http://localhost:<port>/rpc.
- Ensure the MCP client supports JSON-RPC 2.0 with the `tools/list` and `tools/call` methods.
- Use local-only transport (no remote exposure).

## Test Cases

### 1. Server Initialization
**Request:** JSON-RPC `initialize`
**Expected:** `serverInfo` and `capabilities.tools` returned.

### 2. List Templates
**Request:** JSON-RPC `tools/list`
**Expected:** Includes `templates.list` and `chains.run`.

### 3. List Available Chain Templates
**Request:** JSON-RPC `tools/call` with `name: templates.list`
**Expected:** Response includes `MCP Harness` template.

### 4. Run MCP Harness Template
**Request:** JSON-RPC `tools/call` with `name: chains.run`
**Params:**
- `templateName`: `MCP Harness`
- `prompt`: short task prompt
- `workingDirectory`: valid repo path
- `enableReviewLoop`: true

**Expected:**
- `success: true`
- `results` array includes planner, two implementers, reviewer
- `mergeConflicts` empty for clean merges

### 5. Error Handling
**Request:** `chains.run` without `prompt`
**Expected:** JSON-RPC error `-32602`.

### 6. Invalid Template
**Request:** `chains.run` with invalid `templateName`
**Expected:** JSON-RPC error `-32602` (Template not found).

### 7. Port Validation
**Action:** Set port to 80 or 0
**Expected:** Settings shows error, server remains stopped.

### 8. Activity Log Persistence
**Action:** Run a chain via MCP, relaunch Peel, open MCP Activity
**Expected:** Recent MCP run history is visible with timestamp, template, and status.

### 9. Cleanup Action
**Action:** Click “Clean Agent Worktrees” in MCP Activity
**Expected:** Agent worktrees and branches are removed safely, summary shown; errors visible if any.

## Notes
- Parallel runs require a valid git repo and a clean working tree.
- Use small prompts to limit token usage during verification.

## Stopping Point
- MCP server running and responding to `tools/list` and `templates.list`.
- MCP Harness template available and runnable via MCP.
- MCP Activity dashboard visible in Agents sidebar under Infrastructure.

## Resume Checklist
1. Verify MCP server status (Settings shows running state).
2. Run `tools/list` and `templates.list` via MCP.
3. Run `chains.run` with `MCP Harness` on a clean worktree.

## Next Steps
- [x] Add persistent MCP run log + cleanup action (issue #16).
- [ ] Implement validation pipeline for MCP runs (issue #13).
- [ ] Add MCP Activity run detail panel (prompt/output/validation summary).
- [ ] Add MCP run timeline (agent status + tool events).
- [ ] Optional: prevent sleep while MCP chain is running.
- [ ] UX polish: icons, typography, and empty states in Agents sidebar and MCP dashboard.
