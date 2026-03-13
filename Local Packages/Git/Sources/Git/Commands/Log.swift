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
  public static func log(branch: String, on repository: Model.Repository) async -> [Model.LogEntry] {
    // loot at --graph without parent
    var logs = [Model.LogEntry]()
    let cleanBranch = branch.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    let array = try? await Self.simple(
      arguments: [
        "--no-pager", "log",
        "--pretty=tformat:%ad<•>%h<•>%an<•>%d<•>%s",
        "--date=iso-strict",
        "--first-parent",
        cleanBranch
      ],
      in: repository
    )
    let dateFormatter = ISO8601DateFormatter()
    array?.forEach {
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

    return logs
  }
}
