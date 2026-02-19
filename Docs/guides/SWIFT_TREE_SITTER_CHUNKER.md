# SwiftTreeSitterChunker — Guide

## Overview

`SwiftTreeSitterChunker` is an alternative Swift AST chunker that uses
[tree-sitter-swift](https://github.com/alex-pinkus/tree-sitter-swift) instead of Apple's
SwiftSyntax library. The primary motivation is tree-sitter's **iterative parsing**
algorithm, which eliminates the stack-overflow risk present with recursive-descent
parsers on deeply-nested or adversarially-crafted Swift files.

It follows the same architecture already proven for Ruby (`RubyChunker`) and Glimmer
(`GlimmerChunker`) — invoking the tree-sitter CLI as a subprocess and parsing the
S-expression AST output.

---

## Setup

### 1. Build the dylib

```bash
Tools/build-tree-sitter-swift.sh
```

This clones [alex-pinkus/tree-sitter-swift](https://github.com/alex-pinkus/tree-sitter-swift),
generates the parser, and compiles a universal dylib to:

```
~/code/tree-sitter-grammars/tree-sitter-swift/swift.dylib
```

Requirements: `tree-sitter` CLI (`brew install tree-sitter`), `node`/`npm`, Xcode CLT.

### 2. Set the environment variable

```bash
export AST_CHUNKER_SWIFT_LIB=~/code/tree-sitter-grammars/tree-sitter-swift/swift.dylib
```

When this variable is set and the file exists, `ASTChunkerService` will automatically
prefer tree-sitter for `.swift` files; otherwise it falls back to SwiftSyntax.

---

## How It Works

1. Source code is written to a temp file (`/tmp/swift_<UUID>.swift`).
2. The tree-sitter CLI is invoked as a subprocess:
   ```
   tree-sitter parse -l <dylib> --lang-name swift --timeout 3000000 <file>
   ```
3. The S-expression AST output is parsed to find top-level construct nodes.
4. Each construct is converted to an `ASTChunk` with metadata.
5. If tree-sitter is unavailable or fails, a single `.file` fallback chunk is returned.

Output is read asynchronously via `DispatchGroup` to prevent pipe-buffer deadlocks
on large files (same pattern as `RubyChunker`).

---

## Supported Constructs

| Tree-sitter node type      | `ASTChunk.ConstructType` |
|---------------------------|--------------------------|
| `class_declaration`       | `.classDecl`             |
| `struct_declaration`      | `.structDecl`            |
| `protocol_declaration`    | `.protocolDecl`          |
| `enum_declaration`        | `.enumDecl`              |
| `extension_declaration`   | `.extension`             |
| `function_declaration`    | `.function`              |
| `actor_declaration`       | `.actorDecl`             |

---

## Comparison with SwiftSyntax (`SwiftChunker`)

| Feature | SwiftSyntax (`SwiftChunker`) | tree-sitter (`SwiftTreeSitterChunker`) |
|---------|------------------------------|----------------------------------------|
| Parser type | Recursive descent | Iterative |
| Stack overflow risk | Low (but possible on adversarial files) | None |
| External binary required | ❌ No | ✅ Yes (tree-sitter CLI + dylib) |
| Rich AST metadata | ✅ Full Swift AST | ⚠️  S-expression, less detail |
| Import chunk extraction | ✅ Yes | ❌ Not yet |
| Property wrapper detection | ✅ Yes | ❌ Not yet |
| Always available | ✅ Yes | Only when dylib is present |
| Performance | Fast (in-process) | Slightly slower (subprocess per file) |
| Infrastructure consistency | ❌ Swift-only | ✅ Same as Ruby/Glimmer |

**Recommendation**: SwiftSyntax (`SwiftChunker`) is the default and produces higher-quality
metadata. `SwiftTreeSitterChunker` is preferred when processing untrusted or very large Swift
files where iterative parsing safety matters.

---

## Activation

`ASTChunkerService` automatically selects the chunker at init time:

```swift
// Prefer tree-sitter when dylib is available
let candidate = SwiftTreeSitterChunker(
  treeSitterLibPath: swiftTreeSitterLibPath,  // or AST_CHUNKER_SWIFT_LIB env var
  treeSitterCLIPath: treeSitterCLIPath        // or AST_CHUNKER_TREE_SITTER_CLI env var
)
self.swiftTreeSitterChunker = candidate.isAvailable ? candidate : nil
```

In `chunk(source:filename:)`:

```swift
case "swift":
  if let swiftTreeSitterChunker {
    return swiftTreeSitterChunker.chunk(source: source, maxChunkLines: maxChunkLines)
  }
  return swiftChunker.chunk(source: source, maxChunkLines: maxChunkLines)
```

---

## Acceptance Criteria

- [x] `SwiftTreeSitterChunker` added to local `ASTChunker` package
- [x] `ASTChunkerService` prefers tree-sitter when dylib is present, falls back to SwiftSyntax
- [x] `Tools/build-tree-sitter-swift.sh` builds the dylib
- [x] `SwiftTreeSitterChunkerTests` cover language ID, extensions, availability, fallback, and no-crash
- [ ] tree-sitter-swift grammar builds and loads (requires running `build-tree-sitter-swift.sh`)
- [ ] `SwiftTreeSitterChunker` produces valid chunks (verified by running tests with dylib present)
- [ ] No crashes on deeply nested Swift files (covered by `testNoStackOverflowOnDeeplyNested`)
