//
//  Repository.swift
//  Repository
//
//  Created by Cory Loken on 7/15/21.
//

import Foundation

extension Github {
  public struct Permissions: Codable {
    var admin: Bool
    var push: Bool
    var pull: Bool
  }
  
  public struct Repository: Codable, Identifiable {
    public var id: Int
    public var node_id: String
    public var name: String
    public var full_name: String
    //    private: Boolean
    public var owner: User
    public var html_url: String
    public var description: String?
    public var fork: Bool
    public var url: String
    public var forks_url: String
    public var keys_url: String
    public var collaborators_url: String
    public var teams_url: String
    public var hooks_url: String
    public var issue_events_url: String
    public var events_url: String
    public var assignees_url: String
    public var branches_url: String
    public var tags_url: String
    public var blobs_url: String
    public var git_tags_url: String
    public var git_refs_url: String
    public var trees_url: String
    public var statuses_url: String
    public var languages_url: String
    public var stargazers_url: String
    public var contributors_url: String
    public var subscribers_url: String
    public var subscription_url: String
    public var commits_url: String
    public var git_commits_url: String
    public var comments_url: String
    public var issue_comment_url: String
    public var contents_url: String
    public var compare_url: String
    public var merges_url: String
    public var archive_url: String
    public var downloads_url: String
    public var issues_url: String
    public var pulls_url: String
    public var milestones_url: String
    public var notifications_url: String
    public var labels_url: String
    public var releases_url: String
    public var deployments_url: String
    public var created_at: String?
    public var updated_at: String?
    public var pushed_at: String?
    public var git_url: String?
    public var ssh_url: String?
    public var clone_url: String?
    public var svn_url: String?
    public var homepage: String?
    public var size: Int?
    public var stargazers_count: Int?
    public var watchers_count: Int?
    public var language: String?
    public var has_issues: Bool?
    public var has_projects: Bool?
    public var has_downloads: Bool?
    public var has_wiki: Bool?
    public var has_pages: Bool?
    public var forks_count: Int?
    public var mirror_url: String?
    public var archived: Bool?
    public var disabled: Bool?
    public var open_issues_count: Int?
    public var license: License?
    public var forks: Int?
    public var open_issues: Int?
    public var watchers: Int?
    public var default_branch: String?
    public var permissions: Permissions?
  }
}
