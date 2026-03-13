//
//  Stash.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-stash

extension Commands {
  struct Stash {
    static func list(on repository: Model.Repository) async throws -> [String] {
      try await Commands.simple(arguments: ["stash", "list"], in: repository)
    }
    
    static func push(repository: Model.Repository, with message: String = "") async throws -> [String] {
      try await Commands.simple(arguments: ["stash", "push", "-m", message], in: repository)
    }
  }
}
