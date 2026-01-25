# Local RAG Model Setup (CodeBERT → Core ML)

This guide documents how to obtain and install a Local RAG embedding model during development.

Last updated: 2026-01-25

---

## Overview

Peel uses a Core ML embedding model for Local RAG. The current catalog entry is CodeBERT (`microsoft/codebert-base`).

### Required Artifacts

| Artifact | Description |
|----------|-------------|
| `codebert-base-256.mlmodelc` | Compiled Core ML model |
| `codebert-base.vocab.json` | BPE vocabulary file |
| `tokenize_codebert.py` | Python tokenizer helper |

### Model Catalog

See `Tools/ModelTools/model-catalog.json` for the definitive list of supported models.

---

## 1) Prerequisites

- Python 3.10+ with pip
- Xcode Command Line Tools (for `coremlc`)
- Required packages: `coremltools`, `transformers`, `torch`

```bash
pip install coremltools transformers torch
```

---

## 2) Convert the model to Core ML

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

### Limitations

- Model conversion requires Python + ML packages (not included in app)
- Core ML models are platform-specific (macOS only currently)
- First-time indexing with vector embeddings is slower than text-only

### Future Options

1. **Pre-compiled models** - Ship compiled `.mlmodelc` with app bundle
2. **Download service** - On-demand model download from CDN
3. **Separate CLI tool** - Standalone converter installable via Homebrew