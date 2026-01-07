# Plans

This folder contains planning documents, architecture decisions, and roadmaps for the Kitchen Sync project.

## Active Documents

| Document | Description | Status |
|----------|-------------|--------|
| [UX_MODERNIZATION_PLAN.md](./UX_MODERNIZATION_PLAN.md) | UI/UX polish and outdated pattern fixes | 🔴 Not Started |
| [AGENT_ORCHESTRATION_PLAN.md](./AGENT_ORCHESTRATION_PLAN.md) | AI Agent Orchestration integration (future) | 🟡 Planning |

## Reference Documents

| Document | Description |
|----------|-------------|
| [MODERNIZATION_COMPLETE.md](./MODERNIZATION_COMPLETE.md) | Summary of Swift 6 modernization (Sessions 1-4) |
| [SWIFTUI_MODERNIZATION_PLAN.md](./SWIFTUI_MODERNIZATION_PLAN.md) | Original modernization plan (✅ Complete) |

## Archive

Completed plans and session notes are in the `Archive/` folder.

## Quick Start

**Want to improve the app?**
1. Read `UX_MODERNIZATION_PLAN.md` - identifies all UX issues
2. Start with Phase 1 (critical fixes, 30 min)
3. Optionally continue to Phase 2-6

**Want to add features?**
1. Complete at least UX Phase 1 first (fix crash risks)
2. Then proceed with feature development

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