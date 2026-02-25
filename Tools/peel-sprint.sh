#!/bin/zsh
#
# peel-sprint.sh — High-velocity iteration pipeline for Peel
#
# Workflow:
#   1. Audit → Discover issues via codebase analysis
#   2. Triage → Create GitHub issues + add to project board
#   3. Dispatch → Launch parallel worktree batch via MCP
#   4. Monitor → Poll status until complete
#   5. Review → Inspect diffs, approve/reject/retry
#   6. Merge → Auto-merge approved branches
#
# Usage:
#   ./Tools/peel-sprint.sh audit              # Discover issues, create them
#   ./Tools/peel-sprint.sh dispatch [file]    # Launch parallel batch from task file
#   ./Tools/peel-sprint.sh status [runId]     # Check status of a batch run
#   ./Tools/peel-sprint.sh review [runId]     # Review pending branches
#   ./Tools/peel-sprint.sh configure          # Set concurrency, review gates, etc.
#   ./Tools/peel-sprint.sh list               # List all parallel runs
#
# Task File Format (JSON array):
#   [
#     {
#       "title": "Fix alert binding bug (#339)",
#       "prompt": "Fix the SwarmManagementView...",
#       "focusPaths": ["Shared/Views/Swarm/SwarmManagementView.swift"]
#     },
#     ...
#   ]
#
# Environment:
#   PEEL_PORT          MCP server port (default: 8765)
#   PEEL_CONCURRENCY   Max concurrent chains (default: 3)
#   PEEL_TEMPLATE      Chain template name (default: "Guarded Implementation")
#   PEEL_REVIEW_GATE   Require review before merge (default: true)
#   PEEL_AUTO_MERGE    Auto-merge on approval (default: true)
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PEEL_PORT:-8765}"
CONCURRENCY="${PEEL_CONCURRENCY:-3}"
TEMPLATE="${PEEL_TEMPLATE:-Guarded Implementation}"
REVIEW_GATE="${PEEL_REVIEW_GATE:-true}"
AUTO_MERGE="${PEEL_AUTO_MERGE:-true}"
MCP_URL="http://127.0.0.1:${PORT}/rpc"

# ─── Helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo "${BLUE}[sprint]${NC} $*"; }
ok()   { echo "${GREEN}[  ok  ]${NC} $*"; }
warn() { echo "${YELLOW}[ warn ]${NC} $*"; }
err()  { echo "${RED}[error ]${NC} $*" >&2; }

mcp_call() {
  local tool_name="$1"
  local args="$2"
  local result
  result=$(curl -s --max-time 30 "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool_name}\",\"arguments\":${args}}}" 2>&1)
  
  if echo "$result" | python3 -c "import json,sys; r=json.load(sys.stdin); sys.exit(0 if 'result' in r else 1)" 2>/dev/null; then
    echo "$result" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['result']['content'][0]['text'])"
  else
    local errmsg
    errmsg=$(echo "$result" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('error',{}).get('message','Unknown error'))" 2>/dev/null || echo "$result")
    err "MCP call failed: $errmsg"
    return 1
  fi
}

check_server() {
  if ! curl -s --max-time 3 "$MCP_URL" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' >/dev/null 2>&1; then
    err "MCP server not reachable at $MCP_URL"
    err "Start it with: ./Tools/build-and-launch.sh --wait-for-server"
    exit 1
  fi
}

# ─── Commands ─────────────────────────────────────────────────────────

cmd_configure() {
  check_server
  log "Configuring chain queue: maxConcurrent=${CONCURRENCY}"
  mcp_call "chains_queue_configure" "{\"maxConcurrent\":${CONCURRENCY}}" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(f'  Max concurrent: {d[\"maxConcurrent\"]}')
print(f'  Paused: {d[\"pauseNew\"]}')
print(f'  Running: {d[\"running\"]}')
print(f'  Queued: {d[\"queued\"]}')
"
  ok "Queue configured"
}

cmd_dispatch() {
  check_server
  local task_file="${1:-}"
  
  if [[ -z "$task_file" ]]; then
    err "Usage: peel-sprint.sh dispatch <task-file.json>"
    err ""
    err "Task file format (JSON array):"
    err '  [{"title": "...", "prompt": "...", "focusPaths": ["path1", "path2"]}]'
    exit 1
  fi
  
  if [[ ! -f "$task_file" ]]; then
    err "Task file not found: $task_file"
    exit 1
  fi

  # Validate JSON
  if ! python3 -c "import json; json.load(open('$task_file'))" 2>/dev/null; then
    err "Invalid JSON in task file: $task_file"
    exit 1
  fi

  local task_count
  task_count=$(python3 -c "import json; print(len(json.load(open('$task_file'))))")
  log "Dispatching ${task_count} tasks from ${task_file}"
  log "  Template: ${TEMPLATE}"
  log "  Review gate: ${REVIEW_GATE}"
  log "  Auto-merge: ${AUTO_MERGE}"
  log "  Concurrency: ${CONCURRENCY}"

  # First ensure concurrency is set
  mcp_call "chains_queue_configure" "{\"maxConcurrent\":${CONCURRENCY}}" >/dev/null

  # Build the parallel_create payload
  local batch_name
  batch_name="peel-sprint-$(date +%Y%m%d-%H%M%S)"
  
  local tasks_json
  tasks_json=$(python3 -c "
import json
tasks = json.load(open('$task_file'))
print(json.dumps(tasks))
")

  local payload
  payload=$(python3 -c "
import json
tasks = json.load(open('$task_file'))
print(json.dumps({
    'name': '$batch_name',
    'projectPath': '$PROJECT_DIR',
    'baseBranch': 'main',
    'templateName': '$TEMPLATE',
    'requireReviewGate': $( [[ "$REVIEW_GATE" == "true" ]] && echo "True" || echo "False" ),
    'autoMergeOnApproval': $( [[ "$AUTO_MERGE" == "true" ]] && echo "True" || echo "False" ),
    'tasks': tasks
}))
")

  local result
  result=$(mcp_call "parallel_create" "$payload")
  
  local run_id
  run_id=$(echo "$result" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['id'])")
  
  ok "Parallel batch created: ${run_id}"
  ok "Name: ${batch_name}"
  ok "Tasks: ${task_count}"
  echo ""
  log "Monitor with:"
  echo "  ./Tools/peel-sprint.sh status ${run_id}"
  echo ""
  log "Review when ready:"
  echo "  ./Tools/peel-sprint.sh review ${run_id}"
}

cmd_status() {
  check_server
  local run_id="${1:-}"
  
  if [[ -z "$run_id" ]]; then
    # Show all runs
    local result
    result=$(mcp_call "parallel_list" "{}")
    echo "$result" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
runs = data.get('runs', [])
snapshots = data.get('snapshots', [])

# Deduplicate snapshots by runId (take latest)
seen = set()
unique_snapshots = []
for s in snapshots:
    rid = s.get('runId','')
    if rid not in seen:
        seen.add(rid)
        unique_snapshots.append(s)

all_items = runs + unique_snapshots
if not all_items:
    print('No parallel runs found.')
    sys.exit(0)

print(f'{'Status':<18} {'Name':<40} {'Progress':<10} {'Run ID'}')
print('-' * 100)
for r in all_items:
    status = r.get('status', '?')
    name = r.get('name', '?')[:38]
    progress = f\"{r.get('progress', 0)*100:.0f}%\"
    rid = r.get('runId', r.get('id', '?'))[:36]
    merged = r.get('mergedCount', 0)
    total = r.get('executionCount', 0)
    failed = r.get('failedCount', 0)
    pending = r.get('pendingReviewCount', 0)
    detail = f'({merged}/{total} merged'
    if failed: detail += f', {failed} failed'
    if pending: detail += f', {pending} pending review'
    detail += ')'
    print(f'{status:<18} {name:<40} {progress:<10} {rid}  {detail}')
"
    return
  fi
  
  # Show specific run
  local result
  result=$(mcp_call "parallel_status" "{\"runId\":\"${run_id}\"}")
  echo "$result" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())

print(f\"Run: {data.get('name', '?')}\")
print(f\"Status: {data.get('status', '?')}\")
print(f\"Progress: {data.get('progress', 0)*100:.0f}%\")
print()

executions = data.get('executions', [])
for e in executions:
    status = e.get('status', '?')
    title = e.get('title', e.get('prompt', '?'))[:60]
    branch = e.get('branch', '?')
    emoji = {'Completed': '✅', 'Failed': '❌', 'Running': '🔄', 'Pending Review': '👁', 'Merged': '🔀', 'Rejected': '🚫'}.get(status, '⏳')
    print(f'  {emoji} [{status:<16}] {title}')
    if branch and branch != '?':
        print(f'     Branch: {branch}')
"
}

cmd_review() {
  check_server
  local run_id="${1:-}"
  
  if [[ -z "$run_id" ]]; then
    err "Usage: peel-sprint.sh review <runId>"
    exit 1
  fi
  
  local result
  result=$(mcp_call "parallel_status" "{\"runId\":\"${run_id}\"}")
  
  # Find executions pending review
  local pending
  pending=$(echo "$result" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
executions = data.get('executions', [])
pending = [e for e in executions if e.get('status') in ('Pending Review', 'Completed')]
for e in pending:
    eid = e.get('executionId', e.get('id', ''))
    title = e.get('title', '')[:60]
    branch = e.get('branch', '')
    print(f'{eid}|{title}|{branch}')
")
  
  if [[ -z "$pending" ]]; then
    log "No executions pending review."
    return
  fi
  
  echo ""
  echo "${BOLD}Executions pending review:${NC}"
  echo ""
  
  local i=1
  while IFS='|' read -r eid title branch; do
    echo "  ${CYAN}${i}.${NC} ${title}"
    if [[ -n "$branch" ]]; then
      echo "     Branch: ${branch}"
    fi
    
    # Show diff
    log "Fetching diff for execution ${eid}..."
    local diff_result
    diff_result=$(mcp_call "parallel_diff" "{\"runId\":\"${run_id}\",\"executionId\":\"${eid}\"}" 2>/dev/null || echo "")
    if [[ -n "$diff_result" ]]; then
      echo "$diff_result" | head -30
      local diff_lines
      diff_lines=$(echo "$diff_result" | wc -l)
      if [[ $diff_lines -gt 30 ]]; then
        echo "  ... (${diff_lines} total lines, truncated)"
      fi
    fi
    
    echo ""
    echo -n "  Action? [${GREEN}a${NC}]pprove / [${RED}r${NC}]eject / [${YELLOW}s${NC}]kip / [${BLUE}d${NC}]iff: "
    read -r action
    
    case "$action" in
      a|approve)
        mcp_call "parallel_approve" "{\"runId\":\"${run_id}\",\"executionId\":\"${eid}\"}" >/dev/null
        ok "Approved: ${title}"
        ;;
      r|reject)
        echo -n "  Rejection reason: "
        read -r reason
        mcp_call "parallel_reject" "{\"runId\":\"${run_id}\",\"executionId\":\"${eid}\",\"reason\":\"${reason}\"}" >/dev/null
        warn "Rejected: ${title}"
        ;;
      d|diff)
        echo "$diff_result" | less
        echo -n "  Action? [${GREEN}a${NC}]pprove / [${RED}r${NC}]eject: "
        read -r action2
        case "$action2" in
          a|approve)
            mcp_call "parallel_approve" "{\"runId\":\"${run_id}\",\"executionId\":\"${eid}\"}" >/dev/null
            ok "Approved: ${title}"
            ;;
          r|reject)
            echo -n "  Rejection reason: "
            read -r reason
            mcp_call "parallel_reject" "{\"runId\":\"${run_id}\",\"executionId\":\"${eid}\",\"reason\":\"${reason}\"}" >/dev/null
            warn "Rejected: ${title}"
            ;;
        esac
        ;;
      s|skip|*)
        log "Skipped: ${title}"
        ;;
    esac
    
    ((i++))
  done <<< "$pending"
}

cmd_list() {
  cmd_status
}

cmd_audit() {
  log "Audit mode: scanning Peel codebase for issues..."
  log ""
  log "This command runs common static checks. For a full AI-powered audit,"
  log "use the MCP 'Issue Analysis' template or run this in Copilot."
  echo ""
  
  # Quick static checks
  echo "${BOLD}Force unwraps (URL):${NC}"
  grep -rn 'URL(string:.*!)' "$PROJECT_DIR/Shared/" --include="*.swift" 2>/dev/null | head -10 || echo "  None found ✅"
  echo ""
  
  echo "${BOLD}Combine imports (should be replaced):${NC}"
  grep -rn 'import Combine' "$PROJECT_DIR/Shared/" --include="*.swift" 2>/dev/null | head -10 || echo "  None found ✅"
  echo ""
  
  echo "${BOLD}TODO/FIXME comments:${NC}"
  grep -rn 'TODO\|FIXME\|HACK\|XXX' "$PROJECT_DIR/Shared/" --include="*.swift" 2>/dev/null | head -20 || echo "  None found ✅"
  echo ""
  
  echo "${BOLD}.constant() bindings (potential alert bugs):${NC}"
  grep -rn '\.constant(' "$PROJECT_DIR/Shared/" --include="*.swift" 2>/dev/null | grep -i 'alert\|presented' | head -10 || echo "  None found ✅"
  echo ""
  
  echo "${BOLD}Files over 500 lines:${NC}"
  find "$PROJECT_DIR/Shared/" -name "*.swift" -exec wc -l {} + 2>/dev/null | sort -rn | head -15
  echo ""
  
  echo "${BOLD}Deprecated patterns:${NC}"
  echo "  ObservableObject:  $(grep -rn 'ObservableObject' "$PROJECT_DIR/Shared/" --include="*.swift" 2>/dev/null | wc -l | tr -d ' ') occurrences"
  echo "  @StateObject:      $(grep -rn '@StateObject' "$PROJECT_DIR/Shared/" --include="*.swift" 2>/dev/null | wc -l | tr -d ' ') occurrences"
  echo "  NavigationView:    $(grep -rn 'NavigationView' "$PROJECT_DIR/Shared/" --include="*.swift" 2>/dev/null | wc -l | tr -d ' ') occurrences"
  echo "  DispatchQueue.main: $(grep -rn 'DispatchQueue.main' "$PROJECT_DIR/Shared/" --include="*.swift" 2>/dev/null | wc -l | tr -d ' ') occurrences"
}

cmd_help() {
  cat << 'EOF'
peel-sprint.sh — High-velocity iteration pipeline for Peel

COMMANDS:
  audit                     Scan codebase for common issues
  dispatch <task-file>      Launch parallel worktree batch from JSON task file
  status [runId]            Show status of a run (or all runs if no ID)
  review <runId>            Interactive review of pending branches
  configure                 Set chain queue concurrency
  list                      List all parallel runs

ENVIRONMENT:
  PEEL_PORT=8765            MCP server port
  PEEL_CONCURRENCY=3        Max concurrent chains
  PEEL_TEMPLATE="Guarded Implementation"  Chain template
  PEEL_REVIEW_GATE=true     Require review before merge
  PEEL_AUTO_MERGE=true      Auto-merge after approval

EXAMPLES:
  # Run audit to find issues
  ./Tools/peel-sprint.sh audit

  # Set concurrency to 3
  PEEL_CONCURRENCY=3 ./Tools/peel-sprint.sh configure

  # Dispatch a batch
  ./Tools/peel-sprint.sh dispatch tmp/sprint-tasks.json

  # Monitor progress
  ./Tools/peel-sprint.sh status

  # Review and approve/reject
  ./Tools/peel-sprint.sh review <runId>

TASK FILE FORMAT (JSON array):
  [
    {
      "title": "Fix bug in FooView (#123)",
      "prompt": "Detailed implementation instructions...",
      "focusPaths": ["Shared/Views/FooView.swift"]
    }
  ]

PIPELINE WORKFLOW:
  1. Run audit → identify issues
  2. Create GitHub issues (use Tools/gh-issue-create.sh)
  3. Write task file with implementation prompts
  4. Configure concurrency
  5. Dispatch batch
  6. Monitor status
  7. Review diffs → approve/reject
  8. Branches auto-merge on approval

EOF
}

# ─── Main ─────────────────────────────────────────────────────────────

case "${1:-help}" in
  audit)      cmd_audit ;;
  dispatch)   cmd_dispatch "${2:-}" ;;
  status)     cmd_status "${2:-}" ;;
  review)     cmd_review "${2:-}" ;;
  configure)  cmd_configure ;;
  list)       cmd_list ;;
  help|--help|-h) cmd_help ;;
  *)
    err "Unknown command: $1"
    cmd_help
    exit 1
    ;;
esac
