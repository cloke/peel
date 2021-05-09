//
//  Commit.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-commit

extension ViewModel {
  func commit(message: String, callback: (([String]) -> ())? = nil) {
    simpleCommand(command: ["-C", Self.shared.selectedRepository.path, "commit", "-m", message], callback: callback)
  }
}
