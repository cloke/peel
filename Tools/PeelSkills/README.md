# PeelSkills

CLI tools for AI agent workflows, following Intent-Driven Development principles.

## Tools

### gh-issue-sync

Compares GitHub issues against roadmap/plan files and reports discrepancies.

```bash
# Build
cd Tools/PeelSkills && swift build

# Run
.build/debug/gh-issue-sync --repo cloke/peel --plans-dir ../../Plans

# Options
--json           Output as JSON for machine consumption
--problems-only  Only show problems (skip OK items)
```

**Reports:**
- Issues marked closed but still shown as open in docs
- Roadmap items without corresponding issues  
- Issues not referenced in any plan file

### roadmap-audit

Verifies implementation status against roadmap claims.

```bash
.build/debug/roadmap-audit --plans-dir ../../Plans --source-root ../..

# Options
--json     Output as JSON
--verbose  Show all checks, not just failures
```

**Checks:**
- Code locations in frontmatter actually exist
- Line ranges are valid
- Features marked "complete" have corresponding code

### file-rewrite

Reliable file writing that avoids shell escaping issues.

```bash
# Write inline content
.build/debug/file-rewrite path/to/file.md "# Title\n\nContent here"

# From stdin
echo "content" | .build/debug/file-rewrite path/to/file.md --stdin

# From template
.build/debug/file-rewrite Plans/NEW_PLAN.md --template plan --var title="My Plan"

# Options
--template NAME    Use template (plan, roadmap)
--var KEY=VALUE    Template variable
--dry-run          Print without writing
--no-backup        Don't create .bak file
```

**Templates:**
- `plan` - Feature plan with frontmatter
- `roadmap` - Project roadmap with status tables

## Building

```bash
cd Tools/PeelSkills
swift build -c release

# Install to /usr/local/bin (optional)
cp .build/release/gh-issue-sync /usr/local/bin/
cp .build/release/roadmap-audit /usr/local/bin/
cp .build/release/file-rewrite /usr/local/bin/
```

## Ruby Alternative

The `bin/file-rewrite` Ruby script provides the same functionality:

```bash
chmod +x bin/file-rewrite
./bin/file-rewrite path/to/file.md --template plan
```

## Integration with copilot-instructions.md

Add to your `.github/copilot-instructions.md`:

```markdown
### Skills Available

| Tool | Path | Purpose |
|------|------|---------|
| gh-issue-sync | Tools/PeelSkills | Sync GitHub issues with plan files |
| roadmap-audit | Tools/PeelSkills | Verify roadmap claims against code |
| file-rewrite | Tools/PeelSkills | Write files reliably (no shell escaping) |

### When to Use Skills

- **Before editing plans:** Run `gh-issue-sync` to see current state
- **After marking complete:** Run `roadmap-audit` to verify
- **When writing files fails:** Use `file-rewrite --stdin` instead of heredocs
```

## Frontmatter Format

These tools expect YAML frontmatter in plan files:

```yaml
---
title: Feature Plan
status: active
tags:
  - feature-area
updated: 2026-01-18
github_issues:
  - number: 13
    status: open
    title: Issue title
code_locations:
  - file: path/to/file.swift
    lines: 100-200
    description: What this code does
---
```

See [PLAN_FILE_STANDARDS.md](../../Docs/reference/PLAN_FILE_STANDARDS.md) for full specification.
