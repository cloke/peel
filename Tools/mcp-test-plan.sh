#!/bin/sh
set -euo pipefail

PORT=8765
TEMPLATE_NAME="MCP Harness"
PROMPT="Reply with a short confirmation. Do not edit any files."
WORKING_DIRECTORY=""
ENABLE_REVIEW_LOOP=false
SKIP_RUN=false

usage() {
  echo "Usage: $0 --working-directory <path> [--port <port>] [--template-name <name>] [--prompt <text>] [--enable-review-loop] [--skip-run]" >&2
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    --template-name)
      TEMPLATE_NAME="$2"
      shift 2
      ;;
    --prompt)
      PROMPT="$2"
      shift 2
      ;;
    --working-directory)
      WORKING_DIRECTORY="$2"
      shift 2
      ;;
    --enable-review-loop)
      ENABLE_REVIEW_LOOP=true
      shift 1
      ;;
    --skip-run)
      SKIP_RUN=true
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
 done

if [ -z "$WORKING_DIRECTORY" ]; then
  usage
  exit 1
fi

RPC_URL="http://127.0.0.1:${PORT}/rpc"

call_rpc() {
  payload="$1"
  curl -s -X POST -H 'Content-Type: application/json' -d "$payload" "$RPC_URL"
}

printf "MCP Test Plan: tools/list\n"
TOOLS=$(call_rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
echo "$TOOLS" | grep -q '"templates.list"' || fail "tools/list missing templates.list"
echo "$TOOLS" | grep -q '"chains.run"' || fail "tools/list missing chains.run"
printf "PASS: tools/list\n"

printf "MCP Test Plan: templates.list\n"
TEMPLATES=$(call_rpc '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"templates.list","arguments":{}}}')
echo "$TEMPLATES" | grep -q "\"name\" : \"$(json_escape "$TEMPLATE_NAME")\"" || \
  echo "$TEMPLATES" | grep -q "\"name\":\"$(json_escape "$TEMPLATE_NAME")\"" || \
  fail "Template not found: $TEMPLATE_NAME"
printf "PASS: templates.list\n"

printf "MCP Test Plan: chains.run missing prompt\n"
MISSING_PROMPT=$(call_rpc '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chains.run","arguments":{}}}')
echo "$MISSING_PROMPT" | grep -q '"error"' || fail "Expected error for missing prompt"
printf "PASS: chains.run missing prompt\n"

if [ "$SKIP_RUN" = true ]; then
  printf "SKIP: chains.run success test\n"
  exit 0
fi

printf "MCP Test Plan: chains.run success\n"
ESC_PROMPT=$(json_escape "$PROMPT")
ESC_WORKDIR=$(json_escape "$WORKING_DIRECTORY")
ESC_TEMPLATE=$(json_escape "$TEMPLATE_NAME")
RUN_PAYLOAD=$(cat <<EOF
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"chains.run","arguments":{"templateName":"$ESC_TEMPLATE","prompt":"$ESC_PROMPT","workingDirectory":"$ESC_WORKDIR","enableReviewLoop":$ENABLE_REVIEW_LOOP}}}
EOF
)
RUN_RESULT=$(call_rpc "$RUN_PAYLOAD")
echo "$RUN_RESULT" | grep -q '"success"' || fail "chains.run missing success"
echo "$RUN_RESULT" | grep -q '"success" *: *true' || fail "chains.run did not succeed"
printf "PASS: chains.run success\n"

printf "All MCP test plan checks passed.\n"
