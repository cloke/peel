//
//  Add.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-add

#if os(macOS)
extension Commands {
  static func add(to repository: Model.Repository, path: String) async throws -> [String] {
    try await Self.simple(arguments: ["add", path], in: repository)
  }
}
#endif
