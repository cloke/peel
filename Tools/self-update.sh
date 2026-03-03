#!/bin/zsh
# Self-update script for Peel
# Run this on a worker machine to pull latest code, rebuild, and restart
#
# Options:
#   --stash          Stash uncommitted changes before pulling (for MCP/automated use)
#   --skip-build     Skip rebuild if already up to date
#   --no-stash       (default) Abort if uncommitted changes exist instead of stashing

set -e

# Detect repo directory from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="Peel (macOS)"
AUTO_STASH=false

# Parse arguments
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
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="

echo "🍊 Peel Self-Update"
echo "==================="
echo "Directory: $REPO_DIR"
echo "Host: $(hostname)"
echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
echo "Self-update script version: 5"
echo ""

# Check for uncommitted changes
if ! git diff --quiet HEAD 2>/dev/null; then
  if [ "$AUTO_STASH" = true ]; then
    echo "⚠️  Uncommitted changes detected — stashing..."
    git stash
  else
    echo "⚠️  Uncommitted changes detected — continuing anyway"
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
# Use repo-local build dir so we build AND launch from the same path
# (avoids the stale-DerivedData bug where xcodebuild writes to one
#  DerivedData dir but the glob picks an older one to launch)
if xcodebuild \
  -project Peel.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'platform=macOS' \
  build 2>&1 | grep -q "BUILD SUCCEEDED"; then
  echo "✅ Build succeeded"
else
  echo "❌ Build failed"
  exit 1
fi

echo ""
echo "🔄 Restarting Peel..."

# Find the built app in our known build directory
APP_PATH=$(find "$BUILD_DIR" -name "Peel.app" -type d | head -1)
echo "Built app: $APP_PATH"

# Disable macOS state restoration before killing — prevents OS from auto-relaunching
# the app behind our back (which causes the double-instance bug)
if [ -n "$APP_PATH" ]; then
  BUNDLE_ID=$(defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "com.crunchy-bananas.Peel")
else
  BUNDLE_ID="com.crunchy-bananas.Peel"
fi
defaults write "$BUNDLE_ID" NSQuitAlwaysKeepsWindows -bool false 2>/dev/null || true
echo "Disabled state restoration for $BUNDLE_ID"

# Kill ALL Peel processes (there might be multiple from previous failed restarts)
PEEL_PIDS=$(pgrep -x Peel 2>/dev/null || true)
if [ -n "$PEEL_PIDS" ]; then
  PEEL_COUNT=$(echo "$PEEL_PIDS" | wc -l | tr -d ' ')
  echo "Found $PEEL_COUNT running Peel process(es): $PEEL_PIDS"
  
  # First try graceful SIGTERM to all
  echo "Sending SIGTERM to all Peel processes..."
  echo "$PEEL_PIDS" | xargs kill 2>/dev/null || true
  sleep 2
  
  # Check if any are still running and SIGKILL them
  REMAINING=$(pgrep -x Peel 2>/dev/null || true)
  if [ -n "$REMAINING" ]; then
    echo "Processes still running, sending SIGKILL..."
    echo "$REMAINING" | xargs kill -9 2>/dev/null || true
    sleep 1
  fi
else
  echo "No running Peel processes detected."
fi

# Final verification - fail loudly if processes remain
FINAL_CHECK=$(pgrep -x Peel 2>/dev/null || true)
if [ -n "$FINAL_CHECK" ]; then
  echo "⚠️  WARNING: Peel processes still running after termination: $FINAL_CHECK"
  echo "   Attempting forced termination..."
  echo "$FINAL_CHECK" | xargs kill -9 2>/dev/null || true
  sleep 1
fi

if pgrep -x Peel >/dev/null 2>&1; then
  echo "❌ FAILED to terminate all Peel processes"
  exit 1
else
  echo "✅ All Peel processes terminated"
fi

# Wait for any macOS state restoration relaunch attempts to settle
sleep 2
ZOMBIE_CHECK=$(pgrep -x Peel 2>/dev/null || true)
if [ -n "$ZOMBIE_CHECK" ]; then
  echo "⚠️  macOS relaunched Peel (state restoration) — killing zombie..."
  echo "$ZOMBIE_CHECK" | xargs kill -9 2>/dev/null || true
  sleep 1
fi
if [ -n "$APP_PATH" ]; then
  echo "Launching: $APP_PATH"
  
  # Ensure no processes remain before launch (double-check)
  sleep 1
  if pgrep -x Peel >/dev/null 2>&1; then
    echo "⚠️  Peel process appeared unexpectedly, killing..."
    pkill -9 -x Peel 2>/dev/null || true
    sleep 2
  fi
  
  echo "Launching via detached open..."
  nohup /bin/zsh -lc "/usr/bin/open \"$APP_PATH\" --args --worker" >/dev/null 2>&1 &
  RELAUNCH_PID=$!
  echo "Spawned relaunch process: $RELAUNCH_PID"
  
  # Wait longer for app to fully start and stabilize
  sleep 5
  
  # Verify the new process is running
  NEW_PID=$(pgrep -x Peel 2>/dev/null || true)
  if [ -n "$NEW_PID" ]; then
    echo "✅ Peel restarted in headless mode — using persisted swarm role (PID: $NEW_PID)"
    
    # Log the git hash for verification
    GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo "   Expected version: $GIT_HASH"
  else
    echo "⚠️  Peel did not appear to launch (no process detected)"
    echo "   Retrying launch..."
    /usr/bin/open "$APP_PATH" --args --worker &
    sleep 3
    if pgrep -x Peel >/dev/null 2>&1; then
      echo "✅ Peel started on retry"
    else
      echo "❌ Failed to start Peel"
      exit 1
    fi
  fi
else
  echo "❌ Could not find Peel.app in build directory: $BUILD_DIR"
  echo "Tip: ensure Xcode has built Peel at least once on this machine."
  exit 1
fi

echo ""
echo "🎉 Self-update complete!"
