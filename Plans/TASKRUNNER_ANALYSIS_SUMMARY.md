# TaskRunner Analysis - Quick Summary

**Date:** January 6, 2026  
**Status:** Analysis Complete

---

## TL;DR

TaskRunner is an **external dependency** used to execute command-line tools (git, brew). It uses **old patterns** that conflict with modern Swift 6:

❌ Manual `DispatchQueue.main.async`  
❌ Callback-based API wrapped in async/await  
❌ Poor error handling (force unwraps, swallowed errors)  
❌ External dependency we control but haven't audited  

**Recommendation:** Optional modernization - replace with lightweight actor-based process executor.

---

## What is TaskRunner?

A package that wraps macOS `Process` to execute shell commands. Used by:
- **Git package** - All git commands (status, diff, commit, branch, etc.)
- **Brew package** - All brew commands (info, search, install, etc.)

## Current Anti-Patterns

### 1. Manual Threading (🔴 Critical)
```swift
DispatchQueue.main.async {  // ❌ BAD - manual threading
  Self.shared.launch(...)
}
```

### 2. Callback Wrapping (🔴 Critical)
```swift
// Wraps old callback API in async/await - inefficient bridge pattern
return try await withCheckedThrowingContinuation { continuation in
  DispatchQueue.main.async {
    Self.shared.launch(tool: tool, arguments: arguments) { result, arg in
      continuation.resume(returning: .complete(arg, [""]))
    }
  }
}
```

### 3. Poor Error Handling (🟡 Medium)
```swift
let status = try? await Commands.launch(...)  // Swallows errors
return String(data: data, encoding: .utf8)!  // Force unwrap
```

## Proposed Solution

Replace with a **modern actor-based ProcessExecutor**:

```swift
actor ProcessExecutor {
  func execute(_ executable: String, arguments: [String]) async throws -> Result {
    // Modern async/await, no manual threading
    // Proper error handling
    // Stream support for long-running commands
  }
}
```

### Benefits
✅ No external dependency  
✅ Modern Swift 6 concurrency  
✅ Proper error handling  
✅ Streaming support (for brew install progress)  
✅ Simpler, cleaner code  

### Effort
- **Total Time:** 3-6 hours (includes Git, Brew, testing)
- **Risk:** Medium (touches core command execution)
- **Impact:** High (removes anti-patterns, no external dep)

---

## Should You Do This?

### ✅ YES - If you want:
- To eliminate ALL old patterns (this is the last major one)
- No external dependencies
- To implement brew install/uninstall with progress
- A learning project (process execution in Swift 6)
- Complete modernization satisfaction

### ❌ NO - If:
- TaskRunner works fine (it does, functionally)
- Don't want to risk breaking git/brew
- Other priorities more important
- Happy with 95% modernization

---

## Comparison

### Current (TaskRunner)
```swift
// Old pattern - callback wrapped in async/await
static func launch(tool: URL, arguments: [String]) async throws -> TaskStatus {
  return try await withCheckedThrowingContinuation {
    (continuation: CheckedContinuation<TaskStatus, Error>) in
    DispatchQueue.main.async {  // ❌ Manual threading
      Self.shared.launch(tool: tool, arguments: arguments) { result, arg in
        continuation.resume(returning: .complete(arg, [""]))
      }
    }
  }
}

static func simple(arguments: [String]) async throws -> [String] {
  let status = try? await Commands.launch(...)  // ❌ Swallows errors
  switch status {
  case .complete(let data, _):
    return String(data: data, encoding: .utf8)!  // ❌ Force unwrap
  default:
    throw GitError.Unknown
  }
}
```

### Proposed (ProcessExecutor)
```swift
// Modern actor - native async/await
actor ProcessExecutor {
  func execute(_ executable: String, arguments: [String]) async throws -> Result {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    
    try process.run()
    
    async let stdoutData = stdoutPipe.fileHandleForReading.readToEnd()
    async let stderrData = stderrPipe.fileHandleForReading.readToEnd()
    
    process.waitUntilExit()
    
    let stdout = try await stdoutData ?? Data()
    let stderr = try await stderrData ?? Data()
    
    guard process.terminationStatus == 0 else {
      throw ExecutionError.executionFailed(Int(process.terminationStatus))
    }
    
    return Result(stdout: stdout, stderr: stderr, exitCode: Int(process.terminationStatus))
  }
}

// Usage
static func simple(arguments: [String]) async throws -> [String] {
  let result = try await executor.execute(Executable.git.rawValue, arguments: arguments)
  return result.lines  // No force unwrap, proper error propagation
}
```

---

## Files Affected

**Core:**
- `Shared/Services/ProcessExecutor.swift` (new file)

**Git Package (7 files):**
- `Git/Sources/Git/Commands/Commands.swift`
- `Git/Sources/Git/Commands/Diff.swift`
- `Git/Sources/Git/Commands/Branch.swift`
- And 4 more command files
- `Git/Package.swift` (remove TaskRunner dependency)

**Brew Package (3 files):**
- `Brew/Sources/Brew/DetailView.swift`
- `Brew/Sources/Brew/SidebarNavigationView.swift`
- `Brew/Package.swift` (remove TaskRunner dependency)

**Shared:**
- `Shared/Views/TaskDebugWindowView.swift` (update or remove)

---

## Next Steps

**If you want to proceed:**

1. Read full plan: `/Plans/TASKRUNNER_MODERNIZATION_PLAN.md`
2. Start with Phase 1: Create ProcessExecutor
3. Test thoroughly before removing TaskRunner
4. Migrate Git, then Brew
5. Remove dependency

**If you're unsure:**
- Test current git/brew functionality first
- Consider other priorities
- This is truly optional (app works fine without it)

---

## Bottom Line

TaskRunner uses old patterns but **works functionally**. Replacing it would:
- ✅ Complete the modernization to 100%
- ✅ Remove the last major anti-pattern
- ✅ Eliminate an external dependency
- ❌ Take 3-6 hours
- ❌ Risk breaking git/brew commands

**Your call!** 🎯

---

**Related Documents:**
- `/Plans/TASKRUNNER_MODERNIZATION_PLAN.md` - Full migration plan
- `/Plans/CURRENT_STATUS.md` - Current project status
- `/.github/copilot-instructions.md` - Swift 6 best practices
