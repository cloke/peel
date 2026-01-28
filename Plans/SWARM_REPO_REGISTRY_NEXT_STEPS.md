# Swarm RepoRegistry - Next Steps

## Status: In Progress

**Date:** January 28, 2026  
**Commit:** `e6e991c` (pushed to main)

---

## Problem Solved

When the brain dispatches a task with `workingDirectory: /Users/cloken/code/KitchenSink`, the worker receives that path but it doesn't exist on the worker machine. Different machines have the same repo at different paths:

- Brain: `/Users/cloken/code/KitchenSink`
- Worker: `/Users/bob/kitchen-sink` (example)

**Solution:** Use git remote URLs as stable identifiers. Both machines share the same remote (`github.com/cloke/peel`), so we map that to local paths on each machine.

---

## What's Implemented

### New Files
- **RepoRegistry.swift** - Maps normalized git remote URLs to local paths
  - `registerRepo(at:)` - Auto-discovers remote URL via `git remote get-url origin`
  - `registerRepo(remoteURL:localPath:)` - Explicit registration
  - `getLocalPath(for:)` - Look up local path from remote URL
  - `resolveWorkingDirectory(for:)` - Resolve ChainRequest to local path
  - `normalizeRemoteURL(_:)` - Handles SSH, HTTPS, git:// formats

### Modified Files
- **DistributedTypes.swift** - Added `repoRemoteURL: String?` to `ChainRequest`
- **SwarmCoordinator.swift** - Calls `RepoRegistry.shared.resolveWorkingDirectory(for: request)` before task execution
- **SwarmToolsHandler.swift** - Added handlers for `swarm.register-repo` and `swarm.repos`
- **MCPServerService.swift** - Added tool definitions for the new tools

### New MCP Tools
| Tool | Description |
|------|-------------|
| `swarm.register-repo` | Register a local repo path, auto-detects remote URL |
| `swarm.repos` | List all registered repos and their URL mappings |

---

## Current State

1. ✅ Brain started with repo registered:
   ```
   remoteURL: github.com/cloke/peel
   localPath: /Users/cloken/code/KitchenSink
   ```

2. ✅ Worker connected (256GB RAM, 64 GPU cores machine)

3. ⚠️ Task dispatched but stuck in-flight:
   - Branch: `swarm/create-a-file-called-test-swar-09aaf1b6`
   - Status: in-flight for 4+ minutes
   - Likely cause: **Worker hasn't registered its local repo path**

---

## Next Steps

### 1. Register Repo on Worker (REQUIRED)

On the worker machine, run:
```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
    "name":"swarm.register-repo",
    "arguments":{"path":"/path/to/local/repo"}
  }}'
```

Replace `/path/to/local/repo` with the actual path where the worker has the Peel repo cloned.

### 2. Update Worker to Latest Code

The worker is at `c0e4371`, should be at `e6e991c`:
```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
    "name":"swarm.update-workers",
    "arguments":{}
  }}'
```

### 3. Test Task Dispatch

After worker registers its repo:
```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
    "name":"swarm.dispatch",
    "arguments":{
      "prompt":"Create a file called test-swarm.txt with Hello from swarm",
      "workingDirectory":"/Users/cloken/code/KitchenSink"
    }
  }}'
```

### 4. Verify Success

Check task results:
```bash
curl -X POST http://127.0.0.1:8765/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
    "name":"swarm.tasks",
    "arguments":{"limit":5}
  }}'
```

Expected: Task shows `status: completed` with branch info.

---

## Future Improvements

### Auto-Registration on Worker Start
Modify `swarm.start` for worker role to auto-register repos:
```json
{
  "name": "swarm.start",
  "arguments": {
    "role": "worker",
    "repos": ["/path/to/local/repo"]
  }
}
```

### Persist Registry
Currently RepoRegistry is in-memory. Consider:
- Save to UserDefaults or JSON file
- Restore on app launch
- Auto-discover repos in common locations

### Error Handling
When worker can't resolve a path:
- Return clear error message: "Repo not registered on worker"
- Include the remote URL that needs to be registered
- Suggest the `swarm.register-repo` command

---

## Debug Commands

```bash
# Check swarm status
curl -s http://127.0.0.1:8765/rpc -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.status","arguments":{}}}' | jq .

# Check workers
curl -s http://127.0.0.1:8765/rpc -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.workers","arguments":{}}}' | jq .

# Check registered repos
curl -s http://127.0.0.1:8765/rpc -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.repos","arguments":{}}}' | jq .

# Check branch queue
curl -s http://127.0.0.1:8765/rpc -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.branch-queue","arguments":{}}}' | jq .

# Check task results
curl -s http://127.0.0.1:8765/rpc -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"swarm.tasks","arguments":{"limit":10}}}' | jq .
```
