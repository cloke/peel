---
title: MCP Headless/CLI Feasibility
status: active
updated: 2026-01-20
audience:
  - developer
  - ai-agent
related_issues:
  - 67
---

# MCP Headless/CLI Feasibility

## Summary
This document outlines constraints and a proposed path to running MCP without the full SwiftUI app shell.

## Current Dependencies (macOS app)
- `MCPServerService` is hosted inside the SwiftUI app lifecycle.
- UI automation tools depend on AppKit and accessibility APIs.
- Screenshot capture uses `ScreenCaptureKit` and AppKit.
- Agent orchestration relies on settings stored in `UserDefaults`.

## Constraints
- Headless mode cannot provide UI automation tools.
- Screenshot capture likely requires a GUI session.
- Some settings (e.g. tool permissions) are tied to app UI.

## Proposed Module Split
1. **MCPCore** (new Swift package)
   - JSON-RPC server, tool registry, basic RAG, and core chain execution.
2. **MCPApp** (current app)
   - UI automation tools, settings UI, and AppKit-only features.
3. **MCPCLI** (new CLI target)
   - Launches `MCPCore` in headless mode with explicit config file input.

## Proposed CLI Bootstrap
- CLI entrypoint loads a config file:
  - Port
  - Allowed tools
  - Repo/worktree root
  - Default templates
- CLI starts `MCPCore` and logs to stdout.

## Recommended Next Steps
- Extract `MCPServerService` networking and tool registry into a package.
- Replace `UserDefaults` usage with a configuration interface in headless mode.
- Gate UI automation and screenshot tools behind a feature flag.
