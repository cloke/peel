//
//  Network.swift
//  Network
//
//  Created by Cory Loken on 7/15/21.
//  Cleaned up error handling on 1/7/26
//

import Alamofire
import OAuthSwift
import SwiftUI
import os

enum GithubError: LocalizedError {
  case couldNotDecode
  case invalidRepository
  case missingOwner
  case authenticationFailed(String)
  
  var errorDescription: String? {
    switch self {
    case .couldNotDecode:
      return "Failed to decode response from GitHub"
    case .invalidRepository:
      return "Invalid repository configuration"
    case .missingOwner:
      return "Repository owner is missing"
    case .authenticationFailed(let message):
      return "Authentication failed: \(message)"
    }
  }
}

private let logger = Logger(subsystem: "com.kitchensync", category: "GitHub")

extension Github {
  /// Allows the application initializers to call back into SwiftUI after OAuth has been completed in the browser
  private static var oauthswift: OAuthSwift?
  private static let tokenKey = "github-oauth-token"
  
  static var headers: HTTPHeaders {
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
      logger.error("Failed to retrieve token from keychain: \(error.localizedDescription)")
      return ""
    }
  }
  
  /// Returns an array of pull requests from the specified repository
  /// - parameter organization: The github organization or personal repository name
  public static func pullRequests(from repository: Github.Repository) async throws -> [Github.PullRequest] {
    guard let organization = repository.owner?.login else {
      throw GithubError.missingOwner
    }
    return try await loadMany(url: "https://api.github.com/repos/\(organization)/\(repository.name)/pulls")
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
  
  /// Provides the user record of the current authenticated user.
  public static func me() async throws -> Github.User {
    try await load(url: "https://api.github.com/user")
  }
  
  public static func members(from organization: User) async throws -> [Github.User]  {
    guard let membersUrl = organization.members_url else {
      throw AFError.invalidURL(url: "members only exist on organization users")
    }
    /// Git adds /{member} to the url, but we want just the array url.
    let url = "\(membersUrl[..<membersUrl.index(membersUrl.endIndex, offsetBy: -9)])"
    return try await loadMany(url: url)
  }
  
  public static func commits(from repository: Repository) async throws -> [Github.Commit] {
    guard let commitsUrl = repository.commits_url else {
      throw GithubError.invalidRepository
    }
    let url = "\(commitsUrl[..<commitsUrl.index(commitsUrl.endIndex, offsetBy: -6)])"
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
      throw GithubError.missingOwner
    }
    return try await load(url: "https://api.github.com/repos/\(organization)/\(repository.name)/actions/runs")
  }
  
  public static func workflows(from repository: Repository) async throws -> [Workflow] {
    guard let organization = repository.owner?.login else {
      throw GithubError.missingOwner
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
      throw GithubError.missingOwner
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
  /// - Returns: An array of github issues
  static func issues(from repository: Repository) async throws -> [Issue] {
    guard let issuesUrl = repository.issues_url else {
      throw GithubError.invalidRepository
    }
    let url = "\(issuesUrl[..<issuesUrl.index(issuesUrl.endIndex, offsetBy: -9)])"
    return try await loadMany(url: url)
  }
  
  static func createIssue(for repository: Repository, title: String, body: String, owner: String) async throws -> Issue {
    let json = [
      "title": title,
      "body": body,
      "owner": owner
    ]
    
    guard let organization = repository.owner?.login,
          let url = URL(string: "https://api.github.com/repos/\(organization)/\(repository.name)/issues") else {
      throw GithubError.missingOwner
    }
    
    let headers = await headers
    return try await AF.request(url, method: .post, parameters: json, encoder: JSONParameterEncoder.default, headers: headers)
      .serializingDecodable(Issue.self)
      .value
  }
  
  /// Used when the expected response will be a single of codable object.
  private static func load<T: Codable>(url: String) async throws -> T {
    let headers = await headers
    return try await AF.request(URL(string: url)!, method: .get, headers: headers)
        .serializingDecodable(T.self)
        .value
  }
  
  /// Used when the expected response will be an array of codable objects.
  /// - Parameter url: url to the github api
  /// - Returns: array of codables
  private static func loadMany<T: Codable>(url: String) async throws -> [T] {
    let headers = await headers
    return try await AF.request(URL(string: url)!, method: .get, headers: headers)
      .serializingDecodable([T].self)
      .value
  }
  
  /// Authorizes with the github api or returns success if token exists. To reset token and access call reauthorize.
  public static func authorize() async throws -> Void {
    let currentToken = await getToken()
    if !currentToken.isEmpty {
      logger.info("Token already exists, skipping OAuth")
      return
    }
    
    logger.info("Starting GitHub OAuth flow")
    
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
    
    return try await withCheckedThrowingContinuation { continuation in
      oauthswift.authorize(
        withCallbackURL: URL(string: "crunchy-kitchen-sink://oauth-callback")!, scope: "user,repo,admin:org,org", state: state) { result in
          switch result {
          case .success(let (credential, _, _)):
            Task {
              do {
                try await KeychainService.shared.save(credential.oauthToken, for: "github-oauth-token")
                logger.info("OAuth successful, token saved to keychain")
                continuation.resume()
              } catch {
                logger.error("Failed to save token to keychain: \(error.localizedDescription)")
                continuation.resume(throwing: error)
              }
            }
          case .failure(let err):
            logger.error("OAuth failed: \(err.localizedDescription)")
            continuation.resume(throwing: GithubError.authenticationFailed(err.localizedDescription))
          }
        }
    }
  }
  
  public static func reauthorize() async {
    try? await KeychainService.shared.delete(for: "github-oauth-token")
  }
}
