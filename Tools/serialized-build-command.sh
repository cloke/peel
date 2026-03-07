#!/bin/zsh

set -e
source "$(dirname "$0")/build-config.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 '<shell command>'" >&2
  exit 1
fi

BUILD_COMMAND="$1"

peel_acquire_build_lock --wait
trap peel_release_build_lock EXIT

/bin/zsh -lc "$BUILD_COMMAND"