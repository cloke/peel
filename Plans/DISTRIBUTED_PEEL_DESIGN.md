---
title: Distributed Peel Design
status: superseded
created: 2026-01-27
updated: 2026-01-30
tags:
  - distributed
  - swarm
  - cloudkit
audience:
  - developer
  - ai-agent
notes: Superseded by Bonjour/LAN swarm implementation. CloudKit approach deferred.
---

# Distributed Peel Design

**Status:** Design Draft (Superseded by Swarm)  
**Created:** January 27, 2026  
**Goal:** Enable Peel instances to form a swarm where a **Crown** (Mac Studio) coordinates work across multiple devices.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         iCloud Private Zone                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ TaskQueue   │  │ WorkerLease │  │ ResultStore │              │
│  │ (CKRecord)  │  │ (CKRecord)  │  │ (CKRecord)  │              │
│  └─────────────┘  └─────────────┘  └─────────────┘              │
└─────────────────────────────────────────────────────────────────┘
                              │
           ┌──────────────────┼──────────────────┐
           │                  │                  │
           ▼                  ▼                  ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  Mac Studio      │  │  MacBook Pro     │  │  Mac Mini        │
│  (Crown/Peel)    │  │  (Peel)          │  │  (Peel)          │
│                  │  │                  │  │                  │
│  - Task dispatch │  │  - Poll tasks    │  │  - Poll tasks    │
│  - Heavy compute │  │  - Execute       │  │  - Execute       │
│  - Coordination  │  │  - Report back   │  │  - Report back   │
└──────────────────┘  └──────────────────┘  └──────────────────┘
           │                  │                  │
           └──────────────────┼──────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │   LAN Discovery   │
                    │    (Bonjour)      │
                    │                   │
                    │  Fast path when   │
                    │  co-located       │
                    └───────────────────┘
```

---

## Phase 1: LAN-First Prototype (Start Here)

**Why start with LAN?**
- Faster iteration (no CloudKit provisioning)
- Lower latency for testing
- Simpler debugging
- Same actor model works for both

### Transport Layer Options

| Option | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **Swift Distributed Actors + WebSocket** | Native Swift, type-safe | Requires custom transport | ✅ Best fit |
| **Bonjour + NWConnection** | Apple-native, auto-discovery | Lower-level, more code | Good for discovery |
| **gRPC** | Battle-tested, cross-platform | External dependency, codegen | Overkill for now |
| **Raw HTTP/JSON-RPC** | Simple, debuggable | Not type-safe | Fallback option |

### Recommended Stack

```swift
// 1. Discovery: Bonjour/mDNS
let browser = NWBrowser(for: .bonjour(type: "_peel._tcp", domain: nil), using: .tcp)

// 2. Connection: NWConnection for LAN
let connection = NWConnection(to: endpoint, using: .tcp)

// 3. Protocol: Swift Distributed Actors
distributed actor PeelWorker {
  distributed func executeChain(_ request: ChainRequest) async throws -> ChainResult
  distributed func getCapabilities() async -> WorkerCapabilities
  distributed func heartbeat() async -> WorkerStatus
}
```

### Implementation Steps

1. **Define the Actor Protocol** (2h)
   ```swift
   // Shared/Distributed/PeelWorkerActor.swift
   distributed actor PeelWorker {
     typealias ActorSystem = LocalNetworkActorSystem
     
     distributed func executeChain(
       template: String,
       prompt: String,
       workingDir: String
     ) async throws -> ChainResult
     
     distributed func reportCapabilities() async -> WorkerCapabilities
     distributed func claimTask(_ taskId: String) async throws -> Bool
   }
   ```

2. **Build LocalNetworkActorSystem** (4h)
   - WebSocket transport (or NWConnection)
   - Bonjour service advertisement
   - Peer discovery and connection management

3. **Create PeelDaemon mode** (3h)
  - Peel launches in headless **Peel** mode
  - Advertises via Bonjour
  - Polls for tasks from Crown

4. **Add Crown coordination** (4h)
  - Task queue management
  - Peel health monitoring
  - Result aggregation

---

## Phase 2: CloudKit Persistence (WAN Support)

Once LAN works, add CloudKit for:
- **Task durability** - Tasks survive device reboots
- **WAN connectivity** - Work across networks
- **Offline support** - Queue tasks when workers unavailable

### CloudKit Schema

```swift
// TaskRecord
CKRecord(recordType: "Task") {
  taskId: String (indexed)
  status: String // pending, claimed, running, complete, failed
  templateName: String
  prompt: String
  workingDirectory: String
  priority: Int64
  createdAt: Date
  claimedBy: String? // peel device ID
  claimedAt: Date?
  completedAt: Date?
  resultAsset: CKAsset? // compressed result
}

// PeelRecord  
CKRecord(recordType: "Peel") {
  deviceId: String (indexed)
  deviceName: String
  capabilities: Data // JSON: gpu cores, memory, models loaded
  lastHeartbeat: Date
  status: String // online, busy, offline
  currentTaskId: String?
  lanAddress: String? // for direct connect optimization
}

// LeaseRecord (prevents double-claim)
CKRecord(recordType: "Lease") {
  taskId: String (indexed)
  peelId: String
  expiresAt: Date
  renewedAt: Date
}
```

### Sync Strategy

```
┌─────────────────────────────────────────────────────────┐
│                    Task Lifecycle                        │
├─────────────────────────────────────────────────────────┤
│  1. Crown creates Task (status: pending)                │
│  2. Peel polls, finds pending task                      │
│  3. Peel creates Lease, updates Task (status: claimed)  │
│  4. Peel executes, updates Task (status: running)       │
│  5. Peel uploads result, updates Task (status: done)    │
│  6. Crown receives CKSubscription notification          │
│  7. Crown fetches result, deletes Task (or archives)    │
└─────────────────────────────────────────────────────────┘
```

---

## Phase 3: Capability-Based Routing

Peels advertise what they can do:

```swift
struct WorkerCapabilities: Codable {
  let deviceId: String
  let deviceName: String
  
  // Hardware
  let gpuCores: Int
  let neuralEngineCores: Int
  let memoryGB: Int
  let storageAvailableGB: Int
  
  // Loaded Models
  let embeddingModel: String?
  let embeddingDimensions: Int?
  
  // Indexed Repos (for RAG)
  let indexedRepos: [String]
  
  // Network
  let lanAddress: String?
  let preferLAN: Bool
}
```

Crown routes tasks based on capabilities:

```swift
func selectPeel(for task: Task) async -> PeelWorker? {
  let peels = await discoverPeels()
  
  // Filter by capability
  let capable = peels.filter { peel in
    if task.requiresGPU && peel.capabilities.gpuCores < 8 {
      return false
    }
    if let requiredRepo = task.repoPath,
       !peel.capabilities.indexedRepos.contains(requiredRepo) {
      return false
    }
    return true
  }
  
  // Prefer LAN if available
  if let lanPeel = capable.first(where: { $0.capabilities.lanAddress != nil }) {
    return lanPeel
  }
  
  // Fall back to any capable peel
  return capable.first
}
```

---

## Security Model

### Authentication
- **Same iCloud account** = trusted peer (Phase 1-2)
- **CloudKit Sharing** = invite specific devices/users (Phase 3)

### Authorization
- Peels can only execute chains, not access Crown's local files
- Results are encrypted at rest in CloudKit
- LAN transport uses TLS

### Sandboxing
- Peel runs chain in isolated worktree
- No access to Crown's credentials/tokens
- Task payloads are sanitized

---

## MCP Integration

The existing MCP tools work naturally:

```bash
# From any Peel instance, dispatch to Crown
curl -X POST http://127.0.0.1:8765/rpc -d '{
  "method": "tools/call",
  "params": {
    "name": "chains.run",
    "arguments": {
      "prompt": "Fix the login bug",
      "distributed": true,  // NEW: route to best peel
      "preferPeel": "mac-studio"  // NEW: optional affinity
    }
  }
}'
```

New tools for swarm management:

```
swarm.workers.list     - List connected peels and status
swarm.workers.ping     - Health check specific peel  
swarm.tasks.list       - Show pending/running tasks
swarm.tasks.cancel     - Cancel a distributed task
swarm.capabilities     - Show aggregate swarm capabilities
```

---

## Implementation Roadmap

### Week 1: LAN Foundation
- [ ] Define `PeelWorker` distributed actor protocol
- [ ] Build `LocalNetworkActorSystem` with WebSocket transport
- [ ] Add Bonjour service advertisement/discovery
- [ ] Create peel daemon launch mode

### Week 2: Task Execution
- [ ] Implement task claim/execute/report cycle
- [ ] Add heartbeat and peel health monitoring
- [ ] Wire up chain execution on peel side
- [ ] Return results to Crown

### Week 3: CloudKit Layer
- [ ] Define CloudKit schema (Task, Peel, Lease)
- [ ] Implement task persistence and sync
- [ ] Add CKSubscription for push notifications
- [ ] Handle offline/reconnect scenarios

### Week 4: Polish & Security
- [ ] Add capability-based routing
- [ ] Implement task prioritization
- [ ] Add swarm MCP tools
- [ ] Security review and hardening

---

## Open Questions

1. **Peel identity**: Use device UUID? iCloud user ID? Custom registration?
2. **Task serialization**: Codable JSON? Protocol Buffers? FlatBuffers?
3. **Large payloads**: Stream via CKAsset? Chunk and reassemble?
4. **Conflict resolution**: What if two peels claim same task?
5. **Rate limiting**: How to prevent runaway task spawning?

---

## Related Issues

- #142 - Distributed task execution via CloudKit (parent)
- #143 - CloudKit schema design
- #144 - Leasing + heartbeat protocol
- #145 - Peel daemon prototype
- #149 - LAN direct transport

---

## Next Steps

1. **Create #184**: LAN actor system prototype
2. **Create #185**: Bonjour discovery service
3. **Create #186**: Peel daemon mode
4. Start with hardcoded two-machine test before generalizing
