//
//  RevList.swift
//  
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-log

#if canImport(AppKit)
extension Commands {
  static func revList(repository: Model.Repository, branchA: String, branchB: String) async throws -> (Int, Int) {
    let lines = try await Self.simple(
      arguments: ["rev-list", "--left-right", "--count", "\(branchA)...\(branchB)"],
      in: repository
    )

    guard let t = lines.first?.split(separator: "\t"), let l = Int(t.first ?? "0"), let r = Int(t.last ?? "0") else {
      throw GitError.Unknown
    }
    return (l, r)
  }
}
#endif
