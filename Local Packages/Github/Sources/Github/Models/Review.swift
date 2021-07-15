//
//  Review.swift
//  Review
//
//  Created by Cory Loken on 7/15/21.
//

extension Github {
  public struct Review: Codable, Identifiable {
    public var id: Int
    public var node_id: String
    public var user: User
    public var body: String
    public var state: String
    public var html_url: String
    public var pull_request_url: String
    public var author_association: String
    public var submitted_at: String
    public var commit_id: String
  }
}
