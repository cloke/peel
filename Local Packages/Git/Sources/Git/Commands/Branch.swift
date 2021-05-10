//
//  Clone.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-branch

extension ViewModel {
  func branch(name: String, callback: (([String]) -> ())? = nil) {
    simpleCommand(command: ["-C", Self.shared.selectedRepository.path, "checkout", "-b", name], callback: callback)
  }
  
  // git log --pretty=short
  // git shortlog
  // git shortlog -scen
  func showBranches(from location: String = "-r", callback: (([Branch]) -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "branch", location]) {
      switch $0 {
      case .complete(_, let array):
        callback?(array.map {
          return Branch(
            name: $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
            isActive: $0.starts(with: "*")
          )
        })
      default: ()
      }
    }
  }
}
