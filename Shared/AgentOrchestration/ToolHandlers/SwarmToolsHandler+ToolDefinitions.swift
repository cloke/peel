//
//  SwarmToolsHandler+ToolDefinitions.swift
//  Peel
//
//  Tool definitions for SwarmToolsHandler.
//  See also MCPServerService+ToolDefinitions.swift for aggregation.
//  Managed separately per #300 and #301.
//

import Foundation
import MCPCore

// MARK: - Tool Definitions

extension SwarmToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "swarm.start",
        description: "Start the distributed swarm coordinator. Role can be 'brain' (dispatch work), 'worker' (execute work), or 'hybrid' (both).",
        inputSchema: [
          "type": "object",
          "properties": [
            "role": [
              "type": "string",
              "enum": ["brain", "worker", "hybrid"],
              "description": "The role for this Peel instance in the swarm"
            ],
            "port": [
              "type": "integer",
              "description": "Port to listen on (default: 8766)"
            ]
          ],
          "required": ["role"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.stop",
        description: "Stop the distributed swarm coordinator and disconnect from all peers.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.status",
        description: "Get the current swarm status including role, active state, and statistics.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.diagnostics",
        description: "Dev diagnostics snapshot: peers, discovery, and RAG artifact sync status.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.rag.sync",
        description: "Request a Local RAG artifact sync to or from a peel. Direction is 'push' or 'pull'. Optionally scope to a single repo by repoIdentifier.",
        inputSchema: [
          "type": "object",
          "properties": [
            "direction": [
              "type": "string",
              "enum": ["push", "pull"],
              "description": "Sync direction: push sends artifacts to the peel, pull fetches from it"
            ],
            "workerId": [
              "type": "string",
              "description": "Optional worker device ID (defaults to first connected peel)"
            ],
            "repoIdentifier": [
              "type": "string",
              "description": "Optional normalized git remote URL (e.g. 'github.com/org/repo') to sync only one repo. If omitted, syncs all repos."
            ]
          ],
          "required": ["direction"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.workers",
        description: "List all connected workers with their capabilities.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.dispatch",
        description: "Dispatch a task to the swarm for execution by a worker.",
        inputSchema: [
          "type": "object",
          "properties": [
            "prompt": [
              "type": "string",
              "description": "The prompt/task to execute"
            ],
            "workingDirectory": [
              "type": "string",
              "description": "The git repository path on the worker where the task should execute (required for worktree isolation)"
            ],
            "templateId": [
              "type": "string",
              "description": "Optional template ID to use"
            ],
            "priority": [
              "type": "string",
              "enum": ["low", "normal", "high", "critical"],
              "description": "Task priority (default: normal)"
            ]
          ],
          "required": ["prompt", "workingDirectory"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.connect",
        description: "Manually connect to a peer at a specific address. Use for debugging or when auto-discovery fails.",
        inputSchema: [
          "type": "object",
          "properties": [
            "address": [
              "type": "string",
              "description": "IP address or hostname of the peer"
            ],
            "port": [
              "type": "integer",
              "description": "Port number (default: 8766)"
            ]
          ],
          "required": ["address"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.discovered",
        description: "List peers discovered via Bonjour (not yet connected).",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.tasks",
        description: "Get completed task results from the swarm. Returns recent task outputs with worker info.",
        inputSchema: [
          "type": "object",
          "properties": [
            "taskId": [
              "type": "string",
              "description": "Optional: Get results for a specific task ID"
            ],
            "limit": [
              "type": "integer",
              "description": "Maximum number of results to return (default: 10)"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.update-workers",
        description: "Trigger all connected workers to pull latest code, rebuild, and restart. Workers will disconnect briefly during restart.",
        inputSchema: [
          "type": "object",
          "properties": [
            "force": [
              "type": "boolean",
              "description": "Force rebuild even if no new commits (default: false)"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.update-log",
        description: "Fetch the latest lines from the worker self-update log.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lines": [
              "type": "integer",
              "description": "Number of log lines to return (default: 200, max: 500)"
            ],
            "workerId": [
              "type": "string",
              "description": "Specific worker ID to target (optional, defaults to first available)"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.direct-command",
        description: "Execute a shell command directly on a worker without LLM involvement. Useful for debugging and administrative tasks.",
        inputSchema: [
          "type": "object",
          "properties": [
            "command": [
              "type": "string",
              "description": "The command to execute"
            ],
            "args": [
              "type": "array",
              "items": ["type": "string"],
              "description": "Command arguments"
            ],
            "workingDirectory": [
              "type": "string",
              "description": "Working directory for the command (optional)"
            ],
            "workerId": [
              "type": "string",
              "description": "Specific worker ID to target (optional, defaults to first available)"
            ]
          ],
          "required": ["command"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.branch-queue",
        description: "View the branch queue status showing in-flight branches being worked on and completed branches ready for PR.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.pr-queue",
        description: "View the PR queue status showing pending operations and created PRs with their labels.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.create-pr",
        description: "Manually create a PR for a completed swarm task. Use when auto-PR is disabled or you want to create a PR for a specific task.",
        inputSchema: [
          "type": "object",
          "properties": [
            "taskId": [
              "type": "string",
              "description": "The task ID to create a PR for (must be in completed branches)"
            ],
            "title": [
              "type": "string",
              "description": "Optional custom PR title (defaults to task prompt)"
            ]
          ],
          "required": ["taskId"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.setup-labels",
        description: "Ensure all Peel PR labels exist in a repository. Creates peel:created, peel:approved, peel:needs-review, peel:needs-help, peel:conflict, and peel:merged labels with proper colors. Run once per repo before using swarm PR features.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Path to the git repository"
            ]
          ],
          "required": ["repoPath"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.register-repo",
        description: "Register a local repository path with the swarm. This maps the repo's git remote URL to the local path, enabling distributed tasks to work across machines with different folder structures.",
        inputSchema: [
          "type": "object",
          "properties": [
            "path": [
              "type": "string",
              "description": "The local path to the git repository"
            ],
            "remoteURL": [
              "type": "string",
              "description": "Optional: Explicit remote URL (if not provided, will be auto-detected from the git repo)"
            ]
          ],
          "required": ["path"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.repos",
        description: "List all registered repositories and their remote URL mappings.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.firestore.auth",
        description: "Check Firebase authentication status for Firestore swarm coordination.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.firestore.swarms",
        description: "List all Firestore swarms the current user belongs to (for debugging).",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.firestore.create",
        description: "Create a new Firestore swarm.",
        inputSchema: [
          "type": "object",
          "properties": [
            "name": [
              "type": "string",
              "description": "Name for the new swarm"
            ]
          ],
          "required": ["name"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.firestore.debug",
        description: "Debug query: show raw Firestore swarm data and query parameters.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.firestore.activity",
        description: "Get recent activity log entries for swarm debugging. Shows worker events, task status changes, messages, and errors.",
        inputSchema: [
          "type": "object",
          "properties": [
            "limit": [
              "type": "integer",
              "description": "Maximum number of entries to return (default: 50)"
            ],
            "filter": [
              "type": "string",
              "description": "Filter by event type: worker_online, worker_offline, task_submitted, task_claimed, task_completed, error, etc."
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.firestore.workers",
        description: "List workers registered in a Firestore swarm. Shows status, last heartbeat, and capabilities.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to list workers from"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.firestore.register-worker",
        description: "Register this device as a worker in a Firestore swarm. Requires contributor+ permission.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to register as a worker"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.firestore.unregister-worker",
        description: "Unregister this device as a worker from a Firestore swarm.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to unregister from"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.firestore.submit-task",
        description: "Submit a task to a Firestore swarm for remote execution. Requires contributor+ permission.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to submit the task to"
            ],
            "templateName": [
              "type": "string",
              "description": "Name of the chain template to execute"
            ],
            "prompt": [
              "type": "string",
              "description": "The prompt/task description"
            ],
            "workingDirectory": [
              "type": "string",
              "description": "Working directory for the task"
            ],
            "repoRemoteURL": [
              "type": "string",
              "description": "Git remote URL for the repo (optional)"
            ],
            "priority": [
              "type": "integer",
              "description": "Priority (0=low, 1=normal, 2=high, 3=critical)"
            ]
          ],
          "required": ["swarmId", "templateName", "prompt", "workingDirectory"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.firestore.tasks",
        description: "List pending/running tasks in a Firestore swarm.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to list tasks from"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.firestore.rag.artifacts",
        description: "List RAG artifacts available in a Firestore swarm. Shows version, size, and upload info.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to list artifacts from"
            ]
          ],
          "required": ["swarmId"]
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "swarm.firestore.rag.push",
        description: "Push local RAG artifacts to Firestore swarm for sharing with other members. Requires contributor+ role. Uses safe per-repo sync by default — auto-detects repoIdentifier from git remote if not provided.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to push artifacts to"
            ],
            "repoPath": [
              "type": "string",
              "description": "Path to the repository whose RAG index to push"
            ],
            "repoIdentifier": [
              "type": "string",
              "description": "Repository identifier (e.g. github.com/org/repo). Auto-detected from git remote if not provided. Enables safe per-repo sync."
            ],
            "fullDB": [
              "type": "boolean",
              "description": "Force legacy full-DB sync (replaces entire database on pull side). Defaults to false. NOT RECOMMENDED — overwrites all repos on the receiving machine."
            ]
          ],
          "required": ["swarmId", "repoPath"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.firestore.rag.pull",
        description: "Pull RAG artifacts from Firestore swarm to local storage. Requires reader+ role. Uses safe per-repo sync by default — auto-detects repoIdentifier from git remote if not provided.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID to pull artifacts from"
            ],
            "artifactId": [
              "type": "string",
              "description": "The artifact ID (version) to pull"
            ],
            "repoPath": [
              "type": "string",
              "description": "Path to the repository to import the RAG index into"
            ],
            "repoIdentifier": [
              "type": "string",
              "description": "Repository identifier (e.g. github.com/org/repo). Auto-detected from git remote if not provided. Enables safe per-repo sync."
            ],
            "fullDB": [
              "type": "boolean",
              "description": "Force legacy full-DB sync (replaces entire database). Defaults to false. NOT RECOMMENDED — overwrites all repos and embeddings."
            ]
          ],
          "required": ["swarmId", "artifactId", "repoPath"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "swarm.firestore.rag.delete",
        description: "Delete a RAG artifact from Firestore swarm. Requires admin+ role.",
        inputSchema: [
          "type": "object",
          "properties": [
            "swarmId": [
              "type": "string",
              "description": "The swarm ID"
            ],
            "artifactId": [
              "type": "string",
              "description": "The artifact ID (version) to delete"
            ]
          ],
          "required": ["swarmId", "artifactId"]
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "firebase.emulator.install",
        description: "Install Firebase emulator dependencies via Homebrew/npm. Installs firebase-tools and Java (Temurin JDK) if missing. Safe to call multiple times — skips already-installed components.",
        inputSchema: [
          "type": "object",
          "properties": [
            "components": [
              "type": "array",
              "items": ["type": "string", "enum": ["firebase-tools", "java"]],
              "description": "Which components to install. Default: both firebase-tools and java."
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "firebase.emulator.status",
        description: "Check Firebase emulator status: whether emulators are configured, running, and reachable. Shows connection details for both Firestore and Auth emulators.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "firebase.emulator.start",
        description: "Start the Firebase Emulator Suite locally (Firestore + Auth). Use lan=true to bind to all interfaces so other machines can connect. Use seed=true to import previously exported test data.",
        inputSchema: [
          "type": "object",
          "properties": [
            "lan": [
              "type": "boolean",
              "description": "Bind to 0.0.0.0 for LAN access (default: false = localhost only)"
            ],
            "seed": [
              "type": "boolean",
              "description": "Import seed data from tmp/firebase-seed/ (default: false)"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "firebase.emulator.stop",
        description: "Stop the Firebase Emulator Suite. Data is auto-exported to tmp/firebase-seed/ on exit.",
        inputSchema: [
          "type": "object",
          "properties": [:],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "firebase.emulator.configure",
        description: "Configure the app to use Firebase emulators instead of production. Sets UserDefaults so the app connects to emulators on next launch. Both LAN machines should point to the same emulator host.",
        inputSchema: [
          "type": "object",
          "properties": [
            "host": [
              "type": "string",
              "description": "Emulator host IP or hostname (default: localhost). Use a LAN IP for multi-machine testing."
            ],
            "enable": [
              "type": "boolean",
              "description": "Enable (true) or disable (false) emulator mode. Default: true"
            ]
          ],
          "required": []
        ],
        category: .swarm,
        isMutating: true
      ),
    ]
  }
}

