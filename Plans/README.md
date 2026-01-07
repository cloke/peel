# Plans

This folder contains planning documents, architecture decisions, and roadmaps for the Kitchen Sync project.

## Active Documents

| Document | Description | Status |
|----------|-------------|--------|
| [WORKTREE_FEATURE_PLAN.md](./WORKTREE_FEATURE_PLAN.md) | Git worktree management with VS Code | ✅ Phase 1 Complete |
| [SWIFTDATA_PLAN.md](./SWIFTDATA_PLAN.md) | SwiftData + iCloud sync integration | 🟡 Planning |
| [AGENT_ORCHESTRATION_PLAN.md](./AGENT_ORCHESTRATION_PLAN.md) | AI Agent workspace management (future) | 🟡 Planning |

## Completed Documents

| Document | Description |
|----------|-------------|
| [UX_MODERNIZATION_PLAN.md](./UX_MODERNIZATION_PLAN.md) | UI/UX polish and fixes | ✅ Complete |
| [MODERNIZATION_COMPLETE.md](./MODERNIZATION_COMPLETE.md) | Swift 6 modernization summary |
| [SWIFTUI_MODERNIZATION_PLAN.md](./SWIFTUI_MODERNIZATION_PLAN.md) | Original code modernization |

## Archive

Completed session notes and historical documents are in the `Archive/` folder.

## Quick Start

**Current Focus:**
1. `WORKTREE_FEATURE_PLAN.md` - Git worktree management (Phase 1 done)
2. `SWIFTDATA_PLAN.md` - Decide on persistence strategy

**Feature Roadmap:**
1. ✅ Swift 6 modernization
2. ✅ UX polish  
3. ✅ Worktrees (basic)
4. 🟡 SwiftData (optional)
5. 🟡 PR → Worktree integration
6. 🔴 Agent orchestration

## Plan Template

When creating new plans, use this frontmatter:

```yaml
---
status: planning | in-progress | complete
created: YYYY-MM-DD
updated: YYYY-MM-DD
priority: low | medium | high
estimated-effort: X hours/days
---
```