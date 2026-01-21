#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
from transformers import AutoModel, AutoTokenizer


def build_model(model_id: str, seq_len: int):
    tokenizer = AutoTokenizer.from_pretrained(model_id)
    model = AutoModel.from_pretrained(model_id)
    model.eval()

    class MeanPoolEncoder(torch.nn.Module):
        def __init__(self, base):
            super().__init__()
            self.base = base

        def forward(self, input_ids, attention_mask):
            outputs = self.base(input_ids=input_ids, attention_mask=attention_mask)
            token_embeddings = outputs.last_hidden_state
            mask = attention_mask.unsqueeze(-1).type_as(token_embeddings)
            summed = (token_embeddings * mask).sum(dim=1)
            counts = mask.sum(dim=1).clamp(min=1e-9)
            pooled = summed / counts
            return pooled

    wrapped = MeanPoolEncoder(model)

    example_input = torch.zeros((1, seq_len), dtype=torch.int64)
    example_mask = torch.ones((1, seq_len), dtype=torch.int64)
    traced = torch.jit.trace(wrapped, (example_input, example_mask))
    return tokenizer, traced


def convert(model_id: str, seq_len: int, output_path: Path):
    tokenizer, traced = build_model(model_id, seq_len)

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, seq_len), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, seq_len), dtype=np.int32),
        ],
        convert_to="mlprogram",
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))

    vocab_path = output_path.parent / "codebert-base.vocab.json"
    vocab = tokenizer.get_vocab()
    with vocab_path.open("w", encoding="utf-8") as handle:
        import json
        json.dump(vocab, handle)

    helper_path = Path(__file__).parent / "tokenize_codebert.py"
    if helper_path.exists():
        target = output_path.parent / helper_path.name
        target.write_text(helper_path.read_text(encoding="utf-8"), encoding="utf-8")


def load_catalog(path: Path):
    if not path.exists():
        raise SystemExit(f"Model catalog not found at {path}")
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    models = data.get("models", [])
    return {model.get("id"): model for model in models}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", help="Catalog model id")
    parser.add_argument("--catalog", default="Tools/ModelTools/model-catalog.json")
    parser.add_argument("--model-id", default="microsoft/codebert-base")
    parser.add_argument("--seq-len", type=int, default=256)
    parser.add_argument("--output")
    args = parser.parse_args()

    model_id = args.model_id
    seq_len = args.seq_len
    output = args.output

    if args.model:
        catalog = load_catalog(Path(args.catalog))
        entry = catalog.get(args.model)
        if entry is None:
            raise SystemExit(f"Model '{args.model}' not found in catalog")
        source = entry.get("source", {}) if isinstance(entry.get("source"), dict) else {}
        model_id = source.get("modelId", model_id)
        seq_len = entry.get("seqLen", seq_len)
        output = output or entry.get("outputPath")

    output = output or "Tools/ModelTools/output/codebert-base-256.mlpackage"

    output_path = Path(output)
    convert(model_id, seq_len, output_path)
    print(f"Saved Core ML model to {output_path}")


if __name__ == "__main__":
    main()
