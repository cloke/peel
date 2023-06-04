//
//  Stash.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-stash

#if os(macOS)
extension Commands {
  struct Stash {
    static func list(on repository: Model.Repository) async throws -> [String] {
      try await Commands.simple(arguments: ["-C", repository.path, "stash", "list"])
    }
    
    static func push(repository: Model.Repository, with message: String = "") async throws -> [String] {
      try await Commands.simple(arguments: ["-C", repository.path, "stash", "push", "-m", message])
    }
  }
}
#endif
