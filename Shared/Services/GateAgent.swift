//
//  GateAgent.swift
//  Peel
//

import Foundation
import OSLog

// MARK: - Config

struct GateAgentConfig: Sendable {
  var maxRetries: Int = 2
  var autoCreatePR: Bool = true
  var buildCommand: String? = nil
  var lintCommand: String? = nil
}

// MARK: - Result

enum GateAgentResult: Sendable {
  case passed(summary: String)
  case fixable(feedback: String, retryCount: Int)
  case rejected(reason: String)
}

// MARK: - Errors

enum GateAgentError: LocalizedError {
  case worktreeCreationFailed(String)
  case prCreationFailed(String)

  var errorDescription: String? {
    switch self {
    case .worktreeCreationFailed(let msg): return "Worktree creation failed: \(msg)"
    case .prCreationFailed(let msg): return "PR creation failed: \(msg)"
    }
  }
}

// MARK: - Actor

actor GateAgent {
  private let logger = Logger(subsystem: "com.peel.gateagent", category: "GateAgent")
  let config: GateAgentConfig

  init(config: GateAgentConfig = GateAgentConfig()) {
    self.config = config
  }

  // MARK: - Validate

  /// Validates a branch by creating a temporary worktree, running build and lint checks,
  /// and collecting diff stats.
  func validate(
    branchName: String,
    baseBranch: String,
    projectPath: String,
    taskPrompt: String
  ) async -> GateAgentResult {
    let worktreeID = UUID().uuidString
    let agentWorkspacesURL = URL(fileURLWithPath: projectPath)
      .deletingLastPathComponent()
      .appendingPathComponent(".agent-workspaces")
    let worktreePath = agentWorkspacesURL.appendingPathComponent("gate-\(worktreeID)").path

    // Create worktree
    let (addOutput, addExit) = await runGit(
      ["worktree", "add", worktreePath, branchName],
      in: projectPath
    )
    guard addExit == 0 else {
      logger.error("Failed to create gate worktree: \(addOutput)")
      return .rejected(reason: "Worktree creation failed: \(addOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // Always remove worktree on exit
    defer {
      Task {
        let (removeOutput, removeExit) = await self.runGit(
          ["worktree", "remove", "--force", worktreePath],
          in: projectPath
        )
        if removeExit != 0 {
          self.logger.warning("Failed to remove gate worktree: \(removeOutput)")
        }
      }
    }

    // Diff stats
    let (diffOutput, _) = await runGit(
      ["diff", "--stat", "\(baseBranch)...\(branchName)"],
      in: worktreePath
    )

    // Build check
    let buildCmd = config.buildCommand ?? #"if [ -f Package.swift ]; then swift build 2>&1; elif ls *.xcodeproj 1>/dev/null 2>&1; then xcodebuild -quiet build 2>&1; elif [ -f Makefile ] || [ -f makefile ]; then make 2>&1; else echo 'SKIP: No build system detected'; exit 0; fi"#
    logger.info("Running build check on branch \(branchName)")
    let (buildOutput, buildExit) = await runShell(buildCmd, in: worktreePath)
    let buildTrimmed = buildOutput.trimmingCharacters(in: .whitespacesAndNewlines)

    // Lint check (non-fatal)
    var lintWarnings = ""
    let hasSwiftFiles = FileManager.default.enumerator(atPath: worktreePath)?
      .contains { ($0 as? String)?.hasSuffix(".swift") == true } ?? false
    if hasSwiftFiles {
      let lintCmd = config.lintCommand ?? "swiftlint lint --quiet 2>&1"
      logger.info("Running lint check on branch \(branchName)")
      let (lintOutput, lintExit) = await runShell(lintCmd, in: worktreePath)
      if lintExit != 0 {
        let lintTrimmed = lintOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lintTrimmed.isEmpty {
          lintWarnings = "\n\nLint warnings:\n\(String(lintTrimmed.prefix(2000)))"
        }
      }
    }

    // Evaluate results
    if buildExit == -1 {
      return .rejected(reason: "Build process failed to spawn (exit -1). Output: \(buildTrimmed)")
    }

    if buildExit == 0 {
      let diffSummary = diffOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      var summary = "Build passed."
      if !diffSummary.isEmpty {
        summary += "\n\nDiff stats:\n\(diffSummary)"
      }
      summary += lintWarnings
      logger.info("Gate validation PASSED for branch \(branchName)")
      return .passed(summary: summary)
    }

    // Build failed
    if buildTrimmed.isEmpty {
      return .rejected(reason: "Build failed with no output (exit code \(buildExit)). Branch may be fundamentally broken.")
    }

    logger.warning("Gate validation FIXABLE for branch \(branchName): \(String(buildTrimmed.prefix(500)))")
    var feedback = "Build failed with exit code \(buildExit).\n\nErrors:\n\(String(buildTrimmed.prefix(3000)))"
    feedback += lintWarnings
    return .fixable(feedback: feedback, retryCount: 0)
  }

  // MARK: - Create PR

  /// Creates a GitHub pull request using the `gh` CLI.
  func createPR(
    branchName: String,
    baseBranch: String,
    title: String,
    body: String,
    projectPath: String
  ) async throws {
    let (output, exitCode) = await runShell(
      "gh pr create --base \(baseBranch) --head \(branchName) --title \(title.shellQuoted) --body \(body.shellQuoted)",
      in: projectPath
    )
    guard exitCode == 0 else {
      throw GateAgentError.prCreationFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    logger.info("PR created for branch \(branchName): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
  }

  // MARK: - Private Helpers

  private func runGit(_ arguments: [String], in directoryPath: String) async -> (String, Int32) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: directoryPath)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
          try process.run()
          process.waitUntilExit()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          let output = String(data: data, encoding: .utf8) ?? ""
          continuation.resume(returning: (output, process.terminationStatus))
        } catch {
          continuation.resume(returning: (error.localizedDescription, -1))
        }
      }
    }
  }

  private func runShell(_ command: String, in directoryPath: String) async -> (String, Int32) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: directoryPath)
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
          try process.run()
          process.waitUntilExit()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          let output = String(data: data, encoding: .utf8) ?? ""
          continuation.resume(returning: (output, process.terminationStatus))
        } catch {
          continuation.resume(returning: (error.localizedDescription, -1))
        }
      }
    }
  }
}

// MARK: - String helpers

private extension String {
  /// Wraps a string in single quotes, escaping any single quotes within.
  var shellQuoted: String {
    "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}
