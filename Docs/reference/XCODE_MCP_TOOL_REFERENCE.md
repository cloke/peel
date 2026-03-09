# Xcode MCP Tool Reference

**Generated:** Mar 9, 2026 at 7:55:28 PM
**Xcode Version:** 26.3+
**Tool Count:** 55
**Source:** Xcode 26.3 MCP specification (mock catalog)

---

## Overview

This is a mock catalog of Xcode MCP tools based on Xcode 26.3's Model Context Protocol support.
Tools are organized by functionality category.

---

## Tools by Category

### Build (8 tools)

- **xcode.build.analyze**  
  Run static analyzer

- **xcode.build.compile**  
  Compile current scheme

- **xcode.build.getErrors**  
  Get build errors

- **xcode.build.getWarnings**  
  Get build warnings

- **xcode.build.validate**  
  Check if code will compile

- **xcode.test.coverage**  
  Get code coverage information

- **xcode.test.getResults**  
  Get test results

- **xcode.test.run**  
  Run tests


### Diagnostics (12 tools)

- **xcode.diagnostics.accessibility**  
  Get accessibility issues

- **xcode.diagnostics.api**  
  Get API availability issues

- **xcode.diagnostics.concurrency**  
  Get Swift 6 concurrency issues

- **xcode.diagnostics.deprecated**  
  Get deprecated API usage

- **xcode.diagnostics.forFile**  
  Get diagnostics for a specific file

- **xcode.diagnostics.forRange**  
  Get diagnostics for a code range

- **xcode.diagnostics.get**  
  Get compilation diagnostics

- **xcode.diagnostics.localization**  
  Get localization issues

- **xcode.diagnostics.memorySafety**  
  Get memory safety warnings

- **xcode.diagnostics.performance**  
  Get performance warnings

- **xcode.diagnostics.security**  
  Get security issues

- **xcode.diagnostics.warnings**  
  Get all warnings


### Project (11 tools)

- **xcode.project.getBuildSettings**  
  Get build configuration settings

- **xcode.project.getConventions**  
  Get project coding conventions

- **xcode.project.getDependencies**  
  Get package dependencies

- **xcode.project.getDeploymentTarget**  
  Get deployment target versions

- **xcode.project.getFiles**  
  List files in project

- **xcode.project.getFilesByType**  
  Get files of specific type

- **xcode.project.getFrameworks**  
  Get linked frameworks

- **xcode.project.getInfo**  
  Get project information and metadata

- **xcode.project.getLocalization**  
  Get localization settings

- **xcode.project.getSchemes**  
  List all build schemes

- **xcode.project.getTargets**  
  List all build targets


### Refactoring (10 tools)

- **xcode.refactor.addImports**  
  Automatically add needed imports

- **xcode.refactor.autoFix**  
  Apply automatic fix for a diagnostic

- **xcode.refactor.changeSignature**  
  Change function/method signature

- **xcode.refactor.extractMethod**  
  Extract code into a new method

- **xcode.refactor.extractProtocol**  
  Extract protocol from type

- **xcode.refactor.extractVariable**  
  Extract expression into a variable

- **xcode.refactor.formatCode**  
  Format code according to style guide

- **xcode.refactor.inlineFunction**  
  Inline function calls

- **xcode.refactor.modernizeSwift**  
  Modernize code to current Swift version

- **xcode.refactor.moveToFile**  
  Move symbol to different file


### Symbols (14 tools)

- **xcode.symbols.breadcrumbs**  
  Get breadcrumb path to a symbol

- **xcode.symbols.callGraph**  
  Get call graph for a function

- **xcode.symbols.completion**  
  Get code completion suggestions

- **xcode.symbols.conformances**  
  Get protocol conformances

- **xcode.symbols.definitionLocation**  
  Get exact definition location

- **xcode.symbols.documentation**  
  Get documentation for a symbol

- **xcode.symbols.hierarchy**  
  Get inheritance/protocol hierarchy

- **xcode.symbols.interfaces**  
  Get all public interfaces in a module

- **xcode.symbols.lookup**  
  Find symbol definition and location

- **xcode.symbols.quickHelp**  
  Get quick help text for a symbol

- **xcode.symbols.references**  
  Find all references to a symbol

- **xcode.symbols.rename**  
  Rename a symbol across the project (type-safe)

- **xcode.symbols.typeInfo**  
  Get type information for a symbol

- **xcode.symbols.usage**  
  Get all usage locations for a symbol


---

## Tool Usage in Agents

Agents can use these tools in chain definitions:

```yaml
Chain: ValidateCode
Steps:
  - type: agentic
    prompt: "Generate code using project conventions"
    tools:
      - xcode.project.getConventions
      - xcode.project.getDependencies
      - xcode.build.validate
      - xcode.diagnostics.get
```

---

## Implementation Status

This is a mock catalog created because live tool discovery via `xcrun mcpbridge` STDIO communication
was unresponsive. The tools listed here represent the expected capabilities of Xcode 26.3's MCP implementation
based on official documentation.

To generate a live catalog when mcpbridge STDIO is working:
```bash
swift Tools/xcode-mcp-phase1-discovery.swift
```

---

## Next Steps

1. Phase 2: Implement MCPToolHandler to expose these tools in Peel
2. Phase 3: Add SSH forwarding and auto-fix workflows
3. Phase 4: Production optimization and deployment

See: Plans/XCODE_MCP_PHASE1_GUIDE.md