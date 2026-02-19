## Summary

<!-- One-sentence description of what this PR does. -->

## Changes

<!-- Bullet list of the significant changes made. -->

-
-

## Motivation

<!-- Why is this change needed? Link to issue(s) if applicable. Closes #XXX -->

---

## Code Quality Checklist

- [ ] No new `private` access on methods/properties needed by same-module extension files (use `internal` instead)
- [ ] All new Swift files follow the `TypeName+Concern.swift` extension naming convention
- [ ] No new commented-out code added (delete dead code; use git history instead)
- [ ] No new force-unwraps (`!`) or `try!` added without a comment explaining why it's safe
- [ ] Token storage uses Keychain, not `UserDefaults` or `@AppStorage`
- [ ] `@Observable` used for new view models (not `ObservableObject` / `@Published`)
- [ ] `NavigationStack` used (not `NavigationView`)
- [ ] No new `DispatchQueue.main.async` (use `@MainActor` instead)

## RAG Orphan Check

- [ ] Ran `rag.orphans` after changes
- [ ] Any new orphaned files are either deleted or documented in [`Docs/reference/RAG_ORPHAN_BASELINE.md`](Docs/reference/RAG_ORPHAN_BASELINE.md)

## Platform

- [ ] Tested on macOS
- [ ] Tested on iOS (if feature is shared)
- [ ] macOS-only changes gated with `#if os(macOS)`
- [ ] iOS-only changes gated with `#if os(iOS)`
