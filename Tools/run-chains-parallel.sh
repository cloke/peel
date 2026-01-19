#!/bin/zsh
#
# run-chains-parallel.sh - Dispatch multiple MCP chains concurrently
#
# Usage:
#   ./run-chains-parallel.sh \
#     --prompt "First task" \
#     --prompt "Second task" \
#     --template-name "MCP Harness" \
#     --working-directory /path/to/repo \
#     --port 8765 \
#     --max-concurrent 2 \
#     --disable-review-loop
#
# Options:
#   --prompt TEXT           Prompt to run (repeatable)
#   --prompt-file PATH      File with one prompt per line
#   --template-name NAME    Template name (default: MCP Harness)
#   --template-id UUID      Template id (optional)
#   --working-directory PATH  Repo path (default: project root)
#   --port PORT             MCP server port (default: 8765)
#   --max-concurrent N      Max concurrent runs (default: 0 = unlimited)
#   --enable-review-loop    Enable review loop
#   --disable-review-loop   Disable review loop (default)
#   --help                  Show help
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT=8765
WORKDIR="$PROJECT_DIR"
TEMPLATE_NAME="MCP Harness"
TEMPLATE_ID=""
MAX_CONCURRENT=0
REVIEW_FLAG="--disable-review-loop"
PROMPTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)
      PROMPTS+=("$2")
      shift 2
      ;;
    --prompt-file)
      while IFS= read -r line; do
        [[ -n "$line" ]] && PROMPTS+=("$line")
      done < "$2"
      shift 2
      ;;
    --template-name)
      TEMPLATE_NAME="$2"
      shift 2
      ;;
    --template-id)
      TEMPLATE_ID="$2"
      shift 2
      ;;
    --working-directory)
      WORKDIR="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --max-concurrent)
      MAX_CONCURRENT="$2"
      shift 2
      ;;
    --enable-review-loop)
      REVIEW_FLAG="--enable-review-loop"
      shift
      ;;
    --disable-review-loop)
      REVIEW_FLAG="--disable-review-loop"
      shift
      ;;
    --help|-h)
      head -40 "$0" | tail -34
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ ${#PROMPTS[@]} -eq 0 ]]; then
  echo "At least one --prompt or --prompt-file is required."
  exit 1
fi

CLI="${PROJECT_DIR}/Tools/PeelCLI/.build/debug/peel-mcp"
if [[ ! -x "$CLI" ]]; then
  echo "peel-mcp not found. Building PeelCLI..."
  (cd "${PROJECT_DIR}/Tools/PeelCLI" && swift build)
fi

PIDS=()

run_one() {
  local prompt="$1"
  local cmd=("$CLI" --port "$PORT" chains-run)
  if [[ -n "$TEMPLATE_ID" ]]; then
    cmd+=(--template-id "$TEMPLATE_ID")
  else
    cmd+=(--template-name "$TEMPLATE_NAME")
  fi
  cmd+=(--working-directory "$WORKDIR" --prompt "$prompt" "$REVIEW_FLAG")

  echo "▶︎ Starting: $prompt"
  "${cmd[@]}" &
  PIDS+=("$!")
}

wait_for_slot() {
  if [[ "$MAX_CONCURRENT" -le 0 ]]; then
    return
  fi

  while (( ${#PIDS[@]} >= MAX_CONCURRENT )); do
    wait -n
    local alive=()
    for pid in "${PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        alive+=("$pid")
      fi
    done
    PIDS=("${alive[@]}")
  done
}

for prompt in "${PROMPTS[@]}"; do
  wait_for_slot
  run_one "$prompt"
done

wait

echo "✅ All chain runs complete."
