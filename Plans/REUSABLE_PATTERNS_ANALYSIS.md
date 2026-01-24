# Reusable Patterns Analysis

**Date:** January 24, 2026  
**Status:** Analysis Complete

## Executive Summary

After a deep dive into the Peel codebase, I've identified **7 major patterns** where code could be consolidated. Implementing these would reduce boilerplate by an estimated **20-30%** across the UI layer.

---

## 1. Async Data Loading Pattern (HIGH IMPACT)

### Current State
Every view that loads data reimplements the same pattern:

```swift
// This pattern appears 15+ times across the codebase
@State private var isLoading = true
@State private var error: String?
@State private var data = [SomeType]()

var body: some View {
  if isLoading {
    ProgressView()
  } else if let error {
    VStack { Text(error); Button("Retry") { ... } }
  } else if data.isEmpty {
    ContentUnavailableView(...)
  } else {
    List(data) { ... }
  }
}
.task {
  isLoading = true
  defer { isLoading = false }
  do {
    data = try await loadData()
  } catch {
    self.error = error.localizedDescription
  }
}
```

**Files with this pattern:**
- [Github_RootView.swift](../Shared/Applications/Github_RootView.swift) (3 places)
- [PullRequestsView.swift](../Local%20Packages/Github/Sources/Github/Views/PullRequests/PullRequestsView.swift)
- [IssuesListView.swift](../Local%20Packages/Github/Sources/Github/Views/Issues/IssuesListView.swift)
- [ActionsListView.swift](../Local%20Packages/Github/Sources/Github/Views/Actions/ActionsListView.swift)
- [PersonalView.swift](../Local%20Packages/Github/Sources/Github/Views/PersonalView.swift)
- [RepositoryInsightsView.swift](../Local%20Packages/Github/Sources/Github/Views/Repositories/RepositoryInsightsView.swift)
- [OrganizationRepositoryView.swift](../Local%20Packages/Github/Sources/Github/Views/Organizations/OrganizationRepositoryView.swift)
- [WorktreeListView.swift](../Local%20Packages/Git/Sources/Git/WorktreeListView.swift)

### Proposed Solution

Already have `ViewState<T>` in [ViewState.swift](../Shared/Components/ViewState.swift) - but it's not being used! Extend it:

```swift
// ViewState.swift - Enhanced
public enum ViewState<T> {
  case idle
  case loading
  case loaded(T)
  case error(Error)
}

/// Reusable async view that handles loading states
public struct AsyncContentView<T, Content: View, Loader: View, Empty: View>: View {
  @State private var state: ViewState<T> = .idle
  let load: () async throws -> T
  let isEmpty: (T) -> Bool
  @ViewBuilder let content: (T) -> Content
  @ViewBuilder let loadingView: () -> Loader
  @ViewBuilder let emptyView: () -> Empty
  
  public var body: some View {
    switch state {
    case .idle:
      Color.clear.task { await performLoad() }
    case .loading:
      loadingView()
    case .loaded(let data):
      if isEmpty(data) {
        emptyView()
      } else {
        content(data)
      }
    case .error(let error):
      ErrorView(message: error.localizedDescription) {
        Task { await performLoad() }
      }
    }
  }
  
  private func performLoad() async {
    state = .loading
    do {
      state = .loaded(try await load())
    } catch {
      state = .error(error)
    }
  }
}

// Convenience for array data
extension AsyncContentView where T: Collection {
  init(
    load: @escaping () async throws -> T,
    @ViewBuilder content: @escaping (T) -> Content,
    @ViewBuilder loadingView: @escaping () -> Loader = { ProgressView() },
    @ViewBuilder emptyView: @escaping () -> Empty
  ) {
    self.load = load
    self.isEmpty = { $0.isEmpty }
    self.content = content
    self.loadingView = loadingView
    self.emptyView = emptyView
  }
}
```

**Usage (before → after):**

```swift
// BEFORE: 35 lines
struct PullRequestsView: View {
  @State private var pullRequests = [Github.PullRequest]()
  @State private var isLoading = true
  let repository: Github.Repository
  
  var body: some View {
    VStack {
      if isLoading {
        ProgressView()
      } else if !pullRequests.isEmpty {
        PullRequestListView(pullRequests: pullRequests)
      } else {
        Text("No Pull Requests Found")
      }
    }
    .task(id: repository.id) {
      isLoading = true
      defer { isLoading = false }
      do {
        pullRequests = try await Github.pullRequests(from: repository)
      } catch { }
    }
  }
}

// AFTER: 15 lines
struct PullRequestsView: View {
  let repository: Github.Repository
  
  var body: some View {
    AsyncContentView(
      load: { try await Github.pullRequests(from: repository) },
      content: { PullRequestListView(pullRequests: $0) },
      emptyView: { Text("No Pull Requests Found") }
    )
    .id(repository.id) // Reloads when repo changes
  }
}
```

**Estimated savings:** ~200-300 lines across 15+ views

---

## 2. MCP UI Action Handler Pattern (MEDIUM IMPACT)

### Current State
Every root view has an identical `.onChange(of: mcpServer.lastUIAction?.id)` block:

```swift
// This pattern appears in 5+ root views
.onChange(of: mcpServer.lastUIAction?.id) {
  guard let action = mcpServer.lastUIAction else { return }
  switch action.controlId {
  case "someAction":
    doSomething()
    mcpServer.recordUIActionHandled(action.controlId)
  // ... many cases ...
  default:
    break
  }
  mcpServer.lastUIAction = nil
}
```

**Files:**
- [Agents_RootView.swift](../Shared/Applications/Agents_RootView.swift#L57-L100)
- [Github_RootView.swift](../Shared/Applications/Github_RootView.swift#L194-L217)
- [Git_RootView.swift](../Shared/Applications/Git_RootView.swift#L73-L88)
- [Workspaces_RootView.swift](../Shared/Applications/Workspaces_RootView.swift#L85-L122)

### Proposed Solution

Create a view modifier with a declarative action map:

```swift
// MCPActionHandler.swift
struct MCPActionMapping {
  let controlId: String
  let action: () -> Void
}

struct MCPActionHandlerModifier: ViewModifier {
  @Environment(MCPServerService.self) private var mcpServer
  let mappings: [MCPActionMapping]
  
  func body(content: Content) -> some View {
    content.onChange(of: mcpServer.lastUIAction?.id) {
      guard let uiAction = mcpServer.lastUIAction else { return }
      if let mapping = mappings.first(where: { $0.controlId == uiAction.controlId }) {
        mapping.action()
        mcpServer.recordUIActionHandled(uiAction.controlId)
      }
      mcpServer.lastUIAction = nil
    }
  }
}

extension View {
  func mcpActions(_ mappings: [MCPActionMapping]) -> some View {
    modifier(MCPActionHandlerModifier(mappings: mappings))
  }
}
```

**Usage:**

```swift
// BEFORE: 25 lines of switch statement
.onChange(of: mcpServer.lastUIAction?.id) { ... switch ... }

// AFTER: Declarative
.mcpActions([
  MCPActionMapping("git.openRepository") { addRepository() },
  MCPActionMapping("git.cloneRepository") { isCloning = true },
  MCPActionMapping("git.openInVSCode") { openInVSCode() }
])
```

---

## 3. List Row Patterns (MEDIUM IMPACT)

### Current State
Many list rows follow the same layout: icon + primary text + secondary info:

```swift
// Similar patterns in:
// - ParallelRunRow
// - AgentRowView
// - RepoRow
// - WorkspaceRow
// - IssueListItemView
// - CommitsListItemView

HStack {
  statusIcon
  VStack(alignment: .leading, spacing: 4) {
    Text(primaryText).fontWeight(.medium)
    Text(secondaryText).font(.caption).foregroundStyle(.secondary)
  }
  Spacer()
  accessoryView
}
```

### Proposed Solution

```swift
struct ListRowLayout<Icon: View, Accessory: View>: View {
  let title: String
  let subtitle: String?
  @ViewBuilder let icon: () -> Icon
  @ViewBuilder let accessory: () -> Accessory
  
  var body: some View {
    HStack(spacing: 12) {
      icon()
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.medium)
        if let subtitle {
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      accessory()
    }
    .padding(.vertical, 4)
  }
}
```

---

## 4. Model Picker Pattern (MEDIUM IMPACT)

### Current State
The CopilotModel picker is duplicated across 4+ places with identical grouping:

```swift
// Appears in: AgentDetailView, NewAgentSheet, NewChainSheet, and more
Picker("Model", selection: $model) {
  Section("Free") {
    ForEach(CopilotModel.allCases.filter { $0.isFree }) { m in
      ModelLabelView(model: m).tag(m)
    }
  }
  Section("Claude") {
    ForEach(CopilotModel.allCases.filter { $0.isClaude }) { m in
      ModelLabelView(model: m).tag(m)
    }
  }
  Section("GPT") {
    ForEach(CopilotModel.allCases.filter { $0.isGPT && !$0.isFree }) { m in
      ModelLabelView(model: m).tag(m)
    }
  }
  Section("Gemini") {
    ForEach(CopilotModel.allCases.filter { $0.isGemini && !$0.isFree }) { m in
      ModelLabelView(model: m).tag(m)
    }
  }
}
```

### Proposed Solution

```swift
// CopilotModelPicker.swift
struct CopilotModelPicker: View {
  @Binding var selection: CopilotModel
  var showFree: Bool = true
  
  var body: some View {
    Picker("Model", selection: $selection) {
      if showFree {
        Section("Free") {
          ForEach(CopilotModel.allCases.filter { $0.isFree }) { m in
            ModelLabelView(model: m).tag(m)
          }
        }
      }
      Section("Claude") {
        ForEach(CopilotModel.allCases.filter { $0.isClaude }) { m in
          ModelLabelView(model: m).tag(m)
        }
      }
      Section("GPT") {
        ForEach(CopilotModel.allCases.filter { $0.isGPT && !$0.isFree }) { m in
          ModelLabelView(model: m).tag(m)
        }
      }
      Section("Gemini") {
        ForEach(CopilotModel.allCases.filter { $0.isGemini && !$0.isFree }) { m in
          ModelLabelView(model: m).tag(m)
        }
      }
    }
  }
}
```

---

## 5. Destination Loading Pattern (HIGH IMPACT)

### Current State
Multiple destination views load data on appear with identical boilerplate:

```swift
// FavoriteRepositoryDestination, RecentPRDestination, OrganizationDetailView, etc.
struct SomeDestination: View {
  @State private var isLoading = true
  @State private var error: String?
  @State private var data: SomeType?
  
  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading...")
      } else if let error {
        VStack { Text("Failed"); Text(error); Button("Retry") { ... } }
      } else if let data {
        ActualContent(data: data)
      }
    }
    .task { await load() }
  }
  
  private func load() async {
    isLoading = true
    error = nil
    do {
      data = try await fetchData()
    } catch {
      self.error = error.localizedDescription
    }
    isLoading = false
  }
}
```

### Proposed Solution
Use the `AsyncContentView` from Pattern #1, or create a specialized `LoadingDestination`:

```swift
struct LoadingDestination<T, Content: View>: View {
  let loadingTitle: String
  let load: () async throws -> T
  @ViewBuilder let content: (T) -> Content
  
  @State private var state: ViewState<T> = .loading
  
  var body: some View {
    switch state {
    case .idle, .loading:
      ProgressView(loadingTitle)
        .task { await performLoad() }
    case .loaded(let data):
      content(data)
    case .error(let message):
      ErrorView(message: message) {
        Task { await performLoad() }
      }
    }
  }
}
```

---

## 6. Sheet Patterns (MEDIUM IMPACT)

### Current State
Many sheets follow the same structure:

```swift
struct SomeSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var field1 = ""
  @State private var field2 = ""
  
  var body: some View {
    NavigationStack {
      Form { ... }
      .formStyle(.grouped)
      .navigationTitle("Title")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") { ... }
            .disabled(!isValid)
        }
      }
    }
    .frame(minWidth: 400, minHeight: 300)
  }
}
```

### Proposed Solution

```swift
struct FormSheet<Content: View>: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let confirmText: String
  let isConfirmEnabled: Bool
  let onConfirm: () -> Void
  @ViewBuilder let content: () -> Content
  
  var body: some View {
    NavigationStack {
      Form { content() }
      .formStyle(.grouped)
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(confirmText) { onConfirm(); dismiss() }
            .disabled(!isConfirmEnabled)
        }
      }
    }
    .frame(minWidth: 400, minHeight: 300)
  }
}
```

---

## 7. UserDefaults/AppStorage Sync Pattern (LOW IMPACT)

### Current State
Several views sync selection state to UserDefaults with onChange handlers:

```swift
@AppStorage("some.selectedKey") private var selectedKey: String = ""

.onChange(of: someSelection) { _, newValue in
  if selectedKey != newValue { selectedKey = newValue }
}
.onChange(of: selectedKey) { _, _ in
  syncFromStorage()
}
```

**Files:**
- Git_RootView.swift
- Github_RootView.swift  
- Workspaces_RootView.swift

### Proposed Solution
Consider creating a property wrapper or binding helper that handles bidirectional sync automatically.

---

## Implementation Priority

| Pattern | Impact | Effort | Priority |
|---------|--------|--------|----------|
| 1. AsyncContentView | High | Medium | **P1** |
| 5. LoadingDestination | High | Low | **P1** |
| 2. MCP Action Handler | Medium | Low | **P2** |
| 4. Model Picker | Medium | Low | **P2** |
| 6. Form Sheet | Medium | Medium | **P2** |
| 3. List Row Layout | Medium | Medium | **P3** |
| 7. UserDefaults Sync | Low | Medium | **P3** |

---

## Recommended First Steps

1. **Extend `ViewState.swift`** with `AsyncContentView` 
2. **Refactor one view as a pilot** (suggestion: `PullRequestsView` - simple, isolated)
3. **Create `CopilotModelPicker`** (quick win, eliminates 80+ lines)
4. **Create `MCPActionHandlerModifier`** (removes switch boilerplate from 5 views)

---

## Appendix: Files That Would Benefit Most

1. **[Github_RootView.swift](../Shared/Applications/Github_RootView.swift)** - 765 lines, could drop to ~500
2. **[Workspaces_RootView.swift](../Shared/Applications/Workspaces_RootView.swift)** - 1087 lines, heavy boilerplate
3. **[ParallelWorktreeDashboardView.swift](../Shared/Applications/Agents/ParallelWorktreeDashboardView.swift)** - 876 lines
4. **[PersonalView.swift](../Local%20Packages/Github/Sources/Github/Views/PersonalView.swift)** - 448 lines, lots of loading state
5. **[ActionsListView.swift](../Local%20Packages/Github/Sources/Github/Views/Actions/ActionsListView.swift)** - repeated patterns
