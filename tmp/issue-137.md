## Summary
Expose `requireRagUsage` in the MCP UI so operators can enforce RAG usage without CLI flags.

## Proposed Charts / Work
- Add a toggle in MCP dashboard run controls for "Require RAG usage".
- Persist the toggle in run overrides and pass it to `chains.run`.
- Show the requirement in run status details.

## Data Source
- MCP run overrides / chain run arguments

## UI Placement
- Agents → MCP Dashboard (run controls)

## Acceptance Criteria
- [ ] Toggle appears in MCP run controls.
- [ ] Starting a run with the toggle sets `requireRagUsage` in the RPC args.
- [ ] Run status shows `requireRagUsage` when enabled.
- [ ] Validation emits a warning when no RAG tool call occurs during required runs.
