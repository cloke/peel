#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  gh-issue-create.sh --repo owner/repo --title "Title" [--body-file path | --body "text" | --body-stdin]

Examples:
  gh-issue-create.sh --repo cloke/peel --title "My Issue" --body-stdin <<'EOF'
  ## Summary
  Write markdown normally.
  EOF

  gh-issue-create.sh --repo cloke/peel --title "My Issue" --body-file /tmp/body.md
USAGE
}

repo=""
title=""
body_file=""
body_text=""
use_stdin=false

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
    --body)
      body_text="$2"
      shift 2
      ;;
    --body-stdin)
      use_stdin=true
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
 done

if [[ -z "$repo" || -z "$title" ]]; then
  usage
  exit 1
fi

if [[ -n "$body_text" && -n "$body_file" ]]; then
  echo "Use only one of --body or --body-file." >&2
  exit 1
fi

if [[ -n "$body_text" && "$use_stdin" == true ]]; then
  echo "Use only one of --body or --body-stdin." >&2
  exit 1
fi

if [[ -n "$body_file" && "$use_stdin" == true ]]; then
  echo "Use only one of --body-file or --body-stdin." >&2
  exit 1
fi

if [[ -n "$body_text" ]]; then
  tmpfile=$(mktemp)
  printf "%s" "$body_text" > "$tmpfile"
  body_file="$tmpfile"
fi

if [[ "$use_stdin" == true ]]; then
  tmpfile=$(mktemp)
  cat > "$tmpfile"
  body_file="$tmpfile"
fi

if [[ -z "$body_file" ]]; then
  echo "Missing body. Provide --body-file, --body, or --body-stdin." >&2
  exit 1
fi

issue_url=$(gh issue create --repo "$repo" --title "$title" --body-file "$body_file")
issue_number=$(echo "$issue_url" | sed -E 's#.*/([0-9]+)$#\1#')

printf "%s\n%s\n" "$issue_url" "$issue_number"
