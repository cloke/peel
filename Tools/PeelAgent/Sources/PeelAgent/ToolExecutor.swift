import Foundation

/// Executes tool calls requested by the LLM
final class ToolExecutor: Sendable {
  let workingDirectory: String

  init(workingDirectory: String) {
    self.workingDirectory = workingDirectory
  }

  /// Execute a tool and return the result string
  func execute(name: String, input: [String: JSONValue]) async -> ToolResult {
    switch name {
    case "read_file":
      return await readFile(input)
    case "write_file":
      return await writeFile(input)
    case "replace_in_file":
      return await replaceInFile(input)
    case "list_directory":
      return await listDirectory(input)
    case "search_files":
      return await searchFiles(input)
    case "run_command":
      return await runCommand(input)
    case "git_status":
      return await gitStatus()
    case "git_diff":
      return await gitDiff(input)
    case "git_log":
      return await gitLog(input)
    case "git_commit":
      return await gitCommit(input)
    default:
      return .error("Unknown tool: \(name)")
    }
  }

  /// Whether a tool requires user confirmation before executing
  func requiresApproval(_ name: String, input: [String: JSONValue]) -> Bool {
    switch name {
    case "write_file", "replace_in_file", "git_commit":
      return true
    case "run_command":
      // Read-only commands don't need approval
      let cmd = input["command"]?.stringValue ?? ""
      let readOnlyPrefixes = ["cat ", "ls ", "find ", "grep ", "head ", "tail ", "wc ", "echo ", "pwd", "which ", "type ", "file "]
      return !readOnlyPrefixes.contains(where: { cmd.hasPrefix($0) })
    default:
      return false
    }
  }

  // MARK: - Tool Implementations

  private func readFile(_ input: [String: JSONValue]) async -> ToolResult {
    guard let path = input["path"]?.stringValue else {
      return .error("Missing required parameter: path")
    }
    let fullPath = resolvePath(path)

    guard FileManager.default.fileExists(atPath: fullPath) else {
      return .error("File not found: \(path)")
    }

    do {
      let content = try String(contentsOfFile: fullPath, encoding: .utf8)
      let lines = content.components(separatedBy: "\n")

      let startLine = input["start_line"]?.intValue
      let endLine = input["end_line"]?.intValue

      if let start = startLine {
        let s = max(1, start) - 1
        let e = min(endLine ?? lines.count, lines.count)
        let slice = lines[s..<e]
        let numbered = slice.enumerated().map { "\(s + $0.offset + 1): \($0.element)" }
        return .success(numbered.joined(separator: "\n"))
      }

      // For large files, show line count
      if lines.count > 500 {
        let preview = lines.prefix(100).enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        return .success("File has \(lines.count) lines. Showing first 100:\n\n\(preview)\n\n... (\(lines.count - 100) more lines)")
      }

      return .success(content)
    } catch {
      return .error("Failed to read file: \(error.localizedDescription)")
    }
  }

  private func writeFile(_ input: [String: JSONValue]) async -> ToolResult {
    guard let path = input["path"]?.stringValue else {
      return .error("Missing required parameter: path")
    }
    guard let content = input["content"]?.stringValue else {
      return .error("Missing required parameter: content")
    }

    let fullPath = resolvePath(path)

    do {
      // Create parent directories
      let dir = (fullPath as NSString).deletingLastPathComponent
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

      try content.write(toFile: fullPath, atomically: true, encoding: .utf8)

      let lines = content.components(separatedBy: "\n").count
      return .success("Wrote \(lines) lines to \(path)")
    } catch {
      return .error("Failed to write file: \(error.localizedDescription)")
    }
  }

  private func replaceInFile(_ input: [String: JSONValue]) async -> ToolResult {
    guard let path = input["path"]?.stringValue else {
      return .error("Missing required parameter: path")
    }
    guard let oldString = input["old_string"]?.stringValue else {
      return .error("Missing required parameter: old_string")
    }
    guard let newString = input["new_string"]?.stringValue else {
      return .error("Missing required parameter: new_string")
    }

    let fullPath = resolvePath(path)

    guard FileManager.default.fileExists(atPath: fullPath) else {
      return .error("File not found: \(path)")
    }

    do {
      let content = try String(contentsOfFile: fullPath, encoding: .utf8)

      // Count occurrences
      let occurrences = content.components(separatedBy: oldString).count - 1

      if occurrences == 0 {
        return .error("old_string not found in file. Make sure it matches exactly, including whitespace.")
      }

      if occurrences > 1 {
        return .error("old_string matches \(occurrences) locations. Add more context to uniquely identify the target.")
      }

      // Exactly one match — do the replacement
      let updated = content.replacingOccurrences(of: oldString, with: newString)
      try updated.write(toFile: fullPath, atomically: true, encoding: .utf8)

      let oldLines = oldString.components(separatedBy: "\n").count
      let newLines = newString.components(separatedBy: "\n").count
      return .success("Replaced \(oldLines) lines with \(newLines) lines in \(path)")
    } catch {
      return .error("Failed to edit file: \(error.localizedDescription)")
    }
  }

  private func listDirectory(_ input: [String: JSONValue]) async -> ToolResult {
    let path = input["path"]?.stringValue ?? "."
    let fullPath = resolvePath(path)

    do {
      let contents = try FileManager.default.contentsOfDirectory(atPath: fullPath)
      var result: [String] = []

      for item in contents.sorted() {
        var isDir: ObjCBool = false
        let itemPath = (fullPath as NSString).appendingPathComponent(item)
        FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir)
        result.append(isDir.boolValue ? "\(item)/" : item)
      }

      return .success(result.joined(separator: "\n"))
    } catch {
      return .error("Failed to list directory: \(error.localizedDescription)")
    }
  }

  private func searchFiles(_ input: [String: JSONValue]) async -> ToolResult {
    guard let pattern = input["pattern"]?.stringValue else {
      return .error("Missing required parameter: pattern")
    }
    let searchPath = resolvePath(input["path"]?.stringValue ?? ".")
    let mode = input["mode"]?.stringValue ?? "content"
    let filePattern = input["file_pattern"]?.stringValue

    if mode == "files" {
      // Use find to search for files by name
      var cmd = "find '\(searchPath)' -name '\(pattern)' -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/build/*'"
      if let fp = filePattern {
        cmd += " -name '\(fp)'"
      }
      cmd += " | head -50"
      return await shell(cmd)
    } else {
      // Grep for content
      var cmd = "grep -rn --include='*'"
      if let fp = filePattern {
        cmd = "grep -rn --include='\(fp)'"
      }
      cmd += " '\(pattern)' '\(searchPath)' 2>/dev/null | head -50"
      return await shell(cmd)
    }
  }

  private func runCommand(_ input: [String: JSONValue]) async -> ToolResult {
    guard let command = input["command"]?.stringValue else {
      return .error("Missing required parameter: command")
    }
    let timeout = input["timeout"]?.intValue ?? 30
    return await shell(command, timeout: timeout)
  }

  private func gitStatus() async -> ToolResult {
    let branch = await shell("git rev-parse --abbrev-ref HEAD 2>/dev/null")
    let status = await shell("git status --short 2>/dev/null")
    let branchName = branch.content.trimmingCharacters(in: .whitespacesAndNewlines)
    return .success("Branch: \(branchName)\n\n\(status.content)")
  }

  private func gitDiff(_ input: [String: JSONValue]) async -> ToolResult {
    let staged = input["staged"]?.boolValue ?? false
    let file = input["file"]?.stringValue

    var cmd = "git diff"
    if staged { cmd += " --staged" }
    if let f = file { cmd += " -- '\(f)'" }
    cmd += " 2>/dev/null"

    let result = await shell(cmd)
    if result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .success("No changes" + (staged ? " (staged)" : ""))
    }
    return result
  }

  private func gitLog(_ input: [String: JSONValue]) async -> ToolResult {
    let count = input["count"]?.intValue ?? 10
    let oneline = input["oneline"]?.boolValue ?? true

    var cmd = "git --no-pager log -\(count)"
    if oneline {
      cmd += " --oneline"
    } else {
      cmd += " --format='%h %an %ar %s'"
    }
    return await shell(cmd)
  }

  private func gitCommit(_ input: [String: JSONValue]) async -> ToolResult {
    guard let message = input["message"]?.stringValue else {
      return .error("Missing required parameter: message")
    }

    // Stage files
    if let files = input["files"]?.arrayValue {
      let paths = files.compactMap(\.stringValue)
      for path in paths {
        let result = await shell("git add '\(path)'")
        if result.isError { return result }
      }
    } else if input["all"]?.boolValue == true {
      let result = await shell("git add -A")
      if result.isError { return result }
    }

    // Commit
    let escapedMessage = message.replacingOccurrences(of: "'", with: "'\\''")
    return await shell("git commit -m '\(escapedMessage)'")
  }

  // MARK: - Helpers

  private func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    if path.hasPrefix("~") {
      return (path as NSString).expandingTildeInPath
    }
    return (workingDirectory as NSString).appendingPathComponent(path)
  }

  @discardableResult
  private func shell(_ command: String, timeout: Int = 30) async -> ToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()

      // Timeout handling
      let timeoutTask = Task {
        try await Task.sleep(for: .seconds(timeout))
        if process.isRunning {
          process.terminate()
        }
      }

      process.waitUntilExit()
      timeoutTask.cancel()

      let outData = stdout.fileHandleForReading.readDataToEndOfFile()
      let errData = stderr.fileHandleForReading.readDataToEndOfFile()
      let outStr = String(data: outData, encoding: .utf8) ?? ""
      let errStr = String(data: errData, encoding: .utf8) ?? ""

      if process.terminationStatus != 0 {
        let combined = outStr + (errStr.isEmpty ? "" : "\nstderr: \(errStr)")
        return .error("Command exited with status \(process.terminationStatus):\n\(combined)")
      }

      let result = outStr.isEmpty ? errStr : outStr
      return .success(result)
    } catch {
      return .error("Failed to run command: \(error.localizedDescription)")
    }
  }
}

// MARK: - Tool Result

struct ToolResult: Sendable {
  let content: String
  let isError: Bool

  static func success(_ content: String) -> ToolResult {
    ToolResult(content: content, isError: false)
  }

  static func error(_ message: String) -> ToolResult {
    ToolResult(content: message, isError: true)
  }
}
