//
//  Reset.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-reset

extension Commands {
  static func reset(path: String, on repository: Model.Repository) async throws -> [String] {
    try await Self.simple(arguments: ["reset", "HEAD", path], in: repository)
  }
}
