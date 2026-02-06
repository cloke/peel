#!/bin/bash
# firebase-emulator.sh — Start Firebase Emulator Suite for local swarm testing
#
# Usage:
#   ./Tools/firebase-emulator.sh              # localhost only
#   ./Tools/firebase-emulator.sh --lan        # bind to all interfaces (LAN accessible)
#   ./Tools/firebase-emulator.sh --lan --seed # bind to LAN + seed test data
#
# Both Peel instances on the LAN connect to the machine running
# this script. Set the env var in Xcode scheme or launch args:
#
#   FIREBASE_EMULATOR_HOST=192.168.1.50  (IP of the machine running emulators)
#
# Or for single-machine testing:
#   FIREBASE_EMULATOR_HOST=localhost

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LAN_MODE=false
SEED_DATA=false

for arg in "$@"; do
  case "$arg" in
    --lan) LAN_MODE=true ;;
    --seed) SEED_DATA=true ;;
    --install) INSTALL_ONLY=true ;;
    -h|--help)
      echo "Usage: $0 [--lan] [--seed] [--install]"
      echo "  --lan     Bind to 0.0.0.0 (accessible from LAN)"
      echo "  --seed    Import seed data for testing"
      echo "  --install Just install firebase-tools and exit"
      exit 0
      ;;
  esac
done

INSTALL_ONLY=${INSTALL_ONLY:-false}

# Install firebase-tools if missing
install_firebase_tools() {
  echo "📦 Installing firebase-tools..."
  if command -v npm &>/dev/null; then
    npm install -g firebase-tools
  elif command -v brew &>/dev/null; then
    brew install firebase-cli
  else
    echo "❌ Neither npm nor brew found. Install Node.js first: https://nodejs.org"
    exit 1
  fi
  echo "✅ firebase-tools installed: $(firebase --version)"
}

# Check firebase CLI
if ! command -v firebase &>/dev/null; then
  echo "⚠️  firebase-tools not found."
  install_firebase_tools
fi

if $INSTALL_ONLY; then
  echo "✅ firebase-tools ready: $(firebase --version)"
  echo ""
  echo "Java is also required for emulators. Check with: java -version"
  if ! command -v java &>/dev/null; then
    echo "❌ Java not found. Install with: brew install --cask temurin"
  fi
  exit 0
fi

# Java is required for Firebase emulators
if ! command -v java &>/dev/null; then
  echo "❌ Java is required for Firebase emulators."
  echo "   Install with: brew install --cask temurin"
  exit 1
fi

cd "$PROJECT_DIR"

# Show LAN IP for convenience
if $LAN_MODE; then
  LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "unknown")
  echo "🌐 LAN mode enabled — emulators binding to 0.0.0.0"
  echo "📡 Your LAN IP: $LAN_IP"
  echo ""
  echo "On the OTHER machine, set in Xcode scheme environment:"
  echo "   FIREBASE_EMULATOR_HOST=$LAN_IP"
  echo ""
  echo "Or in terminal before building:"
  echo "   defaults write crunchy-bananas.Peel firebase_use_emulators -bool true"
  echo "   defaults write crunchy-bananas.Peel firebase_emulator_host -string \"$LAN_IP\""
  echo ""

  HOST_FLAG="--host 0.0.0.0"
else
  echo "🏠 Localhost mode — emulators on 127.0.0.1 only"
  echo ""
  echo "Set in Xcode scheme environment:"
  echo "   FIREBASE_EMULATOR_HOST=localhost"
  echo ""
  HOST_FLAG=""
fi

IMPORT_FLAG=""
if $SEED_DATA && [ -d "$PROJECT_DIR/tmp/firebase-seed" ]; then
  IMPORT_FLAG="--import=$PROJECT_DIR/tmp/firebase-seed"
  echo "📦 Importing seed data from tmp/firebase-seed/"
fi

echo "Starting Firebase Emulator Suite..."
echo "  Firestore:  port 8080"
echo "  Auth:       port 9099"
echo "  Emulator UI: port 4000"
echo ""
echo "Press Ctrl+C to stop."
echo ""

# Export data on exit so you can resume later
EXPORT_FLAG="--export-on-exit=$PROJECT_DIR/tmp/firebase-seed"
mkdir -p "$PROJECT_DIR/tmp/firebase-seed"

# Start emulators
# shellcheck disable=SC2086
firebase emulators:start \
  --only auth,firestore \
  --project peel-swarm \
  $HOST_FLAG \
  $IMPORT_FLAG \
  $EXPORT_FLAG
