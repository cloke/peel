//
//  IssueComment.swift
//  Github
//

extension Github {
  public struct IssueComment: Codable, Identifiable {
    public var id: Int
    public var node_id: String?
    public var html_url: String?
    public var body: String
    public var user: User
    public var created_at: String?
    public var updated_at: String?
    public var author_association: String?
  }
}
