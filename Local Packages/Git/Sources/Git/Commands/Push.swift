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
  static func push(branch: Model.Branch, to repository: Model.Repository, callback: (([String]) -> ())? = nil) {
    Commands.simple(command: ["-C", repository.path, "push", "origin", branch.name], callback: callback)
  }
}
#endif

