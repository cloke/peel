# Peel

Peel back the layers of your dev environment. A macOS/iOS developer tools app for managing GitHub, Git repositories, Homebrew, and AI coding agents.

**Status:** ✅ Active Development  
**Swift:** 6.0 with strict concurrency  
**Targets:** macOS 26, iOS 26

---

## Features

| Feature | macOS | iOS | Description |
|---------|-------|-----|-------------|
| **GitHub** | ✅ | ✅ | Repos, PRs, issues, actions, OAuth |
| **Git** | ✅ | ❌ | Local repo management, commits, branches |
| **Homebrew** | ✅ | ❌ | Package search, install with streaming output |
| **AI Agents** | ✅ | ❌ | Orchestrated coding agents with VM isolation |
| **Workspaces** | ✅ | ❌ | Multi-worktree management |

---

## Quick Start

```bash
# Open in Xcode and press Cmd+R
open Peel.xcodeproj
```

See [START_HERE.md](START_HERE.md) for detailed setup.

---

## Project Structure

```
KitchenSink/
├── Shared/                    # Cross-platform SwiftUI code
│   ├── PeelApp.swift          # Entry point, SwiftData config
│   ├── Applications/          # Root views (Git, Brew, GitHub, Agents, Workspaces)
│   ├── AgentOrchestration/    # AI agent management system
│   ├── Services/              # Shared services (VSCode, etc.)
│   └── Views/                 # Reusable components
├── Local Packages/
│   ├── Brew/                  # Homebrew package management
│   ├── Git/                   # Git operations and UI
│   └── Github/                # GitHub API client and UI
├── iOS/                       # iOS app entry point
├── macOS/                     # macOS app entry point
└── Plans/                     # Architecture documentation
```

---

## Architecture

### Modern Swift 6 Patterns

This codebase follows Swift 6 and SwiftUI 6 best practices:

```swift
// ViewModels use @Observable (not ObservableObject)
@MainActor
@Observable
class ViewModel {
  var items = [Item]()
  
  func load() async {
    items = await fetchItems()
  }
}

// Thread-safe services use actors
actor KeychainService {
  func save(_ token: String) throws { ... }
}

// Navigation uses NavigationStack (not NavigationView)
NavigationStack {
  List(items) { item in
    NavigationLink(value: item) { ... }
  }
  .navigationDestination(for: Item.self) { ... }
}
```

### Data Persistence

| Data Type | Storage | Sync |
|-----------|---------|------|
| OAuth tokens | Keychain | ❌ |
| User preferences | @AppStorage | ❌ |
| Favorites, history | SwiftData | ✅ iCloud |

---

## Documentation

| Document | Description |
|----------|-------------|
| [START_HERE.md](START_HERE.md) | Quick start guide |
| [Plans/CODE_AUDIT_INDEX.md](Plans/CODE_AUDIT_INDEX.md) | File review tracking |
| [Plans/AGENT_ORCHESTRATION_PLAN.md](Plans/AGENT_ORCHESTRATION_PLAN.md) | AI agent architecture |
| [.github/copilot-instructions.md](.github/copilot-instructions.md) | Coding standards |

---

## Development

### Prerequisites
- Xcode 16+ 
- macOS 26 SDK
- Homebrew (for Brew features)

### Building
```bash
# Build for macOS
xcodebuild -scheme "Peel (macOS)" build

# Build for iOS
xcodebuild -scheme "Peel (iOS)" -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Code Quality

Before committing, check for deprecated patterns:
```bash
# Should return no results
grep -r "ObservableObject\|@Published\|@StateObject\|NavigationView" --include="*.swift" .
```

See [Plans/CODE_AUDIT_INDEX.md](Plans/CODE_AUDIT_INDEX.md) for the full audit checklist.

---

## Roadmap

### Completed ✅
- Swift 6 modernization (all packages)
- SwiftData + iCloud sync
- iOS support (GitHub features)
- VM isolation foundation

### Future 📋
- Apple Intelligence integration
- Metal GPU acceleration for agents
- Distributed actors across devices

---

## License

Private project - not for distribution.
