//
//  Restore.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-restore

extension ViewModel {
  func restore(path: String, callback: (([String]) -> ())? = nil) {
    simpleCommand(command: ["-C", Self.shared.selectedRepository.path, "restore", path], callback: callback)
  }
}
