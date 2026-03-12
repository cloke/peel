#!/bin/zsh
# Self-update script for Peel (build-only mode)
# Handles git pull and xcodebuild. Peel handles restart natively via performSelfRestart().
#
# Options:
#   --stash          Stash uncommitted changes before pulling
#   --skip-build     Skip rebuild if already up to date

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="Peel (macOS)"
AUTO_STASH=false

for arg in "$@"; do
  case $arg in
    --stash) AUTO_STASH=true ;;
  esac
done

cd "$REPO_DIR"

BUILD_DIR="${REPO_DIR}/build"

LOG_DIR="$HOME/Library/Logs/Peel"
LOG_FILE="$LOG_DIR/swarm-self-update.log"
mkdir -p "$LOG_DIR"

# All output goes to log file only. Peel's handleDirectCommand reads the exit code,
# not stdout. This avoids pipe/SIGPIPE issues entirely.
exec >> "$LOG_FILE" 2>&1

echo ""
echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
echo "🍊 Peel Self-Update (build-only)"
echo "Directory: $REPO_DIR"
echo "Host: $(hostname)"
echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
echo "Self-update script version: 7"
echo ""

# Check for uncommitted changes
if ! git diff --quiet HEAD 2>/dev/null; then
  if [ "$AUTO_STASH" = true ]; then
    echo "⚠️  Stashing uncommitted changes..."
    git stash
  else
    echo "⚠️  Uncommitted changes — continuing anyway"
  fi
fi

# Pull latest
echo "📥 Pulling latest code..."
git fetch origin main
BEFORE=$(git rev-parse HEAD)
git pull origin main
AFTER=$(git rev-parse HEAD)

if [ "$BEFORE" = "$AFTER" ]; then
  echo "✅ Already up to date ($BEFORE)"
  for arg in "$@"; do
    if [ "$arg" = "--skip-build" ]; then
      echo "   Skipping rebuild."
      exit 0
    fi
  done
  echo "   Rebuilding anyway (use --skip-build to skip)..."
else
  echo "✅ Updated: $BEFORE → $AFTER"
  git log --oneline -3
fi

echo ""
echo "🔨 Building..."
BUILD_LOG="$LOG_DIR/swarm-self-update-build.log"
if xcodebuild \
  -project Peel.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'platform=macOS' \
  build > "$BUILD_LOG" 2>&1; then
  if grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
    echo "✅ Build succeeded"
  else
    echo "❌ Build completed but BUILD SUCCEEDED not found"
    tail -20 "$BUILD_LOG"
    exit 1
  fi
else
  BUILD_EXIT=$?
  echo "❌ Build failed (exit code: $BUILD_EXIT)"
  tail -30 "$BUILD_LOG"
  exit 1
fi

echo ""
echo "✅ Self-update complete (pull + build). Peel will handle restart natively."
exit 0
