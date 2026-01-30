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
# Open Peel.xcodeproj and press Cmd+R

# Or from terminal (build only - run from Xcode for debugging)
cd /Users/cloken/code/KitchenSink
xcodebuild -scheme "Peel (macOS)" -configuration Debug build
```

### First Time Setup
1. **GitHub** - Click login, authorize OAuth, token saved to Keychain
2. **Git** - Open a local repository folder
3. **Brew** - Just works (requires Homebrew installed)

### Optional: Local RAG Core ML Embeddings
Core ML embedding artifacts are **not** committed. To use CodeBERT embeddings locally, see Docs/guides/LOCAL_RAG_MODEL_CATALOG.md.

1. Generate the Core ML model and vocab:
```bash
python3 Tools/ModelTools/convert_codebert_to_coreml.py --model codebert-base-256
```

2. Compile and copy assets into app support:
```bash
xcrun coremlc compile Tools/ModelTools/output/codebert-base-256.mlpackage Tools/ModelTools/output
mkdir -p "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models"
cp -R Tools/ModelTools/output/codebert-base-256.mlmodelc "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/"
cp Tools/ModelTools/output/codebert-base.vocab.json "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/"
cp Tools/ModelTools/output/tokenize_codebert.py "$HOME/Library/Containers/crunchy-bananas.Peel/Data/Library/Application Support/Peel/RAG/Models/"
```

3. Restart Peel and check Agents → Local RAG. `rag.status` should report `CoreMLEmbeddingProvider`.

### Optional: sqlite-vec Extension (Accelerated Vector Search)

The app bundles a custom SQLite build with extension loading support. To enable sqlite-vec:

1. Download `vec0.dylib` for macOS ARM64 from [sqlite-vec releases](https://github.com/asg017/sqlite-vec/releases)

2. **Sign the dylib** (required for macOS to load it):
```bash
security find-identity -v -p codesigning  # List identities
codesign -f -s "Apple Development: Your Name (XXXXXXXXXX)" vec0.dylib
```

3. **Install to Application Support** (NOT the project folder!):
```bash
mkdir -p "$HOME/Library/Application Support/Peel/Extensions"
cp vec0.dylib "$HOME/Library/Application Support/Peel/Extensions/"
```

4. Restart Peel. Check `rag.status` - it should report `extensionLoaded: True`.

> **Warning:** Do NOT put vec0.dylib in the project folder - Xcode will auto-link it and crash the app on launch.

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
