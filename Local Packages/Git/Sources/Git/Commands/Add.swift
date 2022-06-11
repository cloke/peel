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
    guard let array = try? await Self.simple(command:  ["-C", repository.path, "add", path]) else {
      throw GitError.Unknown
    }
    return array
  }
}
#endif
