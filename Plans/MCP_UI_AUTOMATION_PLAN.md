# MCP UI Automation & Tool Permissions Plan

## Summary
Enable comprehensive app testing via MCP by adding UI automation tools, view/control registry, and per-tool opt-in settings in the app.

## Goals
- Provide MCP tools to navigate views, invoke UI events, and read state.
- Add a Settings section that lets users opt in/out of specific MCP tools (or categories).
- Ensure safety, auditability, and local-only execution.

## Non-Goals
- Full end-to-end UI testing infrastructure (CI runners, cloud devices).
- Remote MCP exposure beyond localhost.
- Automated UI mutation without explicit opt-in.

## Constraints & Considerations
- macOS/iOS SwiftUI with modern patterns (@Observable, NavigationStack).
- Keep tool calls deterministic and scoped (no arbitrary UI traversal).
- Use stable identifiers (accessibility identifiers) for controls and views.

## Proposed Architecture
### 1) UI Automation Layer
- View registry that maps logical IDs to navigable destinations.
- Control registry for key actions (buttons, toggles, text fields).
- MCP tools:
  - `ui.navigate(viewId)`
  - `ui.back()`
  - `ui.tap(controlId)`
  - `ui.setText(controlId, value)`
  - `ui.toggle(controlId, on)`
  - `ui.select(controlId, value)`
  - `ui.snapshot()` (returns current view + visible control IDs)

### 2) State & Inspection
- `state.get()` for current tab, selected repo/PR, active chain, etc.
- `state.list()` for available view IDs and controls.

### 3) Tool Permissions
- MCP tool registry includes category + risk level.
- Settings allowlist for tools (per tool or per category).
- MCP server denies calls to disabled tools with clear error.

### 4) Settings UI
- New “MCP Tools” section in Settings:
  - Enable/disable tool categories and individual tools.
  - “Enable All” / “Disable All” actions.
  - Description per tool (and risk notes).

### 5) Logging & Safety
- Log all tool calls + duration in MCP log.
- Rate-limit destructive tools.
- Require explicit opt-in for state-changing tools.

## Data Storage
- Store tool opt-in map in UserDefaults (simple) or SwiftData (if we want sync).
- Keep defaults conservative (read-only tools enabled, mutating tools disabled).

## UX Placement
- Settings: add “MCP Tools” section after “MCP Test Harness.”
- Agents MCP dashboard: show enabled tool count and last blocked call.

## Implementation Phases
1. **Registry + Permissions**
   - Add tool registry metadata + allowlist checks in MCP server.
   - Add Settings toggles and persistence.
2. **Navigation Tools**
   - Implement `ui.navigate`, `ui.back`, `ui.snapshot`.
3. **Action Tools**
   - Implement `ui.tap`, `ui.toggle`, `ui.setText`, `ui.select`.
4. **State Tools**
   - Implement `state.get`, `state.list`.
5. **Coverage Expansion**
   - Register view/control IDs for GitHub, Agents, Brew, Git, Workspaces.

## Acceptance Criteria
- [ ] MCP tools are listed with category + enabled status.
- [ ] Disabled tools return a deterministic MCP error.
- [ ] Settings allow user to opt in/out per tool or category.
- [ ] Navigation and basic action tools can drive the GitHub and Agents tabs.
- [ ] MCP log includes tool call metadata + timing.

## Open Questions
- Should tool permissions be per-device only or iCloud synced?
- Where should view/control IDs live (central registry vs per-feature)?
- Do we need a “safe mode” that disables state-changing tools by default?
