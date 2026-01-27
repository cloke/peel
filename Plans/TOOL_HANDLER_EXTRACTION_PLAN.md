# Tool Handler Extraction Plan

**Created:** 2026-01-26  
**Status:** In Progress  
**Issues:** #159, #160  
**Recommended Model:** Sonnet or GPT-4.1 (mechanical refactoring)

## Overview

Extract RAG and Chain tools from MCPServerService.swift (~4933 lines) into dedicated handlers following the existing pattern (VMToolsHandler, UIToolsHandler, ParallelToolsHandler).

## Current State

### Completed ✅

1. **RAGToolsHandler.swift** - Scaffold created (`45571af`)
   - `RAGToolsHandlerDelegate` protocol defined
   - 20 RAG tools in `supportedTools`
   - Handler methods implemented
   - Prefixed types to avoid conflicts

2. **ChainToolsHandler.swift** - Scaffold created (`eb89380`)
   - `ChainToolsHandlerDelegate` protocol defined
   - 15 chain/template tools in `supportedTools`
   - Handler methods implemented
   - Supporting types defined

### Remaining Work

#### Phase 1: Wire RAGToolsHandler

1. **Extend MCPServerService to implement RAGToolsHandlerDelegate**
   - Add conformance declaration
   - Implement required methods by delegating to existing `localRagStore`
   - Map existing state properties to delegate requirements

2. **Create and register RAGToolsHandler instance**
   ```swift
   private var ragToolsHandler: RAGToolsHandler?
   
   func setupHandlers() {
     ragToolsHandler = RAGToolsHandler()
     ragToolsHandler?.delegate = self
   }
   ```

3. **Route RAG tools in dispatch**
   ```swift
   // In handleToolCall
   if ragToolsHandler?.supportedTools.contains(name) == true {
     return await ragToolsHandler!.handle(name: name, id: id, arguments: arguments)
   }
   ```

4. **Remove duplicated RAG handlers from MCPServerService** (~350 lines)

#### Phase 2: Wire ChainToolsHandler

1. **Extend MCPServerService to implement ChainToolsHandlerDelegate**
   - Implement methods delegating to `agentManager`, `templateLoader`
   - Expose queue state and prompt rules

2. **Create and register ChainToolsHandler instance**

3. **Route chain/template tools in dispatch**

4. **Remove duplicated chain handlers from MCPServerService** (~400 lines)

## Implementation Notes

### Delegate Method Mapping (RAG)

| Delegate Method | MCPServerService Implementation |
|-----------------|--------------------------------|
| `searchRag()` | `localRagStore?.search()` |
| `ragStatus()` | Build from `localRagStore` state |
| `indexRepository()` | `localRagStore?.indexRepository()` |
| `listRagRepos()` | `localRagStore?.listRepos()` |
| `listRepoGuidanceSkills()` | `dataService.listSkills()` |

### Delegate Method Mapping (Chains)

| Delegate Method | MCPServerService Implementation |
|-----------------|--------------------------------|
| `startChain()` | `agentManager.startChain()` |
| `chainStatus()` | Query `activeChains` |
| `listTemplates()` | `templateLoader.loadBuiltInTemplates()` |
| `getPromptRules()` | Return `promptRules` |

### State Properties to Expose

**RAG:**
- `lastRagSearchQuery`, `lastRagSearchResults`, etc.
- `ragIndexingPath`, `ragIndexProgress`
- `preferredEmbeddingProvider`

**Chains:**
- `activeChains`, `queuedChains`
- `promptRules`
- Queue configuration state

## Testing Checklist

After each phase:

```bash
# Build
xcodebuild -scheme "Peel (macOS)" build

# Launch and test
./Tools/build-and-launch.sh --wait-for-server

# RAG tools
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.status
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.repos.list

# Chain tools
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name chains.promptRules.get
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name templates.list
```

## Estimated Scope

- **Phase 1 (RAG):** ~2 hours, removes ~350 lines from MCPServerService
- **Phase 2 (Chains):** ~2 hours, removes ~400 lines from MCPServerService
- **Net result:** MCPServerService reduced by ~750 lines (15%)

## References

- [MCPToolHandler.swift](../Shared/AgentOrchestration/ToolHandlers/MCPToolHandler.swift) - Base protocol
- [VMToolsHandler.swift](../Shared/AgentOrchestration/ToolHandlers/VMToolsHandler.swift) - Example implementation
- [RAGToolsHandler.swift](../Shared/AgentOrchestration/ToolHandlers/RAGToolsHandler.swift) - Scaffold
- [ChainToolsHandler.swift](../Shared/AgentOrchestration/ToolHandlers/ChainToolsHandler.swift) - Scaffold
