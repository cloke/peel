# Networking Standard

**Status:** Active — all agents MUST follow this before modifying any file in `Shared/Distributed/`.  
**Last Updated:** 2026-03-12

---

## Two-Layer Architecture

All swarm communication uses exactly two layers. There is no third layer, no fallback relay, no "temporary bridge."

### Layer 1: Firestore (Coordination & Persistence)

Firestore handles things that **must survive when peers aren't connected**. It carries only small JSON documents — never bulk data.

| Responsibility | Why Firestore |
|----------------|---------------|
| Auth & membership | Roles, permissions, invite tokens — must persist across sessions |
| Worker registry | Capabilities, "I exist" registration — survives reboots |
| WebRTC signaling | SDP offers/answers + ICE candidates — unavoidable out-of-band bootstrap |
| Offline task queue | A worker that comes online later reads pending tasks |
| Task archival | Completed task history, audit log |
| Transfer metadata | Repo ID, size, duration, timestamp — NOT the actual data |
| Activity log | Swarm events for debugging and billing |

### Layer 2: WebRTC (Everything Real-Time)

One **persistent** `RTCPeerConnection` per brain↔worker pair, established on swarm join, kept alive with ICE restarts on network changes. Multiple named data channels on each connection:

| Channel | Purpose | Reliability |
|---------|---------|-------------|
| `mcp` | MCP JSON-RPC messages (tool calls, results, task dispatch, direct commands) | Reliable / ordered |
| `transfer` | RAG artifacts, large file chunks | Reliable / ordered |
| `heartbeat` | Ping/pong, status updates, resource utilization | Unreliable / unordered |
| `chat` *(future)* | Swarm messaging (persisted to Firestore after delivery) | Reliable / ordered |
| Audio/video tracks *(future)* | Screen share, voice | RTP — already on the same RTCPeerConnection |

---

## Fallback Behavior

The rule is: **WebRTC when connected, Firestore when not.**

| Scenario | Behavior |
|----------|----------|
| WebRTC connection is **open** | Use data channels (sub-100ms latency, zero Firestore cost) |
| WebRTC connection is **not open** | Write to Firestore (offline task queue, signaling to reconnect) |
| WebRTC connection **drops** | Auto-reconnect via ICE restart; queue messages locally; spill to Firestore after timeout |
| All P2P paths fail for **data transfer** | **Fail with an error.** Do NOT relay data through Firestore. Fix the P2P path. |

---

## Hard Rules

These are non-negotiable. Violating any of them is a bug.

### 1. No Bulk Data Through Firestore — Ever

Firestore carries only small JSON coordination documents. RAG artifacts, embeddings, file chunks, or any payload > 1 KB must go over WebRTC data channels. If the WebRTC connection is down, the transfer **fails** — it does not fall back to Firestore relay.

`FirestoreRelayTransfer.swift` is **deprecated**. Do not use it, reference it, or build anything similar.

### 2. No Gating on TCP `connectedWorkers`

The `peers` array in diagnostics shows WebRTC/TCP data-channel readiness. It must **never** be a prerequisite for:
- Task dispatch (goes through Firestore offline queue or WebRTC `mcp` channel)
- Direct commands (same)
- Worker updates (same)

Workers discover tasks via Firestore listeners or WebRTC `mcp` messages. They do not need to be in `connectedWorkers` to receive work.

### 3. No Coordination Through P2P

Status messages, commands, heartbeats, and task dispatch should use either:
- Firestore (if the peer might be offline), or
- WebRTC `mcp`/`heartbeat` channels (if the peer is connected)

Do **not** add coordination logic to `PeerConnectionManager` (TCP). That file is legacy transport for the pre-WebRTC era and is slated for removal.

### 4. Fail Loudly

If a transfer cannot complete because no P2P path exists:
- Mark the transfer as **failed** with a clear error message
- Log the failure with enough context to diagnose (peer ID, attempted transports, ICE state)
- Do **not** silently drop the transfer or leave it stuck at `queued`

### 5. One Connection Per Peer

Do not create per-transfer WebRTC connections. Reuse the persistent `RTCPeerConnection` for the peer. Multiple data channels share one connection.

---

## Persistence: What RTC Data Gets Saved

Not everything over WebRTC is ephemeral. Key data is **written-through to Firestore** asynchronously:

| Data | When Persisted | Why |
|------|----------------|-----|
| Task dispatch + results | On send / on complete | Audit trail, recovery if connection drops mid-task |
| Chat messages | After successful RTC delivery | Conversation history across sessions |
| Transfer metadata | After transfer completes | Diagnostics and billing |
| Connection events | On connect/disconnect | Uptime tracking |
| Worker status snapshots | Periodic (~60s) | Firestore presence for offline discovery |

**Not persisted:** heartbeat pings, transfer data bytes, ICE candidate churn.

**Pattern:** Write-behind with local queue. RTC is the primary transport. A background actor drains delivered messages to Firestore at low priority. If Firestore write fails, retry with backoff — the data already reached the peer.

---

## Key Files

| File | Role |
|------|------|
| `Shared/Distributed/SwarmCoordinator.swift` | Main coordinator — owns peer lifecycle, message routing, transfer state |
| `Shared/Distributed/PeerSessionManager.swift` | WebRTC session management — `RTCPeerConnection` + data channels |
| `Shared/Distributed/FirebaseService.swift` | Firestore reads/writes — signaling, task queue, worker registry |
| `Shared/Distributed/BonjourDiscoveryService.swift` | LAN peer discovery (feeds into WebRTC signaling) |
| `Shared/Distributed/OnDemandPeerTransfer.swift` | Transfer orchestration (being migrated to WebRTC `transfer` channel) |
| `Shared/Distributed/PeerConnectionManager.swift` | **Legacy** TCP transport — slated for removal |
| `Shared/Distributed/FirestoreRelayTransfer.swift` | **Deprecated** — do not use |

---

## Common Mistakes Agents Make

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| Adding Firestore relay as "fallback" for failed transfers | Sends 30 MB+ as base64 through Firestore docs — expensive, slow, defeats P2P | Fix the P2P path (WebRTC signaling, NAT traversal, STUN/TURN) |
| Checking `connectedWorkers.isEmpty` before dispatching tasks | Workers discover tasks via Firestore listeners, not TCP | Dispatch via Firestore offline queue or WebRTC `mcp` channel |
| Creating a new `RTCPeerConnection` per transfer | Full ICE negotiation each time (~2-5s overhead) | Reuse the persistent connection, open a new data channel if needed |
| Using `connectionManager?.send()` with optional chaining | Silently drops the message if connectionManager is nil | Throw an explicit error so the caller knows delivery failed |
| Leaving transfers stuck at `queued` on failure | No visibility into what went wrong | Mark as `failed` with error context, let watchdog clean up |
| Adding heartbeat/status to `PeerConnectionManager` | TCP transport is legacy, being removed | Use WebRTC `heartbeat` channel or Firestore worker status |

---

## Decision Checklist

Before adding any networking code, answer these questions:

1. **Is this transferring large binary data (> 1 KB)?**
   - YES → WebRTC `transfer` channel only. No Firestore fallback.
   - NO → Continue to question 2.

2. **Does this need to work when the peer is offline?**
   - YES → Firestore (offline task queue, worker registry, etc.)
   - NO → WebRTC data channel (`mcp`, `heartbeat`, or `chat`).

3. **Is this a new data channel?**
   - Create it on the existing `RTCPeerConnection`. Do not create a new connection.

4. **Am I modifying a file in `Shared/Distributed/`?**
   - Read the file's header banner first. It states what the file is allowed to do.
