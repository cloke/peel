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
.package(url: "https://github.com/cloke/peel.git", from: "0.0.0"),
// then add "MCPCore" to the target dependencies
```

(If MCPCore is published as a separate repo, use that URL; if using this repo as a package, point to the repo and the package target.)

## 2. Initialize the server (app-embedded mode)

MCPCore exposes a server service that can be started inside your app lifecycle. Typical pattern in an AppDelegate/SceneDelegate or SwiftUI App:

```swift
import MCPCore

@main
struct MyApp: App {
  @StateObject private var mcpService = MCPServerService.shared // or init(config:)

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

Example init with config:

```swift
let config = MCPConfig(port: 8765, allowedTools: ["git", "shell"], repoRoot: "/path/to/repo")
let mcp = MCPServerService(config: config)
try await mcp.start()
```

## 3. Registering tools

MCPCore provides a ToolRegistry where app code can register custom tools (Swift closures or types conforming to the MCP tool protocol).

```swift
mcpService.toolRegistry.register(name: "my.custom.tool") { params in
  // handle invocation
  return .success(["result": "ok"])
}

// Or register a typed handler
mcpService.toolRegistry.register(MyGitTool())
```

When registering tools, provide clear, documented parameter and result schemas so clients know how to call them.

## 4. Connecting a client

Clients speak JSON-RPC over TCP or Unix domain sockets depending on config. A minimal JSON-RPC HTTP client example (using URLSession) or using a raw TCP socket will work.

Example JSON-RPC request (HTTP transport):

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tool.invoke",
  "params": { "tool": "my.custom.tool", "args": { "path": "/" } }
}
```

Expect a JSON-RPC response with either a `result` or `error` field.

## 5. Sample config file

Save a simple config file (YAML/JSON) and load it at startup to decouple from UserDefaults:

```json
{
  "port": 8765,
  "transport": "tcp",
  "allowedTools": ["git", "shell", "my.custom.tool"],
  "repoRoot": "/Users/me/code/repo",
  "logLevel": "info"
}
```

Load via:

```swift
let config = try MCPConfig.from(path: "/path/to/mcp-config.json")
let mcp = MCPServerService(config: config)
try await mcp.start()
```

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
