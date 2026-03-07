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
BUILD_LOCK_DIR="${PROJECT_DIR}/tmp/.peel-build.lock"

peel_build_lock_held_in_process() {
  [[ "${PEEL_BUILD_LOCK_HELD:-}" == "1" ]]
}

peel_build_lock_owner_running() {
  local pid_file="$BUILD_LOCK_DIR/pid"
  [[ -f "$pid_file" ]] || return 1

  local pid
  pid=$(cat "$pid_file" 2>/dev/null)
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

peel_acquire_build_lock() {
  local wait_for_lock=false
  if [[ "${1:-}" == "--wait" ]]; then
    wait_for_lock=true
  fi

  if peel_build_lock_held_in_process; then
    export PEEL_BUILD_LOCK_DEPTH=$(( ${PEEL_BUILD_LOCK_DEPTH:-1} + 1 ))
    return 0
  fi

  mkdir -p "${PROJECT_DIR}/tmp"

  while true; do
    if mkdir "$BUILD_LOCK_DIR" 2>/dev/null; then
      echo $$ > "$BUILD_LOCK_DIR/pid"
      export PEEL_BUILD_LOCK_HELD=1
      export PEEL_BUILD_LOCK_DEPTH=1
      return 0
    fi

    if ! peel_build_lock_owner_running; then
      rm -rf "$BUILD_LOCK_DIR"
      continue
    fi

    local lock_pid="unknown"
    if [[ -f "$BUILD_LOCK_DIR/pid" ]]; then
      lock_pid=$(cat "$BUILD_LOCK_DIR/pid" 2>/dev/null || echo "unknown")
    fi

    if [[ "$wait_for_lock" == "false" ]]; then
      echo "❌ Another Peel build is already running (PID: ${lock_pid})" >&2
      return 1
    fi

    echo "⏳ Waiting for active Peel build to finish (PID: ${lock_pid})..." >&2
    sleep 2
  done
}

peel_release_build_lock() {
  if ! peel_build_lock_held_in_process; then
    return 0
  fi

  local depth="${PEEL_BUILD_LOCK_DEPTH:-1}"
  if (( depth > 1 )); then
    export PEEL_BUILD_LOCK_DEPTH=$(( depth - 1 ))
    return 0
  fi

  if [[ -d "$BUILD_LOCK_DIR" ]] && [[ "$(cat "$BUILD_LOCK_DIR/pid" 2>/dev/null)" == "$$" ]]; then
    rm -rf "$BUILD_LOCK_DIR"
  fi

  unset PEEL_BUILD_LOCK_HELD
  unset PEEL_BUILD_LOCK_DEPTH
}

peel_build_log_has_transient_error() {
  local log_path="$1"
  grep -Eq 'database is locked|stat cache file .* not found' "$log_path"
}

peel_has_active_build_for_build_dir() {
  pgrep -fl xcodebuild | grep -F -- "-derivedDataPath ${BUILD_DIR}" >/dev/null
}

peel_reset_transient_build_state() {
  rm -rf \
    "${BUILD_DIR}/Build/Intermediates.noindex/XCBuildData" \
    "${BUILD_DIR}/ModuleCache.noindex" \
    "${BUILD_DIR}/SDKStatCaches.noindex"
}

peel_run_build_with_retry() {
  local config="${1:-Debug}"
  mkdir -p "${PROJECT_DIR}/tmp"

  PEEL_LAST_BUILD_LOG=$(mktemp "${PROJECT_DIR}/tmp/peel-build.XXXXXX.log")
  export PEEL_LAST_BUILD_LOG

  local build_status
  set +e
  peel_build "$config" > "$PEEL_LAST_BUILD_LOG" 2>&1
  build_status=$?
  set -e

  if [[ $build_status -ne 0 ]] && peel_build_log_has_transient_error "$PEEL_LAST_BUILD_LOG"; then
    if peel_has_active_build_for_build_dir; then
      echo "❌ Build failed: another xcodebuild is using ${BUILD_DIR}" >&2
    else
      echo "⚠️  Detected transient Xcode cache failure. Resetting build caches and retrying once..."
      peel_reset_transient_build_state
      set +e
      peel_build "$config" > "$PEEL_LAST_BUILD_LOG" 2>&1
      build_status=$?
      set -e
    fi
  fi

  PEEL_LAST_BUILD_STATUS=$build_status
  export PEEL_LAST_BUILD_STATUS
  return $build_status
}

peel_print_build_summary() {
  if [[ -n "${PEEL_LAST_BUILD_LOG:-}" ]] && [[ -f "$PEEL_LAST_BUILD_LOG" ]]; then
    grep -E '(Building|Build succeeded|error:|warning:|\*\*)' "$PEEL_LAST_BUILD_LOG" || true
  fi
}

peel_print_failed_build_log() {
  local lines="${1:-200}"
  echo "❌ Build failed"
  echo "---- Build log (last ${lines} lines) ----"
  tail -n "$lines" "$PEEL_LAST_BUILD_LOG"
  echo "------------------------------------"
}

peel_cleanup_build_log() {
  if [[ -n "${PEEL_LAST_BUILD_LOG:-}" ]] && [[ -f "$PEEL_LAST_BUILD_LOG" ]]; then
    rm -f "$PEEL_LAST_BUILD_LOG"
  fi
  unset PEEL_LAST_BUILD_LOG
  unset PEEL_LAST_BUILD_STATUS
}

# Helper: build the app with consistent settings
peel_build() {
  local config="${1:-Debug}"
  shift 2>/dev/null || true
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
