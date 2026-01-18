# Skill: MCP CLI Quick Check

Goal: Verify MCP server is up and respond to tools/list.

## When to use
- After launching Peel with MCP enabled.

## Steps
1. cd Tools/PeelCLI
2. swift run PeelCLI tools-list
3. If it fails, re-run build-and-launch.sh --wait-for-server and retry.

## Notes
- Default port is 8765 unless overridden.
