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

  // MARK: - Pull Request Read

  /// Fetch a single pull request
  func fetchPullRequest(owner: String, repo: String, number: Int) async throws -> Github.PullRequest

  /// Fetch files changed in a pull request
  func fetchPullRequestFiles(owner: String, repo: String, number: Int) async throws -> [Github.PRFile]

  /// Fetch the full unified diff for a pull request
  func fetchPullRequestDiff(owner: String, repo: String, number: Int) async throws -> String

  /// Fetch reviews on a pull request
  func fetchPullRequestReviews(owner: String, repo: String, number: Int) async throws -> [Github.Review]

  /// Fetch conversation + inline review comments on a pull request
  func fetchPullRequestComments(owner: String, repo: String, number: Int) async throws -> (issueComments: [Github.IssueComment], reviewComments: [Github.ReviewComment])

  /// Fetch aggregated check/CI status for a ref
  func fetchCheckStatus(owner: String, repo: String, ref: String) async throws -> Github.AggregatedCheckStatus

  // MARK: - Pull Request Write

  /// Submit a review on a pull request (comments pre-serialized as JSON Data for Sendable compliance)
  func createPullRequestReview(owner: String, repo: String, number: Int, event: String, body: String, commentsJSON: Data?) async throws -> Github.Review

  /// Post a general comment on a pull request
  func createPRComment(owner: String, repo: String, number: Int, body: String) async throws -> Github.IssueComment

  /// Add labels to a pull request
  func addLabels(owner: String, repo: String, number: Int, labels: [String]) async throws -> [Github.Label]
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
    "github.issues.list",
    "github.pr.get",
    "github.pr.files",
    "github.pr.diff",
    "github.pr.reviews",
    "github.pr.comments",
    "github.pr.checks",
    "github.pr.review.create",
    "github.pr.comment",
    "github.pr.label",
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
    case "github.pr.get":
      return await handlePRGet(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.pr.files":
      return await handlePRFiles(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.pr.diff":
      return await handlePRDiff(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.pr.reviews":
      return await handlePRReviews(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.pr.comments":
      return await handlePRComments(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.pr.checks":
      return await handlePRChecks(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.pr.review.create":
      return await handlePRReviewCreate(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.pr.comment":
      return await handlePRCommentCreate(id: id, arguments: arguments, delegate: githubDelegate)
    case "github.pr.label":
      return await handlePRLabel(id: id, arguments: arguments, delegate: githubDelegate)
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
        "updated_at": issue.updated_at,
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
          "updated_at": issue.updated_at
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
  
  // MARK: - PR Read Handlers

  private func handlePRGet(
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
      if case .failure(let error) = parsedResult { return error.response }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let number = parsed.int("number") else {
      return invalidParamError(id: id, param: "arguments")
    }

    do {
      let pr = try await delegate.fetchPullRequest(owner: owner, repo: repo, number: number)

      var result: [String: Any] = [
        "number": pr.number,
        "title": pr.title ?? "",
        "state": pr.state ?? "unknown",
        "body": pr.body ?? "",
        "draft": pr.draft ?? false,
        "additions": pr.additions ?? 0,
        "deletions": pr.deletions ?? 0,
        "changed_files": pr.changed_files ?? 0,
        "commits": pr.commits ?? 0,
        "head_ref": pr.head.ref,
        "head_sha": pr.head.sha,
        "base_ref": pr.base.ref,
        "base_sha": pr.base.sha,
        "html_url": pr.html_url ?? "",
        "created_at": pr.created_at ?? "",
        "updated_at": pr.updated_at ?? "",
        "merged_at": pr.merged_at ?? "",
        "labels": (pr.labels ?? []).compactMap { $0.name },
        "author": pr.user?.login ?? "",
        "assignees": (pr.assignees ?? []).compactMap { $0.login },
        "requested_reviewers": (pr.requested_reviewers ?? []).compactMap { $0.login }
      ]
      if let repo = pr.base.repo.full_name {
        result["repository"] = repo
      }
      return (200, makeResult(id: id, result: result))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to fetch PR", data: ["error": error.localizedDescription]))
    }
  }

  private func handlePRFiles(
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
      if case .failure(let error) = parsedResult { return error.response }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let number = parsed.int("number") else {
      return invalidParamError(id: id, param: "arguments")
    }

    do {
      let files = try await delegate.fetchPullRequestFiles(owner: owner, repo: repo, number: number)

      let fileList = files.map { file -> [String: Any] in
        var item: [String: Any] = [
          "filename": file.filename,
          "status": file.status,
          "additions": file.additions,
          "deletions": file.deletions,
          "changes": file.changes
        ]
        if let patch = file.patch {
          item["patch"] = patch
        }
        if let prev = file.previous_filename {
          item["previous_filename"] = prev
        }
        return item
      }

      return (200, makeResult(id: id, result: [
        "files": fileList,
        "total_files": files.count,
        "total_additions": files.reduce(0) { $0 + $1.additions },
        "total_deletions": files.reduce(0) { $0 + $1.deletions }
      ]))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to fetch PR files", data: ["error": error.localizedDescription]))
    }
  }

  private func handlePRDiff(
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
      if case .failure(let error) = parsedResult { return error.response }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let number = parsed.int("number") else {
      return invalidParamError(id: id, param: "arguments")
    }

    do {
      let diff = try await delegate.fetchPullRequestDiff(owner: owner, repo: repo, number: number)

      // Truncate very large diffs to avoid overwhelming the LLM context
      let maxLength = 100_000
      let truncated = diff.count > maxLength
      let diffText = truncated ? String(diff.prefix(maxLength)) + "\n\n... [diff truncated at \(maxLength) chars, \(diff.count) total]" : diff

      return (200, makeResult(id: id, result: [
        "diff": diffText,
        "length": diff.count,
        "truncated": truncated
      ]))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to fetch PR diff", data: ["error": error.localizedDescription]))
    }
  }

  private func handlePRReviews(
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
      if case .failure(let error) = parsedResult { return error.response }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let number = parsed.int("number") else {
      return invalidParamError(id: id, param: "arguments")
    }

    do {
      let reviews = try await delegate.fetchPullRequestReviews(owner: owner, repo: repo, number: number)

      let reviewList = reviews.map { review -> [String: Any] in
        [
          "id": review.id,
          "user": review.user.login ?? "",
          "state": review.state,
          "body": review.body,
          "submitted_at": review.submitted_at,
          "html_url": review.html_url
        ]
      }

      return (200, makeResult(id: id, result: [
        "reviews": reviewList,
        "count": reviews.count
      ]))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to fetch PR reviews", data: ["error": error.localizedDescription]))
    }
  }

  private func handlePRComments(
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
      if case .failure(let error) = parsedResult { return error.response }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let number = parsed.int("number") else {
      return invalidParamError(id: id, param: "arguments")
    }

    do {
      let (issueComments, reviewComments) = try await delegate.fetchPullRequestComments(owner: owner, repo: repo, number: number)

      let conversationList = issueComments.map { c -> [String: Any] in
        [
          "id": c.id,
          "type": "conversation",
          "user": c.user.login ?? "",
          "body": c.body,
          "created_at": c.created_at,
          "html_url": c.html_url
        ]
      }

      let inlineList = reviewComments.map { c -> [String: Any] in
        var item: [String: Any] = [
          "id": c.id,
          "type": "inline",
          "user": c.user.login ?? "",
          "body": c.body,
          "path": c.path,
          "created_at": c.created_at,
          "html_url": c.html_url
        ]
        if let line = c.line { item["line"] = line }
        if let diffHunk = c.diff_hunk { item["diff_hunk"] = diffHunk }
        if let replyTo = c.in_reply_to_id { item["in_reply_to_id"] = replyTo }
        return item
      }

      return (200, makeResult(id: id, result: [
        "conversation_comments": conversationList,
        "inline_comments": inlineList,
        "total_conversation": issueComments.count,
        "total_inline": reviewComments.count
      ]))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to fetch PR comments", data: ["error": error.localizedDescription]))
    }
  }

  private func handlePRChecks(
    id: Any?,
    arguments: [String: Any],
    delegate: GitHubToolsHandlerDelegate
  ) async -> (Int, Data) {
    let schema: [ToolArgSchemaField] = [
      .required("owner", .string),
      .required("repo", .string),
      .required("ref", .string)
    ]
    let parsedResult = parseArguments(arguments, schema: schema, id: id)
    guard case .success(let parsed) = parsedResult else {
      if case .failure(let error) = parsedResult { return error.response }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let ref = parsed.string("ref") else {
      return invalidParamError(id: id, param: "arguments")
    }

    do {
      let status = try await delegate.fetchCheckStatus(owner: owner, repo: repo, ref: ref)

      let checkList = status.checks.map { check -> [String: Any] in
        let stateStr: String
        switch check.state {
        case .success: stateStr = "success"
        case .failure: stateStr = "failure"
        case .pending: stateStr = "pending"
        case .neutral: stateStr = "neutral"
        case .skipped: stateStr = "skipped"
        }
        var item: [String: Any] = [
          "name": check.name,
          "state": stateStr
        ]
        if let url = check.url { item["url"] = url }
        return item
      }

      let summary: String
      if status.failed > 0 { summary = "failing" }
      else if status.pending > 0 { summary = "pending" }
      else { summary = "passing" }

      return (200, makeResult(id: id, result: [
        "total": status.total,
        "passed": status.passed,
        "failed": status.failed,
        "pending": status.pending,
        "checks": checkList,
        "summary": summary
      ]))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to fetch check status", data: ["error": error.localizedDescription]))
    }
  }

  // MARK: - PR Write Handlers

  private func handlePRReviewCreate(
    id: Any?,
    arguments: [String: Any],
    delegate: GitHubToolsHandlerDelegate
  ) async -> (Int, Data) {
    let schema: [ToolArgSchemaField] = [
      .required("owner", .string),
      .required("repo", .string),
      .required("number", .int),
      .required("event", .string),
      .required("body", .string)
    ]
    let parsedResult = parseArguments(arguments, schema: schema, id: id)
    guard case .success(let parsed) = parsedResult else {
      if case .failure(let error) = parsedResult { return error.response }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let number = parsed.int("number"),
          let event = parsed.string("event"),
          let body = parsed.string("body") else {
      return invalidParamError(id: id, param: "arguments")
    }

    let validEvents = ["APPROVE", "REQUEST_CHANGES", "COMMENT"]
    guard validEvents.contains(event) else {
      return (400, makeError(id: id, code: -32602, message: "Invalid event. Must be one of: \(validEvents.joined(separator: ", "))"))
    }

    // Parse optional inline comments — serialize to JSON Data for Sendable compliance
    var commentsJSON: Data?
    if let rawComments = arguments["comments"] as? [[String: Any]] {
      let parsed = rawComments.compactMap { raw -> [String: Any]? in
        guard let path = raw["path"] as? String,
              let commentBody = raw["body"] as? String else { return nil }
        var comment: [String: Any] = ["path": path, "body": commentBody]
        if let line = raw["line"] as? Int { comment["line"] = line }
        if let side = raw["side"] as? String { comment["side"] = side }
        return comment
      }
      if !parsed.isEmpty {
        commentsJSON = try? JSONSerialization.data(withJSONObject: parsed, options: [])
      }
    }

    do {
      let review = try await delegate.createPullRequestReview(
        owner: owner, repo: repo, number: number,
        event: event, body: body, commentsJSON: commentsJSON
      )

      return (200, makeResult(id: id, result: [
        "id": review.id,
        "state": review.state,
        "html_url": review.html_url,
        "submitted_at": review.submitted_at
      ]))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to create review", data: ["error": error.localizedDescription]))
    }
  }

  private func handlePRCommentCreate(
    id: Any?,
    arguments: [String: Any],
    delegate: GitHubToolsHandlerDelegate
  ) async -> (Int, Data) {
    let schema: [ToolArgSchemaField] = [
      .required("owner", .string),
      .required("repo", .string),
      .required("number", .int),
      .required("body", .string)
    ]
    let parsedResult = parseArguments(arguments, schema: schema, id: id)
    guard case .success(let parsed) = parsedResult else {
      if case .failure(let error) = parsedResult { return error.response }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let number = parsed.int("number"),
          let body = parsed.string("body") else {
      return invalidParamError(id: id, param: "arguments")
    }

    do {
      let comment = try await delegate.createPRComment(
        owner: owner, repo: repo, number: number, body: body
      )

      return (200, makeResult(id: id, result: [
        "id": comment.id,
        "html_url": comment.html_url,
        "created_at": comment.created_at
      ]))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to create comment", data: ["error": error.localizedDescription]))
    }
  }

  private func handlePRLabel(
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
      if case .failure(let error) = parsedResult { return error.response }
      return invalidParamError(id: id, param: "arguments")
    }
    guard let owner = parsed.string("owner"),
          let repo = parsed.string("repo"),
          let number = parsed.int("number") else {
      return invalidParamError(id: id, param: "arguments")
    }
    guard let labels = arguments["labels"] as? [String], !labels.isEmpty else {
      return (400, makeError(id: id, code: -32602, message: "labels must be a non-empty array of strings"))
    }

    do {
      let resultLabels = try await delegate.addLabels(
        owner: owner, repo: repo, number: number, labels: labels
      )

      return (200, makeResult(id: id, result: [
        "labels": resultLabels.map { ["name": $0.name, "color": $0.color] },
        "count": resultLabels.count
      ]))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to add labels", data: ["error": error.localizedDescription]))
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

      // MARK: PR Read Tools

      MCPToolDefinition(
        name: "github.pr.get",
        description: """
        Fetch a single pull request by owner, repository, and PR number.
        Returns PR metadata including title, body, state, author, labels, reviewers,
        additions/deletions/changed_files counts, head/base refs and SHAs, and URLs.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Pull request number"]
          ],
          "required": ["owner", "repo", "number"]
        ],
        category: .github,
        isMutating: false
      ),

      MCPToolDefinition(
        name: "github.pr.files",
        description: """
        List files changed in a pull request.
        Returns each file with filename, status (added/modified/removed/renamed),
        additions, deletions, and patch (unified diff hunks for that file).
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Pull request number"]
          ],
          "required": ["owner", "repo", "number"]
        ],
        category: .github,
        isMutating: false
      ),

      MCPToolDefinition(
        name: "github.pr.diff",
        description: """
        Fetch the full unified diff for a pull request.
        Returns the raw diff text (same format as `git diff`).
        Large diffs are truncated at 100K characters.
        Best for: getting a complete view of all changes at once.
        For per-file patches, use github.pr.files instead.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Pull request number"]
          ],
          "required": ["owner", "repo", "number"]
        ],
        category: .github,
        isMutating: false
      ),

      MCPToolDefinition(
        name: "github.pr.reviews",
        description: """
        List all reviews submitted on a pull request.
        Returns each review with reviewer, state (APPROVED/CHANGES_REQUESTED/COMMENTED/DISMISSED),
        body text, and submission timestamp.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Pull request number"]
          ],
          "required": ["owner", "repo", "number"]
        ],
        category: .github,
        isMutating: false
      ),

      MCPToolDefinition(
        name: "github.pr.comments",
        description: """
        Fetch all comments on a pull request, both conversation comments and inline review comments.
        Returns two arrays:
        - conversation_comments: General PR discussion comments
        - inline_comments: Code-level review comments with file path, line number, and diff context
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Pull request number"]
          ],
          "required": ["owner", "repo", "number"]
        ],
        category: .github,
        isMutating: false
      ),

      MCPToolDefinition(
        name: "github.pr.checks",
        description: """
        Fetch CI/CD check status for a git ref (branch name or commit SHA).
        Returns total, passed, failed, pending counts and individual check details.
        Use the head_sha from github.pr.get as the ref parameter.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "ref": ["type": "string", "description": "Git ref to check — branch name or commit SHA (use head_sha from github.pr.get)"]
          ],
          "required": ["owner", "repo", "ref"]
        ],
        category: .github,
        isMutating: false
      ),

      // MARK: PR Write Tools

      MCPToolDefinition(
        name: "github.pr.review.create",
        description: """
        Submit a review on a pull request.
        Can approve, request changes, or leave a comment-only review.
        Optionally include inline comments on specific files and lines.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Pull request number"],
            "event": ["type": "string", "enum": ["APPROVE", "REQUEST_CHANGES", "COMMENT"], "description": "Review action"],
            "body": ["type": "string", "description": "Review summary text"],
            "comments": [
              "type": "array",
              "description": "Optional inline comments on specific files",
              "items": [
                "type": "object",
                "properties": [
                  "path": ["type": "string", "description": "File path relative to repo root"],
                  "line": ["type": "integer", "description": "Line number in the diff to comment on"],
                  "body": ["type": "string", "description": "Comment text"],
                  "side": ["type": "string", "enum": ["LEFT", "RIGHT"], "description": "Which side of the diff (default: RIGHT)"]
                ],
                "required": ["path", "body"]
              ]
            ]
          ],
          "required": ["owner", "repo", "number", "event", "body"]
        ],
        category: .github,
        isMutating: true
      ),

      MCPToolDefinition(
        name: "github.pr.comment",
        description: """
        Post a general comment on a pull request conversation.
        Use this for overall feedback. For inline code comments, use github.pr.review.create with comments array.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Pull request number"],
            "body": ["type": "string", "description": "Comment text (supports Markdown)"]
          ],
          "required": ["owner", "repo", "number", "body"]
        ],
        category: .github,
        isMutating: true
      ),

      MCPToolDefinition(
        name: "github.pr.label",
        description: """
        Add labels to a pull request. Labels must already exist in the repository.
        Common review labels: needs-review, approved, changes-requested, wip.
        """,
        inputSchema: [
          "type": "object",
          "properties": [
            "owner": ["type": "string", "description": "Repository owner (username or organization)"],
            "repo": ["type": "string", "description": "Repository name"],
            "number": ["type": "integer", "description": "Pull request number"],
            "labels": [
              "type": "array",
              "items": ["type": "string"],
              "description": "Array of label names to add"
            ]
          ],
          "required": ["owner", "repo", "number", "labels"]
        ],
        category: .github,
        isMutating: true
      ),
    ]
  }
}
