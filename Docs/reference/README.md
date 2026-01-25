# Peel Reference Documentation

Quick references for code patterns and standards.

---

## Documents

| Document | Purpose |
|----------|---------|
| [CODE_AUDIT_INDEX.md](CODE_AUDIT_INDEX.md) | File-by-file audit status and deprecated pattern tracking |
| [RAG_PATTERN_INDEX.md](RAG_PATTERN_INDEX.md) | Curated patterns for RAG retrieval and code consistency |
| [PLAN_FILE_STANDARDS.md](PLAN_FILE_STANDARDS.md) | Standards for plan files in `/Plans/` |

---

## Quick Pattern Checks

Run from project root:

```bash
# Check for deprecated patterns
grep -r "ObservableObject\|@Published\|@StateObject" --include="*.swift" .
grep -r "NavigationView" --include="*.swift" .
grep -r "import Combine" --include="*.swift" .
grep -r "DispatchQueue.main" --include="*.swift" .
```

See [RAG_PATTERN_INDEX.md](RAG_PATTERN_INDEX.md) for full pattern guidance.
