---
title: Plan File Documentation Standards
tags:
  - documentation
  - ai-agent
  - standards
  - peel
updated: 2026-01-18
audience:
  - ai-agent
  - developer
question_patterns:
  - "how to write plan files"
  - "documentation format"
  - "frontmatter structure"
related_docs:
  - ../Plans/ROADMAP.md
  - ../.github/copilot-instructions.md
---

# Plan File Documentation Standards

## Overview

This document defines the standard structure for plan and roadmap files in Peel, following Intent-Driven Development principles.

## Frontmatter Requirements

Every plan file should have YAML frontmatter with these fields:

```yaml
---
title: Human-readable title
status: draft | active | complete | archived
phase: 1A | 1B | 1C | 2 | 3  # Current development phase
tags:
  - feature-area
  - technology
updated: YYYY-MM-DD
audience:
  - ai-agent
  - developer
github_issues:
  - number: 13
    status: open
    title: Add validation pipeline for MCP runs
code_locations:
  - file: Shared/AgentOrchestration/AgentManager.swift
    lines: 260-500
    description: AgentChainRunner implementation
related_docs:
  - OTHER_PLAN.md
---
```

## Status Definitions

| Status | Meaning |
|--------|---------|
| `draft` | Proposal, not yet approved |
| `active` | Approved and in progress |
| `complete` | All work done, kept for reference |
| `archived` | Moved to Archive/, no longer relevant |

## Section Structure

### For Roadmaps

```markdown
## Current State Summary
Brief status tables only - no checkbox lists for completed work.

## Active Work: Phase X
Details on current phase items with issue links.

## Phase N: Future Phase Name
Table format: Feature | Issue | Description

## Architecture
Diagrams and key components (if relevant).

## References
Links to related plans.
```

### For Feature Plans

```markdown
## Goal
One-paragraph description of what this plan achieves.

## Implementation
### Completed
Table of done items (no checkboxes).

### In Progress
Active work with issue links.

### Planned
Future work items.

## Code Locations
Where the implementation lives.

## Testing
How to verify the implementation.
```

## Rules

### ❌ NEVER
- Use checkbox lists `[x]` for completed work (noise)
- List closed GitHub issues inline (they're in frontmatter)
- Include "Timeline: X weeks" (outdated quickly)
- Duplicate content across multiple plan files

### ✅ ALWAYS
- Use YAML frontmatter with `github_issues` array
- Link to issues with `[#N](url)` format in prose
- Update `updated:` date when modifying
- Keep completed phases minimal (just status, not details)
- Use tables for structured information
