# Agents UX Audit (Draft)

Date: 2026-01-20

## Scope
Agents root and related Agent tools sheets/views.

## Screenshots Captured
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T21-48-20Z-agents-root.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T21-48-27Z-agents-mcp-dashboard.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T21-48-35Z-agents-local-rag.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T21-48-43Z-agents-pii-scrubber.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T21-48-50Z-agents-translation-validation.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T21-48-57Z-agents-session-summary.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T21-49-02Z-agents-cli-setup.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T21-49-08Z-agents-vm-isolation.png

## Screenshots Captured (Post-cleanup)
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T22-01-22Z-agents-root-cleanup.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T22-01-31Z-agents-mcp-dashboard-cleanup.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T22-01-44Z-agents-local-rag-cleanup.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T22-01-52Z-agents-pii-scrubber-cleanup.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T22-02-02Z-agents-session-summary-cleanup.png
- /Users/cloken/Library/Application Support/Peel/Screenshots/2026-01-20T22-02-11Z-agents-cli-setup-cleanup.png

## Findings (Preliminary)
These are based on the current Agents navigation surface and control inventory captured via MCP. Visual verification should be done against the screenshots above.

1. **Action overload at the top level**
   - Agents root exposes many entry points (new agent, new chain, MCP dashboard, CLI setup, session summary, VM isolation, translation validation, Local RAG, PII scrubber). This makes the surface feel busy and hard to scan.

2. **Inconsistent grouping across tools**
   - Items mix "operational" tasks (new agent/chain) with "diagnostics" and "utilities" (Local RAG, translation validation, PII scrubber). Without grouping, it reads as a flat toolbar.

3. **Context switching without hierarchy**
   - Tool entry points appear to launch disparate destinations without a cohesive sub-navigation or tab grouping. This can feel like jumping out of the Agents area rather than drilling into a structured toolset.

4. **Limited MCP control coverage inside sheets**
   - MCP exposes only top-level Agents controls today; sheet-internal controls (e.g., filters, tabs, action buttons) are not enumerated. This limits automated UX audit coverage and makes it harder to validate interactions end-to-end.

## Recommendations
1. **Add a primary “Agents” sidebar + a secondary “Tools” grouping**
   - Split Agents/Chains from Utilities. Example:
     - Primary: Agents, Chains, Runs
     - Tools: MCP Dashboard, Local RAG, Translation Validation, PII Scrubber, VM Isolation, CLI Setup

2. **Replace toolbar sprawl with a Tools menu**
   - Move infrequently used utilities into a “Tools” menu (or segmented control). Keep only primary actions (New Agent, New Chain) visible at top.

3. **Provide a persistent Agents home view**
   - Make the root screen a stable overview (active agents, queued runs, recent chains), with consistent entry points into sub-areas.

4. **Add missing MCP control IDs inside sheets**
   - Expose control IDs for primary sheet actions and inputs so screenshot-based audits can validate layout and interactions in a repeatable way.

## MCP Coverage Gaps to Address
- Sheet-level controls (filters, action buttons, tabs) are not available via MCP.
- Navigation within Agents subviews is opaque to `ui.snapshot` (only top-level controls surfaced).

## Next Steps
- Review screenshots and confirm layout concerns.
- Implement tool grouping and reduced toolbar density.
- Add MCP control IDs for sheet-level interactions (start with MCP dashboard + session summary).
