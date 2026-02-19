#!/usr/bin/env bash
set -euo pipefail

# Project board: https://github.com/users/cloke/projects/1
# Requires `project` scope: gh auth refresh -s project
PROJECT_NUMBER=1
PROJECT_OWNER=cloke

usage() {
  echo "Usage: $0 --repo <owner/repo> --title <title> [--body-file <path>] [--no-project]" >&2
  echo "If --body-file is omitted, the body is read from stdin." >&2
  echo "Pass --no-project to skip adding to the project board." >&2
  exit 1
}

repo=""
title=""
body_file=""
no_project=false

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
    --no-project)
      no_project=true
      shift
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

issue_url=$(gh issue create --repo "$repo" --title "$title" --body-file "$body_file")
echo "$issue_url"

if [[ "$no_project" == "false" ]]; then
  if gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$issue_url" 2>/dev/null; then
    echo "Added to project board: https://github.com/users/${PROJECT_OWNER}/projects/${PROJECT_NUMBER}" >&2
  else
    echo "⚠️  Could not add to project board (run: gh auth refresh -s project)" >&2
  fi
fi
