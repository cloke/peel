#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --repo <owner/repo> --title <title> [--body-file <path>]" >&2
  echo "If --body-file is omitted, the body is read from stdin." >&2
  exit 1
}

repo=""
title=""
body_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --title)
      title="$2"
      shift 2
      ;;
    --body-file)
      body_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$repo" || -z "$title" ]]; then
  usage
fi

if [[ -z "$body_file" ]]; then
  tmp_file="$(mktemp)"
  cat > "$tmp_file"
  body_file="$tmp_file"
fi

gh issue create --repo "$repo" --title "$title" --body-file "$body_file"
