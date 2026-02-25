#!/bin/zsh
#
# build-config.sh - Shared build configuration for Peel
#
# Source this file in any script that needs to build or locate the app:
#   source "$(dirname "$0")/build-config.sh"
#
# Or from the repo root:
#   source Tools/build-config.sh
#
# Provides:
#   PROJECT_DIR    - Absolute path to the repo root
#   SCHEME         - Xcode scheme name
#   BUILD_DIR      - Local derived data path (repo-local, not ~/Library)
#   APP_PATH       - Path to the built .app bundle
#   PEELCLI_PATH   - Path to the PeelCLI binary
#
# Usage in xcodebuild:
#   xcodebuild -project Peel.xcodeproj \
#     -scheme "$SCHEME" \
#     -configuration Debug \
#     -derivedDataPath "$BUILD_DIR" \
#     -destination 'platform=macOS' \
#     build

# Resolve PROJECT_DIR from this file's location (Tools/build-config.sh → repo root)
if [[ -n "${PEEL_PROJECT_DIR:-}" ]]; then
  PROJECT_DIR="$PEEL_PROJECT_DIR"
elif [[ -f "$(cd "$(dirname "${(%):-%x}")/.." 2>/dev/null && pwd)/Peel.xcodeproj/project.pbxproj" ]]; then
  PROJECT_DIR="$(cd "$(dirname "${(%):-%x}")/.." && pwd)"
elif [[ -f "${PWD}/Peel.xcodeproj/project.pbxproj" ]]; then
  PROJECT_DIR="$PWD"
else
  echo "❌ Cannot determine project directory. Set PEEL_PROJECT_DIR or cd into the repo." >&2
  return 1 2>/dev/null || exit 1
fi

SCHEME="Peel (macOS)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_NAME="Peel.app"
APP_PATH="${BUILD_DIR}/Build/Products/Debug/${APP_NAME}"
PEELCLI_PATH="${PROJECT_DIR}/Tools/PeelCLI/.build/debug/peel-mcp"

# Helper: build the app with consistent settings
peel_build() {
  local config="${1:-Debug}"
  echo "🔨 Building Peel (${config})..."
  cd "$PROJECT_DIR"
  xcodebuild \
    -project Peel.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$config" \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'platform=macOS' \
    build "$@"
}
