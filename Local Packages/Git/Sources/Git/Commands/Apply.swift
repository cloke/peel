//
//  Apply.swift
//  Git
//
//  Applies patches to working tree or index.
//  Issue #112: Stage/revert hunk actions
//

import Foundation

extension Commands {
  
  /// Apply a patch to the index (stage changes)
  /// Equivalent to: echo "$patch" | git apply --cached
  public static func applyToIndex(patch: String, in repository: Model.Repository) async throws {
    try await applyPatch(patch: patch, arguments: ["apply", "--cached"], in: repository)
  }
  
  /// Apply a reverse patch to the working tree (revert changes)
  /// Equivalent to: echo "$patch" | git apply -R
  public static func revertPatch(patch: String, in repository: Model.Repository) async throws {
    try await applyPatch(patch: patch, arguments: ["apply", "-R"], in: repository)
  }
  
  /// Apply a patch with custom arguments
  private static func applyPatch(patch: String, arguments: [String], in repository: Model.Repository) async throws {
    guard let patchData = patch.data(using: .utf8) else {
      throw GitApplyError.patchFailed("Could not encode patch as UTF-8")
    }
    
    // Use the standard git executor with stdin piped
    let result = try await executeWithStdin(
      arguments: arguments,
      stdin: patchData,
      in: repository
    )
    
    if result.exitCode != 0 {
      throw GitApplyError.patchFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
  
  /// Execute a git command with stdin data
  private static func executeWithStdin(
    arguments: [String],
    stdin: Data,
    in repository: Model.Repository
  ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
    let gitExecutable = resolveGitExecutable()
    guard let gitPath = gitExecutable else {
      throw GitError.gitNotInstalled
    }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gitPath)
    process.arguments = ["-C", repository.path] + arguments
    
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    
    try process.run()
    
    // Write stdin and close
    inputPipe.fileHandleForWriting.write(stdin)
    inputPipe.fileHandleForWriting.closeFile()
    
    process.waitUntilExit()
    
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    
    return (
      exitCode: process.terminationStatus,
      stdout: String(data: outputData, encoding: .utf8) ?? "",
      stderr: String(data: errorData, encoding: .utf8) ?? ""
    )
  }
  
  /// Resolve git executable path (shared helper)
  private static func resolveGitExecutable() -> String? {
    let candidates = [
      "/Library/Developer/CommandLineTools/usr/bin/git",
      "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
      "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/git",
      "/opt/homebrew/bin/git",
      "/usr/local/bin/git"
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
      return path
    }
    return nil
  }
}

enum GitApplyError: LocalizedError {
  case patchFailed(String)
  
  var errorDescription: String? {
    switch self {
    case .patchFailed(let message):
      return "Failed to apply patch: \(message)"
    }
  }
}
