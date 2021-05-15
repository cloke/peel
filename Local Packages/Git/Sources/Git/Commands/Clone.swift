//
//  Clone.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

import Foundation

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-clone

extension Commands {
  static func clone(with url: String, to destination: URL, callback: (() -> ())? = nil) {
    // TODO: Refactor most of these to use a state on the callback
    guard let url = URL(string: url) else { return }
    // TODO: Add https support
    if (url.scheme == "https") { return }
    
    guard let repositoryName = url.path.components(separatedBy: "/").last?.dropLast(4).description else { return }
    
    Commands.simple(command: ["clone", url.description, [destination.path, repositoryName].joined(separator: "/")]) { _ in
      let repository = Model.Repository(name: repositoryName, path: destination.path)
      ViewModel.shared.repositories.append(repository)
      ViewModel.shared.selectedRepository = repository
    }    
  }
}
