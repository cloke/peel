# TaskRunner Modernization Plan

**Created:** January 6, 2026  
**Status:** ✅ **COMPLETE**  
**Priority:** DONE

---

## ✅ COMPLETED - See /Plans/TASKRUNNER_COMPLETE.md

All TaskRunner modernization work has been successfully completed:

- ✅ TaskRunner package modernized with ProcessExecutor actor
- ✅ Git package migrated (13 command files)
- ✅ Brew package migrated (2 ViewModels)
- ✅ All using modern Swift 6 async/await patterns
- ✅ Build succeeds with no errors

**For full details, see:** `/Plans/TASKRUNNER_COMPLETE.md`

---

## Original Plan (Now Complete)

## Executive Summary

TaskRunner is an external package dependency used by Git and Brew packages to execute command-line tools (git, brew). The current implementation uses **old patterns** that conflict with modern Swift 6.0 concurrency:

- ❌ Manual `DispatchQueue.main.async` threading
- ❌ Callback-based completion handlers
- ❌ Protocol conformance overhead (TaskRunnerProtocol)
- ❌ External dependency may use outdated patterns
- ❌ Poor error handling with force unwrapping

**Recommendation:** Replace TaskRunner with a modern, lightweight actor-based command executor.

---

## Current Architecture

### Dependencies
```swift
// Git/Package.swift
.package(name: "TaskRunner", path: "../../../TaskRunner")  // ❌ Path doesn't exist!

// Brew/Package.swift
.package(name: "TaskRunner", url: "https://github.com/crunchybananas/TaskRunner", branch: "main")
```

**Issue:** Git package references a local path that doesn't exist, Brew uses external GitHub repo.

### Current Usage Pattern

```swift
// Git/Commands/Commands.swift
public struct Commands: TaskRunnerProtocol {
  private static let shared = Commands()

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
}
```

### Files Using TaskRunner

1. **Git Package:**
   - `Git/Sources/Git/Commands/Commands.swift` - Command wrapper
   - `Git/Sources/Git/Commands/Diff.swift` - Diff operations
   - `Git/Sources/Git/Commands/Branch.swift` - Branch operations
   - All other command files (Status, Commit, Add, etc.)

2. **Brew Package:**
   - `Brew/Sources/Brew/DetailView.swift` - Commands wrapper + ViewModel
   - `Brew/Sources/Brew/SidebarNavigationView.swift` - ViewModel

3. **Shared:**
   - `Shared/Views/TaskDebugWindowView.swift` - Debug logging (uses @ObservedObject!)

---

## Problems Identified

### 1. **Anti-Pattern: Manual Threading** 🔴 Critical
```swift
DispatchQueue.main.async {  // ❌ WRONG
  Self.shared.launch(...)
}
```
**Impact:** Violates Swift 6 concurrency model, can cause data races.

### 2. **Anti-Pattern: Callback Wrapping** 🔴 Critical
The code wraps callback-based TaskRunner in async/await using continuations. This is a **bridge pattern** that should be eliminated.

### 3. **External Dependency Uncertainty** 🟡 Medium
We don't know if TaskRunner itself is using modern patterns. It's an external dependency we control (crunchybananas org) but haven't audited.

### 4. **Poor Error Handling** 🟡 Medium
```swift
let status = try? await Commands.launch(...)  // Swallows errors
return String(data: data, encoding: .utf8)!  // Force unwrap
```

### 5. **TaskDebugWindowView Uses @ObservedObject** 🟡 Medium
```swift
struct TaskDebugDisclosureContentView: View {
  @ObservedObject var log: DebugLog  // ❌ Should be @Bindable
```

### 6. **Commented Out Code** 🟡 Medium
Lots of old buffer-based streaming code is commented out in:
- `Brew/Sources/Brew/DetailView.swift` (install/uninstall methods)
- `Brew/Sources/Brew/SidebarNavigationView.swift` (installed/available methods)

---

## Modern Solution: ProcessExecutor Actor

Replace TaskRunner with a lightweight, Swift 6-native command executor.

### Proposed Architecture

```swift
// Shared/Services/ProcessExecutor.swift
actor ProcessExecutor {
  enum ExecutionError: Error {
    case invalidPath
    case executionFailed(Int)
    case decodingFailed
    case timeout
  }
  
  struct Result {
    let stdout: Data
    let stderr: Data
    let exitCode: Int
    
    var stdoutString: String {
      String(data: stdout, encoding: .utf8) ?? ""
    }
    
    var stderrString: String {
      String(data: stderr, encoding: .utf8) ?? ""
    }
    
    var lines: [String] {
      stdoutString.split(separator: "\n").map(String.init)
    }
  }
  
  /// Execute a command and return the full result
  func execute(
    _ executable: String,
    arguments: [String],
    workingDirectory: String? = nil
  ) async throws -> Result {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    
    guard let url = URL(string: executable) ?? URL(filePath: executable) else {
      throw ExecutionError.invalidPath
    }
    
    process.executableURL = url
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    
    if let workingDirectory {
      process.currentDirectoryURL = URL(filePath: workingDirectory)
    }
    
    try process.run()
    
    // Use async streams for better resource management
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
  
  /// Execute and decode JSON response
  func executeJSON<T: Decodable>(
    _ executable: String,
    arguments: [String],
    workingDirectory: String? = nil
  ) async throws -> T {
    let result = try await execute(executable, arguments: arguments, workingDirectory: workingDirectory)
    return try JSONDecoder().decode(T.self, from: result.stdout)
  }
  
  /// Stream output line-by-line for long-running commands
  func stream(
    _ executable: String,
    arguments: [String],
    workingDirectory: String? = nil
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          let process = Process()
          let stdoutPipe = Pipe()
          
          guard let url = URL(string: executable) ?? URL(filePath: executable) else {
            throw ExecutionError.invalidPath
          }
          
          process.executableURL = url
          process.arguments = arguments
          process.standardOutput = stdoutPipe
          
          if let workingDirectory {
            process.currentDirectoryURL = URL(filePath: workingDirectory)
          }
          
          try process.run()
          
          let handle = stdoutPipe.fileHandleForReading
          
          // Read line by line
          for try await line in handle.bytes.lines {
            continuation.yield(line)
          }
          
          process.waitUntilExit()
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }
}
```

### Migration Example: Git Commands

**Before:**
```swift
public struct Commands: TaskRunnerProtocol {
  private static let shared = Commands()

  static func launch(tool: URL, arguments: [String]) async throws -> TaskStatus {
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<TaskStatus, Error>) in
      DispatchQueue.main.async {
        Self.shared.launch(tool: tool, arguments: arguments) { result, arg in
          continuation.resume(returning: .complete(arg, [""]))
        }
      }
    }
  }
  
  static func simple(arguments: [String]) async throws -> [String] {
    let status = try? await Commands.launch(tool: URL(fileURLWithPath: Executable.git.rawValue), arguments: arguments)
    switch status {
    case .complete(let data, _):
      return String(data: data, encoding: .utf8)!.split(separator: "\n").map { String($0) }
    default:
      throw GitError.Unknown
    }
  }
}
```

**After:**
```swift
public struct Commands {
  private static let executor = ProcessExecutor()
  
  static func execute(arguments: [String], in repository: Model.Repository? = nil) async throws -> ProcessExecutor.Result {
    try await executor.execute(
      Executable.git.rawValue,
      arguments: arguments,
      workingDirectory: repository?.path
    )
  }
  
  static func simple(arguments: [String], in repository: Model.Repository? = nil) async throws -> [String] {
    let result = try await execute(arguments: arguments, in: repository)
    return result.lines
  }
}
```

### Migration Example: Brew Commands

**Before:**
```swift
struct Commands: TaskRunnerProtocol {
  private static let shared = Commands()
  
  static func launch(tool: URL, arguments: [String]) async throws -> TaskStatus {
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<TaskStatus, Error>) in
      Self.shared.launch(tool: tool, arguments: arguments) { result, arg in
        continuation.resume(returning: .complete(arg, [""]))
      }
    }
  }
  
  static func simple(arguments: [String]) async throws -> [String] {
    let status = try? await Commands.launch(tool: URL(string: Executable.brew.rawValue)!, arguments: arguments)
    switch status {
    case .complete(let data, _):
      return String(data: data, encoding: .utf8)!.split(separator: "\n").map { String($0) }
    default: ()
    }
    return []
  }
}
```

**After:**
```swift
struct Commands {
  private static let executor = ProcessExecutor()
  
  static func execute(arguments: [String]) async throws -> ProcessExecutor.Result {
    try await executor.execute(Executable.brew.rawValue, arguments: arguments)
  }
  
  static func executeJSON<T: Decodable>(_ type: T.Type, arguments: [String]) async throws -> T {
    try await executor.executeJSON(Executable.brew.rawValue, arguments: arguments)
  }
}

// Usage in ViewModel
func details(of name: String) async {
  var cmd = Command.BrewInfo
  cmd.append(name)
  
  do {
    let infos = try await Commands.executeJSON([Info].self, arguments: cmd)
    guard let decoded = infos.first else { return }
    
    self.name = decoded.name ?? ""
    self.description = decoded.description ?? ""
    self.homepage = decoded.homepage ?? ""
    self.installed = decoded.installed?.first
    self.versions = decoded.versions
  } catch {
    // Handle error properly
  }
}
```

---

## Migration Steps

### Phase 1: Create ProcessExecutor (30 min)
- [ ] Create `Shared/Services/ProcessExecutor.swift`
- [ ] Implement basic `execute()` method
- [ ] Implement `executeJSON()` method
- [ ] Add proper error types
- [ ] Add unit tests

### Phase 2: Migrate Git Package (1-2 hours)
- [ ] Update `Git/Commands/Commands.swift` to use ProcessExecutor
- [ ] Remove TaskRunnerProtocol conformance
- [ ] Remove DispatchQueue.main.async
- [ ] Add proper error handling
- [ ] Update all command files (Diff, Branch, Status, etc.)
- [ ] Remove TaskRunner dependency from Package.swift
- [ ] Test all git operations

### Phase 3: Migrate Brew Package (1-2 hours)
- [ ] Update `Brew/DetailView.swift` Commands to use ProcessExecutor
- [ ] Update DetailView.ViewModel to use new API
- [ ] Remove TaskRunnerProtocol conformance
- [ ] Implement install/uninstall methods properly (currently commented out)
- [ ] Update SidebarNavigationView.ViewModel
- [ ] Remove TaskRunner dependency from Package.swift
- [ ] Test all brew operations

### Phase 4: Update Debug Window (15 min)
- [ ] Update TaskDebugWindowView to use @Bindable instead of @ObservedObject
- [ ] Consider removing if no longer needed after removing TaskRunner
- [ ] Or update to work with ProcessExecutor logging

### Phase 5: Cleanup (15 min)
- [ ] Remove all commented-out TaskRunner code
- [ ] Remove TaskRunner from Package.resolved
- [ ] Update Package.swift files
- [ ] Build and test

### Phase 6: Enhanced Streaming (Optional - 1 hour)
- [ ] Implement `stream()` method for long-running commands
- [ ] Update install/uninstall methods to show progress
- [ ] Add proper progress indicators in UI

---

## Benefits of Migration

### Code Quality ✅
- **Cleaner:** No protocol conformance, no manual threading
- **Safer:** Proper error handling, no force unwrapping
- **Simpler:** Direct async/await, no callback wrapping

### Performance ✅
- **Faster:** No unnecessary DispatchQueue overhead
- **Efficient:** Actor isolation prevents data races
- **Better:** Async streams for long-running commands

### Maintainability ✅
- **No External Dependency:** One less package to maintain
- **Modern Swift 6:** Follows best practices
- **Self-Contained:** All code in the project

### Developer Experience ✅
- **Easier to Debug:** Clear error messages
- **Easier to Test:** Simple actor interface
- **Easier to Extend:** Add new methods easily

---

## Risks & Mitigation

### Risk 1: Breaking Git/Brew Functionality
**Mitigation:** 
- Test each command after migration
- Keep old code temporarily until verified
- Use feature flag to switch between old/new

### Risk 2: Unknown TaskRunner Features
**Mitigation:**
- Audit TaskRunner source code first
- Identify all features being used
- Ensure ProcessExecutor has feature parity

### Risk 3: Debug Window Dependency
**Mitigation:**
- Update debug window to work with new system
- Or remove if no longer needed
- ProcessExecutor can emit log events

---

## Testing Checklist

After migration, verify:

**Git Package:**
- [ ] Repository status display
- [ ] File diffs
- [ ] Branch switching
- [ ] Committing changes
- [ ] Staging/unstaging files
- [ ] Stash operations

**Brew Package:**
- [ ] Package search
- [ ] Package details display
- [ ] Install (if implemented)
- [ ] Uninstall (if implemented)
- [ ] Package listing

---

## Decision: Should We Do This?

### ✅ YES - If you want:
- Modern Swift 6 patterns throughout
- No external dependencies
- Better error handling
- Streaming output for installs
- Learning exercise in process execution

### ❌ NO - If:
- Current TaskRunner works fine
- Don't want to risk breaking git/brew functionality
- Other priorities are more important
- Satisfied with current state

---

## Recommendation

**Priority: MEDIUM (Optional Enhancement)**

The current TaskRunner usage has old patterns but **works functionally**. This is a good modernization project but NOT critical since:

1. ✅ The core app modernization is complete
2. ✅ TaskRunner is isolated to Git/Brew packages
3. ✅ Build succeeds, no errors
4. ❌ But uses manual threading (anti-pattern)
5. ❌ But has poor error handling

**Suggested Approach:**
- Do this if you want to learn process execution in Swift 6
- Or if you want to implement install/uninstall with progress
- Otherwise, leave it for later

---

## Estimated Effort

- **Phase 1 (ProcessExecutor):** 30-60 minutes
- **Phase 2 (Git):** 1-2 hours
- **Phase 3 (Brew):** 1-2 hours  
- **Phase 4 (Debug):** 15-30 minutes
- **Phase 5 (Cleanup):** 15-30 minutes
- **Phase 6 (Streaming - Optional):** 1 hour

**Total:** 3.5-6 hours (including testing)

---

## Next Steps

**Option 1:** Start with Phase 1 - create ProcessExecutor and test it
**Option 2:** Audit TaskRunner source code first to understand what we're replacing
**Option 3:** Skip this for now, mark as future enhancement

---

**Related Documents:**
- `/Plans/SWIFTUI_MODERNIZATION_PLAN.md` - Main modernization plan
- `/Plans/CURRENT_STATUS.md` - Current project status
- `/.github/copilot-instructions.md` - Swift 6 best practices

**Created:** January 6, 2026  
**Last Updated:** January 6, 2026
