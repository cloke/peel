# Code Health Playbook

This playbook is the fastest repeatable way to do a deep code-health pass in Peel using the existing build, test, and Local RAG tooling.

## Goals

- Catch regressions before cleanup work starts.
- Find structural hotspots, duplicate logic, and dead-code candidates.
- Turn RAG output into an actionable short list instead of a noisy dump.
- Re-run the same sequence after refactors for before/after comparison.

## What A Good Pass Looks Like

Run the audit in layers:

1. Build and tests to establish a baseline.
2. Refresh the RAG index so later queries use current code.
3. Analyze structure, duplicates, and patterns.
4. Run orphan detection with the repo baseline enabled.
5. Review only the top candidates and convert them into concrete cleanup work.

## Pre-Audit Snapshot

The initial pre-audit on March 7, 2026 produced two useful signals:

- `peel-mcp rag-audit --repo-path /Users/coryloken/code/peel --limit 10` returned `0` deprecated-pattern matches.
- `rag.orphans` still returned many obvious false positives without additional filtering, including Markdown docs, HTML artifacts, entry points, and known same-module extension files.

That is why the orphan workflow below matters: use the filtered report first, and only fall back to the raw report when you are debugging the detector itself.

## Phase 1: Baseline Build And Tests

```bash
cd /Users/coryloken/code/peel
./Tools/build.sh
```

If you want a tighter health pass, also run the most relevant test targets from Xcode or your usual XCTest flow before changing code.

## Phase 2: Refresh RAG Context

Build-and-launch is already the expected MCP path in this repo. Once Peel is running with MCP enabled:

```bash
cd /Users/coryloken/code/peel
mkdir -p tmp

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","forceReindex":false}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.index --arguments-json tmp/peel-mcp-args.json

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","limit":200}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.analyze --arguments-json tmp/peel-mcp-args.json

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","limit":500}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.enrich --arguments-json tmp/peel-mcp-args.json
```

Use `rag.analyze` and `rag.enrich` before semantic deep-dives. Without them, duplicate and concept-driven searches are materially weaker.

## Phase 3: Modernization And Safety Sweep

```bash
cd /Users/coryloken/code/peel
Tools/PeelCLI/.build/debug/peel-mcp rag-audit --repo-path /Users/coryloken/code/peel --limit 20
Tools/PeelCLI/.build/debug/peel-mcp rag-pattern-check --repo-path /Users/coryloken/code/peel --limit 10
```

Use this phase to catch deprecated SwiftUI and concurrency patterns before broader refactors. In Peel, this is the quickest way to confirm whether cleanup work is modernization work or architectural work.

## Phase 4: Structural Health Sweep

Look for files that are too large, too dense, or too central.

```bash
cd /Users/coryloken/code/peel

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","statsOnly":true}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.structural --arguments-json tmp/peel-mcp-args.json

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","minLines":800,"sortBy":"lines","limit":20}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.structural --arguments-json tmp/peel-mcp-args.json

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","limit":20}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.hotspots --arguments-json tmp/peel-mcp-args.json
```

Review the overlap between very large files and hotspots first. Those are usually the highest-value cleanup targets.

## Phase 5: Duplicate Logic Sweep

```bash
cd /Users/coryloken/code/peel

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","limit":25,"minFiles":2}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.duplicates --arguments-json tmp/peel-mcp-args.json
```

Use `rag.similar` after `rag.duplicates` when a single suspect helper or view needs a more targeted search.

## Phase 6: Orphan And Dead-Code Sweep

Start with the filtered orphan report.

```bash
cd /Users/coryloken/code/peel

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","excludeTests":true,"excludeEntryPoints":true,"limit":50}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.orphans --arguments-json tmp/peel-mcp-args.json
```

Current default behavior:

- Non-code files such as Markdown, HTML, plist, and JSON are suppressed.
- Files listed in `Docs/reference/RAG_ORPHAN_BASELINE.md` are suppressed.
- The response includes `suppressedNonCodePaths` and `suppressedBaselinePaths` so you can see what was removed.

If you need the raw detector output for debugging the index itself:

```bash
cd /Users/coryloken/code/peel

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","includeNonCode":true,"respectBaseline":false,"limit":50}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.orphans --arguments-json tmp/peel-mcp-args.json
```

Interpret results in this order:

1. Swift source files not listed in the baseline.
2. Large source files with no dependents.
3. Files that also show up in duplicates or hotspots.

## Phase 7: Dependency Deep Dive

Use dependencies and dependents to validate whether a candidate is truly dead or just wired through a non-obvious path.

```bash
cd /Users/coryloken/code/peel

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","filePath":"Shared/PeelApp.swift"}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.dependencies --arguments-json tmp/peel-mcp-args.json

printf '%s' '{"repoPath":"/Users/coryloken/code/peel","filePath":"Shared/PeelApp.swift"}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.dependents --arguments-json tmp/peel-mcp-args.json
```

This phase prevents accidental deletion of files that are live through registries, app startup, or same-module extension patterns.

## Turning Results Into Work

After the sweep, make a short list with three buckets:

- Delete: true orphans, dead docs, stale artifacts.
- Consolidate: duplicate helpers, near-copy views, repeated tool wiring.
- Refactor: large hotspots or files with high method counts.

Do not try to fix all three buckets in one pass. In this repo, focused cleanup passes are lower risk than mixed refactors.

## Before And After Comparison

For cleanup work, save these three snapshots before and after the change:

1. `rag.structural` stats-only output.
2. Top `rag.duplicates` groups.
3. Filtered `rag.orphans` output.

That gives you measurable evidence that the codebase got smaller, less duplicated, or less noisy.

## Current Limitations

This workflow is strong for file-level dead-code detection, but it is not symbol-precise. It will still miss or misclassify cases involving:

- Framework discovery and reflection.
- Runtime registration.
- Same-module extension wiring not captured by the index.
- Unused members inside otherwise-live files.

The next meaningful RAG improvement after this playbook is symbol-level unused-code detection on top of the existing file graph.