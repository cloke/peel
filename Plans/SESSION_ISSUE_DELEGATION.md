# Session: Issue Delegation to Planner Agents

**Created:** January 31, 2026  
**Goal:** Delegate open issues to planner agents for analysis and implementation

---

## Active Epics

### Epic 1: User Onboarding & Feature Discovery (#230)

Enable new users to get started with Peel quickly, with optional swarm features.

| Issue | Title | Priority | Notes |
|-------|-------|----------|-------|
| #236 | Graceful Auth Prompts for Swarm Features | High | Foundation - app works without auth |
| #237 | Invite Deep Link and Join Flow | High | Core swarm onboarding |
| #231 | Feature Discovery Checklist | Medium | Nice-to-have, not blocking |
| #232 | QR Code & Enhanced Invite Sharing | Medium | After invite flow works |
| #233 | Push Notifications for Swarm Events | Low | Requires FCM setup |
| #235 | iOS Monitoring and GitHub Features | Low | iOS is monitoring-only |

**Key Constraints:**
- App must work fully without sign-in (solo mode)
- Swarm features require Sign In with Apple
- iOS = monitoring only (no chain execution)
- No mandatory wizard - users jump right in

---

### Epic 2: Production-Ready Chain Templates (#238)

Make chain templates useful for real workflows, not just MCP testing.

| Issue | Title | Priority | Notes |
|-------|-------|----------|-------|
| #239 | Provider-Aware Template Selection | High | Foundation for other template work |
| #240 | Default Templates for Common Workflows | High | Replace MCP Harness templates |
| #241 | Planner Delegation and Task Routing | High | Enables this delegation workflow |
| #242 | Cost Guidance and Tier Visibility | Medium | UX improvement |
| #243 | Issue Analysis Template | High | Key for delegation workflow |

**Key Constraints:**
- Templates must detect available providers (Copilot vs Claude)
- Cost tiers: Free (GPT-4.1, GPT-5-Mini), Standard (Sonnet, Codex), Premium (Opus)
- Planner outputs should be routable to multiple implementers
- Must work with RAG for codebase grounding

---

## Delegation Strategy

### For Each Issue:

1. **Analyze** - Read issue description, understand acceptance criteria
2. **RAG Search** - Find relevant code in the codebase
3. **Plan** - Produce specific file changes with line numbers
4. **Route** - Recommend model tier for implementation

### Model Selection:

| Task Type | Recommended Model | Cost |
|-----------|-------------------|------|
| Simple UI additions | GPT-4.1 or GPT-5-Mini | Free |
| New Swift files | Claude Sonnet or GPT Codex | 1x |
| Complex refactoring | Claude Sonnet | 1x |
| Architecture decisions | Claude Opus | 3x |

---

## Codebase Context

### Key Files for Onboarding Work:
- `Shared/Views/Swarm/SwarmAuthView.swift` - Existing auth view
- `Shared/Views/Swarm/SwarmManagementView.swift` - Swarm management
- `Shared/Distributed/FirebaseService.swift` - Firebase/auth service
- `Shared/PeelApp.swift` - App entry point (URL handling)

### Key Files for Template Work:
- `Shared/AgentOrchestration/Models/ChainTemplate.swift` - Template definitions
- `Local Packages/MCPCore/Sources/MCPCore/CopilotModel.swift` - Model definitions
- `Shared/AgentOrchestration/CLIService.swift` - Provider detection
- `Shared/Applications/Agents/ChainTemplateGalleryView.swift` - Template UI

### Design Documents:
- `Plans/FIRESTORE_SWARM_DESIGN.md` - Swarm security model
- `Plans/USER_ONBOARDING_PLAN.md` - Onboarding flows
- `.github/copilot-instructions.md` - Project conventions

---

## Suggested Session Order

### Phase 1: Foundation (do first)
1. **#236** Graceful Auth Prompts - Makes app work without blocking auth
2. **#239** Provider-Aware Templates - Foundation for template improvements

### Phase 2: Core Features
3. **#237** Invite Deep Link Flow - Core swarm join experience
4. **#240** Default Templates - Replace test templates with real ones
5. **#243** Issue Analysis Template - Enables this delegation workflow

### Phase 3: Polish
6. **#241** Planner Delegation - Smart task routing
7. **#242** Cost Guidance - Better UX
8. **#231** Feature Discovery - Onboarding checklist

### Phase 4: Extended (lower priority)
9. **#232** QR Code Sharing
10. **#233** Push Notifications
11. **#235** iOS Monitoring

---

## RAG Search Queries

Use these to find relevant code:

```
# For auth/onboarding
"FirebaseService sign in authentication"
"SwarmAuthView SwarmManagementView"
"onOpenURL URL scheme handler"

# For templates
"ChainTemplate builtInTemplates"
"CLIService copilotStatus claudeStatus"
"AgentChainRunner planner implementer"
"CopilotModel premiumCost"
```

---

## Notes for Planner

- All code follows Swift 6 patterns (@Observable, @MainActor, async/await)
- Use 2-space indentation
- Check existing patterns before creating new ones
- RAG search FIRST, then grep, then read files
- Each issue has acceptance criteria - use those as test cases
