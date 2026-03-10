//
//  MCPServerService+GitHubToolsDelegate.swift
//  KitchenSync
//
//  Extracted from MCPServerService.swift for maintainability.
//

import Foundation
import Github

// MARK: - GitHub Tools Handler Delegate

extension MCPServerService: GitHubToolsHandlerDelegate {
  func fetchGitHubIssue(owner: String, repo: String, number: Int) async throws -> Github.Issue {
    try await Github.issue(owner: owner, repository: repo, number: number)
  }
  
  func listGitHubIssues(owner: String, repo: String, state: String) async throws -> [Github.Issue] {
    // Create a minimal repository JSON and decode it to get a proper Repository object
    let issuesUrl = "https://api.github.com/repos/\(owner)/\(repo)/issues{/number}"
    let repoJson: [String: Any] = [
      "id": 0,
      "name": repo,
      "full_name": "\(owner)/\(repo)",
      "url": "https://api.github.com/repos/\(owner)/\(repo)",
      "issues_url": issuesUrl
    ]
    
    let jsonData = try JSONSerialization.data(withJSONObject: repoJson)
    let repository = try JSONDecoder().decode(Github.Repository.self, from: jsonData)
    return try await Github.issues(from: repository, state: state)
  }

  // MARK: - PR Read Delegates

  func fetchPullRequest(owner: String, repo: String, number: Int) async throws -> Github.PullRequest {
    try await Github.pullRequest(owner: owner, repository: repo, number: number)
  }

  func fetchPullRequestFiles(owner: String, repo: String, number: Int) async throws -> [Github.PRFile] {
    try await Github.pullRequestFiles(owner: owner, repository: repo, number: number)
  }

  func fetchPullRequestDiff(owner: String, repo: String, number: Int) async throws -> String {
    try await Github.pullRequestDiff(owner: owner, repository: repo, number: number)
  }

  func fetchPullRequestReviews(owner: String, repo: String, number: Int) async throws -> [Github.Review] {
    try await Github.loadReviews(organization: owner, repository: repo, pullNumber: number)
  }

  func fetchPullRequestComments(
    owner: String, repo: String, number: Int
  ) async throws -> (issueComments: [Github.IssueComment], reviewComments: [Github.ReviewComment]) {
    async let issue = Github.issueComments(owner: owner, repository: repo, number: number)
    async let review = Github.reviewComments(owner: owner, repository: repo, number: number)
    return try await (issueComments: issue, reviewComments: review)
  }

  func fetchCheckStatus(
    owner: String, repo: String, ref: String
  ) async throws -> Github.AggregatedCheckStatus {
    try await Github.aggregatedCheckStatus(owner: owner, repo: repo, ref: ref)
  }

  // MARK: - PR Write Delegates

  func createPullRequestReview(
    owner: String, repo: String, number: Int,
    event: String, body: String, commentsJSON: Data?
  ) async throws -> Github.Review {
    try await Github.createPullRequestReview(
      owner: owner, repository: repo, number: number,
      event: event, body: body, commentsJSON: commentsJSON
    )
  }

  func createPRComment(
    owner: String, repo: String, number: Int, body: String
  ) async throws -> Github.IssueComment {
    try await Github.createPRComment(
      owner: owner, repository: repo, number: number, body: body
    )
  }

  func addLabels(
    owner: String, repo: String, number: Int, labels: [String]
  ) async throws -> [Github.Label] {
    try await Github.addLabels(
      owner: owner, repository: repo, number: number, labels: labels
    )
  }

  // MARK: - Issue Write Delegates

  func createGitHubIssue(
    owner: String, repo: String, title: String, body: String, labels: [String]
  ) async throws -> Github.Issue {
    try await Github.createIssue(
      owner: owner, repository: repo, title: title, body: body, labels: labels
    )
  }
}
