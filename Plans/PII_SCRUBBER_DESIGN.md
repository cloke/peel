---
title: PII Scrubber Design
status: active
updated: 2026-01-20
owner: cloke
related_issues:
  - 31
  - 76
---

# PII Scrubber Design

## Summary
This document defines the PII scrubber architecture, detection strategies, rules config, supported inputs, and audit reporting. It builds on the existing `pii-scrubber` CLI and the UI/MCP integration in Peel.

## Goals
- Provide deterministic, repeatable scrubbing for local datasets.
- Support structured rules for per-table/column behavior.
- Offer on-device NER detection (opt-in) with clear reporting.
- Produce audit reports with counts and samples for verification.

## Non-Goals
- Cloud-based detection or storage.
- Real-time streaming scrubbing for large clusters (future).

## Inputs & Outputs
- **Inputs**: SQL dumps, JSON, CSV, SQLite export files.
- **Outputs**: Scrubbed file in same format.
- **Reports**: JSON (default) or text, with counts and samples.

## Detection Strategies
1. **Regex-based detectors**
   - Email, phone, SSN, credit cards, and other well-known formats.
2. **Column-aware heuristics**
   - Column name matching (`email`, `phone`, `ssn`, `name`, `address`, `org`, etc.).
3. **NER (optional)**
   - On-device entity recognition for names/addresses/organizations.
   - Opt-in via `--enable-ner`.

## Rules Configuration
Rules are defined via YAML or JSON config files. A rule applies to a table and column and chooses an action.

### Example YAML
```yaml
version: 1
rules:
  - table: users
    column: email
    action: fake
    format: email
  - table: users
    column: phone
    action: redact
  - table: companies
    column: name
    action: preserve
  - table: audit_logs
    action: drop
```

### Actions
- `preserve`: leave value unchanged.
- `redact`: replace with a fixed redaction token.
- `fake`: generate deterministic fake data (seed-based).
- `drop`: remove row or column where supported.

### Validation
- Surface invalid rules and config errors in UI/MCP.
- Fail fast on unknown actions or malformed rules.

## Fake Data Generation
- Deterministic based on `--seed`.
- Format-specific generators (email, phone, SSN, credit_card, name, address, organization).
- Consistent output across runs with the same seed.

## Audit Report
- **Counts** by detector and rule category.
- **Samples** (configurable count per category) with original → replacement.
- Summary timestamps for start and completion.

## Performance
- Streaming parse where possible.
- Chunked processing to avoid high memory usage on large dumps.
- Optional max samples to bound report size.

## UI & MCP Integration
- PII Scrubber UI allows config path, NER toggle, report export.
- MCP tools return validation errors and report summary for automation.

## Risks & Mitigations
- **False positives**: keep rules and samples visible.
- **False negatives**: allow NER + column heuristics.
- **Large files**: stream processing and progress reporting.

## Future Work
- NER model upgrades and language expansion.
- Schema-aware preview of rule coverage.
- Streaming progress and partial report exports.
