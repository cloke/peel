//
//  Push.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-push

extension Commands {
  static func push(branch: Model.Branch, to repository: Model.Repository) async throws -> [String] {
    try await Self.simple(arguments: ["push", "origin", branch.name], in: repository)
  }
}

