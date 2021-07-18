//
//  PullRequest.swift
//  PullRequest
//
//  Created by Cory Loken on 7/14/21.
//

extension Github {
  /// WTF is this data type? PullSnapshot is a placeholder until I can research more
  public struct PullSnapshot: Codable {
    public var label: String
    public var ref: String
    public var sha: String
    public var user: User
    public var repo: Repository
  }
  
  public struct PullRequest: Codable, Identifiable {
    public var url: String
    public var id: Int
    public var node_id: String
    public var html_url: String
    public var diff_url: String
    public var patch_url: String
    public var issue_url: String
    public var number: Int
    public var state: String
    public var locked: Bool
    public var title: String
    public var user: User
    public var body: String
    public var created_at: String
    public var updated_at: String
    public var closed_at: String?
    public var merged_at: String?
    public var merge_commit_sha: String?
    public var assignee: User?
    public var assignees: [User]
    public var requested_reviewers: [User]
    //      "requested_teams": [],
    public var labels: [Label]
    //      "milestone": null,
    public var draft: Bool
    public var commits_url: String
    public var review_comments_url: String
    public var review_comment_url: String
    public var comments_url: String
    public var statuses_url: String
    public var head: PullSnapshot
    public var base: PullSnapshot
    public var author_association: String
    public var auto_merge: String?
    public var active_lock_reason: String?
  }
}
