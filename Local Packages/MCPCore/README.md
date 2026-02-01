# MCPCore

A generic Swift package providing core types for Model Context Protocol (MCP) servers. Designed to be embedded in any macOS/iOS app to enable AI agent control and testing during development.

## Purpose

MCPCore provides the foundational types for building MCP-based automation:
- **JSON-RPC 2.0 protocol types** for communication
- **Agent orchestration types** (roles, models, states)
- **Chain templates** for multi-agent workflows
- **Data transfer objects** for persistence abstraction

## Installation

Add MCPCore as a Swift Package dependency:

```swift
dependencies: [
  .package(url: "https://github.com/crunchybananas/MCPCore.git", from: "1.0.0")
]
```

Then add `MCPCore` to your target's dependencies:

```swift
.target(name: "YourApp", dependencies: ["MCPCore"])
```

## Architecture Boundaries

### What's in MCPCore (Generic)

| Module | Types | Purpose |
|--------|-------|---------|
| JSONRPC | `JSONRPCRequest`, `JSONRPCResponse`, `JSONRPCError`, `JSONRPCId`, `JSONRPCParams`, `AnyCodable` | Protocol communication |
| ToolDefinition | `MCPToolCategory`, `MCPToolGroup`, `MCPToolDefinition`, `MCPToolPermission` | Tool metadata |
| AgentTypes | `MCPAgentRole`, `MCPAgentType`, `MCPAgentState`, `MCPFrameworkHint` | Agent configuration |
| CopilotModel | `MCPCopilotModel`, `MCPModelFamily` | AI model selection |
| ChainTemplate | `MCPChainTemplate`, `MCPAgentStepTemplate` | Workflow definitions |
| MCPDataTypes | `MCPRunRecordDTO`, `MCPRunResultDTO`, `MCPChainRunStatus`, `MCPServerStatus` | Data transfer |
| MCPDataPersisting | `MCPDataPersisting` protocol, `MCPNullDataStore` | Persistence abstraction |

### What's in the Host App (App-Specific)

| Component | Responsibility |
|-----------|---------------|
| MCP Server | HTTP server, request routing, tool dispatch |
| Tool Implementations | Actual tool logic (file ops, git, etc.) |
| Agent Execution | CLI invocation, process management |
| Validation Config | App-specific validation rules |
| SwiftData Models | Persistent storage implementation |
| UI | Views, navigation, user interaction |

## Public API

### Agent Roles

```swift
public enum MCPAgentRole: String, Codable {
  case planner     // Read-only: analyze, plan
  case implementer // Full access: edit files, run commands
  case reviewer    // Read-only: review changes
  
  var systemPrompt: String  // Role-specific instructions
  var canWrite: Bool        // Permission check
  var deniedTools: [String] // Tools to block
}
```

### AI Models

```swift
public enum MCPCopilotModel: String, Codable, CaseIterable {
  case claudeSonnet45, claudeHaiku45, claudeOpus45, claudeSonnet4
  case gpt51CodexMax, gpt51Codex, gpt52, gpt51, gpt5, gpt51CodexMini, gpt5Mini, gpt41
  case gemini3Pro
  
  var displayName: String
  var premiumCost: Double  // 0 = free tier
  var isFree: Bool
  var family: MCPModelFamily
}
```

### Chain Templates

```swift
public struct MCPChainTemplate: Identifiable, Codable {
  let id: UUID
  var name: String
  var description: String
  var steps: [MCPAgentStepTemplate]
  var isBuiltIn: Bool
  
  static var builtInTemplates: [MCPChainTemplate]  // 7 generic templates
}
```

### Data Persistence

```swift
public protocol MCPDataPersisting: Sendable {
  func saveRunRecord(_ record: MCPRunRecordDTO) async throws
  func loadRunRecords(limit: Int) async throws -> [MCPRunRecordDTO]
  func saveRunResult(_ result: MCPRunResultDTO) async throws
  func loadRunResults(forChainId: UUID) async throws -> [MCPRunResultDTO]
}
```

## Built-in Templates

| Template | Steps | Cost |
|----------|-------|------|
| Code Review | Planner → Implementer → Reviewer | ~2× premium |
| Quick Fix | Planner → Implementer | ~2× premium |
| Free Review | Planner → Implementer → Reviewer (all free) | Free |
| Deep Analysis | Planner (Opus) | 3× premium |
| Multi-Implementer | Planner → 2 Implementers | ~2× premium |
| Parallel Validation | Planner → 2 Implementers → Reviewer | ~2× premium |
| Parallel Validation (Free) | Same with free models | Free |

## Usage Example

```swift
import MCPCore

// Use type aliases for cleaner code
typealias AgentRole = MCPAgentRole
typealias CopilotModel = MCPCopilotModel

// Create a custom template
let template = MCPChainTemplate(
  name: "Custom Workflow",
  description: "My app's workflow",
  steps: [
    MCPAgentStepTemplate(role: .planner, model: .claudeSonnet45, name: "Analyzer"),
    MCPAgentStepTemplate(role: .implementer, model: .gpt41, name: "Worker")
  ]
)

// Implement persistence for your app
final class MyDataStore: MCPDataPersisting {
  func saveRunRecord(_ record: MCPRunRecordDTO) async throws {
    // Save to your database
  }
  // ... other methods
}
```

## Platform Requirements

- macOS 26.0+
- iOS 26.0+
- Swift 5.9+

## Dependencies

None. MCPCore is intentionally dependency-free to maximize portability.

## License

MIT
