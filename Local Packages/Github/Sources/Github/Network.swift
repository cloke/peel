//
//  Network.swift
//  Network
//
//  Created by Cory Loken on 7/15/21.
//

import OAuthSwift
import SwiftUI

enum GithubError: Error, LocalizedError {
  case couldNotDecode
  case invalidURL(String)
  case badResponse(Int, String? = nil)

  var errorDescription: String? {
    switch self {
    case .couldNotDecode:
      return "Could not decode response"
    case .invalidURL(let detail):
      return "Invalid URL: \(detail)"
    case .badResponse(let code, let message):
      if let message { return "HTTP \(code): \(message)" }
      return "HTTP \(code)"
    }
  }
}

extension Github {
  /// Allows the application initializers to call back into SwiftUI after OAuth has been completed in the browser
  private static var oauthswift: OAuthSwift?
  private static let tokenKey = "github-oauth-token"
  
  static var headers: [String: String] {
    get async {
      let token = await getToken()
      return [
        "Authorization": "token \(token)",
        "Accept": "application/vnd.github.v3+json",
        "Content-Type": "application/vnd.github.v3+json"
      ]
    }
  }
  
  public static var hasToken: Bool {
    get async {
      let token = await getToken()
      return !token.isEmpty
    }
  }
  
  /// Get token from keychain
  private static func getToken() async -> String {
    do {
      return try await KeychainService.shared.retrieve(for: tokenKey)
    } catch KeychainService.KeychainError.itemNotFound {
      return ""
    } catch {
      print("Failed to retrieve token from keychain: \(error)")
      return ""
    }
  }
  
  /// Returns an array of pull requests from the specified repository
  /// - parameter organization: The github organization or personal repository name
  /// - parameter state: open, closed, or all
  public static func pullRequests(
    from repository: Github.Repository,
    state: String = "open"
  ) async throws -> [Github.PullRequest] {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw GithubError.invalidURL("Missing repository owner")
    }
    let encodedState = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
    return try await loadMany(
      url: "https://api.github.com/repos/\(organization)/\(repository.name)/pulls?state=\(encodedState)&per_page=100"
    )
  }

  /// Convenience: fetch pull requests by owner/repo strings.
  /// - parameter owner: The GitHub owner or organization login
  /// - parameter repository: The repository name
  /// - parameter state: open, closed, or all
  public static func pullRequests(
    owner: String,
    repository: String,
    state: String = "open"
  ) async throws -> [Github.PullRequest] {
    let encodedState = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
    return try await loadMany(
      url: "https://api.github.com/repos/\(owner)/\(repository)/pulls?state=\(encodedState)&per_page=100"
    )
  }
  
  public static func loadRepositories(organization: String) async throws -> [Github.Repository] {
    return try await loadMany(url: "https://api.github.com/orgs/\(organization)/repos?per_page=100")
  }
  
  public static func loadOrganizations() async throws -> [Github.User] {
    try await loadMany(url: "https://api.github.com/user/orgs")
  }
  
  public static func loadReviews(organization: String, repository: String, pullNumber: Int) async throws -> [Github.Review] {
    try await loadMany(url: "https://api.github.com/repos/\(organization)/\(repository)/pulls/\(pullNumber)/reviews")
  }

  /// Fetch issue/PR comments (general conversation comments)
  public static func loadComments(owner: String, repository: String, number: Int) async throws -> [Github.IssueComment] {
    try await loadMany(url: "https://api.github.com/repos/\(owner)/\(repository)/issues/\(number)/comments?per_page=100")
  }

  /// Fetch combined commit status (legacy status API) for a specific ref
  public static func combinedStatus(owner: String, repo: String, ref: String) async throws -> Github.CombinedStatus {
    try await load(url: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(ref)/status")
  }

  /// Fetch check runs for a specific ref
  public static func checkRuns(owner: String, repo: String, ref: String) async throws -> Github.CheckRunsResponse {
    try await load(url: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(ref)/check-runs")
  }

  /// Fetch aggregated check status combining both status API and check runs API
  public static func aggregatedCheckStatus(owner: String, repo: String, ref: String) async throws -> Github.AggregatedCheckStatus {
    async let statusTask = combinedStatus(owner: owner, repo: repo, ref: ref)
    async let checksTask = checkRuns(owner: owner, repo: repo, ref: ref)

    var items: [Github.CheckItem] = []

    // Collect legacy statuses
    if let combined = try? await statusTask {
      for s in combined.statuses {
        let state: Github.CheckItemState = switch s.state {
        case "success": .success
        case "failure", "error": .failure
        case "pending": .pending
        default: .neutral
        }
        items.append(Github.CheckItem(id: "status-\(s.id)", name: s.context, state: state, url: s.target_url))
      }
    }

    // Collect check runs
    if let runs = try? await checksTask {
      for run in runs.check_runs {
        let state: Github.CheckItemState
        if run.status != "completed" {
          state = .pending
        } else {
          state = switch run.conclusion {
          case "success": .success
          case "failure", "timed_out", "action_required": .failure
          case "skipped": .skipped
          case "neutral", "cancelled": .neutral
          default: .neutral
          }
        }
        items.append(Github.CheckItem(id: "check-\(run.id)", name: run.name, state: state, url: run.html_url))
      }
    }

    let passed = items.filter { $0.state == .success }.count
    let failed = items.filter { $0.state == .failure }.count
    let pending = items.filter { $0.state == .pending }.count

    return Github.AggregatedCheckStatus(total: items.count, passed: passed, failed: failed, pending: pending, checks: items)
  }
  
  /// Provides the user record of the current authenticated user.
  public static func me() async throws -> Github.User {
    try await load(url: "https://api.github.com/user")
  }
  
  /// Fetch a single repository by owner and name
  public static func repository(owner: String, name: String) async throws -> Github.Repository {
    try await load(url: "https://api.github.com/repos/\(owner)/\(name)")
  }

  /// Fetch a single pull request by owner, repository, and number
  public static func pullRequest(owner: String, repository: String, number: Int) async throws -> Github.PullRequest {
    try await load(url: "https://api.github.com/repos/\(owner)/\(repository)/pulls/\(number)")
  }

  /// Fetch files changed in a pull request
  public static func pullRequestFiles(owner: String, repository: String, number: Int) async throws -> [Github.PRFile] {
    try await loadMany(url: "https://api.github.com/repos/\(owner)/\(repository)/pulls/\(number)/files?per_page=100")
  }

  /// Fetch the full unified diff for a pull request as raw text
  public static func pullRequestDiff(owner: String, repository: String, number: Int) async throws -> String {
    try await loadRawText(
      url: "https://api.github.com/repos/\(owner)/\(repository)/pulls/\(number)",
      accept: "application/vnd.github.v3.diff"
    )
  }

  /// Fetch general conversation comments on a PR (issue comments endpoint)
  public static func issueComments(owner: String, repository: String, number: Int) async throws -> [Github.IssueComment] {
    try await loadMany(url: "https://api.github.com/repos/\(owner)/\(repository)/issues/\(number)/comments?per_page=100")
  }

  /// Fetch inline review comments on a PR diff
  public static func reviewComments(owner: String, repository: String, number: Int) async throws -> [Github.ReviewComment] {
    try await loadMany(url: "https://api.github.com/repos/\(owner)/\(repository)/pulls/\(number)/comments?per_page=100")
  }

  /// Fetch a user by login
  public static func user(login: String) async throws -> Github.User {
    try await load(url: "https://api.github.com/users/\(login)")
  }

  // MARK: - Pull Request Write Operations

  /// Submit a review on a pull request
  /// - Parameters:
  ///   - owner: Repository owner
  ///   - repository: Repository name
  ///   - number: PR number
  ///   - event: APPROVE, REQUEST_CHANGES, or COMMENT
  ///   - body: Review body text
  ///   - comments: Optional inline comments (path, line, body)
  public static func createPullRequestReview(
    owner: String,
    repository: String,
    number: Int,
    event: String,
    body: String,
    commentsJSON: Data? = nil
  ) async throws -> Github.Review {
    let url = "https://api.github.com/repos/\(owner)/\(repository)/pulls/\(number)/reviews"
    var json: [String: Any] = [
      "event": event,
      "body": body
    ]
    if let commentsJSON,
       let comments = try? JSONSerialization.jsonObject(with: commentsJSON) as? [[String: Any]],
       !comments.isEmpty {
      json["comments"] = comments
    }
    let bodyData = try JSONSerialization.data(withJSONObject: json, options: [])
    return try await load(url: URL(string: url)!, method: "POST", body: bodyData)
  }

  /// Post a general comment on a PR (uses the issues comment endpoint)
  public static func createPRComment(
    owner: String,
    repository: String,
    number: Int,
    body: String
  ) async throws -> Github.IssueComment {
    let url = "https://api.github.com/repos/\(owner)/\(repository)/issues/\(number)/comments"
    let json: [String: String] = ["body": body]
    let bodyData = try JSONSerialization.data(withJSONObject: json, options: [])
    return try await load(url: URL(string: url)!, method: "POST", body: bodyData)
  }

  /// Merge a pull request
  public static func mergePullRequest(
    owner: String,
    repository: String,
    number: Int,
    mergeMethod: String = "merge",
    commitTitle: String? = nil,
    commitMessage: String? = nil
  ) async throws -> Github.MergeResult {
    let url = "https://api.github.com/repos/\(owner)/\(repository)/pulls/\(number)/merge"
    var json: [String: String] = ["merge_method": mergeMethod]
    if let commitTitle { json["commit_title"] = commitTitle }
    if let commitMessage { json["commit_message"] = commitMessage }
    let bodyData = try JSONSerialization.data(withJSONObject: json, options: [])
    return try await load(url: URL(string: url)!, method: "PUT", body: bodyData)
  }

  /// Add labels to a PR/issue
  public static func addLabels(
    owner: String,
    repository: String,
    number: Int,
    labels: [String]
  ) async throws -> [Github.Label] {
    let url = "https://api.github.com/repos/\(owner)/\(repository)/issues/\(number)/labels"
    let json: [String: [String]] = ["labels": labels]
    let bodyData = try JSONSerialization.data(withJSONObject: json, options: [])
    return try await load(url: URL(string: url)!, method: "POST", body: bodyData)
  }
  
  public static func members(from organization: User) async throws -> [Github.User]  {
    guard let membersUrl = organization.members_url else {
      throw GithubError.invalidURL("members_url not available on organization")
    }
    /// Git adds /{member} to the url, but we want just the array url.
    let url = String(membersUrl.dropLast(9))
    return try await loadMany(url: url)
  }
  
  public static func commits(from repository: Repository) async throws -> [Github.Commit] {
    guard let commitsUrl = repository.commits_url else {
      throw GithubError.invalidURL("commits_url not available on repository")
    }
    let url = String(commitsUrl.dropLast(6))
    return try await loadMany(url: url)
  }
  
  /// Get the details of a single commit
  static func commitDetail(from commit: Commit) async throws -> Github.CommitDetail {
    try await load(url: commit.url)
  }
  
  static func workflowJobs(from action: Action) async throws -> WorkflowRun {
     try await load(url: action.jobs_url)
  }
  
  static func actions(from repository: Repository) async throws -> Runs {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw GithubError.invalidURL("Missing repository owner")
    }
    return try await load(url: "https://api.github.com/repos/\(organization)/\(repository.name)/actions/runs")
  }
  
  public static func workflows(from repository: Repository) async throws -> [Workflow] {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw GithubError.invalidURL("Missing repository owner")
    }
    let url = "https://api.github.com/repos/\(organization)/\(repository.name)/actions/workflows"

    guard let workflowContainer: Github.WorkflowContainer = try await load(url: url) else {
      throw GithubError.couldNotDecode
    }
    return workflowContainer.workflows
  }
  
  /// Returns an array of Github workflow runs
  /// - Parameters:
  ///   - workflow: Github.Workflow referencing a workflow containing workflow runs
  ///   - repository: repository containing workflows
  /// - Returns: An array of Github actions. [Github.Action]
  public static func runs(from workflow: Workflow, repository: Repository) async throws -> [Action] {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw GithubError.invalidURL("Missing repository owner")
    }
    let url = "https://api.github.com/repos/\(organization)/\(repository.name)/actions/workflows/\(workflow.id)/runs"
    guard let workflowContainer: Github.Runs = try await load(url: url) else {
      throw GithubError.couldNotDecode
    }
    
    return workflowContainer.workflow_runs
  }
  
  /// Returns an array of Github issues.
  /// - Parameters:
  ///   - repository: Github.Repository referencing a repository containing issues
  ///   - state: open, closed, or all
  /// - Returns: An array of github issues
  public static func issues(from repository: Repository, state: String = "open") async throws -> [Issue] {
    guard let issuesUrl = repository.issues_url else {
      throw GithubError.invalidURL("issues_url not available on repository")
    }
    let encodedState = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
    let baseUrl = String(issuesUrl.dropLast(9))
    let url = "\(baseUrl)?state=\(encodedState)&per_page=100"
    return try await loadMany(url: url)
  }
  
  /// Fetch a single issue by owner, repository, and number
  public static func issue(owner: String, repository: String, number: Int) async throws -> Issue {
    try await load(url: "https://api.github.com/repos/\(owner)/\(repository)/issues/\(number)")
  }
  
  static func createIssue(for repository: Repository, title: String, body: String, owner: String) async throws -> Issue {
    guard let organization = repository.owner?.login,
          let url = URL(string: "https://api.github.com/repos/\(organization)/\(repository.name)/issues") else {
      print("Issue generating url for repository")
      throw GithubError.invalidURL("Invalid issues URL")
    }
    
    let json: [String: String] = [
      "title": title,
      "body": body,
      "owner": owner
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: json, options: [])
    return try await load(url: url, method: "POST", body: bodyData)
  }
  
  /// Used when the expected response will be a single of codable object.
  private static func load<T: Codable>(url: String) async throws -> T {
    guard let requestUrl = URL(string: url) else {
      throw GithubError.invalidURL(url)
    }
    return try await load(url: requestUrl)
  }
  
  /// Used when the expected response will be an array of codable objects.
  /// - Parameter url: url to the github api
  /// - Returns: array of codables
  private static func loadMany<T: Codable>(url: String) async throws -> [T] {
    guard let requestUrl = URL(string: url) else {
      throw GithubError.invalidURL(url)
    }
    return try await load(url: requestUrl)
  }

  /// Fetch a raw text response (e.g. diff, patch) with a custom Accept header.
  private static func loadRawText(url: String, accept: String) async throws -> String {
    guard let requestUrl = URL(string: url) else {
      throw GithubError.invalidURL(url)
    }

    var request = URLRequest(url: requestUrl)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let headerValues = await headers
    for (key, value) in headerValues {
      request.setValue(value, forHTTPHeaderField: key)
    }
    // Override Accept header for raw format
    request.setValue(accept, forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GithubError.badResponse(-1)
    }
    guard (200...299).contains(http.statusCode) else {
      throw GithubError.badResponse(http.statusCode, Self.extractErrorMessage(from: data))
    }

    guard let text = String(data: data, encoding: .utf8) else {
      throw GithubError.couldNotDecode
    }
    return text
  }

  private static func load<T: Codable>(url: URL, method: String = "GET", body: Data? = nil) async throws -> T {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let headerValues = await headers
    for (key, value) in headerValues {
      request.setValue(value, forHTTPHeaderField: key)
    }
    
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GithubError.badResponse(-1)
    }
    guard (200...299).contains(http.statusCode) else {
      throw GithubError.badResponse(http.statusCode, Self.extractErrorMessage(from: data))
    }
    
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw GithubError.couldNotDecode
    }
  }

  /// Extract a human-readable error message from a GitHub API error response body.
  private static func extractErrorMessage(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return String(data: data, encoding: .utf8)?.prefix(500).description
    }
    let message = json["message"] as? String
    if let errors = json["errors"] as? [[String: Any]] {
      let details = errors.compactMap { e -> String? in
        let parts = [e["resource"], e["field"], e["code"], e["message"]].compactMap { $0 as? String }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
      }
      if !details.isEmpty {
        return [message, details.joined(separator: "; ")].compactMap { $0 }.joined(separator: " — ")
      }
    }
    return message
  }

  /// Authorizes with the github api or returns success if token exists. To reset token and access call reauthorize.
  public static func authorize() async throws -> Void {
    let currentToken = await getToken()
    if !currentToken.isEmpty {
      print("Token already exists")
      return
    }
    
    print("=== Starting GitHub OAuth ===")
    print("Client ID: Ov23liMnGh1bRfKc0qpU")
    print("Callback URL: crunchy-kitchen-sink://oauth-callback")
    print("============================")
    
    let oauthswift = OAuth2Swift(
      consumerKey:    "Ov23liMnGh1bRfKc0qpU",
      consumerSecret: "2c18d51fc40cda6e94a626fafcc98f4968f4e850",
      authorizeUrl:   "https://github.com/login/oauth/authorize",
      accessTokenUrl: "https://github.com/login/oauth/access_token",
      responseType:   "code"
    )
    
    self.oauthswift = oauthswift
    oauthswift.authorizeURLHandler = OAuthSwiftOpenURLExternally.sharedInstance
    
    let state = generateState(withLength: 20)
    print("Generated OAuth state: \(state)")
    
    return try await withCheckedThrowingContinuation { continuation in
      oauthswift.authorize(
        withCallbackURL: URL(string: "crunchy-kitchen-sink://oauth-callback")!, scope: "user,repo,admin:org,org", state: state) { result in
          switch result {
          case .success(let (credential, _, _)):
            Task {
              do {
                try await KeychainService.shared.save(credential.oauthToken, for: "github-oauth-token")
                print("OAuth successful, token saved to keychain")
                continuation.resume()
              } catch {
                print("Failed to save token to keychain: \(error)")
                continuation.resume(throwing: error)
              }
            }
          case .failure(let err):
            print("OAuth failed: \(err.localizedDescription)")
            print("OAuth error details: \(err)")
            continuation.resume(throwing: err)
          }
        }
    }
  }
  
  public static func reauthorize() async {
    try? await KeychainService.shared.delete(for: "github-oauth-token")
  }
}
