#!/bin/zsh
# Self-update script for Peel
# Run this on a worker machine to pull latest code, rebuild, and restart

set -e

REPO_DIR="${1:-/Users/cloken/code/KitchenSink}"
SCHEME="Peel (macOS)"

cd "$REPO_DIR"

echo "🍊 Peel Self-Update"
echo "==================="
echo "Directory: $REPO_DIR"
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
  echo ""
  echo "Restarting anyway? (y/n)"
  read -r response
  if [ "$response" != "y" ]; then
    echo "Cancelled."
    exit 0
  fi
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
pkill -x Peel 2>/dev/null || true
sleep 2

# Find and launch the built app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Peel-*/Build/Products/Debug/Peel.app -maxdepth 0 2>/dev/null | head -1)
if [ -n "$APP_PATH" ]; then
  echo "Launching: $APP_PATH"
  open "$APP_PATH" --args --worker
  echo "✅ Peel restarted in worker mode"
else
  echo "❌ Could not find Peel.app in DerivedData"
  exit 1
fi

echo ""
echo "🎉 Self-update complete!"
