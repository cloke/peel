# Local RAG Demo Workflow

This guide documents the Local RAG demo scripts and the runner used to drive the Peel UI via MCP. The goal is a repeatable demo where you only type `continue` to advance talking points and UI state.

## What This Demo Shows

- Local RAG indexing and search status
- Core ML embedding provider visibility
- A vector search executed from the UI
- Grounded prompts built from retrieved snippets

## Requirements

- Peel app can build and launch
- Local RAG has indexed the KitchenSink repo
- Core ML assets installed (optional, if using Core ML embeddings)

## Demo Scripts

- Docs/demos/local-rag-codebase-lookup.json
- Docs/demos/prompt-boost-with-snippets.json

Each script includes:
- `pause` steps for narration
- MCP UI automation steps (`ui.navigate`, `ui.tap`, `ui.setText`, `ui.select`, `ui.toggle`)
- MCP calls (`rag.status`, `rag.search`) for validation

## Running the Demo

Run the Local RAG demo:

- Tools/demo-runner.swift Docs/demos/local-rag-codebase-lookup.json

If you want to skip pauses:

- Tools/demo-runner.swift Docs/demos/local-rag-codebase-lookup.json --auto

## UI Automation Notes

### View IDs

Use `state.list` to see available view IDs:
- agents
- workspaces
- brew
- git
- github

### Local RAG Control IDs

These are available while on the `agents` view:
- agents.localRag
- agents.localRag.refresh
- agents.localRag.repoPath
- agents.localRag.init
- agents.localRag.index
- agents.localRag.query
- agents.localRag.mode (values: text, vector)
- agents.localRag.limit (values: 1–25)
- agents.localRag.search
- agents.localRag.useCoreML

## Typical Flow (Local RAG Demo)

1. Launch and activate Peel
2. Navigate to Agents > Local RAG
3. Show Core ML status and DB info
4. Set query + vector mode + limit
5. Tap Search in UI
6. Compare UI results to MCP `rag.search`
7. Build a grounded prompt from snippets

## Troubleshooting

- If MCP UI tools report `foreground needed`, call `app.activate` and retry.
- If the UI fields don’t update, ensure the app was launched with MCP enabled.
- If search returns irrelevant files, re-index or narrow the query.
