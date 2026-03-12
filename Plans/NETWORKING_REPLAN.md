---
title: "Networking Replan: WebRTC-First Swarm Communication"
status: in-progress
tags:
  - networking
  - webrtc
  - swarm
  - distributed
  - cleanup
updated: 2026-06-09
---

# Networking Replan: WebRTC-First Swarm Communication

> **Goal**: Collapse five transports (Firestore coordination, TCP LAN, TCP WAN, STUN/UDP, WebRTC) into two layers: **Firestore** (identity + signaling + persistence) and **WebRTC** (everything real-time). Delete ~2,400 LOC of legacy transport code.

---

## Problem Statement

The current swarm networking has accumulated 25 files (~12K LOC) across five transport mechanisms. The architecture invariant ("Firestore = coordination, P2P = data") is declared in **five separate file headers** — evidence that the separation is confusing enough to need constant reminders.

**Current pain points:**
1. **Three-fallback transfer chain** (TCP LAN → TCP WAN → WebRTC) adds complexity for marginal benefit — WebRTC ICE already handles LAN/WAN/NAT traversal natively
2. **Custom STUN client** (~300 LOC) duplicates what WebRTC ICE does internally
3. **PeerConnectionManager** (~800 LOC TCP framing) is not actively wired — dead infrastructure from an older design
4. **FirestoreRelayTransfer** still exists in-tree despite being banned
5. **Task dispatch goes through Firestore** even when peers are already connected — 4 Firestore ops per MCP call with listener latency
6. **Per-transfer WebRTC connections** — full ICE negotiation for every RAG sync instead of reusing an open connection

**What we want:**
- WebRTC for data transfers, MCP messaging, heartbeats, and eventually chat + video
- Firestore for auth, signaling, offline coordination, and audit persistence
- No legacy code left sitting around

---

## Architecture: Two Layers

### Layer 1: Firestore — Identity, Signaling, Persistence

Firestore's role shrinks to things that **must survive** when peers aren't connected:

| Responsibility | Collection | Notes |
|----------------|------------|-------|
| **Auth & membership** | `swarms/{id}/members/` | Roles, permissions, invites |
| **Worker registry** | `swarms/{id}/workers/` | Capabilities, "I exist" registration |
| **WebRTC signaling** | `swarms/{id}/webrtcSignaling/` | SDP offers/answers + ICE candidates (unavoidable bootstrap) |
| **Offline task queue** | `swarms/{id}/tasks/` | Tasks for workers that aren't online yet |
| **Conversation archive** | `swarms/{id}/conversations/` | Persisted from RTC after delivery (see §Persistence) |
| **Transfer records** | `swarms/{id}/transfers/` | Metadata only (repoId, size, duration, timestamp) |
| **Activity log** | `swarms/{id}/activity/` | Audit trail of swarm events |

**What moves OUT of Firestore:**
- Real-time task dispatch (when peer is connected) → WebRTC `mcp` channel
- Heartbeats → WebRTC `heartbeat` channel
- Direct commands → WebRTC `mcp` channel
- Chat messages → WebRTC `chat` channel (persisted to Firestore after delivery)

### Layer 2: WebRTC — All Real-Time Communication

One **persistent** `RTCPeerConnection` per brain↔worker pair, established on swarm join, kept alive with ICE restarts on network changes.

**Named data channels on each connection:**

| Channel Label | Reliability | Data Format | Purpose |
|---------------|-------------|-------------|---------|
| `mcp` | Reliable / ordered | JSON-RPC 2.0 | MCP tool calls + results, task dispatch, direct commands |
| `transfer` | Reliable / ordered | Binary (chunked) | RAG artifacts, large file transfers |
| `heartbeat` | Unreliable / unordered | JSON | Ping/pong, worker status, resource utilization |
| `chat` | Reliable / ordered | JSON | Swarm messaging (persisted to Firestore after delivery) |
| *(future)* audio/video | RTP tracks | Media | Screen share, voice — already on the same RTCPeerConnection |

**Fallback behavior:**
- If the WebRTC connection is **open** → use data channels (sub-100ms latency, zero Firestore cost)
- If the WebRTC connection is **not open** → write to Firestore (offline task queue, signaling to reconnect)
- If the WebRTC connection **drops** → auto-reconnect via ICE restart; queue messages locally until reconnected; spill to Firestore after timeout

This replaces the current architecture invariant with a simpler rule: **WebRTC when connected, Firestore when not.**

---

## Persistence: What RTC Data Gets Saved to Firestore

Not everything over RTC is ephemeral. Key data is **written-through to Firestore** for reference and recovery:

| Data | When Persisted | Why |
|------|----------------|-----|
| **Task dispatch + results** | On send (brain) / on complete (worker) | Audit trail, recovery if connection drops mid-task |
| **Chat messages** | After successful RTC delivery, async write-behind | Conversation history across sessions |
| **Transfer metadata** | After transfer completes | Size, duration, repo, peer — for diagnostics and billing |
| **Connection events** | On connect/disconnect | Uptime tracking, debugging |
| **Worker status snapshots** | Periodic (every 60s) | Firestore presence for offline discovery |

**What is NOT persisted:**
- Heartbeat pings (ephemeral by design)
- Transfer data bytes (only metadata)
- ICE candidate churn during negotiation

**Implementation pattern:** Write-behind with local queue. The RTC channel is the primary transport. A background actor drains delivered messages to Firestore at low priority. If Firestore write fails, retry with exponential backoff — the data already reached the peer, persistence is best-effort.

---

## Cleanup: Files to Delete

These files are replaced by WebRTC's native capabilities or are already dead code:

| File | LOC | Reason for Deletion |
|------|-----|---------------------|
| `PeerConnectionManager.swift` | ~800 | TCP connection framing — replaced by WebRTC data channels. Not actively wired. |
| `STUNClient.swift` | ~300 | Custom RFC 5389 client — WebRTC ICE does STUN internally via Google STUN servers. |
| `WANAddressResolver.swift` | ~60 | HTTP-based public IP discovery — WebRTC ICE handles NAT traversal natively. |
| `FirestoreRelayTransfer.swift` | ~150 | Deprecated base64-through-Firestore relay. Banned by architecture invariant. Delete for real. |
| `OnDemandPeerTransfer.swift` | ~650 | Three-fallback transfer orchestrator — replaced by persistent WebRTC `transfer` channel. |
| `P2PConnectionLog.swift` | ~55 | Ring buffer for TCP/STUN events — rewritten for WebRTC events in new `PeerSession`. |
| `P2PLogRequestListener.swift` | ~90 | Firestore listener for remote log requests — folded into `PeerSession` diagnostics. |
| `LocalNetworkActorSystem.swift` | ~350 | DistributedActorSystem for LAN — never actively used; WebRTC replaces the transport. |
| **Total** | **~2,455** | |

### Files to Refactor

| File | LOC | Changes |
|------|-----|---------|
| `SwarmCoordinator.swift` | ~3000 | Remove TCP/STUN startup, add `PeerSessionManager` integration, route MCP dispatch through WebRTC when connected |
| `FirestoreWebRTCSignaling.swift` | ~200 | Adapt for persistent connections (reconnect signaling, ICE restart offers) |
| `WebRTCSignalingResponder.swift` | ~250 | Adapt for persistent connections; respond to reconnect offers |
| `BonjourDiscoveryService.swift` | ~455 | Keep as optimization hint — feed discovered LAN candidates to ICE for faster initial connection. No longer load-bearing. |
| `RAGArtifactSyncing.swift` | varies | Change from `OnDemandPeerTransfer` to `PeerSession.transferChannel` |
| `SwarmToolsHandler+TaskDispatch.swift` | varies | Route through WebRTC `mcp` channel when peer connected; Firestore fallback for offline |

### Files Unchanged

| File | Reason |
|------|--------|
| `FirebaseService.swift` | Still the Firestore backbone — auth, registry, offline queue, persistence |
| `FirebaseServiceTypes.swift` | Model types still needed |
| `DistributedTypes.swift` | Core task types still needed |
| `BranchQueue.swift` | Task infrastructure, unrelated to transport |
| `PRQueue.swift` | Task infrastructure, unrelated to transport |
| `RepoRegistry.swift` | Path mapping, unrelated to transport |
| `SwarmWorktreeManager.swift` | Git worktree management, unrelated to transport |
| `WorkerMode.swift` | Worker CLI mode, unrelated to transport |
| `PeelWorker.swift` | Deleted in Phase 3 — `ChainExecutorProtocol` extracted to `ChainExecutor.swift` |
| `SwarmPeerPreferences.swift` | Peer ordering preferences — adapt labels from "LAN/WAN" to connection quality |
| `SwarmStatusView.swift` | UI — update to show WebRTC connection state instead of TCP |
| `SwarmTaskOutputSheet.swift` | UI — unchanged |

---

## New Code

### `PeerSession` (new file: `Shared/Distributed/PeerSession.swift`)

Manages a single persistent WebRTC connection to one peer.

```swift
@Observable
actor PeerSession {
  let peerId: String
  let webrtcClient: WebRTCClient
  
  // Named data channels
  private(set) var mcpChannel: RTCDataChannel?
  private(set) var transferChannel: RTCDataChannel?
  private(set) var heartbeatChannel: RTCDataChannel?
  private(set) var chatChannel: RTCDataChannel?
  
  var isConnected: Bool { ... }
  var lastHeartbeat: Date? { ... }
  var roundTripMs: Double? { ... }
  
  // MCP messaging
  func sendMCPRequest(_ request: JSONRPCRequest) async throws -> JSONRPCResponse
  func mcpResponses() -> AsyncStream<JSONRPCResponse>
  
  // Data transfer
  func sendData(_ data: Data, manifest: TransferManifest) async throws
  func receiveData() -> AsyncStream<(TransferManifest, Data)>
  
  // Chat
  func sendChatMessage(_ message: ChatMessage) async throws
  func chatMessages() -> AsyncStream<ChatMessage>
  
  // Lifecycle
  func connect(signaling: WebRTCSignalingChannel) async throws
  func disconnect() async
  func reconnect() async throws  // ICE restart
}
```

### `PeerSessionManager` (new file: `Shared/Distributed/PeerSessionManager.swift`)

Manages all peer sessions. Replaces `PeerConnectionManager`.

```swift
@MainActor
@Observable
class PeerSessionManager {
  private(set) var sessions: [String: PeerSession] = [:]  // peerId → session
  
  var connectedPeers: [String] { ... }
  
  func connectToPeer(_ peerId: String, signaling: WebRTCSignalingChannel) async throws -> PeerSession
  func disconnectPeer(_ peerId: String) async
  func disconnectAll() async
  
  func session(for peerId: String) -> PeerSession?
  
  // Broadcast to all connected peers
  func broadcastMCP(_ request: JSONRPCRequest) async throws -> [String: JSONRPCResponse]
  func broadcastChat(_ message: ChatMessage) async throws
}
```

### `WebRTCMCPTransport` (new file: `Shared/Distributed/WebRTCMCPTransport.swift`)

Bridges MCP JSON-RPC to/from a WebRTC data channel.

```swift
actor WebRTCMCPTransport {
  func send(_ request: JSONRPCRequest, over channel: RTCDataChannel) async throws -> JSONRPCResponse
  func startListening(on channel: RTCDataChannel) -> AsyncStream<JSONRPCRequest>
}
```

### `PersistenceWriter` (new file: `Shared/Distributed/PersistenceWriter.swift`)

Background write-behind from RTC to Firestore.

```swift
actor PersistenceWriter {
  func enqueue(_ event: PersistableEvent)  // non-blocking
  func flush() async                        // drain queue to Firestore
  func start(interval: Duration = .seconds(5))  // periodic flush
}

enum PersistableEvent {
  case taskDispatched(ChainRequest)
  case taskCompleted(ChainResult)
  case chatMessage(ChatMessage)
  case transferCompleted(TransferRecord)
  case connectionEvent(ConnectionEvent)
  case workerStatusSnapshot(WorkerStatus)
}
```

### WebRTCTransfer Package Changes

| Change | Detail |
|--------|--------|
| **Multi-channel support** | `WebRTCClient` creates named data channels via `createDataChannel(label:)` instead of a single default |
| **Persistent lifecycle** | Remove `defer { client.close() }` pattern; add `reconnect()` with ICE restart |
| **Channel multiplexing** | Each channel gets its own message framing (existing chunked protocol stays on `transfer`; JSON framing on `mcp`/`chat`) |
| **Keep-alive** | `heartbeat` channel sends periodic pings; triggers reconnect if pongs stop |

---

## Migration Plan

### Phase 1: Foundation ✅ COMPLETE

**Goal:** Persistent WebRTC connections with multi-channel support.

| Step | Status | Description | Files |
|------|--------|-------------|-------|
| 1.1 | ✅ | Extend `WebRTCClient` to support multiple named data channels | `WebRTCClient.swift` |
| 1.2 | ✅ | Add `connect()` / `reconnect()` / keep-alive to `WebRTCClient` | `WebRTCClient.swift` |
| 1.3 | ✅ | Create `PeerSession` — wraps `WebRTCClient` with typed channel accessors | New: `PeerSession.swift` |
| 1.4 | ✅ | Create `PeerSessionManager` — manages session lifecycle | New: `PeerSessionManager.swift` |
| 1.5 | ✅ | Adapt `WebRTCSignalingResponder` for persistent sessions (routes `purpose="session"` to PeerSessionManager) | `WebRTCSignalingResponder.swift` |
| 1.6 | ✅ | Wire `PeerSessionManager` into `SwarmCoordinator.start()` — on swarm join, establish persistent connections to all known workers | `SwarmCoordinator.swift` |

**Commits:** b491e8b (foundation files), edbeadd (signaling + coordinator wiring)

### Phase 2: MCP Over WebRTC ✅ COMPLETE

**Goal:** Task dispatch and tool calls flow over the `mcp` data channel.

| Step | Status | Description | Files |
|------|--------|-------------|-------|
| 2.1 | ✅ | Create `WebRTCMCPTransport` — JSON-RPC framing over data channel | New: `WebRTCMCPTransport.swift` |
| 2.2 | ✅ | `SwarmCoordinator.sendMessage()` — checks WebRTC mcp channel first, falls back to TCP | `SwarmCoordinator.swift` |
| 2.3 | ✅ | Worker-side WebRTC listener — `startListeningOnPeerSession()` reads PeerMessages from mcp channel, routes through existing handler | `SwarmCoordinator.swift` |
| 2.4 | ✅ | `dispatchChain`, `dispatchToWorker`, `sendDirectCommand`, `sendDirectCommandAndWait` all use `sendMessage()` abstraction | `SwarmCoordinator.swift` |
| 2.5 | ⏳ | Move heartbeats to `heartbeat` channel (unreliable) — Firestore heartbeat becomes periodic snapshot only | `SwarmCoordinator.swift` |

**Note:** Step 2.2 changed from plan — transport abstraction lives in SwarmCoordinator.sendMessage() instead of SwarmToolsHandler, which is cleaner since dispatch methods are already in SwarmCoordinator.

**Commits:** b491e8b (WebRTCMCPTransport), edbeadd (transport abstraction + listener)

### Phase 3: Transfer Channel Migration & Legacy Cleanup ✅ COMPLETE

**Goal:** RAG transfers use persistent sessions; delete all legacy transport code.

| Step | Status | Description | Files |
|------|--------|-------------|-------|
| 3.1 | ✅ | Refactor `RAGSyncCoordinator` to delegate to `SwarmCoordinator.requestRagArtifactSync()` — removes `OnDemandPeerTransfer` dependency | `RAGSyncCoordinator.swift` |
| 3.2 | ✅ | Add `waitForTransferCompletion()` to SwarmCoordinator for async transfer monitoring | `SwarmCoordinator.swift` |
| 3.3 | ✅ | Broaden `requestRagArtifactSync()` to find WebRTC-only peers (not just TCP `connectedWorkers`) | `SwarmCoordinator.swift` |
| 3.4 | ✅ | Delete `OnDemandPeerTransfer.swift` (~650 LOC) | Delete |
| 3.5 | ✅ | Delete `STUNClient.swift` (~300 LOC) | Delete |
| 3.6 | ✅ | Delete `FirestoreRelayTransfer.swift` (~150 LOC) | Delete |
| 3.7 | ✅ | Delete `LocalNetworkActorSystem.swift` (~350 LOC) | Delete |
| 3.8 | ✅ | Delete `PeelWorker.swift` (~100 LOC) — extract `ChainExecutorProtocol` to new `ChainExecutor.swift` | Delete + New |
| 3.9 | ✅ | Delete `P2PConnectionLog.swift` (~55 LOC) and `P2PLogRequestListener.swift` (~90 LOC) | Delete |
| 3.10 | ✅ | Replace all `P2PConnectionLog.shared.log()` with `Logger` in SwarmCoordinator and WebRTCSignalingResponder | Modified |
| 3.11 | ✅ | Remove `requestRagSyncOnDemand()` bridge, `webrtcResponder` passthrough, `firestoreRelayProvider`, `logRequestListener` from SwarmCoordinator | Modified |
| 3.12 | ✅ | Deprecate MCP tools: `swarm.p2p-logs`, `swarm.request-logs`, `swarm.stun-test` | `SwarmToolsHandler+PeerDiscovery.swift` |
| 3.13 | ✅ | Update `RepoDetailRAGTabView` and `MCPServerService+SmallDelegates` to use new APIs | Modified |
| — | ⏳ | Delete `PeerConnectionManager.swift` — still used as TCP fallback in `sendMessage()`. Deferred to Phase 5. | Deferred |
| — | ⏳ | Delete `WANAddressResolver.swift` — still useful for diagnostics. Deferred to Phase 5. | Deferred |

**Net LOC:** ~3,080 deleted, ~348 added (including ChainExecutor extraction)
**Commits:** 384b9dc

### Phase 4: Persistence & Chat

**Goal:** Write-behind persistence and chat messaging.

| Step | Description | Files |
|------|-------------|-------|
| 4.1 | Create `PersistenceWriter` — background Firestore write-behind for RTC events | New: `PersistenceWriter.swift` |
| 4.2 | Wire persistence for task dispatch/results | `SwarmCoordinator.swift`, `PersistenceWriter.swift` |
| 4.3 | Add `chat` data channel to `PeerSession` | `PeerSession.swift` |
| 4.4 | Wire chat persistence (write-behind after RTC delivery) | `PersistenceWriter.swift` |
| 4.5 | Update `SwarmStatusView` — show WebRTC connection state, channel health, RTT | `SwarmStatusView.swift` |
| 4.6 | Migrate swarm chat UI from Firestore-direct to RTC+persistence | `SwarmStatusView.swift` |

### Phase 5: Cleanup & Docs

**Goal:** Remove all references to deleted types, update architecture docs.

| Step | Description |
|------|-------------|
| 5.1 | Remove all imports/references to deleted types across the codebase |
| 5.2 | Update `copilot-instructions.md` — replace architecture invariant with new "WebRTC when connected, Firestore when not" rule |
| 5.3 | Archive `DISTRIBUTED_PEEL_DESIGN.md` (already superseded) |
| 5.4 | Update `FIRESTORE_SWARM_DESIGN.md` with reduced Firestore scope |
| 5.5 | Update ROADMAP.md swarm architecture diagram |
| 5.6 | Delete architecture invariant banners from remaining files (no longer needed — the design is simple enough) |

---

## New Architecture Invariant

Replace the current 5-file banner with one simple rule:

> **WebRTC when connected, Firestore when not.**
>
> - If a peer session is open → all communication flows over WebRTC data channels (MCP, transfers, heartbeats, chat).
> - If no peer session → work queues to Firestore for the peer to pick up when it reconnects.
> - Firestore is always the source of truth for: auth, membership, signaling, and archived conversations/task history.
> - Key RTC events are written-behind to Firestore asynchronously for persistence and audit.

---

## Risk & Mitigation

| Risk | Mitigation |
|------|------------|
| **ICE failures on restrictive NATs** | Add TURN server support (coturn or Twilio). STUN-only works for most home/office NATs but symmetric NAT requires TURN. |
| **WebRTC library stability** | stasel/WebRTC is actively maintained; pin to known-good version. If issues arise, Google's WebRTC is the upstream. |
| **Data channel message size limits** | Existing 64KB chunking protocol handles this. SCTP fragmentation is also automatic. |
| **Persistence write-behind lag** | Local message queue survives app restart via SwiftData. Firestore write is best-effort — data already reached the peer. |
| **Bonjour removal breaks LAN speed** | Keep Bonjour as ICE candidate hint, not transport. Discovered LAN IPs fed to ICE as pre-candidates for faster connection. |
| **Migration complexity** | Phased approach — each phase is independently testable. Phase 1 can run alongside existing TCP code before Phase 3 deletes it. |

---

## Firestore Cost Impact

| Operation | Before (per MCP call) | After |
|-----------|----------------------|-------|
| Task dispatch | 1 Firestore write + 1 listener read | 0 (WebRTC) or 1 write (offline fallback) |
| Task result | 1 Firestore write + 1 listener read | 0 (WebRTC) + 1 async write-behind |
| Heartbeat | 1 Firestore write every 30s per worker | 1 Firestore write every 60s (snapshot only) |
| Direct command | 1 write + 1 read + 1 result write | 0 (WebRTC) |
| Chat message | 1 write + N reads | 0 (WebRTC) + 1 async write-behind |

**Estimated reduction**: 80-90% fewer Firestore operations during active swarm sessions.

---

## Open Questions

1. **TURN server**: Self-hosted (coturn) or managed (Twilio/Cloudflare)? Needed for symmetric NAT traversal. Could defer until someone actually hits this.
2. **Multi-brain topology**: Current design assumes one brain + N workers. If two brains need to coordinate, do they peer directly or relay through a worker? (Defer — current use case is single brain.)
3. **iOS peer sessions**: iOS background execution limits WebRTC keep-alive. Accept that iOS peers disconnect when backgrounded and reconnect on foreground? (Probably fine — iOS is not a worker target.)
4. **Message ordering guarantees**: Reliable/ordered SCTP channels have head-of-line blocking. For MCP calls this is fine (request-response). For transfers, consider if unordered would be faster for large files. (Test and measure.)

---

## References

- [FIRESTORE_SWARM_DESIGN.md](FIRESTORE_SWARM_DESIGN.md) — Firestore auth/security model (still relevant)
- [DISTRIBUTED_TASK_TYPES_SPEC.md](DISTRIBUTED_TASK_TYPES_SPEC.md) — Task payload schemas (still relevant)
- [SWARM_WORKTREE_INTEGRATION.md](SWARM_WORKTREE_INTEGRATION.md) — Worktree isolation (orthogonal, unaffected)
- [SWARM_WORKTREE_RELIABILITY.md](SWARM_WORKTREE_RELIABILITY.md) — Worktree persistence (orthogonal, unaffected)
- `Local Packages/WebRTCTransfer/` — Current WebRTC implementation (foundation for changes)
- stasel/WebRTC: https://github.com/nicklama/webrtc-swift (Google WebRTC Cocoa wrapper, >= v141)

---

**Last Updated**: March 11, 2026
