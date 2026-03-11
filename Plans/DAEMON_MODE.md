---
title: Always-On Daemon Mode
status: v1-complete
tags:
  - daemon
  - mcp-server
  - background
github-issue: "#371"
updated: 2026-06-28
---

# Always-On Daemon Mode

## Problem Statement

The MCP server only runs while the Peel GUI is open. This means:
- Agents can't run overnight unless the user leaves the window open
- External tools (VS Code, terminal) can't reach Peel after the window is closed
- No way to schedule cron-like chain runs
- Closing the window kills in-progress chains

## Design: V1 — Background App Mode

Instead of extracting the MCP server into a separate process (complex, ~26K lines of code + all service dependencies), V1 keeps everything in one process but changes the app lifecycle:

### How it works

1. **Background mode on window close** — When "Run in Background" is enabled and the user closes the window, the app switches to `NSApp.setActivationPolicy(.accessory)`. This hides from the Dock but keeps the process alive.

2. **Menu bar indicator** — A `NSStatusItem` (system tray icon) shows that Peel is running. Menu actions: Open Peel, Quit.

3. **Login item registration** — Optionally registers via `SMAppService.mainApp` so Peel launches at login automatically.

4. **Foreground restoration** — Clicking "Open Peel" in the menu bar returns to `.regular` activation policy and opens the window.

### Architecture

```
┌─ PeelAppDelegate ──────────────────────────────────┐
│  applicationShouldTerminateAfterLastWindowClosed()  │
│  → asks DaemonModeService                           │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─ DaemonModeService ────────────────────────────┐
│  runInBackground: Bool  (UserDefaults)         │
│  startAtLogin: Bool     (SMAppService)         │
│  isBackgroundMode: Bool (runtime state)        │
│                                                │
│  enterBackgroundMode()                         │
│    → setActivationPolicy(.accessory)           │
│    → show NSStatusItem (menu bar icon)         │
│                                                │
│  bringToForeground()                           │
│    → setActivationPolicy(.regular)             │
│    → activate app, hide status item            │
│                                                │
│  shouldTerminateAfterLastWindowClosed() → Bool │
│    → false if runInBackground (enter bg mode)  │
│    → true otherwise (normal quit)              │
└────────────────────────────────────────────────┘
```

### MCP Tools

| Tool | Description |
|------|-------------|
| `app.daemon.status` | Returns `isBackgroundMode`, `runInBackground`, `startAtLogin` |
| `app.daemon.configure` | Sets `runInBackground` and/or `startAtLogin` |

### Settings UI

New "Background Mode" section in Settings → MCP tab with:
- Toggle: "Keep MCP Server Running in Background"
- Toggle: "Start at Login"
- Status indicator when running in background

## Files

| File | Purpose |
|------|---------|
| `Shared/Services/DaemonModeService.swift` | Core service: background mode, login item, status bar |
| `Shared/PeelApp.swift` | `PeelAppDelegate` + wiring |
| `Shared/Views/SettingsView.swift` | Background Mode settings section |
| `Shared/AgentOrchestration/MCPServerService.swift` | `daemonModeService` property + handler methods |
| `Shared/AgentOrchestration/MCPServerService+ServerCore.swift` | Tool dispatch for `app.daemon.*` |
| `Shared/AgentOrchestration/MCPServerService+ToolDefinitions.swift` | Tool definitions for `app.daemon.*` |

## Implementation Status

### V1: Background App Mode ✅ Complete
- [x] `DaemonModeService` with background mode lifecycle
- [x] `PeelAppDelegate` intercepting window close
- [x] `SMAppService.mainApp` login item registration
- [x] `NSStatusItem` menu bar indicator
- [x] Settings UI toggles
- [x] MCP tools: `app.daemon.status`, `app.daemon.configure`
- [x] Build passes cleanly

### V2: Separate LaunchAgent (Future)
For a daemon that survives force-quit and supports true service behavior:
- [ ] Extract core MCP server + chain runner into a separate executable target
- [ ] Register via `SMAppService.agent(plistName:)` as a LaunchAgent
- [ ] GUI app connects to daemon via HTTP (already the protocol)
- [ ] Auto-restart via launchd `KeepAlive` configuration
- [ ] Shared SwiftData store between daemon and app

### V3: Health Monitoring & Scheduling (Future)
- [ ] Watchdog: auto-restart on crash
- [ ] Cron-like chain scheduling (run template X every N hours)
- [ ] Health check endpoint (uptime, memory, active chains)
