//
//  Stash.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-stash

extension ViewModel {
  struct Stash {
    static func list(callback: (([String]) -> ())? = nil) {
      ViewModel.shared.simpleCommand(command: ["-C", ViewModel.shared.selectedRepository.path, "stash", "list"], callback: callback)
    }
    
    static func push(message: String = "", callback: (([String]) -> ())? = nil) {
      ViewModel.shared.simpleCommand(command: ["-C", ViewModel.shared.selectedRepository.path, "stash", "push", "-m", message], callback: callback)
    }
  }
}
