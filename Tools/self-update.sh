#!/bin/zsh
# Self-update script for Peel
# Run this on a worker machine to pull latest code, rebuild, and restart

set -e

# Detect repo directory from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="Peel (macOS)"

cd "$REPO_DIR"

LOG_DIR="$HOME/Library/Logs/Peel"
LOG_FILE="$LOG_DIR/swarm-self-update.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="

echo "🍊 Peel Self-Update"
echo "==================="
echo "Directory: $REPO_DIR"
echo "Host: $(hostname)"
echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
echo "Self-update script version: 2"
echo ""

# Check for uncommitted changes
if ! git diff --quiet HEAD 2>/dev/null; then
  echo "⚠️  Warning: Uncommitted changes detected"
  echo "   Stashing changes..."
  git stash
fi

# Pull latest
echo "📥 Pulling latest code..."
git fetch origin main
BEFORE=$(git rev-parse HEAD)
git pull origin main
AFTER=$(git rev-parse HEAD)

if [ "$BEFORE" = "$AFTER" ]; then
  echo "✅ Already up to date ($BEFORE)"
  # Default to rebuilding - use --skip-build to skip
  if [ "$1" = "--skip-build" ]; then
    echo "   Skipping rebuild."
    exit 0
  fi
  echo "   Rebuilding anyway (use --skip-build to skip)..."
else
  echo "✅ Updated: $BEFORE → $AFTER"
  git log --oneline -3
fi

echo ""
echo "🔨 Building..."
if xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' build 2>&1 | grep -q "BUILD SUCCEEDED"; then
  echo "✅ Build succeeded"
else
  echo "❌ Build failed"
  exit 1
fi

echo ""
echo "🔄 Restarting Peel..."
if pgrep -x Peel >/dev/null 2>&1; then
  echo "Found running Peel process. Sending pkill..."
else
  echo "No running Peel process detected."
fi
pkill -x Peel 2>/dev/null || true
sleep 2
if pgrep -x Peel >/dev/null 2>&1; then
  echo "⚠️  Peel still running after pkill"
else
  echo "✅ Peel process not running"
fi

# Find and launch the built app
DERIVED_APPS=(~/Library/Developer/Xcode/DerivedData/Peel-*/Build/Products/Debug/Peel.app)
echo "Searching for built app in DerivedData..."
if [ ${#DERIVED_APPS[@]} -gt 0 ] && [ -e "${DERIVED_APPS[1]}" ]; then
  printf '  %s\n' "${DERIVED_APPS[@]}"
fi

APP_PATH=$(printf '%s\n' "${DERIVED_APPS[@]}" 2>/dev/null | head -1)
if [ -n "$APP_PATH" ]; then
  echo "Launching: $APP_PATH"
  open "$APP_PATH" --args --worker
  sleep 2
  if pgrep -x Peel >/dev/null 2>&1; then
    echo "✅ Peel restarted in worker mode"
  else
    echo "⚠️  Peel did not appear to launch (no process detected)"
  fi
else
  echo "❌ Could not find Peel.app in DerivedData"
  echo "Tip: ensure Xcode has built Peel at least once on this machine."
  exit 1
fi

echo ""
echo "🎉 Self-update complete!"
