//
//  Commands.swift
//  
//
//  Created by Cory Loken on 5/14/21.
//

#if os(macOS)
import TaskRunner

public struct Commands: TaskRunnerProtocol {
  private static let shared = Commands()
  
  static func run(_ url: Executable, command: [String], callback: ((TaskStatus) -> ())? = nil) throws {
    try? Self.shared.run(url, command: command, callback: callback)
  }
  
  static func run(_ url: Executable, command: [String]) async throws -> TaskStatus {
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<TaskStatus, Error>) in
      try? Self.shared.run(url, command: command, callback: { status in
        continuation.resume(returning: status)
      })
    }
  }
  
  /// Provides a single point for commands that just execture a command and return data
  static func simple(command: [String], callback: (([String]) -> ())? = nil) {
    try? Commands.run(.git, command: command) {
      switch $0 {
      case .complete(_, let array):
        callback?(array)
      default: ()
      }
    }
  }
  
  static func simple(command: [String]) async throws -> [String] {
    let status = try? await Commands.run(.git, command: command)
    switch status {
    case .complete(_, let array):
      return array
    default:
      throw GitError.Unknown
    }
  }
}
#else
public struct Commands {
  private static let shared = Commands()
}
#endif
