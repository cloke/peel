//
//  Checkout.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-checkout

#if os(macOS)
extension Commands {
  // Would have preferred to name method switch, but that is a reserved word
  static func checkout(branch: String, from repository: Model.Repository, callback: (([String]) -> ())? = nil) {
    Self.simple(command: ["-C", repository.path, "switch", branch], callback: callback)
  }
}
#endif
