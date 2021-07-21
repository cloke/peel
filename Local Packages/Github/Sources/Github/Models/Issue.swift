//
//  Issue.swift
//  Issue
//
//  Created by Cory Loken on 7/18/21.
//

extension Github {
  // TODO: Should we combine with main model? It would require almost all props to be optional. Or do we even worry about a codable?
  public struct NewIssue: Codable {
    public var title: String
    public var body: String
    public var owner: String
  }
  
  public struct Issue: Codable, Identifiable {
    public var id: Int
    public var url: String
    public var repository_url: String
    public var labels_url: String
    public var comments_url: String
    public var events_url: String
    public var html_url: String
    public var node_id: String
    public var number: Int
    public var title: String
    public var user: User
    public var labels: [Label]
    public var state: String
    public var locked: Bool
    public var assignee: User?
    public var assignees: [User]
//    "milestone": null,
    public var comments: Int
    public var created_at: String
    public var updated_at: String
    public var closed_at: String?
    public var author_association: String
    public var active_lock_reason: String?
    public var body: String
    public var performed_via_github_app: String?
  }
}


