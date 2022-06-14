//
//  RevList.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-log

@available(macOS 12, *)
extension Commands {
  static func revList(repository: Model.Repository, branchA: String, branchB: String) async throws -> (Int, Int) {
    let status = try await Commands.run(.git, command: ["-C", repository.path, "rev-list", "--left-right", "--count", "\(branchA)...\(branchB)"])
      
    switch status {
    case .complete(_, let lines):
      /// tab separated to left and right value
      guard let t = lines.first?.split(separator: "\t"), let l = Int(t.first ?? "0"), let r = Int(t.last ?? "0") else {
        throw GitError.Unknown
      }
      return (l, r)

    default: throw GitError.Unknown
    }
  }
}
