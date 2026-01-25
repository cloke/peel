#!/usr/bin/env python3
"""
⚠️  DEPRECATED - NOT USED IN PRODUCTION ⚠️

This Python tokenizer has been replaced by a native Swift implementation:
  Shared/Services/LocalRAGEmbeddings.swift → SwiftBPETokenizer

The Swift version eliminates subprocess overhead (~100-500ms per call)
and is ~100x faster for batch operations.

This file is kept for reference and debugging only.
To compare tokenization outputs:
  python3 tokenize_codebert.py --model-id microsoft/codebert-base --text "your text"

Last used: January 2026
---

CodeBERT tokenizer for Peel RAG.

Supports both single-text and batch modes:
  Single: --text "some code"
  Batch:  --batch (reads JSON array from stdin)

Batch mode is critical for performance - loading the tokenizer once
and processing all texts is ~100x faster than spawning per-text.
"""
import argparse
import json
import sys

from transformers import AutoTokenizer


def tokenize_single(tokenizer, text: str, max_length: int):
    """Tokenize a single text."""
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


def tokenize_batch(tokenizer, texts: list, max_length: int):
    """Tokenize multiple texts in one call."""
    if not texts:
        return []
    
    encoded = tokenizer(
        texts,
        truncation=True,
        padding="max_length",
        max_length=max_length,
        return_attention_mask=True,
        return_tensors=None,
    )
    
    # Convert batch format to list of dicts
    results = []
    for i in range(len(texts)):
        results.append({
            "input_ids": encoded["input_ids"][i],
            "attention_mask": encoded["attention_mask"][i],
        })
    return results


def main():
    parser = argparse.ArgumentParser(description="CodeBERT tokenizer for Peel RAG")
    parser.add_argument("--model-id", default="microsoft/codebert-base")
    parser.add_argument("--max-length", type=int, default=256)
    parser.add_argument("--text", help="Single text to tokenize")
    parser.add_argument("--batch", action="store_true", 
                        help="Batch mode: read JSON array of texts from stdin")
    args = parser.parse_args()

    # Load tokenizer once
    tokenizer = AutoTokenizer.from_pretrained(args.model_id, use_fast=True)

    if args.batch:
        # Batch mode: read JSON array from stdin
        try:
            texts = json.load(sys.stdin)
            if not isinstance(texts, list):
                print(json.dumps({"error": "Expected JSON array of strings"}), file=sys.stderr)
                sys.exit(1)
            results = tokenize_batch(tokenizer, texts, args.max_length)
            json.dump(results, sys.stdout)
        except json.JSONDecodeError as e:
            print(json.dumps({"error": f"Invalid JSON: {e}"}), file=sys.stderr)
            sys.exit(1)
    elif args.text:
        # Single text mode (legacy)
        result = tokenize_single(tokenizer, args.text, args.max_length)
        json.dump(result, sys.stdout)
    else:
        parser.error("Either --text or --batch is required")


if __name__ == "__main__":
    main()
