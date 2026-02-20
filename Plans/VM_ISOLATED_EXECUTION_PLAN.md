---
title: VM Isolated Execution Plan
status: in-progress
created: 2026-02-20
updated: 2026-02-20
tags: [vm, isolation, agents, templates, security]
audience: [developers]
code_locations:
  - path: Shared/AgentOrchestration/VMIsolationService.swift
    description: VM lifecycle management (Linux + macOS)
  - path: Shared/AgentOrchestration/VMChainExecutor.swift
    description: VM-isolated chain execution (new)
  - path: Shared/AgentOrchestration/Models/ChainTemplate.swift
    description: Chain templates and step types
  - path: Shared/AgentOrchestration/AgentChainRunner.swift
    description: Chain execution engine
  - path: Shared/AgentOrchestration/WorkspaceManager.swift
    description: Git worktree workspace management
  - path: Shared/AgentOrchestration/ToolHandlers/VMToolsHandler.swift
    description: MCP tools for VM lifecycle
  - path: Docs/guides/VM_BOOTSTRAP_GITHUB_AUTH.md
    description: Auth bootstrapping guide for VMs
related_docs:
  - Plans/VM_ISOLATION_PLAN.md
  - Plans/ROADMAP.md
closes_issues: ["#9 (remaining presets)", "#106 (worktree mount)", "#95 (pool management)"]
---

# VM Isolated Execution Plan

**Goal**: Enable agents to optionally run chains inside an isolated VM instead of a host worktree.

**Why**: Worktrees provide code isolation but share the host filesystem, network, and toolchain. A VM gives full isolation — untrusted agent code can't access host resources, and each run starts from a known state. This is especially valuable for:
- Running untrusted or generated code safely
- Reproducible builds (known toolchain versions)
- Testing against different OS configurations
- "Yolo mode" where agents have root access inside the VM

---

## Current State (What Already Works)

| Capability | Linux (Alpine) | macOS |
|-----------|----------------|-------|
| VM boots | ✅ (initramfs only) | ✅ (full OS) |
| Console I/O | ✅ ANSI stripping, serial | ✅ Graphics + keyboard |
| Network (NAT) | ✅ | ✅ |
| Start/stop lifecycle | ✅ | ✅ |
| State cleanup on crash | ✅ (delegate) | ✅ (delegate) |
| MCP tools | ❌ | ✅ (6 tools) |
| Task execution inside VM | ❌ (stub) | ❌ (stub) |
| Worktree mount/copy | ❌ | ❌ |
| Pool management | ❌ (scaffolded) | ❌ (scaffolded) |
| Toolchain provisioning | ❌ | ❌ |

---

## Architecture

### Execution Environment Selection

Templates gain an optional `executionEnvironment` field. The existing `ExecutionEnvironment` enum in VMIsolationService.swift is made `Codable` and added to `ChainTemplate`:

```swift
// Already exists in VMIsolationService.swift — made Codable
enum ExecutionEnvironment: String, Codable, Sendable, CaseIterable {
  case host    // Default: git worktree on host (current behavior)
  case linux   // Alpine Linux VM
  case macos   // macOS VM (for Xcode builds, SwiftUI tests)
}
```

This goes on `ChainTemplate`, not per-step. The entire chain runs in one environment.

### VMToolchain

New enum specifying what tools to provision inside the VM:

```swift
enum VMToolchain: String, Codable, Sendable, CaseIterable {
  case minimal     // git, curl, jq
  case swift       // Swift toolchain + SPM
  case node        // Node.js + npm
  case ruby        // Ruby + bundler
  case ember       // Node.js + Ember CLI
  case fullStack   // Everything
}
```

### Flow: VM-Isolated Chain Execution

```
chains.run(template: "VM Isolated Build", ...)
    │
    ▼
1. Create git worktree (.agent-workspaces/<uuid>/)
    │
    ▼
2. Boot VM (or claim from pool)
   - Linux: Alpine with rootfs
   - macOS: From installed image
    │
    ▼
3. Mount worktree into VM
   - VZSharedDirectory + VZVirtioFileSystemDeviceConfiguration
   - Guest mounts at /workspace (Linux) or ~/workspace (macOS)
    │
    ▼
4. Bootstrap VM environment
   - Inject short-lived GitHub App token
   - Install toolchain packages
   - Set git author identity
    │
    ▼
5. Run chain steps
   - Agentic: LLM calls from host, file edits via shared mount
   - Deterministic: shell commands via VM console
   - Gate: build/test commands in VM
    │
    ▼
6. Extract results
   - git diff/commit from shared directory
   - Copy build artifacts if needed
    │
    ▼
7. Teardown
   - Stop VM (or return to pool)
   - Worktree remains for review
```

### Key Design Decision: LLM Calls Stay on Host

The LLM (Copilot/Claude) runs on the host, not inside the VM. The VM is purely an execution sandbox:
- **Agentic steps**: LLM on host, reads/writes files via shared mount
- **Deterministic steps**: Commands execute inside VM via console
- **Gate steps**: Build/test commands run inside VM

This avoids installing CLI tools inside VMs and keeps API keys off the VM.

---

## Implementation Stages

### Stage 1: Model & Template Changes ✅
- Add `Codable` to `ExecutionEnvironment`
- Add `VMToolchain` enum
- Add `executionEnvironment` and `toolchain` fields to `ChainTemplate`

### Stage 2: Directory Sharing
- macOS VM: `VZSharedDirectory` + `VZVirtioFileSystemDeviceConfiguration`
- Linux VM: Same virtio-fs approach
- Auto-mount at `/workspace` inside VM

### Stage 3: VM Command Execution
- `VMChainExecutor`: boot VM → mount → bootstrap → run → teardown
- Execute commands via console pipe (serial I/O)
- Parse command output and exit codes

### Stage 4: Chain Runner Integration
- Dispatch to `VMChainExecutor` when `executionEnvironment != .host`
- Deterministic/gate steps run via VM console
- Agentic steps use host LLM with shared mount for file access

### Stage 5: Linux MCP Tools + Built-in Templates
- Add `vm.linux.start`, `vm.linux.stop`, `vm.linux.status`
- Built-in VM templates for common workflows

### Stage 6: Pools & Golden Images (Future)
- Snapshot-based fast boot
- Pre-warmed VM pools
- Golden image builder

---

## Security Model

- **Short-lived tokens only**: GitHub App installation tokens (1h TTL)
- **No host SSH keys**: VMs never see personal keys
- **Scoped mount**: Only the specific worktree is shared
- **Read-only option**: For analysis templates
- **No host services**: VM cannot reach localhost

---

## Related Docs
- [Plans/VM_ISOLATION_PLAN.md](VM_ISOLATION_PLAN.md) — Original VM plan
- [Docs/guides/VM_BOOTSTRAP_GITHUB_AUTH.md](../Docs/guides/VM_BOOTSTRAP_GITHUB_AUTH.md) — Auth bootstrapping
- Closed issues: #9, #106, #95
