//
//  Push.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-push

extension ViewModel {
  func push(branch: String, callback: (([String]) -> ())? = nil) {
    simpleCommand(command: ["-C", ViewModel.shared.selectedRepository.path, "push", "origin", branch], callback: callback)
  }
}

