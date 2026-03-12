---
title: "Networking: WebRTC-First Swarm Communication"
status: in-progress
tags:
  - networking
  - webrtc
  - swarm
  - distributed
  - reliability
updated: 2026-03-12
---

# Networking: WebRTC-First Swarm Communication

> **Goal**: Two clean layers — **Firestore** (identity + signaling + persistence) and **WebRTC** (everything real-time) — with no race conditions, no dead code, and no God Objects.

This is the single source of truth for all networking work. It consolidates the original migration plan (formerly `NETWORKING_REPLAN.md`) and the reliability/cleanup work identified during a March 2026 deep dive.

---

## Architecture: Two Layers

### The Rule

> **WebRTC when connected, Firestore when not.**
>
> - If a peer session is open → all communication flows over WebRTC data channels.
> - If no peer session → work queues to Firestore for the peer to pick up when it reconnects.
> - Firestore is always the source of truth for: auth, membership, signaling, and archived conversations/task history.
> - Key RTC events are written-behind to Firestore asynchronously for persistence and audit.

### Layer 1: Firestore — Identity, Signaling, Persistence

Firestore carries only small JSON documents — never bulk data. It handles things that **must survive** when peers aren't connected:

| Responsibility | Collection | Notes |
|----------------|------------|-------|
| **Auth & membership** | `swarms/{id}/members/` | Roles, permissions, invites |
| **Worker registry** | `swarms/{id}/workers/` | Capabilities, "I exist" registration |
| **WebRTC signaling** | `swarms/{id}/webrtcSignaling/` | SDP offers/answers + ICE candidates (unavoidable bootstrap) |
| **Offline task queue** | `swarms/{id}/tasks/` | Tasks for workers that aren't online yet |
| **Conversation archive** | `swarms/{id}/conversations/` | Persisted from RTC after delivery |
| **Transfer records** | `swarms/{id}/transfers/` | Metadata only (repoId, size, duration, timestamp) |
| **Activity log** | `swarms/{id}/activity/` | Audit trail of swarm events |

### Layer 2: WebRTC — All Real-Time Communication

One **persistent** `RTCPeerConnection` per brain↔worker pair, established on swarm join, kept alive with ICE restarts on network changes.

| Channel Label | Reliability | Data Format | Purpose |
|---------------|-------------|-------------|---------|
| `mcp` | Reliable / ordered | JSON-RPC 2.0 | MCP tool calls + results, task dispatch, direct commands |
| `transfer` | Reliable / ordered | Binary (chunked) | RAG artifacts, large file transfers |
| `heartbeat` | Unreliable / unordered | JSON | Ping/pong, worker status, resource utilization |
| `chat` | Reliable / ordered | JSON | Swarm messaging (persisted to Firestore after delivery) |
| *(future)* audio/video | RTP tracks | Media | Screen share, voice — already on the same RTCPeerConnection |

### Fallback Behavior

| Scenario | Behavior |
|----------|----------|
| WebRTC connection is **open** | Use data channels (sub-100ms latency, zero Firestore cost) |
| WebRTC connection is **not open** | Write to Firestore (offline task queue, signaling to reconnect) |
| WebRTC connection **drops** | Auto-reconnect via ICE restart; queue messages locally; spill to Firestore after timeout |
| All P2P paths fail for **data transfer** | **Fail with an error.** Do NOT relay data through Firestore. Fix the P2P path. |

### Persistence: What RTC Data Gets Saved

| Data | When Persisted | Why |
|------|----------------|-----|
| **Task dispatch + results** | On send / on complete | Audit trail, recovery if connection drops mid-task |
| **Chat messages** | After successful RTC delivery | Conversation history across sessions |
| **Transfer metadata** | After transfer completes | Diagnostics and billing |
| **Connection events** | On connect/disconnect | Uptime tracking |
| **Worker status snapshots** | Periodic (~60s) | Firestore presence for offline discovery |

**Not persisted:** heartbeat pings, transfer data bytes, ICE candidate churn.

**Pattern:** Write-behind with local queue. RTC is the primary transport. A background actor drains delivered messages to Firestore at low priority. If Firestore write fails, retry with backoff — the data already reached the peer.

### Firestore Cost Impact

| Operation | Before (per MCP call) | After |
|-----------|----------------------|-------|
| Task dispatch | 1 Firestore write + 1 listener read | 0 (WebRTC) or 1 write (offline fallback) |
| Task result | 1 Firestore write + 1 listener read | 0 (WebRTC) + 1 async write-behind |
| Heartbeat | 1 Firestore write every 30s per worker | 1 Firestore write every 60s (snapshot only) |
| Direct command | 1 write + 1 read + 1 result write | 0 (WebRTC) |
| Chat message | 1 write + N reads | 0 (WebRTC) + 1 async write-behind |

Estimated reduction: 80-90% fewer Firestore operations during active swarm sessions.

---

## Hard Rules

These are non-negotiable. Violating any of them is a bug.

1. **No bulk data through Firestore — ever.** RAG artifacts, embeddings, file chunks, or any payload > 1 KB must go over WebRTC. If WebRTC is down, the transfer **fails**.
2. **No gating on TCP `connectedWorkers`.** Workers discover tasks via Firestore listeners or WebRTC `mcp` messages. They do not need to be in `connectedWorkers` to receive work.
3. **No coordination through legacy TCP.** `PeerConnectionManager` is dead code slated for deletion.
4. **Fail loudly.** If a transfer can't complete, mark it as **failed** with a clear error and log enough context to diagnose.
5. **One connection per peer.** Do not create per-transfer WebRTC connections. Reuse the persistent `RTCPeerConnection`.

---

## Completed Work (Phases 1–3)

### Phase 1: Foundation ✅

Persistent WebRTC connections with multi-channel support.

| Step | Description | Files |
|------|-------------|-------|
| 1.1 ✅ | Extend `WebRTCClient` for multiple named data channels | `WebRTCClient.swift` |
| 1.2 ✅ | Add `connect()` / `reconnect()` / keep-alive | `WebRTCClient.swift` |
| 1.3 ✅ | Create `PeerSession` — wraps `WebRTCClient` with typed channel accessors | `PeerSession.swift` |
| 1.4 ✅ | Create `PeerSessionManager` — manages session lifecycle | `PeerSessionManager.swift` |
| 1.5 ✅ | Adapt `WebRTCSignalingResponder` for persistent sessions | `WebRTCSignalingResponder.swift` |
| 1.6 ✅ | Wire `PeerSessionManager` into `SwarmCoordinator.start()` | `SwarmCoordinator.swift` |

Commits: b491e8b, edbeadd

### Phase 2: MCP Over WebRTC ✅

Task dispatch and tool calls flow over the `mcp` data channel.

| Step | Description | Files |
|------|-------------|-------|
| 2.1 ✅ | Create `WebRTCMCPTransport` — JSON-RPC framing over data channel | `WebRTCMCPTransport.swift` |
| 2.2 ✅ | `SwarmCoordinator.sendMessage()` checks WebRTC first, falls back to TCP | `SwarmCoordinator.swift` |
| 2.3 ✅ | Worker-side WebRTC listener via `startListeningOnPeerSession()` | `SwarmCoordinator.swift` |
| 2.4 ✅ | All dispatch methods use `sendMessage()` abstraction | `SwarmCoordinator.swift` |
| 2.5 ⏳ | Move heartbeats to `heartbeat` channel (unreliable) | `SwarmCoordinator.swift` |

Commits: b491e8b, edbeadd

### Phase 3: Transfer Channel Migration & Legacy Cleanup ✅

RAG transfers use persistent sessions. ~3,080 LOC deleted, ~348 added.

| Step | Description |
|------|-------------|
| 3.1 ✅ | Refactor `RAGSyncCoordinator` to use `SwarmCoordinator.requestRagArtifactSync()` |
| 3.2 ✅ | Add `waitForTransferCompletion()` |
| 3.3 ✅ | Broaden `requestRagArtifactSync()` for WebRTC-only peers |
| 3.4 ✅ | Delete `OnDemandPeerTransfer.swift` (~650 LOC) |
| 3.5 ✅ | Delete `STUNClient.swift` (~300 LOC) |
| 3.6 ✅ | Delete `FirestoreRelayTransfer.swift` (~150 LOC) |
| 3.7 ✅ | Delete `LocalNetworkActorSystem.swift` (~350 LOC) |
| 3.8 ✅ | Delete `PeelWorker.swift`, extract `ChainExecutor.swift` |
| 3.9 ✅ | Delete `P2PConnectionLog.swift`, `P2PLogRequestListener.swift` |
| 3.10 ✅ | Replace `P2PConnectionLog.shared.log()` with `Logger` |
| 3.11 ✅ | Remove bridge methods and stale providers from SwarmCoordinator |
| 3.12 ✅ | Deprecate MCP tools: `swarm.p2p-logs`, `swarm.request-logs`, `swarm.stun-test` |
| 3.13 ✅ | Update `RepoDetailRAGTabView` and `MCPServerService+SmallDelegates` |

Commit: 384b9dc

**Deferred from Phase 3 (now in Phases 8 and 9 below):**
- Delete `PeerConnectionManager.swift` — still referenced as TCP fallback in `sendMessage()`
- Delete `WANAddressResolver.swift`

---

## Current Issues (identified March 2026)

The migration succeeded but left behind reliability debt. These are the specific issues driving the remaining phases.

### Issue 1: SwarmCoordinator is a 3,222-line God Object

One `@MainActor @Observable` class owns: peer lifecycle, RAG transfer state machine, message routing, heartbeats, five reconnect loops, Firestore listeners, task dispatch, and diagnostics. Every networking change is risky because all state is interleaved.

### Issue 2: Continuation Races (no generation counters)

**Manifest ACK waiter** (`SwarmCoordinator.swift:1869-1891`):
```swift
private func waitForManifestAck(transferId: UUID) async {
    let timeoutTask = Task { @MainActor [weak self] in
        try await Task.sleep(for: .seconds(2))
        if let waiter = self?.manifestAckWaiters.removeValue(forKey: transferId) {
            waiter.resume(returning: false)
        }
    }
    let gotAck = await withCheckedContinuation { cont in
        manifestAckWaiters[transferId] = cont
    }
    timeoutTask.cancel()
}
```

The timeout task and the ack handler (line 2911) race to resume the same continuation. Unlike `DataChannelHandle` which uses `waiterGeneration`, this has no guard. Same pattern exists in `WebRTCMCPTransport.sendRequest()` and `pendingDirectCommands`.

The proven fix is the task-group timeout pattern from `DataChannelHandle.receive()`:
```swift
try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { /* actual work */ }
    group.addTask {
        try await Task.sleep(for: timeout)
        throw TimeoutError()
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw TimeoutError() }
    return result
}
```

### Issue 3: ICE State via Magic Numbers

`PeerSession.swift:241-249` casts `RTCIceConnectionState` through `Any` → `Int` with magic numbers (6=failed, 7=closed) to avoid importing WebRTC. This silently breaks if enum values change.

### Issue 4: Five Uncoordinated Retry Loops

| Task | Interval | Backoff |
|------|----------|---------|
| `heartbeatTask` | 10s | None |
| `heartbeatMonitorTask` | implicit | None |
| `wanAutoConnectTask` | 2min fixed | None |
| `lanReconnectTask` | varies | None |
| `peerSessionRefreshTask` | debounced | None |

A network change event can trigger all five simultaneously. None use exponential backoff or jitter.

### Issue 5: Unbounded Collections

| Collection | Location | Growth |
|------------|----------|--------|
| `respondedOfferFingerprints` | WebRTCSignalingResponder | Never evicted |
| `wanConnectAttempted` | SwarmCoordinator | Checked at read time, never cleaned |
| `pendingRequests` | WebRTCMCPTransport | Leaked if response never arrives |

### Issue 6: Two Parallel WebRTC Codepaths

`WebRTCPeerTransfer` creates throwaway `WebRTCClient` instances per transfer/ping. `PeerSession` manages persistent connections. Both duplicate ICE/SDP/channel logic. Since persistent sessions exist, the one-shot path is redundant.

### Issue 7: Dead TCP Fallback Still Wired

`sendMessage()` at line 1120 still falls back to `connectionManager?.send()` (TCP `PeerConnectionManager`). If WebRTC silently fails, messages route through dead code.

---

## Remaining Phases (4–9)

### Phase 4: Fix Continuation Races ⏳

**Goal:** Apply `DataChannelHandle`'s proven `waiterGeneration` / task-group pattern everywhere.

**Priority:** Highest — correctness bugs that can crash (double-resume) or silently lose data.

| Step | Description | Files |
|------|-------------|-------|
| 4.1 | Replace `manifestAckWaiters` timeout with task-group pattern | `SwarmCoordinator.swift` |
| 4.2 | Replace `WebRTCMCPTransport.sendRequest()` timeout with task-group pattern | `WebRTCMCPTransport.swift` |
| 4.3 | Add generation counter to `pendingDirectCommands` | `SwarmCoordinator.swift` |

**Risk:** Low — localized changes, no behavioral change.

---

### Phase 5: Extract RAG Transfer Engine ⏳

**Goal:** Pull ~500 LOC of RAG transfer state machine into its own actor.

**New file:** `Shared/Distributed/RAGTransferEngine.swift`

```swift
actor RAGTransferEngine {
    private var incomingTransfers: [UUID: IncomingTransfer] = [:]
    private var transferStates: [RAGArtifactTransferState] = []
    private var watchdogTask: Task<Void, Never>?

    func sendArtifacts(to peerId: String, data: Data, manifest: RAGArtifactManifest,
                       channel: DataChannelHandle) async throws
    func handleManifest(id: UUID, manifest: RAGArtifactManifest, from peerId: String)
    func handleChunk(id: UUID, index: Int, total: Int, data: String)
    func handleComplete(id: UUID, from peerId: String) async
    func handleAck(id: UUID, receivedChunks: Int, receivedBytes: Int)
    func handleResumeRequest(id: UUID, ...) async
    func handlePeerDisconnected(_ peerId: String)

    var transfers: AsyncStream<[RAGArtifactTransferState]>
}
```

**What moves out of SwarmCoordinator:**
- `incomingRagTransfers`, `manifestAckWaiters`, `RAGIncomingTransfer`
- `ragTransferWatchdogTask`, `checkForStalledTransfers()`
- `waitForManifestAck()`, `handleRagArtifactsManifest()`, `handleRagArtifactsChunk()`, `handleRagArtifactsComplete()`, `handleRagArtifactsResumeRequest()`
- `updateRagTransfer()`, `recordRagTransfer()`, `failTransfer()`, `sendRagArtifactError()`
- `waitForTransferCompletion()`

**What stays in SwarmCoordinator:**
- `requestRagArtifactSync()` (orchestration — calls into engine)
- `handlePeerMessage` routing (delegates RAG cases to engine)
- `ragTransfers` observable property (reads from engine's published state)

| Step | Description | Files |
|------|-------------|-------|
| 5.1 | Create `RAGTransferEngine` actor with all transfer state + logic | New: `RAGTransferEngine.swift` |
| 5.2 | Wire SwarmCoordinator to delegate RAG message cases to engine | `SwarmCoordinator.swift` |
| 5.3 | Bridge engine's transfer state back to SwarmCoordinator's observable `ragTransfers` | `SwarmCoordinator.swift` |

**Risk:** Medium — needs careful delegation boundary. Test with end-to-end RAG sync.

---

### Phase 6: Unify Connection Lifecycle ⏳

**Goal:** PeerSessionManager becomes the single authority for connection state and reconnection.

**What moves from SwarmCoordinator → PeerSessionManager:**
- `wanAutoConnectTask`, `lanReconnectTask`, `peerSessionRefreshTask` logic
- `wanConnectAttempted` tracking

**New reconnect strategy:**
- Single coordinated reconnect loop in PeerSessionManager
- Exponential backoff: 2s → 4s → 8s → 16s → 30s (capped)
- Jitter: ±25% randomization to prevent thundering herd
- Max concurrent connection attempts: 3

**Fix ICE state handling** (import WebRTC in PeerSession, use typed enum):
```swift
private func handleICEStateChange(_ state: RTCIceConnectionState) async {
    switch state {
    case .failed, .closed: await onICEFailed()
    default: break
    }
}
```

**Implement ICE restart** (the TODO at `PeerSession.swift:256`):
- `onICEFailed()` attempts ICE restart via `WebRTCClient.restartICE()` before marking failed
- Falls back to full reconnect if ICE restart fails

| Step | Description | Files |
|------|-------------|-------|
| 6.1 | Move reconnect tasks from SwarmCoordinator to PeerSessionManager | Both files |
| 6.2 | Add coordinated backoff + jitter to PeerSessionManager | `PeerSessionManager.swift` |
| 6.3 | Fix ICE state handling (typed enum, remove magic numbers) | `PeerSession.swift`, `WebRTCClient.swift` |
| 6.4 | Implement ICE restart in `PeerSession.onICEFailed()` | `PeerSession.swift` |
| 6.5 | Add max concurrent connection attempts limit | `PeerSessionManager.swift` |

**Risk:** Medium — reconnect behavior changes. Test by killing network interface and verifying recovery.

---

### Phase 7: Bounded Collections ⏳

**Goal:** Prevent memory leaks from unbounded dictionaries.

| Step | Description | Files |
|------|-------------|-------|
| 7.1 | Cap `respondedOfferFingerprints` at 500, evict oldest on overflow | `WebRTCSignalingResponder.swift` |
| 7.2 | Add periodic cleanup for `wanConnectAttempted` (or fold into Phase 6 reconnect) | `SwarmCoordinator.swift` or `PeerSessionManager.swift` |
| 7.3 | Verify `pendingRequests` cleanup in `WebRTCMCPTransport.stop()` | `WebRTCMCPTransport.swift` |

**Risk:** Low — straightforward bounds checking.

---

### Phase 8: Delete TCP Fallback ⏳

**Goal:** Remove the dead TCP path. Completes the deferred deletion from Phase 3.

| Step | Description | Files |
|------|-------------|-------|
| 8.1 | Remove `connectionManager` fallback from `sendMessage()` — throw clear error when WebRTC is down | `SwarmCoordinator.swift` |
| 8.2 | Delete `PeerConnectionManager.swift` (~800 LOC) | Delete |
| 8.3 | Delete `WANAddressResolver.swift` (~60 LOC) | Delete |
| 8.4 | Remove all `connectionManager` imports/references | Various |

**Risk:** Low — verify no code paths depend on `connectionManager` before deleting.

---

### Phase 9: Delete One-Shot WebRTC Codepath ⏳

**Goal:** All WebRTC communication goes through persistent `PeerSession` connections.

`WebRTCPeerTransfer` creates throwaway `WebRTCClient` instances per transfer/ping. Since persistent sessions exist, this is redundant.

| Step | Description | Files |
|------|-------------|-------|
| 9.1 | Route ping through `PeerSession.heartbeatChannel` | Ping tool handler |
| 9.2 | Verify no code calls `WebRTCPeerTransfer.requestData()` or `.ping()` | Search all call sites |
| 9.3 | Delete `WebRTCPeerTransfer.swift` (~499 LOC) | Delete |
| 9.4 | Simplify `WebRTCSignalingResponder` to only handle `purpose="session"` | `WebRTCSignalingResponder.swift` |

**Risk:** Medium — verify all call sites before deleting.

---

### Future: Persistence & Chat

Deferred until the reliability work is done. Originally Phase 4 in the replan.

| Step | Description | Files |
|------|-------------|-------|
| F.1 | Create `PersistenceWriter` — background Firestore write-behind for RTC events | New: `PersistenceWriter.swift` |
| F.2 | Wire persistence for task dispatch/results | `SwarmCoordinator.swift`, `PersistenceWriter.swift` |
| F.3 | Wire chat channel persistence (write-behind after RTC delivery) | `PersistenceWriter.swift` |
| F.4 | Update `SwarmStatusView` — show WebRTC connection state, channel health, RTT | `SwarmStatusView.swift` |
| F.5 | Migrate swarm chat UI from Firestore-direct to RTC+persistence | `SwarmStatusView.swift` |

### Future: Docs Cleanup

| Step | Description |
|------|-------------|
| D.1 | Remove all imports/references to deleted types across the codebase |
| D.2 | Update `copilot-instructions.md` with the "WebRTC when connected, Firestore when not" rule |
| D.3 | Archive `DISTRIBUTED_PEEL_DESIGN.md` (superseded) |
| D.4 | Update `FIRESTORE_SWARM_DESIGN.md` with reduced Firestore scope |
| D.5 | Delete architecture invariant banners from remaining files |

---

## Execution Order

Each phase is independently testable and can be merged separately:

| Order | Phase | Risk | LOC Impact | Why This Order |
|-------|-------|------|-----------|----------------|
| 1 | **4: Fix races** | Low | ~-50 | Correctness bugs — fix first |
| 2 | **5: Extract RAG engine** | Medium | ~-470 | Biggest maintainability win |
| 3 | **7: Bounded collections** | Low | ~+30 | Quick wins, prevents leaks |
| 4 | **6: Unify reconnect** | Medium | ~-200 | Simplifies retry behavior |
| 5 | **8: Delete TCP** | Low | ~-860 | Removes dead code |
| 6 | **9: Delete one-shot WebRTC** | Medium | ~-500 | Removes duplication |

**Estimated totals for Phases 4–9:** Delete ~1,800 LOC, add ~800 LOC, net reduction ~1,000 LOC.

Combined with Phases 1–3 (~3,080 deleted, ~348 added), the full migration deletes **~4,880 LOC** and adds **~1,148 LOC**.

---

## Testing Strategy

Each phase should be validated with:

1. **RAG transfer end-to-end** — push/pull between two peers, verify all chunks arrive
2. **Network interruption** — kill Wi-Fi mid-transfer, verify reconnect + resume
3. **Concurrent transfers** — two RAG syncs to different peers simultaneously
4. **Sleep/wake cycle** — close lid, reopen, verify sessions recover
5. **Long-running stability** — leave swarm active for 1+ hour, check for memory growth

---

## Key Files

| File | Role | LOC |
|------|------|-----|
| `Shared/Distributed/SwarmCoordinator.swift` | Main coordinator — owns peer lifecycle, message routing, transfer state | 3,222 |
| `Shared/Distributed/PeerSession.swift` | Single persistent WebRTC connection to one peer | 291 |
| `Shared/Distributed/PeerSessionManager.swift` | Manages all peer sessions, observable state for UI | 144 |
| `Shared/Distributed/WebRTCMCPTransport.swift` | MCP JSON-RPC over WebRTC data channel | 153 |
| `Shared/Distributed/FirestoreWebRTCSignaling.swift` | Firestore-backed WebRTC signaling | 305 |
| `Shared/Distributed/WebRTCSignalingResponder.swift` | Watches Firestore for incoming WebRTC offers | 210 |
| `Shared/Distributed/FirebaseService.swift` | Firestore backbone — auth, registry, offline queue | ~100+ |
| `Shared/Distributed/BonjourDiscoveryService.swift` | LAN peer discovery (feeds into WebRTC signaling) | ~455 |
| `Shared/Services/RAGSyncCoordinator.swift` | Orchestrates RAG index syncing between peers | ~150 |
| `Local Packages/WebRTCTransfer/.../WebRTCClient.swift` | RTCPeerConnection wrapper with async/await | 712 |
| `Local Packages/WebRTCTransfer/.../DataChannelHandle.swift` | Single data channel wrapper with ordering + backpressure | 285 |
| `Local Packages/WebRTCTransfer/.../WebRTCPeerTransfer.swift` | One-shot transfer API (slated for deletion in Phase 9) | 499 |
| `Local Packages/WebRTCTransfer/.../SignalingChannel.swift` | Signaling protocol definition | 49 |
| `Shared/Distributed/PeerConnectionManager.swift` | **DEAD CODE** — TCP transport (slated for deletion in Phase 8) | ~800 |
| `Shared/Distributed/WANAddressResolver.swift` | **DEAD CODE** — public IP discovery (slated for deletion in Phase 8) | ~60 |

---

## Risk & Mitigation

| Risk | Mitigation |
|------|------------|
| **ICE failures on restrictive NATs** | Add TURN server support (coturn or Twilio). STUN-only works for most home/office NATs but symmetric NAT requires TURN. |
| **WebRTC library stability** | stasel/WebRTC is actively maintained; pin to known-good version. |
| **Data channel message size limits** | Existing 64KB chunking protocol handles this. SCTP fragmentation is also automatic. |
| **Persistence write-behind lag** | Local message queue survives app restart via SwiftData. Firestore write is best-effort. |
| **Bonjour removal breaks LAN speed** | Keep Bonjour as ICE candidate hint, not transport. |

---

## Open Questions

1. **TURN server**: Self-hosted (coturn) or managed (Twilio/Cloudflare)? Defer until someone hits symmetric NAT.
2. **Multi-brain topology**: Current design assumes one brain + N workers. Defer — current use case is single brain.
3. **iOS peer sessions**: iOS background execution limits WebRTC keep-alive. Accept disconnect on background, reconnect on foreground.
4. **Message ordering**: Reliable/ordered SCTP channels have head-of-line blocking. Fine for MCP (request-response). Consider unordered for large transfers (test and measure).

---

## References

- [NETWORKING_STANDARD.md](../Docs/reference/NETWORKING_STANDARD.md) — Architecture rules (hard rules, decision checklist)
- [FIRESTORE_SWARM_DESIGN.md](FIRESTORE_SWARM_DESIGN.md) — Firestore auth/security model
- [DISTRIBUTED_TASK_TYPES_SPEC.md](DISTRIBUTED_TASK_TYPES_SPEC.md) — Task payload schemas
- `DataChannelHandle.swift:114-141` — Reference implementation for waiter generation counters
- `DataChannelHandle.swift:224-236` — Reference implementation for task-group timeout pattern

---

**Last Updated**: March 12, 2026
