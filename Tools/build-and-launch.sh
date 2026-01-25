#!/bin/zsh
#
# build-and-launch.sh - Build Peel and launch with MCP server enabled
#
# Usage:
#   ./build-and-launch.sh [--port PORT] [--wait-for-server]
#
# Options:
#   --port PORT           MCP server port (default: 8765)
#   --wait-for-server     Wait until MCP server is responding before exiting
#   --skip-build          Skip build, just launch existing app
#   --allow-while-chains-running  Allow build/launch even if MCP chains are running
#   --help                Show this help message
#

set -e

# Configuration
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Peel (macOS)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_NAME="Peel.app"
MCP_PORT=8765
WAIT_FOR_SERVER=false
SKIP_BUILD=false
ALLOW_DURING_CHAINS=false
PEELCLI_PATH="${PROJECT_DIR}/Tools/PeelCLI/.build/debug/peel-mcp"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      MCP_PORT="$2"
      shift 2
      ;;
    --wait-for-server)
      WAIT_FOR_SERVER=true
      shift
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --allow-while-chains-running)
      ALLOW_DURING_CHAINS=true
      shift
      ;;
    --help|-h)
      head -20 "$0" | tail -18
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Lock file to prevent concurrent invocations (relaunch storm prevention)
LOCK_FILE="${PROJECT_DIR}/tmp/.build-launch.lock"
LOCK_MAX_AGE=300  # 5 minutes max lock age

cleanup_lock() {
  rm -f "$LOCK_FILE"
}

# Check for stale lock file (older than LOCK_MAX_AGE)
if [[ -f "$LOCK_FILE" ]]; then
  lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE") ))
  if [[ $lock_age -gt $LOCK_MAX_AGE ]]; then
    echo "⚠️  Removing stale lock file (age: ${lock_age}s)"
    rm -f "$LOCK_FILE"
  fi
fi

# Try to acquire lock
mkdir -p "$(dirname "$LOCK_FILE")"
if [[ -f "$LOCK_FILE" ]]; then
  lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  echo "❌ Another build-and-launch is in progress (PID: ${lock_pid})"
  echo "   Lock file: ${LOCK_FILE}"
  echo "   If this is stale, delete the lock file and retry."
  exit 1
fi

# Create lock file with our PID
echo $$ > "$LOCK_FILE"
trap cleanup_lock EXIT

echo "🍊 Peel Build & Launch Script"
echo "=============================="
echo "Project: ${PROJECT_DIR}"
echo "MCP Port: ${MCP_PORT}"
echo ""

mcp_server_ready() {
  local response
  response=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    "http://127.0.0.1:${MCP_PORT}/rpc" 2>/dev/null || echo "")
  [[ "$response" == *"tools"* ]]
}

chains_running() {
  if [[ ! -x "$PEELCLI_PATH" ]]; then
    return 1
  fi
  local output
  output=$("$PEELCLI_PATH" --port "$MCP_PORT" chains-run-list --limit 25 2>/dev/null || true)
  echo "$output" | grep -q '"status" : "running"' && return 0
  echo "$output" | grep -q '"status" : "queued"' && return 0
  return 1
}

if [[ "$ALLOW_DURING_CHAINS" == "false" ]] && pgrep -x "Peel" > /dev/null 2>&1; then
  if ! mcp_server_ready; then
    echo "⚠️  Peel is running but MCP server is not responding."
    echo "    Refusing to relaunch to avoid interrupting active chains."
    echo "    Re-run with --allow-while-chains-running to override."
    exit 1
  fi
  if chains_running; then
    echo "⚠️  MCP chains are running. Refusing to build/launch to avoid overload."
    echo "    Re-run with --allow-while-chains-running to override."
    exit 1
  fi
fi

# Kill any existing Peel instances
if pgrep -x "Peel" > /dev/null 2>&1; then
  echo "⏹️  Stopping existing Peel instance..."
  pkill -x "Peel" || true
  sleep 1
fi

# Build the app
if [[ "$SKIP_BUILD" == "false" ]]; then
  echo "🔨 Building Peel..."
  cd "$PROJECT_DIR"

  BUILD_LOG=$(mktemp)
  set +e
  xcodebuild \
    -project Peel.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'platform=macOS' \
    build > "$BUILD_LOG" 2>&1
  BUILD_STATUS=$?
  set -e

  grep -E '(Building|Build succeeded|error:|warning:|\*\*)' "$BUILD_LOG" || true

  if [[ $BUILD_STATUS -ne 0 ]]; then
    echo "❌ Build failed"
    echo "---- Build log (last 200 lines) ----"
    tail -n 200 "$BUILD_LOG"
    echo "------------------------------------"
    rm -f "$BUILD_LOG"
    exit 1
  fi
  rm -f "$BUILD_LOG"
  echo "✅ Build succeeded"
else
  echo "⏭️  Skipping build (--skip-build)"
fi

# Find the built app
APP_PATH=$(find "$BUILD_DIR" -name "$APP_NAME" -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
  echo "❌ Could not find ${APP_NAME} in ${BUILD_DIR}"
  exit 1
fi

echo "📦 App: ${APP_PATH}"

# Set MCP defaults before launch
echo "⚙️  Configuring MCP server (port ${MCP_PORT}, enabled)..."
defaults write crunchy-bananas.Peel "mcp.server.enabled" -bool true
defaults write crunchy-bananas.Peel "mcp.server.port" -int "$MCP_PORT"

# Launch the app
echo "🚀 Launching Peel..."
open -a "$APP_PATH"

# Wait for MCP server to respond
if [[ "$WAIT_FOR_SERVER" == "true" ]]; then
  echo "⏳ Waiting for MCP server on localhost:${MCP_PORT}..."
  
  MAX_ATTEMPTS=30
  ATTEMPT=0
  
  while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    
    # Try to connect
    RESPONSE=$(curl -s -X POST \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
      "http://127.0.0.1:${MCP_PORT}/rpc" 2>/dev/null || echo "")
    
    if [[ "$RESPONSE" == *"tools"* ]]; then
      echo "✅ MCP server ready!"
      echo ""
      echo "Available commands:"
      echo "  curl -X POST -H 'Content-Type: application/json' \\"
      echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}' \\"
      echo "    http://127.0.0.1:${MCP_PORT}/rpc"
      exit 0
    fi
    
    sleep 1
  done
  
  echo "⚠️  Timeout waiting for MCP server (${MAX_ATTEMPTS}s)"
  echo "   App launched, but server may not be responding"
  exit 1
fi

echo ""
echo "✅ Peel launched!"
echo ""
echo "MCP server should be available at: http://127.0.0.1:${MCP_PORT}/rpc"
echo ""
echo "Test with:"
echo "  curl -X POST -H 'Content-Type: application/json' \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}' \\"
echo "    http://127.0.0.1:${MCP_PORT}/rpc"
