//
//  Restore.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-restore

extension Commands {
  static func restore(path: String, on repository: Model.Repository) async throws -> [String] {
    try await Self.simple(arguments: ["-C", repository.path, "restore", path])
  }
}
