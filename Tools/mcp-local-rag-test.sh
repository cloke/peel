#!/bin/sh
set -euo pipefail

PORT=8765
REPO_PATH=""
TEXT_QUERY="Local RAG"
VECTOR_QUERY="agent orchestration"
LIMIT=5
SKIP_INDEX=false
SKIP_VECTOR=false

usage() {
  echo "Usage: $0 --repo-path <path> [--port <port>] [--text-query <text>] [--vector-query <text>] [--limit <n>] [--skip-index] [--skip-vector]" >&2
}

json_escape() {
  printf '%s' "$1" | perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    --repo-path)
      REPO_PATH="$2"
      shift 2
      ;;
    --text-query)
      TEXT_QUERY="$2"
      shift 2
      ;;
    --vector-query)
      VECTOR_QUERY="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --skip-index)
      SKIP_INDEX=true
      shift 1
      ;;
    --skip-vector)
      SKIP_VECTOR=true
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

if [ -z "$REPO_PATH" ]; then
  usage
  exit 1
fi

RPC_URL="http://127.0.0.1:${PORT}/rpc"

call_rpc() {
  payload="$1"
  curl -s -X POST -H 'Content-Type: application/json' -d "$payload" "$RPC_URL"
}

printf "Local RAG MCP Test: rag.status\n"
call_rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rag.status","arguments":{}}}' | grep -q '"exists"' || {
  echo "FAIL: rag.status" >&2
  exit 1
}
printf "PASS: rag.status\n"

if [ "$SKIP_INDEX" = false ]; then
  printf "Local RAG MCP Test: rag.index\n"
  ESC_REPO=$(json_escape "$REPO_PATH")
  call_rpc "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"rag.index\",\"arguments\":{\"repoPath\":\"$ESC_REPO\"}}}" | grep -q '"repoPath"' || {
    echo "FAIL: rag.index" >&2
    exit 1
  }
  printf "PASS: rag.index\n"
fi

printf "Local RAG MCP Test: rag.search (text)\n"
ESC_TEXT=$(json_escape "$TEXT_QUERY")
ESC_REPO=$(json_escape "$REPO_PATH")
call_rpc "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"rag.search\",\"arguments\":{\"query\":\"$ESC_TEXT\",\"repoPath\":\"$ESC_REPO\",\"mode\":\"text\",\"limit\":$LIMIT}}}" | grep -q '"results"' || {
  echo "FAIL: rag.search text" >&2
  exit 1
}
printf "PASS: rag.search (text)\n"

if [ "$SKIP_VECTOR" = false ]; then
  printf "Local RAG MCP Test: rag.search (vector)\n"
  ESC_VECTOR=$(json_escape "$VECTOR_QUERY")
  call_rpc "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"rag.search\",\"arguments\":{\"query\":\"$ESC_VECTOR\",\"repoPath\":\"$ESC_REPO\",\"mode\":\"vector\",\"limit\":$LIMIT}}}" | grep -q '"results"' || {
    echo "FAIL: rag.search vector" >&2
    exit 1
  }
  printf "PASS: rag.search (vector)\n"
fi

printf "Local RAG MCP Test: rag.ui.status\n"
call_rpc '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rag.ui.status","arguments":{}}}' | grep -q '"lastSearch"' || {
  echo "FAIL: rag.ui.status" >&2
  exit 1
}
printf "PASS: rag.ui.status\n"

printf "All Local RAG MCP tests passed.\n"
