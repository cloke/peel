#!/usr/bin/env bash
set -euo pipefail

PROJECT_OWNER="cloke"
PROJECT_NUMBER="1"
REPO="cloke/peel"
START_DATE=""
REMOVE_DONE="false"
LIMIT="200"

usage() {
  cat <<'USAGE'
Usage: Tools/roadmap-sync.sh [options]

Options:
  --project-owner <owner>    Project owner (default: cloke)
  --project-number <number>  Project number (default: 1)
  --repo <owner/repo>        Repository (default: cloke/peel)
  --start-date <YYYY-MM-DD>  Start date for scheduling (default: max Roadmap Day or today)
  --remove-done              Remove items with Status=Done from the project
  --limit <n>                Max open issues to consider (default: 200)
  -h, --help                 Show help

Examples:
  Tools/roadmap-sync.sh
  Tools/roadmap-sync.sh --start-date 2026-01-25
  Tools/roadmap-sync.sh --remove-done
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-owner)
      PROJECT_OWNER="$2"
      shift 2
      ;;
    --project-number)
      PROJECT_NUMBER="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --start-date)
      START_DATE="$2"
      shift 2
      ;;
    --remove-done)
      REMOVE_DONE="true"
      shift 1
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "gh CLI is required." >&2; exit 1; }
command -v ruby >/dev/null 2>&1 || { echo "ruby is required." >&2; exit 1; }

PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json -q .id)

FIELDS_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json)

ROADMAP_DAY_ID=$(echo "$FIELDS_JSON" | ruby -rjson -e '
  fields = JSON.parse(STDIN.read)["fields"] || []
  field = fields.find { |f| f["name"] == "Roadmap Day" }
  puts(field ? field["id"] : "")
')

if [[ -z "$ROADMAP_DAY_ID" ]]; then
  ROADMAP_DAY_ID=$(gh project field-create "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --name "Roadmap Day" --data-type DATE --format json -q .id)
fi

STATUS_FIELD_ID=$(echo "$FIELDS_JSON" | ruby -rjson -e '
  fields = JSON.parse(STDIN.read)["fields"] || []
  field = fields.find { |f| f["name"] == "Status" }
  puts(field ? field["id"] : "")
')

STATUS_TODO_ID=$(echo "$FIELDS_JSON" | ruby -rjson -e '
  fields = JSON.parse(STDIN.read)["fields"] || []
  field = fields.find { |f| f["name"] == "Status" }
  opt = field && field["options"]&.find { |o| o["name"] == "Todo" }
  puts(opt ? opt["id"] : "")
')

if [[ -z "$STATUS_FIELD_ID" || -z "$STATUS_TODO_ID" ]]; then
  echo "Status field or Todo option not found in project." >&2
  exit 1
fi

WORKDIR="/Users/cloken/code/KitchenSink/tmp"
mkdir -p "$WORKDIR"
EXISTING_URLS_FILE="$WORKDIR/roadmap_existing_urls.txt"
MAX_DATE_FILE="$WORKDIR/roadmap_max_date.txt"

ITEMS_JSON=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json)

echo "$ITEMS_JSON" | ruby -rjson -e '
  items = JSON.parse(STDIN.read)["items"] || []
  items.map { |i| i.dig("content", "url") }.compact.each { |u| puts u }
' > "$EXISTING_URLS_FILE"

if [[ -z "$START_DATE" ]]; then
  echo "$ITEMS_JSON" | ruby -rjson -e '
    require "date"
    items = JSON.parse(STDIN.read)["items"] || []
    dates = items.map { |i| i["roadmap Day"] }.compact.map { |s| (Date.parse(s) rescue nil) }.compact
    if dates.empty?
      puts Date.today.to_s
    else
      puts dates.max.to_s
    end
  ' > "$MAX_DATE_FILE"
  START_DATE=$(cat "$MAX_DATE_FILE")
fi

IDX=1

gh issue list --repo "$REPO" --state open --limit "$LIMIT" --json url -q '.[].url' \
  | while read -r URL; do
      if grep -Fxq "$URL" "$EXISTING_URLS_FILE"; then
        continue
      fi
      DATE_STR=$(ruby -e 'require "date"; puts (Date.parse(ARGV[0]) + ARGV[1].to_i).to_s' "$START_DATE" "$IDX")
      ITEM_ID=$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$URL" --format json -q .id)
      echo "added $URL -> $ITEM_ID -> $DATE_STR"
      gh project item-edit --project-id "$PROJECT_ID" --id "$ITEM_ID" --field-id "$ROADMAP_DAY_ID" --date "$DATE_STR"
      gh project item-edit --project-id "$PROJECT_ID" --id "$ITEM_ID" --field-id "$STATUS_FIELD_ID" --single-select-option-id "$STATUS_TODO_ID"
      IDX=$((IDX+1))
    done

if [[ "$REMOVE_DONE" == "true" ]]; then
  ITEMS_JSON=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json)
  echo "$ITEMS_JSON" | ruby -rjson -e '
    items = JSON.parse(STDIN.read)["items"] || []
    items.select { |i| i["status"] == "Done" }.map { |i| i["id"] }.each { |id| puts id }
  ' | while read -r ITEM_ID; do
    echo "removing done item $ITEM_ID"
    gh project item-delete "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --id "$ITEM_ID"
  done
fi

TOTAL=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json -q '.totalCount')

echo "Roadmap sync complete. Total items: $TOTAL"
