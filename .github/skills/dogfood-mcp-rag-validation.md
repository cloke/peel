# Skill: Dogfood MCP + RAG Validation

## When to Use
- Peel is expected to build features via MCP chains.
- You need to validate RAG relevance and UX surfaces.

## Prerequisites
- MCP server running (use start-mcp-chain skill if needed).
- Repo indexed for Local RAG.

## Safety Rules (Non-Negotiable)
- **Never use blanket checkout** (e.g., `git checkout -- .` or multi-file checkout without confirmation).
- If unexpected files are modified, **assume an agent forgot to commit** and **do not discard work**.
- Prefer **stash-first** when uncertain (include untracked files), then investigate.

## Steps
1. **Build + launch Peel (MCP enabled)**
   - Use the standard build-and-launch flow.
2. **Run an MCP chain**
   - Use a planner + implementers + reviewer template.
   - Require planner to use RAG before task breakdown.
3. **Validate**
   - Reviewer confirms changes match plan and project patterns.
   - Run RAG pattern checks if applicable.
4. **Record RAG feedback**
   - Note when snippets helped vs. misled.
   - Log missing context or index gaps.

## Recovery Playbook (If Unexpected Changes Appear)
1. `git status`
2. **Stash** (include untracked files).
3. Inspect MCP run history and agent workspaces.
4. Decide: apply stash into a proper commit or keep isolated.

## RAG UX Validation Checklist
- Planner used RAG at least once.
- RAG snippets were relevant (target ≥2 of 3 prompts).
- Reviewer notes false positives.
- UX surfaces show latest RAG status/query/snippets.
