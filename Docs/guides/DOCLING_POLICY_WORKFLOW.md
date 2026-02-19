# Docling Policy Workflow

This guide explains how to use Docling inside Peel to convert policy PDFs to Markdown, validate policies with rules, and analyze them with Local RAG.

## What Docling does and why it’s useful

Docling is a document conversion and analysis tool that extracts structured Markdown from PDFs (including OCR for scanned documents), identifies headings, tables, code blocks, and allows running validation rules against the converted Markdown. In Peel, Docling helps teams ingest corporate policies, standard operating procedures, and regulatory documents into a searchable policy repository so you can: 

- Convert PDFs to readable, linkable Markdown
- Apply automated validation rules (regex or phrase matches)
- Index policies into Local RAG for natural-language search and question answering
- Track violations and surface them in the UI

## Installation

Peel supports two installation flows for Docling:

1. Automatic (recommended)

- From Docling Import in Peel, click "Install Docling". This creates a Python venv under Application Support/Peel/docling-venv and installs Docling into it.
- Requirements: Python 3.10+ must be available on your machine (system python or Homebrew python).

Notes:
- The venv is stored in the standard Application Support directory so other users/processes won’t accidentally modify it.
- If installation fails, check the install log visible in the Docling Import view.

2. Manual

- Create a virtualenv manually and pip install docling:

  python3 -m venv ~/tmp/docling-venv
  source ~/tmp/docling-venv/bin/activate
  pip install --upgrade pip
  pip install docling

- In Peel’s Docling Import view set the Python Path to the venv python executable and, if needed, the Script Path to the repo `Tools/docling-convert.py` script.

## Converting PDFs to Markdown

1. Pick the company and preset that will own the policy.
2. Browse for the input PDF and set an output path for the Markdown (.md).
3. Choose a profile (High / Standard) — high uses more OCR and heavier processing; standard is faster.
4. Click Convert. The converted Markdown is saved to the output path and a copy is stored under Application Support/Peel/Policies/<company-slug>/.

Screenshots

- Screenshot: Docling Import view with input/output and profile settings. (Include a screenshot showing the input PDF selection, output path, and Convert button.)
- Screenshot: Conversion success with "Open Output" available.

## Policy validation concepts

- Company: A logical scope for policies. Policies are organized under companies so rules and presets can be scoped per-organization.
- Preset: A conversion preset (profile, OCR, table extraction settings) that can be reused across imports.
- Rule: A validation rule that runs against converted Markdown. Rules contain:
  - name
  - pattern (a regex or plain phrase)
  - severity (info, warning, critical)

Why scope matters:
- Different companies have different compliance requirements and rule sets. Scoping rules to companies allows teams to have tailored checks.

## Presets and profiles

Peel includes a simple preset system:
- High: aggressive image scaling, OCR, table recognition and code/formula detection.
- Standard: faster, fewer heuristics.

Create custom presets from the Docling Import view and save them. Presets affect the conversion step and therefore the content and structure of the resulting Markdown.

## Example validation rules

- Email disclosure check (simple phrase):

  Name: "Personal email disclosure"
  Pattern: `\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-z]{2,}\b`
  Severity: warning

- Prohibited phrase (exact match):

  Name: "No personal devices"
  Pattern: `"personal devices are not allowed"`
  Severity: critical

- Policy section header check (ensure a section exists):

  Name: "Has Data Retention section"
  Pattern: `(?m)^#+\s*Data Retention`  
  Severity: info

Best practices:
- Use anchored regex when you expect structure (e.g., `^` and `$` or multiline flags).
- Test regex against a sample converted Markdown before applying wide-scoped rules.
- Start with `info` severity for broad rules to avoid noise.

## Integration with Local RAG

- After converting and storing a policy for a company, Peel will index the company policy directory into the local RAG store.
- Indexed policies become searchable by natural language via the app’s RAG search UI and can be used by agents.
- Tips for better RAG results:
  - Ensure headings (#, ##) are preserved in the converted Markdown — they improve chunking and retrieval.
  - Keep tables and key-value lists intact where possible.

## Troubleshooting

- Install failures:
  - Confirm Python 3.10+ is installed and on PATH. Try `python3 --version`.
  - Check the install log shown after installation attempts (visible in Docling Import view).
  - If pip install fails due to missing build tools, install Xcode Command Line Tools: `xcode-select --install`.

- GPU / MPS errors (when Docling or OCR uses accelerated libs):
  - On macOS Apple Silicon, some libraries attempt to use MPS and may fail if not supported. Retry by using a CPU-only fallback or run conversion on a machine with supported drivers.

- Conversion produces garbled text:
  - Try the High profile (more aggressive OCR) if the PDF is scanned.
  - Inspect the raw output `.md` file and check the OCR section outputs.

- Script not found:
  - Ensure `Tools/docling-convert.py` exists in the project root or set the Script Path in Docling Import.

## Common workflows

1. First import
  - Add a company, set a preset, select PDF, Convert, then Run Validation.
2. Ongoing checks
  - Add or tune rules for a company and run validation after each conversion.

## Screenshots and assets

Add screenshots under `Docs/guides/assets/docling/` using descriptive filenames (e.g., `import-view.png`, `conversion-success.png`). Reference them in this guide:

![Import view](assets/docling/import-view.png)

## Links

- MCP tool docs: see `Shared/AgentOrchestration/MCPServerService+ToolDefinitions.swift` for RPC tool names like `docling.convert` and `docling.setup`.
- Implementation: `Shared/Services/DoclingService.swift` contains the conversion and install helpers.

---

If something in this guide is unclear, open an issue in the repository with the subject "Docling doc request".
