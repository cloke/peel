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
}
