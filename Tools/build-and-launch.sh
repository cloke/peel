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
#   --emulator [HOST]     Start Firebase emulators and configure app to use them
#                         HOST defaults to localhost; use a LAN IP for multi-machine
#   --swarm [ROLE]        Auto-start swarm after launch (default role: hybrid)
#                         ROLE: brain, worker, hybrid
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
EMULATOR_MODE=false
EMULATOR_HOST=""
SWARM_MODE=false
SWARM_ROLE="hybrid"
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
    --emulator)
      EMULATOR_MODE=true
      # Check if next arg is a host (not another flag)
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        EMULATOR_HOST="$2"
        shift
      fi
      shift
      ;;
    --swarm)
      SWARM_MODE=true
      # Check if next arg is a role (not another flag)
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        SWARM_ROLE="$2"
        shift
      fi
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
    echo "    Proceeding with relaunch because no active chains can be verified."
  elif chains_running; then
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

# Firebase emulator mode
if [[ "$EMULATOR_MODE" == "true" ]]; then
  # Resolve host
  if [[ -z "$EMULATOR_HOST" ]]; then
    EMULATOR_HOST="localhost"
  fi
  
  echo "🔥 Firebase emulator mode: host=${EMULATOR_HOST}"
  
  # Install firebase-tools if needed
  if ! command -v firebase &>/dev/null; then
    echo "📦 Installing firebase-tools..."
    "${PROJECT_DIR}/Tools/firebase-emulator.sh" --install
  fi
  
  # Configure app to use emulators
  defaults write crunchy-bananas.Peel firebase_use_emulators -bool true
  defaults write crunchy-bananas.Peel firebase_emulator_host -string "$EMULATOR_HOST"
  
  # Start emulators if they're not already running
  if ! curl -s "http://${EMULATOR_HOST}:4000" &>/dev/null; then
    echo "🚀 Starting Firebase emulators..."
    LAN_FLAG=""
    if [[ "$EMULATOR_HOST" != "localhost" && "$EMULATOR_HOST" != "127.0.0.1" ]]; then
      LAN_FLAG="--lan"
    fi
    # Start in background
    "${PROJECT_DIR}/Tools/firebase-emulator.sh" $LAN_FLAG &
    EMULATOR_PID=$!
    echo "   Emulator PID: ${EMULATOR_PID}"
    
    # Wait for emulator to be ready
    echo "⏳ Waiting for emulators..."
    for i in $(seq 1 20); do
      if curl -s "http://${EMULATOR_HOST}:8080" &>/dev/null 2>&1 || \
         curl -s "http://localhost:8080" &>/dev/null 2>&1; then
        echo "✅ Firebase emulators ready!"
        break
      fi
      sleep 1
    done
  else
    echo "✅ Firebase emulators already running at ${EMULATOR_HOST}"
  fi
  
  echo "   Firestore emulator UI: http://${EMULATOR_HOST}:4000"
else
  # Clear emulator settings if not in emulator mode
  defaults delete crunchy-bananas.Peel firebase_use_emulators 2>/dev/null || true
  defaults delete crunchy-bananas.Peel firebase_emulator_host 2>/dev/null || true
fi

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
      
      # Auto-start swarm if requested
      if [[ "$SWARM_MODE" == "true" ]]; then
        echo "🐝 Starting swarm as ${SWARM_ROLE} with WAN..."
        sleep 2  # Brief pause for app to fully initialize
        
        SWARM_RESPONSE=$(curl -s -X POST \
          -H "Content-Type: application/json" \
          -d "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"tools/call\",\"params\":{\"name\":\"swarm.start\",\"arguments\":{\"role\":\"${SWARM_ROLE}\",\"wan\":true}}}" \
          "http://127.0.0.1:${MCP_PORT}/rpc" 2>/dev/null || echo "")
        
        if echo "$SWARM_RESPONSE" | grep -q '"success":true'; then
          echo "✅ Swarm started as ${SWARM_ROLE} with WAN enabled"
        else
          echo "⚠️  Swarm start may have failed: ${SWARM_RESPONSE}"
        fi
      fi
      
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

# Auto-start swarm even without --wait-for-server (best-effort)
if [[ "$SWARM_MODE" == "true" && "$WAIT_FOR_SERVER" == "false" ]]; then
  echo "⏳ Waiting briefly for MCP server to start swarm..."
  sleep 5
  for i in $(seq 1 15); do
    RESPONSE=$(curl -s -X POST \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
      "http://127.0.0.1:${MCP_PORT}/rpc" 2>/dev/null || echo "")
    if [[ "$RESPONSE" == *"tools"* ]]; then
      echo "🐝 Starting swarm as ${SWARM_ROLE} with WAN..."
      SWARM_RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"tools/call\",\"params\":{\"name\":\"swarm.start\",\"arguments\":{\"role\":\"${SWARM_ROLE}\",\"wan\":true}}}" \
        "http://127.0.0.1:${MCP_PORT}/rpc" 2>/dev/null || echo "")
      if echo "$SWARM_RESPONSE" | grep -q '"success":true'; then
        echo "✅ Swarm started as ${SWARM_ROLE} with WAN enabled"
      else
        echo "⚠️  Swarm start may have failed"
      fi
      break
    fi
    sleep 2
  done
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
