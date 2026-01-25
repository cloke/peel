# Local RAG Loop Test Workflow

End-to-end workflow to validate indexing, search, and planner grounding.

Last updated: 2026-01-25

---

## Quick Validation (TL;DR)

```bash
# 1. Build CLI
cd /path/to/KitchenSink && swift build -c debug --package-path Tools/PeelCLI

# 2. Ensure Peel is running with MCP enabled (port 8765)

# 3. Run pattern check (no server needed for --diff-only)
Tools/PeelCLI/.build/debug/peel-mcp rag-pattern-check --repo-path .

# 4. Check RAG status
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.status
```

---

## Full Workflow

### Prereqs
- Peel built and running with MCP enabled
- Local RAG model installed (see `Docs/guides/LOCAL_RAG_MODEL_SETUP.md`)
- MCP tool permissions enabled for `rag.init`, `rag.index`, `rag.search`

---

## 1) Initialize and index

```bash
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.init
```

```bash
cat > tmp/peel-mcp-args.json <<'JSON'
{
  "repoPath": "/Users/you/code/KitchenSink"
}
JSON

Tools/PeelCLI/.build/debug/peel-mcp tools-call \
  --tool-name rag.index \
  --arguments-json tmp/peel-mcp-args.json
```

Expected: non-zero `filesIndexed` and `chunksIndexed`.

---

## 2) Text search sanity check

```bash
cat > tmp/peel-mcp-args.json <<'JSON'
{
  "query": "DateFormatter()",
  "repoPath": "/Users/you/code/KitchenSink",
  "mode": "text",
  "limit": 3
}
JSON

Tools/PeelCLI/.build/debug/peel-mcp tools-call \
  --tool-name rag.search \
  --arguments-json tmp/peel-mcp-args.json
```

Expected: results contain file paths and snippets.

---

## 3) Vector search validation

```bash
cat > tmp/peel-mcp-args.json <<'JSON'
{
  "query": "Local RAG embeddings",
  "repoPath": "/Users/you/code/KitchenSink",
  "mode": "vector",
  "limit": 3
}
JSON

Tools/PeelCLI/.build/debug/peel-mcp tools-call \
  --tool-name rag.search \
  --arguments-json tmp/peel-mcp-args.json
```

Expected: results returned with relevant docs/code.

---

## 4) Planner grounding smoke test

Run a lightweight chain with RAG enabled and inspect the grounded context:

```bash
Tools/PeelCLI/.build/debug/peel-mcp chains-run \
  --prompt "Summarize the Local RAG architecture and list key files" \
  --working-directory "/Users/you/code/KitchenSink"
```

Expected: chain results include file snippets from RAG search.

---

## 5) Pre-commit pattern check

Validate staged changes don't introduce deprecated patterns:

```bash
# Stage some Swift files
git add path/to/file.swift

# Check staged changes only (doesn't need MCP server)
Tools/PeelCLI/.build/debug/peel-mcp rag-pattern-check --diff-only
```

Expected: "No pattern matches in staged changes. ✅" or list of matches.

---

## 6) Status snapshot

```bash
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.status
```

Expected: Core ML asset flags are true and `schemaVersion` is 1.

---

## Validation Checkpoints

| Step | Command | Success Criteria |
|------|---------|------------------|
| Init | `rag.init` | No error |
| Index | `rag.index` | `filesIndexed > 0` |
| Text search | `rag.search` (text) | Results returned |
| Vector search | `rag.search` (vector) | Results returned |
| Pattern check | `rag-pattern-check` | Runs without crash |
| Status | `rag.status` | Core ML flags = true |

---

## Troubleshooting

**"No staged changes found"** - Use `--repo-path` for full repo scan, or stage files first.

**"Connection refused"** - MCP server not running. Launch Peel with MCP enabled.

**"Core ML assets missing"** - Follow `LOCAL_RAG_MODEL_SETUP.md` to install models.