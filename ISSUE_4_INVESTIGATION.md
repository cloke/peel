# Issue #4 Investigation: Delete duplicate parseWorktreeList

**Date**: January 18, 2026  
**Status**: ✅ Already Completed  
**Issue**: https://github.com/cloke/peel/issues/4

## Summary

After thorough investigation, all work items from issue #4 have already been completed in the base codebase. No code changes are required.

## Issue Requirements (from #4)

1. Delete duplicate `parseWorktreeList()` (lines 314-371) in WorkspaceDashboardService
2. Use `Git.Commands.Worktree.list()` instead
3. Replace `runGit()` helper with `Git.Commands.simple()`
4. See Plans/CONSOLIDATION_PLAN.md for details

## Investigation Results

### 1. Duplicate parseWorktreeList() ✅ RESOLVED

**Finding**: No duplicate exists
- `parseWorktreeList()` exists only in `Local Packages/Git/Sources/Git/Commands/Worktree.swift` (lines 176-254)
- It's a private helper method within the Git package (correct location)
- Lines 314-371 of WorkspaceDashboardService.swift contain worktree creation code, not parsing logic
- No duplication found

### 2. Git.Commands.Worktree.list() Usage ✅ IMPLEMENTED

**Finding**: Already in use
- WorkspaceDashboardService.swift line 277:
  ```swift
  let gitWorktrees = try await Commands.Worktree.list(on: repository)
  ```
- Proper usage of the Git package API as recommended

### 3. Replace runGit() Helper ✅ NOT NEEDED

**Finding**: No `runGit()` function exists
- All git operations use `Git.Commands.simple()`:
  - Lines 313, 318, 321: worktree management
  - Lines 358, 362, 366: PR worktree operations
  - Lines 402, 405: worktree removal
  - Lines 419, 439, 442: status checking

**Note**: A `runCommand()` helper exists (line 551) but is only used for GitHub CLI (`gh`) commands at line 354, not git commands. This is appropriate as `Git.Commands.simple()` is specifically for git operations.

### 4. Model Usage ✅ CORRECT

**Finding**: Proper model in use
- `Git.Worktree` type used throughout (lines 60, 84, 200, 275, 285, 289, 301, 337, 349, 381, 390, etc.)
- No deprecated `WorktreeInfo` model exists in the codebase
- Compliant with CONSOLIDATION_PLAN.md recommendations

## Code Quality Check

### Current Implementation (WorkspaceDashboardService.swift)

```swift
// Line 275-282: Proper worktree loading
private func loadWorktrees(for repo: WorkspaceRepo, in workspace: Workspace) async throws -> [Git.Worktree] {
  let repository = Model.Repository(name: repo.name, path: repo.path)
  let gitWorktrees = try await Commands.Worktree.list(on: repository)
  for worktree in gitWorktrees {
    worktreeRepoNames[worktree.path] = repo.name
    worktreeWorkspaceNames[worktree.path] = workspace.name
  }
  return gitWorktrees
}
```

### Git Commands Pattern

All git operations follow the proper pattern:
```swift
_ = try await Commands.simple(arguments: [...], in: repository)
```

## Conclusion

**The codebase is already in full compliance with the requirements stated in issue #4 and CONSOLIDATION_PLAN.md.**

Possible explanations:
1. Issue was created based on outdated information
2. Work was completed before issue creation
3. Line numbers in issue description were from a different branch/version

## Recommendation

**Close issue #4** as the requested work is complete.

## Files Analyzed

- `Shared/Services/WorkspaceDashboardService.swift` (654 lines)
- `Local Packages/Git/Sources/Git/Commands/Worktree.swift` (257 lines)
- `Local Packages/Git/Sources/Git/Commands/Commands.swift` (75 lines)
- `Shared/Services/WorktreeErrors.swift` (52 lines)
- `Plans/CONSOLIDATION_PLAN.md`

## Next Steps

No code changes needed. Consider:
1. Closing issue #4
2. Moving to next item in CONSOLIDATION_PLAN.md (Error type consolidation or TrackedWorktree wiring)
