//
//  Clone.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-branch

import SwiftUI
import OSLog

private let branchLogger = Logger(subsystem: "Peel", category: "Git.Branch")

#if os(macOS)
extension Commands {
  struct Branch {
    // TODO: This should allow the root branch to be specified.
    static func create(name: String, on repository: Model.Repository) async throws -> [String] {
      try await Commands.simple(arguments: ["checkout", "-b", name], in: repository)
    }
    
    static func delete(name: String, on repository: Model.Repository) async throws -> [String] {
      try await Commands.simple(arguments: ["branch", "-d", name], in: repository)
    }
    
    static func list(from branchType: Model.BranchType, on repository: Model.Repository) async throws -> [Model.Branch] {
      let startTime = Date()
      let array = branchType == .remote ?
        try await Commands.simple(arguments: ["for-each-ref", "--format=%(refname:short)", "refs/remotes"], in: repository) :
        try await Commands.simple(arguments: ["branch", "-l"], in: repository)

      let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
      return array.compactMap {
        if branchType == .remote {
          let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !name.isEmpty, !name.contains("->") else { return nil }
          return Model.Branch(name: name, isActive: false)
        }
        _ = durationMs
        return Model.Branch(
          name: $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
          isActive: false
        )
      }
    }
  }
}
#endif
