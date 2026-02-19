//
//  IssueComment.swift
//  Github
//
//  Model for PR/issue comments (general conversation) and review comments (inline code).
//

import Foundation

extension Github {
  /// A general comment on a PR or issue (from /issues/{number}/comments).
  public struct IssueComment: Codable, Identifiable {
    public var id: Int
    public var node_id: String
    public var user: User
    public var body: String
    public var created_at: String
    public var updated_at: String
    public var html_url: String
    public var author_association: String?
  }

  /// An inline review comment on a PR diff (from /pulls/{number}/comments).
  public struct ReviewComment: Codable, Identifiable {
    public var id: Int
    public var node_id: String
    public var user: User
    public var body: String
    public var created_at: String
    public var updated_at: String
    public var html_url: String
    public var path: String
    public var line: Int?
    public var original_line: Int?
    public var diff_hunk: String?
    public var pull_request_review_id: Int?
    public var author_association: String?
    public var in_reply_to_id: Int?
  }
}
