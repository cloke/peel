#!/usr/bin/env python3
import argparse
import os
from pathlib import Path

from docling.datamodel.accelerator_options import AcceleratorOptions
from docling.datamodel.base_models import InputFormat
from docling.datamodel.pipeline_options import ThreadedPdfPipelineOptions
from docling.document_converter import DocumentConverter, PdfFormatOption


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert a document to Markdown with Docling")
    parser.add_argument("--input", required=True, help="Input file path or URL")
    parser.add_argument("--output", required=True, help="Output markdown file path")
    parser.add_argument(
        "--profile",
        default="high",
        choices=["high", "standard"],
        help="Conversion profile (default: high)",
    )
    args = parser.parse_args()

    os.environ.setdefault("DOCLING_DEVICE", "cpu")
    if args.profile == "high":
        pipeline_options = ThreadedPdfPipelineOptions(
            accelerator_options=AcceleratorOptions(device="cpu"),
            do_ocr=True,
            do_table_structure=True,
            do_code_enrichment=True,
            do_formula_enrichment=True,
            images_scale=2.0,
        )
    else:
        pipeline_options = ThreadedPdfPipelineOptions(
            accelerator_options=AcceleratorOptions(device="cpu")
        )
    converter = DocumentConverter(
        format_options={
            InputFormat.PDF: PdfFormatOption(pipeline_options=pipeline_options)
        }
    )
    result = converter.convert(args.input)
    markdown = result.document.export_to_markdown()

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(markdown, encoding="utf-8")


if __name__ == "__main__":
    main()
