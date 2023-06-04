//
//  Clone.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-branch

import SwiftUI
import TaskRunner

#if os(macOS)
extension Commands {
  struct Branch {
    // TODO: This should allow the root branch to be specified.
    static func create(name: String, on repository: Model.Repository) async throws -> [String] {
      try await Commands.simple(arguments: ["-C", repository.path, "checkout", "-b", name])
    }
    
    static func delete(name: String, on repository: Model.Repository) async throws -> [String] {
      try await Commands.simple(arguments: ["-C", repository.path, "branch", "-d", name])
    }
    
    static func list(from branchType: Model.BranchType, on repository: Model.Repository) async throws -> [Model.Branch] {
      let array = branchType == .remote ?
      try await Commands.simple(arguments:  ["-C", repository.path, "ls-remote", "--heads", "origin"]) :
      try await Commands.simple(arguments:  ["-C", repository.path, "branch", "-l"])


      return array.map {
        return Model.Branch(
          name: branchType == .remote ?
            ($0.split(separator: "\t").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Who Knows") :
            $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
          isActive: false
        )
      }
    }
  }
}
#endif
