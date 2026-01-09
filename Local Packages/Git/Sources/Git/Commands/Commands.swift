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
  public static func simple(
    arguments: [String],
    in repository: Model.Repository? = nil
  ) async throws -> [String] {
    let result = try await execute(arguments: arguments, in: repository)
    return result.lines
  }
}
