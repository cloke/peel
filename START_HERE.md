# 🚀 Quick Start - Peel

**Last Updated:** January 16, 2026  
**Status:** ✅ Modernization Complete | Active Development

---

## What is Peel?

A macOS/iOS developer tools app for managing:
- **GitHub** - Repos, PRs, issues, actions (works on iOS too!)
- **Git** - Local repo management, commits, branches (macOS only)
- **Homebrew** - Package management with streaming output (macOS only)
- **AI Agents** - Orchestrated coding agents with VM isolation (macOS only)
- **Workspaces** - Multi-worktree management (macOS only)

---

## Quick Start (2 minutes)

### Build & Run
```bash
# From Xcode - recommended
# Open KitchenSync.xcodeproj and press Cmd+R

# Or from terminal (build only - run from Xcode for debugging)
cd /Users/cloken/code/KitchenSink
xcodebuild -scheme "Peel (macOS)" -configuration Debug build
```

### First Time Setup
1. **GitHub** - Click login, authorize OAuth, token saved to Keychain
2. **Git** - Open a local repository folder
3. **Brew** - Just works (requires Homebrew installed)

---

## Project Structure

```
KitchenSink/
├── Shared/                    # Cross-platform code
│   ├── PeelApp.swift          # App entry point, SwiftData
│   ├── Applications/          # Root views for each tool
│   ├── AgentOrchestration/    # AI agent management
│   ├── Services/              # Shared services
│   └── Views/                 # Reusable UI components
├── Local Packages/
│   ├── Brew/                  # Homebrew integration
│   ├── Git/                   # Git operations
│   └── Github/                # GitHub API + UI
├── iOS/                       # iOS-specific entry
├── macOS/                     # macOS-specific entry
└── Plans/                     # Architecture docs
```

---

## Key Documentation

| Document | Purpose |
|----------|---------|
| [Plans/CODE_AUDIT_INDEX.md](Plans/CODE_AUDIT_INDEX.md) | File status tracking, anti-patterns |
| [Plans/MODERNIZATION_COMPLETE.md](Plans/MODERNIZATION_COMPLETE.md) | What was modernized |
| [Plans/AGENT_ORCHESTRATION_PLAN.md](Plans/AGENT_ORCHESTRATION_PLAN.md) | AI agent architecture |
| [Plans/SESSION_JAN16.md](Plans/SESSION_JAN16.md) | Current session notes |
| [.github/copilot-instructions.md](.github/copilot-instructions.md) | Coding standards |

---

## Tech Stack

- **Swift 6.0** with strict concurrency
- **SwiftUI 6.0** with @Observable pattern
- **SwiftData** with iCloud sync (CloudKit)
- **Targets:** macOS 26 (Tahoe), iOS 26

### Patterns Used
- `@MainActor @Observable` for ViewModels
- `actor` for thread-safe services
- `async/await` throughout (no Combine)
- `NavigationStack`/`NavigationSplitView` (not NavigationView)

---

## Development Notes

### Before Making Changes
1. Check [Plans/CODE_AUDIT_INDEX.md](Plans/CODE_AUDIT_INDEX.md) for existing patterns
2. Follow [.github/copilot-instructions.md](.github/copilot-instructions.md)
3. Search codebase before creating new components

### Testing
- Run from Xcode (Cmd+R) for proper debugging
- Check both macOS and iOS targets
- Verify iCloud sync if touching SwiftData models

---

## Current Focus Areas

See [Plans/SESSION_JAN16.md](Plans/SESSION_JAN16.md) for active work:
- Swift 6 strict concurrency (complete)
- iOS TabView navigation (complete)
- VM isolation for agents (in progress)
- Code audit and cleanup (in progress)
