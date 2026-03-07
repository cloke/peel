#!/bin/zsh
#
# build.sh - Canonical Peel build entry point
#
# Usage:
#   ./Tools/build.sh              # Build Debug
#   ./Tools/build.sh Release      # Build Release
#
# Uses the shared build helpers in build-config.sh and is the single
# source of truth for shell-based Peel builds.
#

set -e
source "$(dirname "$0")/build-config.sh"

CONFIG="${1:-Debug}"

peel_acquire_build_lock --wait
trap peel_release_build_lock EXIT

if ! peel_run_build_with_retry "$CONFIG"; then
  peel_print_build_summary
  peel_print_failed_build_log 100
  peel_cleanup_build_log
  exit 1
fi

peel_print_build_summary
peel_cleanup_build_log
echo "✅ Build succeeded: ${APP_PATH}"
