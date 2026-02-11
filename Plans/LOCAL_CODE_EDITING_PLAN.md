---
title: Local Code Editing with Qwen3-Coder-Next
status: draft
created: 2026-02-10
tags: [mlx, qwen3, code-editing, local-ai, agent]
audience: [developers, stakeholders]
related_docs:
  - Plans/LOCAL_RAG_PLAN.md
  - Plans/apple-agent-big-ideas.md
  - Plans/ROADMAP.md
  - Docs/reference/RAG_EMBEDDING_MODEL_EVALUATION.md
---

# Local Code Editing with Qwen3-Coder-Next

## Summary

Add on-device code editing to Peel using Qwen3-Coder-Next (80B MoE, 3B active params)
running via MLX on Apple Silicon. This moves beyond read-only analysis to local code
generation and refactoring — no external API needed.

## Why Qwen3-Coder-Next

| Property | Value |
|----------|-------|
| Total params | 80B |
| Active params | 3B (MoE: 512 experts, 10 active) |
| Architecture | Hybrid Gated DeltaNet + Gated Attention |
| Native context | 256K tokens |
| Training | Code RL + Long-Horizon Agent RL |
| License | Apache 2.0 |
| MLX availability | `mlx-community/Qwen3-Coder-Next-4bit` (~40GB), `-8bit` (~80GB) |

Key differentiator: trained with **Agent RL** on 20K parallel environments for
multi-turn tool use, failure recovery, and long-horizon planning. This isn't a
general model doing code — it was built for agentic software engineering.

## Hardware Requirements

| Variant | RAM Needed | Quality | Our Machine (256GB) |
|---------|-----------|---------|---------------------|
| 4-bit | ~40GB | Good | ✅ Easy |
| 8-bit | ~80GB | Great | ✅ Comfortable |
| Full BF16 | ~160GB | Best | ✅ Fits with headroom |

With 256GB, we can run the **8-bit or even full-precision** model with plenty of
room for embeddings, the analyzer, and the app itself.

## Architecture

### Existing Infrastructure (Reused)

- `MLXCodeAnalyzer` — actor pattern, model loading, chat messages, streaming generation
- `MLXEmbeddingProvider` — model selection by RAM tier
- `RAGToolsHandler` — MCP tool registration and delegation pattern
- `MCPToolHandler` protocol — parameter extraction, error responses

### New Components

#### 1. `MLXCodeEditor` actor (`Shared/Services/MLXCodeEditor.swift`)

Mirrors `MLXCodeAnalyzer` but for generation-heavy tasks:

```
MLXCodeAnalyzer                    MLXCodeEditor
─────────────────                  ──────────────
maxTokens: 256                     maxTokens: 16,384
temperature: 0.1                   temperature: 0.2
Output: {"summary","tags"}         Output: unified diff / full file
Models: 0.5B–7B                    Models: 7B–80B MoE
Purpose: Read-only tagging         Purpose: Code generation & editing
```

#### 2. MCP Tools

| Tool | Description |
|------|-------------|
| `code.edit` | Edit a file given natural language instruction |
| `code.edit.status` | Check editor model status (loaded, tier, memory) |
| `code.edit.unload` | Unload editor model to free RAM |

#### 3. Integration with Agent Chains

```
Chain Runner
  → calls code.edit MCP tool
    → MLXCodeEditor generates diff
      → chain runner applies diff to worktree
        → runs tests / validates
          → commits if passing
```

This replaces the external LLM API call for simple-to-moderate edits, keeping
everything local and private.

## MCP Tool: `code.edit`

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "filePath": {
      "type": "string",
      "description": "Path to the file to edit"
    },
    "instruction": {
      "type": "string",
      "description": "Natural language instruction for the edit"
    },
    "mode": {
      "type": "string",
      "enum": ["diff", "fullFile", "snippet"],
      "description": "Output format: unified diff, complete file, or changed block only",
      "default": "diff"
    },
    "context": {
      "type": "string",
      "description": "Optional additional context (related code, requirements)"
    },
    "useRag": {
      "type": "boolean",
      "description": "Auto-fetch related code from RAG for style matching",
      "default": true
    },
    "tier": {
      "type": "string",
      "enum": ["small", "medium", "large", "auto"],
      "description": "Model tier override (default: auto based on RAM)"
    }
  },
  "required": ["filePath", "instruction"]
}
```

### Example

```json
{
  "name": "code.edit",
  "arguments": {
    "filePath": "/Users/me/code/peel/Shared/Services/AuthService.swift",
    "instruction": "Convert this class to use @MainActor @Observable instead of ObservableObject with @Published",
    "mode": "diff",
    "useRag": true
  }
}
```

### Response

```json
{
  "editedContent": "--- a/Shared/Services/AuthService.swift\n+++ b/Shared/Services/AuthService.swift\n@@ -5,8 +5,8 @@\n-class AuthService: ObservableObject {\n-  @Published var isAuthenticated = false\n+@MainActor\n+@Observable\n+class AuthService {\n+  var isAuthenticated = false\n",
  "explanation": "Replaced ObservableObject conformance with @Observable macro and added @MainActor isolation. Removed @Published wrappers.",
  "model": "Qwen3-Coder-Next",
  "durationMs": 3200,
  "tokensGenerated": 847
}
```

## RAG-Augmented Editing

The killer feature: when `useRag: true`, the handler:

1. Reads the target file
2. Searches RAG for similar patterns in the repo (vector search on the instruction)
3. Includes top-3 results as "style reference" context
4. Qwen3-Coder-Next generates edits matching the project's conventions

This means "convert to @Observable" will produce output that matches how
*your project* already uses @Observable, not generic examples.

## Model Memory Strategy

With 256GB, we can keep multiple models in memory simultaneously:

| Model | RAM | Purpose | Loaded |
|-------|-----|---------|--------|
| nomic-embed-text-v1.5 | ~500MB | RAG embeddings | Always |
| Qwen2.5-Coder-7B-4bit | ~4GB | RAG analysis | On demand |
| Qwen3-Coder-Next-8bit | ~80GB | Code editing | On demand |
| **Total** | **~85GB** | | **156GB free** |

The `MLXCodeEditor` loads lazily on first `code.edit` call and can be explicitly
unloaded via `code.edit.unload` when not needed.

## Swarm Integration

For team members on smaller machines (18GB M3), the instruction router delegates
`code.edit` calls to the Mac Studio via the swarm:

```
M3 MacBook (18GB)                Mac Studio (256GB)
  code.edit request ──────────→  MLXCodeEditor (local)
                    ←──────────  diff result
  apply diff locally
```

This is a natural extension of the existing swarm `rag.analyze` delegation pattern.

## Implementation Phases

### Phase 1: Core Editor (This PR)
- [x] `MLXCodeEditor` actor with diff/fullFile/snippet modes
- [ ] `code.edit` MCP tool registration
- [ ] `code.edit.status` and `code.edit.unload` tools
- [ ] Basic prompt engineering for unified diffs

### Phase 2: RAG Integration
- [ ] Auto-fetch related code from RAG on edit requests
- [ ] Style-matching context injection
- [ ] Instruction routing (small edits → 7B, large → Qwen3-Coder-Next)

### Phase 3: Agent Chain Integration
- [ ] Chain runner uses `code.edit` for local edits
- [ ] Fallback to external API when edit quality is insufficient
- [ ] Cost tracking: local edits = $0

### Phase 4: Swarm Delegation
- [ ] Route `code.edit` to Mac Studio for small-RAM machines
- [ ] Batch editing across worktrees
- [ ] Model hot-swap for different task sizes

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Model outputs bad diffs | Validate diff format before applying; reject malformed output |
| Context too large for model | Truncate source + use RAG snippets instead of full files |
| Memory pressure with editor + embeddings | Lazy loading + explicit unload tool |
| Qwen3-Coder-Next MLX format issues | Fall back to Qwen2.5-Coder-7B; monitor mlx-community updates |
| Edit quality below external API | Use as fast-path for simple edits; fall back to API for complex ones |

## Success Metrics

- Local edits for rename/extract/modernize patterns: **>80% diff-applies-cleanly rate**
- Latency: **<10s for single-file edits** on Qwen3-Coder-Next 8-bit
- Cost savings: **$0 per local edit** vs $0.01-0.10 per API call
- Privacy: **100% local** — no code leaves the machine
