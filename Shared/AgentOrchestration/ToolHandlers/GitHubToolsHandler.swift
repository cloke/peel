//
//  GitHubToolsHandler.swift
//  Peel
//
//  Created on 1/31/26.
//

import Foundation
import MCPCore
import Github

// MARK: - GitHub Tools Handler Delegate Extension

/// Extended delegate protocol for GitHub-specific functionality
@MainActor
protocol GitHubToolsHandlerDelegate: MCPToolHandlerDelegate {
  /// Fetch a single issue by owner, repo, and number
  func fetchGitHubIssue(owner: String, repo: String, number: Int) async throws -> Github.Issue
  
  /// List issues for a repository
  func listGitHubIssues(owner: String, repo: String, state: String) async throws -> [Github.Issue]
}

// MARK: - GitHub Tools Handler

/// Handles GitHub API tools for issue analysis
@MainActor
final class GitHubToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?
  
  /// Typed delegate for GitHub-specific operations
  private var githubDelegate: GitHubToolsHandlerDelegate? {
    delegate as? GitHubToolsHandlerDelegate
  }
  
  let supportedTools: Set<String> = [
    "github.issue.get",
    "github.issues.list"
  ]
  
  init() {}
  
  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let githubDelegate else {
      return notConfiguredError(id: id)
    }
    
    switch name {
    case "github.issue.get":
      return await handleIssueGet(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.issues.list":
      return await handleIssuesList(id: id, arguments: arguments, delegate: githubDelegate)
    default:
      return makeError(id: id, code: -32601, message: "Method not found", data: ["method": name])
    }
  }
  
  // MARK: - Tool Handlers
  
  private func handleIssueGet(
    id: Any?,
    arguments: [String: Any],
    delegate: GitHubToolsHandlerDelegate
  ) async -> (Int, Data) {
    guard let owner = arguments["owner"] as? String,
          let repo = arguments["repo"] as? String,
          let number = arguments["number"] as? Int else {
      return makeError(
        id: id,
        code: -32602,
        message: "Invalid params",
        data: ["error": "Required: owner (string), repo (string), number (int)"]
      )
    }
    
    do {
      let issue = try await delegate.fetchGitHubIssue(owner: owner, repo: repo, number: number)
      
      let result: [String: Any] = [
        "number": issue.number,
        "title": issue.title,
        "state": issue.state,
        "body": issue.body ?? "",
        "labels": issue.labels.map { $0.name },
        "comments": issue.comments,
        "created_at": issue.created_at,
        "updated_at": issue.updated_at ?? "",
        "html_url": issue.html_url
      ]
      
      return makeResult(id: id, result: result)
    } catch {
      return makeError(
        id: id,
        code: -32000,
        message: "Failed to fetch issue",
        data: ["error": error.localizedDescription]
      )
    }
  }
  
  private func handleIssuesList(
    id: Any?,
    arguments: [String: Any],
    delegate: GitHubToolsHandlerDelegate
  ) async -> (Int, Data) {
    guard let owner = arguments["owner"] as? String,
          let repo = arguments["repo"] as? String else {
      return makeError(
        id: id,
        code: -32602,
        message: "Invalid params",
        data: ["error": "Required: owner (string), repo (string). Optional: state (string)"]
      )
    }
    
    let state = arguments["state"] as? String ?? "open"
    
    do {
      let issues = try await delegate.listGitHubIssues(owner: owner, repo: repo, state: state)
      
      let result = issues.map { issue -> [String: Any] in
        [
          "number": issue.number,
          "title": issue.title,
          "state": issue.state,
          "labels": issue.labels.map { $0.name },
          "comments": issue.comments,
          "created_at": issue.created_at,
          "updated_at": issue.updated_at ?? ""
        ]
      }
      
      return makeResult(id: id, result: result)
    } catch {
      return makeError(
        id: id,
        code: -32000,
        message: "Failed to list issues",
        data: ["error": error.localizedDescription]
      )
    }
  }
  
  // MARK: - Error Helpers
  
  private func notConfiguredError(id: Any?) -> (Int, Data) {
    makeError(
      id: id,
      code: -32603,
      message: "Internal error",
      data: ["error": "GitHub tools handler not configured"]
    )
  }
}
