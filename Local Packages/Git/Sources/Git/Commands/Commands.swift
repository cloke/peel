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
}
#endif
