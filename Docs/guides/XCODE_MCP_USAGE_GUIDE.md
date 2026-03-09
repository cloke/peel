# Xcode MCP Integration - Usage Guide for Peel App

**Version:** 1.0  
**Date:** March 9, 2026  
**Status:** Planning Phase (Pre-Implementation)

---

## Overview

This guide explains how to use Xcode's Model Context Protocol (MCP) bridge within Peel for enhanced code intelligence, diagnostics, and automated refactoring.

---

## Table of Contents

1. [User-Facing Features](#user-facing-features)
2. [Agent Developer Guide](#agent-developer-guide)
3. [Copilot Skill Guide](#copilot-skill-guide)
4. [API Reference](#api-reference)
5. [Troubleshooting](#troubleshooting)
6. [Examples](#examples)

---

## User-Facing Features

### Feature 1: Real-Time Code Validation

**What it does:** Validates code before writing to disk

**User workflow:**
```
User: "Add a new settings view"
  ↓
Peel Agent: Generates code
  ↓
Xcode MCP: Validates compilation
  ↓
Peel: ✅ Code guaranteed to compile
  ↓
Result written to disk
```

**Benefits:**
- No build surprises
- Instant feedback on errors
- Automatic fixes applied before commit

**How to use:**
- Enable in: Settings → Agent Workflows → "Auto-validate with Xcode"
- Validation happens automatically during agent execution
- View validation results in: Agent Panel → "Validation Results"

---

### Feature 2: Smart Code Generation

**What it does:** Agents understand project structure and conventions

**User workflow:**
```
User: "Add a feature view"
  ↓
Agent queries Xcode:
  • What targets exist?
  • What dependencies are available?
  • What naming conventions are used?
  • What design patterns are common?
  ↓
Agent generates code that:
  ✅ Matches conventions
  ✅ Uses correct dependencies
  ✅ Follows project patterns
```

**Benefits:**
- No manual convention checking
- Correct dependency usage
- Consistent code style

**How to use:**
- Enable in: Settings → Agent Workflows → "Smart project analysis"
- Agents automatically query Xcode on startup
- View project context in: Agent Panel → "Project Context"

---

### Feature 3: Type-Safe Refactoring

**What it does:** Uses Xcode's semantic refactoring for guaranteed correctness

**User workflow:**
```
User: "Rename MyViewController to ScreenController"
  ↓
Xcode MCP: Semantic refactoring (type-safe)
  ↓
Results:
  ✅ All references updated
  ✅ Type safety verified
  ✅ No broken references
  ✅ Build validated
```

**Benefits:**
- 100% accurate renames
- Type-safe transformations
- Zero broken references

**How to use:**
- Available in: Refactor Panel → "Xcode-Powered Refactoring"
- Select operation: Rename, Extract, Move, etc.
- Xcode handles the transformation

---

### Feature 4: Auto-Fix & Modernization

**What it does:** Automatically fixes and modernizes code

**Examples:**
- Swift 6 concurrency issues → Auto-fixed to @Observable
- Memory safety warnings → Auto-fixed with proper ownership
- Accessibility issues → Auto-fixed with labels
- Deprecated APIs → Auto-modernized to current Swift

**How to use:**
- Enable in: Settings → Quality Gates → "Auto-fix issues"
- Run manually in: Code Panel → "Fix Issues"
- Auto-runs during agent generation (when enabled)

---

### Feature 5: Distributed Development

**What it does:** Remote agents can access local Xcode instance

**User workflow:**
```
Local Mac:      Running Xcode 26.3 + Peel
Remote Mac:     Running Peel agent worker

Remote agent runs:
  • Generates code
  • Queries local Xcode via SSH tunnel
  • Validates against real Xcode
  • Commits with confidence
```

**Benefits:**
- Remote development fully supported
- Full code intelligence on any Mac
- Validation happens locally on source Mac

**How to use:**
- Setup: Swarm → "Configure Xcode Forwarding"
- Automatic SSH tunneling to main Mac
- Works like local development

---

## Agent Developer Guide

### Using Xcode MCP Tools in Chains

#### Simple Chain Example: Validate Code

```yaml
Chain: ValidateCodeGeneration
Description: Generate code with automatic Xcode validation

Steps:
  - type: agentic
    prompt: |
      Generate a new SwiftUI view for {feature_name}.
      Use the project's existing patterns and conventions.
    tools:
      - xcode.project.getInfo
      - xcode.symbols.lookup
      - xcode.diagnostics.get
      - xcode.build.validate
    
    validation:
      required: true
      threshold: "no-errors"
      
  - type: deterministic
    action: writeFiles
    
  - type: agentic
    prompt: "Review generated code and ensure it compiles"
    tools:
      - xcode.build.compile
      - xcode.diagnostics.get
```

#### Complex Chain Example: Modernize to Swift 6

```yaml
Chain: ModernizeToSwift6
Description: Automatically update code to Swift 6 patterns

Steps:
  - type: agentic
    prompt: |
      Find all @ObservableObject usages and update to @Observable.
      Find all DispatchQueue.main.async and update to @MainActor.
      Ensure all changes compile and tests pass.
      
    tools:
      - xcode.diagnostics.getConcurrencyIssues
      - xcode.refactor.autoFix
      - xcode.build.validate
      - xcode.test.run
    
    iterations: 3
    stopOn: ["no-errors", "all-tests-pass"]
```

### Available Tool Categories

#### Symbols & Code Intelligence
```
xcode.symbols.lookup(symbol: String) -> SymbolInfo
xcode.symbols.references(symbol: String) -> [Reference]
xcode.symbols.typeInfo(symbol: String) -> TypeInfo
xcode.symbols.rename(oldName: String, newName: String) -> [Change]
```

#### Diagnostics & Analysis
```
xcode.diagnostics.get(file?: String, category?: String) -> [Diagnostic]
xcode.diagnostics.getConcurrencyIssues() -> [ConcurrencyIssue]
xcode.diagnostics.getMemorySafetyIssues() -> [MemorySafetyIssue]
xcode.diagnostics.getAccessibilityIssues() -> [AccessibilityIssue]
```

#### Project Information
```
xcode.project.getInfo() -> ProjectInfo
xcode.project.getTargets() -> [Target]
xcode.project.getSchemes() -> [Scheme]
xcode.project.getDependencies() -> [Dependency]
xcode.project.getConventions() -> ProjectConventions
```

#### Refactoring & Fixes
```
xcode.refactor.extractMethod(code: String) -> [Suggestion]
xcode.refactor.moveToFile(symbol: String) -> Change
xcode.refactor.autoFix(issue: Diagnostic) -> Change
xcode.refactor.formatCode(files: [String]) -> [Change]
```

#### Build & Validation
```
xcode.build.validate(files: [String]) -> BuildResult
xcode.build.compile() -> CompileResult
xcode.test.run(pattern?: String) -> TestResult
xcode.test.coverage(file?: String) -> CoverageInfo
```

### Error Handling

All Xcode tools can return errors. Handle appropriately:

```swift
// In chain definition:
steps:
  - type: agentic
    prompt: "Use Xcode tools"
    tools:
      - xcode.build.validate
    
    errorHandling:
      onXcodeMissing: "fallback-to-file-validation"
      onTimeout: "retry-with-backoff"
      onMaxRetries: "report-and-continue"
```

### Best Practices

1. **Always validate before writing**
   ```yaml
   - tools: [xcode.build.validate]
     then: writeFiles
   ```

2. **Query conventions first**
   ```yaml
   - tools: [xcode.project.getConventions]
     then: generate
   ```

3. **Handle Xcode not running gracefully**
   ```yaml
   fallback:
     - if: xcodeMissing
       then: use-file-based-validation
   ```

4. **Cache project info**
   ```yaml
   - type: deterministic
     cache:
       key: "project-info"
       ttl: "1 hour"
     result: xcode.project.getInfo()
   ```

---

## Copilot Skill Guide

### Is This a Copilot Skill?

**Answer:** Partially. Here's the breakdown:

**What IS a Copilot Skill:**
- ✅ Discovering Xcode tools (Phase 1)
- ✅ Creating example chains using Xcode MCP
- ✅ Troubleshooting validation issues
- ✅ Writing agent templates

**What is NOT a Copilot Skill:**
- ❌ Core XcodeMCPAdapter implementation (engineering task)
- ❌ Tool handler integration (engineering task)
- ❌ System-level changes (engineering task)

### Proposed Copilot Skills

#### Skill 1: Xcode MCP Discovery
**Trigger:** When starting Phase 1 implementation

```
Objective: Discover all available Xcode MCP tools
Input: Xcode version (26.3+)
Process:
  1. Query xcrun mcpbridge for tools/list
  2. Extract tool names and signatures
  3. Document parameters and return types
  4. Create tool inventory JSON
Output: 
  - tmp/xcode-mcp-tools.json (tool catalog)
  - Documentation of each tool
  - Test harness for validation
```

**Instructions for Copilot:**
```
You are helping to discover Xcode's Model Context Protocol (MCP) tools.

Task: Use mcpbridge to enumerate all available Xcode tools and document them.

Requirements:
1. Run: echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | xcrun mcpbridge
2. Parse the JSON-RPC response
3. For each tool, extract:
   - name (e.g., "xcode.symbols.lookup")
   - description
   - parameters (with types)
   - return type
4. Create comprehensive documentation
5. Organize tools by category
6. Create test cases for each tool

Output files:
- tmp/xcode-mcp-tools.json (catalog)
- Docs/reference/XCODE_MCP_TOOL_REFERENCE.md (documentation)
```

#### Skill 2: Example Chain Builder
**Trigger:** When building chains that use Xcode MCP

```
Objective: Create example agent chains using Xcode MCP tools
Input: Feature description (e.g., "Add a new view")
Process:
  1. Determine required Xcode MCP tools
  2. Create chain YAML template
  3. Add error handling
  4. Create test cases
Output:
  - Chain YAML file
  - Test cases
  - Documentation
```

#### Skill 3: Xcode MCP Troubleshooting
**Trigger:** When agents fail using Xcode tools

```
Objective: Diagnose and fix Xcode MCP integration issues
Input: Error message or symptom
Process:
  1. Check if Xcode is running
  2. Check mcpbridge availability
  3. Validate STDIO communication
  4. Check timeout issues
  5. Suggest fixes
Output:
  - Root cause analysis
  - Recommended fixes
  - Logging guidance
```

### How to Use Copilot Skills

1. **Start Discovery Skill:**
   ```
   @skills run xcode-mcp-discovery --xcode-version 26.3
   ```

2. **Create Chain with Example Skill:**
   ```
   @skills run example-chain-builder --feature "Add settings view"
   ```

3. **Troubleshoot with Diagnostic Skill:**
   ```
   @skills run xcode-mcp-troubleshooting --error "mcpbridge timeout"
   ```

---

## API Reference

### XcodeMCPAdapter Service

**Location:** `Shared/Services/XcodeMCPAdapter.swift`

```swift
actor XcodeMCPAdapter {
    /// Initialize adapter (spawns mcpbridge)
    func start() throws
    
    /// Send JSON-RPC call to Xcode MCP
    func call<T: Decodable>(_ method: String, params: [String: Any]) async throws -> T
    
    /// List all available tools
    func listTools() async throws -> [MCPTool]
    
    /// Gracefully shutdown
    func shutdown()
    
    /// Check if Xcode is running
    func isXcodeAvailable() async -> Bool
}
```

### MCPTool Handler

**Registered as:** `"xcode.*"`

```swift
struct XcodeToolHandler: MCPToolHandler {
    static var supportedTools: [String] {
        [
            "xcode.symbols.lookup",
            "xcode.symbols.references",
            "xcode.diagnostics.get",
            "xcode.project.getInfo",
            "xcode.build.validate",
            // ... more tools
        ]
    }
    
    func handle(toolName: String, arguments: [String: Any]) async throws -> MCPToolResult
}
```

### Chain Template Integration

**In chain YAML:**
```yaml
Tools:
  - name: xcode.build.validate
    category: validation
    timeout: 10s
    
  - name: xcode.symbols.lookup
    category: intelligence
    cacheResults: true
    cacheTTL: 1h
```

---

## Troubleshooting

### Issue: "mcpbridge not found"

**Cause:** Xcode not installed or not in PATH

**Solution:**
```bash
# Check Xcode installation
xcode-select -p

# If needed, select Xcode
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

# Verify mcpbridge
xcrun mcpbridge --help
```

### Issue: "Connection to Xcode tool service failed"

**Cause:** Xcode process not running or IPC issue

**Solutions:**
1. Check if Xcode is running: `ps aux | grep Xcode`
2. If not running, launch Xcode: `open /Applications/Xcode.app`
3. Check IPC health: `xcrun mcpbridge --help`

### Issue: "Timeout waiting for Xcode response"

**Cause:** Xcode slow to respond or large project

**Solutions:**
1. Increase timeout: Set `MCP_XCODE_TIMEOUT=30s` environment variable
2. Check Xcode performance: Open Activity Monitor
3. Try simpler queries first (cache results)

### Issue: "Tool not found: xcode.symbols.lookup"

**Cause:** Tool not available in Xcode 26.3 or not discovered

**Solutions:**
1. Run discovery again: `Phase 1` implementation
2. Check tool availability: `xcrun mcpbridge < query.json`
3. Verify Xcode version: `xcodebuild -version`

### Issue: "SSH tunnel to Xcode failed"

**Cause:** Network configuration or firewall

**Solutions:**
1. Check SSH access: `ssh user@host "xcrun mcpbridge --help"`
2. Verify firewall allows port forwarding
3. Check Peel swarm configuration
4. Fallback to local validation

---

## Examples

### Example 1: Rename Symbol Across Project

**User Request:**
```
"Rename MyViewController to SettingsViewController"
```

**Chain Execution:**
```yaml
Chain: RenameSymbol
Steps:
  - type: agentic
    prompt: "Use Xcode to rename MyViewController to SettingsViewController"
    tools:
      - xcode.symbols.rename
      - xcode.build.validate
      - xcode.test.run
```

**Result:**
- ✅ All references updated
- ✅ Build succeeds
- ✅ Tests pass
- ✅ Zero broken references

---

### Example 2: Add Feature with Auto-Validation

**User Request:**
```
"Add a settings screen following project patterns"
```

**Agent Workflow:**
```
1. Query: xcode.project.getConventions()
   → Learn naming patterns, design patterns

2. Query: xcode.project.getTargets()
   → Know where to add file

3. Query: xcode.project.getDependencies()
   → Know what's available

4. Generate code
   → Uses all above context

5. Validate: xcode.build.validate()
   → Confirms compile

6. Write files
   → Only if validation passed
```

**Result:**
- ✅ Code matches conventions
- ✅ Guaranteed to compile
- ✅ Correct dependencies used

---

### Example 3: Modernize to Swift 6

**User Request:**
```
"Update the project to Swift 6 concurrency patterns"
```

**Agent Workflow:**
```
1. Query: xcode.diagnostics.getConcurrencyIssues()
   → Find all @ObservableObject, DispatchQueue.main, etc.

2. For each issue:
   xcode.refactor.autoFix(issue)
   → Apply automatic modernization

3. Validate: xcode.build.validate()
   → Confirm all fixes work

4. Test: xcode.test.run()
   → Ensure tests still pass
```

**Result:**
- ✅ 100+ lines modernized automatically
- ✅ All tests pass
- ✅ Zero manual intervention needed

---

### Example 4: Code Review Quality Gate

**Automated Quality Check:**
```
Before committing:
  1. Compile check: xcode.build.validate()
  2. Warnings: xcode.diagnostics.get()
  3. Tests: xcode.test.run()
  4. Coverage: xcode.test.coverage()
  5. Accessibility: xcode.diagnostics.getAccessibilityIssues()
  6. Memory Safety: xcode.diagnostics.getMemorySafetyIssues()
  
PR Created: ✅ All checks passed, ready to merge
```

---

## Configuration

### Enable/Disable Xcode MCP

**In App Settings:**
```
Settings → Developer Tools → Xcode Integration

☑ Enable Xcode MCP
  ☑ Auto-validate on agent generation
  ☑ Use semantic refactoring
  ☑ Auto-fix issues
  ☑ Show validation warnings
  
Timeout (seconds): [10 ▼]
```

### Environment Variables

```bash
# Set Xcode instance to use
export MCP_XCODE_PID=12345

# Set session ID
export MCP_XCODE_SESSION_ID=550e8400-e29b-41d4-a716-446655440000

# Set timeout
export MCP_XCODE_TIMEOUT=15

# Enable verbose logging
export MCP_XCODE_DEBUG=1
```

### Project Configuration

**In `.peel/config.yaml`:**
```yaml
xcodeIntegration:
  enabled: true
  autoValidate: true
  semanticRefactoring: true
  autoFix: true
  timeout: 10
  cache:
    enabled: true
    ttl: 3600
```

---

## Next Steps

1. ✅ Review this guide
2. ⏳ Phase 1: Discover tools
3. ⏳ Phase 2: Implement XcodeMCPAdapter
4. ⏳ Phase 3: Create example chains
5. ⏳ Phase 4: Production deployment

---

## Related Documentation

- [XCODE_MCP_ROADMAP.md](../tmp/XCODE_MCP_ROADMAP.md) — Implementation plan
- [XCODE_MCP_EXAMPLES.md](../tmp/XCODE_MCP_EXAMPLES.md) — Real-world examples
- [Peel Chain Templates](./Docs/guides/CHAIN_TEMPLATES.md) — Chain syntax

---

**Last Updated:** March 9, 2026  
**Status:** Pre-Implementation Guide  
**Questions?** See main analysis in `/tmp/XCODE_MCP_*.md`
