//
//  Checkout.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-checkout

extension ViewModel {
  // Would have preferred to name method switch, but that is a reserved word
  func checkout(branch: String, callback: (([String]) -> ())? = nil) {
    simpleCommand(command: ["-C", Self.shared.selectedRepository.path, "switch", branch], callback: callback)
  }
}
