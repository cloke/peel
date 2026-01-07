# Git Worktree Feature Plan

**Date:** January 7, 2026  
**Status:** 🟡 **IN PROGRESS**  
**Priority:** High  
**Goal:** Manage git worktrees and open them in VS Code for isolated development

---

## Overview

Git worktrees allow you to have multiple working directories from the same repository, each checked out to a different branch. This is perfect for:

- Working on multiple features simultaneously
- Code review in an isolated environment  
- Running different versions for testing
- AI agent isolation (each agent gets its own worktree)

This feature will integrate with VS Code to open worktrees in separate windows.

---

## User Stories

1. **As a developer**, I want to see all worktrees for my repository so I can manage them
2. **As a developer**, I want to create a new worktree for a branch so I can work on it in isolation
3. **As a developer**, I want to open a worktree in VS Code so I can edit code
4. **As a developer**, I want to delete worktrees I'm done with to clean up disk space
5. **As a developer**, I want to create a worktree from a PR so I can review code locally

---

## Implementation Plan

### Phase 1: Git Worktree Commands
- [ ] Add `git worktree list` parsing
- [ ] Add `git worktree add` support
- [ ] Add `git worktree remove` support  
- [ ] Add `git worktree prune` support

### Phase 2: Worktree Model & UI
- [ ] Create `Worktree` model
- [ ] Add worktree list to Git sidebar
- [ ] Create worktree detail view
- [ ] Add create worktree sheet

### Phase 3: VS Code Integration
- [ ] Detect VS Code installation
- [ ] Open worktree in new VS Code window
- [ ] Track open VS Code windows (optional)

### Phase 4: GitHub PR Integration  
- [ ] Create worktree from PR branch
- [ ] Quick "Review Locally" action on PRs

---

## Technical Design

### Worktree Model
```swift
public struct Worktree: Identifiable {
  public let id: UUID
  public let path: String           // /path/to/worktree
  public let branch: String         // feature/my-branch
  public let head: String           // abc123 (commit SHA)
  public let isMain: Bool           // Is this the main working directory?
  public let isLocked: Bool         // Is this worktree locked?
  public let prunable: Bool         // Can this be pruned?
}
```

### Git Commands
```bash
# List worktrees (porcelain format for parsing)
git worktree list --porcelain

# Add new worktree
git worktree add ../my-feature feature/my-branch
git worktree add -b new-branch ../new-branch  # Create new branch

# Remove worktree
git worktree remove ../my-feature
git worktree remove --force ../my-feature  # Force if dirty

# Prune stale worktrees
git worktree prune
```

### VS Code Integration
```bash
# Open in new window
code -n /path/to/worktree

# Open with isolated settings (for agents)
code -n --user-data-dir ~/.vscode-worktree-{id} /path/to/worktree
```

---

## UI Mockup

```
┌─────────────────────────────────────────────────────────────┐
│ Git - my-repo                                               │
├─────────────────────────────────────────────────────────────┤
│ 📂 Local Changes (3)                                        │
│ 📦 Stashes                                                  │
│ 🌿 Local Branches                                           │
│ 🌍 Remote Branches                                          │
│ ─────────────────────                                       │
│ 🗂️ Worktrees                         [+ New Worktree]       │
│   ├─ main (current)                                         │
│   ├─ feature/auth         [Open in VS Code] [Delete]        │
│   └─ bugfix/login         [Open in VS Code] [Delete]        │
└─────────────────────────────────────────────────────────────┘
```

---

## File Structure

```
Local Packages/Git/Sources/Git/
├── Commands/
│   └── Worktree.swift          # NEW: Worktree commands
├── Models/
│   └── Worktree.swift          # NEW: Worktree model  
├── WorktreeListView.swift      # NEW: Worktree list UI
├── CreateWorktreeView.swift    # NEW: Create worktree sheet
└── ... existing files
```

---

## Success Criteria

- [ ] Can list all worktrees for a repository
- [ ] Can create new worktree from existing or new branch
- [ ] Can delete worktrees
- [ ] Can open worktree in VS Code with one click
- [ ] UI shows worktree status (locked, prunable)
- [ ] Proper error handling with user feedback

---

## Future Enhancements

- **Agent Integration:** Auto-create worktree when spawning AI agent
- **PR Review:** One-click "Review Locally" creates worktree from PR
- **Cleanup:** Auto-prune worktrees when branches are merged
- **Tracking:** Show which worktrees have VS Code windows open
