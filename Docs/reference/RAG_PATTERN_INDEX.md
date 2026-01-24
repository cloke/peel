# RAG Pattern Index

Curated patterns to keep Peel consistent. Use this as the primary RAG seed for detecting preferred patterns and anti-patterns.

Last updated: 2026-01-24

---

## SwiftUI + Observation

### ✅ Preferred
- Use `@Observable` for view models (main-threaded with `@MainActor`).
- Use `@State` for owning view model instances.
- Use `@Environment` for shared dependencies.
- Use `NavigationStack` or `NavigationSplitView`.

### ❌ Avoid
- `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`.
- `NavigationView`.
- `DispatchQueue.main.async` in view models.

---

## Concurrency

### ✅ Preferred
- `actor` for thread-safe shared state.
- `async/await` with structured concurrency.
- `async let` for parallel work.
- `@MainActor` for UI-bound view models.

### ❌ Avoid
- `Combine` (unless required for legacy APIs).
- Manual `DispatchQueue` synchronization.

---

## Error Handling

### ✅ Preferred
- Use `do/catch` with a typed error enum where possible.
- Propagate errors up; surface user-facing states explicitly.

### ❌ Avoid
- `try!` or force unwraps (`!`).

---

## Formatting + Dates

### ✅ Preferred
- Reuse/cached `DateFormatter` instances.
- Convert external date strings via dedicated helpers.

### ❌ Avoid
- Allocating `DateFormatter()` on every access.

---

## Navigation + Tabs

### ✅ Preferred
- Tag `TabView` selections with a local `enum` instead of magic numbers.

### ❌ Avoid
- Integer tags without semantic meaning.

---

## Storage + Secrets

### ✅ Preferred
- Store tokens in Keychain.

### ❌ Avoid
- Storing tokens in `UserDefaults` or plaintext files.

---

## Quick Grep Checks

Use these to detect regressions:

```bash
grep -r "ObservableObject\|@Published\|@StateObject\|@ObservedObject" --include="*.swift" .
grep -r "NavigationView" --include="*.swift" .
grep -r "import Combine" --include="*.swift" .
grep -r "DispatchQueue.main" --include="*.swift" .
grep -r "try!" --include="*.swift" .
```