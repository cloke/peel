//
//  PRFile.swift
//  Github
//
//  Model for files changed in a pull request
//

import Foundation

extension Github {
  /// A file changed in a pull request.
  /// Similar to CommitFile but with optional patch (binary files have no patch).
  public struct PRFile: Codable, Identifiable {
    public var id: String { sha ?? filename }
    public var sha: String?
    public var filename: String
    public var status: String  // added, removed, modified, renamed, copied, changed, unchanged
    public var additions: Int
    public var deletions: Int
    public var changes: Int
    public var blob_url: String?
    public var raw_url: String?
    public var contents_url: String?
    public var patch: String?
    public var previous_filename: String?
  }
}
