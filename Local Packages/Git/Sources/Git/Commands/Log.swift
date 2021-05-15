//
//  Log.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

import Foundation

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-log

extension Commands {
  static func log(branch: String, on repository: Model.Repository, callback: (([Model.LogEntry]) -> ())? = nil) {
    // loot at --graph without parent
    var logs = [Model.LogEntry]()
    try? Commands.run(.git, command: ["-C", repository.path, "--no-pager", "log", "--pretty=tformat:%ad<•>%h<•>%an<•>%d<•>%s", "--date=iso-strict", "--first-parent", branch.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)]) {
      switch $0 {
      case .complete(_, let array):
        let dateFormatter = ISO8601DateFormatter()
        array.forEach {
          let components = $0.components(separatedBy: "<•>")
          logs.append(
            // This feels like a crash waiting to happen. Probably need to create a safe index extension.
            Model.LogEntry(
              commit: components[1],
              date: dateFormatter.date(from: components[0]) ?? Date(),
              author: components[2],
              message: components[4]
            )
          )
        }
        callback?(logs)
        default: ()
      }
    }
  }
}
