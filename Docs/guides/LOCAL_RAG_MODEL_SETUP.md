# Local RAG Model Setup (CodeBERT → Core ML)

This guide documents how to obtain and install a Local RAG embedding model during development.

Last updated: 2026-01-24

---

## Overview

Peel uses a Core ML embedding model for Local RAG. The current catalog entry is CodeBERT (`microsoft/codebert-base`).

Artifacts required:
- `codebert-base-256.mlmodelc`
- `codebert-base.vocab.json`
- `tokenize_codebert.py`

---

## 1) Convert the model to Core ML

From the repo root:

```bash
python3 Tools/ModelTools/convert_codebert_to_coreml.py --model codebert-base-256
```

Output:
```
Tools/ModelTools/output/codebert-base-256.mlpackage
Tools/ModelTools/output/codebert-base.vocab.json
Tools/ModelTools/output/tokenize_codebert.py
```

---

## 2) Compile and install artifacts

Compile the model and copy artifacts into the app support directory:

```bash
mkdir -p "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models"

/usr/bin/xcrun coremlc compile \
  Tools/ModelTools/output/codebert-base-256.mlpackage \
  "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models"

cp Tools/ModelTools/output/codebert-base.vocab.json \
  "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/"

cp Tools/ModelTools/output/tokenize_codebert.py \
  "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/"
```

Optional mirror for non-container Application Support:

```bash
mkdir -p "$HOME/Library/Application Support/Peel/RAG/Models"
cp -R "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/codebert-base-256.mlmodelc" \
  "$HOME/Library/Application Support/Peel/RAG/Models/"
cp "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/codebert-base.vocab.json" \
  "$HOME/Library/Application Support/Peel/RAG/Models/"
cp "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/tokenize_codebert.py" \
  "$HOME/Library/Application Support/Peel/RAG/Models/"
```

---

## 3) Validate via MCP

Ensure the MCP server is running, then check:

```bash
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.status
```

Expected flags:
- `coreMLModelPresent: true`
- `coreMLVocabPresent: true`
- `coreMLTokenizerHelperPresent: true`

Then confirm vector search works:

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

---

## Release Notes

For release builds, conversion should be external (CLI or precompiled assets). Shipping coremltools/transformers in-app is not recommended.