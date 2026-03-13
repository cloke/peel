//
//  Fetch.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

/// Functions that are defined in the git reference
/// https://git-scm.com/docs/git-fetch

extension Commands {
  /// Fetch from a remote
  /// - Parameters:
  ///   - remote: The remote to fetch from (default: "origin")
  ///   - refspec: Optional refspec to fetch
  ///   - repository: The repository to fetch in
  public static func fetch(
    remote: String = "origin",
    refspec: String? = nil,
    on repository: Model.Repository
  ) async throws {
    var args = ["fetch", remote]
    if let refspec {
      args.append(refspec)
    }
    _ = try await simple(arguments: args, in: repository)
  }
  
  /// Get the remote URL for a repository
  /// - Parameters:
  ///   - remote: The remote name (default: "origin")
  ///   - repository: The repository to check
  /// - Returns: The remote URL or nil if not found
  public static func getRemoteURL(
    remote: String = "origin",
    on repository: Model.Repository
  ) async -> String? {
    do {
      let lines = try await simple(
        arguments: ["remote", "get-url", remote],
        in: repository
      )
      return lines.first
    } catch {
      return nil
    }
  }
}

