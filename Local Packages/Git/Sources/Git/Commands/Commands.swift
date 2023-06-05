//
//  Commands.swift
//  
//
//  Created by Cory Loken on 5/14/21.
//

#if canImport(AppKit)
import TaskRunner
import Foundation

public struct Commands: TaskRunnerProtocol {
  private static let shared = Commands()

  static func launch(tool: URL, arguments: [String]) async throws -> TaskStatus {
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<TaskStatus, Error>) in
      DispatchQueue.main.async {
        Self.shared.launch(tool: tool, arguments: arguments) { result, arg in
          continuation.resume(returning: .complete(arg, [""]))
        }
      }
    }
  }
  
  /// Provides a single point for commands that just execture a command and return data
  static func simple(arguments: [String]) async throws -> [String] {
    let status = try? await Commands.launch(tool: URL(string: Executable.git.rawValue)!, arguments: arguments)
    switch status {
    case .complete(let data, _):
      return String(data: data, encoding: .utf8)!.split(separator: "\n").map { String($0) }
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
