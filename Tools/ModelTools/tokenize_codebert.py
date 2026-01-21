#!/usr/bin/env python3
import argparse
import json
import sys

from transformers import AutoTokenizer


def tokenize(text: str, model_id: str, max_length: int):
    tokenizer = AutoTokenizer.from_pretrained(model_id, use_fast=True)
    encoded = tokenizer(
        text,
        truncation=True,
        padding="max_length",
        max_length=max_length,
        return_attention_mask=True,
        return_tensors=None,
    )
    return {
        "input_ids": encoded["input_ids"],
        "attention_mask": encoded["attention_mask"],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", default="microsoft/codebert-base")
    parser.add_argument("--max-length", type=int, default=256)
    parser.add_argument("--text", required=True)
    args = parser.parse_args()

    result = tokenize(args.text, args.model_id, args.max_length)
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
