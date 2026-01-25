## Summary
Document how MCP tool permissions and discovery work for CLI-driven chains, and how to verify RAG tool availability.

## Proposed Charts / Work
- Add a short section explaining MCP tool permissions (enabled tools, blocked tools) and how agents discover tools.
- Document how to verify tool availability via `tools.list` and `rag.ui.status`.
- Add a note that chain prompts alone do not enforce tool use unless validation/flags require it.

## Data Source
- MCP server tool registry and permissions store

## UI Placement
- Docs/guides/MCP_AGENT_WORKFLOW.md (or MCP_VALIDATION.md)

## Acceptance Criteria
- [ ] Docs explain where MCP tools live and how permissions affect availability.
- [ ] Docs include a verification checklist using `tools.list` and `rag.ui.status`.
- [ ] Docs clarify that `requireRagUsage` enforces a warning if RAG tools are not used.
