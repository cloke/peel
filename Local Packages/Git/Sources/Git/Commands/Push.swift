//
//  Push.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-push

#if os(macOS)
extension Commands {
  static func push(branch: Model.Branch, to repository: Model.Repository) async throws -> [String] {
    try await Self.simple(arguments: ["-C", repository.path, "push", "origin", branch.name])
  }
}
#endif

