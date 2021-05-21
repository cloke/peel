//
//  RevList.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-log

extension Commands {
  static func revList(repository: Model.Repository, branchA: String, branchB: String, callback: ((Int, Int) -> ())? = nil) {
    try? Commands.run(.git, command: ["-C", repository.path, "rev-list", "--left-right", "--count", "\(branchA)...\(branchB)"]) {
      switch $0 {
      case .complete(_, let lines):
        /// tab separated to left and right value
        if let t = lines.first?.split(separator: "\t"), let l = Int(t.first ?? "0"), let r = Int(t.last ?? "0") {
          callback?(l, r)
        }
      default: ()
      }
    }
  }
}
