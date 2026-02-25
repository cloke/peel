#!/bin/zsh
#
# build.sh - Build Peel without launching
#
# Usage:
#   ./Tools/build.sh              # Build Debug
#   ./Tools/build.sh Release      # Build Release
#
# Uses the same local derivedDataPath as build-and-launch.sh so both
# scripts always operate on the same binary.
#

set -e
source "$(dirname "$0")/build-config.sh"

CONFIG="${1:-Debug}"

BUILD_LOG=$(mktemp)
set +e
peel_build "$CONFIG" > "$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

grep -E '(Building|Build succeeded|error:|warning:|\*\*)' "$BUILD_LOG" || true

if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "❌ Build failed"
  tail -n 100 "$BUILD_LOG"
  rm -f "$BUILD_LOG"
  exit 1
fi

rm -f "$BUILD_LOG"
echo "✅ Build succeeded: ${APP_PATH}"
