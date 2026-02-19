---
title: MCP Embedding Guide
status: draft
updated: 2026-02-19
---

# MCP Embedding Guide

This guide explains how to embed MCPCore (the MCP server core) into another macOS/iOS app so other apps can expose MCP services or run chains programmatically.

## Goals
- Add MCPCore as a Swift Package dependency
- Initialize and run the server inside an app process (app-embedded mode)
- Register custom tools with the server tool registry
- Connect a JSON-RPC client to the embedded server

## 1. Add the package

In your Package.swift, add MCPCore as a dependency (example):

```swift
// Package.swift (snippet)
.package(url: "https://github.com/crunchybananas/MCPCore.git", from: "0.0.0"),
// then add "MCPCore" to the target dependencies
```

## 2. Initialize the server (app-embedded mode)

MCPCore exposes a server service that can be started inside your app lifecycle. Typical pattern in a SwiftUI App:

```swift
import MCPCore

@main
struct MyApp: App {
  @State private var mcpService = MCPServerService()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .onAppear {
          Task {
            try? await mcpService.start()
          }
        }
        .onDisappear {
          mcpService.stop()
        }
    }
  }
}
```

> **Note:** In app-embedded mode (Peel), server settings (port, allowed tools, repo root) are configured via the Settings UI and stored in UserDefaults. There is no public `MCPServerService.shared` singleton or `MCPConfig(...)` initializer in the current API — the service reads from app settings on start. For file-based config in headless mode, use `Tools/MCPCLI` instead (see [Headless section in MCP_CLI_USAGE](MCP_CLI_USAGE.md#headless-server-mcpcli)).

## 3. Registering tools

In Peel, custom tools are added by extending the MCPServerService tool handlers in `Shared/AgentOrchestration/`. There is no public `toolRegistry.register(...)` API; instead, add a new `case` in the appropriate handler file and implement its logic following the existing patterns.

When adding tools, provide clear parameter and result schemas so clients know how to call them. Use `JSONRPCResponseBuilder.makeResult` / `makeError` (from `MCPCore/JSONRPC.swift`) to build responses.

## 4. Connecting a client

Clients speak JSON-RPC over TCP or Unix domain sockets depending on config. A minimal JSON-RPC HTTP client example (using URLSession) or using a raw TCP socket will work.

Example JSON-RPC request (HTTP transport):

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": { "name": "my.custom.tool", "arguments": { "path": "/" } }
}
```

Expect a JSON-RPC response with either a `result` or `error` field.

## 5. Sample config file (headless / MCPCLI)

When running the server headlessly via `Tools/MCPCLI`, use a JSON config file:

```json
{
  "port": 8765,
  "repoRoot": "/Users/me/code/repo",
  "dataStorePath": "/Users/me/Library/Application Support/Peel",
  "allowedTools": null,
  "logLevel": "info"
}
```

See `Tools/MCPCLI/config.example.json` for the canonical template.

For app-embedded mode, the app configures the server via its Settings UI (no config file needed).

## 6. App-embedded vs Headless (CLI) differences and limitations

- App-embedded mode (recommended for UI apps):
  - Runs inside the host app process and can access AppKit/UIKit features (screenshots, UI automation).
  - Can reuse existing app credentials, keychain, and settings.
  - Tightly couples lifecycle to the app — server stops when the app quits.

- Headless / CLI mode:
  - Runs as a separate process (recommended for CI, servers, or other tools).
  - Must not rely on AppKit; UI automation and screenshot tooling will be unavailable or require a GUI session.
  - Uses file-based or explicit config instead of UserDefaults; permission prompts or UI-driven flows must be adapted.

**Limitations to note**:
- Tools that rely on accessibility APIs or ScreenCaptureKit will not function in headless mode.
- Keychain access across processes may require additional entitlements or user approval.
- App-embedded mode may leak UI-specific state into MCP — prefer explicit config objects for portability.

## 7. Best practices

- Register only the tools you intend to expose to untrusted clients. Use allowlists.
- Prefer explicit configuration objects over UserDefaults for reproducible runs.
- Document tool parameter schemas and error codes.
- Use authentication/ACLs on the transport if exposing MCP on a network interface.

---

For more details about headless feasibility and design decisions, see: ../guides/MCP_HEADLESS_FEASIBILITY.md
