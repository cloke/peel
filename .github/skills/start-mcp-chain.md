# Skill: Start MCP Chain via CLI

Goal: Start an MCP chain using the Peel app + MCP CLI. Do not create worktrees manually.

## When to use
- User asks to start a chain or run MCP work in worktrees.

## Steps
1. Ensure repo is clean. If not, commit + push (unless user says not to).
2. Launch Peel with MCP enabled and wait for server:
   - Tools/build-and-launch.sh --wait-for-server
3. Run the chain via CLI:
   - cd Tools/PeelCLI
   - swift run PeelCLI chains-run --prompt "<prompt>" --template-name "<name>"
4. Confirm MCP server responds and worktrees were created by the app.

## Notes
- Use --template-id instead of --template-name when provided.
- Do not create worktrees with git unless explicitly requested.
