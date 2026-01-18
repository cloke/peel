# Peel - Project Plans

**Updated:** January 18, 2026

---

## Active Plans

| Plan | Status | Description |
|------|--------|-------------|
| [ROADMAP](ROADMAP.md) | 📋 Master | Overall project roadmap with issue tracking |
| [MCP_AGENT_WORKFLOW](MCP_AGENT_WORKFLOW.md) | ✅ Active | Build → Launch → Connect MCP workflow |
| [MCP_TEST_PLAN](MCP_TEST_PLAN.md) | ✅ Active | MCP server test cases |
| [CONSOLIDATION_PLAN](CONSOLIDATION_PLAN.md) | ✅ Complete | Code deduplication, unified worktrees |
| [AGENT_ORCHESTRATION_PLAN](AGENT_ORCHESTRATION_PLAN.md) | ✅ Complete | AI agent management with CLI tools |
| [PARALLEL_AGENTS_PLAN](PARALLEL_AGENTS_PLAN.md) | ✅ Complete | Multiple agents + merge workflow |
| [VM_ISOLATION_PLAN](VM_ISOLATION_PLAN.md) | 🟡 Partial | Linux VM boots, needs polish |
| [apple-agent-big-ideas](apple-agent-big-ideas.md) | 📋 Vision | Hardware-maximizing features |
| [CODE_AUDIT_INDEX](CODE_AUDIT_INDEX.md) | 📝 Reference | File-by-file audit tracker |

---

## Roadmap Summary

### Phase 1A: Polish ✅ Complete
- [x] TrackedWorktree wiring
- [x] Worktree visibility unification  
- [x] CLI state persistence
- [x] Code consolidation

### Phase 1B: Parallel Agents ✅ Complete
- [x] TaskGroup-based parallel execution
- [x] Merge Agent implementation
- [x] Planner structured output

### Phase 1C: MCP 🔄 In Progress
- [x] MCP server in app
- [x] Chain templates via MCP
- [ ] Validation pipeline (#13)
- [ ] Activity log + cleanup (#16)

### Phase 2: Local AI
- [ ] PII scrubber tool (#8)
- [ ] XPC tool brokers
- [ ] MLX integration

### Phase 3: VM Isolation
- [x] Linux VM boots to CLI
- [ ] Full rootfs setup
- [ ] macOS VM support

---

## Completed (Archived)

All completed plans are in [Archive/](Archive/):
- SwiftUI Modernization (Swift 6, @Observable)
- SwiftData + iCloud sync
- UX improvements
- Git worktree feature
- PR review locally
