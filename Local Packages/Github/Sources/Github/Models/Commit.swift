//
//  Commit.swift
//  Commit
//
//  Created by Cory Loken on 7/16/21.
//

import Foundation

extension Github {
  public struct CommitStats: Codable {
    public var total: Int
    public var additions: Int
    public var deletions: Int
  }
  
  public struct CommitFile: Codable, Identifiable {
    public var id: String { sha }
    public var sha: String
    public var filename: String
    public var status: String
    public var additions: Int
    public var deletions: Int
    public var changes: Int
    public var blob_url: String
    public var raw_url: String
    public var contents_url: String
    public var patch: String
  }
  
  public struct CommitParent: Codable {
    public var sha: String
    public var url: String
    public var html_url: String
  }
  
  public struct CommitDetail: Codable, Identifiable {
    public var id: String { sha }
    public var sha: String
    public var node_id: String
    public var commit: CommitSnapshot
    public var url: String
    public var html_url: String
    public var comments_url: String
    public var author: User
    public var committer: User
    public var parents: [CommitParent]
    public var stats: CommitStats
    public var files: [CommitFile]
  }
  
  public struct CommitUser: Codable, Equatable {
    var name: String
    var email: String
    var date: String?
    
    var dateFormatted: String {
      date?.dateFromGithubFormat?.relativeFormatted ?? ""
    }
    
    public static func == (lhs: Github.CommitUser, rhs: Github.CommitUser) -> Bool {
      return lhs.name == rhs.name &&
      lhs.email == rhs.email &&
      lhs.date == rhs.date
    }
  }
  
  public struct CommitVerification: Codable {
    public var verified: Bool?
    public var reason: String
    public var signature: String?
    public var payload: String?
  }
  
  public struct CommitTree: Codable {
    public var sha: String
    public var url: String
  }
  
  public struct CommitSnapshot: Codable {
    public var author: CommitUser
    public var committer: CommitUser
    public var message: String
    public var url: String?
    public var commentCount: Int?
    public var verification: CommitVerification?
  }

  public struct Commit: Codable {
    public var sha: String
    public var node_id: String
    public var commit: CommitSnapshot
    public var url: String
    public var html_url: String
    public var comments_url: String
    public var author: User?
    public var committer: User?
    public var parents: [CommitParent]
  }
}
