//
//  Add.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-add

#if os(macOS)
extension Commands {
  static func add(to repository: Model.Repository, path: String, callback: (([String]) -> ())? = nil) {
    Self.simple(command:  ["-C", repository.path, "add", path], callback: callback)
  }
}
#endif
