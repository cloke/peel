//
//  Clone.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-branch

import SwiftUI

extension Commands {
  struct Branch {
    // TODO: This should allow the root branch to be specified.
    static func create(name: String, on repository: Model.Repository, callback: (([String]) -> ())? = nil) {
      Commands.simple(command: ["-C", repository.path, "checkout", "-b", name], callback: callback)
    }
    
    static func delete(name: String, on repository: Model.Repository, callback: (([String]) -> ())? = nil) {
      Commands.simple(command: ["-C", repository.path, "branch", "-d", name], callback: callback)
    }
    
    // git log --pretty=short
    // git shortlog
    // git shortlog -scen
    static func list(from location: Model.BranchType = .remote, on repository: Model.Repository, callback: (([Model.Branch]) -> ())? = nil) {
      try? Commands.run(.git, command: ["-C", repository.path, "branch", location.rawValue]) {
        switch $0 {
        case .complete(_, let array):
          callback?(array.map {
            return Model.Branch(
              name: $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
              isActive: $0.starts(with: "*"),
              type: location
            )
          })
        default: ()
        }
      }
    }
  }
}
