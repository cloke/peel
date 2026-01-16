# Kitchen Sync - Project Plans

## Status Overview

| Plan | Status | Description |
|------|--------|-------------|
| [SWIFTUI_MODERNIZATION_PLAN](SWIFTUI_MODERNIZATION_PLAN.md) | ✅ Complete | Swift 6 / SwiftUI 6 migration |
| [UX_MODERNIZATION_PLAN](UX_MODERNIZATION_PLAN.md) | ✅ Complete | UI/UX improvements |
| [SWIFTDATA_PLAN](SWIFTDATA_PLAN.md) | ✅ Complete | SwiftData + iCloud sync |
| [WORKTREE_FEATURE_PLAN](WORKTREE_FEATURE_PLAN.md) | ✅ Complete | Git worktrees + PR review |
| [AGENT_ORCHESTRATION_PLAN](AGENT_ORCHESTRATION_PLAN.md) | 🟡 In Progress | AI agent management |
| [apple-agent-big-ideas](apple-agent-big-ideas.md) | 📋 Vision | Hardware-maximizing agent features |

## Current Session

**[SESSION_JAN16.md](SESSION_JAN16.md)** — Big picture planning, phased roadmap

## Phased Roadmap

### Phase 1: TestFlight Ready (Current)
- [ ] Core Git/GitHub/Homebrew polished
- [ ] Workspaces tab working
- [ ] iOS feature parity

### Phase 2: Local AI Foundation
- [ ] XPC tool brokers
- [ ] Basic MLX integration
- [ ] PII scrubber tool

### Phase 3: Multimodal & Feedback
- [ ] Vision-guided agents
- [ ] Voice commands
- [ ] Distributed Actors

### Phase 4: Full Isolation
- [ ] Per-task micro-VMs
- [ ] GPU shared cache
- [ ] ANE micro-services

## Completed Work (January 2026)

### Core Modernization
- Migrated all packages to @Observable (removed Combine)
- Fixed navigation with NavigationStack
- Removed all manual DispatchQueue threading

### New Features
- **PR → Worktree Integration** - Review PRs locally in VS Code
- **GitHub Favorites** - Star repos, synced via iCloud
- **Recent PRs** - Track viewed PRs
- **Archive Filtering** - Hide archived repos by default
- **iCloud Sync** - SwiftData with CloudKit

---

See [MODERNIZATION_COMPLETE.md](MODERNIZATION_COMPLETE.md) for detailed history.
See [apple-agent-big-ideas.md](apple-agent-big-ideas.md) for the full vision.
