# Local RAG Model Catalog

This guide documents the Local RAG Core ML model catalog and the conversion pipeline for generating embedding assets.

## Catalog Location
- Tools/ModelTools/model-catalog.json

Each entry defines:
- `id` for CLI selection
- `source.modelId` for Hugging Face
- `seqLen` for tokenizer/model input
- `outputPath` for the generated `.mlpackage`
- `artifacts` for the compiled model and tokenizer assets

## Convert a Catalog Model

1. Convert the model using the catalog entry:
```bash
python3 Tools/ModelTools/convert_codebert_to_coreml.py --model codebert-base-256
```

2. Compile the `.mlpackage` to `.mlmodelc`:
```bash
xcrun coremlc compile Tools/ModelTools/output/codebert-base-256.mlpackage Tools/ModelTools/output
```

3. Copy assets into the app support folder (choose one or both paths):
```bash
# App support
mkdir -p "$HOME/Library/Application Support/Peel/RAG/Models"
cp -R Tools/ModelTools/output/codebert-base-256.mlmodelc "$HOME/Library/Application Support/Peel/RAG/Models/"
cp Tools/ModelTools/output/codebert-base.vocab.json "$HOME/Library/Application Support/Peel/RAG/Models/"
cp Tools/ModelTools/output/tokenize_codebert.py "$HOME/Library/Application Support/Peel/RAG/Models/"

# Sandbox container (macOS app sandbox)
mkdir -p "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models"
cp -R Tools/ModelTools/output/codebert-base-256.mlmodelc "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/"
cp Tools/ModelTools/output/codebert-base.vocab.json "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/"
cp Tools/ModelTools/output/tokenize_codebert.py "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/"
```

4. Restart Peel and verify Local RAG status (Agents → Local RAG). The status should report the Core ML embedding provider if assets are present.

## Adding a New Model

1. Add a new entry to Tools/ModelTools/model-catalog.json.
2. Run the conversion with `--model <id>`.
3. Validate with `rag.status` and `rag.search`.

## Troubleshooting
- If you see “tokenizer helper missing”, ensure `tokenize_codebert.py` is copied alongside the model.
- If the Core ML model fails to load, run `rag.model.describe` on the bundle to inspect input/output shapes.
