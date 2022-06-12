//
//  Clone.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

import Foundation

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-clone
#if os(macOS)
extension Commands {
  static func clone(with url: String, to destination: URL) async throws -> Model.Repository {
    // TODO: Refactor most of these to use a state on the callback
    guard let url = URL(string: url) else { throw GitError.Unknown }
    // TODO: Add https support
    if (url.scheme == "https") { throw GitError.Unknown }
    
    guard let repositoryName = url.path.components(separatedBy: "/").last?.dropLast(4).description else { throw GitError.Unknown }
    
    _ = try await Commands.simple(command: ["clone", url.description, [destination.path, repositoryName].joined(separator: "/")])
    return Model.Repository(name: repositoryName, path: destination.path)
  }
}
#endif
