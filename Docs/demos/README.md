# Demo Scripts

These JSON files describe step-by-step demos for Peel features. They are **human-guided** scripts intended for live walkthroughs. Each step can include a pause so you can narrate, answer questions, then resume.

## Format

```json
{
  "id": "string",
  "title": "string",
  "description": "string",
  "preconditions": ["string"],
  "continueToken": "continue",
  "steps": [
    {
      "type": "app.launch",
      "command": "./Tools/build-and-launch.sh --wait-for-server"
    },
    {
      "type": "mcp.call",
      "tool": "rag.status",
      "arguments": {}
    },
    {
      "type": "app.activate"
    },
    {
      "type": "ui.navigate",
      "path": "agents"
    },
    {
      "type": "ui.tap",
      "path": "agents.localRag"
    },
    {
      "type": "pause",
      "message": "Explain what this screen shows. Type continue to proceed."
    },
    {
      "type": "prompt.compose",
      "template": "Use the snippets below to produce a stronger prompt...",
      "inputs": ["snippet-1", "snippet-2"]
    }
  ]
}
```

## Notes
- These scripts are **human-guided** but can also be run with the simple demo runner.
- Use them as a checklist for a live demo.

## UI Automation

UI steps use MCP tools (`ui.navigate`, `ui.tap`, `ui.setText`, `ui.select`, `ui.toggle`, `ui.snapshot`).
View IDs are reported by `state.list` (e.g., `agents`, `workspaces`, `brew`, `git`, `github`).
Control IDs are the app's accessibility identifiers (e.g., `agents.localRag`).

### Local RAG controls (agents view)
- `agents.localRag.refresh`
- `agents.localRag.repoPath`
- `agents.localRag.init`
- `agents.localRag.index`
- `agents.localRag.query`
- `agents.localRag.mode` (values: `text`, `vector`)
- `agents.localRag.limit` (values: `1`-`25`)
- `agents.localRag.search`
- `agents.localRag.useCoreML`

## Demo Runner

Run a script with the Swift runner:

```bash
./Tools/demo-runner.swift Docs/demos/local-rag-codebase-lookup.json
```

Options:
- `--port 8765` (default: 8765)
- `--auto` (skip pauses)
