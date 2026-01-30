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
echo "Self-update script version: 3"
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

# Find and launch the built app
DERIVED_APPS=(~/Library/Developer/Xcode/DerivedData/Peel-*/Build/Products/Debug/Peel.app)
echo "Searching for built app in DerivedData..."
if [ ${#DERIVED_APPS[@]} -gt 0 ] && [ -e "${DERIVED_APPS[1]}" ]; then
  printf '  %s\n' "${DERIVED_APPS[@]}"
fi

APP_PATH=$(printf '%s\n' "${DERIVED_APPS[@]}" 2>/dev/null | head -1)
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
  nohup /bin/zsh -lc "/usr/bin/open -n \"$APP_PATH\" --args --worker" >/dev/null 2>&1 &
  RELAUNCH_PID=$!
  echo "Spawned relaunch process: $RELAUNCH_PID"
  
  # Wait longer for app to fully start and stabilize
  sleep 5
  
  # Verify the new process is running
  NEW_PID=$(pgrep -x Peel 2>/dev/null || true)
  if [ -n "$NEW_PID" ]; then
    echo "✅ Peel restarted in worker mode (PID: $NEW_PID)"
    
    # Log the git hash for verification
    GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo "   Expected version: $GIT_HASH"
  else
    echo "⚠️  Peel did not appear to launch (no process detected)"
    echo "   Retrying launch..."
    /usr/bin/open -n "$APP_PATH" --args --worker &
    sleep 3
    if pgrep -x Peel >/dev/null 2>&1; then
      echo "✅ Peel started on retry"
    else
      echo "❌ Failed to start Peel"
      exit 1
    fi
  fi
else
  echo "❌ Could not find Peel.app in DerivedData"
  echo "Tip: ensure Xcode has built Peel at least once on this machine."
  exit 1
fi

echo ""
echo "🎉 Self-update complete!"
