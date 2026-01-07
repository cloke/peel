//
//  Commit.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-commit

#if os(macOS)
extension Commands {
  static func commit(repository: Model.Repository, message: String) async throws -> [String] {
    try await Self.simple(arguments: ["commit", "-m", message], in: repository)
  }
}
#endif
