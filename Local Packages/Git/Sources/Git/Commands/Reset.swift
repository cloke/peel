//
//  Reset.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-reset

extension ViewModel {
  func reset(path: String, callback: (([String]) -> ())? = nil) {
    simpleCommand(command: ["-C", Self.shared.selectedRepository.path, "reset", "HEAD", path], callback: callback)
  }
}
