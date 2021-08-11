//
//  Action.swift
//  File
//
//  Created by Cory Loken on 7/30/21.
//

import Foundation

extension Github {
  
  /// The github api returns queries for what workflows exist on an organization as a count and an array of workflows.
  /// This servers the only purpose to decode the workflows so that the array can be returned.
  struct WorkflowContainer: Codable {
    public var total_count: Int
    public var workflows: [Workflow]
  }
  
  struct Workflow: Codable, Identifiable {
    public var id: Int
    public var node_id: String
    public var name: String
    public var path: String
    public var state: String
    public var created_at: String
    public var updated_at: String
    public var url: String
    public var html_url: String
    public var badge_url: String
  }
  
  struct WorkflowRun: Codable {
    public var total_count: Int
    public var jobs: [WorkflowJob]
  }
  
  /// Workflow jobs appear to be the individual runs of an action.
  struct WorkflowJob: Codable, Identifiable {

    /// Steps are the individual tasks within the workflow.
    struct Steps: Codable {
      public var name: String
      public var status: String
      public var conclusion: String?
      public var number: Int
      public var started_at: String
      public var completed_at: String
    }
    
    public var id: Int
    public var run_id: Int
    public var run_url: String
    public var node_id: String
    public var head_sha: String
    public var url: String
    public var html_url: String
    public var status: String
    public var conclusion: String?
    public var started_at: String
    public var completed_at: String
    public var name: String
    public var steps: [Steps]
    public var check_run_url: String
  }
  
  struct Runs: Codable {
    public var total_count: Int
    public var workflow_runs: [Action]
  }
  
  public struct Action: Codable, Identifiable {
    public var id: Int
    public var name: String
    public var node_id: String
    public var head_branch: String
    public var head_sha: String
    public var run_number: Int
    public var event: String
    public var status: String
    public var conclusion: String?
    public var workflow_id: Int
    public var check_suite_id: Int
    public var check_suite_node_id: String
    public var url: String
    public var html_url: String
    public var pull_requests: [PullRequest]
    public var created_at: String
    public var updated_at: String
    public var jobs_url: String
    public var logs_url: String
    public var check_suite_url: String
    public var artifacts_url: String
    public var cancel_url: String
    public var rerun_url: String
    public var workflow_url: String
    public var head_commit: CommitSnapshot
//          "head_commit": {
//            "id": "0a14debd8ac45606defb14729d60161a8ea5f3b9",
//            "tree_id": "db09c94c353a61d9089d19e6cfd74afd6a1f24c9",
//            "message": "Bump aws-sdk-s3 from 1.96.1 to 1.96.2 (#200)\n\nBumps [aws-sdk-s3](https://github.com/aws/aws-sdk-ruby) from 1.96.1 to 1.96.2.\r\n- [Release notes](https://github.com/aws/aws-sdk-ruby/releases)\r\n- [Changelog](https://github.com/aws/aws-sdk-ruby/blob/version-3/gems/aws-sdk-s3/CHANGELOG.md)\r\n- [Commits](https://github.com/aws/aws-sdk-ruby/commits)\r\n\r\n---\r\nupdated-dependencies:\r\n- dependency-name: aws-sdk-s3\r\n  dependency-type: direct:production\r\n  update-type: version-update:semver-patch\r\n...\r\n\r\nSigned-off-by: dependabot[bot] <support@github.com>\r\n\r\nCo-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>",
//            "timestamp": "2021-07-22T13:04:13Z",
//            "author": {
//              "name": "dependabot[bot]",
//              "email": "49699333+dependabot[bot]@users.noreply.github.com"
//            },
//            "committer": {
//              "name": "GitHub",
//              "email": "noreply@github.com"
//            }
//          },
    public var repository: Repository
//    public var head_repository: Repository
  
    var updatedAtFormatted: String {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
      if let date = formatter.date(from: created_at) {
        formatter.doesRelativeDateFormatting = true
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
      }
      return ""
    }
  }
}
