//
//  Network.swift
//  Network
//
//  Created by Cory Loken on 7/15/21.
//

import Alamofire
import OAuthSwift
import SwiftUI

enum GithubError: Error {
  case couldNotDecode
}

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
      print("Failed to retrieve token from keychain: \(error)")
      return ""
    }
  }
  
  /// Returns an array of pull requests from the specified repository
  /// - parameter organization: The github organization or personal repository name
  public static func pullRequests(from repository: Github.Repository) async throws -> [Github.PullRequest] {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw AFError.invalidURL(url: "")
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
  
  /// Fetch a single repository by owner and name
  public static func repository(owner: String, name: String) async throws -> Github.Repository {
    try await load(url: "https://api.github.com/repos/\(owner)/\(name)")
  }
  
  /// Fetch a user by login
  public static func user(login: String) async throws -> Github.User {
    try await load(url: "https://api.github.com/users/\(login)")
  }
  
  public static func members(from organization: User) async throws -> [Github.User]  {
    guard let membersUrl = organization.members_url else {
      throw AFError.invalidURL(url: "members only exist on organization users")
    }
    /// Git adds /{member} to the url, but we want just the array url.
    let url = String(membersUrl.dropLast(9))
    return try await loadMany(url: url)
  }
  
  public static func commits(from repository: Repository) async throws -> [Github.Commit] {
    guard let commitsUrl = repository.commits_url else {
      throw AFError.invalidURL(url: "commits_url not available on repository")
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
      throw AFError.invalidURL(url: "")
    }
    return try await load(url: "https://api.github.com/repos/\(organization)/\(repository.name)/actions/runs")
  }
  
  public static func workflows(from repository: Repository) async throws -> [Workflow] {
    guard let organization = repository.owner?.login else {
      print("Issue generating url for repository")
      throw AFError.invalidURL(url: "")
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
      throw AFError.invalidURL(url: "")
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
      throw AFError.invalidURL(url: "issues_url not available on repository")
    }
    let url = String(issuesUrl.dropLast(9))
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
      print("Issue generating url for repository")
      throw AFError.invalidURL(url: "")
    }
    
    let headers = await headers
    return try await AF.request(url, method: .post, parameters: json, encoder: JSONParameterEncoder.default, headers: headers)
      .serializingDecodable(Issue.self)
      .value
  }
  
  /// Used when the expected response will be a single of codable object.
  private static func load<T: Codable>(url: String) async throws -> T {
    guard let requestUrl = URL(string: url) else {
      throw AFError.invalidURL(url: url)
    }
    let headers = await headers
    return try await AF.request(requestUrl, method: .get, headers: headers)
        .serializingDecodable(T.self)
        .value
  }
  
  /// Used when the expected response will be an array of codable objects.
  /// - Parameter url: url to the github api
  /// - Returns: array of codables
  private static func loadMany<T: Codable>(url: String) async throws -> [T] {
    guard let requestUrl = URL(string: url) else {
      throw AFError.invalidURL(url: url)
    }
    let headers = await headers
    return try await AF.request(requestUrl, method: .get, headers: headers)
      .serializingDecodable([T].self)
      .value
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
