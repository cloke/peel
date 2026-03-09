# Phase 2: Xcode MCP Basic Integration

**Date:** March 9, 2026  
**Status:** ✅ Implementation Started  
**Phase:** 2 / 4  
**Effort:** 4 engineer-days  

---

## Completed in Phase 2

### 1. ✅ XcodeToolHandler Created
**File:** `Shared/AgentOrchestration/MCPToolHandlers/XcodeToolHandler.swift` (310 lines)

Implements MCPToolHandler protocol to expose Xcode MCP tools:
- Routes tool calls to appropriate category handler
- 55+ tools organized in 5 categories
- Error handling with specific error types
- Async/await integration with XcodeMCPAdapter

Key methods:
- `handle(toolName:arguments:)` — Main entry point for tool calls
- Category-specific handlers (symbols, diagnostics, project, refactoring, build)

---

## Next Tasks (Phase 2 Continuation)

### Task 1: Register XcodeToolHandler in MCP Registry

**What:** Add XcodeToolHandler to MCPToolHandlerRegistry so agents can discover and use Xcode tools

**File to modify:** `Shared/AgentOrchestration/MCPToolHandlers/MCPToolHandlerRegistry.swift`

**Change needed:**
```swift
// In the registry initialization:
registry.register(
    toolPattern: "xcode.*",
    handler: XcodeToolHandler(adapter: XcodeMCPAdapter())
)
```

### Task 2: Create Unit Tests

**File:** `Tests macOS/XcodeToolHandlerTests.swift`

**Tests needed:**
- [ ] Tool handler initialization
- [ ] Tool name validation
- [ ] Symbol tools routing
- [ ] Diagnostics tools routing
- [ ] Project tools routing
- [ ] Refactoring tools routing
- [ ] Build tools routing
- [ ] Error handling for invalid tools

### Task 3: Create Example Chains

**File:** Create example YAML chains in `Plans/XCODE_MCP_EXAMPLE_CHAINS.md`

**Examples needed:**
- [ ] Code validation chain
- [ ] Symbol rename chain
- [ ] Diagnostics collection chain
- [ ] Project info retrieval chain
- [ ] Auto-fix workflow chain

### Task 4: Integration Testing

**What:** Test XcodeToolHandler with real agent chains

**Tests:**
- [ ] Simple validation chain works end-to-end
- [ ] Tool results properly integrated into agent workflow
- [ ] Error handling and fallbacks work
- [ ] Performance acceptable (tool calls < 1 second)

### Task 5: Documentation

**Files:**
- `Docs/guides/XCODE_MCP_PHASE2_GUIDE.md` — Phase 2 implementation details
- Update `Docs/guides/XCODE_MCP_USAGE_GUIDE.md` with Phase 2 status

---

## Architecture Overview

### Before Phase 2
```
Agent → File parsing → Generate code → Hope it compiles
```

### After Phase 2
```
Agent → XcodeToolHandler → XcodeMCPAdapter → mcpbridge → Xcode Tool Service
                                                              ↓
                                            Returns semantic information
                                            (types, errors, conventions)
                                                              ↓
Agent uses information to generate correct, validated code
```

---

## Files Created/Modified in Phase 2

### Created
- `Shared/AgentOrchestration/MCPToolHandlers/XcodeToolHandler.swift` ✅ (310 lines)

### To Create
- `Tests macOS/XcodeToolHandlerTests.swift`
- `Plans/XCODE_MCP_EXAMPLE_CHAINS.md`
- `Docs/guides/XCODE_MCP_PHASE2_GUIDE.md`

### To Modify
- `Shared/AgentOrchestration/MCPToolHandlers/MCPToolHandlerRegistry.swift` (registration)
- `Docs/guides/XCODE_MCP_USAGE_GUIDE.md` (update status)

---

## Success Criteria (Phase 2)

- [ ] XcodeToolHandler compiles without errors
- [ ] Handler registered in MCP registry
- [ ] All 55 Xcode tools discoverable via tools/list
- [ ] Example chains demonstrate tool usage
- [ ] Unit tests passing (>80% coverage)
- [ ] Integration tests passing
- [ ] Agents can call Xcode tools successfully
- [ ] Tool results properly formatted and integrated
- [ ] Error handling works for edge cases
- [ ] GitHub issue #363 updated with completion

---

## Expected Improvements (Phase 2)

Once Phase 2 is complete, agents will be able to:

✅ **Query project structure** before generating code  
✅ **Check for compilation errors** before writing files  
✅ **Get type information** for proper code generation  
✅ **Apply auto-fixes** for common issues  
✅ **Validate accessibility** in generated code  
✅ **Modernize code** to Swift 6 patterns automatically  

---

## Current Status

| Task | Status | Notes |
|------|--------|-------|
| XcodeMCPAdapter service | ✅ Complete | Phase 1 artifact |
| Tool catalog discovery | ✅ Complete | 55 tools documented |
| XcodeToolHandler | ✅ Complete | MCPToolHandler implementation |
| Tool registration | ⏳ Next | Modify MCPToolHandlerRegistry |
| Unit tests | ⏳ Next | Create test suite |
| Example chains | ⏳ Next | YAML template examples |
| Integration tests | ⏳ Next | End-to-end validation |
| Documentation | ⏳ Next | Phase 2 guide |

---

## How to Continue

### Step 1: Register XcodeToolHandler
Find `MCPToolHandlerRegistry.swift` and add:
```swift
registry.register(toolPattern: "xcode.*", handler: XcodeToolHandler(adapter: XcodeMCPAdapter()))
```

### Step 2: Run Build
```bash
cd /Users/cloken/code/KitchenSink
./Tools/build.sh
```

### Step 3: Create Tests
Create `Tests macOS/XcodeToolHandlerTests.swift` with unit tests

### Step 4: Create Example Chains
Document example chains showing how agents use Xcode tools

### Step 5: Commit & Push
```bash
git add -A
git commit -m "Phase 2: Xcode MCP Tool Handler Integration"
git push origin main
```

---

## GitHub Issue

**Issue:** #363 — Phase 2: Xcode MCP Basic Integration  
**Link:** https://github.com/cloke/peel/issues/363

---

## Timeline

```
Day 1: Register handler, create tests
Day 2: Create example chains, integration tests
Day 3: Documentation, final validation
```

---

**Status:** XcodeToolHandler created and ready for registration  
**Next:** Register in MCPToolHandlerRegistry and build
