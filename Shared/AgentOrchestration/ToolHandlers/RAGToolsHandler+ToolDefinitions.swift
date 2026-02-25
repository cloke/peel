//
//  RAGToolsHandler+ToolDefinitions.swift
//  Peel
//
//  Tool definitions for RAGToolsHandler.
//  See also MCPServerService+ToolDefinitions.swift for aggregation.
//  Managed separately per #300 and #301.
//

import Foundation
import MCPCore

// MARK: - Tool Definitions

extension RAGToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "rag.status",
        description: "Get Local RAG database status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.config",
        description: "Get or set RAG configuration (embedding provider, memory limits). Use action='get' to see current config, action='set' with provider='mlx' (MLX native, best for Apple Silicon), 'system' (Apple NLEmbedding), 'coreml' (CoreML), or 'hash' (fallback). Set mlxMemoryLimitGB to control max process memory before pausing indexing.",
        inputSchema: [
          "type": "object",
          "properties": [
            "action": ["type": "string", "enum": ["get", "set"], "default": "get"],
            "provider": ["type": "string", "enum": ["mlx", "coreml", "system", "hash", "auto"]],
            "reinitialize": ["type": "boolean", "default": true],
            "mlxCacheLimitMB": ["type": "integer"],
            "mlxClearCacheAfterBatch": ["type": "boolean"],
            "mlxMemoryLimitGB": ["type": "number", "description": "Max process memory (GB) before pausing indexing. Default: 80% of RAM."],
            "clearMlxCacheLimit": ["type": "boolean"]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.init",
        description: "Initialize the Local RAG database schema",
        inputSchema: [
          "type": "object",
          "properties": [
            "extensionPath": ["type": "string"]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.index",
        description: """
        Index a repository path into the Local RAG database. Use forceReindex=true to re-index all files regardless of whether they've changed.
        
        Workspace/monorepo support: If the path contains multiple git sub-repos or sub-packages \
        (directories with Package.swift, package.json, Cargo.toml, etc.), each sub-package is \
        automatically indexed as a separate repo entry with parent/child relationships tracked. \
        Use allowWorkspace=true to instead index everything as a single flat repo.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"],
            "forceReindex": ["type": "boolean", "default": false, "description": "If true, re-index all files even if unchanged. Useful after changing chunking or embedding settings."],
            "allowWorkspace": ["type": "boolean", "default": false, "description": "If true, index workspace as a single flat repo instead of auto-indexing sub-packages separately."],
            "excludeSubrepos": ["type": "boolean", "default": true, "description": "When indexing a workspace with allowWorkspace=true, skip sub-repo folders (index only workspace-level content)." ]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.branch.index",
        description: """
        Index a repository branch or worktree incrementally. Uses copy-on-branch strategy:
        1) If no existing index for this path, copies file/chunk/embedding records from the base
           repo's index (fast — avoids re-embedding unchanged files).
        2) Uses git diff to find changed files since the base branch.
        3) Force-reindexes only the changed/added files.
        4) Deleted files are naturally removed by the incremental scan.

        Use this instead of rag.index when working in a git worktree or on a feature branch
        to get fast, branch-accurate search results.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Path to the worktree or branch checkout to index"],
            "baseBranch": ["type": "string", "default": "main", "description": "The base branch to diff against for finding changed files. Default: main"],
            "baseRepoPath": ["type": "string", "description": "Optional: explicit path to the main repo. If omitted, auto-detected via git worktree list."]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.branch.cleanup",
        description: "Remove stale RAG index entries for repository paths that no longer exist on disk. Use after deleting worktrees or old branch checkouts to reclaim database space.",
        inputSchema: [
          "type": "object",
          "properties": [
            "dryRun": ["type": "boolean", "default": false, "description": "If true, report what would be removed without deleting. Default: false"]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.analyze",
        description: """
        Analyze indexed chunks using local MLX LLM to generate semantic summaries and tags.
        This runs the Qwen2.5-Coder model (hardware-adaptive size selection) on un-analyzed chunks.
        Analysis improves RAG search quality by adding semantic context. macOS only.
        
        The model tier is automatically selected based on available RAM:
        - tiny (8-12GB): Qwen2.5-Coder-0.5B
        - small (12-24GB): Qwen2.5-Coder-1.5B (default for M3 18GB)
        - medium (24-48GB): Qwen2.5-Coder-3B
        - large (48GB+): Qwen2.5-Coder-7B (best for Mac Studio)
        
        After analyzing, run rag.enrich to re-embed chunks with AI summaries for better vector search.
        Results sync via swarm, so Mac Studio can generate high-quality analysis for the team.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "limit": ["type": "integer", "description": "Max chunks to analyze (default 100)", "default": 100]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.analyze.status",
        description: "Get AI analysis status - counts of analyzed vs un-analyzed chunks (macOS only)",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.enrich",
        description: """
        Re-embed analyzed chunks using enriched text (code + AI summary) for better vector search.
        
        After running rag.analyze, chunks have AI-generated summaries but the embeddings still only
        encode the raw code. This tool re-embeds those chunks using "code + AI summary" as input,
        so vector search captures both code structure AND semantic meaning.
        
        Workflow: rag.index → rag.analyze → rag.enrich → dramatically better rag.search vector results
        
        macOS only. Safe to run incrementally — only processes chunks not yet enriched.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "limit": ["type": "integer", "description": "Max chunks to enrich (default 500)", "default": 500]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.enrich.status",
        description: "Get embedding enrichment status — how many analyzed chunks have enriched embeddings (macOS only)",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.duplicates",
        description: """
        Find duplicate/redundant code across a codebase. Returns a ranked report of all constructs
        (functions, classes, types) that appear in multiple files — the #1 tool for code dedup,
        reducing code size, finding copy-paste, and identifying consolidation opportunities.
        
        One call returns a complete ranked list sorted by wasted tokens (code that could be
        eliminated). Each group includes file paths, token counts, and AI-generated summaries
        confirming the duplicates are semantically identical.
        
        USE THIS TOOL when asked to: reduce code size, find duplicates, find redundant code,
        find copy-paste, optimize codebase, consolidate shared code, DRY violations, or
        find refactoring opportunities.
        
        Requires rag.analyze to have been run first. Examples of what it finds:
        - Utility functions copy-pasted across files (eq, gt, formatDate, etc.)
        - Service classes duplicated across apps (ApplicationAdapter, SessionContextService)
        - Component variants that could be unified with a config flag
        
        macOS only. Prefer this over rag.similar for bulk duplicate analysis.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "minFiles": ["type": "integer", "description": "Minimum number of distinct files a construct must appear in (default 2)", "default": 2],
            "constructTypes": [
              "type": "array",
              "items": ["type": "string"],
              "description": "Filter to specific construct types (e.g. ['function', 'classDecl']). Default: all except imports and file-level chunks"
            ],
            "sortBy": ["type": "string", "enum": ["wastedTokens", "fileCount", "totalTokens"], "description": "Sort order (default: wastedTokens)", "default": "wastedTokens"],
            "limit": ["type": "integer", "description": "Max groups to return (default 25)", "default": 25]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.patterns",
        description: """
        Analyze naming conventions and pattern consistency across a codebase. Returns a breakdown
        of how constructs are named — grouped by suffix (Route, Component, Service, Adapter, etc.)
        — plus a list of "other" classes that don't follow any convention.
        
        USE THIS TOOL when asked to: enforce naming conventions, find inconsistent names, audit
        code patterns, check code style, review codebase architecture, identify non-standard
        classes, or improve code consistency.
        
        Returns: convention rate (% following a pattern), count per suffix, total tokens per
        pattern, and 5 sample constructs for each group. The '(other)' group shows classes
        that lack a standard suffix — these are candidates for renaming.
        
        Requires rag.analyze to have been run first. macOS only.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "constructType": ["type": "string", "description": "Filter to a specific construct type (e.g. 'classDecl'). Default: all types."],
            "limit": ["type": "integer", "description": "Max pattern groups to return (default 30)", "default": 30]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.hotspots",
        description: """
        Find complexity hotspots — "god components" and oversized constructs that are prime
        refactoring targets. Returns constructs sorted by token count (largest first), with
        AI summaries and tags to help understand what each one does.
        
        USE THIS TOOL when asked to: find refactoring targets, identify god components, find
        large/complex code, reduce component size, improve maintainability, find code that
        needs splitting, or assess code complexity.
        
        Default threshold is 5000 tokens (~2500 lines). Adjustable via minTokens parameter.
        Results include: construct name, type, file path, token count, line range, AI summary.
        
        Requires rag.analyze to have been run first. macOS only.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Filter to specific repo (optional)"],
            "constructType": ["type": "string", "description": "Filter to a specific construct type (e.g. 'classDecl'). Default: all types."],
            "minTokens": ["type": "integer", "description": "Minimum token count threshold (default 5000)", "default": 5000],
            "limit": ["type": "integer", "description": "Max hotspots to return (default 30)", "default": 30]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.search",
        description: """
        Search indexed code content. Returns matching chunks with metadata.
        
        Modes:
        - "text" (default): Keyword search across chunk text, construct names, and AI summaries
        - "vector": Semantic similarity search using embeddings (enriched with AI summaries when available)
        
        Detail levels (IMPORTANT for context window management):
        - "full" (default): Returns code snippet + AI summary + tags + all metadata
        - "summary": Returns AI summary + tags + metadata WITHOUT code snippet (20-80x smaller). Use this for broad exploration — get an overview of what exists, then fetch specific files with full detail.
        - "minimal": Returns only path + construct name/type + token count. Smallest possible response for listing/counting.
        
        Strategy: Start with detail:"summary" for broad queries, then use detail:"full" on specific results you need code for.
        
        Filters:
        - excludeTests: Skip test/spec files
        - constructType: Filter by type (e.g., "component", "function", "classDecl")
        - modulePath: Filter by module path (e.g., "Shared/Services")
        - featureTag: Filter by feature tag (e.g., "rag", "mcp", "agent")
        - matchAll: For text mode - true=AND all words, false=OR any word (default true)
        
        Reranking:
        - rerank: Enable HuggingFace cross-encoder reranking for better relevance. Must configure with rag.reranker.config first.
        
        Results include: filePath, startLine, endLine, constructType, name, tokenCount, isTest, lineCount + (depending on detail level) snippet, aiSummary, aiTags, language, score, modulePath, featureTags
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "query": ["type": "string", "description": "Search query"],
            "repoPath": ["type": "string", "description": "Filter to specific repo"],
            "limit": ["type": "integer", "description": "Max results (default 10)"],
            "mode": ["type": "string", "enum": ["text", "vector"], "description": "Search mode: text (keyword) or vector (semantic)"],
            "detail": ["type": "string", "enum": ["full", "summary", "minimal"], "description": "Response detail level. 'summary' returns AI summaries instead of code (20-80x smaller context). 'minimal' returns only paths and construct names. Default: 'full'"],
            "excludeTests": ["type": "boolean", "description": "Exclude test/spec files"],
            "constructType": ["type": "string", "description": "Filter by construct type"],
            "modulePath": ["type": "string", "description": "Filter by module path (e.g., 'Shared/Services')"],
            "featureTag": ["type": "string", "description": "Filter by feature tag (e.g., 'rag', 'mcp')"],
            "matchAll": ["type": "boolean", "description": "Text mode: true=AND all words, false=OR any word"],
            "rerank": ["type": "boolean", "description": "Apply HF cross-encoder reranking for improved relevance (requires rag.reranker.config setup)"]
          ],
          "required": ["query"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.queryHints",
        description: "Return recent successful RAG queries with result counts.",
        inputSchema: [
          "type": "object",
          "properties": [
            "limit": ["type": "integer", "description": "Max hints to return (default 10)"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.cache.clear",
        description: "Clear cached embeddings (cache_embeddings table)",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.model.describe",
        description: "Describe the current embedding model (MLX, CoreML, System, or Hash)",
        inputSchema: [
          "type": "object",
          "properties": [
            "modelName": ["type": "string"],
            "extension": ["type": "string"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.model.list",
        description: "List available MLX embedding models and current preference",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.model.set",
        description: "Set preferred MLX embedding model by modelId (HuggingFace id or name). Use empty to reset to auto.",
        inputSchema: [
          "type": "object",
          "properties": [
            "modelId": ["type": "string"],
            "reinitialize": ["type": "boolean", "default": true]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.embedding.test",
        description: "Test embedding generation with sample texts. Returns embeddings and timing info.",
        inputSchema: [
          "type": "object",
          "properties": [
            "texts": ["type": "array", "items": ["type": "string"], "description": "Array of texts to embed (max 5)"],
            "showVectors": ["type": "boolean", "default": false, "description": "Include first 10 values of each vector"]
          ],
          "required": ["texts"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.ui.status",
        description: "Get Local RAG dashboard status snapshot",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.skills.list",
        description: "List repo guidance skills",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"],
            "repoRemoteURL": ["type": "string"],
            "includeInactive": ["type": "boolean"],
            "limit": ["type": "integer"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.skills.add",
        description: "Add a repo guidance skill",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"],
            "repoRemoteURL": ["type": "string"],
            "repoName": ["type": "string"],
            "title": ["type": "string"],
            "body": ["type": "string"],
            "source": ["type": "string"],
            "tags": ["type": "string"],
            "priority": ["type": "integer"],
            "isActive": ["type": "boolean"]
          ],
          "required": ["title", "body"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.skills.update",
        description: "Update a repo guidance skill",
        inputSchema: [
          "type": "object",
          "properties": [
            "skillId": ["type": "string"],
            "repoPath": ["type": "string"],
            "repoRemoteURL": ["type": "string"],
            "repoName": ["type": "string"],
            "title": ["type": "string"],
            "body": ["type": "string"],
            "source": ["type": "string"],
            "tags": ["type": "string"],
            "priority": ["type": "integer"],
            "isActive": ["type": "boolean"]
          ],
          "required": ["skillId"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.skills.delete",
        description: "Delete a repo guidance skill",
        inputSchema: [
          "type": "object",
          "properties": [
            "skillId": ["type": "string"]
          ],
          "required": ["skillId"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.skills.ember.detect",
        description: "Detect if a repository is an Ember project and check if Ember best-practice skills are loaded. Returns isEmberProject, alreadySeeded, emberSkillCount, and bundledVersion.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.skills.ember.update",
        description: "Manage bundled Ember best-practice skills. Actions: 'check' (check for updates), 'seed' (add skills), 'update' (force update), 'remove' (delete Ember skills).",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"],
            "action": ["type": "string", "enum": ["check", "seed", "update", "remove"], "description": "Action to perform: check, seed, update, or remove"]
          ],
          "required": ["repoPath", "action"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.skills.init",
        description: "Bootstrap .peel/directives.md and .peel/skills.json in a repository from bundled defaults. Idempotent by default — skips files that already exist unless force is true.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository to initialize"],
            "force": ["type": "boolean", "description": "Overwrite existing files (default: false)"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.lessons.list",
        description: "List lessons learned from agent fixes. Lessons capture recurring error patterns and their fixes to help prevent future mistakes.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"],
            "includeInactive": ["type": "boolean", "description": "Include deactivated lessons (default: false)"],
            "limit": ["type": "integer", "description": "Max lessons to return"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.lessons.add",
        description: "Record a lesson learned from fixing an error. Used to capture patterns of mistakes and their fixes for future reference.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"],
            "filePattern": ["type": "string", "description": "Glob pattern for files this applies to (e.g., '*.gts', 'app/models/*.rb')"],
            "errorSignature": ["type": "string", "description": "Normalized error pattern for matching (e.g., 'undefined method X')"],
            "fixDescription": ["type": "string", "description": "Human-readable description of the fix"],
            "fixCode": ["type": "string", "description": "Actual code snippet that fixed the issue"],
            "source": ["type": "string", "description": "Source: 'manual', 'auto', or 'imported' (default: 'manual')"]
          ],
          "required": ["repoPath", "fixDescription"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.lessons.query",
        description: "Query lessons relevant to a specific file or error. Returns lessons that match the file pattern and/or error signature, sorted by confidence.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository"],
            "filePattern": ["type": "string", "description": "File path to match against lesson patterns"],
            "errorSignature": ["type": "string", "description": "Error text to match against lesson signatures"],
            "limit": ["type": "integer", "description": "Max lessons to return (default: 20)"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.lessons.update",
        description: "Update a lesson's description, code, confidence, or active status.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lessonId": ["type": "string", "description": "The lesson ID to update"],
            "fixDescription": ["type": "string", "description": "Updated fix description"],
            "fixCode": ["type": "string", "description": "Updated fix code"],
            "confidence": ["type": "number", "description": "New confidence score (0.0-1.0)"],
            "isActive": ["type": "boolean", "description": "Whether the lesson is active"]
          ],
          "required": ["lessonId"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.lessons.delete",
        description: "Delete a lesson permanently.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lessonId": ["type": "string", "description": "The lesson ID to delete"]
          ],
          "required": ["lessonId"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.lessons.applied",
        description: "Record that a lesson was applied to provide feedback. Updates confidence based on success/failure.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lessonId": ["type": "string", "description": "The lesson ID that was applied"],
            "success": ["type": "boolean", "description": "Whether applying the lesson was successful"]
          ],
          "required": ["lessonId", "success"]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.repos.list",
        description: "List all indexed repositories with stats",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.repos.delete",
        description: "Delete an indexed repository and all its data (files, chunks, embeddings)",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoId": ["type": "string", "description": "The repo ID (hash) to delete"],
            "repoPath": ["type": "string", "description": "The repo path to delete (alternative to repoId)"]
          ]
        ],
        category: .rag,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "rag.stats",
        description: "Get index statistics: file count, chunk count, embedding count, total lines for a specific repository.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.largeFiles",
        description: "Find the largest files in a repository by line count. Useful for finding refactor candidates.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"],
            "limit": ["type": "integer", "description": "Max files to return (default 20)"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.constructTypes",
        description: "Get distribution of construct types (class, function, component, etc.) in a repository.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.facets",
        description: "Get facet counts for filtering/grouping search results. Returns counts for module paths, feature tags, languages, and construct types.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Optional repo path to filter"]
          ]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.dependencies",
        description: "Get what a file depends on (imports, requires, inheritance, protocol conformance). Returns the list of modules/files that the specified file imports or depends on.",
        inputSchema: [
          "type": "object",
          "properties": [
            "filePath": ["type": "string", "description": "Relative path of the file within the repo (e.g., 'Shared/Services/LocalRAGStore.swift')"],
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"]
          ],
          "required": ["filePath", "repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.dependents",
        description: "Get what depends on a file (reverse dependencies). Returns the list of files that import or depend on the specified file.",
        inputSchema: [
          "type": "object",
          "properties": [
            "filePath": ["type": "string", "description": "Relative path of the file within the repo (e.g., 'Shared/Services/LocalRAGStore.swift')"],
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"]
          ],
          "required": ["filePath", "repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.orphans",
        description: "Find potentially orphaned/unused files in a repository. An orphan is a file that has no imports/requires pointing to it AND no type references from other files. Useful for finding dead code. Note: May still show entry points, dynamically loaded files, or reflection-based usage.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"],
            "excludeTests": ["type": "boolean", "description": "Exclude test files from results (default: true)"],
            "excludeEntryPoints": ["type": "boolean", "description": "Exclude common entry point files like App.swift, main.swift, index.ts (default: true)"],
            "limit": ["type": "integer", "description": "Maximum results to return (default: 50)"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.structural",
        description: "Query files by structural characteristics: line count, method count, byte size. Use for finding large/complex files or filtering by size. Set statsOnly=true for aggregate statistics.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string", "description": "Absolute path to the repository root"],
            "minLines": ["type": "integer", "description": "Minimum line count filter"],
            "maxLines": ["type": "integer", "description": "Maximum line count filter"],
            "minMethods": ["type": "integer", "description": "Minimum method/function count filter"],
            "maxMethods": ["type": "integer", "description": "Maximum method/function count filter"],
            "minBytes": ["type": "integer", "description": "Minimum file size in bytes"],
            "maxBytes": ["type": "integer", "description": "Maximum file size in bytes"],
            "language": ["type": "string", "description": "Filter by language (e.g., 'swift', 'ruby', 'typescript')"],
            "sortBy": ["type": "string", "description": "Sort results by: 'lines', 'methods', 'bytes' (default: 'lines')"],
            "limit": ["type": "integer", "description": "Maximum results to return (default: 50)"],
            "statsOnly": ["type": "boolean", "description": "Return only aggregate statistics (no file list)"]
          ],
          "required": ["repoPath"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.similar",
        description: "Find code chunks semantically similar to a given snippet or query. Uses embedding-based similarity search to find related code patterns, implementations, or concepts. Note: for finding duplicate/redundant code across a codebase, use rag.duplicates instead — it returns a ranked report of all same-name constructs across files in one call.",
        inputSchema: [
          "type": "object",
          "properties": [
            "query": ["type": "string", "description": "Code snippet or text to find similar code for"],
            "repoPath": ["type": "string", "description": "Absolute path to repository (optional - searches all indexed repos if omitted)"],
            "threshold": ["type": "number", "description": "Minimum similarity score 0.0-1.0 (default: 0.6)"],
            "limit": ["type": "integer", "description": "Maximum results to return (default: 10)"],
            "excludePath": ["type": "string", "description": "File path to exclude from results (useful when finding similar code to an existing file)"]
          ],
          "required": ["query"]
        ],
        category: .rag,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "rag.reranker.config",
        description: "Configure HuggingFace reranker for improved search relevance. Cross-encoder reranking can significantly improve search quality by rescoring results with a dedicated relevance model. Requires HF API token for best results.",
        inputSchema: [
          "type": "object",
          "properties": [
            "action": ["type": "string", "description": "Action to perform: 'get' (view config), 'set' (update config), 'test' (info only). Default: 'get'"],
            "enabled": ["type": "boolean", "description": "Enable/disable HF reranking (for 'set' action)"],
            "modelId": ["type": "string", "description": "HuggingFace model ID for reranking (e.g., 'BAAI/bge-reranker-base')"],
            "apiToken": ["type": "string", "description": "HuggingFace API token (optional but recommended for reliability)"]
          ],
          "required": []
        ],
        category: .rag,
        isMutating: false
      ),
    ]
  }
}

