# Unified Repositories View Plan

## Summary
Merge the current Git and GitHub app surfaces into one "Repositories" experience while keeping platform/service constraints explicit.

## Goals
- Present one top-level repository workspace instead of separate Git and GitHub tools.
- Keep local Git operations available on macOS.
- Keep remote GitHub operations available on macOS and iOS.
- Preserve automation compatibility and existing persisted selections.

## Non-Goals
- Rewriting the internals of `Git_RootView` or `Github_RootView`.
- Adding new GitHub API features.
- Solving iOS local filesystem access for Git.

## UX Design
### Top-Level
- Add a new tool: **Repositories**.
- Replace separate Git/GitHub entries in the tool picker and iOS tab bar.

### Repositories Root
- Use a segmented picker for repository scope:
  - `Overview` (shared guidance / empty-state / shortcuts)
  - `Local` (embeds `Git_RootView`, macOS only)
  - `Remote` (embeds `Github_RootView`, all platforms where package is available)
- Persist selected scope with AppStorage (`repositories.selectedScope`).
- On iOS, show capability-aware Local unavailable messaging.
- Add a consistent top-right **Home** action for `Local` and `Remote` that resets the embedded view to root.
  - This avoids "profile click then back" recovery when deep in PR detail/navigation.
  - Pattern: keep user in current scope, but provide one-tap return to that scope's root.

## Migration & Compatibility
- Keep legacy `CurrentTool` cases for `git` and `github` to avoid decode/migration issues.
- Soft-migrate to `repositories` on appear.
- If automation sets `current-tool` to legacy values, route to `repositories` and set the corresponding scope.

## Implementation Steps
1. ✅ Create `Repositories_RootView` with scope picker and platform-aware child content.
2. ✅ Add `CurrentTool.repositories` and keep legacy cases.
3. ✅ Update macOS `ContentView` switch routing to new root view.
4. ✅ Update `ToolSelectionToolbar` to show a single Repositories item.
5. ✅ Update iOS `ContentView` tabs to use Repositories as one tab.
6. ✅ Verify build for macOS target and fix compile issues.

## Next-Step UX (Implemented)
- ✅ Added a persistent scope-level Home action (`Local Home` / `Remote Home`) in Repositories.
- ✅ Added a Repositories Overview dashboard with quick actions and live summary metrics:
  - Local repository count
  - Favorite repository count
  - Recent PR count
- ✅ Added MCP UI automation support for the new Repositories surface:
  - View id: `repositories`
  - Controls: `repositories.selectScope`, `repositories.openLocal`, `repositories.openRemote`, `repositories.resetScope`, `repositories.goHome`

## UX Refinement (Implemented)
- ✅ Clarified top-right actions:
  - `Reset` = return current scope (`Local`/`Remote`) to its root list
  - `Home` = return to `Overview`
- ✅ Separated GitHub automation selection from normal user navigation state:
  - Automation now uses dedicated keys (`github.automationSelectedFavoriteKey`, `github.automationSelectedRecentPRKey`)
  - Prevents stale automated detail selection from hijacking normal Remote entry flow

## Risks
- Nested toolbars from embedded root views can feel duplicated.
- Legacy automation selecting `git`/`github` may need explicit remap logic.

## Follow-ups
- Optional: extract shared repository header/status card shown in all scopes.
- Optional: add unified activity stream (local commits + PR activity).
