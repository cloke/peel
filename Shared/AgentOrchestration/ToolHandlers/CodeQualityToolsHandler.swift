//
//  CodeQualityToolsHandler.swift
//  Peel
//
//  MCP tool handler for code quality operations (lint, format, type-check).
//  Auto-detects the project's lint toolchain and provides structured results.
//

import Foundation
import MCPCore
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "CodeQualityToolsHandler")

// MARK: - Lint Configuration Detection

/// Detected lint configuration for a project
struct LintConfig: Sendable {
  /// The package manager (npm, pnpm, yarn, bun, none)
  let packageManager: PackageManager
  /// Whether lint:fix script exists
  let hasLintFix: Bool
  /// Whether lint script exists
  let hasLint: Bool
  /// Individual detected lint tools
  let tools: [LintTool]
  /// Root directory of the project
  let rootPath: String

  enum PackageManager: String, Sendable {
    case pnpm, npm, yarn, bun, none
  }

  struct LintTool: Sendable {
    let name: String
    let configFile: String?
    let fixCommand: String?
    let checkCommand: String?
  }

  /// Best command to run lint checks
  var lintCommand: String? {
    guard hasLint else { return nil }
    return "\(packageManager.runPrefix) lint"
  }

  /// Best command to run lint fix
  var lintFixCommand: String? {
    guard hasLintFix else { return lintCommand }
    return "\(packageManager.runPrefix) lint:fix"
  }
}

extension LintConfig.PackageManager {
  var runPrefix: String {
    switch self {
    case .pnpm: "pnpm run"
    case .npm: "npm run"
    case .yarn: "yarn"
    case .bun: "bun run"
    case .none: ""
    }
  }

  var execPrefix: String {
    switch self {
    case .pnpm: "pnpm exec"
    case .npm: "npx"
    case .yarn: "yarn"
    case .bun: "bunx"
    case .none: ""
    }
  }
}

// MARK: - CodeQualityToolsHandler

/// Handles code quality MCP tools: code.lint, code.detect-lint-config
@MainActor
public final class CodeQualityToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  public let supportedTools: Set<String> = [
    "code.lint",
    "code.detect-lint-config"
  ]

  public init() {}

  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "code.lint":
      return await handleLint(id: id, arguments: arguments)
    case "code.detect-lint-config":
      return await handleDetectConfig(id: id, arguments: arguments)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }

  // MARK: - code.lint

  /// Run lint (and optionally fix) in a project directory
  private func handleLint(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let path) = requireString("path", from: arguments, id: id) else {
      return missingParamError(id: id, param: "path")
    }

    let fix = optionalBool("fix", from: arguments, default: false)
    let filter = optionalString("filter", from: arguments)
    let customCommand = optionalString("command", from: arguments)

    // Detect lint config
    let config = await detectLintConfig(at: path)

    // Determine command to run
    let command: String
    if let customCommand {
      command = customCommand
    } else if fix {
      guard let fixCmd = config.lintFixCommand else {
        return (200, makeResult(id: id, result: [
          "success": false,
          "error": "No lint:fix script found in project",
          "detected": configSummary(config)
        ]))
      }
      command = fixCmd
    } else {
      guard let lintCmd = config.lintCommand else {
        return (200, makeResult(id: id, result: [
          "success": false,
          "error": "No lint script found in project",
          "detected": configSummary(config)
        ]))
      }
      command = lintCmd
    }

    // Build full command with optional filter and working directory
    var fullCommand = "cd \(shellEscape(path)) && "
    if let filter, config.packageManager == .pnpm {
      // For pnpm monorepos, inject --filter
      let scriptName = fix ? "lint:fix" : "lint"
      fullCommand += "pnpm run --filter '\(filter)' \(scriptName) 2>&1"
    } else {
      fullCommand += "\(command) 2>&1"
    }

    logger.info("Running lint: \(fullCommand, privacy: .public)")

    // Execute
    let result = await runShellCommand(fullCommand, timeout: 120)

    // Parse output for structured results
    let parsed = parseLintOutput(result.output, exitCode: result.exitCode)

    var response: [String: Any] = [
      "success": result.exitCode == 0,
      "exitCode": result.exitCode,
      "output": result.output,
      "fix": fix,
      "command": fullCommand,
      "errorCount": parsed.errorCount,
      "warningCount": parsed.warningCount,
      "fixableCount": parsed.fixableCount,
    ]

    if !parsed.fileErrors.isEmpty {
      response["fileErrors"] = parsed.fileErrors
    }

    response["detected"] = configSummary(config)

    return (200, makeResult(id: id, result: response))
  }

  // MARK: - code.detect-lint-config

  /// Detect the lint configuration for a project
  private func handleDetectConfig(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let path) = requireString("path", from: arguments, id: id) else {
      return missingParamError(id: id, param: "path")
    }

    let config = await detectLintConfig(at: path)

    var result: [String: Any] = configSummary(config)
    result["lintCommand"] = config.lintCommand ?? "none"
    result["lintFixCommand"] = config.lintFixCommand ?? "none"

    return (200, makeResult(id: id, result: result))
  }

  // MARK: - Lint Config Detection

  /// Detect lint tools and configuration from the project directory
  private func detectLintConfig(at path: String) async -> LintConfig {
    let fm = FileManager.default

    // 1. Detect package manager
    let packageManager: LintConfig.PackageManager
    if fm.fileExists(atPath: "\(path)/pnpm-lock.yaml") || fm.fileExists(atPath: "\(path)/pnpm-workspace.yaml") {
      packageManager = .pnpm
    } else if fm.fileExists(atPath: "\(path)/yarn.lock") {
      packageManager = .yarn
    } else if fm.fileExists(atPath: "\(path)/bun.lockb") || fm.fileExists(atPath: "\(path)/bun.lock") {
      packageManager = .bun
    } else if fm.fileExists(atPath: "\(path)/package-lock.json") || fm.fileExists(atPath: "\(path)/package.json") {
      packageManager = .npm
    } else {
      packageManager = .none
    }

    // 2. Parse package.json scripts
    var hasLint = false
    var hasLintFix = false
    var scriptNames: [String] = []
    if let packageData = fm.contents(atPath: "\(path)/package.json"),
       let json = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
       let scripts = json["scripts"] as? [String: String] {
      scriptNames = Array(scripts.keys)
      hasLint = scripts["lint"] != nil
      hasLintFix = scripts["lint:fix"] != nil
    }

    // 3. Detect individual lint tools
    var tools: [LintConfig.LintTool] = []

    // ESLint
    let eslintConfigs = ["eslint.config.mjs", "eslint.config.js", "eslint.config.cjs", ".eslintrc.js", ".eslintrc.json", ".eslintrc.yml", ".eslintrc"]
    for configFile in eslintConfigs {
      if fm.fileExists(atPath: "\(path)/\(configFile)") {
        tools.append(LintConfig.LintTool(
          name: "eslint",
          configFile: configFile,
          fixCommand: scriptNames.contains("lint:js:fix") ? "\(packageManager.runPrefix) lint:js:fix" : "\(packageManager.execPrefix) eslint --fix .",
          checkCommand: scriptNames.contains("lint:js") ? "\(packageManager.runPrefix) lint:js" : "\(packageManager.execPrefix) eslint ."
        ))
        break
      }
    }

    // Prettier
    let prettierConfigs = [".prettierrc", ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.json", ".prettierrc.yml", "prettier.config.js", "prettier.config.cjs"]
    for configFile in prettierConfigs {
      if fm.fileExists(atPath: "\(path)/\(configFile)") {
        tools.append(LintConfig.LintTool(
          name: "prettier",
          configFile: configFile,
          fixCommand: scriptNames.contains("lint:prettier:fix") ? "\(packageManager.runPrefix) lint:prettier:fix" : "\(packageManager.execPrefix) prettier --write .",
          checkCommand: scriptNames.contains("lint:prettier") ? "\(packageManager.runPrefix) lint:prettier" : "\(packageManager.execPrefix) prettier --check ."
        ))
        break
      }
    }

    // ember-template-lint
    let templateLintConfigs = [".template-lintrc.js", ".template-lintrc.cjs"]
    for configFile in templateLintConfigs {
      if fm.fileExists(atPath: "\(path)/\(configFile)") {
        tools.append(LintConfig.LintTool(
          name: "ember-template-lint",
          configFile: configFile,
          fixCommand: scriptNames.contains("lint:hbs:fix") ? "\(packageManager.runPrefix) lint:hbs:fix" : nil,
          checkCommand: scriptNames.contains("lint:hbs") ? "\(packageManager.runPrefix) lint:hbs" : nil
        ))
        break
      }
    }

    // TypeScript
    if fm.fileExists(atPath: "\(path)/tsconfig.json") {
      tools.append(LintConfig.LintTool(
        name: "typescript",
        configFile: "tsconfig.json",
        fixCommand: nil,
        checkCommand: scriptNames.contains("lint:types") ? "\(packageManager.runPrefix) lint:types" : "\(packageManager.execPrefix) tsc --noEmit"
      ))
    }

    // Swift (SwiftLint)
    let swiftLintConfigs = [".swiftlint.yml", ".swiftlint.yaml"]
    for configFile in swiftLintConfigs {
      if fm.fileExists(atPath: "\(path)/\(configFile)") {
        tools.append(LintConfig.LintTool(
          name: "swiftlint",
          configFile: configFile,
          fixCommand: "swiftlint lint --fix",
          checkCommand: "swiftlint lint"
        ))
        break
      }
    }

    // Rust (clippy)
    if fm.fileExists(atPath: "\(path)/Cargo.toml") {
      tools.append(LintConfig.LintTool(
        name: "clippy",
        configFile: "Cargo.toml",
        fixCommand: "cargo clippy --fix --allow-staged",
        checkCommand: "cargo clippy"
      ))
    }

    // Python (ruff, flake8, black)
    let pythonLintConfigs = ["ruff.toml", ".ruff.toml", "pyproject.toml"]
    for configFile in pythonLintConfigs {
      if fm.fileExists(atPath: "\(path)/\(configFile)") {
        tools.append(LintConfig.LintTool(
          name: "ruff",
          configFile: configFile,
          fixCommand: "ruff check --fix . && ruff format .",
          checkCommand: "ruff check . && ruff format --check ."
        ))
        break
      }
    }

    return LintConfig(
      packageManager: packageManager,
      hasLintFix: hasLintFix,
      hasLint: hasLint,
      tools: tools,
      rootPath: path
    )
  }

  // MARK: - Lint Output Parsing

  struct LintParseResult {
    let errorCount: Int
    let warningCount: Int
    let fixableCount: Int
    let fileErrors: [[String: Any]]
  }

  /// Parse lint output to extract structured error counts
  private func parseLintOutput(_ output: String, exitCode: Int) -> LintParseResult {
    var errorCount = 0
    var warningCount = 0
    var fixableCount = 0
    var fileErrors: [[String: Any]] = []

    let lines = output.components(separatedBy: .newlines)

    for line in lines {
      let lowered = line.lowercased()

      // ESLint summary pattern: "X problems (Y errors, Z warnings)"
      if lowered.contains("problem") && (lowered.contains("error") || lowered.contains("warning")) {
        if let match = line.range(of: #"(\d+)\s+error"#, options: .regularExpression) {
          let numStr = line[match].components(separatedBy: .whitespaces).first ?? ""
          errorCount = max(errorCount, Int(numStr) ?? 0)
        }
        if let match = line.range(of: #"(\d+)\s+warning"#, options: .regularExpression) {
          let numStr = line[match].components(separatedBy: .whitespaces).first ?? ""
          warningCount = max(warningCount, Int(numStr) ?? 0)
        }
        if let match = line.range(of: #"(\d+)\s+fixable"#, options: .regularExpression) {
          let numStr = line[match].components(separatedBy: .whitespaces).first ?? ""
          fixableCount = max(fixableCount, Int(numStr) ?? 0)
        }
        continue
      }

      // ESLint/Prettier file error patterns: "/path/to/file.ts"
      //   Line:Col  error  message  rule-name
      if line.contains("error") || line.contains("warning") {
        // Capture "filepath:line:col: error" patterns
        if let match = line.range(of: #"^(.+?):(\d+):(\d+):\s+(error|warning)"#, options: .regularExpression) {
          let matchStr = String(line[match])
          let parts = matchStr.components(separatedBy: ":")
          if parts.count >= 4 {
            fileErrors.append([
              "file": parts[0],
              "line": Int(parts[1]) ?? 0,
              "column": Int(parts[2]) ?? 0,
              "severity": parts[3].trimmingCharacters(in: .whitespaces),
              "message": String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            ])
          }
        }
      }
    }

    // Fallback: if no counts parsed but exit code non-zero, at least mark 1 error
    if exitCode != 0 && errorCount == 0 {
      errorCount = 1
    }

    // Cap fileErrors to avoid huge payloads
    let cappedErrors = Array(fileErrors.prefix(50))

    return LintParseResult(
      errorCount: errorCount,
      warningCount: warningCount,
      fixableCount: fixableCount,
      fileErrors: cappedErrors
    )
  }

  // MARK: - Shell Execution

  private struct ShellResult: Sendable {
    let output: String
    let exitCode: Int
  }

  /// Run a shell command and capture output
  private func runShellCommand(_ command: String, timeout: Int) async -> ShellResult {
    await withCheckedContinuation { continuation in
      let process = Process()
      let pipe = Pipe()

      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-l", "-c", command]
      process.standardOutput = pipe
      process.standardError = pipe

      // Inherit PATH from shell
      var env = ProcessInfo.processInfo.environment
      if let path = env["PATH"] {
        // Ensure common tool paths are included
        let additionalPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let existingPaths = Set(path.components(separatedBy: ":"))
        let newPaths = additionalPaths.filter { !existingPaths.contains($0) }
        if !newPaths.isEmpty {
          env["PATH"] = (newPaths + [path]).joined(separator: ":")
        }
      }
      process.environment = env

      do {
        try process.run()
      } catch {
        continuation.resume(returning: ShellResult(
          output: "Failed to launch process: \(error.localizedDescription)",
          exitCode: -1
        ))
        return
      }

      // Timeout handling
      let timeoutItem = DispatchWorkItem {
        if process.isRunning {
          process.terminate()
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutItem)

      process.waitUntilExit()
      timeoutItem.cancel()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""

      // Truncate very large output
      let maxLen = 50_000
      let truncatedOutput = output.count > maxLen
        ? String(output.prefix(maxLen)) + "\n... (truncated, \(output.count) chars total)"
        : output

      continuation.resume(returning: ShellResult(
        output: truncatedOutput,
        exitCode: Int(process.terminationStatus)
      ))
    }
  }

  // MARK: - Helpers

  private func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func configSummary(_ config: LintConfig) -> [String: Any] {
    var summary: [String: Any] = [
      "packageManager": config.packageManager.rawValue,
      "hasLintScript": config.hasLint,
      "hasLintFixScript": config.hasLintFix,
      "toolCount": config.tools.count,
    ]

    if !config.tools.isEmpty {
      summary["tools"] = config.tools.map { tool -> [String: Any] in
        var t: [String: Any] = ["name": tool.name]
        if let cf = tool.configFile { t["configFile"] = cf }
        if let fc = tool.fixCommand { t["fixCommand"] = fc }
        if let cc = tool.checkCommand { t["checkCommand"] = cc }
        return t
      }
    }

    return summary
  }
}

// MARK: - Tool Definitions

extension CodeQualityToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "code.lint",
        description: """
          Run lint checks or auto-fix on a project. Auto-detects the project's lint toolchain \
          (ESLint, Prettier, ember-template-lint, SwiftLint, Clippy, Ruff, etc.) and runs the \
          appropriate commands. Returns structured results with error/warning counts. \
          Use fix=true to auto-fix fixable issues.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the project root directory"],
            "fix": ["type": "boolean", "description": "Auto-fix fixable lint issues (default: false)"],
            "filter": ["type": "string", "description": "Package filter for monorepos (e.g., 'tio-employee' for pnpm --filter)"],
            "command": ["type": "string", "description": "Override: run this exact command instead of auto-detected lint"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "code.detect-lint-config",
        description: """
          Detect the lint configuration for a project without running anything. \
          Returns the package manager, available lint scripts, and detected lint tools \
          (ESLint, Prettier, TypeScript, SwiftLint, Clippy, Ruff, etc.).
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Absolute path to the project root directory"]
          ],
          "required": ["path"]
        ],
        category: .terminal,
        isMutating: false
      ),
    ]
  }
}
