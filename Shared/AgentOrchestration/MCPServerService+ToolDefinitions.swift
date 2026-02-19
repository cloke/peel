import Foundation
import MCPCore

// MARK: - Tool Definitions
// Extracted from MCPServerService.swift for maintainability

extension MCPServerService {
  var allowForegroundTools: Bool {
    config.bool(forKey: StorageKey.allowForegroundTools, default: true)
  }

  func toolDefinition(named name: String) -> ToolDefinition? {
    allToolDefinitions.first { $0.name == name }
  }

  var activeToolDefinitions: [ToolDefinition] {
    guard allowForegroundTools else {
      return allToolDefinitions.filter { !$0.requiresForeground }
    }
    return allToolDefinitions
  }

  var allToolDefinitions: [ToolDefinition] {
    [
      ToolDefinition(
        name: "ui.tap",
        description: "Tap a control by controlId",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"]
          ],
          "required": ["controlId"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.setText",
        description: "Set text for a control",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"],
            "value": ["type": "string"]
          ],
          "required": ["controlId", "value"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.toggle",
        description: "Toggle a control",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"],
            "on": ["type": "boolean"]
          ],
          "required": ["controlId"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.select",
        description: "Select a value for a control",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"],
            "value": ["type": "string"]
          ],
          "required": ["controlId", "value"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.navigate",
        description: "Navigate to a top-level view by viewId",
        inputSchema: [
          "type": "object",
          "properties": [
            "viewId": ["type": "string"]
          ],
          "required": ["viewId"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.back",
        description: "Navigate back to the previous view (if supported)",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "ui.snapshot",
        description: "Return the current view and visible control IDs",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .ui,
        isMutating: false,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "state.get",
        description: "Get current app state summary",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "state.readonly",
        description: "Background-safe, read-only state snapshot",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "state.list",
        description: "List available view IDs and tools",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "repos.list",
        description: "List git repositories tracked in Peel on this device",
        inputSchema: [
          "type": "object",
          "properties": [
            "includeInvalid": ["type": "boolean", "default": true]
          ]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "repos.resolve",
        description: "Resolve repositories by name (exact, contains, or pathSuffix match)",
        inputSchema: [
          "type": "object",
          "properties": [
            "name": ["type": "string"],
            "match": ["type": "string", "enum": ["exact", "contains", "pathSuffix"], "default": "exact"],
            "includeInvalid": ["type": "boolean", "default": true]
          ],
          "required": ["name"]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "repos.delete",
        description: "Delete a repository from Peel's SwiftData store by repoId or localPath",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoId": ["type": "string", "description": "Repository UUID to delete"],
            "localPath": ["type": "string", "description": "Local path of repository to delete"]
          ]
        ],
        category: .state,
        isMutating: true
      ),
      ToolDefinition(
        name: "rag.status",
        description: "Get Local RAG database status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
        name: "rag.cache.clear",
        description: "Clear cached embeddings (cache_embeddings table)",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: true
      ),
      ToolDefinition(
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
      ToolDefinition(
        name: "rag.model.list",
        description: "List available MLX embedding models and current preference",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
        name: "rag.ui.status",
        description: "Get Local RAG dashboard status snapshot",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      // MARK: Ember Skills (#263) - Bundled Ember best practices
      ToolDefinition(
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
      ToolDefinition(
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
      // MARK: Learning Loop (#210) - Lesson Tools
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
        name: "rag.repos.list",
        description: "List all indexed repositories with stats",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .rag,
        isMutating: false
      ),
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      ToolDefinition(
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
      // MARK: Local Code Editing (Qwen3-Coder-Next)
      ToolDefinition(
        name: "code.edit",
        description: """
        Edit a file using a local MLX LLM (Qwen3-Coder-Next on 96GB+ machines, Qwen2.5-Coder-7B on smaller).
        Reads the file, applies the natural-language instruction, and returns a unified diff, the full edited file, or a changed snippet.
        When useRag=true (default), related code from the RAG index is included as style context.
        macOS only. Requires at least 24GB RAM.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "filePath": ["type": "string", "description": "Absolute path to the file to edit"],
            "instruction": ["type": "string", "description": "Natural language instruction for the edit (e.g., 'convert to @Observable', 'extract validation into a protocol')"],
            "mode": ["type": "string", "enum": ["diff", "fullFile", "snippet"], "description": "Output format (default: diff)"],
            "context": ["type": "string", "description": "Optional additional context (related code, requirements)"],
            "useRag": ["type": "boolean", "description": "Auto-fetch related code from RAG for style matching (default: true)"],
            "tier": ["type": "string", "enum": ["small", "medium", "large", "auto"], "description": "Model tier override (default: auto based on RAM)"]
          ],
          "required": ["filePath", "instruction"]
        ],
        category: .codeEdit,
        isMutating: false  // Returns edit content but does not write to disk
      ),
      ToolDefinition(
        name: "code.edit.status",
        description: "Check local code editor model status: loaded model, tier, memory requirements, feasibility on this machine. macOS only.",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .codeEdit,
        isMutating: false
      ),
      ToolDefinition(
        name: "code.edit.unload",
        description: "Unload the local code editor model to free RAM. The model will be reloaded on next code.edit call. macOS only.",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .codeEdit,
        isMutating: true
      ),
      ToolDefinition(
        name: "github.issue.get",
        description: """
        Fetch a single GitHub issue by owner, repository, and issue number.
        Returns issue title, body, state, labels, comments count, and timestamps.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Issue number"]
          ],
          "required": ["owner", "repo", "number"]
        ],
        category: .github,
        isMutating: false
      ),
      ToolDefinition(
        name: "github.issues.list",
        description: """
        List issues for a repository.
        Returns an array of issue summaries with title, state, labels, and metadata.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "state": ["type": "string", "enum": ["open", "closed", "all"], "description": "Issue state filter (default: open)"]
          ],
          "required": ["owner", "repo"]
        ],
        category: .github,
        isMutating: false
      ),
      ToolDefinition(
        name: "templates.list",
        description: "List available chain templates",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .chains,
        isMutating: false
      ),
      ToolDefinition(
        name: "chains.run",
        description: "Run a chain template with a prompt",
        inputSchema: [
          "type": "object",
          "properties": [
            "templateId": ["type": "string"],
            "templateName": ["type": "string"],
            "chainSpec": [
              "type": "object",
              "properties": [
                "name": ["type": "string"],
                "description": ["type": "string"],
                "steps": [
                  "type": "array",
                  "items": [
                    "type": "object",
                    "properties": [
                      "role": ["type": "string"],
                      "model": ["type": "string"],
                      "name": ["type": "string"],
                      "frameworkHint": ["type": "string"],
                      "customInstructions": ["type": "string"]
                    ],
                    "required": ["role", "model"]
                  ]
                ]
              ],
              "required": ["steps"]
            ],
            "prompt": ["type": "string"],
            "workingDirectory": ["type": "string"],
            "enableReviewLoop": ["type": "boolean"],
            "pauseOnReview": ["type": "boolean"],
            "enablePrePlanner": ["type": "boolean", "description": "Enable RAG-grounded pre-planner step before main planner runs"],
            "allowPlannerModelSelection": ["type": "boolean"],
            "allowImplementerModelOverride": ["type": "boolean"],
            "allowPlannerImplementerScaling": ["type": "boolean"],
            "maxImplementers": ["type": "integer"],
            "maxPremiumCost": ["type": "number"],
            "priority": ["type": "integer"],
            "timeoutSeconds": ["type": "number"],
            "returnImmediately": ["type": "boolean"],
            "keepWorkspace": ["type": "boolean"],
            "requireRagUsage": ["type": "boolean"]
          ],
          "required": ["prompt"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.run.status",
        description: "Get status for a running or queued chain by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: false
      ),
      ToolDefinition(
        name: "chains.run.list",
        description: "List recent chain runs and optional logs",
        inputSchema: [
          "type": "object",
          "properties": [
            "limit": ["type": "integer"],
            "chainId": ["type": "string"],
            "runId": ["type": "string"],
            "includeResults": ["type": "boolean"],
            "includeOutputs": ["type": "boolean"]
          ]
        ],
        category: .chains,
        isMutating: false
      ),
      ToolDefinition(
        name: "workspaces.agent.list",
        description: "List agent workspaces and their status",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": ["type": "string"]
          ]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "workspaces.agent.cleanup.status",
        description: "Get agent worktree cleanup status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      ToolDefinition(
        name: "chains.runBatch",
        description: "Run multiple chains (optionally in parallel)",
        inputSchema: [
          "type": "object",
          "properties": [
            "runs": [
              "type": "array",
              "items": [
                "type": "object",
                "properties": [
                  "templateId": ["type": "string"],
                  "templateName": ["type": "string"],
                  "prompt": ["type": "string"],
                  "workingDirectory": ["type": "string"],
                  "enableReviewLoop": ["type": "boolean"],
                  "pauseOnReview": ["type": "boolean"],
                  "enablePrePlanner": ["type": "boolean"],
                  "allowPlannerModelSelection": ["type": "boolean"],
                  "allowImplementerModelOverride": ["type": "boolean"],
                  "allowPlannerImplementerScaling": ["type": "boolean"],
                  "maxImplementers": ["type": "integer"],
                  "maxPremiumCost": ["type": "number"],
                  "priority": ["type": "integer"],
                  "timeoutSeconds": ["type": "number"]
                ],
                "required": ["prompt"]
              ]
            ],
            "parallel": ["type": "boolean"]
          ],
          "required": ["runs"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.stop",
        description: "Cancel a running chain by runId (or all running chains)",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "all": ["type": "boolean"]
          ]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.pause",
        description: "Pause a running chain by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.resume",
        description: "Resume a paused chain by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.instruct",
        description: "Inject operator guidance into a running chain",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "guidance": ["type": "string"]
          ],
          "required": ["runId", "guidance"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.step",
        description: "Step a paused chain to the next agent by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.queue.status",
        description: "Get chain queue status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .chains,
        isMutating: false
      ),
      ToolDefinition(
        name: "chains.queue.configure",
        description: "Configure chain queue limits",
        inputSchema: [
          "type": "object",
          "properties": [
            "maxConcurrent": ["type": "integer"],
            "maxQueued": ["type": "integer"]
          ]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.queue.cancel",
        description: "Cancel a queued chain by runId",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "chains.promptRules.get",
        description: "Get current prompt rules and guardrails configuration",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .chains,
        isMutating: false
      ),
      ToolDefinition(
        name: "chains.promptRules.set",
        description: "Update prompt rules and guardrails. Partial updates supported.",
        inputSchema: [
          "type": "object",
          "properties": [
            "globalPrefix": ["type": "string", "description": "Text prepended to all prompts"],
            "enforcePlannerModel": ["type": "string", "description": "Model name to enforce for planner"],
            "maxPremiumCostDefault": ["type": "number", "description": "Default max premium cost"],
            "requireRagByDefault": ["type": "boolean", "description": "Require RAG usage by default"],
            "perTemplateOverrides": ["type": "object", "description": "Per-template overrides keyed by template name"]
          ]
        ],
        category: .chains,
        isMutating: true
      ),
      ToolDefinition(
        name: "logs.mcp.path",
        description: "Get MCP log file path",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .logs,
        isMutating: false
      ),
      ToolDefinition(
        name: "logs.mcp.tail",
        description: "Get last N lines of MCP log",
        inputSchema: [
          "type": "object",
          "properties": [
            "lines": ["type": "integer"]
          ]
        ],
        category: .logs,
        isMutating: false
      ),
      ToolDefinition(
        name: "vm.macos.status",
        description: "Get macOS VM readiness and status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: false
      ),
      ToolDefinition(
        name: "vm.macos.restore.download",
        description: "Download the macOS restore image",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      ToolDefinition(
        name: "vm.macos.install",
        description: "Install macOS into the VM disk",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      ToolDefinition(
        name: "vm.macos.start",
        description: "Start the macOS VM",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      ToolDefinition(
        name: "vm.macos.stop",
        description: "Stop the macOS VM",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .vm,
        isMutating: true
      ),
      ToolDefinition(
        name: "vm.macos.reset",
        description: "Delete the macOS VM bundle and reset install state",
        inputSchema: [
          "type": "object",
          "properties": [
            "deleteRestoreImage": ["type": "boolean"]
          ]
        ],
        category: .vm,
        isMutating: true
      ),
      ToolDefinition(
        name: "server.stop",
        description: "Stop the MCP server",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: true
      ),
      ToolDefinition(
        name: "server.restart",
        description: "Restart the MCP server",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: true
      ),
      ToolDefinition(
        name: "server.port.set",
        description: "Set MCP server port and restart",
        inputSchema: [
          "type": "object",
          "properties": [
            "port": ["type": "integer"],
            "autoFind": ["type": "boolean"],
            "maxAttempts": ["type": "integer"]
          ],
          "required": ["port"]
        ],
        category: .server,
        isMutating: true
      ),
      ToolDefinition(
        name: "server.status",
        description: "Get MCP server status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: false
      ),
      ToolDefinition(
        name: "server.sleep.prevent",
        description: "Enable or disable system sleep prevention",
        inputSchema: [
          "type": "object",
          "properties": [
            "enabled": ["type": "boolean"]
          ],
          "required": ["enabled"]
        ],
        category: .server,
        isMutating: true
      ),
      ToolDefinition(
        name: "server.sleep.prevent.status",
        description: "Get sleep prevention status",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .server,
        isMutating: false
      ),
      ToolDefinition(
        name: "server.lan",
        description: "Enable or disable LAN mode (accept MCP connections from network, not just localhost). WARNING: Only use on trusted networks - no authentication.",
        inputSchema: [
          "type": "object",
          "properties": [
            "enabled": ["type": "boolean", "description": "true to enable LAN mode, false to restrict to localhost only"]
          ],
          "required": ["enabled"]
        ],
        category: .server,
        isMutating: true
      ),
      ToolDefinition(
        name: "app.quit",
        description: "Quit the Peel app",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .app,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "app.activate",
        description: "Bring the Peel app to the foreground",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .app,
        isMutating: true,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "screenshot.capture",
        description: "Capture screenshot of current screen state",
        inputSchema: [
          "type": "object",
          "properties": [
            "label": ["type": "string"],
            "outputDir": ["type": "string"]
          ]
        ],
        category: .diagnostics,
        isMutating: false,
        requiresForeground: true
      ),
      ToolDefinition(
        name: "translations.validate",
        description: "Validate translation key parity and consistency",
        inputSchema: [
          "type": "object",
          "properties": [
            "root": ["type": "string"],
            "translationsPath": ["type": "string"],
            "baseLocale": ["type": "string"],
            "only": ["type": "string"],
            "summary": ["type": "boolean"],
            "toolPath": ["type": "string"],
            "useAppleAI": ["type": "boolean"],
            "redactSamples": ["type": "boolean"]
          ]
        ],
        category: .diagnostics,
        isMutating: false
      ),
      ToolDefinition(
        name: "pii.scrub",
        description: "Scrub PII from a text file using the pii-scrubber CLI",
        inputSchema: [
          "type": "object",
          "properties": [
            "inputPath": ["type": "string"],
            "outputPath": ["type": "string"],
            "reportPath": ["type": "string"],
            "reportFormat": ["type": "string"],
            "configPath": ["type": "string"],
            "seed": ["type": "string"],
            "maxSamples": ["type": "integer"],
            "enableNER": ["type": "boolean"],
            "toolPath": ["type": "string"]
          ],
          "required": ["inputPath", "outputPath"]
        ],
        category: .diagnostics,
        isMutating: true
      ),
      ToolDefinition(
        name: "docling.convert",
        description: "Convert a document (PDF, etc.) to Markdown using Docling",
        inputSchema: [
          "type": "object",
          "properties": [
            "inputPath": ["type": "string"],
            "outputPath": ["type": "string"],
            "pythonPath": ["type": "string", "description": "Optional path to python3"],
            "scriptPath": ["type": "string", "description": "Optional path to Tools/docling-convert.py"],
            "profile": ["type": "string", "description": "Conversion profile: high or standard"],
            "includeText": ["type": "boolean", "description": "Include markdown text in response"],
            "maxChars": ["type": "integer", "description": "Max chars to include if includeText is true"]
          ],
          "required": ["inputPath", "outputPath"]
        ],
        category: .diagnostics,
        isMutating: true
      ),
      ToolDefinition(
        name: "docling.setup",
        description: "Install Docling into Peel's Application Support venv",
        inputSchema: [
          "type": "object",
          "properties": [
            "pythonPath": ["type": "string", "description": "Optional path to python3 for venv creation"]
          ]
        ],
        category: .diagnostics,
        isMutating: true
      ),
      // Parallel Worktree Tools
      ToolDefinition(
        name: "parallel.create",
        description: "Create a new parallel worktree run with multiple tasks",
        inputSchema: [
          "type": "object",
          "properties": [
            "name": ["type": "string"],
            "projectPath": ["type": "string"],
            "baseBranch": ["type": "string"],
            "targetBranch": ["type": "string"],
            "requireReviewGate": ["type": "boolean"],
            "autoMergeOnApproval": ["type": "boolean"],
            "templateName": ["type": "string"],
            "allowPlannerModelSelection": ["type": "boolean"],
            "allowImplementerModelOverride": ["type": "boolean"],
            "allowPlannerImplementerScaling": ["type": "boolean"],
            "maxImplementers": ["type": "integer"],
            "maxPremiumCost": ["type": "number"],
            "tasks": [
              "type": "array",
              "items": [
                "type": "object",
                "properties": [
                  "title": ["type": "string"],
                  "description": ["type": "string"],
                  "prompt": ["type": "string"],
                  "focusPaths": [
                    "type": "array",
                    "items": ["type": "string"]
                  ]
                ],
                "required": ["title", "prompt"]
              ]
            ]
          ],
          "required": ["name", "projectPath", "tasks"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.start",
        description: "Start a pending parallel worktree run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.status",
        description: "Get status of a parallel worktree run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: false
      ),
      ToolDefinition(
        name: "parallel.list",
        description: "List all parallel worktree runs",
        inputSchema: [
          "type": "object",
          "properties": [
            "includeCompleted": ["type": "boolean"]
          ]
        ],
        category: .parallelWorktrees,
        isMutating: false
      ),
      ToolDefinition(
        name: "parallel.approve",
        description: "Approve an execution in a parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "approveAll": ["type": "boolean"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.reject",
        description: "Reject an execution in a parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "reason": ["type": "string"]
          ],
          "required": ["runId", "executionId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.reviewed",
        description: "Mark an execution as reviewed without approving",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "reviewAll": ["type": "boolean"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.merge",
        description: "Merge approved executions in a parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "mergeAll": ["type": "boolean"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.pause",
        description: "Pause a parallel run (halts new executions and pauses active chains)",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.resume",
        description: "Resume a paused parallel run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.instruct",
        description: "Inject operator guidance into a parallel run or execution",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"],
            "executionId": ["type": "string"],
            "guidance": ["type": "string"]
          ],
          "required": ["runId", "guidance"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "parallel.cancel",
        description: "Cancel a parallel worktree run",
        inputSchema: [
          "type": "object",
          "properties": [
            "runId": ["type": "string"]
          ],
          "required": ["runId"]
        ],
        category: .parallelWorktrees,
        isMutating: true
      ),
      // MARK: - Swarm Tools
      ToolDefinition(
        name: "swarm.start",
        description: "Start the distributed swarm coordinator. Role can be 'brain' (dispatch work), 'worker' (execute work), or 'hybrid' (both).",
        inputSchema: [
          "type": "object",
          "properties": [
            "role": [
              "type": "string",
              "enum": ["brain", "worker", "hybrid"],
              "description": "The role for this Peel instance in the swarm"
            ],
            "port": [
              "type": "integer",
              "description": "Port to listen on (default: 8766)"
            ]
          ],
          "required": ["role"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.stop",
        description: "Stop the distributed swarm coordinator and disconnect from all peers.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.status",
        description: "Get the current swarm status including role, active state, and statistics.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.diagnostics",
        description: "Dev diagnostics snapshot: peers, discovery, and RAG artifact sync status.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.rag.sync",
        description: "Request a Local RAG artifact sync to or from a peel. Direction is 'push' or 'pull'.",
        inputSchema: [
          "type": "object",
          "properties": [
            "direction": [
              "type": "string",
              "enum": ["push", "pull"],
              "description": "Sync direction: push sends artifacts to the peel, pull fetches from it"
            ],
            "workerId": [
              "type": "string",
              "description": "Optional worker device ID (defaults to first connected peel)"
            ]
          ],
          "required": ["direction"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.workers",
        description: "List all connected workers with their capabilities.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.dispatch",
        description: "Dispatch a task to the swarm for execution by a worker.",
        inputSchema: [
          "type": "object",
          "properties": [
            "prompt": [
              "type": "string",
              "description": "The prompt/task to execute"
            ],
            "workingDirectory": [
              "type": "string",
              "description": "The git repository path on the worker where the task should execute (required for worktree isolation)"
            ],
            "templateId": [
              "type": "string",
              "description": "Optional template ID to use"
            ],
            "priority": [
              "type": "string",
              "enum": ["low", "normal", "high", "critical"],
              "description": "Task priority (default: normal)"
            ]
          ],
          "required": ["prompt", "workingDirectory"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.connect",
        description: "Manually connect to a peer at a specific address. Use for debugging or when auto-discovery fails.",
        inputSchema: [
          "type": "object",
          "properties": [
            "address": [
              "type": "string",
              "description": "IP address or hostname of the peer"
            ],
            "port": [
              "type": "integer",
              "description": "Port number (default: 8766)"
            ]
          ],
          "required": ["address"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.discovered",
        description: "List peers discovered via Bonjour (not yet connected).",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.tasks",
        description: "Get completed task results from the swarm. Returns recent task outputs with worker info.",
        inputSchema: [
          "type": "object",
          "properties": [
            "taskId": [
              "type": "string",
              "description": "Optional: Get results for a specific task ID"
            ],
            "limit": [
              "type": "integer",
              "description": "Maximum number of results to return (default: 10)"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.update-workers",
        description: "Trigger all connected workers to pull latest code, rebuild, and restart. Workers will disconnect briefly during restart.",
        inputSchema: [
          "type": "object",
          "properties": [
            "force": [
              "type": "boolean",
              "description": "Force rebuild even if no new commits (default: false)"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.update-log",
        description: "Fetch the latest lines from the worker self-update log.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lines": [
              "type": "integer",
              "description": "Number of log lines to return (default: 200, max: 500)"
            ],
            "workerId": [
              "type": "string",
              "description": "Specific worker ID to target (optional, defaults to first available)"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.direct-command",
        description: "Execute a shell command directly on a worker without LLM involvement. Useful for debugging and administrative tasks.",
        inputSchema: [
          "type": "object",
          "properties": [
            "command": [
              "type": "string",
              "description": "The command to execute"
            ],
            "args": [
              "type": "array",
              "items": ["type": "string"],
              "description": "Command arguments"
            ],
            "workingDirectory": [
              "type": "string",
              "description": "Working directory for the command (optional)"
            ],
            "workerId": [
              "type": "string",
              "description": "Specific worker ID to target (optional, defaults to first available)"
            ]
          ],
          "required": ["command"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.branch-queue",
        description: "View the branch queue status showing in-flight branches being worked on and completed branches ready for PR.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.pr-queue",
        description: "View the PR queue status showing pending operations and created PRs with their labels.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.create-pr",
        description: "Manually create a PR for a completed swarm task. Use when auto-PR is disabled or you want to create a PR for a specific task.",
        inputSchema: [
          "type": "object",
          "properties": [
            "taskId": [
              "type": "string",
              "description": "The task ID to create a PR for (must be in completed branches)"
            ],
            "title": [
              "type": "string",
              "description": "Optional custom PR title (defaults to task prompt)"
            ]
          ],
          "required": ["taskId"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.setup-labels",
        description: "Ensure all Peel PR labels exist in a repository. Creates peel:created, peel:approved, peel:needs-review, peel:needs-help, peel:conflict, and peel:merged labels with proper colors. Run once per repo before using swarm PR features.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Path to the git repository"
            ]
          ],
          "required": ["repoPath"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.register-repo",
        description: "Register a local repository path with the swarm. This maps the repo's git remote URL to the local path, enabling distributed tasks to work across machines with different folder structures.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": [
              "type": "string",
              "description": "The local path to the git repository"
            ],
            "remoteURL": [
              "type": "string",
              "description": "Optional: Explicit remote URL (if not provided, will be auto-detected from the git repo)"
            ]
          ],
          "required": ["path"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.repos",
        description: "List all registered repositories and their remote URL mappings.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      // MARK: - Firestore Swarm Tools
      ToolDefinition(
        name: "swarm.firestore.auth",
        description: "Check Firebase authentication status for Firestore swarm coordination.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.firestore.swarms",
        description: "List all Firestore swarms the current user belongs to (for debugging).",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.firestore.create",
        description: "Create a new Firestore swarm.",
        inputSchema: [
          "type": "object",
          "properties": [
            "name": [
              "type": "string",
              "description": "Name for the new swarm"
            ]
          ],
          "required": ["name"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.firestore.debug",
        description: "Debug query: show raw Firestore swarm data and query parameters.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.firestore.activity",
        description: "Get recent activity log entries for swarm debugging. Shows worker events, task status changes, messages, and errors.",
        inputSchema: [
          "type": "object",
          "properties": [
            "limit": [
              "type": "integer",
              "description": "Maximum number of entries to return (default: 50)"
            ],
            "filter": [
              "type": "string",
              "description": "Filter by event type: worker_online, worker_offline, task_submitted, task_claimed, task_completed, error, etc."
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      // Firestore worker/task management (#225)
      ToolDefinition(
        name: "swarm.firestore.workers",
        description: "List workers registered in a Firestore swarm. Shows status, last heartbeat, and capabilities.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to list workers from"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.firestore.register-worker",
        description: "Register this device as a worker in a Firestore swarm. Requires contributor+ permission.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to register as a worker"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.firestore.unregister-worker",
        description: "Unregister this device as a worker from a Firestore swarm.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to unregister from"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.firestore.submit-task",
        description: "Submit a task to a Firestore swarm for remote execution. Requires contributor+ permission.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to submit the task to"
            ],
            "templateName": [
              "type": "string",
              "description": "Name of the chain template to execute"
            ],
            "prompt": [
              "type": "string",
              "description": "The prompt/task description"
            ],
            "workingDirectory": [
              "type": "string",
              "description": "Working directory for the task"
            ],
            "repoRemoteURL": [
              "type": "string",
              "description": "Git remote URL for the repo (optional)"
            ],
            "priority": [
              "type": "integer",
              "description": "Priority (0=low, 1=normal, 2=high, 3=critical)"
            ]
          ],
          "required": ["swarmId", "templateName", "prompt", "workingDirectory"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.firestore.tasks",
        description: "List pending/running tasks in a Firestore swarm.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to list tasks from"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: false
      ),
      // RAG Artifact Sync (#226)
      ToolDefinition(
        name: "swarm.firestore.rag.artifacts",
        description: "List RAG artifacts available in a Firestore swarm. Shows version, size, and upload info.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to list artifacts from"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "swarm.firestore.rag.push",
        description: "Push local RAG artifacts to Firestore swarm for sharing with other members. Requires contributor+ role.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to push artifacts to"
            ],
            "repoPath": [
              "type": "string",
              "description": "Path to the repository whose RAG index to push"
            ]
          ],
          "required": ["swarmId", "repoPath"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.firestore.rag.pull",
        description: "Pull RAG artifacts from Firestore swarm to local storage. Requires reader+ role.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to pull artifacts from"
            ],
            "artifactId": [
              "type": "string",
              "description": "The artifact ID (version) to pull"
            ],
            "repoPath": [
              "type": "string",
              "description": "Path to the repository to import the RAG index into"
            ]
          ],
          "required": ["swarmId", "artifactId", "repoPath"]
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "swarm.firestore.rag.delete",
        description: "Delete a RAG artifact from Firestore swarm. Requires admin+ role.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID"
            ],
            "artifactId": [
              "type": "string",
              "description": "The artifact ID (version) to delete"
            ]
          ],
          "required": ["swarmId", "artifactId"]
        ],
        category: .swarm,
        isMutating: true
      ),
      // MARK: - Firebase Emulator Tools
      ToolDefinition(
        name: "firebase.emulator.install",
        description: "Install Firebase emulator dependencies via Homebrew/npm. Installs firebase-tools and Java (Temurin JDK) if missing. Safe to call multiple times — skips already-installed components.",
        inputSchema: [
          "type": "object",
          "properties": [
            "components": [
              "type": "array",
              "items": ["type": "string", "enum": ["firebase-tools", "java"]],
              "description": "Which components to install. Default: both firebase-tools and java."
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "firebase.emulator.status",
        description: "Check Firebase emulator status: whether emulators are configured, running, and reachable. Shows connection details for both Firestore and Auth emulators.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      ToolDefinition(
        name: "firebase.emulator.start",
        description: "Start the Firebase Emulator Suite locally (Firestore + Auth). Use lan=true to bind to all interfaces so other machines can connect. Use seed=true to import previously exported test data.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lan": [
              "type": "boolean",
              "description": "Bind to 0.0.0.0 for LAN access (default: false = localhost only)"
            ],
            "seed": [
              "type": "boolean",
              "description": "Import seed data from tmp/firebase-seed/ (default: false)"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "firebase.emulator.stop",
        description: "Stop the Firebase Emulator Suite. Data is auto-exported to tmp/firebase-seed/ on exit.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      ToolDefinition(
        name: "firebase.emulator.configure",
        description: "Configure the app to use Firebase emulators instead of production. Sets UserDefaults so the app connects to emulators on next launch. Both LAN machines should point to the same emulator host.",
        inputSchema: [
          "type": "object",
          "properties": [
            "host": [
              "type": "string",
              "description": "Emulator host IP or hostname (default: localhost). Use a LAN IP for multi-machine testing."
            ],
            "enable": [
              "type": "boolean",
              "description": "Enable (true) or disable (false) emulator mode. Default: true"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      // MARK: - Worktree Tools
      ToolDefinition(
        name: "worktree.list",
        description: "List all git worktrees across registered repositories and the peel-worktrees directory. Returns path, branch, disk size, and status for each worktree.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Optional: Filter to worktrees for a specific repository path"
            ],
            "includeMain": [
              "type": "boolean",
              "description": "Include main worktrees (the original repo checkouts). Default: false"
            ]
          ],
          "required": []
        ],
        category: .worktrees,
        isMutating: false
      ),
      ToolDefinition(
        name: "worktree.remove",
        description: "Remove a git worktree by path. Use force=true if the worktree has uncommitted changes.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": [
              "type": "string",
              "description": "The absolute path to the worktree to remove"
            ],
            "force": [
              "type": "boolean",
              "description": "Force removal even if worktree is dirty. Default: false"
            ]
          ],
          "required": ["path"]
        ],
        category: .worktrees,
        isMutating: true
      ),
      ToolDefinition(
        name: "worktree.stats",
        description: "Get aggregate statistics about all worktrees: total count, disk usage, prunable count, grouped by repository.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .worktrees,
        isMutating: false
      ),
      ToolDefinition(
        name: "worktree.create",
        description: "Create a new git worktree for ad-hoc work, PR review, or experiments. The worktree will be created in ~/peel-worktrees/ with the specified branch.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Path to the git repository"
            ],
            "branchName": [
              "type": "string",
              "description": "Name for the new branch (will be sanitized)"
            ],
            "baseBranch": [
              "type": "string",
              "description": "Base branch to create from (default: origin/main)"
            ]
          ],
          "required": ["repoPath", "branchName"]
        ],
        category: .worktrees,
        isMutating: true
      ),
      // MARK: - AI Terminal Tools
      ToolDefinition(
        name: "terminal.run",
        description: """
          Run a shell command with automatic bash→zsh adaptation and safety analysis.
          Automatically converts common bash patterns to zsh (echo -e, backticks, heredocs, read -p).
          Analyzes commands for safety and blocks critical operations (rm -rf /, curl|sh, etc.).
          Returns structured output with stdout, stderr, exit code, and adaptation/safety info.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "command": ["type": "string", "description": "The command to execute"],
            "workingDirectory": ["type": "string", "description": "Working directory (optional)"],
            "timeout": ["type": "integer", "description": "Timeout in seconds (default: 30)"],
            "skipAdaptation": ["type": "boolean", "description": "Skip bash→zsh adaptation (default: false)"],
            "skipSafetyCheck": ["type": "boolean", "description": "Skip safety analysis (default: false)"]
          ],
          "required": ["command"]
        ],
        category: .terminal,
        isMutating: true
      ),
      ToolDefinition(
        name: "terminal.analyze",
        description: """
          Analyze a command for safety without executing it.
          Returns risk level (safe/low/medium/high/critical), detected risks, and suggestions.
          Use this to pre-flight check commands before running them.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "command": ["type": "string", "description": "The command to analyze"]
          ],
          "required": ["command"]
        ],
        category: .terminal,
        isMutating: false
      ),
      ToolDefinition(
        name: "terminal.adapt",
        description: """
          Preview bash→zsh shell adaptation without executing.
          Shows what transformations would be applied: echo -e removal, backtick→$() conversion,
          read -p adaptation, heredoc escaping, declare→typeset, etc.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "command": ["type": "string", "description": "The command to adapt"]
          ],
          "required": ["command"]
        ],
        category: .terminal,
        isMutating: false
      ),
      // MARK: - Git tools (bypasses shell — no escaping issues)
      ToolDefinition(
        name: "git.status",
        description: "Show git working tree status. Returns clean/dirty indicator plus the status lines.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "short": ["type": "boolean", "description": "Use --short format (default: true)"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: false
      ),
      ToolDefinition(
        name: "git.add",
        description: "Stage files for commit. Defaults to staging everything ('.'). Pass a 'files' array to stage specific paths.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "files": ["type": "array", "items": ["type": "string"], "description": "Paths to stage (default: [\".\"])"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: true
      ),
      ToolDefinition(
        name: "git.commit",
        description: """
          Create a git commit. The message is passed directly to the git Process argument list — \
          no shell involved, so quotes, backticks, and special characters never need escaping.
          Set addAll=true to automatically stage all tracked-file changes before committing.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "message": ["type": "string", "description": "Commit message (no escaping needed)"],
            "addAll": ["type": "boolean", "description": "Stage all tracked changes first (-a flag, default: false)"]
          ],
          "required": ["path", "message"]
        ],
        category: .terminal,
        isMutating: true
      ),
      ToolDefinition(
        name: "git.push",
        description: "Push commits to a remote. Defaults to 'origin'. Omit 'branch' to push the current branch.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "remote": ["type": "string", "description": "Remote name (default: 'origin')"],
            "branch": ["type": "string", "description": "Branch name (default: current branch)"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: true
      ),
      ToolDefinition(
        name: "git.log",
        description: "Show recent commit history.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the git repository"],
            "limit": ["type": "integer", "description": "Number of commits (default: 10)"],
            "format": ["type": "string", "description": "Log format: 'oneline', 'short', 'medium' (default: 'oneline')"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: false
      )
    ]
  }

  func toolList() -> [[String: Any]] {
    activeToolDefinitions.map { tool in
      [
        "name": sanitizedToolName(tool.name),
        "originalName": tool.name,
        "description": tool.description,
        "inputSchema": tool.inputSchema,
        "category": tool.category.rawValue,
        "groups": groups(for: tool).map { $0.rawValue },
        "enabled": isToolEnabled(tool.name),
        "requiresForeground": tool.requiresForeground
      ]
    }
  }

  func sanitizedToolName(_ name: String) -> String {
    let lowercased = name.lowercased()
    return lowercased.map { char in
      let isAllowed = (char >= "a" && char <= "z") || (char >= "0" && char <= "9") || char == "_" || char == "-"
      return isAllowed ? String(char) : "_"
    }.joined()
  }

  func resolveToolName(_ name: String) -> String? {
    if toolDefinition(named: name) != nil {
      return name
    }
    let match = allToolDefinitions.first { sanitizedToolName($0.name) == name }
    if let match {
      return match.name
    }
    let dotted = name.replacingOccurrences(of: "_", with: ".")
    if toolDefinition(named: dotted) != nil {
      return dotted
    }
    return nil
  }


  func groups(for tool: ToolDefinition) -> [ToolGroup] {
    var groups: [ToolGroup] = []
    if tool.name == "screenshot.capture" {
      groups.append(.screenshots)
    }
    if tool.name == "ui.navigate" || tool.name == "ui.back" || tool.name == "ui.snapshot" {
      groups.append(.uiNavigation)
    }
    if tool.isMutating {
      groups.append(.mutating)
    }
    if !tool.requiresForeground {
      groups.append(.backgroundSafe)
    }
    return groups
  }
}
