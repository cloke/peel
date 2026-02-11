# GitHub Copilot Instructions for Peel

## Project Context

Peel is a macOS/iOS SwiftUI application for managing GitHub, Git repositories, and Homebrew. "Peel back the layers" of your dev environment.

**Targets:** macOS 26 (Tahoe), iOS 26  
**Swift Version:** 6.0  
**Status:** Active development

---

## Preferred Languages & Tech

**Preferred (in order):**
1. **Swift** — First choice for all Apple platform code, agents, services
2. **Shell (bash/zsh)** — Scripting, automation, CLI tools
3. **Rust** — Performance-critical components, CLI tools
4. **Ruby** — Scripting, data processing, quick prototypes

**Fallback only when necessary:**
- **Python** — AI/ML ecosystem tools (MLX has Python bindings, some models require it)
- Prefer Swift wrappers around Python when possible (e.g., PythonKit or shell-out)

---

## 🗂️ Quick Navigation

### Finding Code
| Looking for... | Location |
|----------------|----------|
| App entry point | `Shared/PeelApp.swift` |
| MCP Server | `Shared/AgentOrchestration/MCPServerService.swift` |
| Agent chain execution | `Shared/AgentOrchestration/AgentChainRunner.swift` |
| Agent lifecycle | `Shared/AgentOrchestration/AgentManager.swift` |
| CLI tool detection | `Shared/AgentOrchestration/CLIService.swift` |
| Git operations | `Local Packages/Git/Sources/Git/` |
| GitHub API | `Local Packages/Github/Sources/Github/` |
| Homebrew | `Local Packages/Brew/Sources/Brew/` |
| SwiftData models | `Shared/SwiftDataModels.swift` |
| Views by feature | `Shared/Applications/` (Git_RootView, Github_RootView, etc.) |

### Documentation vs Plans
| Type | Location | Purpose |
|------|----------|---------|
| **Docs/** | How things work NOW | Guides, reference |
| **Plans/** | Future work | Roadmaps, proposals |

### Key Docs
| Doc | Path |
|-----|------|
| MCP usage guide | `Docs/guides/MCP_AGENT_WORKFLOW.md` |
| Project roadmap | `Plans/ROADMAP.md` |
| Code patterns | `Docs/reference/CODE_AUDIT_INDEX.md` |

### Tools
| Tool | Path | Purpose |
|------|------|---------|
| Build & launch | `Tools/build-and-launch.sh` | Build app, enable MCP, launch |
| MCP CLI | `Tools/PeelCLI/` | CLI wrapper for MCP commands |
| gh-issue-sync | `Tools/PeelSkills/` | Sync GitHub issues with plan files |
| roadmap-audit | `Tools/PeelSkills/` | Verify roadmap claims against code |
| file-rewrite | `Tools/PeelSkills/` | Write files reliably (no shell escaping) |

### Local RAG Embeddings
- **MLX is now the default** - no setup required, models auto-download from HuggingFace
- Default model: `nomic-embed-text-v1.5` (768 dims, good for code)
- Auto-selects model tier based on available RAM (8GB → MiniLM, 16GB+ → nomic)
- See `Docs/reference/RAG_EMBEDDING_MODEL_EVALUATION.md` for provider comparison

~~### Local RAG Core ML Embeddings (Deprecated)~~
The CodeBERT → Core ML conversion pipeline has been replaced by MLX. The old workflow required:
- Manual Python conversion with `coremltools`
- Separate tokenizer scripts
- Manual deployment to Application Support
- Poor search quality results

**Legacy artifacts (if needed):** `Tools/ModelTools/` - but prefer MLX instead.

### Skills (Agent Tools)

**Before editing roadmap/plan files:**
```bash
cd /path/to/KitchenSink
Tools/PeelSkills/.build/debug/gh-issue-sync --plans-dir Plans
```

**When file writes fail (heredoc issues):**
```bash
Tools/PeelSkills/.build/debug/file-rewrite path/to/file.md --stdin
# Then pipe content to stdin
```

**Create new plan from template:**
```bash
Tools/PeelSkills/.build/debug/file-rewrite Plans/NEW_PLAN.md --template plan --var title="My Plan"
```

### MCP CLI First (IMPORTANT)
When the user asks to **start a chain**, **use the MCP CLI** instead of manually creating worktrees.

**Preferred flow:**
1. Launch Peel with MCP enabled using `Tools/build-and-launch.sh` (use `--wait-for-server`).
2. Use `Tools/PeelCLI` to run `chains-run` with `--prompt` and (optionally) `--template-name` or `--template-id`.
3. Let the app create worktrees; do **not** create worktrees manually unless the user explicitly asks.

**If local changes exist and this is an MCP chain invocation:** commit and push first (unless user says not to). When the user manually runs build-and-launch, do **not** auto-stash or commit — just build and launch.

### Temp Files — Always Use Project `tmp/` (IMPORTANT)
**Never write temp files to `/tmp` or system temp directories.** Always use the repo-local `tmp/` directory instead.

- MCP CLI args: `tmp/peel-mcp-args.json`
- Test scripts: `tmp/test-*.sh`, `tmp/test-*.swift`
- Debug output: `tmp/debug-*.json`, `tmp/debug-*.log`
- Any scratch files: `tmp/<descriptive-name>`

Create `tmp/` if it doesn't exist. This directory is gitignored.

Reason: `/tmp` triggers macOS permission prompts and scatters files outside the project. Repo-local `tmp/` keeps everything scoped and accessible.

### Execution Guardrails (IMPORTANT)
- If a skill or better docs would have prevented confusion, **pause and ask** for clarification or propose adding a skill/doc before continuing.
- Prefer **one decisive action** over trying multiple approaches. If the first attempt is uncertain, stop and ask rather than trying 10 things.

### RAG-First Search Strategy (CRITICAL)

**ALWAYS use RAG search BEFORE grep_search or reading files directly.**

```
✅ CORRECT workflow:
   1. rag.search (vector or text) → get relevant file list
   2. read_file on top results
   3. make changes

❌ WRONG workflow:
   1. grep_search or semantic_search
   2. read files
   3. make changes
```

**Search modes:**
- `mode: "vector"` — Semantic search (e.g., "how does authentication work")
- `mode: "text"` — Exact keyword match (e.g., "@tracked", "validateForm")

**Example RAG-first flow:**
```bash
# 1. Search RAG first
curl -X POST http://127.0.0.1:8765/rpc -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.search","arguments":{"query":"form validation error handling","repoPath":"/path/to/repo","mode":"vector","limit":10}}}'

# 2. Read files returned by RAG
# 3. Make targeted changes
```

**Only use grep_search when:**
- RAG returns no results AND you've tried both vector and text modes
- The repo is not indexed (check with `rag.repos.list` first)

### RAG Search Before Writing Code (IMPORTANT)

**Before writing new utility code, helpers, or patterns**, search the RAG to avoid reinventing the wheel:

```bash
# Text search for exact names (best for finding existing utilities)
echo '{"query": "JSONRPCResponseBuilder", "repoPath": "/path/to/repo", "mode": "text", "limit": 10}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.search --arguments-json tmp/peel-mcp-args.json

# Vector search for concepts (best for "how does X work")
echo '{"query": "error handling response pattern", "repoPath": "/path/to/repo", "mode": "vector", "limit": 5}' > tmp/peel-mcp-args.json
Tools/PeelCLI/.build/debug/peel-mcp tools-call --tool-name rag.search --arguments-json tmp/peel-mcp-args.json
```

**When to search RAG first:**
| Task | Query Example |
|------|---------------|
| Adding MCP tool response code | `"makeResult makeError"` (text) |
| Creating error handling | `"error handling pattern"` (vector) |
| Adding validation logic | `"guard let arguments validation"` (text) |
| Building UI patterns | `"SwiftUI view pattern"` (vector) |
| Working with protocols | `"protocol delegate handler"` (text) |

**Key reusable code locations found via RAG:**
- `MCPCore/JSONRPC.swift` — `JSONRPCResponseBuilder.makeResult/makeError`, `ErrorCode` constants
- `MCPToolHandler.swift` — Protocol + delegate pattern for tool handlers
- `LocalizedError+Helper.swift` — Error protocol helpers

**Rule: If you're about to write a helper function, search first.**

### RAG Database Management via MCP (IMPORTANT)

**Always use MCP tools** to manage the RAG database—never delete or modify `rag.sqlite` directly:

| Task | MCP Tool | Example |
|------|----------|---------|
| Check status | `rag.status` | Verify DB exists, schema version, provider |
| List repos | `rag.repos.list` | See what's indexed with file/chunk counts |
| Delete repo | `rag.repos.delete` | Remove repo to force clean re-index |
| Re-index | `rag.index` with `forceReindex: true` | Rebuild embeddings |
| Test embeddings | `rag.embedding.test` | Verify dimensions and timing |
| Set provider | `rag.config` with `action: "set"` | Switch between mlx/coreml/system |

**Why not delete the sqlite file directly:**
- The app may hold open database handles → causes "disk I/O error"
- Database recreation may not match expected schema
- Loses all indexed repos, not just the one you want to reset

**Proper workflow for resetting a repo's embeddings:**
```bash
# 1. Delete the specific repo
curl -X POST http://127.0.0.1:8765/rpc -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.repos.delete","arguments":{"repoPath":"/path/to/repo"}}}'

# 2. Re-index
curl -X POST http://127.0.0.1:8765/rpc -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.index","arguments":{"repoPath":"/path/to/repo"}}}'
```

---

## Model Selection for Cost Optimization

Use the right model for the task to minimize premium request costs.

### Task → Model Mapping

| Task Type | Recommended Model | Premium Cost | Notes |
|-----------|-------------------|--------------|-------|
| **Planning/Architecture** | Claude Opus, o1 | High (1.0) | Complex reasoning, multi-step plans |
| **Implementation** | Claude Sonnet, GPT-4.1 | Medium (0.33) | Good balance of quality/cost |
| **Simple Implementation** | GPT-4.1-mini, Claude Haiku | Low (0) | Single-file changes, clear specs |
| **Tests/Docs** | GPT-4.1-mini, Haiku | Low (0) | Mechanical, well-defined output |
| **Renames/Formatting** | Any fast model | Low (0) | Trivial transformations |

### MCP Chain Strategy

For the Peel MCP chain workflow:
1. **Planner** (Opus/Sonnet): Creates the plan, splits tasks, picks models for each
2. **Implementers** (Sonnet or lower): Execute individual sub-tasks
3. **Merge Agent** (Sonnet): Combine results, resolve conflicts  
4. **Reviewer** (Sonnet): Validate correctness

### When to Use Cheap Models

✅ **Good for 0-cost models:**
- Writing unit tests from existing code
- Adding documentation/comments
- Renaming variables/functions
- Formatting changes
- Simple CRUD operations
- Copying patterns from elsewhere in codebase

❌ **Use premium models for:**
- Architecture decisions
- Complex refactoring
- Security-sensitive code
- Multi-file coordinated changes
- Novel algorithms

---

## Project Management

### GitHub Project & Issues
- **Project Board:** https://github.com/users/cloke/projects/1
- **Repository:** https://github.com/cloke/peel
- **Roadmap:** `/Plans/ROADMAP.md`

### Current Phases
| Phase | Focus | Status |
|-------|-------|--------|
| **1A** | Polish existing features | ✅ Complete |
| **1B** | Parallel agent execution | ✅ Complete |
| **1C** | MCP server & templates | 🔄 In Progress (#13, #16 open) |
| **2** | Local AI foundation | 📋 Next (#8 PII scrubber) |
| **3** | VM isolation | 📋 Future (#9 Linux VM polish) |

### Working with Issues
```bash
# List open issues
gh issue list --repo cloke/peel

# View issue details
gh issue view 5 --repo cloke/peel

# Create a branch for an issue
git checkout -b issue-5-parallel-agents

# Close an issue via commit
git commit -m "Implement parallel execution

Closes #5"

# Update project item status
gh project item-edit --project-id PVT_kwHNO8jOATOTCg --id <ITEM_ID> \
  --field-id PVTSSF_lAHNO8jOATOTCs4PAuuN --single-select-option-id 47fc9ee4  # In Progress
```

### Issue Template (REQUIRED)
When creating issues, use this exact Markdown structure to keep formatting consistent:

```
## Summary
<one sentence>

## Proposed Charts / Work
- <bullet list>

## Data Source
- <API/log/store>

## UI Placement
- <view/area>

## Acceptance Criteria
- [ ] <testable outcome>
```

If an issue template file exists in .github/ISSUE_TEMPLATE, prefer:
```
gh issue create --repo cloke/peel --template <template-file>
```

### Issue Body Formatting (IMPORTANT)
To avoid escaped newline formatting in issue bodies, use the repo script instead of inline `gh issue create` bodies:

```bash
Tools/gh-issue-create.sh --repo cloke/peel --title "Title" --body-file /path/to/body.md
# or pipe from stdin
cat /path/to/body.md | Tools/gh-issue-create.sh --repo cloke/peel --title "Title"
```

### Delegating to GitHub Copilot Workspace
For simple, well-defined tasks, you can delegate to Copilot Workspace:
1. Open issue in browser: `gh issue view <number> --repo cloke/peel --web`
2. Click "Open in Copilot Workspace" on the issue page
3. Copilot Workspace will analyze and propose changes
4. Review and create PR from Copilot Workspace

Good candidates for delegation:
- Simple refactors (rename, extract method)
- Adding tests for existing code
- Documentation updates
- Mechanical code cleanup (like #4 - delete duplicate code)

---

## Code Style & Conventions

### Formatting
- **Indentation:** 2 spaces (not tabs)
- **Line Length:** 120 characters max (soft limit)
- **Blank Lines:** Use sparingly, one between logical sections
- **Braces:** Opening brace on same line (K&R style)

### File Organization
```swift
// 1. Imports (alphabetical, grouped by framework)
import Foundation
import SwiftUI

// 2. Type extensions
extension MyType { }

// 3. Main type definition
struct MyView: View {
  // 4. Property wrappers (@State, @Observable, etc.)
  // 5. Stored properties
  // 6. Computed properties
  // 7. Body
  // 8. Helper methods
  // 9. Nested types
}

// 10. Previews (if applicable)
```

---

## Swift 6 & Modern Patterns (REQUIRED)

### ✅ DO: Modern Patterns

#### 1. Use @Observable instead of ObservableObject
```swift
// ✅ CORRECT (Modern)
@MainActor
@Observable
class ViewModel {
  var items = [Item]()
  var isLoading = false
}

// ❌ WRONG (Old pattern - being phased out)
class ViewModel: ObservableObject {
  @Published var items = [Item]()
}
```

#### 2. Use @MainActor for UI ViewModels
```swift
// ✅ CORRECT
@MainActor
@Observable
class GitHubViewModel {
  var repositories = [Repository]()
  
  func loadData() async {
    // Already on main actor, direct assignment
    repositories = await fetchRepositories()
  }
}

// ❌ WRONG
class GitHubViewModel: ObservableObject {
  @Published var repositories = [Repository]()
  
  func loadData() async {
    let data = await fetchRepositories()
    DispatchQueue.main.async {
      self.repositories = data
    }
  }
}
```

#### 3. Use NavigationStack (not NavigationView)
```swift
// ✅ CORRECT
NavigationStack(path: $navigationPath) {
  List(items) { item in
    NavigationLink(value: item) {
      ItemRow(item: item)
    }
  }
  .navigationDestination(for: Item.self) { item in
    ItemDetailView(item: item)
  }
}

// ❌ WRONG (Deprecated)
NavigationView {
  List(items) { item in
    NavigationLink(destination: ItemDetailView(item: item)) {
      ItemRow(item: item)
    }
  }
}
```

#### 4. Use Actors for Thread-Safe Data
```swift
// ✅ CORRECT
actor NetworkService {
  private var cache = [String: Data]()
  
  func fetchData(url: String) async throws -> Data {
    if let cached = cache[url] { return cached }
    let data = try await URLSession.shared.data(from: URL(string: url)!).0
    cache[url] = data
    return data
  }
}

// ❌ WRONG
class NetworkService {
  private var cache = [String: Data]()
  private let queue = DispatchQueue(label: "network")
  // Manual synchronization complexity...
}
```

#### 5. Use Structured Concurrency
```swift
// ✅ CORRECT (Parallel loading)
async let repos = loadRepositories()
async let user = loadUser()
async let orgs = loadOrganizations()

let (repositories, currentUser, organizations) = await (repos, user, orgs)

// ❌ WRONG (Sequential - slower)
let repositories = await loadRepositories()
let currentUser = await loadUser()
let organizations = await loadOrganizations()
```

#### 6. Proper Error Handling
```swift
// ✅ CORRECT
enum LoadingState<T> {
  case idle
  case loading
  case loaded(T)
  case error(Error)
}

@MainActor
@Observable
class ViewModel {
  var state: LoadingState<[Item]> = .idle
  
  func load() async {
    state = .loading
    do {
      let items = try await fetchItems()
      state = .loaded(items)
    } catch {
      state = .error(error)
    }
  }
}

// ❌ WRONG
@Published var items = [Item]()
@Published var isLoading = false
// Lost error information
```

### ❌ DON'T: Deprecated Patterns

#### Avoid Combine (unless interfacing with existing APIs)
```swift
// ❌ AVOID
import Combine
var cancellables = Set<AnyCancellable>()
$searchText
  .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
  .sink { ... }

// ✅ PREFER
var searchTask: Task<Void, Never>?
func updateSearch(_ text: String) {
  searchTask?.cancel()
  searchTask = Task {
    try? await Task.sleep(for: .seconds(0.3))
    guard !Task.isCancelled else { return }
    await performSearch(text)
  }
}
```

#### Avoid Manual DispatchQueue.main
```swift
// ❌ AVOID
DispatchQueue.main.async {
  self.items = newItems
}

// ✅ PREFER
@MainActor
func updateItems(_ newItems: [Item]) {
  items = newItems
}
```

#### Avoid @StateObject/@ObservedObject for New Code
```swift
// ❌ OLD
@StateObject var viewModel = ViewModel()
@ObservedObject var settings: Settings

// ✅ NEW
@State var viewModel = ViewModel()
@Environment(Settings.self) var settings
```

---

## Security Best Practices

### Sensitive Data Storage
```swift
// ✅ CORRECT - Use Keychain for tokens/credentials
actor KeychainService {
  func save(_ value: String, for key: String) throws {
    // Use Security framework
  }
}

// ❌ WRONG - Never store tokens in UserDefaults
@AppStorage("github-token") var token = ""
```

### OAuth Tokens
- Always use Keychain for OAuth tokens
- Never log tokens or sensitive data
- Use HTTPS for all API calls
- Validate SSL certificates

---

## Project-Specific Patterns

### GitHub API Calls
```swift
// Prefer async/await URLSession over Alamofire for new code
actor GitHubAPI {
  private let baseURL = "https://api.github.com"
  
  func fetch<T: Decodable>(_ endpoint: String) async throws -> T {
    let url = URL(string: baseURL + endpoint)!
    var request = URLRequest(url: url)
    request.addValue("token \(token)", forHTTPHeaderField: "Authorization")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse,
          (200...299).contains(http.statusCode) else {
      throw APIError.badResponse
    }
    
    return try JSONDecoder().decode(T.self, from: data)
  }
}
```

### SwiftUI View Structure
```swift
struct MyView: View {
  // 1. Environment and state
  @Environment(\.dismiss) var dismiss
  @State private var viewModel = ViewModel()
  
  // 2. View body
  var body: some View {
    contentView
      .navigationTitle("Title")
      .toolbar { toolbarContent }
      .task { await viewModel.load() }
  }
  
  // 3. Extracted computed views (for readability)
  private var contentView: some View {
    switch viewModel.state {
    case .idle, .loading: ProgressView()
    case .loaded(let items): ListView(items: items)
    case .error(let error): ErrorView(error: error)
    }
  }
  
  // 4. Toolbar builders
  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button("Refresh") { Task { await viewModel.load() } }
    }
  }
}
```

---

## Common Tasks

### When Adding a New Feature
1. Check `/Plans/` for relevant architecture decisions
2. Follow existing patterns in the package/feature
3. Use modern Swift 6/SwiftUI 6 patterns
4. Add error handling
5. Consider both macOS and iOS if applicable

### RAG Pattern Check (Preferred)
- After meaningful edits, run the Local RAG pattern check:
  - `Tools/PeelCLI/.build/debug/peel-mcp rag-pattern-check --repo-path /path/to/repo`
- Use the results to avoid reintroducing deprecated patterns.

### When Refactoring
1. Check `SWIFTUI_MODERNIZATION_PLAN.md` for migration patterns
2. Update one file/component at a time
3. Prefer @Observable over ObservableObject
4. Replace NavigationView with NavigationStack
5. Remove Combine if possible
6. Add @MainActor where appropriate

### When Reviewing Code
- Look for deprecated patterns (NavigationView, ObservableObject, Combine)
- Check for DispatchQueue.main.async (should be @MainActor)
- Verify token storage uses Keychain (not UserDefaults)
- Ensure proper error handling
- Check actor isolation compliance

---

## Anti-Patterns to Avoid

### ❌ Singleton ViewModels
```swift
// ❌ AVOID
class ViewModel: ObservableObject {
  static let shared = ViewModel()
}

// ✅ PREFER - Environment injection
@Environment(ViewModel.self) var viewModel
```

### ❌ Force Unwrapping
```swift
// ❌ AVOID
let url = URL(string: urlString)!

// ✅ PREFER
guard let url = URL(string: urlString) else {
  throw URLError(.badURL)
}
```

### ❌ try! and forced error suppression
```swift
// ❌ AVOID
let data = try! JSONEncoder().encode(value)

// ✅ PREFER
do {
  let data = try JSONEncoder().encode(value)
  // handle data
} catch {
  logger.error("Encoding failed: \(error)")
  // handle error
}
```

### ❌ Commented-out code
```swift
// ❌ AVOID - Delete instead of commenting
// class OldViewModel: ObservableObject {
//   @Published var data = [Item]()
// }

// ✅ PREFER - Use version control, delete dead code
```

---

## Testing Considerations

- ViewModels should be testable without UI
- Use @MainActor for UI-related tests
- Mock network calls with protocols/actors
- Test error states and edge cases
- Verify accessibility labels

---

## Performance Guidelines

- Use `.task { }` for view lifecycle async work
- Prefer `LazyVStack/LazyHStack` for large lists
- Use `@Environment` for shared state (not singleton)
- Profile before optimizing
- Consider `@Observable` performance benefits over `@Published`

---

## Accessibility

- Always provide accessibility labels for images/icons
- Use semantic colors (`.primary`, `.secondary`) 
- Test with VoiceOver
- Support keyboard navigation
- Respect Dynamic Type

---

## Platform Differences

### macOS-specific
- Use `#if os(macOS)` for macOS-only features
- Toolbar placement: `.navigation`, `.primaryAction`
- Window management with WindowGroup

### iOS-specific  
- Use `#if os(iOS)` for iOS-only features
- Consider iPad split view
- Toolbar placement: `.bottomBar`, `.navigationBarTrailing`

### Shared
- Prefer shared code in `/Shared/`
- Use platform checks only when necessary
- Test on both platforms

---

## Quick Reference

**Before starting work:**
1. Read `/Plans/SWIFTUI_MODERNIZATION_PLAN.md`
2. Check for existing similar code
3. Follow Swift 6 concurrency patterns
4. Use 2-space indentation

**When stuck:**
1. Check this file for patterns
2. Review similar existing code
3. Consult the modernization plan
4. Ask before introducing new dependencies

**Before committing:**
1. Remove commented code
2. Check for deprecated APIs
3. Verify actor isolation
4. Test on both platforms (if applicable)

---

## Resources

- [Swift 6 Migration Guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/)
- [Observation Framework](https://developer.apple.com/documentation/observation)
- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
- Project plans in `/Plans/`

---

**Last Updated:** January 5, 2026  
**Modernization Status:** In Progress - See SWIFTUI_MODERNIZATION_PLAN.md

---

## SwiftData & iCloud Sync

### CloudKit Compatibility Requirements
When creating or modifying `@Model` classes for SwiftData with iCloud sync:

```swift
// ✅ CORRECT - CloudKit compatible
@Model
final class MyModel {
  var id: UUID = UUID()           // Default value required
  var name: String = ""           // Default value required  
  var count: Int = 0              // Default value required
  var optionalField: String?      // Optional is fine
  var createdAt: Date = Date()    // Default value required
}

// ❌ WRONG - Will crash with CloudKit
@Model
final class MyModel {
  @Attribute(.unique) var id: UUID  // No unique constraints!
  var name: String                   // No default = crash
  var count: Int                     // No default = crash
}
```

**CloudKit Rules:**
1. **No `@Attribute(.unique)`** - CloudKit doesn't support unique constraints
2. **All non-optional properties must have default values**
3. **No relationships with delete rules** - Use UUID references instead
4. **Test locally first** with `cloudKitDatabase: .none` before enabling `.automatic`

### iCloud Configuration
- Entitlements are in `macOS/macOS.entitlements`
- Container ID: `iCloud.crunchy-bananas.Peel`
- SwiftData config in `PeelApp.swift` uses `cloudKitDatabase: .automatic`

---

## Agent Tool Usage

### MCP Validation & Test Runs (IMPORTANT)
- For validation/tests (MCP runs, screenshot checks, harness tests), **use free/low-cost models only**.
- Prefer templates that are explicitly low-cost (e.g., Free Review) and avoid premium models unless the user explicitly requests them.

### File Verification
When editing files, the tool cache may show stale content. If you suspect a file wasn't updated:

```bash
# Always verify with terminal commands
cat /path/to/file | head -20
grep "specific text" /path/to/file
tail -10 /path/to/file
```

### When Replacements Fail
If `replace_string_in_file` reports success but the file hasn't changed:
1. Use `sed` or direct file manipulation via terminal
2. Verify changes with `grep` or `cat`
3. Don't repeatedly try the same replacement

```bash
# Direct sed replacement
sed -i '' 's/old text/new text/' /path/to/file

# Verify
grep "new text" /path/to/file
```

### App Launching & Testing
**Normal development:** do **not** launch the app from terminal. The user should run from Xcode.

Why:
- Launching from terminal doesn't attach the debugger properly
- User needs to see console output in Xcode
- ViewBridge/RemoteViewService errors occur when launched externally

**MCP development/testing:** it is OK to launch via the script, since MCP requires the app to be running.
Use `Tools/build-and-launch.sh --wait-for-server` (or `--skip-build` if a build already exists).
The script now **refuses to relaunch** if MCP chains are running or if Peel is running but MCP is unresponsive, unless you pass `--allow-while-chains-running`.

Normal dev flow:
1. Build the project: `xcodebuild -scheme "Peel (macOS)" build`
2. Tell the user the build succeeded
3. Let the user run from Xcode with ⌘R

MCP flow:
1. Run `Tools/build-and-launch.sh --wait-for-server`
2. Use `Tools/PeelCLI` to call MCP endpoints
3. Stop the server or quit the app when done
4. If chains are running, avoid relaunching; use `--skip-build` or wait until chains finish

```bash
# ✅ DO: Just build (normal dev)
xcodebuild -scheme "Peel (macOS)" -destination 'platform=macOS' build

# ✅ DO: Launch via script (MCP dev/testing)
./Tools/build-and-launch.sh --wait-for-server

# ❌ DON'T: Launch the app
# open "/path/to/Kitchen Sync.app"  # Don't do this
# pkill -f "Kitchen Sync"           # Don't do this
```

---

## GitHub CLI Quick Reference

```bash
# Issues
gh issue list --repo cloke/peel
gh issue view <number> --repo cloke/peel
gh issue create --repo cloke/peel --title "Title" --body "Description"
gh issue close <number> --repo cloke/peel

# Project Board
gh project item-list 1 --owner cloke --format json
gh project view 1 --owner cloke --web

# PRs
gh pr create --title "Title" --body "Closes #X"
gh pr list --repo cloke/peel
gh pr merge <number>
```

---

**Last Updated:** January 18, 2026  
**Modernization Status:** Complete - See Plans/Archive/MODERNIZATION_COMPLETE.md