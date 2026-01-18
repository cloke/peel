# MCP Validation Pipeline

## Overview

The MCP validation pipeline provides automated correctness checks for chain execution results. Validation runs after chain completion and reports structured results via the MCP API.

## Validation Schema

### ValidationResult

```swift
public struct ValidationResult {
  public enum Status {
    case passed
    case failed
    case warning
    case skipped
  }
  
  public let status: Status
  public let reasons: [String]
  public let metadata: [String: String]
  public let timestamp: Date
}
```

### Status Meanings

- **passed**: All validation checks succeeded
- **failed**: One or more validation checks failed
- **warning**: Validation found issues but not critical failures
- **skipped**: Validation was not applicable or disabled

## Built-in Validation Rules

### SuccessValidationRule
Checks that the chain completed without errors or merge conflicts.

### OutputValidationRule
Ensures all agents produced non-empty output.

### ReviewerApprovalValidationRule
Validates that the reviewer agent approved changes (if present).

### GitDiffValidationRule
Verifies that implementers made git changes in the working directory.

### HeuristicValidationRule
Scans agent output for common issues like error messages, failures, and TODO markers.

## Validation Configurations

### Predefined Configurations

```swift
// Default: Success, Output, Reviewer Approval, Heuristic
ValidationConfiguration.default

// Strict: Includes Git Diff check
ValidationConfiguration.strict

// Minimal: Only Success check
ValidationConfiguration.minimal

// None: No validation
ValidationConfiguration.none
```

### Custom Configuration

```swift
let config = ValidationConfiguration(
  enabledRules: [.success, .output, .reviewerApproval]
)
```

## Per-Template Validation

Templates can specify their validation configuration:

```swift
ChainTemplate(
  name: "MCP Harness",
  description: "...",
  steps: [...],
  validationConfig: .default
)
```

## MCP API Response

When running a chain via MCP, the response includes validation results:

```json
{
  "chain": {
    "id": "...",
    "name": "MCP Harness",
    "state": "Complete"
  },
  "success": true,
  "validation": {
    "status": "passed",
    "reasons": ["Chain completed successfully", "All agents produced output"],
    "metadata": {},
    "timestamp": "2026-01-18T21:00:00Z"
  },
  "results": [...]
}
```

## Persistence

Validation results are stored in `MCPRunRecord`:

- `validationStatus`: The status (passed/failed/warning/skipped)
- `validationReasons`: Newline-separated reasons

## Adding Custom Validators

Implement the `ValidationRule` protocol:

```swift
public struct MyCustomRule: ValidationRule {
  public let name = "My Custom Validation"
  public let description = "Checks something custom"
  
  public func validate(
    chain: AgentChain,
    summary: AgentChainRunner.RunSummary,
    workingDirectory: String?
  ) async -> ValidationResult {
    // Your validation logic here
    if someCondition {
      return .passed(reason: "Custom check passed")
    } else {
      return .failed(reasons: ["Custom check failed"])
    }
  }
}
```

Then add it to `ValidationConfiguration.RuleType` and update `createRules()`.

## Testing

Run validation tests:

```bash
xcodebuild test -scheme "Peel (macOS)" -only-testing:ValidationTests
```

## Example Usage

### Via MCP API

```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "chains.run",
    "arguments": {
      "templateName": "MCP Harness",
      "prompt": "Fix the login bug",
      "workingDirectory": "/path/to/repo"
    }
  },
  "id": 1
}
```

The response will include validation results automatically for templates with validation enabled.

### Programmatically

```swift
let summary = await chainRunner.runChain(
  chain, 
  prompt: prompt,
  validationConfig: .strict
)

if let validation = summary.validationResult {
  print("Validation status: \(validation.status)")
  for reason in validation.reasons {
    print("  - \(reason)")
  }
}
```

## Future Enhancements

- Add lint/test validators that run actual commands
- Support for custom validation scripts
- Validation result visualization in UI
- Configurable validation timeouts
- Parallel validation rule execution
