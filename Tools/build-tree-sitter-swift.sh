#!/usr/bin/env bash
# build-tree-sitter-swift.sh
# Builds the tree-sitter-swift grammar dylib for use with SwiftTreeSitterChunker.
#
# Usage:
#   Tools/build-tree-sitter-swift.sh [--force]
#
# Requirements:
#   - tree-sitter CLI: brew install tree-sitter
#   - node / npm: https://nodejs.org (for generating parser.c)
#   - clang (comes with Xcode Command Line Tools)

set -e

FORCE=0
for arg in "$@"; do
  if [ "$arg" = "--force" ]; then
    FORCE=1
  fi
done

# --- Locate tree-sitter CLI ---
TREE_SITTER_CLI=""
for candidate in /opt/homebrew/bin/tree-sitter /usr/local/bin/tree-sitter /usr/bin/tree-sitter; do
  if [ -f "$candidate" ]; then
    TREE_SITTER_CLI="$candidate"
    break
  fi
done
if [ -z "$TREE_SITTER_CLI" ]; then
  TREE_SITTER_CLI=$(which tree-sitter 2>/dev/null || true)
fi
if [ -z "$TREE_SITTER_CLI" ]; then
  echo "❌  tree-sitter CLI not found."
  echo "    Install it with: brew install tree-sitter"
  exit 1
fi
echo "✅  tree-sitter CLI: $TREE_SITTER_CLI"

# --- Paths ---
TARGET_DIR="$HOME/code/tree-sitter-grammars/tree-sitter-swift"
DYLIB_PATH="$TARGET_DIR/swift.dylib"

# --- Skip if dylib already exists ---
if [ -f "$DYLIB_PATH" ] && [ "$FORCE" -eq 0 ]; then
  echo "✅  Dylib already exists at $DYLIB_PATH"
  echo "    Use --force to rebuild."
  echo ""
  echo "    Set the env var for Peel:"
  echo "    export AST_CHUNKER_SWIFT_LIB=$DYLIB_PATH"
  exit 0
fi

mkdir -p "$(dirname "$TARGET_DIR")"

# --- Clone or update grammar ---
if [ -d "$TARGET_DIR/.git" ]; then
  echo "🔄  Updating tree-sitter-swift grammar..."
  git -C "$TARGET_DIR" pull --ff-only
else
  echo "📥  Cloning tree-sitter-swift grammar..."
  git clone https://github.com/alex-pinkus/tree-sitter-swift.git "$TARGET_DIR"
fi

# --- Install npm dependencies and generate parser ---
echo "📦  Installing npm dependencies..."
(cd "$TARGET_DIR" && npm install --silent)

echo "⚙️   Generating parser..."
(cd "$TARGET_DIR" && "$TREE_SITTER_CLI" generate)

# --- Compile dylib ---
echo "🔨  Compiling dylib..."

SOURCES=("$TARGET_DIR/src/parser.c")
if [ -f "$TARGET_DIR/src/scanner.c" ]; then
  SOURCES+=("$TARGET_DIR/src/scanner.c")
fi
if [ -f "$TARGET_DIR/src/scanner.cc" ]; then
  SOURCES+=("$TARGET_DIR/src/scanner.cc")
fi

clang -dynamiclib -o "$DYLIB_PATH" \
  -I "$TARGET_DIR/src" \
  "${SOURCES[@]}" \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min=13.0

echo ""
echo "✅  Build complete!"
echo "    Dylib: $DYLIB_PATH"
echo ""
echo "    Set the env var for Peel:"
echo "    export AST_CHUNKER_SWIFT_LIB=$DYLIB_PATH"
