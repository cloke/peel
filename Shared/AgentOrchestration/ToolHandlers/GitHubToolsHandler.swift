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
      return localNotConfiguredError(id: id)
    }
    
    switch name {
    case "github.issue.get":
      return await handleIssueGet(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.issues.list":
      return await handleIssuesList(id: id, arguments: arguments, delegate: githubDelegate)
    default:
      return (404, makeError(id: id, code: -32601, message: "Method not found", data: ["method": name]))
    }
  }
  
  // MARK: - Tool Handlers
  
  private func handleIssueGet(
    id: Any?,
    arguments: [String: Any],
    delegate: GitHubToolsHandlerDelegate
  ) async -> (Int, Data) {
    let schema: [ToolArgSchemaField] = [
      .required("owner", .string),
      .required("repo", .string),
      .required("number", .int)
    ]
    let parsedResult = parseArguments(arguments, schema: schema, id: id)
    guard case .success(let parsed) = parsedResult else {
      if case .failure(let error) = parsedResult {
        return error.response
      }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let number = parsed.int("number") else {
      return invalidParamError(id: id, param: "arguments")
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
      
      return (200, makeResult(id: id, result: result))
    } catch {
      return (500, makeError(
        id: id,
        code: -32000,
        message: "Failed to fetch issue",
        data: ["error": error.localizedDescription]
      ))
    }
  }
  
  private func handleIssuesList(
    id: Any?,
    arguments: [String: Any],
    delegate: GitHubToolsHandlerDelegate
  ) async -> (Int, Data) {
    let schema: [ToolArgSchemaField] = [
      .required("owner", .string),
      .required("repo", .string),
      .optional("state", .string, default: "open")
    ]
    let parsedResult = parseArguments(arguments, schema: schema, id: id)
    guard case .success(let parsed) = parsedResult else {
      if case .failure(let error) = parsedResult {
        return error.response
      }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo") else {
      return invalidParamError(id: id, param: "arguments")
    }
    let state = parsed.string("state") ?? "open"
    
    do {
      let issues = try await delegate.listGitHubIssues(owner: owner, repo: repo, state: state)
      
      let resultList = issues.map { issue -> [String: Any] in
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
      
      return (200, makeResult(id: id, result: ["issues": resultList]))
    } catch {
      return (500, makeError(
        id: id,
        code: -32000,
        message: "Failed to list issues",
        data: ["error": error.localizedDescription]
      ))
    }
  }
  
  // MARK: - Error Helpers
  
  private func localNotConfiguredError(id: Any?) -> (Int, Data) {
    (500, makeError(
      id: id,
      code: -32603,
      message: "Internal error",
      data: ["error": "GitHub tools handler not configured"]
    ))
  }
}

// MARK: - Tool Definitions

extension GitHubToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "github.issue.get",
        description: """
        Fetch a single GitHub issue by owner, repository, and issue number.
        Returns issue title, body, state, labels, comments count, and timestamps.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Issue number"]
          ],
          "required": ["owner", "repo", "number"]
        ],
        category: .github,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "github.issues.list",
        description: """
        List issues for a repository.
        Returns an array of issue summaries with title, state, labels, and metadata.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "state": ["type": "string", "enum": ["open", "closed", "all"], "description": "Issue state filter (default: open)"]
          ],
          "required": ["owner", "repo"]
        ],
        category: .github,
        isMutating: false
      ),
    ]
  }
}
