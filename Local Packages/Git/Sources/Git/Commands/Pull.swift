//
//  Pull.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-pull

#if os(macOS)
extension Commands {
  /// Pull from remote, optionally for a specific branch.
  /// - Parameters:
  ///   - remote: The remote to pull from (default: "origin")
  ///   - branch: Optional branch name to pull
  ///   - repository: The repository to pull in
  public static func pull(
    remote: String = "origin",
    branch: String? = nil,
    on repository: Model.Repository
  ) async throws {
    var args = ["pull", remote]
    if let branch {
      args.append(branch)
    }
    _ = try await simple(arguments: args, in: repository)
  }
}
#endif

