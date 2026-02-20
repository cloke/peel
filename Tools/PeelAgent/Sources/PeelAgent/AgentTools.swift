import Foundation

/// Defines all tools available to the agent
enum AgentTools {
  static func all() -> [ToolDefinition] {
    [
      readFile,
      writeFile,
      replaceInFile,
      listDirectory,
      searchFiles,
      runCommand,
      gitStatus,
      gitDiff,
      gitLog,
      gitCommit,
    ]
  }

  static let readFile = ToolDefinition(
    name: "read_file",
    description: "Read the contents of a file. Returns the full file contents or a specific line range.",
    input_schema: .init(
      type: "object",
      properties: [
        "path": .init(type: "string", description: "Absolute or relative path to the file", items: nil, enum: nil),
        "start_line": .init(type: "integer", description: "Optional: 1-based start line number", items: nil, enum: nil),
        "end_line": .init(type: "integer", description: "Optional: 1-based end line number", items: nil, enum: nil),
      ],
      required: ["path"]
    )
  )

  static let writeFile = ToolDefinition(
    name: "write_file",
    description: "Write content to a file. Creates the file if it doesn't exist, or overwrites if it does. Creates parent directories as needed.",
    input_schema: .init(
      type: "object",
      properties: [
        "path": .init(type: "string", description: "Absolute or relative path to the file", items: nil, enum: nil),
        "content": .init(type: "string", description: "The content to write to the file", items: nil, enum: nil),
      ],
      required: ["path", "content"]
    )
  )

  static let replaceInFile = ToolDefinition(
    name: "replace_in_file",
    description: "Replace an exact string in a file with new content. The old_string must match exactly (including whitespace and indentation). Include enough context lines to uniquely identify the location.",
    input_schema: .init(
      type: "object",
      properties: [
        "path": .init(type: "string", description: "Path to the file to edit", items: nil, enum: nil),
        "old_string": .init(type: "string", description: "The exact text to find and replace (must match exactly)", items: nil, enum: nil),
        "new_string": .init(type: "string", description: "The replacement text", items: nil, enum: nil),
      ],
      required: ["path", "old_string", "new_string"]
    )
  )

  static let listDirectory = ToolDefinition(
    name: "list_directory",
    description: "List the contents of a directory. Returns file and directory names with / suffix for directories.",
    input_schema: .init(
      type: "object",
      properties: [
        "path": .init(type: "string", description: "Path to the directory (default: working directory)", items: nil, enum: nil),
      ],
      required: nil
    )
  )

  static let searchFiles = ToolDefinition(
    name: "search_files",
    description: "Search for files matching a pattern (glob or regex), and optionally search file contents with grep.",
    input_schema: .init(
      type: "object",
      properties: [
        "pattern": .init(type: "string", description: "Search pattern: a grep regex for content search, or a glob for file name search", items: nil, enum: nil),
        "path": .init(type: "string", description: "Directory to search in (default: working directory)", items: nil, enum: nil),
        "file_pattern": .init(type: "string", description: "Optional glob to filter files (e.g. '*.swift')", items: nil, enum: nil),
        "mode": .init(type: "string", description: "Search mode: 'content' (grep) or 'files' (find). Default: 'content'", items: nil, enum: ["content", "files"]),
      ],
      required: ["pattern"]
    )
  )

  static let runCommand = ToolDefinition(
    name: "run_command",
    description: "Execute a shell command and return its output. Commands run in the working directory. Use for builds, tests, installations, or any terminal operation.",
    input_schema: .init(
      type: "object",
      properties: [
        "command": .init(type: "string", description: "The shell command to execute", items: nil, enum: nil),
        "timeout": .init(type: "integer", description: "Timeout in seconds (default: 30)", items: nil, enum: nil),
      ],
      required: ["command"]
    )
  )

  static let gitStatus = ToolDefinition(
    name: "git_status",
    description: "Get the current git status (branch, staged/unstaged changes, untracked files).",
    input_schema: .init(
      type: "object",
      properties: [:],
      required: nil
    )
  )

  static let gitDiff = ToolDefinition(
    name: "git_diff",
    description: "Show git diff for working directory changes or between commits.",
    input_schema: .init(
      type: "object",
      properties: [
        "staged": .init(type: "boolean", description: "Show staged changes (default: false, shows unstaged)", items: nil, enum: nil),
        "file": .init(type: "string", description: "Optional: specific file to diff", items: nil, enum: nil),
      ],
      required: nil
    )
  )

  static let gitLog = ToolDefinition(
    name: "git_log",
    description: "Show recent git log entries.",
    input_schema: .init(
      type: "object",
      properties: [
        "count": .init(type: "integer", description: "Number of commits to show (default: 10)", items: nil, enum: nil),
        "oneline": .init(type: "boolean", description: "Use one-line format (default: true)", items: nil, enum: nil),
      ],
      required: nil
    )
  )

  static let gitCommit = ToolDefinition(
    name: "git_commit",
    description: "Stage files and create a git commit.",
    input_schema: .init(
      type: "object",
      properties: [
        "message": .init(type: "string", description: "Commit message", items: nil, enum: nil),
        "files": .init(type: "array", description: "Files to stage (default: all changed files)", items: .init(type: "string"), enum: nil),
        "all": .init(type: "boolean", description: "Stage all changes with -a (default: false)", items: nil, enum: nil),
      ],
      required: ["message"]
    )
  )
}
