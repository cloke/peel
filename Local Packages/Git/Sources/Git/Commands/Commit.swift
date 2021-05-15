//
//  Commit.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-commit

extension Commands {
  static func commit(message: String, callback: (([String]) -> ())? = nil) {
    Self.simple(command: ["-C", ViewModel.shared.selectedRepository.path, "commit", "-m", message], callback: callback)
  }
}
