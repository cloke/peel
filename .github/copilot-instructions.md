# GitHub Copilot Instructions for Peel

## Project Context

Peel is a macOS/iOS SwiftUI application for managing GitHub, Git repositories, and Homebrew. "Peel back the layers" of your dev environment.

**Targets:** macOS 26 (Tahoe), iOS 26  
**Swift Version:** 6.0  
**Status:** Active development - refer to `/Plans/SWIFTUI_MODERNIZATION_PLAN.md`

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
**DO NOT launch the app from terminal.** The user will run the app themselves from Xcode.

Why:
- Launching from terminal doesn't attach the debugger properly
- User needs to see console output in Xcode
- ViewBridge/RemoteViewService errors occur when launched externally

Instead:
1. Build the project: `xcodebuild -scheme "KitchenSink (macOS)" build`
2. Tell the user the build succeeded
3. Let the user run from Xcode with ⌘R

```bash
# ✅ DO: Just build
xcodebuild -scheme "KitchenSink (macOS)" -destination 'platform=macOS' build

# ❌ DON'T: Launch the app
# open "/path/to/Kitchen Sync.app"  # Don't do this
# pkill -f "Kitchen Sync"           # Don't do this
```

---

**Last Updated:** January 9, 2026  
**Modernization Status:** Complete - See MODERNIZATION_COMPLETE.md
