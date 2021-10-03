//
//  Stash.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-stash

#if os(macOS)
extension Commands {
  struct Stash {
    static func list(on repository: Model.Repository, callback: (([String]) -> ())? = nil) {
      Commands.simple(command: ["-C", repository.path, "stash", "list"], callback: callback)
    }
    
    static func push(repository: Model.Repository, with message: String = "", callback: (([String]) -> ())? = nil) {
      Commands.simple(command: ["-C", repository.path, "stash", "push", "-m", message], callback: callback)
    }
  }
}
#endif
