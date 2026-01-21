#!/usr/bin/env python3
import argparse
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", default="microsoft/codebert-base")
    parser.add_argument("--seq-len", type=int, default=256)
    parser.add_argument("--output", default="Tools/ModelTools/output/codebert-base-256.mlpackage")
    args = parser.parse_args()

    output_path = Path(args.output)
    convert(args.model_id, args.seq_len, output_path)
    print(f"Saved Core ML model to {output_path}")


if __name__ == "__main__":
    main()
