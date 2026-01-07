//
//  Commands.swift
//  
//
//  Created by Cory Loken on 5/14/21.
//

import Foundation
import TaskRunner

/// Git command executor using modern ProcessExecutor actor.
/// All git commands are executed through this interface.
public struct Commands {
  private static let executor = ProcessExecutor()
  private static let gitExecutable = "git"
  
  /// Execute a git command and return the result.
  /// - Parameters:
  ///   - arguments: Git command arguments
  ///   - repository: Optional repository to run command in (uses -C flag)
  ///   - throwOnError: Whether to throw on non-zero exit code (default: true)
  /// - Returns: ProcessExecutor result with stdout, stderr, and exit code
  static func execute(
    arguments: [String],
    in repository: Model.Repository? = nil,
    throwOnError: Bool = true
  ) async throws -> ProcessExecutor.Result {
    var args = arguments
    
    // Prepend repository path if provided
    if let repository {
      args = ["-C", repository.path] + args
    }
    
    return try await executor.execute(
      gitExecutable,
      arguments: args,
      throwOnNonZeroExit: throwOnError
    )
  }
  
  /// Execute a git command and return output as lines of text.
  /// This is the most common pattern for git commands.
  /// - Parameters:
  ///   - arguments: Git command arguments  
  ///   - repository: Optional repository to run command in
  /// - Returns: Array of non-empty output lines
  static func simple(
    arguments: [String],
    in repository: Model.Repository? = nil
  ) async throws -> [String] {
    let result = try await execute(arguments: arguments, in: repository)
    return result.lines
  }
  
  // MARK: - Public API for external packages
  
  /// Execute a git command and return output as lines of text (public API).
  /// - Parameters:
  ///   - arguments: Git command arguments
  ///   - repository: Repository to run command in
  /// - Returns: Array of non-empty output lines
  public static func run(
    _ arguments: [String],
    in repository: Model.Repository
  ) async throws -> [String] {
    try await simple(arguments: arguments, in: repository)
  }
  
  /// Fetch from a remote.
  /// - Parameters:
  ///   - remote: Remote name (default: "origin")
  ///   - refspec: Optional refspec to fetch
  ///   - repository: Repository to run command in
  public static func fetch(
    remote: String = "origin",
    refspec: String? = nil,
    on repository: Model.Repository
  ) async throws {
    var args = ["fetch", remote]
    if let refspec {
      args.append(refspec)
    }
    _ = try await simple(arguments: args, in: repository)
  }
  
  /// Get the URL of a remote.
  /// - Parameters:
  ///   - remote: Remote name (default: "origin")
  ///   - repository: Repository to run command in
  /// - Returns: The remote URL, or nil if not found
  public static func getRemoteURL(
    remote: String = "origin",
    on repository: Model.Repository
  ) async -> String? {
    do {
      let lines = try await simple(arguments: ["remote", "get-url", remote], in: repository)
      return lines.first
    } catch {
      return nil
    }
  }
}
