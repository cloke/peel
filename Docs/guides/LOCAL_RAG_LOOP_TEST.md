# Local RAG Loop Test Workflow

End-to-end workflow to validate indexing, search, and planner grounding.

Last updated: 2026-01-24

---

## Prereqs
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

## 5) Status snapshot

```bash
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.status
```

Expected: Core ML asset flags are true and `schemaVersion` is 1.