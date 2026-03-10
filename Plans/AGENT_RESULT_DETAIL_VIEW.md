# Agent Result Detail View — Plan

**Status:** Proposed  
**Created:** 2025-03-10  
**Issue:** Improve agent chain result display — more detail in the "Needs Your Attention" list and a rich detail view when clicking into an execution.

---

## Problem

The current "Needs Your Attention" → agent chain review flow is too shallow:

1. **List-level:** The attention card only shows the chain name + "N tasks awaiting review" — no indication of *what* the agent did (code changes? review? planning?), which files were touched, or the risk level.

2. **InlineExecutionCard (expanded):** Shows agent steps, but:
   - Step output is capped at 500 chars in a flat monospaced block — no structure.
   - The "Changes" section is `diffSummary` (a `--stat` text blob, 6 lines max) — no actual diff.
   - Artifacts (screenshots, test results) exist in the data model but have **zero UI rendering**.
   - No cost/token tracking shown despite `premiumCost` being stored per step.
   - No way to see the full output of any step — only a truncated preview.

3. **No dedicated detail view:** Everything is crammed into an inline expandable card. There's no "click to see full details" experience — no equivalent of the PR detail sheet for agent work.

4. **Step output is unstructured:** Planner output, implementer diffs, reviewer verdicts, and gate decisions all render as identical monospaced text blocks. No role-specific rendering.

---

## Existing Assets to Reuse

| Asset | Location | What it offers |
|-------|----------|----------------|
| `Git.DiffView` | `Local Packages/Git/Sources/Git/DiffView.swift` | Full inline colored diff rendering (gutter bars, line numbers, hunk headers, stage/revert callbacks) |
| `Git.Commands.processDiff(lines:)` | `Local Packages/Git/Sources/Git/Commands/Diff.swift` | Parses raw `git diff` output into `Diff` struct for `DiffView` |
| `PRChangedFilesView` | `Local Packages/Github/Sources/Github/Views/PullRequests/PRChangedFilesView.swift` | Per-file collapsible rows with inline diffs, expand-all toggle |
| `ParallelWorktreeRunner.diffExecution()` | `Shared/Services/ParallelWorktreeRunner.swift:898` | Already produces full unified diff text for an execution's branch vs base |
| `AgentReviewSheet` | `Shared/Applications/AgentReviewSheet.swift` | Rich structured display: verdict banner, issues/suggestions lists, action buttons — pattern for review-type results |
| `ParsedReview` | `AgentReviewSheet.swift:964` | Structured parsing of reviewer output into summary/risk/issues/suggestions |
| `ParallelWorktreeExecution` | `Shared/Services/ParallelWorktreeRunner.swift:122` | Data model already has: `artifacts`, `chainStepResults`, `output`, `worktreePath`, diff stats, RAG snippets, operator guidance, review records |

---

## Design

### Part 1: Richer Attention Cards

Improve the "Needs Your Attention" list entries to show more context at a glance.

**Current:**
```
🛡 Chain: Deep PR Review
   1 pending review                                [Review]
```

**Proposed:**
```
🛡 Chain: Deep PR Review                           [Review]
   2 tasks • 5 files changed • +142 -20
   ██████░░░░ 1/2 reviewed • Risk: medium
```

**Changes to `RepoDetailView.needsAttentionSection`:**
- Add aggregate diff stats across all executions in the run (files/insertions/deletions)
- Show review progress (N/M reviewed)
- Show aggregate risk level if any reviewer step produced one
- Show chain type indicator (review, implementation, fix, etc.)

**Data available:** `ParallelWorktreeRun` already exposes `pendingReviewCount`, `reviewedCount`, and each execution has `filesChanged`, `insertions`, `deletions`. Risk level can be pulled from `chainStepResults` reviewer verdicts.

### Part 2: Execution Detail Sheet

Create a new `ExecutionDetailView` presented as a sheet/navigation destination when the user taps an execution card. This replaces the inline-only expansion and provides full-screen detail.

**Layout (inspired by PR detail view):**

```
┌──────────────────────────────────────────────────┐
│ ← Back          Task: "Implement form validation" │
│ Branch: feature/form-validation  • 45s  • $0.33   │
├──────────────────────────────────────────────────┤
│                                                    │
│ ┌─ Status Bar ──────────────────────────────────┐ │
│ │ ✅ Approved  │ 5 files │ +142 -20 │ Risk: low │ │
│ └───────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Agent Timeline ──────────────────────────────┐ │
│ │ ● Planner  (Sonnet, 3.2s, $0.33)             │ │
│ │   "Split into 2 tasks: form + validation"     │ │
│ │ ● Implementer (Haiku, 15s, $0.00)             │ │
│ │   5 files changed, +142 -20                   │ │
│ │ ● Reviewer (Sonnet, 8s, $0.33)                │ │
│ │   ✅ Approved — "Clean implementation"         │ │
│ │ ● Gate (—, 0.1s, $0.00)                       │ │
│ │   ✓ Passed                                    │ │
│ └───────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Changed Files (5) ──────── [Expand All] ─────┐ │
│ │ ▶ src/forms/Validator.swift    M  +80  -5      │ │
│ │ ▶ src/forms/FormView.swift     M  +42  -10     │ │
│ │ ▶ src/models/FormModel.swift   A  +15          │ │
│ │ ▶ tests/ValidatorTests.swift   A  +20          │ │
│ │ ▶ src/utils/Helpers.swift      M  +5   -5      │ │
│ │                                                 │ │
│ │ [expanded diff view using Git.DiffView]         │ │
│ └─────────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ Artifacts ───────────────────────────────────┐ │
│ │ 📸 screenshot-form.png    🧪 test-results.log │ │
│ └───────────────────────────────────────────────┘ │
│                                                    │
│ ┌─ RAG Context (3 files) ───────────────────────┐ │
│ │ src/existing/FormBase.swift (score: 0.92)      │ │
│ │ docs/validation-spec.md (score: 0.87)          │ │
│ └───────────────────────────────────────────────┘ │
│                                                    │
│        [Approve]  [Reviewed]  [Reject]             │
└──────────────────────────────────────────────────┘
```

#### 2A: Header & Status Bar

- Task title, branch name, total duration, total cost
- Status pills: approval state, file count, +/- stats, risk level
- Mirroring the PR detail view's metadata grid pattern

#### 2B: Agent Timeline

A vertical timeline replacing the flat step list. Each step rendered differently by role:

| Role | Rendering |
|------|-----------|
| **Planner** | Decision text, task count planned, expandable full plan |
| **Implementer** | Files changed summary, expandable to full output |
| **Reviewer** | Verdict banner (approve/needs changes), issues/suggestions lists (reuse `ParsedReview` parsing), risk badge |
| **Gate** | Pass/fail with colored indicator, reason text |

Each step shows: icon, name, model, duration, cost. Expandable to full output.

#### 2C: Changed Files with Inline Diff

This is the core improvement. Use the same pattern as `PRChangedFilesView`:

1. Call `ParallelWorktreeRunner.diffExecution()` to get the raw unified diff
2. Parse with `Git.Commands.processDiff(lines:)` → `Diff` struct
3. Render with `Git.DiffView(diff: diff, compact: true)`

**Implementation:**
- New `ExecutionChangedFilesView` component
- Loads diff async on appear (`.task { }`)
- Shows loading state while diff is fetched
- Per-file collapsible rows with file status icon, name, +/- stats
- Inline `Git.DiffView` when expanded (max height 400pt, scrollable)
- "Expand All / Collapse All" toggle

**Edge cases:**
- Worktree already cleaned up → diff from branch comparison (`base...branch`)
- No changes → "No code changes in this execution"
- Binary files → "Binary file — no diff available"
- Very large diffs → truncate with "showing first N files" + expand option

#### 2D: Artifacts Gallery

Render `execution.artifacts` by type:
- **Screenshots:** Thumbnail grid, tap to expand (using `AsyncImage` with `file://` URL)
- **Test results:** Monospaced scrollable text
- **Reports:** Rendered based on content (markdown or plain text)
- Hidden if empty

#### 2E: Full Step Output Viewer

Replace the 500-char `outputPreview` with a "View Full Output" button that presents a sheet with:
- Full `output` text, monospaced, selectable
- Search within output (⌘F)
- Copy button

### Part 3: Action Buttons Enhancement

The existing approve/reject/merge buttons are good. Add:
- **"View in Finder"** → opens worktree directory (if still exists)
- **"Open in Xcode"** → opens worktree as workspace
- **Cost summary** → total run cost, breakdown by step

---

## Implementation Order

### Phase 1: Execution Detail Sheet (highest impact)
1. Create `ExecutionDetailView.swift` in `Shared/Applications/`
2. Add header + status bar section
3. Add agent timeline with role-specific rendering
4. Wire up navigation from `InlineExecutionCard` → sheet presentation
5. Wire up navigation from `WorktreeRunApprovalCard` → sheet presentation

### Phase 2: Inline Diff View (core ask)
6. Create `ExecutionChangedFilesView.swift` — fetches diff via `diffExecution()`, parses with `processDiff()`, renders with `DiffView`
7. Embed in `ExecutionDetailView` under the timeline
8. Handle edge cases (no worktree, no changes, large diffs)

### Phase 3: Attention Card Enrichment
9. Update `RepoDetailView.attentionCard()` to show aggregate stats
10. Add review progress indicator
11. Add risk level badge

### Phase 4: Artifact Display & Polish
12. Add artifact gallery in `ExecutionDetailView`
13. Add full output viewer sheet
14. Add cost summary display
15. Add "Open in Finder" / "Open in Xcode" actions

---

## Data Model Changes

Minimal — the data model is already rich enough. Only additions needed:

```swift
// On ParallelWorktreeExecution — cache the parsed diff
var cachedDiff: Git.Diff?

// On ParallelWorktreeRun — computed aggregate stats
var totalFilesChanged: Int { executions.reduce(0) { $0 + $1.filesChanged } }
var totalInsertions: Int { executions.reduce(0) { $0 + $1.insertions } }
var totalDeletions: Int { executions.reduce(0) { $0 + $1.deletions } }
```

The `diffExecution()` method already exists and returns raw diff text. We just need to parse it through `Commands.processDiff(lines:)` to get a `Diff` struct for `DiffView`.

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `Shared/Applications/ExecutionDetailView.swift` | **Create** | Main detail sheet for a single execution |
| `Shared/Applications/ExecutionChangedFilesView.swift` | **Create** | Diff file list + inline DiffView (modeled on PRChangedFilesView) |
| `Shared/Applications/WorktreeApprovalViews.swift` | **Modify** | Add navigation to detail sheet from InlineExecutionCard |
| `Shared/Applications/RepoDetailView.swift` | **Modify** | Enrich attention cards with aggregate stats |
| `Shared/Services/ParallelWorktreeRunner.swift` | **Modify** | Add `cachedDiff` property, aggregate computed properties |

---

## Open Questions

1. **Should the detail view replace the inline card or supplement it?** Recommendation: supplement — keep the inline card for quick approve/reject, add a "Details" button that opens the full view.
2. **Tab-based layout in detail view?** Could use tabs (Timeline | Changes | Output | Artifacts) instead of a single scroll. PR view uses sections in a scroll — recommend matching that pattern for consistency.
3. **Should diff loading be eager or lazy?** Recommend lazy — only fetch when the user opens the detail view or expands the Changes section, since `diffExecution()` runs a git subprocess.
