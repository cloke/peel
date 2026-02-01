# MCPServerKit

A reusable Swift package for embedding MCP (Model Context Protocol) servers in macOS/iOS apps.

## Features

- **JSON-RPC 2.0 HTTP server** with connection management
- **Tool registry** for registering and dispatching tool definitions
- **Configuration abstraction** for flexible settings storage
- **Tool handler protocol** with convenience helpers
- **LAN mode** support for network access control

## Installation

Add MCPServerKit as a local package dependency:

```swift
.package(path: "Local Packages/MCPServerKit")
```

## Quick Start

```swift
import MCPServerKit

// Create server with registry
let registry = MCPToolRegistry()
let server = MCPServer(port: 8765, registry: registry)

// Register tool definitions
registry.register(MCPToolDefinition(
  name: "my.tool",
  description: "Does something useful",
  inputSchema: ["type": "object", "properties": [:]],
  category: .state,
  isMutating: false
))

// Register tool handler
registry.register(handler: MyToolHandler())

// Start server
server.start()
```

## Architecture

### MCPServer

The main server class handles:
- TCP listener on configurable port
- HTTP request parsing
- JSON-RPC 2.0 protocol
- Connection lifecycle
- LAN mode enforcement

### MCPToolRegistry

Manages tool definitions and handlers:
- Register/lookup tool definitions
- Register tool handlers
- Permission checking
- tools/list response building

### MCPToolHandling

Protocol for implementing tool handlers:

```swift
@MainActor
public protocol MCPToolHandling: AnyObject {
  var supportedTools: Set<String> { get }
  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data)
}
```

### MCPServerConfigProviding

Protocol for configuration storage:

```swift
@MainActor
public protocol MCPServerConfigProviding {
  func bool(forKey: String, default: Bool) -> Bool
  func integer(forKey: String, default: Int) -> Int
  func string(forKey: String, default: String) -> String
  // ... setters
}
```

Default implementation `MCPUserDefaultsConfig` uses UserDefaults.

## Custom Request Handling

For app-specific methods, use the `onRequest` callback:

```swift
server.onRequest = { method, id, params in
  switch method {
  case "myapp.customMethod":
    return (200, JSONRPCResponseBuilder.makeResult(id: id, result: ["ok": true]))
  default:
    return nil // Fall through to built-in handling
  }
}
```

## Platform Requirements

- macOS 15.0+
- iOS 18.0+
- Swift 6.0+

## Dependencies

- MCPCore (types and JSON-RPC utilities)
