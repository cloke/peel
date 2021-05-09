//
//  Add.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-add

extension ViewModel {
  func add(path: String, callack: (([String]) -> ())? = nil) {
    simpleCommand(command:  ["-C", Self.shared.selectedRepository.path, "add", path], callback: callack)
  }
}
